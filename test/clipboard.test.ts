// The clipboard bridge, both halves without a browser: the engine's
// selection API against the real core over a scripted link (STREAM frames
// in and out: FEATURE selection_cache first, FDMSG pipe_read to read an
// app's selection, FDMSG own_pipe to answer a receive of the embedder's
// own; without the FEATURE — wlandr 0.1.0 — none of it), and the page side
// (lib/clipboard.ts + input's chord handling) on the fake DOM with a fake
// engine and a fake navigator.clipboard. Needs a prior `zig build`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { installFakeDom } from './fake-dom.ts';
import { createEngine, NO_SELECTION_BRIDGE, readSelectionText, setSelectionText, TEXT_MIMES, type Engine, type Link, type LinkCallbacks } from '../lib/engine.ts';
import { createView } from '../lib/view.ts';
import { createInput } from '../lib/input.ts';
import { createClipboardBridge } from '../lib/clipboard.ts';
import { createWland } from '../lib/client.ts';

const wasm = await readFile(new URL('../lib/wland.wasm', import.meta.url));

// --- STREAM frames + wayland wire ------------------------------------------
const CONN = 7;
const enc = new TextEncoder(), dec = new TextDecoder();
const u32s = (...v: number[]) => new Uint8Array(new Uint32Array(v).buffer);
const cat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
};
const frame = (type: number, ...parts: Uint8Array[]) => cat(new Uint8Array([type]), ...parts);
const connOpen = (conn: number) => frame(3, u32s(conn));
const wireFrame = (conn: number, bytes: Uint8Array) => frame(1, u32s(conn, bytes.length), bytes);
const fdmsg = (conn: number, kind: number, wire: Uint8Array, aux: Uint8Array) =>
  frame(5, u32s(conn, kind, wire.length), wire, u32s(aux.length), aux);
/** FEATURE selection_cache (0x0c, kind 3, no bytes): first on a link from a
 *  relay that bridges the clipboard. */
const selectionCache = () => frame(0x0c, u32s(3, 0));
function wlString(s: string) {
  const b = enc.encode(s);
  const padded = new Uint8Array(4 + ((b.length + 1 + 3) & ~3));
  new DataView(padded.buffer).setUint32(0, b.length + 1, true);
  padded.set(b, 4);
  return padded;
}
function msg(object: number, opcode: number, ...args: (number | string)[]) {
  const body = args.map((a) => (typeof a === 'string' ? wlString(a) : u32s(a)));
  const size = 8 + body.reduce((n, b) => n + b.length, 0);
  return cat(u32s(object, (size << 16) | opcode), ...body);
}
const pack = (...frames: Uint8Array[]) => cat(...frames).buffer;

type ScriptedLink = Link & { sent: Uint8Array[]; cb: LinkCallbacks | null };
function scriptedLink(): ScriptedLink {
  const link: ScriptedLink = { sent: [], bufferedAmount: 0, cb: null, start: (cb) => { link.cb = cb; }, send: (b) => { link.sent.push(b); } };
  return link;
}

// every frame the engine sent: WIRE events (conn, object, opcode, args as
// raw bytes) and FDMSGs
type Out = { type: 'wire'; conn: number; object: number; opcode: number; body: Uint8Array }
  | { type: 'fdmsg'; conn: number; kind: number; wire: Uint8Array; aux: Uint8Array };
function sentFrames(sent: Uint8Array[]): Out[] {
  const out: Out[] = [];
  for (const bytes of sent) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let off = 0; off < bytes.length;) {
      const t = bytes[off];
      if (t === 1) {
        const conn = dv.getUint32(off + 1, true), len = dv.getUint32(off + 5, true);
        for (let m = off + 9; m < off + 9 + len;) {
          const word = dv.getUint32(m + 4, true), size = word >>> 16;
          out.push({ type: 'wire', conn, object: dv.getUint32(m, true), opcode: word & 0xffff, body: bytes.slice(m + 8, m + size) });
          m += size;
        }
        off += 9 + len;
      } else if (t === 5) {
        const conn = dv.getUint32(off + 1, true), kind = dv.getUint32(off + 5, true), wl = dv.getUint32(off + 9, true);
        const al = dv.getUint32(off + 13 + wl, true);
        out.push({ type: 'fdmsg', conn, kind, wire: bytes.slice(off + 13, off + 13 + wl), aux: bytes.slice(off + 17 + wl, off + 17 + wl + al) });
        off += 17 + wl + al;
      } else if (t === 6) off += 13; // SRVOBJ
      else break;
    }
  }
  return out;
}
function globals(sent: Uint8Array[]) {
  const found: Record<string, number> = {};
  for (const f of sentFrames(sent)) {
    if (f.type !== 'wire' || f.object !== 2 || f.opcode !== 0) continue;
    const dv = new DataView(f.body.buffer);
    const slen = dv.getUint32(4, true);
    found[dec.decode(f.body.subarray(8, 8 + slen - 1))] = dv.getUint32(0, true);
  }
  return found;
}
const u32At = (b: Uint8Array, at: number) => new DataView(b.buffer, b.byteOffset).getUint32(at, true);

// wl_data_device_manager 3: create_data_source 0, get_data_device 1;
// wl_data_source: offer 0 (events: send 1, cancelled 2); wl_data_device:
// set_selection 1 (events: data_offer 0, selection 5); wl_data_offer:
// receive 1 (event: offer 0)
const SOURCE = 12, DEVICE = 13, DDM = 10, KB = 11;

/** An engine with one app (conn CONN): a toplevel (surface 6), a keyboard,
 *  a data device; `copy` makes it own the clipboard with those types.
 *  `bridge` false: the relay sends no FEATURE selection_cache (0.1.0). */
async function setup(copy?: string[], bridge = true) {
  const link = scriptedLink();
  const events: any[] = [];
  const logs: string[] = [];
  const engine = await createEngine({ wasm, link, onEvent: (ev) => { if (ev.type !== 'log') events.push(ev); else logs.push(ev.line); } });
  engine.start();
  link.cb!.onOpen();
  link.cb!.onMessage(pack(...(bridge ? [selectionCache()] : []), connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
  const g = globals(link.sent);
  link.cb!.onMessage(pack(wireFrame(CONN, cat(
    msg(2, 0, g.wl_compositor, 'wl_compositor', 4, 4),
    msg(2, 0, g.xdg_wm_base, 'xdg_wm_base', 1, 5),
    msg(2, 0, g.wl_seat, 'wl_seat', 5, 9),
    msg(2, 0, g.wl_data_device_manager, 'wl_data_device_manager', 3, DDM),
    msg(4, 0, 6), msg(5, 2, 7, 6), msg(7, 1, 8), msg(9, 1, KB),
    msg(DDM, 1, DEVICE, 9),
  ))));
  if (copy) {
    // copied while it holds keyboard focus (the core ignores a background
    // client's set_selection), which goes again after
    engine.keyboardEnter(CONN, 6);
    link.cb!.onMessage(pack(wireFrame(CONN, cat(
      msg(DDM, 0, SOURCE), ...copy.map((m) => msg(SOURCE, 0, m)), msg(DEVICE, 1, SOURCE, 0),
    ))));
    engine.keyboardLeave(CONN);
  }
  link.sent.length = 0;
  return { link, events, logs, engine };
}

test('engine: an app\'s selection is a selection event; readSelection asks its source through a pipe_read and resolves the relay\'s answer', async () => {
  const { link, events, engine } = await setup(['text/plain;charset=utf-8', 'text/plain']);
  assert.deepEqual(events.filter((e) => e.type === 'selection'), [{ type: 'selection', conn: CONN, mimes: ['text/plain;charset=utf-8', 'text/plain'] }]);
  assert.deepEqual(engine.selection(), { conn: CONN, mimes: ['text/plain;charset=utf-8', 'text/plain'] });

  const p = readSelectionText(engine, { maxBytes: 100 });
  const asks = sentFrames(link.sent.splice(0)).filter((f) => f.type === 'fdmsg') as Extract<Out, { type: 'fdmsg' }>[];
  assert.equal(asks.length, 1);
  assert.equal(asks[0].conn, CONN);
  assert.equal(asks[0].kind, 5, 'FDMSG pipe_read');
  assert.equal(u32At(asks[0].wire, 0), SOURCE, 'wl_data_source.send on the source');
  assert.equal(u32At(asks[0].wire, 4) & 0xffff, 1);
  assert.equal(dec.decode(asks[0].wire.subarray(12, 12 + 'text/plain;charset=utf-8'.length)), 'text/plain;charset=utf-8', 'the best text type');
  const id = u32At(asks[0].aux, 0);
  assert.equal(u32At(asks[0].aux, 4), 100, 'max bytes');
  link.cb!.onMessage(pack(fdmsg(CONN, 5, new Uint8Array(0), cat(u32s(id, 0), enc.encode('héllo wayland')))));
  assert.equal(await p, 'héllo wayland');

  // too large / failed: null; no answer: null at the timeout
  const big = engine.readSelection('text/plain');
  const id2 = u32At((sentFrames(link.sent.splice(0))[0] as any).aux, 0);
  link.cb!.onMessage(pack(fdmsg(CONN, 5, new Uint8Array(0), u32s(id2, 1))));
  assert.equal(await big, null);
  assert.equal(await engine.readSelection('text/plain', { timeout: 5 }), null);
  link.sent.length = 0;
  // a type it does not offer: nothing is asked
  assert.equal(await engine.readSelection('image/png'), null);
  assert.equal(link.sent.length, 0);

  // the link closes: pending reads resolve null, the clipboard is empty
  const pending = engine.readSelection('text/plain');
  events.length = 0;
  link.cb!.onClose({ takenOver: false });
  assert.equal(await pending, null);
  assert.deepEqual(events.filter((e) => e.type === 'selection'), [{ type: 'selection', conn: 0, mimes: [] }]);
  assert.equal(engine.setSelection({ 'text/plain': 'x' }), false, 'no link: not set');
});

test('engine: setSelection makes the embedder\'s own selection — the app\'s source is cancelled, the focused app is offered it and its receive is answered with the bytes', async () => {
  const { link, events, engine } = await setup(['text/plain']);
  engine.keyboardEnter(CONN, 6);
  link.sent.length = 0;
  events.length = 0;

  assert.equal(setSelectionText(engine, 'from the page ✓'), true);
  assert.deepEqual(events, [{ type: 'selection', conn: 0, mimes: [...TEXT_MIMES] }]);
  const out = sentFrames(link.sent.splice(0)) as Extract<Out, { type: 'wire' }>[];
  assert.ok(out.some((f) => f.object === SOURCE && f.opcode === 2), 'the app\'s source is cancelled');
  const offer = u32At(out.find((f) => f.object === DEVICE && f.opcode === 0)!.body, 0);
  assert.ok(offer >= 0xff000000);
  assert.deepEqual(out.filter((f) => f.object === offer && f.opcode === 0).map((f) => dec.decode(f.body.subarray(4, 4 + u32At(f.body, 0) - 1))), [...TEXT_MIMES]);
  assert.equal(u32At(out.find((f) => f.object === DEVICE && f.opcode === 5)!.body, 0), offer);

  // the app's receive(mime, fd) reaches the engine as FDMSG pipe (token 99):
  // the answer is an FDMSG own_pipe (no wire message; token, generation,
  // payload, flags 1 = the bytes follow, the first time on the link)
  link.cb!.onMessage(pack(fdmsg(CONN, 3, msg(offer, 1, 'UTF8_STRING'), u32s(99))));
  const ans = sentFrames(link.sent.splice(0)).filter((f) => f.type === 'fdmsg') as Extract<Out, { type: 'fdmsg' }>[];
  assert.equal(ans.length, 1);
  assert.equal(ans[0].kind, 6);
  assert.equal(ans[0].conn, CONN);
  assert.equal(ans[0].wire.length, 0);
  assert.equal(u32At(ans[0].aux, 0), 99);
  assert.equal(u32At(ans[0].aux, 8), 0, 'payload 0');
  assert.equal(u32At(ans[0].aux, 12), 1, 'with its bytes');
  assert.equal(dec.decode(ans[0].aux.subarray(16)), 'from the page ✓');
  // its own selection reads back without the relay
  assert.equal(await readSelectionText(engine), 'from the page ✓');
  assert.equal(link.sent.length, 0);

  // cleared by the embedder: the app hears selection(null)
  events.length = 0;
  assert.equal(engine.setSelection(null), true);
  assert.deepEqual(events, [{ type: 'selection', conn: 0, mimes: [] }]);
  const cleared = sentFrames(link.sent.splice(0)) as Extract<Out, { type: 'wire' }>[];
  assert.equal(u32At(cleared.find((f) => f.object === DEVICE && f.opcode === 5)!.body, 0), 0);
  // refused: nothing set, nothing sent
  assert.equal(engine.setSelection({}), false);
  assert.equal(engine.setSelection({ ['x'.repeat(300)]: 'a' }), false);
  assert.deepEqual(engine.selection(), { conn: 0, mimes: [] });
});

test('engine: a relay without FEATURE selection_cache (wlandr 0.1.0) — selectionBridged() false, setSelection sets nothing (logged once), readSelection rejects at once; no pipe_read goes out and no app is offered an embedder selection', async () => {
  const { link, events, logs, engine } = await setup(['text/plain'], false);
  assert.equal(engine.selectionBridged(), false);
  // apps' selections are still reported (app → app works through the relay)
  assert.deepEqual(engine.selection(), { conn: CONN, mimes: ['text/plain'] });
  const t0 = Date.now();
  await assert.rejects(engine.readSelection('text/plain'), { message: NO_SELECTION_BRIDGE });
  await assert.rejects(readSelectionText(engine), { message: NO_SELECTION_BRIDGE });
  assert.ok(Date.now() - t0 < 1000, 'promptly, not at a timeout');
  engine.keyboardEnter(CONN, 6);
  link.sent.length = 0;
  events.length = 0;
  assert.equal(setSelectionText(engine, 'from the page'), false);
  assert.equal(engine.setSelection(null), false);
  assert.equal(setSelectionText(engine, 'again'), false);
  assert.deepEqual(events.filter((e) => e.type === 'selection'), [], 'unchanged: still the app\'s');
  assert.deepEqual(engine.selection(), { conn: CONN, mimes: ['text/plain'] });
  const out = sentFrames(link.sent.splice(0));
  assert.equal(out.filter((f) => f.type === 'fdmsg').length, 0, 'no FDMSG (pipe_read, own_pipe or pipe with bytes)');
  assert.equal(out.filter((f) => f.type === 'wire' && (f.object === SOURCE || f.object === DEVICE)).length, 0, 'no cancel, no offer');
  assert.deepEqual(logs.filter((l) => l.includes(NO_SELECTION_BRIDGE)).length, 1, 'logged once');

  // the next link's relay has it: decided again
  link.cb!.onClose({ takenOver: false });
  link.cb!.onOpen();
  assert.equal(engine.selectionBridged(), null, 'not known before its first message');
  assert.equal(setSelectionText(engine, 'early'), false);
  link.cb!.onMessage(pack(selectionCache()));
  assert.equal(engine.selectionBridged(), true, 'its FEATURE says so at once');
  assert.equal(setSelectionText(engine, 'now'), true);
  assert.equal(logs.filter((l) => l.includes(NO_SELECTION_BRIDGE)).length, 1);
});

test('engine: an unfocused app is never offered the embedder\'s selection', async () => {
  const { link, engine } = await setup();
  assert.equal(setSelectionText(engine, 'secret'), true);
  const out = sentFrames(link.sent.splice(0)) as Extract<Out, { type: 'wire' }>[];
  assert.equal(out.filter((f) => f.object === DEVICE).length, 0);
  engine.keyboardEnter(CONN, 6); // focus: now it is
  assert.ok((sentFrames(link.sent.splice(0)) as Extract<Out, { type: 'wire' }>[]).some((f) => f.object === DEVICE && f.opcode === 5));
});

test('engine: an app clearing its selection (set_selection(null)) is reported with its conn and no types; its source going is conn 0', async () => {
  const { link, events, engine } = await setup();
  engine.keyboardEnter(CONN, 6);
  // the enter's serial (wl_keyboard.enter: serial, surface, keys)
  const enter = (sentFrames(link.sent.splice(0)) as Extract<Out, { type: 'wire' }>[]).find((f) => f.type === 'wire' && f.object === KB && f.opcode === 1)!;
  const serial = u32At(enter.body, 0);
  const own = () => events.filter((e) => e.type === 'selection');
  // wl_data_source.destroy = 1
  link.cb!.onMessage(pack(wireFrame(CONN, cat(msg(DDM, 0, SOURCE), msg(SOURCE, 0, 'text/plain'), msg(DEVICE, 1, SOURCE, serial)))));
  assert.deepEqual(own(), [{ type: 'selection', conn: CONN, mimes: ['text/plain'] }]);
  events.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, msg(DEVICE, 1, 0, serial))));
  assert.deepEqual(own(), [{ type: 'selection', conn: CONN, mimes: [] }], 'cleared by the app');
  assert.deepEqual(engine.selection(), { conn: CONN, mimes: [] });
  assert.equal(await readSelectionText(engine), null);
  events.length = 0;
  link.cb!.onMessage(pack(wireFrame(CONN, cat(msg(DDM, 0, SOURCE + 10), msg(SOURCE + 10, 0, 'text/plain'), msg(DEVICE, 1, SOURCE + 10, serial), msg(SOURCE + 10, 1)))));
  assert.deepEqual(own(), [{ type: 'selection', conn: CONN, mimes: ['text/plain'] }, { type: 'selection', conn: 0, mimes: [] }], 'its source destroyed: the owner went');
});

// --- the page side ----------------------------------------------------------

type FakeClipboard = { text: string; writes: string[]; reads: number; refuse: string | null };
function fakeNavigator(permission: string | 'throws' = 'prompt') {
  const clip: FakeClipboard = { text: '', writes: [], reads: 0, refuse: null };
  const nav = globalThis.navigator as any;
  Object.defineProperty(nav, 'clipboard', {
    configurable: true,
    value: {
      writeText(t: string) {
        if (clip.refuse) return Promise.reject(Object.assign(new Error('no'), { name: clip.refuse }));
        clip.writes.push(t);
        clip.text = t;
        return Promise.resolve();
      },
      readText() { clip.reads++; return Promise.resolve(clip.text); },
    },
  });
  Object.defineProperty(nav, 'permissions', {
    configurable: true,
    value: {
      query: () => {
        if (permission === 'throws') throw new TypeError('clipboard-read is not a valid permission name');
        return Promise.resolve({ state: permission });
      },
    },
  });
  return { clip, restore: () => { delete nav.clipboard; delete nav.permissions; } };
}

/** A fake engine recording what the page side asks of it, in order.
 *  `relay.bridges`: what selectionBridged() says (its relay's FEATURE
 *  selection_cache); `relay.reads`: readSelection calls. */
function fakeEngine(appText: Record<number, string> = {}, recordLocks = false) {
  const calls: any[] = [];
  let sel = { conn: 0, mimes: [] as string[] };
  const relay = { bridges: true as boolean | null, reads: 0 };
  const engine = new Proxy({} as Engine, {
    get: (_, name) => {
      if (name === 'selection') return () => sel;
      if (name === 'selectionBridged') return () => relay.bridges;
      if (name === 'setSelection') return (data: Record<string, string> | null) => {
        calls.push(['setSelection', data ? data['text/plain;charset=utf-8'] : null]);
        sel = { conn: 0, mimes: data ? Object.keys(data) : [] };
        return true;
      };
      if (name === 'readSelection') return () => { relay.reads++; return Promise.resolve(appText[sel.conn] != null ? enc.encode(appText[sel.conn]) : null); };
      if (name === 'keyboardLocks') return (...args: unknown[]) => { if (recordLocks) calls.push(['keyboardLocks', ...args]); };
      return (...args: unknown[]) => { calls.push([name, ...args]); };
    },
  });
  return { engine, calls, relay, setApp: (conn: number, mimes: string[]) => { sel = { conn, mimes }; } };
}

const settle = () => new Promise((r) => setTimeout(r, 0));

function pageSetup(appText: Record<number, string> = {}, permission: string | 'throws' = 'prompt',
  opts: { platform?: string; recordLocks?: boolean; clipboard?: boolean } = {}) {
  const dom = installFakeDom();
  const nav = fakeNavigator(permission);
  const g = globalThis.navigator as any;
  if (opts.platform !== undefined) Object.defineProperty(g, 'platform', { configurable: true, value: opts.platform });
  const container = dom.container();
  const fe = fakeEngine(appText, opts.recordLocks);
  const view = createView({ container, webgl: 'never' });
  const logs: string[] = [];
  const bridge = createClipboardBridge({ engine: fe.engine, container, log: (l) => logs.push(l) });
  const input = createInput({ engine: fe.engine, view, container, clipboard: opts.clipboard === false ? undefined : bridge.hooks });
  const sink = container.children.find((c: any) => c.contentEditable === 'true');
  input.focus(3, 6);
  fe.calls.length = 0;
  const keyEv = (code: string, mods: Record<string, unknown> = {}) => {
    const ev = { code, ctrlKey: false, metaKey: false, shiftKey: false, altKey: false, isComposing: false, keyCode: 0, ...mods, prevented: false,
      preventDefault() { ev.prevented = true; }, getModifierState: (mods.getModifierState as (k: string) => boolean) || (() => false) };
    return ev;
  };
  // the app at conn `conn` set the clipboard to `mimes`
  const appCopies = (conn: number, mimes = ['text/plain;charset=utf-8']) => {
    fe.setApp(conn, mimes);
    bridge.handle({ type: 'selection', conn, mimes });
  };
  // `types`: what the page clipboard holds (default: text/plain when there is text)
  const paste = (text: string, types: string[] = text ? ['text/plain'] : []) => {
    const ev = { clipboardData: { getData: (t: string) => (t === 'text/plain' ? text : ''), types }, prevented: false, preventDefault() { ev.prevented = true; } };
    dom.document.dispatch('paste', ev); // (Firefox targets the body: input listens on the document)
    return ev;
  };
  const copy = () => {
    const data: Record<string, string> = {};
    const ev = { clipboardData: { setData: (t: string, v: string) => { data[t] = v; } }, data, prevented: false, preventDefault() { ev.prevented = true; } };
    dom.document.dispatch('copy', ev);
    return ev;
  };
  const done = () => {
    input.dispose(); bridge.dispose(); view.dispose(); nav.restore(); dom.uninstall();
    if (opts.platform !== undefined) delete g.platform;
  };
  return { dom, sink, input, bridge, ...fe, clip: nav.clip, keyEv, appCopies, paste, copy, logs, done, container };
}

test('page → app: a paste chord keeps its default, the paste event\'s text becomes the selection before the chord\'s press reaches the app', async () => {
  const t = pageSetup();
  try {
    const down = t.keyEv('KeyV', { ctrlKey: true });
    t.sink.dispatch('keydown', down);
    assert.equal(down.prevented, false, 'the browser\'s paste must happen');
    assert.deepEqual(t.calls.filter((c) => c[0] === 'key'), [], 'the press is held');
    const ev = t.paste('copied outside');
    assert.equal(ev.prevented, true, 'nothing lands in the sink');
    assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? ['key', c[1], c[3], c[4]] : c),
      [['setSelection', 'copied outside'], ['key', 3, 47, true]], 'selection first, then the press');
    // the same text again: the page clipboard has not changed, nothing is set
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('copied outside');
    assert.deepEqual(t.calls.map((c) => c[0]), ['key']);
    // Shift+Insert is a paste chord too
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('Insert', { shiftKey: true }));
    t.paste('newer outside');
    assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? c[3] : c[1]), ['newer outside', 110]);
  } finally { t.done(); }
});

test('page → app: the keys wait for a late paste event (Firefox: after the keyup); with none at all (refused) they go 300 ms later, nothing set', async () => {
  const t = pageSetup();
  try {
    // Firefox: the paste event comes after the chord's keyup
    t.sink.dispatch('keydown', t.keyEv('ControlLeft', { ctrlKey: true }));
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.sink.dispatch('keyup', t.keyEv('KeyV', { ctrlKey: true }));
    t.sink.dispatch('keyup', t.keyEv('ControlLeft'));
    assert.equal(t.calls.length, 0, 'queued');
    await settle();
    assert.equal(t.calls.length, 0, 'still queued past the task');
    t.paste('late paste');
    assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? [c[3], c[4]] : c[1]), ['late paste', [47, true], [47, false], [29, false]]);
    // refused: no paste event; the keys go in order at the timeout
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.sink.dispatch('keyup', t.keyEv('KeyV', { ctrlKey: true }));
    await new Promise((r) => setTimeout(r, 350));
    assert.deepEqual(t.calls.map((c) => [c[0], c[3], c[4]]), [['key', 47, true], ['key', 47, false]]);
    // plain keys are still prevented and sent at once
    t.calls.length = 0;
    const a = t.keyEv('KeyA');
    t.sink.dispatch('keydown', a);
    assert.equal(a.prevented, true);
    assert.equal(t.calls.length, 1);
    // a focus change flushes what is queued first, to the conn it was typed
    // into, then lets go of what is held there (the A above, the V)
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.input.focus(9, 6);
    assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? [c[0], c[1], c[3], c[4]] : [c[0], c[1]]),
      [['key', 3, 47, true], ['key', 3, 30, false], ['key', 3, 47, false], ['keyboardLeave', 3], ['keyboardEnter', 9]]);
  } finally { t.done(); }
});

test('app → page: an app\'s selection is written right after a gesture in the desktop; its own write never comes back as a paste', async () => {
  const t = pageSetup({ 4: 'from foot' });
  try {
    const c = t.keyEv('KeyC', { ctrlKey: true, shiftKey: true }); // foot's copy: a gesture
    t.sink.dispatch('keydown', c);
    assert.equal(c.prevented, true, 'Ctrl+Shift+C is no browser copy chord: a plain key');
    t.appCopies(4);
    await settle();
    assert.deepEqual(t.clip.writes, ['from foot']);
    // pasting it back inside the desktop: the Wayland clipboard keeps the app's source
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('from foot');
    assert.deepEqual(t.calls.map((c) => c[0]), ['key']);
    // nothing owed: a copy event sets nothing (cancelled: the page's selection is not copied)
    const ev = t.copy();
    assert.deepEqual(ev.data, {});
    assert.equal(ev.prevented, true);
    // an app without text in its selection: nothing written
    t.appCopies(5, ['image/png']);
    await settle();
    assert.deepEqual(t.clip.writes, ['from foot']);
  } finally { t.done(); }
});

test('app → page: no recent gesture, or a refused write: owed until the next key/click (writeText) or copy event (setData)', async () => {
  const t = pageSetup({ 4: 'background copy', 5: 'refused copy' });
  try {
    t.appCopies(4); // no gesture yet (wl-copy from a script)
    await settle();
    assert.deepEqual(t.clip.writes, [], 'a background copy does not touch the page clipboard');
    t.sink.dispatch('keydown', t.keyEv('KeyA')); // the user comes back
    await settle();
    assert.deepEqual(t.clip.writes, ['background copy']);

    t.clip.refuse = 'NotAllowedError'; // Safari, Firefox past its activation
    t.appCopies(5);
    await settle();
    assert.deepEqual(t.clip.writes, ['background copy']);
    assert.equal(t.logs.filter((l) => l.includes('refused')).length, 1, 'logged once, nothing thrown');
    const ev = t.copy(); // Ctrl+C on the desktop: the event carries it
    assert.equal(ev.prevented, true);
    assert.deepEqual(ev.data, { 'text/plain': 'refused copy' });
    assert.deepEqual(t.copy().data, {}, 'written: nothing owed any more');
  } finally { t.done(); }
});

test('page → app never steals a newer app selection the page could not get; once the desktop lost focus, the page\'s text wins', async () => {
  const t = pageSetup({ 4: 'app is newer' });
  try {
    t.clip.refuse = 'NotAllowedError';
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('older page text');
    assert.deepEqual(t.calls.map((c) => c[0]), ['key'], 'the app\'s selection stays');
    // the user went elsewhere (and may have copied there)
    (globalThis as any).window.dispatch('blur');
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('copied elsewhere');
    assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? 'key' : c[1]), ['copied elsewhere', 'key']);
  } finally { t.done(); }
});

test('page → app on focus: readText only when clipboard-read is already granted; a browser without the permission name is fine', async () => {
  for (const permission of ['prompt', 'denied', 'throws', 'granted']) {
    const t = pageSetup({}, permission);
    try {
      t.clip.text = 'outside text';
      (globalThis as any).document.body.focus(); // leave the desktop…
      await settle();
      t.clip.reads = 0;                          // (the setup's own focus read once, if granted)
      t.input.focus(3, 6);                       // …and come back
      await settle();
      if (permission === 'granted') {
        assert.equal(t.clip.reads, 1);
        assert.deepEqual(t.calls.filter((c) => c[0] === 'setSelection'), [['setSelection', 'outside text']]);
      } else {
        assert.equal(t.clip.reads, 0, permission);
        assert.equal(t.calls.filter((c) => c[0] === 'setSelection').length, 0);
      }
    } finally { t.done(); }
  }
});

test('page → app: text over the size bound is not pasted (logged)', async () => {
  const t = pageSetup();
  try {
    const fe = fakeEngine();
    const bridge = createClipboardBridge({ engine: fe.engine, container: t.container, maxBytes: 8, log: (l) => t.logs.push(l) });
    bridge.hooks.paste({ getData: () => 'ninebytes' } as unknown as DataTransfer);
    assert.equal(fe.calls.length, 0);
    assert.ok(t.logs.some((l) => l.includes('over 8 bytes')));
    bridge.hooks.paste({ getData: () => 'eight b!' } as unknown as DataTransfer);
    assert.deepEqual(fe.calls, [['setSelection', 'eight b!']]);
    bridge.dispose();
  } finally { t.done(); }
});

test('createWland: the bridge is on by default (paste chord held for its paste event), inert in front of a relay without FEATURE selection_cache (a plain key, one log line), off with clipboard: false (a plain key); dispose leaves no listener', async () => {
  for (const [clipboard, bridge] of [[undefined, true], [undefined, false], [false, true]] as const) {
    const dom = installFakeDom();
    const nav = fakeNavigator();
    try {
      const container = dom.container();
      const link = scriptedLink();
      const logs: string[] = [];
      const wl = await createWland({ container, wasm, link, clipboard, onEvent: (ev) => { if (ev.type === 'log') logs.push(ev.line); } });
      link.cb!.onOpen();
      const sink = container.children.find((c: any) => c.contentEditable === 'true');
      // a mapped toplevel to focus
      link.cb!.onMessage(pack(...(bridge ? [selectionCache()] : []), connOpen(CONN), wireFrame(CONN, msg(1, 1, 2))));
      const g = globals(link.sent);
      link.cb!.onMessage(pack(wireFrame(CONN, cat(
        msg(2, 0, g.wl_compositor, 'wl_compositor', 4, 4), msg(2, 0, g.xdg_wm_base, 'xdg_wm_base', 1, 5),
        msg(4, 0, 6), msg(5, 2, 7, 6), msg(7, 1, 8),
      ))));
      wl.input.focus(CONN, 6);
      const ev = { code: 'KeyV', ctrlKey: true, metaKey: false, shiftKey: false, altKey: false, isComposing: false, keyCode: 0,
        prevented: false, preventDefault() { ev.prevented = true; }, getModifierState: () => false };
      sink.dispatch('keydown', ev);
      assert.equal(ev.prevented, clipboard === false || !bridge);
      assert.equal(logs.filter((l) => l.includes(NO_SELECTION_BRIDGE)).length, clipboard !== false && !bridge ? 1 : 0);
      wl.dispose();
      await settle();
      assert.deepEqual(dom.leftovers(), { documentListeners: 0, windowListeners: 0, observers: 0, mediaListeners: 0, frames: 0 });
    } finally { nav.restore(); dom.uninstall(); }
  }
});

test('page side in front of a relay that can\'t bridge (no FEATURE selection_cache): inert — one log line per link, chords are plain keys sent at once (no 300 ms hold), no reads or writes either way; a later link that can works again', async () => {
  const t = pageSetup({ 4: 'from foot' }, 'granted');
  try {
    t.relay.bridges = false;
    t.bridge.handle({ type: 'open' });
    t.bridge.handle({ type: 'title', conn: 4, surface: 6, title: 'foot' }); // the link's first event past its FEATUREs
    assert.equal(t.logs.filter((l) => l.includes(NO_SELECTION_BRIDGE)).length, 1, 'said at once');
    // Ctrl+V: prevented, sent at once (as with clipboard: false)
    t.calls.length = 0;
    const v = t.keyEv('KeyV', { ctrlKey: true });
    t.sink.dispatch('keydown', v);
    assert.equal(v.prevented, true, 'no browser paste');
    assert.deepEqual(t.calls.filter((c) => c[0] === 'key').map((c) => [c[3], c[4]]), [[47, true]], 'not held');
    // a paste event anyway (the browser's Edit menu): nothing set
    const ev = t.paste('page text');
    assert.equal(ev.prevented, true, 'nothing lands in the sink');
    // Ctrl+C: a plain key
    const c = t.keyEv('KeyC', { ctrlKey: true });
    t.sink.dispatch('keydown', c);
    assert.equal(c.prevented, true);
    // an app's copy after a gesture: not read, not written
    t.appCopies(4);
    await settle();
    assert.equal(t.relay.reads, 0);
    assert.deepEqual(t.clip.writes, []);
    // coming back with clipboard-read granted: no read of the page
    t.clip.reads = 0;
    (globalThis as any).document.body.focus();
    await settle();
    t.input.focus(3, 6);
    await settle();
    assert.equal(t.clip.reads, 0);
    assert.equal(t.calls.filter((k) => k[0] === 'setSelection').length, 0, 'never set');
    assert.equal(t.logs.filter((l) => l.includes(NO_SELECTION_BRIDGE)).length, 1, 'one line for the link');

    // the next link's relay bridges it: the chord is held for its paste again
    t.bridge.handle({ type: 'open' });
    t.relay.bridges = true;
    t.calls.length = 0;
    const v2 = t.keyEv('KeyV', { ctrlKey: true });
    t.sink.dispatch('keydown', v2);
    assert.equal(v2.prevented, false);
    t.paste('page text');
    assert.deepEqual(t.calls.map((k) => k[0] === 'key' ? 'key' : k[1]), ['page text', 'key']);
    // and a link that can't again: said again
    t.bridge.handle({ type: 'open' });
    t.relay.bridges = false;
    t.bridge.handle({ type: 'title', conn: 4, surface: 6, title: 'foot' });
    assert.equal(t.logs.filter((l) => l.includes(NO_SELECTION_BRIDGE)).length, 2);
  } finally { t.done(); }
});

// --- the bridge's state machine, row by row (lib/clipboard.ts's table) ------

const leaveWindow = () => (globalThis as any).window.dispatch('blur');
const backToWindow = () => (globalThis as any).window.dispatch('focus');

test('state: an app\'s copy while the user is away (window blur) is not written at their next key; their paste decides — page unchanged: written and pasted; changed: the page\'s text is pasted', async () => {
  // unchanged: the app's copy is newer
  let t = pageSetup({ 4: 'A', 5: 'S' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    assert.deepEqual(t.clip.writes, ['A']);
    leaveWindow();
    t.appCopies(5); // wl-copy from a script while the user is elsewhere
    await settle();
    backToWindow();
    t.sink.dispatch('keydown', t.keyEv('KeyB')); // a key: no write (the page may have changed)
    await settle();
    assert.deepEqual(t.clip.writes, ['A']);
    assert.deepEqual(t.copy().data, {}, 'nothing owed for a copy event either');
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('A'); // the page clipboard is what the bridge last wrote
    await settle();
    assert.deepEqual(t.clip.writes, ['A', 'S'], 'written inside the paste');
    assert.deepEqual(t.calls.map((c) => c[0]), ['key'], 'the selection stays the app\'s: it pastes S');
  } finally { t.done(); }

  // changed: the user copied U elsewhere (the reviewer's repro)
  t = pageSetup({ 4: 'A', 5: 'S' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    leaveWindow();
    t.clip.refuse = 'NotAllowedError'; // an unfocused page: writes refused
    t.appCopies(5);
    await settle();
    t.clip.text = 'U';
    t.clip.refuse = null;
    backToWindow();
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('U');
    await settle();
    assert.deepEqual(t.clip.writes, ['A'], 'S never overwrote U');
    assert.equal(t.clip.text, 'U');
    assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? 'key' : c[1]), ['U', 'key'], 'U is the selection before the V');
  } finally { t.done(); }
});

test('state: focus leaving the desktop for page UI, or the tab going hidden, is "away" too; a press in the desktop is back', async () => {
  for (const away of ['page-ui', 'hidden'] as const) {
    const t = pageSetup({ 4: 'S' });
    try {
      const doc = (globalThis as any).document;
      t.sink.dispatch('keydown', t.keyEv('KeyA')); // a gesture just before: a copy now would be written at once
      if (away === 'page-ui') doc.body.focus();
      else { doc.hidden = true; doc.dispatch('visibilitychange'); doc.hidden = false; }
      t.appCopies(4);
      await settle();
      assert.deepEqual(t.clip.writes, [], away);
      // a click in the desktop proves the focus is back: the next copy is written
      t.input.focus(3, 6);
      t.sink.dispatch('keydown', t.keyEv('KeyA'));
      t.appCopies(4);
      await settle();
      assert.deepEqual(t.clip.writes, ['S'], away);
    } finally { t.done(); }
  }
});

test('state: an owed copy the browser refused, then the user leaves: decided at their return — page unchanged since the bridge saw it: written at the paste; never seen: the page\'s text wins', async () => {
  for (const seen of [true, false]) {
    const t = pageSetup({ 3: 'A', 4: 'S' });
    try {
      t.sink.dispatch('keydown', t.keyEv('KeyA'));
      if (seen) { t.appCopies(3); await settle(); } // the page holds A, as written here
      t.clip.refuse = 'NotAllowedError';
      t.appCopies(4);
      await settle();
      leaveWindow();
      t.clip.refuse = null;
      backToWindow();
      t.sink.dispatch('keydown', t.keyEv('KeyB'));
      await settle();
      assert.deepEqual(t.clip.writes, seen ? ['A'] : [], 'not at a plain key: the page may hold something newer');
      t.calls.length = 0;
      t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
      t.paste(seen ? 'A' : 'older');
      await settle();
      if (seen) {
        assert.deepEqual(t.clip.writes, ['A', 'S']);
        assert.deepEqual(t.calls.map((c) => c[0]), ['key'], 'the app pastes S');
      } else {
        assert.deepEqual(t.clip.writes, []);
        assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? 'key' : c[1]), ['older', 'key']);
      }
    } finally { t.done(); }
  }
});

test('state: another type, or an embedder\'s own selection, cancels what was owed', async () => {
  const t = pageSetup({ 4: 'S' });
  try {
    t.clip.refuse = 'NotAllowedError';
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    t.appCopies(5, ['image/png']);
    assert.deepEqual(t.copy().data, {}, 'nothing owed after an image');
    t.appCopies(4);
    await settle();
    t.bridge.handle({ type: 'selection', conn: 0, mimes: ['text/html'] }); // an embedder's own
    assert.deepEqual(t.copy().data, {}, 'nothing owed after the embedder\'s own');
  } finally { t.done(); }
});

test('state: an app clearing what the page holds (a password manager\'s timeout) clears the page clipboard — at once after a gesture, else at the next key, or a copy event', async () => {
  // at once
  let t = pageSetup({ 4: 'hunter2' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    assert.equal(t.clip.text, 'hunter2');
    t.bridge.handle({ type: 'selection', conn: 4, mimes: [] });
    await settle();
    assert.deepEqual(t.clip.writes, ['hunter2', '']);
    assert.equal(t.clip.text, '');
    // pasting the cleared page clipboard brings nothing back
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('');
    assert.deepEqual(t.calls.map((c) => c[0]), ['key']);
  } finally { t.done(); }

  // refused now: at the next key; or the copy event carries ''
  t = pageSetup({ 4: 'hunter2' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    t.clip.refuse = 'NotAllowedError';
    t.bridge.handle({ type: 'selection', conn: 4, mimes: [] });
    await settle();
    assert.equal(t.clip.text, 'hunter2');
    const ev = t.copy();
    assert.equal(ev.prevented, true);
    assert.deepEqual(ev.data, { 'text/plain': '' });
    t.clip.refuse = null;
    t.appCopies(4);
    await settle();
    t.clip.refuse = 'NotAllowedError';
    t.bridge.handle({ type: 'selection', conn: 4, mimes: [] });
    t.clip.refuse = null;
    t.sink.dispatch('keydown', t.keyEv('KeyB'));
    await settle();
    assert.equal(t.clip.text, '', 'written at the next key');
  } finally { t.done(); }
});

test('state: a clear of something the page does not hold writes nothing; an app merely going away leaves the page clipboard alone (an owed copy still gets there)', async () => {
  const t = pageSetup({ 4: 'mine', 5: 'other' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    t.clip.refuse = 'NotAllowedError';
    t.appCopies(5); // owed, not written: the page still holds 'mine'
    await settle();
    t.bridge.handle({ type: 'selection', conn: 5, mimes: [] });
    t.clip.refuse = null;
    t.sink.dispatch('keydown', t.keyEv('KeyB'));
    await settle();
    assert.deepEqual(t.clip.writes, ['mine'], 'app 5 cleared its own copy, not what the page holds');

    // owner went (conn 0, no types): the page keeps its text, and an owed copy still goes
    t.clip.refuse = 'NotAllowedError';
    t.appCopies(5);
    await settle();
    t.bridge.handle({ type: 'selection', conn: 0, mimes: [] });
    t.clip.refuse = null;
    const ev = t.copy();
    assert.deepEqual(ev.data, { 'text/plain': 'other' });
    t.bridge.handle({ type: 'selection', conn: 0, mimes: [] });
    t.sink.dispatch('keydown', t.keyEv('KeyC'));
    await settle();
    assert.deepEqual(t.clip.writes, ['mine'], 'no clear for an app going away');
  } finally { t.done(); }
});

test('state: an app clearing while the user is away clears the page at their next paste in the desktop if it still holds that text (not pasted back), else nothing', async () => {
  for (const pageNow of ['hunter2', 'copied elsewhere']) {
    const t = pageSetup({ 4: 'hunter2' });
    try {
      t.sink.dispatch('keydown', t.keyEv('KeyA'));
      t.appCopies(4);
      await settle();
      leaveWindow();
      t.bridge.handle({ type: 'selection', conn: 4, mimes: [] });
      await settle();
      assert.deepEqual(t.clip.writes, ['hunter2'], 'not while away');
      t.clip.text = pageNow;
      backToWindow();
      t.sink.dispatch('keydown', t.keyEv('KeyB'));
      await settle();
      assert.deepEqual(t.clip.writes, ['hunter2'], 'not at a plain key: unverified');
      t.calls.length = 0;
      t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
      t.paste(pageNow);
      await settle();
      if (pageNow === 'hunter2') {
        assert.deepEqual(t.clip.writes, ['hunter2', ''], 'cleared inside the paste');
        assert.deepEqual(t.calls.map((c) => c[0]), ['key'], 'the secret is not made the selection again');
      } else {
        assert.deepEqual(t.clip.writes, ['hunter2']);
        assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? 'key' : c[1]), ['copied elsewhere', 'key']);
      }
    } finally { t.done(); }
  }
});

test('state: with clipboard-read granted, coming back reads the page: an away copy is written if the page is unchanged', async () => {
  const t = pageSetup({ 4: 'A', 5: 'S' }, 'granted');
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    (globalThis as any).document.body.focus();
    t.appCopies(5);
    await settle();
    t.input.focus(3, 6); // back: the granted read sees 'A', unchanged
    await settle();
    await settle();
    assert.deepEqual(t.clip.writes, ['A', 'S']);
  } finally { t.done(); }
});

test('state: the app that copied went (exit, link reconnect) or cleared over the bridge\'s own: the page\'s unchanged text pastes again; an app\'s newer non-text selection is left alone', async () => {
  for (const gone of ['exit', 'reconnect', 'clear'] as const) {
    const t = pageSetup({ 4: 'S' });
    try {
      t.sink.dispatch('keydown', t.keyEv('KeyA'));
      if (gone === 'clear') {
        t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
        t.paste('S'); // the user pasted S from the page: the bridge's own selection
        t.bridge.handle({ type: 'selection', conn: 0, mimes: ['text/plain;charset=utf-8'] });
        t.bridge.handle({ type: 'selection', conn: 4, mimes: [] }); // an app's set_selection(null)
      } else {
        t.appCopies(4); // foot copies S: written to the page
        await settle();
        assert.deepEqual(t.clip.writes, ['S']);
        t.bridge.handle({ type: 'selection', conn: 0, mimes: [] }); // foot exits / the link closes (engine: the selection empties)
      }
      t.calls.length = 0;
      t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true })); // into another app
      t.paste('S');
      assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? 'key' : c[1]), ['S', 'key'], `${gone}: S is the selection again before the V`);
      // once it is, the same paste again sets nothing
      t.calls.length = 0;
      t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
      t.paste('S');
      assert.deepEqual(t.calls.map((c) => c[0]), ['key'], gone);
      assert.deepEqual(t.clip.writes, gone === 'clear' ? [] : ['S'], 'nothing written to the page');
    } finally { t.done(); }
  }
  // an app's image: newer than the page's unchanged text, kept
  const t = pageSetup({ 4: 'S' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    t.appCopies(5, ['image/png']);
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('S');
    assert.deepEqual(t.calls.map((c) => c[0]), ['key'], 'the app pastes its image');
  } finally { t.done(); }
});

test('state: focus leaving for nothing (a click on plain page text, an embedder\'s blur()) or a press outside the desktop that keeps the focus is "away": an app\'s copy then never overwrites what the user copied on the page', async () => {
  for (const how of ['blur', 'press'] as const) {
    // Safari: the write waits for the next gesture; the user meanwhile copies P on the page
    const t = pageSetup({ 4: 'S' });
    try {
      t.sink.dispatch('keydown', t.keyEv('KeyA'));
      t.clip.refuse = 'NotAllowedError';
      t.appCopies(4);
      await settle();
      t.clip.refuse = null;
      if (how === 'blur') t.sink.blur(); // focus → the body: no focusin anywhere
      else t.dom.document.dispatch('pointerdown', { target: t.dom.document.body, button: 0, getModifierState: () => false });
      await settle();
      t.clip.text = 'P';
      if (how === 'blur') t.input.focus(3, 6); // back: a click on the window
      t.sink.dispatch('keydown', t.keyEv('ShiftLeft', { shiftKey: true }));
      await settle();
      assert.deepEqual(t.clip.writes, [], `${how}: S did not overwrite P`);
      t.calls.length = 0;
      t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
      t.paste('P');
      assert.deepEqual(t.calls.map((c) => c[0] === 'key' ? 'key' : c[1]), ['P', 'key'], `${how}: P is pasted`);
      assert.equal(t.clip.text, 'P');
    } finally { t.done(); }
  }
  // the same hole let an app's clear wipe what the user copied on the page
  const t = pageSetup({ 4: 'hunter2' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    t.sink.blur();
    await settle();
    t.clip.text = 'P'; // copied on the page
    t.bridge.handle({ type: 'selection', conn: 4, mimes: [] }); // the password manager's timeout
    await settle();
    assert.deepEqual(t.clip.writes, ['hunter2'], 'not cleared while away');
    assert.equal(t.clip.text, 'P');
  } finally { t.done(); }
  // input's own blur-and-refocus of its sink (the on-screen keyboard's mode) is no leave
  const u = pageSetup({ 4: 'S' });
  try {
    u.input.handle({ type: 'text-input', conn: 3, active: true, x: 0, y: 0, width: 0, height: 0 });
    await settle();
    u.sink.dispatch('keydown', u.keyEv('KeyA'));
    u.appCopies(4);
    await settle();
    assert.deepEqual(u.clip.writes, ['S']);
  } finally { u.done(); }
});

test('state: a paste showing no text but other content (an image copied elsewhere) means the page clipboard changed: nothing is written over it', async () => {
  const t = pageSetup({ 4: 'A', 5: 'S' });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    t.appCopies(4);
    await settle();
    t.bridge.handle({ type: 'selection', conn: 4, mimes: [] }); // the app clears: the page cleared too
    await settle();
    assert.deepEqual(t.clip.writes, ['A', '']);
    leaveWindow();
    t.appCopies(5); // an away copy: decided at the next look
    await settle();
    backToWindow();
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('', ['image/png']); // the user copied an image elsewhere
    await settle();
    assert.deepEqual(t.clip.writes, ['A', ''], 'the image is not overwritten');
    assert.deepEqual(t.calls.map((c) => c[0]), ['key']);
    // a later empty paste with the same image: still nothing
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    t.paste('', ['Files']);
    await settle();
    assert.deepEqual(t.clip.writes, ['A', '']);
  } finally { t.done(); }
});

// --- input around the paste chord: everything keyboard-side keeps its order --

test('input: a lock-state change and IME text during a paste\'s wait reach the app after the held keys, in order', async () => {
  const t = pageSetup({}, 'prompt', { recordLocks: true });
  try {
    t.sink.dispatch('keydown', t.keyEv('KeyV', { ctrlKey: true }));
    // Caps Lock went on (its own press toggles in the core), then `a` with it on
    const caps = (on: boolean) => (k: string) => k === 'CapsLock' && on;
    t.sink.dispatch('keydown', t.keyEv('CapsLock', { getModifierState: caps(true) }));
    t.sink.dispatch('keydown', t.keyEv('KeyA', { getModifierState: caps(true) }));
    t.sink.dispatch('compositionend', { data: 'é' });
    assert.deepEqual(t.calls, [['keyboardLocks', false, true]], 'nothing after the chord\'s own lock sync reaches the app before the paste');
    t.paste('text');
    const seen = t.calls.map((c) => c[0] === 'key' ? `key ${c[3]}` : c[0] === 'keyboardLocks' ? `locks ${c[1]}` : c[0] === 'setSelection' ? 'set' : c[0]);
    assert.deepEqual(seen, ['locks false', 'set', 'key 47', 'key 58', 'locks true', 'key 30', 'textInputCommit']);
  } finally { t.done(); }
});

test('input: Ctrl+V keeps the browser default, Ctrl+C only while the bridge has text for the copy event; both reach a terminal exactly as without the bridge (Ctrl+C → SIGINT, Ctrl+V literal-next); Meta+V off Apple is a plain key', async () => {
  const run = async (clipboard: boolean) => {
    const t = pageSetup({}, 'prompt', { clipboard });
    try {
      const evs = [t.keyEv('ControlLeft', { ctrlKey: true }), t.keyEv('KeyC', { ctrlKey: true }), t.keyEv('KeyV', { ctrlKey: true })];
      for (const e of evs) t.sink.dispatch('keydown', e);
      t.sink.dispatch('keyup', t.keyEv('KeyV', { ctrlKey: true }));
      t.sink.dispatch('keyup', t.keyEv('KeyC', { ctrlKey: true }));
      t.sink.dispatch('keyup', t.keyEv('ControlLeft'));
      if (clipboard) t.paste('');
      const meta = t.keyEv('KeyV', { metaKey: true });
      t.sink.dispatch('keydown', meta);
      return { keys: t.calls.filter((c) => c[0] === 'key').map((c) => [c[3], c[4]]), prevented: evs.map((e) => e.prevented), meta: meta.prevented };
    } finally { t.done(); }
  };
  const off = await run(false), on = await run(true);
  assert.deepEqual(on.keys, off.keys, 'the same key events');
  assert.deepEqual(on.keys, [[29, true], [46, true], [47, true], [47, false], [46, false], [29, false], [47, true]]);
  assert.deepEqual(on.prevented, [true, true, false], 'nothing owed: Ctrl+C is a plain key (no copy of the page\'s selection); Ctrl+V keeps its paste');
  assert.equal(on.meta, true, 'Meta+V is no paste chord off Apple');

  // something owed (a refused write): Ctrl+C keeps its default, the copy event carries it
  const t = pageSetup({ 4: 'owed' });
  try {
    t.clip.refuse = 'NotAllowedError';
    t.appCopies(4);
    await settle();
    const c = t.keyEv('KeyC', { ctrlKey: true });
    t.sink.dispatch('keydown', c);
    assert.equal(c.prevented, false);
    assert.deepEqual(t.copy().data, { 'text/plain': 'owed' });
    const again = t.keyEv('KeyC', { ctrlKey: true });
    t.sink.dispatch('keydown', again);
    assert.equal(again.prevented, true, 'written: the next Ctrl+C is a plain key again');
  } finally { t.done(); }
});

test('input: a copy or cut event while the desktop has the focus is always cancelled (a page selection left from before is never copied); one elsewhere on the page is left alone', async () => {
  const t = pageSetup();
  try {
    for (const type of ['copy', 'cut']) {
      const data: Record<string, string> = {};
      const ev = { clipboardData: { setData: (k: string, v: string) => { data[k] = v; } }, prevented: false, preventDefault() { ev.prevented = true; } };
      t.dom.document.dispatch(type, ev);
      assert.equal(ev.prevented, true, type);
      assert.deepEqual(data, {}, `${type}: nothing set, the clipboard stays as it was`);
    }
    (globalThis as any).document.body.focus(); // page UI
    await settle();
    const ev = t.copy();
    assert.equal(ev.prevented, false, 'the page\'s own copy');
  } finally { t.done(); }
});

test('input: keys held when the window loses focus (Alt+Tab) are let go of in the app; their late releases, and releases of keys never pressed, are dropped', async () => {
  const t = pageSetup();
  try {
    const keys = () => t.calls.filter((c) => c[0] === 'key' || c[0] === 'keyboardLeave').map((c) => c[0] === 'key' ? `${c[4] ? '+' : '-'}${c[3]}` : 'leave');
    t.sink.dispatch('keydown', t.keyEv('AltLeft', { altKey: true }));
    t.sink.dispatch('keydown', t.keyEv('KeyA'));
    (globalThis as any).window.dispatch('blur'); // Alt+Tab: the releases go to another window
    assert.deepEqual(keys(), ['+56', '+30', '-56', '-30']);
    t.sink.dispatch('keyup', t.keyEv('AltLeft'));
    t.sink.dispatch('keyup', t.keyEv('KeyQ'));
    assert.deepEqual(keys().length, 4, 'nothing more');
    // focus leaving the desktop: released before the leave
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('ControlLeft', { ctrlKey: true }));
    t.sink.blur();
    await settle();
    assert.deepEqual(keys(), ['+29', '-29', 'leave']);
    // another app: its keys are let go of in the app they were pressed in
    t.input.focus(3, 6);
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('ShiftLeft', { shiftKey: true }));
    t.input.focus(9, 6);
    t.sink.dispatch('keyup', t.keyEv('ShiftLeft'));
    assert.deepEqual(t.calls.filter((c) => c[0] === 'key' || c[0] === 'keyboardLeave').map((c) => `${c[0]} ${c[1]}${c[0] === 'key' ? ` ${c[3]} ${c[4]}` : ''}`),
      ['key 3 42 true', 'key 3 42 false', 'keyboardLeave 3']);
  } finally { t.done(); }
});

test('input (Apple): Cmd+V is the paste chord and reaches the app as a whole Ctrl+V after the selection; Cmd+C as Ctrl+C; Ctrl+V is a plain key, sent at once', async () => {
  const t = pageSetup({}, 'prompt', { platform: 'MacIntel' });
  try {
    const keys = () => t.calls.filter((c) => c[0] === 'key' || c[0] === 'setSelection')
      .map((c) => c[0] === 'key' ? `${c[4] ? '+' : '-'}${c[3]}` : 'set');
    const cmd = t.keyEv('MetaLeft', { metaKey: true });
    t.sink.dispatch('keydown', cmd);
    assert.deepEqual(keys(), ['+125']);
    const v = t.keyEv('KeyV', { metaKey: true });
    t.sink.dispatch('keydown', v);
    assert.equal(v.prevented, false, 'the browser\'s paste happens');
    assert.deepEqual(keys(), ['+125'], 'held for the paste event');
    t.paste('from the mac');
    assert.deepEqual(keys(), ['+125', 'set', '-125', '+29', '+47', '-47', '-29', '+125'], 'Super up, Ctrl+V pressed and released, Super down: Cmd is still held');
    t.sink.dispatch('keyup', t.keyEv('KeyV', { metaKey: true }));
    assert.deepEqual(keys().length, 8, 'V\'s own release: the chord had it');
    t.sink.dispatch('keyup', t.keyEv('MetaLeft'));
    assert.deepEqual(keys().slice(8), ['-125']);

    // Cmd+C, nothing owed: not held (no paste to wait for), a plain key for the browser (no copy of a page selection), Ctrl+C at once
    t.calls.length = 0;
    t.sink.dispatch('keydown', t.keyEv('MetaLeft', { metaKey: true }));
    const c = t.keyEv('KeyC', { metaKey: true });
    t.sink.dispatch('keydown', c);
    assert.equal(c.prevented, true);
    t.sink.dispatch('keyup', t.keyEv('MetaLeft'));
    t.sink.dispatch('keyup', t.keyEv('KeyC'));
    assert.deepEqual(keys(), ['+125', '-125', '+29', '+46', '-46', '-29', '+125', '-125']);

    // Ctrl+V: no paste on Apple — a plain key, prevented, sent at once
    t.calls.length = 0;
    const cv = t.keyEv('KeyV', { ctrlKey: true });
    t.sink.dispatch('keydown', cv);
    assert.equal(cv.prevented, true);
    assert.deepEqual(keys(), ['+47']);
  } finally { t.done(); }
});

test('input (Apple): no key stays down in the app whatever macOS delivers — releases in either order, none at all under Cmd, auto-repeat, Cmd+Shift+V, Cmd+A, a blur mid-chord, Cmd held across a window switch', async () => {
  const t = pageSetup({}, 'prompt', { platform: 'MacIntel' });
  const keys = () => t.calls.filter((c) => c[0] === 'key' || c[0] === 'keyboardLeave' || c[0] === 'keyboardEnter')
    .map((c) => c[0] === 'key' ? `${c[4] ? '+' : '-'}${c[3]}` : c[0]);
  const down = (code: string, mods: Record<string, unknown> = {}) => t.sink.dispatch('keydown', t.keyEv(code, mods));
  const up = (code: string, mods: Record<string, unknown> = {}) => t.sink.dispatch('keyup', t.keyEv(code, mods));
  // what the app holds after the calls so far (a press without its release)
  const held = () => {
    const h = new Set<string>();
    for (const k of keys()) if (k[0] === '+') h.add(k.slice(1)); else if (k[0] === '-') h.delete(k.slice(1)); else h.clear();
    return [...h];
  };
  const chordV = ['+29', '+47', '-47', '-29'];
  try {
    // Cmd up first, V's release after it
    down('MetaLeft', { metaKey: true }); down('KeyV', { metaKey: true }); t.paste('x');
    up('MetaLeft'); up('KeyV');
    assert.deepEqual(keys(), ['+125', '-125', ...chordV, '+125', '-125']);
    assert.deepEqual(held(), []);

    // no V release at all (macOS under Cmd); a later plain V is a plain V
    t.calls.length = 0;
    down('MetaLeft', { metaKey: true }); down('KeyV', { metaKey: true }); t.paste('x');
    up('MetaLeft');
    down('KeyV'); up('KeyV');
    assert.deepEqual(keys(), ['+125', '-125', ...chordV, '+125', '-125', '+47', '-47']);

    // auto-repeat: every repeat a whole chord (and a paste)
    t.calls.length = 0;
    down('MetaLeft', { metaKey: true });
    down('KeyV', { metaKey: true }); t.paste('x');
    down('KeyV', { metaKey: true, repeat: true }); t.paste('x');
    up('MetaLeft');
    assert.deepEqual(keys(), ['+125', '-125', ...chordV, '+125', '-125', ...chordV, '+125', '-125']);

    // Cmd+Shift+V: Ctrl+Shift+V (a terminal's paste); Shift's release does arrive
    t.calls.length = 0;
    down('MetaLeft', { metaKey: true }); down('ShiftLeft', { metaKey: true, shiftKey: true });
    down('KeyV', { metaKey: true, shiftKey: true }); t.paste('x');
    up('ShiftLeft', { metaKey: true }); up('MetaLeft');
    assert.deepEqual(keys(), ['+125', '+42', '-125', ...chordV, '+125', '-42', '-125']);

    // Cmd+A, A's release never delivered: the last Cmd's release lets go of it
    t.calls.length = 0;
    down('MetaLeft', { metaKey: true }); down('MetaRight', { metaKey: true }); down('KeyA', { metaKey: true });
    up('MetaRight', { metaKey: true });
    assert.deepEqual(held().sort(), ['125', '30'], 'Left Cmd still held: A still down');
    up('MetaLeft');
    assert.deepEqual(keys().slice(-3), ['-126', '-30', '-125']);
    up('KeyA'); // (arrives late: already up)
    assert.deepEqual(held(), []);

    // the window loses focus mid-chord (paste pending): everything let go of, in order after the chord
    t.calls.length = 0;
    down('MetaLeft', { metaKey: true }); down('KeyV', { metaKey: true });
    (globalThis as any).window.dispatch('blur');
    t.paste('x');
    assert.deepEqual(keys(), ['+125', '-125', ...chordV, '+125', '-125']);
    // back, Left Cmd's release went elsewhere; Right Cmd+V: Left Cmd is not pressed again
    t.calls.length = 0;
    (globalThis as any).window.dispatch('focus');
    down('MetaRight', { metaKey: true }); down('KeyV', { metaKey: true }); t.paste('x');
    up('KeyV', { metaKey: true }); up('MetaRight');
    assert.deepEqual(keys(), ['+126', '-126', ...chordV, '+126', '-126']);

    // focus leaving the desktop with Cmd held (the repro's C2): released before the leave, never pressed again
    t.calls.length = 0;
    down('MetaLeft', { metaKey: true });
    t.sink.blur();
    await settle();
    t.input.focus(3, 6);
    down('MetaRight', { metaKey: true }); down('KeyV', { metaKey: true }); t.paste('x');
    up('KeyV', { metaKey: true }); up('MetaRight');
    assert.deepEqual(keys(), ['+125', '-125', 'keyboardLeave', 'keyboardEnter', '+126', '-126', ...chordV, '+126', '-126']);
    assert.deepEqual(held(), []);
  } finally { t.done(); }
});
