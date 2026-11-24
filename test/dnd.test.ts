// The page's drag-and-drop bridge (lib/dnd.ts) on the fake DOM: an HTML drag
// over the desktop driving a recording engine — what it begins, moves,
// hands over and drops, what it refuses, how it ends. The engine side (the
// core's own drag) is covered in engine.test.ts and the core's unit tests.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { installFakeDom } from './fake-dom.ts';
import { createView } from '../lib/view.ts';
import { createInput } from '../lib/input.ts';
import { createDndBridge, dropActions, dropData, dropEffect, dropFileData, dropPlan, dropTypes, finishDrop, uriList, type DndBridgeOptions } from '../lib/dnd.ts';
import { createWland } from '../lib/client.ts';
import { DND_COPY, DND_MOVE, TEXT_MIMES, type Engine, type Link, type LinkCallbacks } from '../lib/engine.ts';

const wasm = await readFile(new URL('../lib/wland.wasm', import.meta.url));

test('dropTypes / dropData / dropActions / dropEffect: text/plain as the UTF-8 types, text/html, text/uri-list (CRLF lines); files and others left out; over the cap left out', () => {
  assert.deepEqual(dropTypes(['text/uri-list', 'text/plain', 'Files', 'application/x-moz-file', 'text/html', 'TEXT/PLAIN']), {
    web: ['text/uri-list', 'text/plain', 'text/html'],
    wayland: ['text/uri-list', ...TEXT_MIMES, 'text/html'],
  });
  assert.deepEqual(dropTypes(['Files']), { web: [], wayland: [] });
  const got = dropData((t) => ({ 'text/uri-list': 'https://a.example/\n# comment\nhttps://b.example/', 'text/plain': 'hé', 'text/html': '' } as Record<string, string>)[t],
    ['text/uri-list', 'text/plain', 'text/html']);
  const want: Record<string, string> = { 'text/uri-list': 'https://a.example/\r\n# comment\r\nhttps://b.example/\r\n' };
  for (const m of TEXT_MIMES) want[m] = 'hé';
  assert.deepEqual(got, want, 'an empty value is left out');
  assert.deepEqual(dropData(() => 'x'.repeat(11), ['text/html'], 10), {}, 'over the cap');
  assert.deepEqual(dropData(() => 'é'.repeat(5), ['text/html'], 10), { 'text/html': 'é'.repeat(5) }, '10 bytes fit');
  assert.equal(dropActions('copyLink'), DND_COPY);
  assert.equal(dropActions('move'), DND_MOVE);
  assert.equal(dropActions('all'), DND_COPY | DND_MOVE);
  assert.equal(dropActions('uninitialized'), DND_COPY | DND_MOVE);
  assert.equal(dropActions('none'), 0);
  assert.equal(dropEffect(DND_COPY, 'all'), 'copy');
  assert.equal(dropEffect(DND_COPY, 'link'), 'link');
  assert.equal(dropEffect(DND_MOVE, 'copyMove'), 'move');
  assert.equal(dropEffect(0, 'all'), 'none');
});

// the bridge with the real view and input on a recording engine:
// `state.action` is what dragAction() answers, `state.bridged` what
// selectionBridged() does, `state.begin` what dragBegin returns
function dndRig(dom: ReturnType<typeof installFakeDom>, opts: Partial<DndBridgeOptions> = {}) {
  const container = dom.container();
  const view = createView({ container, webgl: 'never' });
  const calls: unknown[][] = [];
  const state = { action: 0, bridged: true as boolean | null, begin: true };
  const engine = new Proxy({} as Engine, {
    get: (_, name) => {
      if (name === 'dragAction') return () => state.action;
      if (name === 'selectionBridged') return () => state.bridged;
      if (name === 'touchBound') return () => false;
      return (...args: unknown[]) => {
        calls.push([name, ...args.filter((_, i) => !(name === 'dragMotion' && i === 2))]); // (no times)
        if (name === 'dragBegin') return state.begin;
        return true;
      };
    },
  });
  const input = createInput({ engine, view, container });
  const logs: string[] = [];
  const dnd = createDndBridge({ engine, view, input, container, log: (l) => logs.push(l), ...opts });
  view.handle({
    type: 'commit', conn: 1, surface: 5, role: 1, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
    geometry: { x: 0, y: 0, width: 40, height: 30 }, width: 40, height: 30, logicalWidth: 40, logicalHeight: 30,
    format: 'rgba', stride: 0, damage: new Int32Array(0), pixels: new Uint8Array(0),
  });
  calls.length = 0; // (its focus at the map)
  const canvas = view.canvas(1, 5) as any;
  const doc = dom.document;
  doc.elementFromPoint = () => canvas; // what surfaceAt hit-tests
  const outside = doc.createElement('div');
  doc.body.appendChild(outside);
  // a DataTransfer: its types and effectAllowed, its data (readable at the drop)
  const transfer = (data: Record<string, string>, effectAllowed = 'all', types = Object.keys(data), files: File[] = []) =>
    ({ types: files.length ? [...types, 'Files'] : types, effectAllowed, dropEffect: '', getData: (t: string) => data[t] ?? '',
       items: [...types.map((t) => ({ kind: 'string', type: t })), ...files.map((f) => ({ kind: 'file', type: f.type }))], files });
  // a drag event on the document; `prevented` says whether it was cancelled
  const drag = (type: string, dt: unknown, x: number, y: number, extra: Record<string, unknown> = {}) => {
    let prevented = false;
    doc.dispatch(type, { target: canvas, dataTransfer: dt, clientX: x, clientY: y, relatedTarget: null,
      preventDefault() { prevented = true; }, ...extra });
    return prevented;
  };
  const names = () => calls.map((c) => c[0]);
  return {
    container, view, input, dnd, calls, state, logs, canvas, doc, outside, transfer, drag, names,
    dispose() { dnd.dispose(); input.dispose(); view.dispose(); },
  };
}

const tick = () => new Promise((res) => setTimeout(res, 0));

test('dnd bridge: a text drag entering the desktop begins a drag (its types, its actions), the app under it loses the pointer, dragovers move it and answer the app\'s action as dropEffect; the drop hands the data over and drops, then the pointer is entered where it fell', async () => {
  const dom = installFakeDom();
  try {
    const r = dndRig(dom);
    r.doc.dispatch('pointerover', { target: r.canvas, pointerId: 1, pointerType: 'mouse', clientX: 1, clientY: 1, buttons: 0 });
    r.calls.length = 0;
    const dt = r.transfer({ 'text/plain': 'dragged', 'text/html': '<i>dragged</i>' }, 'copyMove');
    assert.equal(r.drag('dragenter', dt, 10, 12), true, 'the desktop is a drop target');
    assert.deepEqual(r.calls, [
      ['dragBegin', [...TEXT_MIMES, 'text/html'], DND_COPY | DND_MOVE],
      ['pointerLeave', 1], // the pointerless grab: the app under the pointer lost it
      ['dragMotion', 1, 5, 10, 12],
    ]);
    assert.equal(r.dnd.active(), true);

    // nothing taken yet: dropEffect none; the app accepts: copy, then move
    r.calls.length = 0;
    assert.equal(r.drag('dragover', dt, 10, 12), true);
    assert.equal(dt.dropEffect, 'none');
    assert.deepEqual(r.calls, [], 'the same place: nothing sent again');
    r.state.action = DND_COPY;
    r.drag('dragover', dt, 11, 12);
    assert.equal(dt.dropEffect, 'copy');
    r.state.action = DND_MOVE;
    r.drag('dragover', dt, 12, 13);
    assert.equal(dt.dropEffect, 'move');
    assert.deepEqual(r.calls, [['dragMotion', 1, 5, 11, 12], ['dragMotion', 1, 5, 12, 13]]);
    // a move within the desktop (from one element to another): it goes on
    r.calls.length = 0;
    r.drag('dragenter', dt, 13, 13);
    r.drag('dragleave', dt, 13, 13, { relatedTarget: null });
    r.drag('dragleave', dt, 13, 13, { relatedTarget: r.container });
    assert.equal(r.dnd.active(), true);
    // pointer events meanwhile are held off (a pointer grab)
    r.doc.dispatch('pointermove', { target: r.canvas, pointerId: 1, pointerType: 'mouse', clientX: 3, clientY: 3, buttons: 0 });
    assert.ok(!r.names().includes('pointerMotion'));

    // the drop: the data by Wayland type, the drop, then the pointer entered there
    r.calls.length = 0;
    assert.equal(r.drag('drop', dt, 14, 15), true, 'the page does nothing with it');
    const data: Record<string, string> = {};
    for (const m of TEXT_MIMES) data[m] = 'dragged';
    data['text/html'] = '<i>dragged</i>';
    assert.deepEqual(r.calls, [['dragMotion', 1, 5, 14, 15], ['dragData', data], ['dragDrop'], ['pointerEnter', 1, 5, 14, 15]]);
    assert.equal(r.dnd.active(), false);
    // pointer events reach the app again
    r.calls.length = 0;
    r.doc.dispatch('pointermove', { target: r.canvas, pointerId: 1, pointerType: 'mouse', clientX: 16, clientY: 15, buttons: 0 });
    assert.ok(r.names().includes('pointerMotion'));
    r.dispose();
    await tick();
  } finally {
    dom.uninstall();
  }
});

test('dnd bridge: the drag leaving the desktop (to the page, or out of the window), a drop nothing takes, the window blur, a press, the page\'s dragend and the link closing all end it — cancelled, never dropped', async () => {
  const dom = installFakeDom();
  try {
    const r = dndRig(dom);
    const dt = r.transfer({ 'text/uri-list': 'https://example.org/' }, 'link');
    const begin = () => { r.drag('dragenter', dt, 5, 5); r.calls.length = 0; };

    // to an element of the page outside the desktop: its dragenter, then our dragleave
    begin();
    assert.equal(r.calls.length, 0);
    r.doc.dispatch('dragenter', { target: r.outside, dataTransfer: dt, clientX: 900, clientY: 5, preventDefault() {} });
    r.doc.elementFromPoint = () => r.outside;
    r.drag('dragleave', dt, 900, 5, { relatedTarget: r.outside });
    assert.deepEqual(r.calls, [['dragCancel']], 'no enter: the pointer is not over the app');
    assert.equal(r.dnd.active(), false);
    r.doc.elementFromPoint = () => r.canvas;

    // out of the window: a dragleave with no dragenter before it in the task
    begin();
    await tick();
    r.drag('dragleave', dt, 0, 0);
    assert.equal(r.names()[0], 'dragCancel');

    // dropped where nothing takes it (dragAction 0): cancelled, no data
    begin();
    r.state.action = 0;
    r.drag('drop', dt, 5, 5);
    assert.deepEqual(r.names(), ['dragCancel', 'pointerEnter']);

    // the window blur ends the grab: cancelled
    begin();
    (globalThis as any).window.dispatch('blur');
    assert.equal(r.names()[0], 'dragCancel');
    // a press: the browser's drag is over
    begin();
    r.doc.dispatch('pointerdown', { target: r.canvas, pointerId: 1, pointerType: 'mouse', clientX: 5, clientY: 5, buttons: 1, button: 0 });
    assert.equal(r.names()[0], 'dragCancel');
    // the page's own drag ended
    begin();
    r.doc.dispatch('dragend', { target: r.outside });
    assert.equal(r.names()[0], 'dragCancel');
    // the link closed: the core's drag went with it, nothing is sent for it
    begin();
    r.dnd.handle({ type: 'close', takenOver: false });
    assert.ok(!r.names().includes('dragCancel'));
    assert.equal(r.dnd.active(), false);
    r.dispose();
    await tick();
  } finally {
    dom.uninstall();
  }
});

test('dnd bridge: a drag of files with no type shown (no hook), or on a link whose relay can\'t bridge, starts nothing — the desktop still refuses the drop (no navigation); a refused dragBegin starts nothing; dispose removes its listeners', async () => {
  const dom = installFakeDom();
  try {
    const before = dom.leftovers().documentListeners;
    const r = dndRig(dom);
    const files = r.transfer({}, 'all', ['Files']);
    assert.equal(r.drag('dragenter', files, 5, 5), true);
    const dragover = r.drag('dragover', files, 5, 5);
    assert.deepEqual([dragover, files.dropEffect], [true, 'none']);
    assert.equal(r.drag('drop', files, 5, 5), true);
    assert.deepEqual(r.calls, []);

    r.state.bridged = false;
    const text = r.transfer({ 'text/plain': 'x' });
    r.drag('dragenter', text, 5, 5);
    r.drag('dragover', text, 5, 5);
    assert.equal(text.dropEffect, 'none');
    r.drag('dragleave', text, 0, 0);
    r.drag('dragenter', text, 5, 5);
    assert.deepEqual(r.calls, []);
    assert.equal(r.logs.filter((l) => l.includes('selection_cache')).length, 1, 'said once');

    r.state.bridged = true;
    r.state.begin = false; // (another drag on)
    r.drag('dragenter', text, 5, 5);
    assert.deepEqual(r.names(), ['dragBegin']);
    assert.equal(r.dnd.active(), false);
    r.dispose();
    await tick();
    assert.equal(dom.leftovers().documentListeners, before);
  } finally {
    dom.uninstall();
  }
});

type ScriptedLink = Link & { sent: Uint8Array[]; bufferedAmount: number; cb: LinkCallbacks | null };
function scriptedLink(): ScriptedLink {
  const link: ScriptedLink = {
    sent: [], bufferedAmount: 0, cb: null,
    start: (cb) => { link.cb = cb; },
    send: (bytes) => { link.sent.push(bytes); },
  };
  return link;
}

test('createWland: the dnd bridge is on by default (drops on the desktop are the apps\'), off with dnd: false (left to the page)', async () => {
  const dom = installFakeDom();
  try {
    for (const dnd of [undefined, false]) {
      const container = dom.container();
      const link = scriptedLink();
      const wl = await createWland({ container, wasm, link, webgl: 'never', dnd });
      link.cb!.onOpen();
      let prevented = false;
      dom.document.dispatch('dragover', { target: container, dataTransfer: { types: ['text/plain'], effectAllowed: 'all', dropEffect: '' },
        clientX: 1, clientY: 1, preventDefault() { prevented = true; } });
      assert.equal(prevented, dnd !== false);
      wl.dispose();
    }
    await tick();
  } finally {
    dom.uninstall();
  }
});

// --- dropped files -----------------------------------------------------------

const file = (name: string, type: string, text: string) => new File([text], name, { type });

test('dropPlan / uriList / dropFileData: with a hook files are text/uri-list (the drag\'s own uri-list wins); without, each file type as itself (no type, or one a text already has, left out); the first file of a type within the cap is its content; paths become file:// URIs', async () => {
  assert.deepEqual(dropPlan(['Files'], ['image/png'], true), { web: [], wayland: ['text/uri-list'], files: 'uris', fileTypes: [] });
  assert.deepEqual(dropPlan(['text/uri-list', 'Files'], ['image/png'], true).files, 'none', 'an image dragged from a web page: its URL');
  assert.deepEqual(dropPlan(['Files'], ['image/png', '', 'IMAGE/PNG', 'text/plain'], false),
    { web: [], wayland: ['image/png', 'text/plain'], files: 'content', fileTypes: ['image/png', 'text/plain'] });
  assert.deepEqual(dropPlan(['text/plain', 'Files'], ['text/plain'], false).files, 'none', 'the drag\'s own text wins');
  assert.deepEqual(dropPlan(['Files'], [''], false).wayland, [], 'no usable type: nothing');
  assert.deepEqual(dropPlan(['text/html'], [], true).files, 'none');

  assert.equal(uriList(['/tmp/a b/ü.png', 'file:///x', ' ', 'https://e.org/']), 'file:///tmp/a%20b/%C3%BC.png\r\nfile:///x\r\nhttps://e.org/\r\n');

  const plan = dropPlan(['Files'], ['image/png', 'text/plain'], false);
  const big = file('big.png', 'image/png', 'x'.repeat(20));
  const small = file('small.png', 'image/png', 'png!');
  const txt = file('a.txt', 'text/plain', 'hello');
  const got = await dropFileData(plan, [big, small, txt], undefined, 10);
  assert.deepEqual(Object.keys(got!), ['image/png', 'text/plain']);
  assert.equal(new TextDecoder().decode(got!['image/png'] as Uint8Array), 'png!', 'the first one within the cap');
  assert.equal(dropFileData(plan, [big], undefined, 10), null, 'none fits: nothing to wait for');
  assert.equal(dropFileData(plan, [], undefined, 10), null);
  const uris = dropPlan(['Files'], ['image/png'], true);
  assert.deepEqual(await dropFileData(uris, [small], async (fs) => fs.map((f) => `/up/${f.name}`)), { 'text/uri-list': 'file:///up/small.png\r\n' });
  assert.deepEqual(await dropFileData(uris, [small], () => null), {}, 'null: no files dropped');
  assert.deepEqual(await dropFileData(uris, [small], () => []), {});
});

// an engine that records calls, for finishDrop
function recorder() {
  const calls: unknown[][] = [];
  const engine = new Proxy({} as Engine, { get: (_, name) => (...args: unknown[]) => { calls.push([name, ...args]); return true; } });
  return { engine, calls };
}

test('finishDrop: text alone is handed over and dropped at once; files make the drop now and the data when ready (the hook\'s URIs; a rejection, null or the timeout: without them); nothing to hand over cancels; a stale drop hands nothing', async () => {
  const text = dropPlan(['text/html'], [], false);
  {
    const { engine, calls } = recorder();
    assert.equal(await finishDrop(engine, text, () => '<b>x</b>', []), true);
    assert.deepEqual(calls, [['dragData', { 'text/html': '<b>x</b>' }], ['dragDrop']]);
  }
  {
    const { engine, calls } = recorder();
    assert.equal(await finishDrop(engine, text, () => '', []), false);
    assert.deepEqual(calls, [['dragCancel']]);
  }
  const uris = dropPlan(['text/plain', 'Files'], ['image/png'], true);
  const png = file('a.png', 'image/png', 'png');
  {
    const { engine, calls } = recorder();
    let release!: (v: string[]) => void;
    const p = finishDrop(engine, uris, (t) => (t === 'text/plain' ? 'a.png' : ''), [png], { hook: () => new Promise((r) => { release = r; }) });
    await tick();
    assert.deepEqual(calls, [['dragDrop', true]], 'the drop now, its data to come');
    release(['/srv/a.png']);
    assert.equal(await p, true);
    const want: Record<string, string> = { 'text/uri-list': 'file:///srv/a.png\r\n' };
    for (const m of TEXT_MIMES) want[m] = 'a.png';
    assert.deepEqual(calls[1], ['dragData', want]);
  }
  for (const hook of [() => Promise.reject(new Error('upload failed')), () => null, () => { throw new Error('sync throw'); }]) {
    const { engine, calls } = recorder();
    const logs: string[] = [];
    assert.equal(await finishDrop(engine, uris, () => '', [png], { hook, log: (l) => logs.push(l) }), true);
    assert.deepEqual(calls, [['dragDrop', true], ['dragData', null]], 'no files: the app reads an empty list');
  }
  {
    const { engine, calls } = recorder();
    const logs: string[] = [];
    assert.equal(await finishDrop(engine, uris, () => '', [png], { hook: () => new Promise(() => {}), timeoutMs: 20, log: (l) => logs.push(l) }), true);
    assert.deepEqual(calls, [['dragDrop', true], ['dragData', null]], 'a hook that never answers: the timeout');
    assert.ok(logs.some((l) => l.includes('20 ms')));
  }
  {
    const { engine, calls } = recorder();
    assert.equal(await finishDrop(engine, uris, () => '', [png], { hook: async () => ['/x'], stale: () => true }), true);
    assert.deepEqual(calls, [['dragDrop', true]], 'another drag began: its data is not this one\'s');
  }
  // no hook: content, over the cap with no text → cancelled
  const content = dropPlan(['Files'], ['image/png'], false);
  {
    const { engine, calls } = recorder();
    assert.equal(await finishDrop(engine, content, () => '', [file('b.png', 'image/png', 'x'.repeat(9))], { maxBytes: 8 }), false);
    assert.deepEqual(calls, [['dragCancel']]);
  }
  {
    const { engine, calls } = recorder();
    assert.equal(await finishDrop(engine, content, () => '', [png]), true);
    assert.equal(calls[0][0], 'dragDrop');
    assert.deepEqual(Object.keys(calls[1][1] as object), ['image/png']);
    assert.equal(new TextDecoder().decode((calls[1][1] as Record<string, Uint8Array>)['image/png']), 'png');
  }
});

test('dnd bridge, files: with a hook a drag of files offers text/uri-list (copy only, whatever it allows), the drop is made at once and the hook\'s URIs follow; a rejecting hook drops no files', async () => {
  const dom = installFakeDom();
  try {
    let answer: (files: File[]) => Promise<string[] | null> = async (files) => files.map((f) => `/home/u/Downloads/${f.name}`);
    const r = dndRig(dom, { files: (files) => answer(files) });
    const png = file('shot one.png', 'image/png', 'png');
    const dt = r.transfer({}, 'all', [], [png]);
    r.drag('dragenter', dt, 5, 5);
    assert.deepEqual(r.calls[0], ['dragBegin', ['text/uri-list'], DND_COPY]);
    r.state.action = DND_COPY;
    r.calls.length = 0;
    r.drag('drop', dt, 5, 5);
    assert.deepEqual(r.calls, [['dragDrop', true], ['pointerEnter', 1, 5, 5, 5]], 'dropped at once: the pointer is the apps\' again');
    await tick();
    assert.deepEqual(r.calls[2], ['dragData', { 'text/uri-list': 'file:///home/u/Downloads/shot%20one.png\r\n' }]);

    answer = () => Promise.reject(new Error('quota'));
    r.drag('dragenter', dt, 5, 5);
    r.calls.length = 0;
    r.drag('drop', dt, 5, 5);
    await tick();
    assert.deepEqual(r.calls.filter((c) => c[0] !== 'pointerEnter'), [['dragDrop', true], ['dragData', null]]);
    assert.ok(r.logs.some((l) => l.includes('quota')));
    r.dispose();
    await tick();
  } finally {
    dom.uninstall();
  }
});

test('dnd bridge, files without a hook: each file type is offered as itself; at the drop the first file within the cap is its content; one over the cap (nothing else to drop) cancels the drag; a file with no type offers nothing', async () => {
  const dom = installFakeDom();
  try {
    const r = dndRig(dom, { maxBytes: 8 });
    const ok = file('a.png', 'image/png', 'png');
    const dt = r.transfer({}, 'copyMove', [], [ok]);
    r.drag('dragenter', dt, 5, 5);
    assert.deepEqual(r.calls[0], ['dragBegin', ['image/png'], DND_COPY], 'copy only: never a move of files');
    r.state.action = DND_COPY;
    r.calls.length = 0;
    r.drag('drop', dt, 5, 5);
    await tick();
    assert.deepEqual(r.calls.map((c) => c[0]), ['dragDrop', 'pointerEnter', 'dragData']);
    assert.equal(new TextDecoder().decode((r.calls[2][1] as Record<string, Uint8Array>)['image/png']), 'png');

    const big = r.transfer({}, 'all', [], [file('b.png', 'image/png', 'x'.repeat(9))]);
    r.drag('dragenter', big, 5, 5);
    r.calls.length = 0;
    r.drag('drop', big, 5, 5);
    assert.deepEqual(r.calls.map((c) => c[0]), ['dragCancel', 'pointerEnter']);

    r.calls.length = 0;
    const untyped = r.transfer({}, 'all', [], [file('blob', '', 'x')]);
    r.drag('dragenter', untyped, 5, 5);
    assert.deepEqual(r.calls, []);
    r.dispose();
    await tick();
  } finally {
    dom.uninstall();
  }
});
