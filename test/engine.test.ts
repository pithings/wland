// The engine runs with no DOM: load the real core wasm in Node, drive it
// through a scripted link (STREAM.md frames in, frames out) and assert the
// plain-data events it emits. Needs a prior `zig build` (lib/wland.wasm).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createEngine, type Link, type LinkCallbacks } from '../lib/engine.ts';

const wasm = await readFile(new URL('../lib/wland.wasm', import.meta.url));

// --- STREAM frames + wayland wire encoding --------------------------------
const CONN = 7;

function frame(type: number, ...parts: Uint8Array[]) {
  const len = 1 + parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(len);
  out[0] = type;
  let off = 1;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}
const u32s = (...v: number[]) => new Uint8Array(new Uint32Array(v).buffer);
const i32s = (...v: number[]) => new Uint8Array(new Int32Array(v).buffer);
const connOpen = (conn: number) => frame(3, u32s(conn));
const wireFrame = (conn: number, bytes: Uint8Array) => frame(1, u32s(conn, bytes.length), bytes);

function wlString(s: string) {
  const b = new TextEncoder().encode(s);
  const padded = new Uint8Array(4 + ((b.length + 1 + 3) & ~3));
  new DataView(padded.buffer).setUint32(0, b.length + 1, true);
  padded.set(b, 4);
  return padded;
}
// one request: object id, opcode, args (numbers = u32, strings, Uint8Array)
function msg(object: number, opcode: number, ...args: (number | string | Uint8Array)[]) {
  const body = args.map((a) => (typeof a === 'string' ? wlString(a) : a instanceof Uint8Array ? a : u32s(a)));
  const size = 8 + body.reduce((n, b) => n + b.length, 0);
  const out = new Uint8Array(size);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, object, true);
  dv.setUint32(4, (size << 16) | opcode, true);
  let off = 8;
  for (const b of body) { out.set(b, off); off += b.length; }
  return out;
}
const pack = (...frames: Uint8Array[]) => {
  const out = new Uint8Array(frames.reduce((n, f) => n + f.length, 0));
  let off = 0;
  for (const f of frames) { out.set(f, off); off += f.length; }
  return out.buffer;
};

// parse wl_registry.global events out of the engine's outgoing WIRE frames
function globals(sent: Uint8Array[], registry: number) {
  const found: Record<string, { name: number; version: number }> = {};
  for (const bytes of sent) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let off = 0;
    while (off < bytes.length) {
      const t = bytes[off];
      if (t !== 1) break; // the replies here are WIRE only
      const len = dv.getUint32(off + 5, true);
      let m = off + 9;
      while (m < off + 9 + len) {
        const obj = dv.getUint32(m, true), word = dv.getUint32(m + 4, true);
        const size = word >>> 16, opcode = word & 0xffff;
        if (obj === registry && opcode === 0) {
          const name = dv.getUint32(m + 8, true);
          const slen = dv.getUint32(m + 12, true);
          const iface = new TextDecoder().decode(bytes.subarray(m + 16, m + 16 + slen - 1));
          const version = dv.getUint32(m + 16 + ((slen + 3) & ~3), true);
          found[iface] = { name, version };
        }
        m += size;
      }
      off += 9 + len;
    }
  }
  return found;
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

test('engine runs without a DOM: registry, toplevel, title, commit, destroy', async () => {
  assert.equal(typeof document, 'undefined');
  assert.equal(typeof window, 'undefined');

  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({
    wasm, link,
    onEvent: (ev) => {
      // pixels are a view valid only during dispatch: copy to inspect later
      events.push(ev.type === 'commit' ? { ...ev, pixels: ev.pixels.slice() } : ev);
    },
  });
  assert.ok(engine.version > 0);
  engine.setScale(2, 240);
  engine.setOutput(1280, 720);
  engine.start();
  link.cb!.onOpen();
  assert.deepEqual(events.shift(), { type: 'open' });

  // wl_display.get_registry(new_id 2) + sync(new_id 3)
  link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, new Uint8Array([...msg(1, 1, 2), ...msg(1, 0, 3)]))));
  const g = globals(link.sent, 2);
  assert.ok(g.wl_compositor && g.xdg_wm_base && g.wl_shm && g.wl_seat, `globals: ${Object.keys(g)}`);
  assert.ok(g.wl_compositor.version >= 4);

  // bind wl_compositor → 4, xdg_wm_base → 5; create_surface → 6;
  // get_xdg_surface(7, 6); get_toplevel(8); set_title
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', g.wl_compositor.version, 4),
    ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', g.xdg_wm_base.version, 5),
    ...msg(4, 0, 6),
    ...msg(5, 2, 7, 6),
    ...msg(7, 1, 8),
    ...msg(8, 2, 'hello wland'),
  ]))));
  const surface = events.find((e) => e.type === 'surface');
  assert.deepEqual(surface, { type: 'surface', conn: CONN, surface: 6, role: 1, root: 6, parent: 0, z: 0 });
  const title = events.find((e) => e.type === 'title');
  assert.deepEqual(title, { type: 'title', conn: CONN, surface: 6, title: 'hello wland' });

  // a BUFFER frame (canvas-ready RGBA, packed per damage rect) → commit
  const px = new Uint8Array(2 * 1 * 4 + 1 * 2 * 4).map((_, i) => i + 1);
  link.cb!.onMessage(pack(frame(2,
    u32s(CONN, 6, 64, 32, 2),
    i32s(0, 0, 2, 1, 10, 5, 1, 2),
    px)));
  const commit = events.find((e) => e.type === 'commit');
  assert.equal(commit.conn, CONN);
  assert.equal(commit.surface, 6);
  assert.equal(commit.role, 1);
  assert.equal(commit.root, 6);
  assert.equal(commit.format, 'rgba');
  assert.equal(commit.width, 64);
  assert.equal(commit.height, 32);
  assert.equal(commit.logicalWidth, 64); // no set_buffer_scale / viewport
  assert.equal(commit.maximized, false);
  assert.equal(commit.fullscreen, false);
  assert.equal(commit.minimized, false);
  assert.deepEqual([...commit.damage], [0, 0, 2, 1, 10, 5, 1, 2]);
  assert.deepEqual([...commit.pixels], [...px]);
  assert.equal(engine.stats.commits, 1);

  // every event survives structured cloning (the Worker boundary)
  for (const ev of events) assert.deepEqual(structuredClone(ev), ev);

  // wl_surface.destroy → destroy
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([...msg(8, 0), ...msg(7, 0), ...msg(6, 0)]))));
  assert.deepEqual(events.at(-1), { type: 'destroy', conn: CONN, surface: 6 });

  // CONN_CLOSE → disconnect
  link.cb!.onMessage(pack(frame(4, u32s(CONN))));
  assert.deepEqual(events.at(-1), { type: 'disconnect', conn: CONN });

  link.cb!.onClose({ takenOver: true });
  assert.deepEqual(events.at(-1), { type: 'close', takenOver: true });
});

test('motion is coalesced and held back while the link is backed up', async () => {
  const link = scriptedLink();
  const engine = await createEngine({ wasm, link, onEvent: () => {} });
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(connOpen(1)));
  for (let i = 0; i < 5; i++) engine.pointerMotion(1, i, i, i);
  link.bufferedAmount = 1 << 20;
  engine.tick(16);
  assert.equal(engine.stats.backpressured, 1);
  assert.equal(engine.stats.sentMotions, 0);
  link.bufferedAmount = 0;
  engine.tick(32);
  assert.deepEqual(
    { motions: engine.stats.motions, sentMotions: engine.stats.sentMotions },
    { motions: 5, sentMotions: 1 },
  );
  // an order-sensitive call ships the pending motion first, even when backed up
  engine.pointerMotion(1, 40, 1, 1);
  link.bufferedAmount = 1 << 20;
  engine.pointerButton(1, 41, 0x110, true);
  assert.equal(engine.stats.sentMotions, 2);
});

test('calls before the link opens are dropped, output state is kept', async () => {
  const link = scriptedLink();
  const engine = await createEngine({ wasm, link, onEvent: () => {} });
  engine.pointerMotion(1, 0, 1, 1);
  engine.key(1, 0, 30, true);
  engine.setOutput(800, 600);
  engine.start();
  assert.equal(link.sent.length, 0);
  assert.equal(engine.stats.motions, 0);
});

test('a link that opens again: close ends every conn (disconnect first), the next open is a fresh compositor', async () => {
  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({ wasm, link, onEvent: (ev) => events.push(ev) });
  engine.start();
  link.cb!.onOpen();
  // two apps; one maps a toplevel
  link.cb!.onMessage(pack(connOpen(1), connOpen(2), wireFrame(1, new Uint8Array([...msg(1, 1, 2)]))));
  const g = globals(link.sent, 2);
  link.cb!.onMessage(pack(wireFrame(1, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', g.wl_compositor.version, 4),
    ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', g.xdg_wm_base.version, 5),
    ...msg(4, 0, 6), ...msg(5, 2, 7, 6), ...msg(7, 1, 8),
  ]))));
  assert.ok(events.some((e) => e.type === 'surface' && e.conn === 1));
  // conn 2 closed by the relay already: not ended twice
  link.cb!.onMessage(pack(frame(4, u32s(2))));
  events.length = 0;
  const sentBefore = link.sent.length;

  link.cb!.onClose({ takenOver: false });
  assert.deepEqual(events.filter((e) => e.type !== 'log'), [
    { type: 'disconnect', conn: 1 },
    { type: 'close', takenOver: false },
  ]);
  assert.equal(link.sent.length, sentBefore, 'nothing is sent on a closed link');

  // the relay reconnects: a fresh compositor, conn ids start over at the relay's will
  events.length = 0;
  link.sent.length = 0;
  link.cb!.onOpen();
  assert.deepEqual(events.filter((e) => e.type !== 'log'), [{ type: 'open' }]);
  link.cb!.onMessage(pack(connOpen(3), wireFrame(3, new Uint8Array([...msg(1, 1, 2)]))));
  assert.ok(globals(link.sent, 2).wl_compositor, 'the new link has a working registry');
  // an id the old link used is unknown to the new compositor: no events for it
  engine.keyboardEnter(1, 6);
  link.cb!.onClose({ takenOver: false });
  assert.deepEqual(events.filter((e) => e.type === 'disconnect'), [{ type: 'disconnect', conn: 3 }]);
});

test('a FEATURE frame (linux_dmabuf) ahead of the conns makes the compositor advertise zwp_linux_dmabuf_v1', async () => {
  const run = async (feature: Uint8Array | null) => {
    const link = scriptedLink();
    const errors: string[] = [];
    const engine = await createEngine({ wasm, link, onEvent: (ev) => { if (ev.type === 'error') errors.push(ev.detail); } });
    engine.start();
    link.cb!.onOpen();
    // FEATURE: u32 feature (1 = linux_dmabuf), u32 len, u64 dev_t, then
    // 16-byte table entries {fourcc, 0, u64 modifier}: XR24 LINEAR
    const bytes = feature ?? new Uint8Array(0);
    const frames = feature ? [frame(0x0c, u32s(1, bytes.length), bytes)] : [];
    link.cb!.onMessage(pack(...frames, connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
    assert.deepEqual(errors, []);
    return globals(link.sent, 2);
  };
  const dmabuf = new Uint8Array([...u32s(0xe280, 0), ...u32s(0x34325258, 0, 0, 0)]);
  const g = await run(dmabuf);
  assert.ok(g.wl_compositor, 'the rest of the message was processed');
  assert.deepEqual(g.zwp_linux_dmabuf_v1, { name: 14, version: 4 });
  assert.equal((await run(null)).zwp_linux_dmabuf_v1, undefined);
});

test('FEATURE dmabuf_kind (virtgpu) before linux_dmabuf: offered only by an engine with a gpu source; without one the global is absent (a bind is a protocol error), wl_shm stays, the core says why; readback (no dmabuf_kind) needs none; on every link', async () => {
  const table = new Uint8Array([...u32s(0xe280, 0), ...u32s(0x34325258, 0, 0, 0)]);
  const linuxDmabuf = frame(0x0c, u32s(1, table.length), table);
  const dmabufKind = frame(0x0c, u32s(2, 4, 2)); // u32 buffer kind 2 = virtgpu
  const run = async (gpu: boolean, features: Uint8Array[]) => {
    const link = scriptedLink();
    const logs: string[] = [];
    const errors: string[] = [];
    const engine = await createEngine({
      wasm, link, gpu: gpu ? { resolve: () => null } : undefined,
      onEvent: (ev) => { if (ev.type === 'log') logs.push(ev.line); else if (ev.type === 'error') errors.push(ev.detail); },
    });
    engine.start();
    const links: Record<string, { name: number; version: number }>[] = [];
    for (let i = 0; i < 2; i++) { // a link, then the relay reconnects
      link.sent.length = 0;
      link.cb!.onOpen();
      link.cb!.onMessage(pack(...features, connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
      links.push(globals(link.sent, 2));
      if (i === 0) link.cb!.onClose({ takenOver: false });
    }
    // bound anyway, by its name: a protocol error (wl_display.error) for the client
    link.sent.length = 0;
    link.cb!.onMessage(pack(wireFrame(CONN, msg(2, 0, 14, 'zwp_linux_dmabuf_v1', 4, 3))));
    const protocolError = wireEvents(link.sent, CONN).some((e) => e[0] === 1 && e[1] === 0);
    const refused = logs.filter((l) => /linux-dmabuf not offered/.test(l)).length;
    return { links, protocolError, refused, errors };
  };
  const dmabufOf = (r: Awaited<ReturnType<typeof run>>) => r.links.map((g) => g.zwp_linux_dmabuf_v1 ?? null);
  const shmOf = (r: Awaited<ReturnType<typeof run>>) => r.links.every((g) => !!g.wl_shm && !!g.wl_compositor);
  const offered = { name: 14, version: 4 };

  const withGpu = await run(true, [dmabufKind, linuxDmabuf]);
  assert.deepEqual(dmabufOf(withGpu), [offered, offered]);
  assert.equal(withGpu.protocolError, false);
  assert.equal(withGpu.refused, 0);

  const without = await run(false, [dmabufKind, linuxDmabuf]);
  assert.deepEqual(dmabufOf(without), [null, null], 'no gpu source: GPU clients must not take the GPU path');
  assert.ok(shmOf(without), 'the software path stays');
  assert.equal(without.protocolError, true);
  assert.equal(without.refused, 2, 'one log line per link');
  assert.deepEqual(without.errors, []);

  const readback = await run(false, [linuxDmabuf]); // pixels in the stream: any engine shows them
  assert.deepEqual(dmabufOf(readback), [offered, offered]);
  assert.equal(readback.refused, 0);
});

// every wayland event the engine sent to `conn`: [object, opcode, ...arg words]
function wireEvents(sent: Uint8Array[], conn: number): number[][] {
  const out: number[][] = [];
  for (const bytes of sent) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let off = 0; off < bytes.length;) {
      if (bytes[off] !== 1) break;
      const c = dv.getUint32(off + 1, true), len = dv.getUint32(off + 5, true);
      for (let m = off + 9; c === conn && m < off + 9 + len;) {
        const word = dv.getUint32(m + 4, true), size = word >>> 16;
        const ev = [dv.getUint32(m, true), word & 0xffff];
        for (let a = m + 8; a < m + size; a += 4) ev.push(dv.getInt32(a, true));
        out.push(ev);
        m += size;
      }
      off += 9 + len;
    }
  }
  return out;
}

test('relative pointer + pointer lock through the engine: motions coalesce with their deltas summed; the lock is a pointer-lock event, granted → locked, lost → unlocked', async () => {
  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({ wasm, link, onEvent: (ev) => { if (ev.type !== 'log') events.push(ev); } });
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
  const g = globals(link.sent, 2);
  assert.deepEqual(g.zwp_relative_pointer_manager_v1, { name: 15, version: 1 });
  assert.deepEqual(g.zwp_pointer_constraints_v1, { name: 16, version: 1 });
  // wl_compositor 4, wl_seat 5 (v5: frames), relative manager 9,
  // constraints 10; surface 6, wl_pointer 11, relative pointer 12, a
  // persistent lock 13 on the surface
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', 4, 4),
    ...msg(2, 0, g.wl_seat.name, 'wl_seat', 5, 5),
    ...msg(2, 0, 15, 'zwp_relative_pointer_manager_v1', 1, 9),
    ...msg(2, 0, 16, 'zwp_pointer_constraints_v1', 1, 10),
    ...msg(4, 0, 6), ...msg(5, 0, 11), ...msg(9, 1, 12, 11), ...msg(10, 1, 13, 6, 11, 0, 2),
  ]))));
  events.length = 0;
  link.sent.length = 0;
  const FIX = 256, PTR = 11;
  engine.pointerEnter(CONN, 6, 10, 10);
  assert.deepEqual(events, [{ type: 'pointer-lock', conn: CONN, surface: 6 }], 'the pointer is in: the lock is wanted');
  // two motions before a frame: the newest position, the deltas summed
  engine.pointerMotion(CONN, 1, 11, 10, { dx: 1, dy: 0, time: 1000 });
  engine.pointerMotion(CONN, 2, 13, 11, { dx: 2, dy: 1.5, dxUnaccel: 4, time: 2000 });
  link.sent.length = 0;
  engine.tick(16);
  assert.deepEqual(wireEvents(link.sent, CONN), [
    [PTR, 2, 2, 13 * FIX, 11 * FIX],
    [12, 0, 0, 2000, 3 * FIX, 1.5 * FIX, 5 * FIX, 1.5 * FIX], // utime hi/lo, dx dy, unaccelerated
    [PTR, 5],
  ]);
  assert.equal(engine.stats.sentMotions, 1);
  // the browser granted it: locked; motion is relative only from here
  link.sent.length = 0;
  engine.pointerLockGranted(CONN, 6);
  engine.pointerMotion(CONN, 3, 13, 11, { dx: -7, dy: 2 });
  engine.tick(32);
  assert.deepEqual(wireEvents(link.sent, CONN), [[13, 0], [12, 0, 0, 3000, -7 * FIX, 2 * FIX, -7 * FIX, 2 * FIX], [PTR, 5]]);
  // Esc: lost → unlocked; persistent, so still wanted (no new event)
  link.sent.length = 0;
  events.length = 0;
  engine.pointerLockLost(CONN);
  assert.deepEqual(wireEvents(link.sent, CONN), [[13, 1]]);
  assert.deepEqual(events, []);
  // the app hangs up: the lock is let go
  link.cb!.onMessage(pack(frame(4, u32s(CONN))));
  assert.deepEqual(events, [{ type: 'pointer-lock', conn: CONN, surface: 0 }, { type: 'disconnect', conn: CONN }]);
});

test('lock modifiers through the engine: NumLock (Mod2) locked from the start, keyboardLocks sets the browser\'s state; the state — lock keys\' toggles included — is kept across a link reopen', async () => {
  const link = scriptedLink();
  const engine = await createEngine({ wasm, link, onEvent: () => {} });
  engine.start();
  const KB = 11, MODIFIERS = 4, CAPS = 1 << 1, NUM = 1 << 4;
  const mapped = () => {
    link.sent.length = 0;
    link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
    const g = globals(link.sent, 2);
    // wl_compositor 4, xdg_wm_base 5, wl_seat 9; surface 6 → xdg_surface 7 → toplevel 8; keyboard 11
    link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
      ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', 4, 4),
      ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', g.xdg_wm_base.version, 5),
      ...msg(2, 0, g.wl_seat.name, 'wl_seat', 5, 9),
      ...msg(4, 0, 6), ...msg(5, 2, 7, 6), ...msg(7, 1, 8), ...msg(9, 1, KB),
    ]))));
    link.sent.length = 0; // (the keymap's FDMSG)
  };
  // [depressed, latched, locked, group] of each wl_keyboard.modifiers sent
  const mods = () => wireEvents(link.sent.splice(0), CONN).filter((e) => e[0] === KB && e[1] === MODIFIERS).map((e) => e.slice(3));

  link.cb!.onOpen();
  mapped();
  engine.keyboardEnter(CONN, 6);
  assert.deepEqual(mods(), [[0, 0, NUM, 0]], 'the enter: NumLock on (keypad keys type digits)');
  engine.key(CONN, 1, 71, true); // KP7: no modifier change
  engine.key(CONN, 2, 71, false);
  assert.deepEqual(mods(), []);
  engine.keyboardLocks(true, true);
  engine.keyboardLocks(true, true); // unchanged: nothing
  assert.deepEqual(mods(), [[0, 0, CAPS | NUM, 0]]);
  engine.keyboardLocks(false, false);
  assert.deepEqual(mods(), [[0, 0, 0, 0]]);
  // the lock keys toggle the core's state after keyboardLocks
  engine.key(CONN, 3, 69, true); // NumLock
  engine.key(CONN, 4, 69, false);
  engine.key(CONN, 5, 58, true); // Caps Lock
  engine.key(CONN, 6, 58, false);
  assert.deepEqual(mods(), [[0, 0, NUM, 0], [0, 0, CAPS | NUM, 0]]);
  // the next link's compositor is fresh: it starts from the state the last
  // one ended with (the toggles), not keyboardLocks' stale (false, false)
  link.cb!.onClose({ takenOver: false });
  link.cb!.onOpen();
  mapped();
  engine.keyboardEnter(CONN, 6);
  assert.deepEqual(mods(), [[0, 0, CAPS | NUM, 0]]);
  // the embedder's word while closed wins over what the link ended with
  engine.key(CONN, 7, 69, true); // NumLock off
  assert.deepEqual(mods(), [[0, 0, CAPS, 0]]);
  link.cb!.onClose({ takenOver: false });
  engine.keyboardLocks(false, true); // while closed: kept
  link.cb!.onOpen();
  mapped();
  engine.keyboardEnter(CONN, 6);
  assert.deepEqual(mods(), [[0, 0, NUM, 0]]);
  // a link that opens again without a close in between carries it too
  engine.key(CONN, 8, 58, true); // Caps Lock on
  assert.deepEqual(mods(), [[0, 0, CAPS | NUM, 0]]);
  link.cb!.onOpen();
  mapped();
  engine.keyboardEnter(CONN, 6);
  assert.deepEqual(mods(), [[0, 0, CAPS | NUM, 0]]);
});

// WIRE events and PRESENTED frames of the engine's output, in order: WIRE
// as [object, opcode, ...u32 args], PRESENTED as { age, event } (the event
// likewise)
function outFrames(sent: Uint8Array[], conn: number): (number[] | { age: number; event: number[] })[] {
  const out: (number[] | { age: number; event: number[] })[] = [];
  const words = (dv: DataView, m: number) => {
    const word = dv.getUint32(m + 4, true), size = word >>> 16;
    const ev = [dv.getUint32(m, true), word & 0xffff];
    for (let a = m + 8; a < m + size; a += 4) ev.push(dv.getUint32(a, true));
    return { ev, size };
  };
  for (const bytes of sent) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let off = 0; off < bytes.length;) {
      const t = bytes[off], c = dv.getUint32(off + 1, true);
      if (t === 0x0e) {
        const len = dv.getUint32(off + 9, true);
        assert.equal(c, conn);
        const { ev, size } = words(dv, off + 13);
        assert.equal(size, len, 'one presented event per frame');
        out.push({ age: dv.getUint32(off + 5, true), event: ev });
        off += 13 + len;
        continue;
      }
      assert.equal(t, 1, `frame type ${t}`);
      const len = dv.getUint32(off + 5, true);
      for (let m = off + 9; c === conn && m < off + 9 + len;) {
        const { ev, size } = words(dv, m);
        out.push(ev);
        m += size;
      }
      off += 9 + len;
    }
  }
  return out;
}

test('presentation feedback: the tick presents, as a PRESENTED frame after its sync_output (age, refresh, vsync only for a display frame)', async () => {
  const link = scriptedLink();
  const engine = await createEngine({ wasm, link, onEvent: () => {} });
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
  const g = globals(link.sent, 2);
  assert.deepEqual(g.wp_presentation, { name: 17, version: 3 });
  // wl_compositor 4, xdg_wm_base 5, wl_output 9, wp_presentation 10;
  // toplevel 6 (xdg_surface 7, xdg_toplevel 8)
  link.sent.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', 4, 4),
    ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', 1, 5),
    ...msg(2, 0, g.wl_output.name, 'wl_output', 4, 9),
    ...msg(2, 0, 17, 'wp_presentation', 3, 10),
    ...msg(4, 0, 6), ...msg(5, 2, 7, 6), ...msg(7, 1, 8),
  ]))));
  assert.ok(outFrames(link.sent, CONN).some((e) => Array.isArray(e) && e[0] === 10 && e[1] === 0 && e[2] === 1), 'clock_id(CLOCK_MONOTONIC)');
  // feedback 11, attach + commit: latched; the next tick presents
  const commitWith = (fb: number) => link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(10, 1, 6, fb), ...msg(6, 1, 20, 0, 0), ...msg(6, 6),
  ]))));
  commitWith(11);
  link.sent.length = 0;
  const t = performance.now() - 3; // a rAF timestamp: the frame began 3 ms ago
  engine.tick(t, 16.6);
  const out = outFrames(link.sent, CONN);
  assert.equal(out.length, 3, JSON.stringify(out));
  assert.deepEqual(out[0], [11, 0, 9]); // sync_output(wl_output 9)
  const p = out[1] as { age: number; event: number[] };
  assert.ok(p.age >= 3000 && p.age < 500_000, `age ${p.age} µs`);
  const ms = t >>> 0;
  assert.deepEqual(p.event, [11, 1, 0, Math.floor(ms / 1000), (ms % 1000) * 1e6, 16_600_000, 0, 0, 1]);
  assert.deepEqual(out[2], [1, 1, 11]); // delete_id

  // a tick that is no display's (headless's timer): no age, refresh or vsync
  commitWith(12);
  link.sent.length = 0;
  engine.tick(5000);
  const q = outFrames(link.sent, CONN)[1] as { age: number; event: number[] };
  assert.deepEqual(q, { age: 0, event: [12, 1, 0, 5, 0, 0, 0, 0, 0] });
  // a "display" time from long ago is not a rAF timestamp of now: no age
  commitWith(13);
  link.sent.length = 0;
  engine.tick(performance.now() - 5000, 0);
  const r = outFrames(link.sent, CONN)[1] as { age: number; event: number[] };
  assert.equal(r.age, 0);
  assert.equal(r.event[5], 0); // refresh not known yet
  assert.equal(r.event[8], 1);
});
