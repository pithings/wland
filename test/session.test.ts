// The session profile (protocol/STREAM.md "Profiles: passthrough and
// session") from the viewer's side: the engine against a scripted relay
// that speaks the contract's bytes — FEATURE session, then CALL frames out
// and EVENT / SURFACE / pixel frames in. Encoders here are written from
// STREAM.md, independent of lib/remote-core.ts. Needs lib/wland.wasm.
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createEngine, type Engine, type Event, type Link, type LinkCallbacks } from '../lib/engine.ts';
import { installFakeDom } from './fake-dom.ts';
import { createView } from '../lib/view.ts';
import { createInput } from '../lib/input.ts';
import { createWindowManager } from '../lib/wm.ts';
import { reconnecting } from '../lib/link-ws.ts';

const wasm = await readFile(new URL('../lib/wland.wasm', import.meta.url));
const SID = 0x0123456789abcdefn;

// --- STREAM frames ---------------------------------------------------------
const enc = new TextEncoder();
function cat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}
const u8 = (v: number) => Uint8Array.of(v);
const u16 = (v: number) => { const b = new Uint8Array(2); new DataView(b.buffer).setUint16(0, v, true); return b; };
const u32 = (...v: number[]) => { const b = new Uint8Array(4 * v.length); v.forEach((x, i) => new DataView(b.buffer).setUint32(i * 4, x >>> 0, true)); return b; };
const i32 = (...v: number[]) => { const b = new Uint8Array(4 * v.length); v.forEach((x, i) => new DataView(b.buffer).setInt32(i * 4, x, true)); return b; };
const f64 = (v: number) => { const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, v, true); return b; };
const u64 = (v: bigint) => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, v, true); return b; };
const bytes = (b: Uint8Array | string) => { const d = typeof b === 'string' ? enc.encode(b) : b; return cat(u32(d.length), d); };

const feature = (kind: number, body: Uint8Array = new Uint8Array(0)) => cat(u8(0x0c), u32(kind, body.length), body);
const connOpen = (conn: number) => cat(u8(0x03), u32(conn));
const connClose = (conn: number) => cat(u8(0x04), u32(conn));
// CALL (0x0f) / EVENT (0x10): u8 type, u16 op, u32 len, args
const op = (type: number, code: number, ...args: Uint8Array[]) => { const a = cat(...args); return cat(u8(type), u16(code), u32(a.length), a); };
const event = (code: number, ...args: Uint8Array[]) => op(0x10, code, ...args);
const call = (code: number, ...args: Uint8Array[]) => op(0x0f, code, ...args);
interface Surf {
  role: number; scale?: number; viewW?: number; viewH?: number; state?: number; root: number; parent?: number;
  x?: number; y?: number; z?: number; geom?: [number, number, number, number];
}
// SURFACE (0x11), 65 bytes
const surface = (conn: number, id: number, s: Surf) => cat(u8(0x11), u32(conn, id, s.role), i32(s.scale ?? 1, s.viewW ?? 0, s.viewH ?? 0),
  u32(s.state ?? 0, s.root, s.parent ?? 0), i32(s.x ?? 0, s.y ?? 0, s.z ?? 0, ...(s.geom ?? [0, 0, 0, 0])));
// BUFFER (0x02): one rect, the whole w × h image
const buffer = (conn: number, id: number, w: number, h: number, fill: number) =>
  cat(u8(0x02), u32(conn, id, w, h, 1), i32(0, 0, w, h), new Uint8Array(w * h * 4).fill(fill));
const msg = (...frames: Uint8Array[]) => cat(...frames).buffer;

// the frames of every message the engine sent, as byte strings
function framesOf(sent: Uint8Array[]): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (const m of sent) {
    const dv = new DataView(m.buffer, m.byteOffset, m.byteLength);
    let off = 0;
    while (off < m.length) {
      const t = m[off];
      const len = t === 0x0f ? 7 + dv.getUint32(off + 3, true) : t === 0x0b ? 9 : t === 0x01 ? 9 + dv.getUint32(off + 5, true) : -1;
      assert.ok(len > 0, `unexpected frame type 0x${t.toString(16)} from the engine`);
      out.push(m.subarray(off, off + len));
      off += len;
    }
  }
  return out;
}
const hex = (b: Uint8Array) => Buffer.from(b).toString('hex');

type ScriptedLink = Link & { sent: Uint8Array[]; bufferedAmount: number; cb: LinkCallbacks | null };
function scriptedLink(): ScriptedLink {
  const link: ScriptedLink = {
    sent: [], bufferedAmount: 0, cb: null,
    start: (cb) => { link.cb = cb; },
    send: (b) => { link.sent.push(b); },
  };
  return link;
}

// sent frames since the last take(), as hex
function taker(link: ScriptedLink) {
  return () => framesOf(link.sent.splice(0)).map(hex);
}

async function setup(prepare?: (engine: Engine) => void, decorations?: 'client' | 'server') {
  const link = scriptedLink();
  const events: any[] = [];
  let engine!: Engine;
  engine = await createEngine({
    wasm, link, decorations,
    onEvent: (ev: Event) => {
      // pixels are a view valid during dispatch only; session() as seen then
      events.push(ev.type === 'commit' ? { ...ev, pixels: ev.pixels.slice() } : ev.type === 'disconnect' ? { ...ev, session: engine.session() } : ev);
    },
  });
  prepare?.(engine);
  engine.start();
  link.cb!.onOpen();
  return { link, events, engine, take: taker(link) };
}

test('FEATURE session: init goes out first, then the attach calls; session() has the id', async () => {
  const { link, events, engine, take } = await setup((e) => {
    e.setScale(2, 240);
    e.setOutput(1280, 720);
    e.setSuspended(true);
    e.keyboardLocks(true, true);
  });
  assert.deepEqual(events.splice(0), [{ type: 'open' }]);
  assert.deepEqual(take(), [], 'the local core sends nothing on open');
  assert.equal(engine.session(), null);
  // selection_cache first (the local core's), then session
  link.cb!.onMessage(msg(feature(3), feature(4, u64(SID))));
  assert.deepEqual(engine.session(), { id: '0123456789abcdef' });
  assert.deepEqual(take(), [
    call(1, i32(2, 240), u32(0)),
    call(2, u32(0)),
    call(4, i32(1280, 720)),
    call(5, u32(1)),
    call(16, u32(3)),
  ].map(hex));
  assert.equal(engine.selectionBridged(), true);
});

test('decorations \'server\' rides init (its third word), bounds follow as set_bounds; later setBounds is CALL 30; EVENT 16 is a decoration event', async () => {
  const { link, events, engine, take } = await setup((e) => {
    e.setOutput(1280, 720);
    e.setBounds(1200, 700, 1180, 660);
  }, 'server');
  link.cb!.onMessage(msg(feature(4, u64(SID))));
  assert.deepEqual(take(), [
    call(1, i32(1, 120), u32(1)),
    call(2, u32(0)),
    call(4, i32(1280, 720)),
    call(30, i32(1200, 700, 1180, 660)),
  ].map(hex));
  engine.setBounds(0, 0);
  assert.deepEqual(take(), [call(30, i32(0, 0, 0, 0))].map(hex));
  events.length = 0;
  link.cb!.onMessage(msg(connOpen(7), surface(7, 10, { role: 1, root: 10 }), event(16, u32(7, 10, 1)), event(16, u32(7, 10, 0)), event(13)));
  assert.deepEqual(events.filter((e) => e.type === 'decoration'), [
    { type: 'decoration', conn: 7, surface: 10, decorated: true },
    { type: 'decoration', conn: 7, surface: 10, decorated: false },
  ]);
});

test('EVENT 17 is a configure event (states decoded, the cause), EVENT 18 an acked event', async () => {
  const { link, events } = await setup();
  link.cb!.onMessage(msg(feature(4, u64(SID))));
  events.length = 0;
  link.cb!.onMessage(msg(connOpen(7), surface(7, 10, { role: 1, root: 10 }),
    event(17, u32(7, 10, 0xfffffff0), i32(640, 480), u32(1 | 4 | (5 << 4), 3)),
    event(17, u32(7, 10, 0xfffffff1), i32(0, 0), u32(2 | 8, 0)),
    event(18, u32(7, 10, 0xfffffff0), i32(640, 480)),
    event(13)));
  assert.deepEqual(events.filter((e) => e.type === 'configure' || e.type === 'acked'), [
    { type: 'configure', conn: 7, surface: 10, serial: 0xfffffff0, width: 640, height: 480,
      maximized: true, fullscreen: false, activated: true, suspended: false, tiled: 5, cause: 3 },
    { type: 'configure', conn: 7, surface: 10, serial: 0xfffffff1, width: 0, height: 0,
      maximized: false, fullscreen: true, activated: false, suspended: true, tiled: 0, cause: 0 },
    { type: 'acked', conn: 7, surface: 10, serial: 0xfffffff0, width: 640, height: 480 },
  ]);
});

test('scene replay: surfaces, titles, regions, states and commits from the SURFACE mirror, then synced', async () => {
  const { link, events, engine, take } = await setup();
  link.cb!.onMessage(msg(feature(4, u64(SID))));
  take();
  events.length = 0;
  link.cb!.onMessage(msg(
    connOpen(7),
    surface(7, 10, { role: 1, scale: 2, state: 1, root: 10, geom: [5, 6, 100, 80] }),
    event(3, u32(7, 10, 1)),
    event(2, u32(7, 10), bytes('foot')),
    event(14, u32(7, 10), bytes('org.codeberg.dnkl.foot')),
    event(8, u32(7, 10, 0, 2), i32(1, 2, 3, 4, 10, 20, 30, 40)),
    event(15, u32(7, 10), i32(120, 40, 0, 0)),
    event(16, u32(7, 10, 1)),
    event(4, u32(7, 10, 2, 0)),
    surface(7, 11, { role: 2, scale: 2, root: 10, parent: 10, x: 4, y: 5, z: 1 }),
    event(3, u32(7, 11, 2)),
    event(99, u32(1, 2, 3)), // an op this viewer does not know: skipped
    buffer(7, 10, 4, 2, 0x11),
    buffer(7, 11, 2, 2, 0x22),
    event(5, u32(7, 4)),
    event(10, u32(7), bytes('text/plain\0UTF8_STRING')),
    event(12, u32(1)),
    event(13),
  ));
  const types = events.map((e) => e.type);
  assert.deepEqual(types, ['surface', 'title', 'app-id', 'input-region', 'size-limits', 'decoration', 'maximize', 'surface', 'commit', 'commit', 'cursor', 'selection', 'synced']);
  assert.deepEqual(events[0], { type: 'surface', conn: 7, surface: 10, role: 1, root: 10, parent: 0, z: 0 });
  assert.deepEqual(events[1], { type: 'title', conn: 7, surface: 10, title: 'foot' });
  assert.deepEqual(events[2], { type: 'app-id', conn: 7, surface: 10, appId: 'org.codeberg.dnkl.foot' });
  assert.deepEqual(events[3].region && [...events[3].region], [1, 2, 3, 4, 10, 20, 30, 40]);
  assert.deepEqual(events[4], { type: 'size-limits', conn: 7, surface: 10, minW: 120, minH: 40, maxW: 0, maxH: 0 });
  assert.deepEqual(events.at(5), { type: 'decoration', conn: 7, surface: 10, decorated: true });
  events.splice(2, 1);
  events.splice(3, 2);
  assert.deepEqual(events[3], { type: 'maximize', conn: 7, surface: 10, maximized: true });
  assert.deepEqual(events[4], { type: 'surface', conn: 7, surface: 11, role: 2, root: 10, parent: 10, z: 1 });
  const top = events[5];
  assert.deepEqual({ ...top, pixels: undefined, damage: [...top.damage] }, {
    type: 'commit', conn: 7, surface: 10, role: 1, root: 10, parent: 0, z: 0,
    geometry: { x: 5, y: 6, width: 100, height: 80 }, x: 0, y: 0,
    maximized: true, fullscreen: false, minimized: false,
    width: 4, height: 2, logicalWidth: 2, logicalHeight: 1,
    format: 'rgba', stride: 0, damage: [0, 0, 4, 2], pixels: undefined,
  });
  assert.ok(top.pixels.every((v: number) => v === 0x11));
  const sub = events[6];
  assert.deepEqual([sub.surface, sub.role, sub.root, sub.parent, sub.x, sub.y, sub.z, sub.maximized, sub.logicalWidth],
    [11, 2, 10, 10, 4, 5, 1, true, 1]);
  assert.deepEqual(sub.geometry, { x: 5, y: 6, width: 100, height: 80 }, 'the root\'s geometry');
  assert.deepEqual(events[7], { type: 'cursor', conn: 7, cursor: 'pointer', surface: 0, hotspotX: 0, hotspotY: 0 });
  assert.deepEqual(events[8], { type: 'selection', conn: 7, mimes: ['text/plain', 'UTF8_STRING'] });
  assert.deepEqual(engine.selection(), { conn: 7, mimes: ['text/plain', 'UTF8_STRING'] });
  assert.deepEqual(take(), [], 'replay needs no answer (no ACK for BUFFER, no tick)');
  engine.tick(16);
  assert.deepEqual(take(), [], 'no tick crosses the link');

  // a SURFACE that moves (and restacks) the placed subsurface: 'position'
  events.length = 0;
  link.cb!.onMessage(msg(surface(7, 11, { role: 2, scale: 2, root: 10, parent: 10, x: 8, y: 9, z: -1 })));
  assert.deepEqual(events, [{ type: 'position', conn: 7, surface: 11, x: 8, y: 9, z: -1 }]);
  // ... and one that only changes the window's state reads as no position
  events.length = 0;
  link.cb!.onMessage(msg(surface(7, 10, { role: 1, scale: 2, state: 0, root: 10, geom: [5, 6, 100, 80] }), event(4, u32(7, 10, 3, 0))));
  assert.deepEqual(events, [{ type: 'maximize', conn: 7, surface: 10, maximized: false }]);

  // the subsurface destroyed, then the app gone: a real disconnect
  // (session() still set while it is dispatched)
  events.length = 0;
  link.cb!.onMessage(msg(event(3, u32(7, 11, 0xffffffff)), connClose(7)));
  assert.deepEqual(events, [
    { type: 'destroy', conn: 7, surface: 11 },
    { type: 'disconnect', conn: 7, session: { id: '0123456789abcdef' } },
  ]);
});

test('input and window calls are CALL frames with the contract\'s bytes', async () => {
  const { link, engine, take } = await setup();
  link.cb!.onMessage(msg(feature(4, u64(SID)), connOpen(7), event(13)));
  take();
  const fx = (v: number) => Math.round(v * 256);

  engine.pointerEnter(7, 10, 1.5, 2);
  engine.pointerMotion(7, 100, 3, 4, { dx: 1, dy: 2, time: 123456 });
  engine.pointerMotion(7, 101, 5, 6, { dx: 1, dy: 1, dxUnaccel: 3, dyUnaccel: 4, time: 123999 });
  engine.pointerButton(7, 102, 0x110, true); // ships the coalesced motion first
  engine.pointerAxis(7, 103, 0, -2.5, -120);
  engine.pointerLeave(7);
  engine.pointerLockGranted(7, 10);
  engine.pointerLockLost(7);
  engine.keyboardEnter(7, 10);
  engine.key(7, 104, 30, true);
  engine.keyboardLeave(7);
  engine.keyboardLocks(false, true);
  engine.textInputPreedit(7, 'hé');
  engine.textInputCommit(7, 'ok');
  assert.equal(engine.setMaximized(7, 10, true), 1, 'the token');
  assert.equal(engine.setFullscreen(7, 10, false), 2);
  engine.setMinimized(7, 10, true);
  engine.popupDismiss(7, 12);
  engine.close(7, 10);
  engine.setVisible(7, 10, false);
  assert.equal(engine.requestResize(7, 10, 640.4, 480.6), 3);
  assert.equal(engine.setTiled(7, 10, 4 | 1, 300.2, 199.6), 4);
  assert.equal(engine.setTiled(7, 10, 0), 5);
  engine.dragMotion(7, 10, 105, 1, 2);
  engine.dragDrop();
  engine.dragCancel();
  engine.setScale(3, 300);
  engine.setOutput(800, 600);
  engine.setSuspended(false);
  assert.deepEqual(take(), [
    call(6, u32(7, 10), i32(fx(1.5), fx(2))),
    call(8, u32(7, 101), i32(fx(5), fx(6), fx(2), fx(3), fx(4), fx(6)), f64(123999)),
    call(11, u32(7, 102, 0x110, 1)),
    call(12, u32(7, 103, 0), i32(fx(-2.5), -120)),
    call(7, u32(7)),
    call(9, u32(7, 10)),
    call(10, u32(7)),
    call(13, u32(7, 10)),
    call(15, u32(7, 104, 30, 1)),
    call(14, u32(7)),
    call(16, u32(2)),
    call(17, u32(7), bytes('hé'), i32(3, 3)),
    call(18, u32(7), bytes('ok')),
    call(19, u32(7, 10, 1, 1)),
    call(20, u32(7, 10, 0, 2)),
    call(21, u32(7, 10, 1)),
    call(22, u32(7, 12)),
    call(29, u32(7, 10)),
    call(31, u32(7, 10, 0)),
    call(23, u32(7, 10), i32(640, 481), u32(3)),
    call(32, u32(7, 10, 5), i32(300, 200), u32(4)),
    call(32, u32(7, 10, 0), i32(0, 0), u32(5)),
    call(24, u32(7, 10, 105), i32(fx(1), fx(2))),
    call(25),
    call(26),
    call(3, i32(3, 300)),
    call(4, i32(800, 600)),
    call(5, u32(0)),
  ].map(hex));
});

test('clipboard: set_selection packs entries, read_selection is answered by EVENT selection_data', async () => {
  const { link, events, engine, take } = await setup();
  link.cb!.onMessage(msg(feature(4, u64(SID)), connOpen(7), event(13)));
  take();
  // the embedder's own: one CALL, true at once; the EVENT selection follows
  assert.equal(engine.setSelection({ 'text/plain': 'hi', TEXT: 'hi' }), true);
  assert.deepEqual(take(), [call(27, bytes(cat(u32(10), enc.encode('text/plain'), u32(2), enc.encode('hi'), u32(4), enc.encode('TEXT'), u32(0xffffffff))))].map(hex));
  link.cb!.onMessage(msg(event(10, u32(0), bytes('text/plain\0TEXT'))));
  assert.deepEqual(engine.selection(), { conn: 0, mimes: ['text/plain', 'TEXT'] });
  assert.deepEqual(await engine.readSelection('TEXT'), enc.encode('hi'), 'the own selection reads locally');
  assert.deepEqual(take(), []);
  // clearing it: an empty set_selection
  assert.equal(engine.setSelection(null), true);
  assert.deepEqual(take(), [call(27, bytes(new Uint8Array(0)))].map(hex));

  // an app's selection: read through the relay
  link.cb!.onMessage(msg(event(10, u32(7), bytes('text/plain'))));
  assert.equal(await engine.readSelection('image/png'), null, 'not offered: nothing asked');
  assert.deepEqual(take(), []);
  const read = engine.readSelection('text/plain', { maxBytes: 100 });
  const sent = framesOf(link.sent.splice(0));
  assert.equal(sent.length, 1);
  const dv = new DataView(sent[0].buffer, sent[0].byteOffset);
  const id = dv.getUint32(7 + 4 + 10, true);
  assert.equal(hex(sent[0]), hex(call(28, bytes('text/plain'), u32(id, 100))));
  link.cb!.onMessage(msg(event(11, u32(id, 0), bytes('pasted'))));
  assert.deepEqual(await read, enc.encode('pasted'));
  assert.ok(events.some((e) => e.type === 'selection' && e.conn === 7));
});

test('link close in session: disconnects stay local (session() null), nothing sent; the next link is passthrough unless it says session', async () => {
  const { link, events, engine, take } = await setup();
  link.cb!.onMessage(msg(feature(4, u64(SID)), connOpen(7), connOpen(8),
    surface(8, 3, { role: 1, root: 3 }), event(3, u32(8, 3, 1)), event(12, u32(1)), event(13)));
  take();
  events.length = 0;
  link.cb!.onClose({ takenOver: false });
  assert.deepEqual(events, [
    { type: 'disconnect', conn: 7, session: null },
    { type: 'disconnect', conn: 8, session: null },
    { type: 'close', takenOver: false },
  ]);
  assert.deepEqual(take(), []);
  assert.equal(engine.session(), null);

  // passthrough again: the local core answers WIRE (get_registry + sync)
  events.length = 0;
  link.cb!.onOpen();
  const getRegistry = cat(u32(1), u32((12 << 16) | 1), u32(2));
  const sync = cat(u32(1), u32((12 << 16) | 0), u32(3));
  link.cb!.onMessage(msg(connOpen(1), cat(u8(0x01), u32(1, 24)), getRegistry, sync));
  const out = framesOf(link.sent.splice(0));
  assert.ok(out.length > 0 && out.every((f) => f[0] === 0x01), 'WIRE replies from the local compositor');
  assert.equal(engine.session(), null);
  // a session FEATURE after the link's first frames is too late: ignored
  link.cb!.onMessage(msg(feature(4, u64(SID))));
  assert.equal(engine.session(), null);
  assert.ok(events.some((e: any) => e.type === 'log' && /FEATURE session after/.test(e.line)));
  link.cb!.onClose({ takenOver: false });

  // a session link again: the lock state the last session reported carries
  // over (keyboard_locks 1), as on passthrough reopens
  link.cb!.onOpen();
  take();
  link.cb!.onMessage(msg(feature(4, u64(SID + 1n))));
  assert.deepEqual(engine.session(), { id: '0123456789abcdf0' });
  const attach = take();
  assert.equal(attach[0], hex(call(1, i32(1, 120), u32(0))));
  assert.equal(attach.at(-1), hex(call(16, u32(1))));
});

test('session frames on a passthrough link are skipped, the rest of the message still processed', async () => {
  const { link, events, engine } = await setup();
  link.cb!.onMessage(msg(connOpen(5), event(13), surface(5, 1, { role: 1, root: 1 }), connClose(5)));
  assert.equal(engine.session(), null);
  assert.ok(!events.some((e) => e.type === 'synced'));
  assert.deepEqual(events.at(-1), { type: 'disconnect', conn: 5, session: null });
});

test('HANDLE_OPEN goes to the wasm\'s decoder, a COMMIT is ACKed (0x0b) on the session link', async () => {
  const { link, events, take } = await setup();
  link.cb!.onMessage(msg(feature(4, u64(SID)), connOpen(7), event(13)));
  take();
  events.length = 0;
  // a handle of an unknown kind: broken; a shm COMMIT naming it: ACKed unpresented
  const commit = cat(u8(0x0a), u32(7, 10, 1, 1, 1, 24), u32(5, 0, 2, 2, 8, 0), i32(0, 0, 2, 2));
  link.cb!.onMessage(msg(cat(u8(0x08), u32(7, 5, 9, 0)), commit));
  assert.ok(events.some((e) => e.type === 'error' && /buffer handle 5 \(conn 7\)/.test(e.detail)), JSON.stringify(events));
  assert.ok(!events.some((e) => e.type === 'commit'));
  assert.deepEqual(take(), [hex(cat(u8(0x0b), u32(7, 1)))]);
});

// --- window places across a reload (wm.ts on the fake DOM) -----------------
type Ev = Parameters<ReturnType<typeof createView>['handle']>[0];
function memoryStorage() {
  const m = new Map<string, string>();
  return {
    map: m,
    get length() { return m.size; },
    key: (i: number) => [...m.keys()][i] ?? null,
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => { m.set(k, String(v)); },
    removeItem: (k: string) => { m.delete(k); },
    clear: () => m.clear(),
  };
}
// a page: view + input + wm on an engine whose session() the test sets
function page(dom: ReturnType<typeof installFakeDom>, state: { session: { id: string } | null }) {
  const container = dom.container();
  const view = createView({ container, webgl: 'never' });
  const calls: unknown[][] = [];
  const engine = new Proxy({} as Engine, {
    get: (_, name) => name === 'session' ? () => state.session : (...args: unknown[]) => { calls.push([name, ...args]); },
  });
  const input = createInput({ engine, view, container });
  const wm = createWindowManager({ engine, view, input, container });
  const feed = (ev: Ev) => { view.handle(ev); input.handle(ev); wm.handle(ev); };
  const commit = (conn: number, surface: number, st: { maximized?: boolean } = {}) => feed({
    type: 'commit', conn, surface, role: 1, root: surface, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false, ...st,
    geometry: { x: 0, y: 0, width: 40, height: 30 }, width: 40, height: 30, logicalWidth: 40, logicalHeight: 30, format: 'rgba', stride: 0,
    damage: new Int32Array(0), pixels: new Uint8Array(0),
  });
  const el = (conn: number, surface: number) => view.window(conn, surface)!.element as any;
  const pos = (conn: number, surface: number) => [el(conn, surface).style.left, el(conn, surface).style.top];
  const z = (conn: number, surface: number) => Number(el(conn, surface).style.zIndex);
  return { view, input, wm, calls, feed, commit, el, pos, z, dispose() { wm.dispose(); input.dispose(); view.dispose(); } };
}
const tick = () => new Promise((res) => setTimeout(res, 0));

test('session: window positions and stacking survive a reload (sessionStorage by session id, conn, surface); states are not kept; a real disconnect drops them, a closing link does not', async () => {
  const dom = installFakeDom();
  const storage = memoryStorage();
  (globalThis as any).sessionStorage = storage;
  try {
    const state: { session: { id: string } | null } = { session: { id: 's1' } };
    let p = page(dom, state);
    p.commit(1, 5);
    p.commit(2, 5);
    p.feed({ type: 'synced' });
    assert.deepEqual(JSON.parse(storage.getItem('wland.win:s1:1:5')!), { x: 24, y: 48, z: p.z(1, 5) });
    // the user moves window 1 and raises it; window 2 is maximized
    p.el(1, 5).style.left = '300px';
    p.el(1, 5).style.top = '200px';
    p.view.raise(1, 5);
    dom.document.dispatch('pointerup', { pointerId: 1 });
    p.feed({ type: 'maximize', conn: 2, surface: 5, maximized: true });
    assert.deepEqual(p.pos(2, 5), ['0px', '0px']);
    await tick();
    assert.deepEqual(JSON.parse(storage.getItem('wland.win:s1:1:5')!), { x: 300, y: 200, z: p.z(1, 5) });
    assert.deepEqual(JSON.parse(storage.getItem('wland.win:s1:2:5')!), { x: 64, y: 84, z: p.z(2, 5) }, 'the floating position, not the snap');
    storage.setItem('wland.win:old:1:5', '{"x":1,"y":1,"z":1}'); // an earlier relay run's
    p.dispose();

    // the reload: the scene comes again (window 2 maximized before it maps)
    p = page(dom, state);
    p.feed({ type: 'maximize', conn: 2, surface: 5, maximized: true });
    p.commit(2, 5, { maximized: true });
    p.commit(1, 5);
    assert.ok(p.z(1, 5) > p.z(2, 5));
    p.view.raise(2, 5); // replay order is not the stacking
    p.calls.length = 0;
    p.feed({ type: 'synced' });
    assert.deepEqual(p.pos(1, 5), ['300px', '200px']);
    assert.deepEqual(p.pos(2, 5), ['0px', '0px'], 'maximized: the relay\'s state');
    assert.ok(p.z(1, 5) > p.z(2, 5), 'the saved stacking');
    assert.ok(p.input.focused(1, 5), 'the top window has the keyboard');
    assert.equal(storage.getItem('wland.win:old:1:5'), null, 'other sessions\' places dropped');
    p.feed({ type: 'maximize', conn: 2, surface: 5, maximized: false });
    assert.deepEqual(p.pos(2, 5), ['64px', '84px'], 'unmaximized: back to the saved floating position');

    // a window mapped after the scene (sid known): placed at its first commit
    storage.setItem('wland.win:s1:3:7', '{"x":111,"y":222,"z":0}');
    p.commit(3, 7);
    assert.deepEqual(p.pos(3, 7), ['111px', '222px']);

    // an app that really goes: its places go; a closing link's disconnects
    // (session() null) keep them
    p.feed({ type: 'disconnect', conn: 3 });
    assert.equal(storage.getItem('wland.win:s1:3:7'), null);
    state.session = null;
    p.feed({ type: 'disconnect', conn: 1 });
    p.feed({ type: 'disconnect', conn: 2 });
    p.feed({ type: 'close', takenOver: false });
    assert.ok(storage.getItem('wland.win:s1:1:5'));
    assert.ok(storage.getItem('wland.win:s1:2:5'));
    p.dispose();
    await tick();
  } finally {
    delete (globalThis as any).sessionStorage;
    dom.uninstall();
  }
});

test('passthrough: the wm keeps nothing in sessionStorage', async () => {
  const dom = installFakeDom();
  const storage = memoryStorage();
  (globalThis as any).sessionStorage = storage;
  try {
    const p = page(dom, { session: null });
    p.commit(1, 5);
    dom.document.dispatch('pointerup', { pointerId: 1 });
    p.feed({ type: 'maximize', conn: 1, surface: 5, maximized: true });
    p.feed({ type: 'disconnect', conn: 1 });
    await tick();
    assert.equal(storage.length, 0);
    p.dispose();
    await tick();
  } finally {
    delete (globalThis as any).sessionStorage;
    dom.uninstall();
  }
});

test('reconnecting(): starts the link again after a close while wanted (backing off, reset by an open), never after a takeover or close()', () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    let starts = 0, closes = 0;
    let inner: LinkCallbacks | null = null;
    const link = reconnecting({
      start: (cb) => { starts++; inner = cb; },
      send: () => {},
      bufferedAmount: 0,
      close: () => { closes++; },
    }, () => wanted);
    let wanted = true;
    const seen: string[] = [];
    link.start({ onOpen: () => seen.push('open'), onMessage: () => {}, onError: () => {}, onClose: (i) => seen.push(`close ${i.takenOver}`) });
    assert.equal(starts, 1);
    inner!.onOpen();
    inner!.onClose({ takenOver: false });
    mock.timers.tick(499);
    assert.equal(starts, 1);
    mock.timers.tick(1);
    assert.equal(starts, 2, 'again after 0.5 s');
    inner!.onClose({ takenOver: false }); // a failed attempt: no open
    mock.timers.tick(999);
    assert.equal(starts, 2);
    mock.timers.tick(1);
    assert.equal(starts, 3, 'then after 1 s');
    inner!.onOpen(); // reset
    inner!.onClose({ takenOver: false });
    mock.timers.tick(500);
    assert.equal(starts, 4);
    inner!.onOpen();
    inner!.onClose({ takenOver: true });
    mock.timers.tick(20_000);
    assert.equal(starts, 4, 'not after a takeover');
    link.start({ onOpen: () => seen.push('open'), onMessage: () => {}, onError: () => {}, onClose: (i) => seen.push(`close ${i.takenOver}`) });
    assert.equal(starts, 5);
    wanted = false;
    inner!.onClose({ takenOver: false });
    mock.timers.tick(20_000);
    assert.equal(starts, 5, 'not when not wanted (a passthrough link)');
    wanted = true;
    inner!.onClose({ takenOver: false });
    link.close();
    mock.timers.tick(20_000);
    assert.equal(starts, 5, 'not after close()');
    assert.equal(closes, 1);
    assert.deepEqual(seen.slice(0, 3), ['open', 'close false', 'close false']);
  } finally {
    mock.timers.reset();
  }
});
