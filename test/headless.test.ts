// wland/headless over a scripted link: the real core in Node, scripted
// clients (STREAM frames in), the engine calls the headless scene makes (a
// spy on its engine) and what its screenshots show. Needs a prior
// `zig build` (lib/wland.wasm; the engine finds it by default).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { crc32, inflateSync } from 'node:zlib';
import { createHeadless, encodePNG, type Headless, type HeadlessOptions } from '../lib/headless.ts';
import type { BufferHandle, Engine, Event, HandleSource, Link, LinkCallbacks } from '../lib/engine.ts';

// --- STREAM frames + wayland wire ------------------------------------------
const u32s = (...v: number[]) => new Uint8Array(new Uint32Array(v).buffer);
function cat(...parts: Uint8Array[]) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}
const frame = (type: number, ...parts: Uint8Array[]) => cat(new Uint8Array([type]), ...parts);
const wire = (conn: number, bytes: Uint8Array) => frame(0x01, u32s(conn, bytes.length), bytes);
const connOpen = (conn: number) => frame(0x03, u32s(conn));
const connClose = (conn: number) => frame(0x04, u32s(conn));
// BUFFER: canvas-ready RGBA, packed per damage rect (rects [x, y, w, h])
const buffer = (conn: number, surface: number, w: number, h: number, rects: number[][], pixels: Uint8Array) =>
  frame(0x02, u32s(conn, surface, w, h, rects.length), u32s(...rects.flat()), pixels);
const fdmsg = (conn: number, kind: number, bytes: Uint8Array) => frame(0x05, u32s(conn, kind, bytes.length), bytes, u32s(0));
const handleOpen = (conn: number, handle: number, id: number, size: number) =>
  frame(0x08, u32s(conn, handle, 1, 12, id, size, 0)); // kwshm: export id + u64 size
const shmCommit = (conn: number, surface: number, serial: number, ref: number[], rects: number[][]) =>
  frame(0x0a, u32s(conn, surface, serial, rects.length, 1, 24, ...ref), u32s(...rects.flat()));

function wlString(s: string) {
  const b = new TextEncoder().encode(s);
  const out = new Uint8Array(4 + ((b.length + 1 + 3) & ~3));
  new DataView(out.buffer).setUint32(0, b.length + 1, true);
  out.set(b, 4);
  return out;
}
// one request: object, opcode, args (numbers = u32/i32, strings)
function msg(object: number, opcode: number, ...args: (number | string)[]) {
  const body = args.map((a) => (typeof a === 'string' ? wlString(a) : u32s(a >>> 0)));
  const size = 8 + body.reduce((n, b) => n + b.length, 0);
  return cat(u32s(object, (size << 16) | opcode), ...body);
}

type ScriptedLink = Link & { sent: Uint8Array[]; bufferedAmount: number; cb: LinkCallbacks | null };
function scriptedLink(): ScriptedLink {
  const link: ScriptedLink = {
    sent: [], bufferedAmount: 0, cb: null,
    start: (cb) => { link.cb = cb; },
    send: (bytes) => { link.sent.push(bytes); },
  };
  return link;
}

// wl_registry.global events the engine sent to `conn`
function globals(link: ScriptedLink, conn: number) {
  const found: Record<string, { name: number; version: number }> = {};
  for (const bytes of link.sent) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let off = 0; off < bytes.length;) {
      if (bytes[off] === 0x0b) { off += 9; continue; } // ACK
      if (bytes[off] !== 0x01) break;
      const c = dv.getUint32(off + 1, true), len = dv.getUint32(off + 5, true);
      for (let m = off + 9; c === conn && m < off + 9 + len;) {
        const obj = dv.getUint32(m, true), word = dv.getUint32(m + 4, true);
        if (obj === REG && (word & 0xffff) === 0) {
          const name = dv.getUint32(m + 8, true), slen = dv.getUint32(m + 12, true);
          const iface = new TextDecoder().decode(bytes.subarray(m + 16, m + 16 + slen - 1));
          found[iface] = { name, version: dv.getUint32(m + 16 + ((slen + 3) & ~3), true) };
        }
        m += word >>> 16;
      }
      off += 9 + len;
    }
  }
  return found;
}

// --- the headless under test, its engine spied on ---------------------------
// engine calls with the time argument dropped, e.g. ['pointerMotion', conn, x, y];
// a motion's relative part goes to `rels` instead, as [dx, dy]
type Call = [string, ...unknown[]];
const TIMED: Record<string, number> = { pointerMotion: 1, pointerButton: 1, pointerAxis: 1, key: 1, dragMotion: 2 };
function spy(engine: Engine, rels: number[][]): Call[] {
  const calls: Call[] = [];
  const e = engine as unknown as Record<string, (...a: unknown[]) => void>;
  for (const name of ['pointerEnter', 'pointerLeave', 'pointerMotion', 'pointerButton', 'pointerAxis',
    'keyboardEnter', 'keyboardLeave', 'key', 'textInputCommit', 'popupDismiss', 'requestResize',
    'dragMotion', 'dragDrop', 'dragCancel', 'pointerLockGranted', 'pointerLockLost', 'tick',
    'setFullscreen', 'setMaximized', 'setMinimized']) {
    const orig = e[name];
    e[name] = (...args) => {
      const shown = [...args];
      if (name === 'pointerMotion') {
        const r = shown.splice(4, 1)[0] as { dx: number; dy: number } | undefined;
        if (r) rels.push([r.dx, r.dy]);
      }
      if (name in TIMED) shown.splice(TIMED[name], 1);
      calls.push([name, ...shown]);
      orig(...args);
    };
  }
  return calls;
}

async function setup(opts: Partial<HeadlessOptions> = {}) {
  const link = scriptedLink();
  const events: Event[] = [];
  const hl: Headless = await createHeadless({
    link, frameInterval: 0, width: 200, height: 150,
    onEvent: (ev) => { if (ev.type !== 'log') events.push(ev); },
    ...opts,
  });
  const rels: number[][] = [];
  const calls = spy(hl.engine, rels);
  link.cb!.onOpen();
  const deliver = (...frames: Uint8Array[]) => link.cb!.onMessage(cat(...frames).buffer);
  return { hl, link, events, calls, rels, deliver };
}
type Ctx = Awaited<ReturnType<typeof setup>>;

// object ids every scripted client uses
const REG = 2, COMP = 3, SUBC = 4, WM = 5, SEAT = 6, DDM = 7, PTR = 8, KBD = 9, SHM = 10;

// A wayland client on `conn`: registry, the globals bound, a seat with
// pointer + keyboard. Surfaces get ids from 20 up.
function client(ctx: Ctx, conn: number) {
  ctx.deliver(connOpen(conn), wire(conn, msg(1, 1, REG)));
  const g = globals(ctx.link, conn);
  const bind = (iface: string, version: number, id: number) => msg(REG, 0, g[iface].name, iface, version, id);
  ctx.deliver(wire(conn, cat(
    bind('wl_compositor', 4, COMP), bind('wl_subcompositor', 1, SUBC), bind('xdg_wm_base', 1, WM),
    bind('wl_seat', 5, SEAT), bind('wl_data_device_manager', 3, DDM), bind('wl_shm', 1, SHM),
    msg(SEAT, 0, PTR), msg(SEAT, 1, KBD),
  )));
  let next = 20;
  const send = (...m: Uint8Array[]) => ctx.deliver(wire(conn, cat(...m)));
  // a solid w×h RGBA block, damaged whole
  const solid = (w: number, h: number, rgba: number[]) =>
    new Uint8Array(w * h * 4).map((_, i) => rgba[i % 4]);
  const paint = (surface: number, w: number, h: number, rgba: number[]) =>
    ctx.deliver(buffer(conn, surface, w, h, [[0, 0, w, h]], solid(w, h, rgba)));
  return {
    conn, send, paint,
    /** xdg toplevel: { surface, xdg, toplevel } */
    toplevel(title: string) {
      const surface = next++, xdg = next++, toplevel = next++;
      send(msg(COMP, 0, surface), msg(WM, 2, xdg, surface), msg(xdg, 1, toplevel), msg(toplevel, 2, title), msg(surface, 6));
      return { surface, xdg, toplevel };
    },
    subsurface(parent: number, x: number, y: number) {
      const surface = next++, sub = next++;
      send(msg(COMP, 0, surface), msg(SUBC, 1, sub, surface, parent), msg(sub, 1, x, y));
      return surface;
    },
    /** a popup of `parentXdg` whose top-left lands at (x, y) of the parent */
    popup(parentXdg: number, x: number, y: number, w: number, h: number) {
      const surface = next++, xdg = next++, popup = next++, pos = next++;
      send(msg(WM, 1, pos), msg(pos, 1, w, h), msg(pos, 2, x, y, 1, 1), msg(pos, 3, 5), msg(pos, 4, 8),
        msg(COMP, 0, surface), msg(WM, 2, xdg, surface), msg(xdg, 2, popup, parentXdg, pos));
      return { surface, xdg, popup };
    },
    bare() {
      const surface = next++;
      send(msg(COMP, 0, surface));
      return surface;
    },
    id: () => next++,
  };
}

const px = (img: { width: number; data: Uint8Array }, x: number, y: number) =>
  [...img.data.subarray((y * img.width + x) * 4, (y * img.width + x) * 4 + 4)];
const without = (calls: Call[], ...names: string[]) => calls.filter((c) => !names.includes(c[0]));

test('scene: windows cascade, take focus on map, and go away with their surface or conn (no leave; focus passes on)', async () => {
  let changes = 0;
  const ctx = await setup({ onWindowsChange: () => { changes++; } });
  const { hl, calls } = ctx;
  const a = client(ctx, 1);
  const ta = a.toplevel('first');
  assert.equal(hl.windows().length, 0, 'no window before the first commit');
  a.paint(ta.surface, 40, 30, [255, 0, 0, 255]);
  const [w1] = hl.windows();
  assert.deepEqual({ ...w1 }, {
    key: `c1s${ta.surface}`, conn: 1, surface: ta.surface, title: 'first',
    x: 24, y: 48, width: 40, height: 30, originX: 24, originY: 48, z: w1.z, maximized: false, fullscreen: false, minimized: false, focused: true,
  });
  assert.deepEqual(calls, [['keyboardEnter', 1, ta.surface]]);
  assert.ok(changes > 0, 'onWindowsChange');

  const b = client(ctx, 2);
  const tb = b.toplevel('second');
  b.paint(tb.surface, 50, 20, [0, 255, 0, 255]);
  const w2 = hl.window(`c2s${tb.surface}`)!;
  assert.deepEqual([w2.x, w2.y], [64, 84], 'cascaded');
  assert.ok(w2.z > w1.z, 'a new window stacks on top');
  assert.deepEqual(calls.slice(1), [['keyboardLeave', 1], ['keyboardEnter', 2, tb.surface]], 'leave the old, then enter the new');
  assert.equal(hl.focused()!.key, w2.key);

  // the focused toplevel closes (role objects, then the surface): it gets
  // its leave while the surface can still be named, and the window left
  // takes focus
  calls.length = 0;
  b.send(msg(tb.toplevel, 0), msg(tb.xdg, 0), msg(tb.surface, 0));
  assert.deepEqual(hl.windows().map((w) => w.key), [w1.key]);
  assert.deepEqual(calls, [['keyboardLeave', 2], ['keyboardEnter', 1, ta.surface]]);
  assert.equal(hl.focused()!.key, w1.key);

  // the focused conn hangs up, nothing is left: focus is just gone
  calls.length = 0;
  ctx.deliver(connClose(1));
  assert.deepEqual(hl.windows(), []);
  assert.deepEqual(hl.surfaces(), []);
  assert.equal(hl.focused(), undefined);
  assert.deepEqual(calls, []);
  hl.dispose();
});

test('pixels: rgba packed rects, bgrx (alpha forced) and bgra (alpha kept) composite into the screenshot', async () => {
  const W = 4, H = 2, STRIDE = 24;
  const mem = new Uint8Array(STRIDE * H);
  const reads: number[] = [];
  const buffers: HandleSource<Uint8Array> = {
    open: (h: BufferHandle) => { assert.equal(h.kind, 'kwshm'); return mem; },
    read: (m, offset, dst) => { reads.push(offset); dst.set(m.subarray(offset, offset + dst.length)); },
    close: () => {},
  };
  const ctx = await setup({ buffers, background: [0, 0, 255, 255] });
  const { hl } = ctx;
  const a = client(ctx, 1);
  const t = a.toplevel('px');

  // rgba: two rects packed back to back, onto a fresh (transparent) buffer
  ctx.deliver(buffer(1, t.surface, W, H, [[0, 0, 2, 1], [3, 1, 1, 1]], new Uint8Array([
    10, 20, 30, 255, 40, 50, 60, 255, // rect 0: (0,0), (1,0)
    70, 80, 90, 255,                  // rect 1: (3,1)
  ])));
  const win = hl.windows()[0];
  let shot = hl.screenshot();
  assert.deepEqual([shot.width, shot.height], [200, 150]);
  assert.deepEqual(px(shot, win.x, win.y), [10, 20, 30, 255]);
  assert.deepEqual(px(shot, win.x + 1, win.y), [40, 50, 60, 255]);
  assert.deepEqual(px(shot, win.x + 3, win.y + 1), [70, 80, 90, 255]);
  assert.deepEqual(px(shot, win.x + 2, win.y), [0, 0, 255, 255], 'undamaged pixels are transparent: background shows');
  assert.deepEqual(px(shot, 0, 0), [0, 0, 255, 255]);
  assert.deepEqual([...hl.surfacePixels(1, t.surface)!.data.subarray(0, 8)], [10, 20, 30, 255, 40, 50, 60, 255]);

  // bgrx through the buffer source: B, G, R, X rows `STRIDE` apart
  const POOL = a.id(), BUF = a.id();
  ctx.deliver(fdmsg(1, 1, msg(SHM, 0, POOL, 4096)), wire(1, msg(POOL, 0, BUF, 0, W, H, STRIDE, 1)));
  mem.set([1, 2, 3, 0], 1 * STRIDE + 2 * 4);   // (2,1): X = 0 → opaque
  ctx.deliver(
    wire(1, cat(msg(t.surface, 1, BUF, 0, 0), msg(t.surface, 9, 0, 0, W, H), msg(t.surface, 6))),
    handleOpen(1, 5, 77, mem.length),
    shmCommit(1, t.surface, 1, [5, 0, W, H, STRIDE, 1], [[2, 1, 1, 1]]),
  );
  assert.ok(reads.length > 0, 'read through the source');
  shot = hl.screenshot();
  assert.deepEqual(px(shot, win.x + 2, win.y + 1), [3, 2, 1, 255]);
  assert.deepEqual(px(shot, win.x, win.y), [10, 20, 30, 255], 'outside the damage the old pixels stay');

  // bgra: alpha passes through and blends over what is below (straight
  // alpha, as stacked canvases do): a = 0 → background, 128 → half
  mem.set([0, 0, 200, 0], 0);             // (0,0) red, a 0
  mem.set([0, 200, 0, 128], 4);           // (1,0) green, a 128
  ctx.deliver(
    wire(1, cat(msg(t.surface, 1, BUF, 0, 0), msg(t.surface, 9, 0, 0, W, H), msg(t.surface, 6))),
    shmCommit(1, t.surface, 2, [5, 0, W, H, STRIDE, 0], [[0, 0, 2, 1]]),
  );
  assert.deepEqual([...hl.surfacePixels(1, t.surface)!.data.subarray(0, 8)], [200, 0, 0, 0, 0, 200, 0, 128]);
  shot = hl.screenshot();
  assert.deepEqual(px(shot, win.x, win.y), [0, 0, 255, 255]);
  assert.deepEqual(px(shot, win.x + 1, win.y), [0, 100, 127, 255]);
  hl.dispose();
});

// COMMIT kind 2 (virtgpu): resource, w, h, fourcc, flags, offset, stride, u64 modifier
const virtgpuCommit = (conn: number, surface: number, serial: number, resource: number, w: number, h: number, rects: number[][]) =>
  frame(0x0a, u32s(conn, surface, serial, rects.length, 2, 36, resource, w, h, 0x34324258, 0, 0, w * 4, 0xffffffff, 0x00ffffff),
    u32s(...rects.flat()));

test('gpu: a resolver\'s RgbaImage lands in the scene; the ref is on the surface; without a resolver the surface maps empty', async () => {
  const W = 4, H = 2;
  const img = { width: W, height: H, data: new Uint8Array(W * H * 4).map((_, i) => (i % 4 === 3 ? 255 : 10 * (i >> 2) + (i % 4))) };
  const resolved: number[] = [];
  const released: unknown[] = [];
  const ctx = await setup({
    gpu: { resolve: (ref) => { resolved.push(ref.resource); return ref.resource === 7 ? img : null; }, release: (i) => { released.push(i); } },
    background: [0, 0, 255, 255],
  });
  const { hl, link } = ctx;
  const a = client(ctx, 1);
  const t = a.toplevel('gpu');
  ctx.deliver(wire(1, cat(msg(t.surface, 9, 0, 0, W, H), msg(t.surface, 6))), virtgpuCommit(1, t.surface, 1, 7, W, H, [[0, 0, W, H]]));
  assert.deepEqual(resolved, [7]);
  assert.deepEqual(released, [img]);
  const [win] = hl.windows();
  assert.deepEqual([win.width, win.height], [W, H]);
  const [s] = hl.surfaces();
  assert.deepEqual(s.gpu, { kind: 'virtgpu', resource: 7, width: W, height: H, format: 0x34324258, flags: 0, offset: 0, stride: W * 4, modifier: 0x00ffffffffffffffn });
  const shot = hl.screenshot();
  assert.deepEqual(px(shot, win.x + 1, win.y + 1), [50, 51, 52, 255]);
  // ACKed after the dispatch
  assert.ok(link.sent.some((b) => b[0] === 0x0b && new DataView(b.buffer, b.byteOffset).getUint32(5, true) === 1));

  // resource 8 resolves to null: nothing changes, the ref still updates
  ctx.deliver(wire(1, cat(msg(t.surface, 9, 0, 0, W, H), msg(t.surface, 6))), virtgpuCommit(1, t.surface, 2, 8, W, H, [[0, 0, W, H]]));
  assert.equal(hl.surfaces()[0].gpu!.resource, 8);
  assert.deepEqual(px(hl.screenshot(), win.x + 1, win.y + 1), [50, 51, 52, 255]);
  // a pixel commit: no gpu ref any more
  a.paint(t.surface, W, H, [1, 2, 3, 255]);
  assert.equal(hl.surfaces()[0].gpu, undefined);
  hl.dispose();

  // no resolver: an error event, the window maps at its size, transparent
  const bare = await setup({ background: [0, 0, 255, 255] });
  const b = client(bare, 1);
  const tb = b.toplevel('gpu');
  bare.deliver(wire(1, cat(msg(tb.surface, 9, 0, 0, W, H), msg(tb.surface, 6))), virtgpuCommit(1, tb.surface, 1, 7, W, H, [[0, 0, W, H]]));
  assert.ok(bare.events.some((e) => e.type === 'error' && /no gpu source/.test(e.detail)));
  const [wb] = bare.hl.windows();
  assert.deepEqual([wb.width, wb.height], [W, H]);
  assert.deepEqual(px(bare.hl.screenshot(), wb.x, wb.y), [0, 0, 255, 255]);
  bare.hl.dispose();
});

test('screenshot at scale 2: buffers at 2× copy 1:1, a 1× buffer is upscaled; per-window shots crop to the window', async () => {
  const ctx = await setup({ scale: 2, width: 100, height: 80 });
  const { hl } = ctx;
  const a = client(ctx, 1);
  const t = a.toplevel('hidpi');
  a.send(msg(t.surface, 8, 2)); // set_buffer_scale 2: a 20×10 buffer is 10×5 logical
  const pixels = new Uint8Array(20 * 10 * 4).map((_, i) => (i % 4 === 3 ? 255 : i % 4 === 0 ? (i / 4) % 20 : 0));
  ctx.deliver(buffer(1, t.surface, 20, 10, [[0, 0, 20, 10]], pixels));
  // a subsurface above the toplevel with a 1× buffer: 4×2 logical → 8×4 device px
  const sub = a.subsurface(t.surface, 0, -2);
  a.paint(sub, 4, 2, [9, 9, 9, 255]);
  const win = hl.windows()[0];
  assert.deepEqual([win.width, win.height], [10, 7], 'the box holds the toplevel and the subsurface above it');
  assert.deepEqual([win.originX - win.x, win.originY - win.y], [0, 2], 'the toplevel sits below the subsurface in it');
  const ox = win.originX * 2, oy = win.originY * 2; // the toplevel's origin, device px

  const shot = hl.screenshot();
  assert.deepEqual([shot.width, shot.height], [200, 160]);
  for (const x of [0, 7, 19]) assert.equal(px(shot, ox + x, oy + 5)[0], x, `buffer column ${x} lands 1:1`);
  assert.deepEqual(px(shot, ox + 7, oy - 4), [9, 9, 9, 255]);
  assert.deepEqual(px(shot, ox + 8, oy - 4), [0, 0, 0, 255], 'past the subsurface, above the toplevel: background');

  const one = hl.screenshot({ window: win, scale: 1 });
  assert.deepEqual([one.width, one.height], [10, 7], 'the toplevel plus the subsurface above it');
  assert.deepEqual(px(one, 0, 0), [9, 9, 9, 255]);
  assert.deepEqual(px(one, 9, 0), [0, 0, 0, 0], 'transparent outside every surface');
  assert.equal(px(one, 3, 2)[3], 255);
  hl.dispose();
});

// toplevel A (conn 1) at (24,48) 40×30 with a subsurface at (0,-10) 40×10 and
// a popup at (10,10) 20×20; toplevel B (conn 2) at (64,84) 50×20. A sets no
// window geometry, so its box is toplevel + subsurface: 40×40 at (24,38).
function desk(ctx: Ctx, { popup = true } = {}) {
  const a = client(ctx, 1);
  const ta = a.toplevel('A');
  a.paint(ta.surface, 40, 30, [255, 0, 0, 255]);
  const sub = a.subsurface(ta.surface, 0, -10);
  a.paint(sub, 40, 10, [0, 255, 0, 255]);
  // the box grew upwards around the subsurface and stayed where it was
  // placed, which pushed the toplevel down: put the toplevel back at (24,48)
  const wa = ctx.hl.window(`c1s${ta.surface}`)!;
  assert.deepEqual([wa.x, wa.y, wa.width, wa.height, wa.originX, wa.originY], [24, 48, 40, 40, 24, 58]);
  ctx.hl.move(wa, 24, 38);
  const pop = popup ? a.popup(ta.xdg, 10, 10, 20, 20) : null;
  if (pop) a.paint(pop.surface, 20, 20, [255, 255, 0, 255]);
  const b = client(ctx, 2);
  const tb = b.toplevel('B');
  b.paint(tb.surface, 50, 20, [0, 0, 255, 255]);
  return { a, ta, sub, pop, b, tb };
}

test('hit-testing: popups above subsurfaces above their toplevel, windows by z; enter/leave synthesised as the target changes', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const { a, ta, sub, pop, tb } = desk(ctx);
  const at = (x: number, y: number) => { const h = hl.surfaceAt(x, y); return h && [h.conn, h.surface, h.role, h.x, h.y]; };
  assert.deepEqual(at(30, 60), [1, ta.surface, 1, 6, 12]);
  assert.deepEqual(at(40, 65), [1, pop!.surface, 4, 6, 7]);
  assert.deepEqual(at(30, 40), [1, sub, 2, 6, 2]);
  assert.deepEqual(at(10, 10), null);

  calls.length = 0;
  hl.pointerMove(30, 60);
  hl.pointerMove(31, 60);
  hl.pointerMove(30, 40);
  hl.pointerMove(40, 65);
  hl.pointerMove(5, 5);
  hl.pointerMove(6, 5);
  assert.deepEqual(calls, [
    ['pointerEnter', 1, ta.surface, 6, 12],
    ['pointerMotion', 1, 7, 12],
    ['pointerLeave', 1], ['pointerEnter', 1, sub, 6, 2],
    ['pointerLeave', 1], ['pointerEnter', 1, pop!.surface, 6, 7],
    ['pointerLeave', 1],
  ]);

  // overlapping windows: the higher z wins, raise changes it
  hl.move(`c2s${tb.surface}`, 30, 50);
  assert.equal(hl.surfaceAt(35, 55)!.conn, 2);
  hl.raise(`c1s${ta.surface}`);
  assert.equal(hl.surfaceAt(35, 55)!.conn, 1);

  // late roles: a buffer committed before set_cursor never hits or shows,
  // nor does a popup whose role died while its surface lives on
  const cur = a.bare();
  hl.move(`c2s${tb.surface}`, 120, 100);
  const before = hl.screenshot();
  a.paint(cur, 8, 8, [1, 1, 1, 255]);
  a.send(msg(PTR, 0, 0, cur, 0, 0));
  assert.equal(hl.surfaces().find((s) => s.surface === cur)!.role, 3);
  assert.deepEqual(hl.screenshot().data, before.data, 'the cursor buffer is never drawn');
  a.send(msg(pop!.popup, 0), msg(pop!.xdg, 0));
  assert.equal(hl.surfaces().find((s) => s.surface === pop!.surface)!.role, 0, 'the surface lives, role-less');
  assert.deepEqual(at(40, 65), [1, ta.surface, 1, 16, 17]);
  assert.deepEqual(px(hl.screenshot(), 40, 65), [255, 0, 0, 255], 'the toplevel shows where the popup was');
  hl.dispose();
});

test('focus handover: when the focused window closes, unmaps or hangs up, the topmost window left takes focus', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const [a, b, c] = [client(ctx, 1), client(ctx, 2), client(ctx, 3)];
  const open = (cl: typeof a, title: string) => {
    const t = cl.toplevel(title);
    cl.paint(t.surface, 40, 30, [9, 9, 9, 255]);
    return t;
  };
  const ta = open(a, 'A'), tb = open(b, 'B'), tc = open(c, 'C'), tc2 = open(c, 'C2');
  const key = (conn: number, t: { surface: number }) => `c${conn}s${t.surface}`;
  assert.equal(hl.focused()!.title, 'C2', 'the last one mapped');

  // stacking decides, not creation order: A is raised above B and C
  hl.raise(key(1, ta));
  hl.raise(key(3, tc2));
  calls.length = 0;
  c.send(msg(tc2.surface, 0)); // C2's surface is destroyed outright
  assert.deepEqual(calls, [['keyboardEnter', 1, ta.surface]], 'A was next in the stack; the dead surface gets no leave');
  assert.equal(hl.focused()!.title, 'A');

  // a window that is not focused closing changes nothing
  calls.length = 0;
  b.send(msg(tb.toplevel, 0), msg(tb.xdg, 0), msg(tb.surface, 0));
  assert.deepEqual(calls, []);
  assert.equal(hl.focused()!.title, 'A');

  // unmapped with its wl_surface alive (only the xdg role objects go): the
  // surface can be named, so it gets its leave before C takes over
  calls.length = 0;
  a.send(msg(ta.toplevel, 0), msg(ta.xdg, 0));
  assert.deepEqual(calls, [['keyboardLeave', 1], ['keyboardEnter', 3, tc.surface]]);
  assert.equal(hl.focused()!.title, 'C');
  assert.deepEqual(hl.windows().map((w) => w.title), ['C']);

  // a conn hanging up hands on the same way; with no window left, nothing
  const td = open(a, 'D');
  assert.equal(hl.focused()!.title, 'D', 'focus on map');
  calls.length = 0;
  ctx.deliver(connClose(1));
  assert.deepEqual(calls, [['keyboardEnter', 3, tc.surface]]);
  calls.length = 0;
  ctx.deliver(connClose(3));
  assert.deepEqual(calls, []);
  assert.equal(hl.focused(), undefined);
  void td;
  hl.dispose();
});

test('click focuses and raises; a held button keeps the pointer on the pressed surface; scroll goes where the pointer is', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const { a, ta, tb } = desk(ctx, { popup: false });
  assert.equal(hl.focused()!.conn, 2, 'B mapped last');
  calls.length = 0;
  hl.click(30, 60);
  assert.deepEqual(calls, [
    ['pointerEnter', 1, ta.surface, 6, 12],
    ['keyboardLeave', 2], ['keyboardEnter', 1, ta.surface],
    ['pointerButton', 1, 0x110, true], ['pointerButton', 1, 0x110, false],
  ]);
  const [wa, wb] = hl.windows();
  assert.ok(wa.z > wb.z && wa.focused && !wb.focused);

  // implicit grab: motion stays with A in its local px; on release the
  // pointer moves on to what is under it
  calls.length = 0;
  hl.pointerDown('right');
  hl.pointerMove(70, 90); // over B
  hl.pointerUp('right');
  assert.deepEqual(calls, [
    ['pointerButton', 1, 0x111, true],
    ['pointerMotion', 1, 46, 42],
    ['pointerButton', 1, 0x111, false],
    ['pointerLeave', 1], ['pointerEnter', 2, tb.surface, 6, 6],
  ]);

  calls.length = 0;
  hl.scroll(1);
  hl.scroll(0, -0.5);
  assert.deepEqual(calls, [['pointerAxis', 2, 0, 10, 120], ['pointerAxis', 2, 1, -5, -60]]);

  // a popup of the pressed client mapping (a popup grab) ends the implicit
  // grab: its surfaces get the pointer by position, the release lands on it
  hl.pointerMove(30, 60);
  hl.pointerDown();
  const pop = a.popup(ta.xdg, 10, 10, 20, 20);
  a.paint(pop.surface, 20, 20, [255, 255, 0, 255]);
  calls.length = 0;
  hl.pointerMove(40, 65);
  hl.pointerUp();
  assert.deepEqual(without(calls, 'popupDismiss'), [
    ['pointerLeave', 1], ['pointerEnter', 1, pop.surface, 6, 7], ['pointerButton', 1, 0x110, false],
  ]);
  hl.dispose();
});

test('popup dismiss: a press on the popup keeps it, a press anywhere else dismisses it once', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const { pop } = desk(ctx);
  calls.length = 0;
  hl.click(40, 65); // on the popup
  assert.ok(!calls.some((c) => c[0] === 'popupDismiss'));
  hl.click(30, 50); // the toplevel, outside the popup
  assert.deepEqual(calls.filter((c) => c[0] === 'popupDismiss'), [['popupDismiss', 1, pop!.surface]]);
  hl.click(5, 5); // nothing: already dismissed
  hl.click(40, 65);
  assert.equal(calls.filter((c) => c[0] === 'popupDismiss').length, 1);
  hl.dispose();
});

test('drag-start: cancelled at once with no button held (the core would wedge the seat); driven by the pointer while one is', async () => {
  const ctx = await setup();
  const { hl, calls, events } = ctx;
  const { a, ta, tb } = desk(ctx, { popup: false });
  const DS = a.id(), DD = a.id();
  a.send(msg(DDM, 0, DS), msg(DDM, 1, DD, SEAT), msg(DS, 0, 'text/plain'));
  calls.length = 0;
  a.send(msg(DD, 0, DS, ta.surface, 0, 0)); // start_drag, nothing held
  assert.deepEqual(calls, [['dragCancel']]);
  assert.deepEqual(events.slice(-2).map((e) => e.type), ['drag-start', 'drag-end']);

  // with the button held: the drag owns the pointer until release; the icon
  // (committed before start_drag) follows the pointer
  const icon = a.bare();
  a.paint(icon, 4, 4, [7, 7, 7, 255]);
  hl.pointerMove(30, 60);
  hl.pointerDown();
  calls.length = 0;
  a.send(msg(DD, 0, DS, ta.surface, icon, 0));
  assert.deepEqual(calls, [['pointerLeave', 1]]);
  hl.pointerMove(70, 90);
  assert.deepEqual(calls.at(-1), ['dragMotion', 2, tb.surface, 6, 6]);
  assert.deepEqual(px(hl.screenshot(), 75, 95), [7, 7, 7, 255]);
  calls.length = 0;
  hl.pointerUp();
  assert.deepEqual(calls, [['dragMotion', 2, tb.surface, 6, 6], ['dragDrop'], ['pointerEnter', 2, tb.surface, 6, 6]]);
  assert.equal(events.at(-1)!.type, 'drag-end');
  assert.equal(hl.surfaces().find((s) => s.surface === icon)!.role, 0);
  assert.deepEqual(px(hl.screenshot(), 75, 95), [0, 0, 255, 255], 'the icon is gone with the drag');

  // Escape cancels a drag in progress
  hl.pointerMove(30, 60);
  hl.pointerDown();
  a.send(msg(DD, 0, DS, ta.surface, 0, 0));
  calls.length = 0;
  hl.keyDown('Escape');
  assert.deepEqual(calls, [['dragCancel']]);
  hl.pointerUp();
  hl.dispose();
});

test('move/resize requests: a scripted grab while the button is held, nothing once released; maximize snaps and restores', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const { a, ta } = desk(ctx, { popup: false });
  const key = `c1s${ta.surface}`;
  calls.length = 0;
  a.send(msg(ta.toplevel, 5, SEAT, 0)); // move, no button held
  assert.deepEqual(calls, []);

  hl.pointerMove(30, 60);
  hl.pointerDown();
  calls.length = 0;
  a.send(msg(ta.toplevel, 5, SEAT, 0));
  assert.deepEqual(calls, [['pointerLeave', 1]]);
  hl.pointerMove(50, 70);
  assert.deepEqual([hl.window(key)!.x, hl.window(key)!.y], [44, 48]);
  hl.pointerUp();
  assert.deepEqual(calls.slice(1), [['pointerEnter', 1, ta.surface, 6, 12]], 'the release belongs to the grab');

  hl.pointerDown();
  a.send(msg(ta.toplevel, 6, SEAT, 0, 10)); // resize bottom-right
  calls.length = 0;
  hl.pointerMove(100, 110);
  hl.pointerUp();
  // the size asked for is the box's (40×40, subsurface included) plus the drag
  assert.deepEqual(calls.filter((c) => c[0] === 'requestResize'), [['requestResize', 1, ta.surface, 90, 80], ['requestResize', 1, ta.surface, 90, 80]]);

  a.send(msg(ta.toplevel, 9)); // set_maximized
  assert.deepEqual([hl.window(key)!.x, hl.window(key)!.y, hl.window(key)!.maximized], [0, 0, true]);
  a.send(msg(ta.toplevel, 10)); // unset_maximized
  assert.deepEqual([hl.window(key)!.x, hl.window(key)!.y, hl.window(key)!.maximized], [44, 48, false]);
  hl.dispose();
});

// xdg_toplevel requests: set_maximized 9, unset_maximized 10,
// set_fullscreen 11 (output), unset_fullscreen 12, set_minimized 13
test('fullscreen: the box fills the output, the geometry centred on black, raised and focused; nothing below shows or takes the pointer; back to its place', async () => {
  const ctx = await setup({ background: [9, 9, 9, 255] });
  const { hl, calls, events } = ctx;
  const a = client(ctx, 1);
  const ta = a.toplevel('game');
  a.paint(ta.surface, 40, 30, [255, 0, 0, 255]);
  const b = client(ctx, 2);
  const tb = b.toplevel('other');
  b.paint(tb.surface, 50, 20, [0, 255, 0, 255]);
  const ka = `c1s${ta.surface}`, kb = `c2s${tb.surface}`;
  assert.equal(hl.focused()!.key, kb);
  assert.deepEqual(px(hl.screenshot(), 70, 90), [0, 255, 0, 255]);

  calls.length = 0;
  a.send(msg(ta.toplevel, 11, 0)); // set_fullscreen(NULL)
  assert.ok(events.some((e) => e.type === 'fullscreen' && e.fullscreen && e.conn === 1));
  let w = hl.window(ka)!;
  // the app hasn't redrawn yet: its 40×30 sits centred on black
  assert.deepEqual([w.x, w.y, w.width, w.height, w.originX, w.originY, w.fullscreen], [0, 0, 200, 150, 80, 60, true]);
  assert.ok(w.z > hl.window(kb)!.z && w.focused, 'on top, and focused');
  assert.deepEqual(calls, [['keyboardLeave', 2], ['keyboardEnter', 1, ta.surface]]);
  let shot = hl.screenshot();
  assert.deepEqual(px(shot, 70, 90), [0, 0, 0, 255], 'the other window is covered by the border fill');
  assert.deepEqual(px(shot, 0, 0), [0, 0, 0, 255]);
  assert.deepEqual(px(shot, 80, 60), [255, 0, 0, 255]);
  assert.equal(hl.surfaceAt(70, 90), null, 'the backdrop takes the pointer');
  assert.equal(hl.surfaceAt(85, 65)!.surface, ta.surface);
  // a move request is ignored while fullscreen (the core drops it)
  hl.pointerMove(85, 65);
  hl.pointerDown();
  calls.length = 0;
  a.send(msg(ta.toplevel, 5, SEAT, 0));
  assert.deepEqual(calls, []);
  hl.pointerUp();

  // the app obeys: a 200×150 buffer fills it
  a.paint(ta.surface, 200, 150, [255, 0, 0, 255]);
  w = hl.window(ka)!;
  assert.deepEqual([w.originX, w.originY], [0, 0]);
  // a larger output: the box follows it
  hl.setOutput(240, 160);
  assert.deepEqual([hl.window(ka)!.width, hl.window(ka)!.height], [240, 160]);
  hl.setOutput(200, 150);

  // back: the old place, the other window shows again
  a.send(msg(ta.toplevel, 12));
  a.paint(ta.surface, 40, 30, [255, 0, 0, 255]);
  w = hl.window(ka)!;
  assert.deepEqual([w.x, w.y, w.width, w.height, w.fullscreen], [24, 48, 40, 30, false]);
  assert.deepEqual(px(hl.screenshot(), 70, 90), [0, 255, 0, 255]);

  // maximized under fullscreen: back from fullscreen it stays at the origin
  a.send(msg(ta.toplevel, 9), msg(ta.toplevel, 11, 0), msg(ta.toplevel, 12));
  w = hl.window(ka)!;
  assert.deepEqual([w.x, w.y, w.maximized, w.fullscreen], [0, 0, true, false]);
  a.send(msg(ta.toplevel, 10));
  assert.deepEqual([hl.window(ka)!.x, hl.window(ka)!.y], [24, 48]);
  hl.dispose();
});

test('fullscreen before the first commit: the window maps fullscreen, on top', async () => {
  const ctx = await setup();
  const { hl } = ctx;
  const b = client(ctx, 2);
  const tb = b.toplevel('other');
  b.paint(tb.surface, 50, 20, [0, 255, 0, 255]);
  const a = client(ctx, 1);
  const surface = a.id(), xdg = a.id(), toplevel = a.id();
  a.send(msg(COMP, 0, surface), msg(WM, 2, xdg, surface), msg(xdg, 1, toplevel), msg(toplevel, 11, 0), msg(surface, 6));
  a.paint(surface, 200, 150, [255, 0, 0, 255]);
  const w = hl.window(`c1s${surface}`)!;
  assert.deepEqual([w.x, w.y, w.width, w.height, w.originX, w.originY, w.fullscreen, w.focused], [0, 0, 200, 150, 0, 0, true, true]);
  assert.ok(w.z > hl.window(`c2s${tb.surface}`)!.z);
  hl.dispose();
});

test('window bindings: Alt+F11 / Alt+F10 / Alt+F9 on the focused window, the key swallowed; not with another modifier', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const a = client(ctx, 1);
  const ta = a.toplevel('app');
  a.paint(ta.surface, 40, 30, [255, 0, 0, 255]);
  const key = `c1s${ta.surface}`;
  calls.length = 0;
  hl.keyDown('AltLeft');
  hl.keyDown('F11');
  hl.keyUp('F11');
  assert.deepEqual(calls, [['key', 1, 56, true], ['setFullscreen', 1, ta.surface, true]], 'Alt reaches the app, F11 does not');
  assert.equal(hl.window(key)!.fullscreen, true);
  hl.press('F11'); // Alt still held: toggles back
  assert.equal(hl.window(key)!.fullscreen, false);
  hl.press('F10');
  assert.equal(hl.window(key)!.maximized, true);
  hl.press('F10');
  assert.equal(hl.window(key)!.maximized, false);
  hl.keyUp('AltLeft');
  calls.length = 0;
  hl.press('ControlLeft', 'AltLeft', 'F11'); // another modifier: the app's
  assert.deepEqual(calls.filter((c) => c[0] !== 'key'), []);
  assert.ok(calls.some((c) => c[0] === 'key' && c[2] === 87));
  hl.press('AltLeft', 'F9');
  assert.equal(hl.window(key)!.minimized, true);
  hl.dispose();
});

test('minimize: hidden but listed, keyboard and pointer pass on; focus() refuses it; raise()/restore() bring it back raised and focused', async () => {
  const ctx = await setup({ background: [9, 9, 9, 255] });
  const { hl, calls, events } = ctx;
  const a = client(ctx, 1);
  const ta = a.toplevel('below');
  a.paint(ta.surface, 40, 30, [255, 0, 0, 255]);
  const b = client(ctx, 2);
  const tb = b.toplevel('above');
  b.paint(tb.surface, 50, 20, [0, 255, 0, 255]);
  const ka = `c1s${ta.surface}`, kb = `c2s${tb.surface}`;
  hl.move(ka, 60, 80); // under b, which sits at 64,84
  hl.pointerMove(70, 90);
  assert.equal(hl.surfaceAt(70, 90)!.conn, 2);

  calls.length = 0;
  b.send(msg(tb.toplevel, 13)); // set_minimized
  assert.ok(events.some((e) => e.type === 'minimize' && e.minimized && e.conn === 2));
  assert.deepEqual(hl.windows().map((w) => [w.key, w.minimized]), [[ka, false], [kb, true]], 'still listed');
  assert.equal(hl.focused()!.key, ka);
  // the core sent b its leaves; a gets the keyboard and the pointer it is now under
  assert.deepEqual(calls, [['keyboardEnter', 1, ta.surface], ['pointerEnter', 1, ta.surface, 10, 10]]);
  assert.deepEqual(px(hl.screenshot(), 70, 90), [255, 0, 0, 255]);
  assert.equal(hl.surfaceAt(70, 90)!.conn, 1);
  hl.focus(kb);
  assert.equal(hl.focused()!.key, ka, 'focus() leaves a minimized window alone');

  calls.length = 0;
  hl.raise(kb); // a taskbar click restores it
  assert.equal(hl.window(kb)!.minimized, false);
  assert.ok(hl.window(kb)!.z > hl.window(ka)!.z && hl.focused()!.key === kb);
  assert.deepEqual(calls, [['setMinimized', 2, tb.surface, false], ['keyboardLeave', 1], ['keyboardEnter', 2, tb.surface],
    ['pointerLeave', 1], ['pointerEnter', 2, tb.surface, 6, 6]]);
  assert.deepEqual(px(hl.screenshot(), 70, 90), [0, 255, 0, 255]);

  // the embedder's own minimize / restore
  hl.minimize(kb);
  assert.equal(hl.window(kb)!.minimized, true);
  hl.restore(kb);
  assert.equal(hl.window(kb)!.minimized, false);
  assert.equal(hl.focused()!.key, kb);
  hl.dispose();
});

test('window geometry: the box is what set_window_geometry names; shadows hang outside it, placement and sizes follow it', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const a = client(ctx, 1);
  const t = a.toplevel('framed');
  const key = `c1s${t.surface}`;
  // a 140×90 frame inside a 160×110 buffer: 10 px of shadow all around
  a.send(msg(t.xdg, 3, 10, 10, 140, 90), msg(t.surface, 6)); // set_window_geometry, commit
  a.paint(t.surface, 160, 110, [255, 0, 0, 255]);
  const w = hl.window(key)!;
  assert.deepEqual([w.x, w.y, w.width, w.height], [24, 48, 140, 90], 'the frame is cascaded, not the shadow');
  assert.deepEqual([w.originX, w.originY], [14, 38]);
  assert.deepEqual(px(hl.screenshot(), 14, 38), [255, 0, 0, 255], 'the shadow is drawn outside the box');
  const hit = hl.surfaceAt(24, 48)!;
  assert.deepEqual([hit.surface, hit.x, hit.y], [t.surface, 10, 10], 'surface-local px count from the buffer origin');

  // a resize grab starts from the frame's size, not the buffer's
  hl.pointerMove(60, 75);
  hl.pointerDown();
  a.send(msg(t.toplevel, 6, SEAT, 0, 10)); // resize bottom-right
  calls.length = 0;
  hl.pointerMove(70, 80);
  hl.pointerUp();
  assert.deepEqual(calls.filter((c) => c[0] === 'requestResize')[0], ['requestResize', 1, t.surface, 150, 95]);

  // maximized, the box fills the output from its origin; the app drops its
  // shadow (geometry at 0,0) and the buffer lands there
  a.send(msg(t.toplevel, 9), msg(t.xdg, 3, 0, 0, 200, 150), msg(t.surface, 6));
  a.paint(t.surface, 200, 150, [0, 0, 255, 255]);
  const m = hl.window(key)!;
  assert.deepEqual([m.x, m.y, m.width, m.height, m.originX, m.originY, m.maximized], [0, 0, 200, 150, 0, 0, true]);
  // back to floating: the old place, the shadow outside it again
  a.send(msg(t.toplevel, 10), msg(t.xdg, 3, 10, 10, 140, 90), msg(t.surface, 6));
  a.paint(t.surface, 160, 110, [255, 0, 0, 255]);
  const f = hl.window(key)!;
  assert.deepEqual([f.x, f.y, f.width, f.height, f.originX, f.originY], [24, 48, 140, 90, 14, 38]);
  hl.dispose();
});

// wl_compositor.create_region 1, wl_region.add 1 / subtract 2,
// wl_surface.set_input_region 5, commit 6
function region(cl: ReturnType<typeof client>, ...ops: [op: 'add' | 'sub', x: number, y: number, w: number, h: number][]) {
  const id = cl.id();
  cl.send(msg(COMP, 1, id), ...ops.map(([op, ...r]) => msg(id, op === 'add' ? 1 : 2, ...r)));
  return id;
}

test('input regions: outside one the point falls through to what is below; a held button still keeps the pressed surface', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const a = client(ctx, 1);
  const ta = a.toplevel('A');
  a.paint(ta.surface, 100, 80, [255, 0, 0, 255]); // at (24,48)
  const sub = a.subsurface(ta.surface, 60, 60);
  a.paint(sub, 20, 20, [0, 255, 0, 255]);
  const b = client(ctx, 2);
  const tb = b.toplevel('B');
  // GTK's shape: a 60×40 frame in 10 px of shadow, input = the frame plus a
  // 2 px resize margin, set before the first buffer (and the region object
  // destroyed right away: the surface keeps its copy)
  const rb = region(b, ['add', 8, 8, 64, 44]);
  b.send(msg(tb.xdg, 3, 10, 10, 60, 40), msg(tb.surface, 5, rb), msg(rb, 0), msg(tb.surface, 6));
  b.paint(tb.surface, 80, 60, [0, 0, 255, 255]);
  hl.move(`c2s${tb.surface}`, 40, 60); // B's surface at (30,50)..(110,110), above A
  assert.deepEqual([...hl.surfaces().find((s) => s.surface === tb.surface && s.conn === 2)!.inputRegion!], [8, 8, 64, 44]);
  assert.equal(hl.surfaces().find((s) => s.surface === ta.surface && s.conn === 1)!.inputRegion, null);

  const at = (x: number, y: number) => { const h = hl.surfaceAt(x, y); return h && [h.conn, h.surface, h.x, h.y]; };
  assert.deepEqual(at(32, 52), [1, ta.surface, 8, 4], 'B\'s shadow: A below takes it');
  assert.deepEqual(at(105, 105), [1, ta.surface, 81, 57], 'the far shadow corner too');
  assert.deepEqual(at(39, 59), [2, tb.surface, 9, 9], 'the resize margin is B\'s');
  assert.deepEqual(at(50, 70), [2, tb.surface, 20, 20]);
  assert.deepEqual(at(90, 120), [1, sub, 6, 12]);

  // enter/leave follow the region; a press holds the pointer on B even
  // when it moves out of B's region (the implicit grab), the release hands
  // it to what is under it
  calls.length = 0;
  hl.pointerMove(50, 70);
  hl.pointerMove(32, 52);
  hl.pointerMove(50, 70);
  hl.pointerDown();
  hl.pointerMove(32, 52);
  hl.pointerUp();
  assert.deepEqual(without(calls, 'keyboardLeave', 'keyboardEnter'), [
    ['pointerEnter', 2, tb.surface, 20, 20],
    ['pointerLeave', 2], ['pointerEnter', 1, ta.surface, 8, 4],
    ['pointerLeave', 1], ['pointerEnter', 2, tb.surface, 20, 20],
    ['pointerButton', 2, 0x110, true],
    ['pointerMotion', 2, 2, 2],
    ['pointerButton', 2, 0x110, false],
    ['pointerLeave', 2], ['pointerEnter', 1, ta.surface, 8, 4],
  ]);

  // a click in the shadow focuses and raises the window below, not B
  hl.raise(`c2s${tb.surface}`);
  hl.click(32, 52);
  assert.equal(hl.focused()!.conn, 1);
  assert.ok(hl.window(`c1s${ta.surface}`)!.z > hl.window(`c2s${tb.surface}`)!.z);
  hl.raise(`c2s${tb.surface}`);

  // an empty region takes no input: the subsurface lets the toplevel through
  a.send(msg(sub, 5, region(a)), msg(sub, 6));
  assert.deepEqual(at(90, 120), [1, ta.surface, 66, 72]);

  // double-buffered: nothing changes before the commit; NULL is the whole
  // surface again, and a commit without a buffer applies it
  b.send(msg(tb.surface, 5, 0));
  assert.deepEqual(at(32, 52), [1, ta.surface, 8, 4]);
  b.send(msg(tb.surface, 6));
  assert.deepEqual(at(32, 52), [2, tb.surface, 2, 2]);
  assert.equal(hl.surfaces().find((s) => s.surface === tb.surface && s.conn === 2)!.inputRegion, null);

  // order matters: add then subtract leaves a hole the pointer falls through
  b.send(msg(tb.surface, 5, region(b, ['add', 0, 0, 80, 60], ['sub', 20, 20, 10, 10])), msg(tb.surface, 6));
  assert.deepEqual(at(55, 75), [1, ta.surface, 31, 27]);
  assert.deepEqual(at(49, 69), [2, tb.surface, 19, 19]);
  // a click in the hole (inside B's geometry) focuses and raises A behind it
  assert.ok(hl.window(`c2s${tb.surface}`)!.z > hl.window(`c1s${ta.surface}`)!.z);
  hl.click(55, 75);
  assert.equal(hl.focused()!.conn, 1);
  assert.ok(hl.window(`c1s${ta.surface}`)!.z > hl.window(`c2s${tb.surface}`)!.z);
  hl.dispose();
});

test('input regions: a press in a popup\'s shadow misses it (dismisses it) and lands below', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  const a = client(ctx, 1);
  const ta = a.toplevel('A');
  a.paint(ta.surface, 100, 80, [255, 0, 0, 255]); // at (24,48)
  const pop = a.popup(ta.xdg, 10, 10, 30, 30); // at (34,58)..(64,88)
  a.send(msg(pop.surface, 5, region(a, ['add', 5, 5, 20, 20])), msg(pop.surface, 6));
  a.paint(pop.surface, 30, 30, [255, 255, 0, 255]);
  assert.equal(hl.surfaceAt(36, 60)!.surface, ta.surface, 'the popup\'s shadow');
  assert.equal(hl.surfaceAt(45, 70)!.surface, pop.surface);
  calls.length = 0;
  hl.click(45, 70);
  assert.ok(!calls.some((c) => c[0] === 'popupDismiss'));
  hl.click(36, 60);
  assert.deepEqual(calls.filter((c) => c[0] === 'popupDismiss'), [['popupDismiss', 1, pop.surface]]);
  assert.deepEqual(calls.filter((c) => c[0] === 'pointerButton').at(-1), ['pointerButton', 1, 0x110, false]);
  hl.dispose();
});

// the serial of the latest wl_pointer.enter the engine sent to `conn`
function enterSerial(link: ScriptedLink, conn: number): number {
  let serial = -1;
  for (const bytes of link.sent) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let off = 0; off < bytes.length;) {
      if (bytes[off] === 0x0b) { off += 9; continue; } // ACK
      if (bytes[off] !== 0x01) break;
      const c = dv.getUint32(off + 1, true), len = dv.getUint32(off + 5, true);
      for (let m = off + 9; c === conn && m < off + 9 + len;) {
        const obj = dv.getUint32(m, true), word = dv.getUint32(m + 4, true);
        if (obj === PTR && (word & 0xffff) === 0) serial = dv.getUint32(m + 8, true);
        m += word >>> 16;
      }
      off += 9 + len;
    }
  }
  return serial;
}

test('pointer lock + relative motion: granted at once (autoLock), moves are relative only while locked, Escape breaks it (swallowed), the next press re-grants', async () => {
  const ctx = await setup();
  const { hl, calls, rels } = ctx;
  const { a, ta } = desk(ctx, { popup: false }); // A's origin (24,48), 40×30
  const g = globals(ctx.link, 1);
  const RELM = a.id(), CONS = a.id(), RP = a.id(), LOCK = a.id();
  a.send(msg(REG, 0, g.zwp_relative_pointer_manager_v1.name, 'zwp_relative_pointer_manager_v1', 1, RELM),
    msg(REG, 0, g.zwp_pointer_constraints_v1.name, 'zwp_pointer_constraints_v1', 1, CONS),
    msg(RELM, 1, RP, PTR), msg(CONS, 1, LOCK, ta.surface, PTR, 0, 2)); // persistent, no region
  calls.length = 0;
  hl.pointerMove(30, 60); // in: the core wants the lock, a page with a gesture gets it
  assert.deepEqual(without(calls, 'keyboardLeave', 'keyboardEnter'), [['pointerEnter', 1, ta.surface, 6, 12], ['pointerLockGranted', 1, ta.surface]]);
  assert.deepEqual(hl.pointerLock(), { conn: 1, surface: ta.surface, locked: true });

  // locked: the pointer stays, the moves reach the app as relative motion
  calls.length = 0;
  rels.length = 0;
  hl.pointerMove(40, 70);
  hl.pointerMoveBy(-5, 0);
  assert.deepEqual(calls, [['pointerMotion', 1, 6, 12], ['pointerMotion', 1, 6, 12]]);
  assert.deepEqual(rels, [[10, 10], [-5, 0]]);
  assert.equal(hl.surfaceAt(30, 60)!.surface, ta.surface);

  // Escape: the lock breaks, the key never reaches the app
  calls.length = 0;
  hl.keyDown('Escape');
  hl.keyUp('Escape');
  assert.deepEqual(calls, [['pointerLockLost', 1]]);
  assert.deepEqual(hl.pointerLock(), { conn: 1, surface: ta.surface, locked: false }, 'persistent: still wanted');
  // unlocked moves are absolute again (and relative); a press re-grants
  calls.length = 0;
  rels.length = 0;
  hl.pointerMove(31, 60);
  hl.pointerDown();
  hl.pointerUp();
  assert.deepEqual(without(calls, 'keyboardLeave', 'keyboardEnter'), [
    ['pointerMotion', 1, 7, 12],
    ['pointerButton', 1, 0x110, true], ['pointerLockGranted', 1, ta.surface], ['pointerButton', 1, 0x110, false],
  ]);
  assert.deepEqual(rels, [[1, 0]]);
  // the app drops the lock: nothing is wanted any more
  a.send(msg(LOCK, 0));
  assert.equal(hl.pointerLock(), null);
  hl.dispose();

  // autoLock false: the lock waits for grantLock()
  const m = await setup({ autoLock: false });
  const d = desk(m, { popup: false });
  const g2 = globals(m.link, 1);
  const CONS2 = d.a.id(), LOCK2 = d.a.id();
  d.a.send(msg(REG, 0, g2.zwp_pointer_constraints_v1.name, 'zwp_pointer_constraints_v1', 1, CONS2), msg(CONS2, 1, LOCK2, d.ta.surface, PTR, 0, 1));
  m.hl.pointerMove(30, 60);
  m.hl.click(30, 60);
  assert.deepEqual(m.hl.pointerLock(), { conn: 1, surface: d.ta.surface, locked: false });
  assert.ok(!m.calls.some((c) => c[0] === 'pointerLockGranted'));
  m.hl.grantLock();
  assert.deepEqual(m.hl.pointerLock()!.locked, true);
  m.hl.breakLock(); // oneshot: dead, nothing wanted
  assert.equal(m.hl.pointerLock(), null);
  m.hl.dispose();
});

test('cursor(): the image the client under the pointer set — a cursor surface with its hotspot, hidden, or the default after it leaves', async () => {
  const ctx = await setup();
  const { hl } = ctx;
  const a = client(ctx, 1);
  const t = a.toplevel('A');
  a.paint(t.surface, 40, 30, [9, 9, 9, 255]);
  // the cursor buffer comes first (GTK's order): attach + commit on the
  // wire, then its pixels, as the relay sends them
  const cur = a.bare();
  a.send(msg(cur, 1, 50, 0, 0), msg(cur, 6));
  a.paint(cur, 8, 8, [1, 2, 3, 255]);
  assert.equal(hl.cursor(), null);

  hl.pointerMove(30, 60);
  const serial = enterSerial(ctx.link, 1);
  assert.ok(serial > 0);
  assert.equal(hl.cursor(), null, 'nothing set since the enter: the default');
  a.send(msg(PTR, 0, serial + 9, cur, 2, 3));
  assert.equal(hl.cursor(), null, 'a stale serial is ignored');
  a.send(msg(PTR, 0, serial, cur, 2, 3));
  assert.deepEqual(hl.cursor(), { conn: 1, cursor: 'default', surface: cur, hotspotX: 2, hotspotY: 3 });
  assert.deepEqual(px(hl.surfacePixels(1, cur)!, 7, 7), [1, 2, 3, 255], 'the image is the surface\'s buffer');
  assert.equal(hl.surfaceAt(30, 60)!.surface, t.surface, 'and it never takes the pointer');
  // attach's x,y moves the hotspot against it once committed
  a.send(msg(cur, 1, 51, 1, 2), msg(cur, 6));
  a.paint(cur, 8, 8, [4, 5, 6, 255]);
  assert.deepEqual(hl.cursor(), { conn: 1, cursor: 'default', surface: cur, hotspotX: 1, hotspotY: 1 });
  // NULL hides the pointer
  a.send(msg(PTR, 0, serial, 0, 0, 0));
  assert.deepEqual(hl.cursor(), { conn: 1, cursor: 'none', surface: 0, hotspotX: 0, hotspotY: 0 });
  // leaving: the default again, and that enter's serial is spent
  a.send(msg(PTR, 0, serial, cur, 2, 3));
  hl.pointerMove(5, 5);
  assert.equal(hl.cursor(), null);
  a.send(msg(PTR, 0, serial, cur, 2, 3));
  assert.equal(hl.cursor(), null);
  // destroyed while it is the image: hidden
  hl.pointerMove(30, 60);
  a.send(msg(PTR, 0, enterSerial(ctx.link, 1), cur, 2, 3));
  assert.equal(hl.cursor()!.surface, cur);
  a.send(msg(cur, 0));
  assert.deepEqual(hl.cursor(), { conn: 1, cursor: 'none', surface: 0, hotspotX: 0, hotspotY: 0 });
  // the client hangs up: nothing of it is left
  ctx.deliver(connClose(1));
  assert.equal(hl.cursor(), null);
  hl.dispose();
});

test('keyboard: type() on a US layout with shift, press() chords, nothing sent for untypable text', async () => {
  const ctx = await setup();
  const { hl, calls } = ctx;
  desk(ctx, { popup: false });
  calls.length = 0;
  hl.type('aB!\n');
  const keys = (cs: Call[]) => cs.filter((c) => c[0] === 'key').map((c) => `${c[3] ? '+' : '-'}${c[2]}`).join(' ');
  assert.equal(keys(calls), '+30 -30 +42 +48 -48 -42 +42 +2 -2 -42 +28 -28');
  assert.ok(calls.every((c) => c[1] === 2), 'to the focused window');
  calls.length = 0;
  assert.throws(() => hl.type('xé'), /no US-layout key/);
  assert.deepEqual(calls, []);
  hl.press('ControlLeft', 'KeyC');
  assert.equal(keys(calls), '+29 +46 -46 -29');
  assert.throws(() => hl.press('NoSuchKey'), /unknown key/);
  hl.dispose();
});

test('the clock: manual tick() with frameInterval 0, a timer by default that dispose() stops', async () => {
  const ctx = await setup();
  ctx.hl.tick(5);
  assert.deepEqual(ctx.calls, [['tick', 5]]);
  ctx.hl.dispose();

  const timed = await setup({ frameInterval: 5 });
  await new Promise((r) => setTimeout(r, 40));
  const n = timed.calls.filter((c) => c[0] === 'tick').length;
  assert.ok(n >= 2, `${n} ticks`);
  timed.hl.dispose();
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(timed.calls.filter((c) => c[0] === 'tick').length, n);
});

test('encodePNG: signature, IHDR, CRCs and IDAT rows', async () => {
  const img = { width: 3, height: 2, data: new Uint8Array(24).map((_, i) => i * 10) };
  const png = await encodePNG(img);
  assert.deepEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const dv = new DataView(png.buffer);
  const chunks: Record<string, Uint8Array> = {};
  for (let off = 8; off < png.length;) {
    const len = dv.getUint32(off);
    const type = new TextDecoder().decode(png.subarray(off + 4, off + 8));
    assert.equal(dv.getUint32(off + 8 + len), crc32(png.subarray(off + 4, off + 8 + len)), `${type} crc`);
    chunks[type] = png.subarray(off + 8, off + 8 + len);
    off += 12 + len;
  }
  assert.deepEqual(Object.keys(chunks), ['IHDR', 'IDAT', 'IEND']);
  assert.deepEqual([...chunks.IHDR], [0, 0, 0, 3, 0, 0, 0, 2, 8, 6, 0, 0, 0]);
  assert.deepEqual([...inflateSync(chunks.IDAT)], [0, ...img.data.subarray(0, 12), 0, ...img.data.subarray(12)]);
});
