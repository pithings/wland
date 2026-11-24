// The engine runs with no DOM: load the real core wasm in Node, drive it
// through a scripted link (STREAM.md frames in, frames out) and assert the
// plain-data events it emits. Needs a prior `zig build` (lib/wland.wasm).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createEngine, DND_COPY, DND_MOVE, EDGE_LEFT, EDGE_TOP, type Link, type LinkCallbacks } from '../lib/engine.ts';

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

  // set_app_id at once; set_min_size / set_max_size at the commit
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(8, 3, 'org.wland.hello'),
    ...msg(8, 8, 100, 50),
    ...msg(8, 7, 0, 400),
  ]))));
  assert.deepEqual(events.find((e) => e.type === 'app-id'), { type: 'app-id', conn: CONN, surface: 6, appId: 'org.wland.hello' });
  assert.equal(events.find((e) => e.type === 'size-limits'), undefined, 'pending until the commit');
  link.cb!.onMessage(pack(wireFrame(CONN, msg(6, 6))));
  assert.deepEqual(events.find((e) => e.type === 'size-limits'),
    { type: 'size-limits', conn: CONN, surface: 6, minW: 100, minH: 50, maxW: 0, maxH: 400 });

  // close: one xdg_toplevel.close (object 8, event 1, no args) to the app
  link.sent.length = 0;
  engine.close(CONN, 6);
  assert.deepEqual(link.sent.map((b) => [...b]), [[...wireFrame(CONN, u32s(8, (8 << 16) | 1))]]);

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

test('decorations \'server\': a toplevel that asks is configured server_side and a \'decoration\' event precedes its first commit; client_side asked undecorates; setBounds sends configure_bounds (the decorated area) and a configure', async () => {
  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({
    wasm, link, decorations: 'server',
    onEvent: (ev) => { events.push(ev.type === 'commit' ? { ...ev, pixels: null } : ev); },
  });
  engine.setOutput(1280, 720);
  engine.setBounds(1000, 700, 980, 660); // before the link: applied at open
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, new Uint8Array([...msg(1, 1, 2), ...msg(1, 0, 3)]))));
  const g = globals(link.sent, 2);
  const dm = g.zxdg_decoration_manager_v1;
  assert.ok(dm, 'the decoration manager is advertised');
  // compositor 4, xdg_wm_base (v6) 5, decoration manager 9; surface 6,
  // xdg_surface 7, toplevel 8, decoration 10 — then the initial commit
  link.sent.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', g.wl_compositor.version, 4),
    ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', g.xdg_wm_base.version, 5),
    ...msg(2, 0, dm.name, 'zxdg_decoration_manager_v1', dm.version, 9),
    ...msg(4, 0, 6),
    ...msg(5, 2, 7, 6),
    ...msg(7, 1, 8),
    ...msg(9, 1, 10, 8),
    ...msg(6, 6),
  ]))));
  assert.deepEqual(events.filter((e) => e.type === 'decoration'), [{ type: 'decoration', conn: CONN, surface: 6, decorated: true }]);
  assert.equal(events.find((e) => e.type === 'commit'), undefined, 'told before any buffer');
  // ([object, opcode, ...args])
  let wire = wireEvents(link.sent, CONN);
  assert.equal(wire.find((e) => e[0] === 10 && e[1] === 0)?.[2], 2, 'decoration.configure(server_side)');
  assert.deepEqual(wire.find((e) => e[0] === 8 && e[1] === 2)?.slice(2), [980, 660], 'the decorated work area');

  // setBounds: one area for both now; configure_bounds then a configure
  link.sent.length = 0;
  engine.setBounds(900, 600);
  wire = wireEvents(link.sent, CONN);
  assert.deepEqual(wire.map((e) => e.slice(0, 2)), [[8, 2], [8, 0], [7, 0]]);
  assert.deepEqual(wire[0].slice(2), [900, 600]);
  link.sent.length = 0;
  engine.setBounds(900, 600, 0, 0); // the same: nothing
  assert.equal(link.sent.length, 0);

  // set_mode(client_side): honoured, told
  events.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, msg(10, 1, 1))));
  assert.deepEqual(events.filter((e) => e.type === 'decoration'), [{ type: 'decoration', conn: CONN, surface: 6, decorated: false }]);
  engine.dispose();
});

test('decorations default (\'client\'): client_side for every toplevel, no \'decoration\' event', async () => {
  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({ wasm, link, onEvent: (ev) => { events.push(ev); } });
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, new Uint8Array([...msg(1, 1, 2), ...msg(1, 0, 3)]))));
  const g = globals(link.sent, 2);
  const dm = g.zxdg_decoration_manager_v1;
  link.sent.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', g.wl_compositor.version, 4),
    ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', g.xdg_wm_base.version, 5),
    ...msg(2, 0, dm.name, 'zxdg_decoration_manager_v1', dm.version, 9),
    ...msg(4, 0, 6), ...msg(5, 2, 7, 6), ...msg(7, 1, 8), ...msg(9, 1, 10, 8),
    ...msg(10, 1, 2), // set_mode(server_side): asked, not given
    ...msg(6, 6),
  ]))));
  assert.equal(wireEvents(link.sent, CONN).find((e) => e[0] === 10 && e[1] === 0)?.[2], 1);
  assert.equal(events.find((e) => e.type === 'decoration'), undefined);
  engine.dispose();
});

// An engine whose link has one app with a v6 toplevel mapped: compositor 4,
// xdg_wm_base 5; surface 6, xdg_surface 7, toplevel 8, initial commit sent
// (its configure is in link.sent).
async function withToplevel(options: Partial<Parameters<typeof createEngine>[0]> = {}) {
  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({
    wasm, link, ...options,
    onEvent: (ev) => { if (ev.type !== 'log') events.push(ev.type === 'commit' ? { ...ev, pixels: null } : ev); },
  });
  engine.setOutput(1280, 720);
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, new Uint8Array([...msg(1, 1, 2), ...msg(1, 0, 3)]))));
  const g = globals(link.sent, 2);
  link.sent.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', g.wl_compositor.version, 4),
    ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', g.xdg_wm_base.version, 5),
    ...msg(4, 0, 6), ...msg(5, 2, 7, 6), ...msg(7, 1, 8),
    ...msg(6, 6),
  ]))));
  const send = (...msgs: Uint8Array[]) => {
    const all = new Uint8Array(msgs.reduce((n, m) => n + m.length, 0));
    let off = 0;
    for (const m of msgs) { all.set(m, off); off += m.length; }
    link.cb!.onMessage(pack(wireFrame(CONN, all)));
  };
  // the toplevel configures sent since `from`: [w, h, ...states]
  const configures = (from = 0) => wireEvents(link.sent.slice(from), CONN).filter((e) => e[0] === 8 && e[1] === 0).map((e) => [e[2], e[3], ...e.slice(5)]);
  return { link, events, engine, g, send, configures };
}

test('setVisible: a hidden toplevel is configured suspended (v6) with nothing else changed; shown again it is not; repeats send nothing', async () => {
  const { link, events, engine, configures } = await withToplevel();
  link.sent.length = 0;
  events.length = 0;
  engine.setVisible(CONN, 8, false); // not a toplevel's surface: ignored
  assert.equal(link.sent.length, 0);
  engine.setVisible(CONN, 6, false);
  assert.deepEqual(configures(), [[0, 0, 9]]); // suspended
  engine.setVisible(CONN, 6, false);
  assert.deepEqual(configures(), [[0, 0, 9]]);
  engine.setVisible(CONN, 6, true);
  assert.deepEqual(configures(), [[0, 0, 9], [0, 0]]);
  assert.deepEqual(events.filter((e) => e.type === 'minimize'), [], 'not minimized');
  engine.dispose();
});

test('setTiled / requestResize return a token the configure event carries back; the app\'s ack + commit is an acked event naming that configure; tiled states reach the app', async () => {
  const { link, events, engine, send, configures } = await withToplevel();
  const initial = events.filter((e) => e.type === 'configure');
  assert.deepEqual(initial.map((e) => [e.width, e.height, e.cause]), [[0, 0, 0]], 'the initial configure: no cause');
  link.sent.length = 0;
  events.length = 0;
  const t1 = engine.setTiled(CONN, 6, EDGE_LEFT | EDGE_TOP, 400.4, 300);
  const t2 = engine.requestResize(CONN, 6, 500, 350);
  assert.ok(t1 > 0 && t2 === t1 + 1);
  assert.deepEqual(configures(), [[400, 300, 5, 7], [500, 350, 5, 7]]); // tiled_left, tiled_top
  const cfgs = events.filter((e) => e.type === 'configure');
  assert.deepEqual(cfgs.map((e) => [e.width, e.height, e.tiled, e.cause]), [[400, 300, EDGE_LEFT | EDGE_TOP, t1], [500, 350, EDGE_LEFT | EDGE_TOP, t2]]);
  assert.equal(cfgs[1].serial, cfgs[0].serial + 1);
  // the app acks the first (it had not seen the second), then commits
  events.length = 0;
  send(msg(7, 4, cfgs[0].serial));
  assert.deepEqual(events.filter((e) => e.type === 'acked'), [], 'at the commit');
  send(msg(6, 6));
  assert.deepEqual(events.filter((e) => e.type === 'acked'), [{ type: 'acked', conn: CONN, surface: 6, serial: cfgs[0].serial, width: 400, height: 300 }]);
  // the same edges, no size: nothing (no token comes back)
  events.length = 0;
  engine.setTiled(CONN, 6, EDGE_LEFT | EDGE_TOP);
  assert.deepEqual(events.filter((e) => e.type === 'configure'), []);
  engine.dispose();
  assert.equal(engine.setTiled(CONN, 6, 0), 0, 'nothing sent: no token');
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

test('EngineOptions.gpu\'s resolvers set what the compositor offers: resolve → linux-dmabuf before a virtgpu relay, resolveExternal → wland_external_buffer_manager_v1 with FEATURE external_buffer; externalBuffers() null until known, then true/false, again on every link', async () => {
  const table = new Uint8Array([...u32s(0xe280, 0), ...u32s(0x34325258, 0, 0, 0)]);
  const linuxDmabuf = frame(0x0c, u32s(1, table.length), table);
  const dmabufKind = frame(0x0c, u32s(2, 4, 2));
  const external = frame(0x0c, u32s(5, 0));
  const shapes = {
    none: undefined,
    resolve: { resolve: () => null },
    resolveExternal: { resolveExternal: () => null },
    both: { resolve: () => null, resolveExternal: () => null },
  };
  for (const [name, gpu] of Object.entries(shapes)) {
    const hasExt = name === 'resolveExternal' || name === 'both';
    const hasVirt = name === 'resolve' || name === 'both';
    const link = scriptedLink();
    const errors: string[] = [];
    const engine = await createEngine({ wasm, link, gpu, onEvent: (ev) => { if (ev.type === 'error') errors.push(ev.detail); } });
    assert.equal(engine.externalBuffers(), null, `${name}: no link`);
    engine.start();
    const states: (boolean | null)[] = [];
    const offered: { ext: boolean; dmabuf: boolean }[] = [];
    // three links: FEATURE external_buffer (alone first, then an app), the
    // same again (a reconnect), then a relay without it
    for (const features of [[dmabufKind, linuxDmabuf, external], [dmabufKind, linuxDmabuf, external], [dmabufKind, linuxDmabuf]]) {
      link.sent.length = 0;
      link.cb!.onOpen();
      states.push(engine.externalBuffers());
      link.cb!.onMessage(pack(...features));
      states.push(engine.externalBuffers());
      link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
      states.push(engine.externalBuffers());
      const g = globals(link.sent, 2);
      assert.ok(g.wl_compositor && g.wl_shm, `${name}: the rest is there`);
      if (g.wland_external_buffer_manager_v1) assert.equal(g.wland_external_buffer_manager_v1.version, 1);
      offered.push({ ext: !!g.wland_external_buffer_manager_v1, dmabuf: !!g.zwp_linux_dmabuf_v1 });
      link.cb!.onClose({ takenOver: false });
    }
    assert.equal(engine.externalBuffers(), null, `${name}: closed`);
    const settled = hasExt ? [null, true, true] : [null, null, false];
    assert.deepEqual(states, [...settled, ...settled, null, null, false], name);
    assert.deepEqual(offered, [
      { ext: hasExt, dmabuf: hasVirt }, { ext: hasExt, dmabuf: hasVirt }, { ext: false, dmabuf: hasVirt },
    ], name);
    assert.deepEqual(errors, []);
    engine.dispose();
  }
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

test('touch through the engine: get_touch is a touch-bound event, the calls are wl_touch down/motion/up/frame/cancel, a pending motion goes first; release unbinds', async () => {
  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({ wasm, link, onEvent: (ev) => { if (ev.type !== 'log') events.push(ev); } });
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
  const g = globals(link.sent, 2);
  // wl_compositor 4, wl_seat 5 (v5), surface 6, wl_pointer 10, wl_touch 11
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', 4, 4),
    ...msg(2, 0, g.wl_seat.name, 'wl_seat', 5, 5),
    ...msg(4, 0, 6), ...msg(5, 0, 10),
  ]))));
  assert.equal(engine.touchBound(CONN), false);
  events.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, msg(5, 2, 11))));
  assert.deepEqual(events, [{ type: 'touch-bound', conn: CONN, bound: true }]);
  assert.equal(engine.touchBound(CONN), true);

  const FIX = 256, T = 11;
  engine.pointerEnter(CONN, 6, 1, 1);
  engine.pointerMotion(CONN, 1, 2, 2);
  link.sent.length = 0;
  engine.touchDown(CONN, 5, 6, 0, 10.5, 20);
  engine.touchMotion(CONN, 6, 0, -3, 4);
  engine.touchFrame(CONN);
  engine.touchUp(CONN, 7, 0);
  engine.touchFrame(CONN);
  engine.touchDown(CONN, 8, 6, 1, 0, 0);
  engine.touchCancel(CONN);
  const got = wireEvents(link.sent, CONN);
  const down = got[2], up = got[5];
  assert.deepEqual(got, [
    [10, 2, 1, 2 * FIX, 2 * FIX], [10, 5], // the coalesced pointer motion first
    [T, 0, down[2], 5, 6, 0, 10.5 * FIX, 20 * FIX],
    [T, 2, 6, 0, -3 * FIX, 4 * FIX],
    [T, 3],
    [T, 1, up[2], 7, 0],
    [T, 3],
    [T, 0, up[2] + 1, 8, 6, 1, 0, 0],
    [T, 4],
  ]);
  assert.ok(up[2] > down[2]);

  events.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, msg(T, 0)))); // release
  assert.deepEqual(events, [{ type: 'touch-bound', conn: CONN, bound: false }]);
  assert.equal(engine.touchBound(CONN), false);
  engine.dispose();
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

// every frame of the engine's output: WIRE events [conn, object, opcode,
// ...words] and FDMSG [conn, kind, wire bytes, aux bytes]
function engineOut(sent: Uint8Array[]) {
  const wire: number[][] = [], fdmsgs: { conn: number; kind: number; wire: Uint8Array; aux: Uint8Array }[] = [];
  for (const bytes of sent) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let off = 0; off < bytes.length;) {
      const t = bytes[off], conn = dv.getUint32(off + 1, true);
      if (t === 1) {
        const len = dv.getUint32(off + 5, true);
        for (let m = off + 9; m < off + 9 + len;) {
          const word = dv.getUint32(m + 4, true), size = word >>> 16;
          const ev = [conn, dv.getUint32(m, true), word & 0xffff];
          for (let a = m + 8; a < m + size; a += 4) ev.push(dv.getUint32(a, true));
          wire.push(ev);
          m += size;
        }
        off += 9 + len;
      } else if (t === 5) {
        const kind = dv.getUint32(off + 5, true), wl = dv.getUint32(off + 9, true);
        const al = dv.getUint32(off + 13 + wl, true);
        fdmsgs.push({ conn, kind, wire: bytes.slice(off + 13, off + 13 + wl), aux: bytes.slice(off + 17 + wl, off + 17 + wl + al) });
        off += 17 + wl + al;
      } else throw new Error(`frame type ${t} in the engine's output`);
    }
  }
  return { wire, fdmsgs };
}

test('the embedder\'s own drag through the engine: refused without FEATURE selection_cache; begun with no button, offered to the toplevel under it, an early receive held until dragData, accept/set_actions are drag-action events, the drop; no drag-start/drag-end', async () => {
  // a relay without selection_cache (wlandr 0.1.0): nothing begins, nothing is offered
  {
    const link = scriptedLink();
    const engine = await createEngine({ wasm, link, onEvent: () => {} });
    engine.start();
    link.cb!.onOpen();
    link.cb!.onMessage(pack(connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
    link.sent.length = 0;
    assert.equal(engine.selectionBridged(), false);
    assert.equal(engine.dragBegin(['text/plain']), false);
    assert.deepEqual(link.sent, []);
    engine.dispose();
  }

  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({ wasm, link, onEvent: (ev) => { if (ev.type !== 'log') events.push(ev); } });
  engine.start();
  link.cb!.onOpen();
  assert.equal(engine.dragBegin(['text/plain']), false, 'not known yet whether the relay bridges');
  link.cb!.onMessage(pack(frame(0x0c, u32s(3, 0)), connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
  const g = globals(link.sent, 2);
  // wl_compositor 4, xdg_wm_base 5, wl_seat 9, wl_data_device_manager 12 (v3);
  // surface 6 → xdg_surface 7 → toplevel 8, committed; data device 13
  link.cb!.onMessage(pack(wireFrame(CONN, new Uint8Array([
    ...msg(2, 0, g.wl_compositor.name, 'wl_compositor', 4, 4),
    ...msg(2, 0, g.xdg_wm_base.name, 'xdg_wm_base', 1, 5),
    ...msg(2, 0, g.wl_seat.name, 'wl_seat', 5, 9),
    ...msg(2, 0, g.wl_data_device_manager.name, 'wl_data_device_manager', 3, 12),
    ...msg(4, 0, 6), ...msg(5, 2, 7, 6), ...msg(7, 1, 8), ...msg(6, 6),
    ...msg(12, 1, 13, 9),
  ]))));
  events.length = 0;
  link.sent.length = 0;

  assert.equal(engine.dragBegin(['text/plain', 'text/html'], DND_COPY | DND_MOVE), true);
  assert.equal(engine.dragBegin(['text/plain']), false, 'one drag at a time');
  engine.dragMotion(CONN, 6, 10, 5, 5);
  const { wire } = engineOut(link.sent.splice(0));
  // data_offer(new id), offer ×2, source_actions(copy|move), enter
  assert.deepEqual(wire.map((e) => [e[1] === 13 ? 'device' : 'offer', e[2]]),
    [['device', 0], ['offer', 0], ['offer', 0], ['offer', 1], ['device', 1]]);
  const offer = wire[0][3];
  assert.ok(offer >= 0xff000000);
  assert.deepEqual(wire[3].slice(3), [DND_COPY | DND_MOVE]);
  assert.equal(wire[4][4], 6, 'the enter names the surface');

  // the app reads at once (FDMSG pipe from the relay: receive(mime, fd), token 77): held
  const recv = (mime: string, token: number) => {
    const m = msg(offer, 1, mime);
    link.cb!.onMessage(pack(frame(5, u32s(CONN, 3, m.length), m, u32s(4, token))));
  };
  recv('text/plain', 77);
  assert.deepEqual(link.sent, [], 'held: the bytes are not known yet');

  // accept, then set_actions(copy|move, preferred move): drag-action events
  link.cb!.onMessage(pack(wireFrame(CONN, msg(offer, 0, 1, 'text/plain'))));
  assert.deepEqual(events, [{ type: 'drag-action', action: DND_COPY }]);
  link.cb!.onMessage(pack(wireFrame(CONN, msg(offer, 4, DND_COPY | DND_MOVE, DND_MOVE))));
  assert.deepEqual(events.at(-1), { type: 'drag-action', action: DND_MOVE });
  assert.equal(engine.dragAction(), DND_MOVE);
  link.sent.length = 0;

  // the bytes: the held receive is answered (FDMSG pipe, no wire message, token ++ bytes)
  assert.equal(engine.dragData({ 'text/plain': 'héllo', 'text/html': '<b>x</b>' }), true);
  assert.equal(engine.dragData(null), false, 'once');
  const answered = engineOut(link.sent.splice(0)).fdmsgs;
  assert.equal(answered.length, 1);
  assert.equal(answered[0].kind, 3);
  assert.equal(answered[0].wire.length, 0);
  assert.equal(new DataView(answered[0].aux.buffer).getUint32(0, true), 77);
  assert.equal(new TextDecoder().decode(answered[0].aux.subarray(4)), 'héllo');

  // the drop: wl_data_device.drop, the action back to 0, no drag events
  engine.dragDrop();
  const dropped = engineOut(link.sent.splice(0)).wire;
  assert.deepEqual(dropped.map((e) => e.slice(1, 3)), [[13, 4]]);
  assert.equal(engine.dragAction(), 0);
  assert.deepEqual(events.map((e) => e.type), ['drag-action', 'drag-action', 'drag-action']);
  // a receive after it: answered from the bytes
  recv('text/html', 78);
  const late = engineOut(link.sent.splice(0)).fdmsgs;
  assert.equal(new TextDecoder().decode(late[0].aux.subarray(4)), '<b>x</b>');
  engine.dispose();
});
