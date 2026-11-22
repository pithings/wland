// The DOM half of the client (view, input, wm, createWland) on the fake DOM
// in fake-dom.ts: what the browser tests can't pin down deterministically.
// Needs a prior `zig build` (lib/wland.wasm).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { installFakeDom } from './fake-dom.ts';
import { createView, watchOutput } from '../lib/view.ts';
import { createInput } from '../lib/input.ts';
import { createWindowManager, type WindowManagerOptions } from '../lib/wm.ts';
import { createWland, type ViewWindow, type Wland } from '../lib/client.ts';
import type { Engine, Link, LinkCallbacks, Role } from '../lib/engine.ts';

const wasm = await readFile(new URL('../lib/wland.wasm', import.meta.url));

type ScriptedLink = Link & { sent: Uint8Array[]; bufferedAmount: number; cb: LinkCallbacks | null };

function scriptedLink(): ScriptedLink {
  const link: ScriptedLink = {
    sent: [], bufferedAmount: 0, cb: null,
    start: (cb) => { link.cb = cb; },
    send: (bytes) => { link.sent.push(bytes); },
  };
  return link;
}

// collect what the client reports with queueMicrotask(() => { throw e })
// instead of letting it fail the test run
async function catchAsyncThrows(fn: () => Promise<void>): Promise<any[]> {
  const caught: any[] = [];
  const orig = globalThis.queueMicrotask;
  globalThis.queueMicrotask = (cb) => orig(() => { try { cb(); } catch (e) { caught.push(e); } });
  try {
    await fn();
    await new Promise((r) => setTimeout(r, 0));
  } finally {
    globalThis.queueMicrotask = orig;
  }
  return caught;
}

test('view: a new toplevel is presented before it takes focus (focus calls the engine, which may detach pixels)', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const backing = new ArrayBuffer(16);
    const pixels = new Uint8Array(backing).fill(7);
    const calls: (string | symbol)[] = [];
    // what the real engine can do inside keyboardEnter: run the core, grow
    // its memory, and so detach a wasm-backed pixels view
    const engine = new Proxy({} as Engine, {
      get: (_, name) => (..._args: unknown[]) => {
        calls.push(name);
        if (name === 'keyboardEnter') backing.transfer();
      },
    });
    createInput({ engine, view, container });
    view.handle({
      type: 'commit', conn: 1, surface: 5, role: 1, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 2, height: 2 },
      width: 2, height: 2, logicalWidth: 2, logicalHeight: 2, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 2, 2]), pixels,
    });
    const canvas = view.canvas(1, 5) as any;
    assert.equal(canvas.puts.length, 1, 'the first frame was painted');
    assert.deepEqual([...canvas.puts[0][0].data], new Array(16).fill(7));
    assert.deepEqual(calls, ['keyboardEnter'], 'and then the window took keyboard focus');
  } finally {
    dom.uninstall();
  }
});

test('view: a gpu commit draws its image\'s damaged rects (clear, then draw); a different size is scaled whole; null keeps the canvas', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const gpu = { kind: 'virtgpu' as const, resource: 9, width: 4, height: 2, format: 0x34324258, flags: 0, offset: 0, stride: 16, modifier: 0n };
    const commit = (image: unknown, damage: number[]) => view.handle({
      type: 'commit', conn: 1, surface: 5, role: 1, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 4, height: 2 },
      width: 4, height: 2, logicalWidth: 4, logicalHeight: 2, format: 'gpu', stride: 0,
      damage: new Int32Array(damage), pixels: new Uint8Array(0), gpu, image,
    });
    const bitmap = { width: 4, height: 2 }; // an ImageBitmap's shape
    commit(bitmap, [0, 0, 4, 2, 1, 1, 2, 1]);
    const canvas = view.canvas(1, 5) as any;
    assert.deepEqual(canvas.draws, [
      ['clear', 0, 0, 4, 2], ['draw', bitmap, 0, 0, 4, 2, 0, 0, 4, 2],
      ['clear', 1, 1, 2, 1], ['draw', bitmap, 1, 1, 2, 1, 1, 1, 2, 1],
    ]);
    canvas.draws.length = 0;
    const video = { displayWidth: 8, displayHeight: 4 }; // a VideoFrame at 2x
    commit(video, [0, 0, 1, 1]);
    assert.deepEqual(canvas.draws, [['clear', 0, 0, 4, 2], ['draw', video, 0, 0, 4, 2]]);
    canvas.draws.length = 0;
    commit(null, [0, 0, 4, 2]);
    assert.deepEqual(canvas.draws, []);
    assert.equal(canvas.puts.length, 0);
    assert.equal(canvas.style.display, 'block', 'laid out like any commit');
  } finally {
    dom.uninstall();
  }
});

test('view: the window element is the window geometry\'s box; canvases sit at the surface origin inside it', () => {
  const dom = installFakeDom();
  try {
    const view = createView({ container: dom.container(), webgl: 'never' });
    const commit = (surface: number, role: 1 | 2, x: number, y: number, w: number, h: number,
      geometry: { x: number; y: number; width: number; height: number }) => view.handle({
      type: 'commit', conn: 1, surface, role, root: 5, x, y, maximized: false, fullscreen: false, minimized: false, geometry,
      width: w, height: h, logicalWidth: w, logicalHeight: h, format: 'rgba', stride: 0,
      damage: new Int32Array(0), pixels: new Uint8Array(0),
    });
    const box = () => {
      const el = view.window(1, 5)!.element as any, origin = view.canvas(1, 5)!.parentElement as any;
      assert.equal(origin.parentElement, el, 'canvases live in the origin element inside the window element');
      return [el.style.width, el.style.height, origin.style.left, origin.style.top];
    };

    // no geometry known yet: the box is the toplevel's
    commit(5, 1, 0, 0, 70, 47, { x: 0, y: 0, width: 0, height: 0 });
    assert.deepEqual(box(), ['70px', '47px', '0px', '0px']);
    // a titlebar subsurface above the toplevel grows the box around both
    // (xwayland-satellite: no set_window_geometry, so the bounds of the tree)
    commit(6, 2, 0, -25, 70, 25, { x: 0, y: -25, width: 70, height: 72 });
    assert.deepEqual(box(), ['70px', '72px', '0px', '25px']);
    const bar = view.canvas(1, 6) as any;
    assert.deepEqual([bar.parentElement, bar.style.left, bar.style.top], [view.canvas(1, 5)!.parentElement, '0px', '-25px']);
    // a frame inside shadow margins (GTK): the box is the frame, the canvas
    // overflows it by the margins
    commit(5, 1, 0, 0, 122, 96, { x: 26, y: 23, width: 70, height: 50 });
    assert.deepEqual(box(), ['70px', '50px', '-26px', '-23px']);
    assert.deepEqual([(view.canvas(1, 5) as any).style.width, (view.canvas(1, 5) as any).style.left], ['122px', '0px']);
  } finally {
    dom.uninstall();
  }
});

test('view: an input region makes the canvas inert and a hit element clipped to the region the target; null hands it back', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const calls: unknown[][] = [];
    const engine = new Proxy({} as Engine, {
      get: (_, name) => (...args: unknown[]) => { calls.push([name, ...args]); },
    });
    const input = createInput({ engine, view, container });
    const wm = createWindowManager({ engine, view, input, container });
    const feed = (ev: Parameters<typeof view.handle>[0]) => { view.handle(ev); input.handle(ev); wm.handle(ev); };
    const commit = (surface: number, role: 1 | 4, x: number, y: number, w: number, h: number) => feed({
      type: 'commit', conn: 1, surface, role, root: 5, x, y, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 10, y: 10, width: 60, height: 40 },
      width: w, height: h, logicalWidth: w, logicalHeight: h, format: 'rgba', stride: 0,
      damage: new Int32Array(0), pixels: new Uint8Array(0),
    });
    // the region can come before the surface's first commit (same WIRE frame)
    feed({ type: 'input-region', conn: 1, surface: 5, region: new Int32Array([8, 8, 64, 44, -5, 50, 200, 100]) });
    commit(5, 1, 0, 0, 80, 60);
    const canvas = view.canvas(1, 5) as any;
    const hit = canvas.parentElement.children[canvas.parentElement.children.indexOf(canvas) + 1];
    assert.equal(hit.dataset.wlandHit, 'c1s5', 'right after its canvas: same stacking');
    assert.equal(canvas.style.pointerEvents, 'none');
    assert.equal(hit.style.pointerEvents, 'auto', 'spelled out: the window element is none');
    assert.deepEqual([hit.style.left, hit.style.top, hit.style.width, hit.style.height, hit.style.display],
      ['0px', '0px', '80px', '60px', 'block'], 'the canvas\'s box: surface-local coordinates measure the same');
    assert.equal(hit.style.clipPath, "path('M8 8H72V52H8ZM0 50H80V60H0Z')", 'rects clipped to the surface');
    assert.deepEqual(view.surfaceOf(hit), { conn: 1, surface: 5, root: 5, role: 1 });

    // pointer events on the hit element reach the surface, a press focuses it
    calls.length = 0;
    dom.document.dispatch('pointerover', { target: hit, clientX: 20, clientY: 20 });
    dom.document.dispatch('pointerdown', { target: hit, button: 0 });
    assert.deepEqual(calls.map((c) => c[0]), ['pointerEnter', 'pointerButton']);

    // a popup with a shadow: a press on its hit element keeps it, one that
    // fell through its shadow onto the toplevel dismisses it
    feed({ type: 'input-region', conn: 1, surface: 6, region: new Int32Array([4, 4, 12, 12]) });
    commit(6, 4, 30, 20, 20, 20);
    const popCanvas = view.canvas(1, 6) as any;
    const popHit = popCanvas.parentElement.children[popCanvas.parentElement.children.indexOf(popCanvas) + 1];
    assert.ok(Number(popHit.style.zIndex) > 0 && popHit.style.zIndex === popCanvas.style.zIndex, 'stacked above the toplevel, with its canvas');
    calls.length = 0;
    dom.document.dispatch('pointerdown', { target: popHit, button: 0 });
    assert.ok(!calls.some((c) => c[0] === 'popupDismiss'));
    dom.document.dispatch('pointerdown', { target: hit, button: 0 });
    assert.deepEqual(calls.filter((c) => c[0] === 'popupDismiss'), [['popupDismiss', 1, 6]]);

    // a region with nothing inside the surface: no hit target at all
    feed({ type: 'input-region', conn: 1, surface: 5, region: new Int32Array([100, 100, 5, 5]) });
    assert.equal(hit.style.display, 'none');
    assert.equal(canvas.style.pointerEvents, 'none');
    // unmapped: hidden with its canvas
    feed({ type: 'input-region', conn: 1, surface: 5, region: new Int32Array([0, 0, 10, 10]) });
    assert.equal(hit.style.display, 'block');
    feed({ type: 'surface', conn: 1, surface: 5, role: 0, root: 5 });
    assert.ok(!hit.parentElement, 'a role-less surface takes no input');
    commit(5, 1, 0, 0, 80, 60);
    const hit2 = canvas.parentElement.children[canvas.parentElement.children.indexOf(canvas) + 1];
    assert.deepEqual([hit2.dataset.wlandHit, hit2.style.clipPath], ['c1s5', "path('M0 0H10V10H0Z')"], 'mapped again, region kept');
    // null: the whole surface again, the canvas is the target
    feed({ type: 'input-region', conn: 1, surface: 5, region: null });
    assert.ok(!hit2.parentElement);
    assert.equal(canvas.style.pointerEvents, 'auto', 'spelled out: the window element is none');
    assert.equal(view.surfaceOf(hit), null);
    // and the hit element goes with its surface
    feed({ type: 'destroy', conn: 1, surface: 6 });
    assert.ok(!popHit.parentElement);
    wm.dispose();
    input.dispose();
  } finally {
    dom.uninstall();
  }
});

test('view: the window element takes no pointer, so a hole in an input region inside the geometry passes the press to the window behind; canvases and hit elements say auto, inert ones none', async () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const calls: unknown[][] = [];
    const engine = new Proxy({} as Engine, {
      get: (_, name) => (...args: unknown[]) => { calls.push([name, ...args]); },
    });
    const input = createInput({ engine, view, container });
    const wm = createWindowManager({ engine, view, input, container });
    const feed = (ev: Parameters<typeof view.handle>[0]) => { view.handle(ev); input.handle(ev); wm.handle(ev); };
    const commit = (conn: number, surface: number, role: 1 | 2 | 4 | 5, root: number, w: number, h: number) => feed({
      type: 'commit', conn, surface, role, root, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: role === 1 ? w : 0, height: role === 1 ? h : 0 },
      width: w, height: h, logicalWidth: w, logicalHeight: h, format: 'rgba', stride: 0,
      damage: new Int32Array(0), pixels: new Uint8Array(0),
    });
    const pe = (el: any) => el.style.pointerEvents;
    // B behind, then A on top of it: a frame whose region is its border
    commit(2, 7, 1, 7, 200, 150);
    commit(1, 5, 1, 5, 120, 90);
    feed({ type: 'input-region', conn: 1, surface: 5, region: new Int32Array([0, 0, 120, 8, 0, 82, 120, 8, 0, 8, 8, 74, 112, 8, 8, 74]) });
    const a = view.window(1, 5)!.element as any, b = view.window(2, 7)!.element as any;
    const aHit = view.hitTarget(1, 5) as any, bCanvas = view.canvas(2, 7) as any;
    assert.deepEqual([pe(a), pe(b)], ['none', 'none'], 'the box is no hit target: a hole shows what is behind');
    assert.deepEqual([pe(view.canvas(1, 5)), pe(aHit), pe(bCanvas)], ['none', 'auto', 'auto'], 'explicit: none is inherited');
    // a subsurface and a popup are their own targets too; a dnd icon is not
    commit(2, 8, 2, 7, 20, 20);
    commit(2, 9, 4, 7, 30, 30);
    commit(2, 10, 5, 10, 16, 16);
    assert.deepEqual([pe(view.canvas(2, 8)), pe(view.canvas(2, 9)), pe(view.canvas(2, 10))], ['auto', 'auto', 'none']);

    // through A's hole the browser targets B's canvas: B is focused and raised
    assert.ok(Number(a.style.zIndex) > Number(b.style.zIndex));
    assert.ok(input.focused(1, 5));
    calls.length = 0;
    b.dispatch('pointerdown', { target: bCanvas, button: 0 }); // the default mount's raise (capture on the box)
    dom.document.dispatch('pointerdown', { target: bCanvas, button: 0 });
    assert.ok(Number(b.style.zIndex) > Number(a.style.zIndex), 'raised');
    assert.ok(input.focused(2, 7), 'focused');
    assert.deepEqual(calls.filter((c) => c[0] === 'pointerButton').map((c) => c[1]), [2], 'the press went to B');
    assert.deepEqual(calls.filter((c) => c[0] === 'popupDismiss'), [['popupDismiss', 2, 9]], 'a press off the popup');
    wm.dispose();
    input.dispose();
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('view: a cursor surface is the CSS cursor (image-set at its scale, hotspot, last frame as fallback); too big or off-image, its canvas follows the pointer', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const commit = (surface: number, role: 1 | 3, w: number, h: number, lw: number, lh: number) => view.handle({
      type: 'commit', conn: 1, surface, role, root: surface, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: role === 1 ? lw : 0, height: role === 1 ? lh : 0 },
      width: w, height: h, logicalWidth: lw, logicalHeight: lh, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, w, h]), pixels: new Uint8Array(w * h * 4),
    });
    const cursor = (cursor: string, surface: number, hotspotX = 0, hotspotY = 0) =>
      view.handle({ type: 'cursor', conn: 1, cursor, surface, hotspotX, hotspotY });
    commit(5, 1, 80, 60, 80, 60);
    const win = view.window(1, 5)!.element as any;

    // GTK order: the buffer (2x: 48 px for 24 logical) before set_cursor
    commit(7, 3, 48, 48, 24, 24);
    const cur = view.canvas(1, 7) as any;
    assert.equal(cur.style.display, 'none', 'never shown in place');
    cursor('default', 7, 4, 5);
    assert.equal(win.style.cursor, 'image-set(url("data:image/png;base64,48x48n1") 2x) 4 5, default');
    // the next frame (animated cursor): the previous one is the fallback while it decodes
    commit(7, 3, 48, 48, 24, 24);
    assert.equal(win.style.cursor,
      'image-set(url("data:image/png;base64,48x48n2") 2x) 4 5, image-set(url("data:image/png;base64,48x48n1") 2x) 4 5, default');
    // the hotspot moves (set_cursor again, a committed offset): same image
    cursor('default', 7, 1, 1);
    assert.match(win.style.cursor, /^image-set\(url\("data:image\/png;base64,48x48n2"\) 2x\) 1 1, /);
    // a window the client maps meanwhile gets it too
    commit(9, 1, 20, 20, 20, 20);
    assert.equal((view.window(1, 9)!.element as any).style.cursor, win.style.cursor);

    // a hotspot outside the image: CSS would ignore it, so the canvas is
    // drawn at the pointer, input-inert, over everything
    dom.document.dispatch('pointermove', { clientX: 100, clientY: 50 });
    cursor('default', 7, 30, -2);
    assert.equal(win.style.cursor, 'none');
    assert.equal(cur.parentElement, container);
    assert.deepEqual([cur.style.display, cur.style.position, cur.style.pointerEvents, cur.style.left, cur.style.top],
      ['block', 'fixed', 'none', '70px', '52px']);
    dom.document.dispatch('pointermove', { clientX: 110, clientY: 60 });
    assert.deepEqual([cur.style.left, cur.style.top], ['80px', '62px'], 'it follows the pointer');
    commit(7, 3, 48, 48, 24, 24);
    assert.equal(cur.style.display, 'block', 'a new frame keeps it shown');
    // back in range: CSS again, the canvas hidden
    cursor('default', 7, 2, 2);
    assert.match(win.style.cursor, /^image-set\(url\("data:image\/png;base64,48x48n3"\) 2x\) 2 2, default$/);
    assert.equal(cur.style.display, 'none');
    // above the browsers' 128 px cap: drawn as an element too
    commit(7, 3, 300, 300, 150, 150);
    assert.equal(win.style.cursor, 'none');
    assert.equal(cur.style.display, 'block');

    // set_cursor NULL hides the pointer; leaving restores the default
    cursor('none', 0);
    assert.equal(win.style.cursor, 'none');
    assert.equal(cur.style.display, 'none');
    cursor('', 0);
    assert.equal(win.style.cursor, '');
    // a shape after an image: just the shape
    cursor('default', 7, 2, 2);
    cursor('text', 0);
    assert.equal(win.style.cursor, 'text');

    // destroyed while drawn as the element: gone with it
    cursor('default', 7, 2, 2);
    assert.equal(cur.style.display, 'block');
    view.handle({ type: 'destroy', conn: 1, surface: 7 });
    assert.ok(!cur.parentElement);
    view.dispose();
    assert.equal(dom.leftovers().documentListeners, 0, 'the pointer tracker is removed');
  } finally {
    dom.uninstall();
  }
});

test('input: the implicit grab is pointer capture on the pressed target; a wm grab or a popup of the pressed client lets it go', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const calls: unknown[][] = [];
    const engine = new Proxy({} as Engine, {
      get: (_, name) => (...args: unknown[]) => { calls.push([name, ...args]); },
    });
    const input = createInput({ engine, view, container });
    const wm = createWindowManager({ engine, view, input, container });
    const feed = (ev: Parameters<typeof view.handle>[0]) => { view.handle(ev); input.handle(ev); wm.handle(ev); };
    const commit = (surface: number, role: 1 | 4) => feed({
      type: 'commit', conn: 1, surface, role, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 40, height: 40 },
      width: 40, height: 40, logicalWidth: 40, logicalHeight: 40, format: 'rgba', stride: 0,
      damage: new Int32Array(0), pixels: new Uint8Array(0),
    });
    commit(5, 1);
    const canvas = view.canvas(1, 5) as any;
    const down = (target: any) => dom.document.dispatch('pointerdown', { target, button: 0, pointerId: 1 });

    down(canvas);
    assert.equal(canvas.captured, 1, 'the press captures the pointer to its target');
    // the browser routes everything to the captured element, outside it too:
    // the motion stays the pressed surface's
    calls.length = 0;
    dom.document.dispatch('pointermove', { target: canvas, clientX: -30, clientY: 70 });
    dom.document.dispatch('pointerup', { target: canvas, button: 0, pointerId: 1 });
    assert.deepEqual(calls.map((c) => c[0]), ['pointerMotion', 'pointerButton']);
    assert.deepEqual(calls[0]!.slice(1, 2).concat(calls[0]!.slice(3, 5)), [1, -30, 70]);
    canvas.captured = null; // capture ends after the last pointerup
    dom.document.dispatch('lostpointercapture', { target: canvas, pointerId: 1 });

    // a window-manager grab (xdg_toplevel.move) takes the pointer over
    down(canvas);
    assert.equal(canvas.captured, 1);
    feed({ type: 'move', conn: 1, surface: 5 });
    assert.equal(canvas.captured, null, 'released: the browser tracks the pointer for the grab');
    dom.document.dispatch('pointerup', { target: container, button: 0, pointerId: 1, clientX: 0, clientY: 0 });

    // a popup of the pressed client maps (a popup grab): released too,
    // and a press on the popup captures again — its own commits keep it
    down(canvas);
    commit(6, 4);
    assert.equal(canvas.captured, null);
    dom.document.dispatch('pointerup', { target: canvas, button: 0, pointerId: 1 });
    const pop = view.canvas(1, 6) as any;
    down(pop);
    assert.equal(pop.captured, 1);
    commit(6, 4);
    assert.equal(pop.captured, 1);
    // its surface goes: the next press captures afresh
    feed({ type: 'destroy', conn: 1, surface: 6 });
    down(canvas);
    assert.equal(canvas.captured, 1);
    input.dispose();
    assert.equal(canvas.captured, null, 'dispose lets go');
    wm.dispose();
  } finally {
    dom.uninstall();
  }
});

test('input: pointer lock — requested on the hit target (raw movement first), reported on pointerlockchange, retried at the next press; under it relative motion only, the cursor surface drawn frozen', async () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const calls: unknown[][] = [];
    const engine = new Proxy({} as Engine, {
      get: (_, name) => (...args: unknown[]) => { calls.push([name, ...args]); },
    });
    const input = createInput({ engine, view, container });
    const feed = (ev: Parameters<typeof view.handle>[0]) => { view.handle(ev); input.handle(ev); };
    const commit = (surface: number, role: 1 | 3, w: number) => feed({
      type: 'commit', conn: 1, surface, role, root: surface, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: role === 1 ? w : 0, height: role === 1 ? w : 0 },
      width: w, height: w, logicalWidth: w, logicalHeight: w, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, w, w]), pixels: new Uint8Array(w * w * 4),
    });
    feed({ type: 'input-region', conn: 1, surface: 5, region: new Int32Array([0, 0, 50, 50]) });
    commit(5, 1, 60);
    const canvas = view.canvas(1, 5) as any;
    const hit = view.hitTarget(1, 5) as any;
    assert.notEqual(hit, canvas, 'with an input region the hit element is the target');
    const flush = () => new Promise((r) => setTimeout(r, 0));
    const doc = dom.document;
    const names = () => calls.map((c) => c[0]);

    // the core wants it while the page has activation (the click that made
    // the app ask): requested at once, raw movement first; Linux refuses
    // that, so again without it
    doc.lockResult = () => Promise.reject(Object.assign(new Error('no'), { name: 'NotSupportedError' }));
    feed({ type: 'pointer-lock', conn: 1, surface: 5 });
    await flush();
    assert.deepEqual(hit.lockRequests, [{ unadjustedMovement: true }, undefined]);
    assert.deepEqual(canvas.lockRequests, []);
    // granted: reported once
    doc.lockResult = null;
    calls.length = 0;
    dom.lock(hit);
    dom.lock(hit);
    assert.deepEqual(calls, [['pointerLockGranted', 1, 5]]);

    // locked: motion carries movementX/Y; no boundary events reach the app
    calls.length = 0;
    doc.dispatch('pointermove', { target: hit, clientX: 10, clientY: 10, movementX: 7, movementY: -3, timeStamp: 1.5 });
    doc.dispatch('pointerout', { target: hit });
    doc.dispatch('pointerover', { target: canvas });
    assert.deepEqual(calls, [['pointerMotion', 1, calls[0]![2], 10, 10, { dx: 7, dy: -3, time: 1500 }]]);

    // a cursor surface: CSS while unlocked; under the lock (the browser
    // hides the pointer) drawn as the element where the pointer froze
    commit(7, 3, 16);
    feed({ type: 'cursor', conn: 1, cursor: 'default', surface: 7, hotspotX: 1, hotspotY: 1 });
    const cur = view.canvas(1, 7) as any;
    assert.deepEqual([cur.style.display, view.window(1, 5)!.element.style.cursor], ['block', 'none']);
    dom.lock(null); // the user pressed Esc
    assert.equal(cur.style.display, 'none');
    assert.match(view.window(1, 5)!.element.style.cursor, /^image-set\(/);
    assert.deepEqual(names().slice(-1), ['pointerLockLost']);

    // still wanted (persistent): without activation nothing is asked
    // until the next press on its surface
    dom.activation.isActive = false;
    hit.lockRequests.length = 0;
    feed({ type: 'pointer-lock', conn: 1, surface: 5 });
    assert.deepEqual(hit.lockRequests, []);
    doc.dispatch('pointerdown', { target: hit, button: 0, pointerId: 1 });
    assert.deepEqual(hit.lockRequests, [undefined], 'the press is the gesture (raw movement known refused)');
    dom.lock(hit);
    // the core withdraws it: the browser's lock goes, nothing is reported
    calls.length = 0;
    feed({ type: 'pointer-lock', conn: 1, surface: 0 });
    assert.equal(doc.pointerLockElement, null);
    assert.deepEqual(calls, []);
    // a late grant nobody wants is let go at once
    const exits = doc.exits;
    dom.lock(hit);
    assert.equal(doc.exits, exits + 1);
    assert.deepEqual(calls, []);
    input.dispose();
    view.dispose();
    assert.equal(dom.leftovers().documentListeners, 0);
  } finally {
    dom.uninstall();
  }
});

test('input: when the focused window closes or unmaps, focus passes to the topmost window left', async () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const calls: unknown[][] = [];
    const engine = new Proxy({} as Engine, {
      get: (_, name) => (...args: unknown[]) => { calls.push([name, ...args]); },
    });
    let focusChanges = 0;
    const input = createInput({ engine, view, container, onFocusChange: () => { focusChanges++; } });
    const feed = (ev: Parameters<typeof view.handle>[0]) => { view.handle(ev); input.handle(ev); };
    const map = (conn: number, surface: number) => feed({
      type: 'commit', conn, surface, role: 1, root: surface, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 4, height: 4 },
      width: 4, height: 4, logicalWidth: 4, logicalHeight: 4, format: 'rgba', stride: 0,
      damage: new Int32Array(0), pixels: new Uint8Array(0),
    });
    map(1, 5);
    map(2, 5);
    map(3, 5);
    assert.ok(input.focused(3, 5), 'the last one mapped has focus');
    view.raise(1, 5); // stacked above c2, below nothing but the focused c3… then c3 goes
    view.raise(3, 5);

    calls.length = 0;
    focusChanges = 0;
    feed({ type: 'destroy', conn: 3, surface: 5 });
    assert.deepEqual(calls, [['keyboardEnter', 1, 5]], 'the next in the stack, and no leave naming the dead surface');
    assert.ok(input.focused(1, 5) && focusChanges === 1);

    // unmapped with the wl_surface alive: a leave, then the window left
    calls.length = 0;
    feed({ type: 'surface', conn: 1, surface: 5, role: 0, root: 5 });
    assert.deepEqual(calls, [['keyboardLeave', 1], ['keyboardEnter', 2, 5]]);

    // the last window's app hangs up: focus is just gone
    calls.length = 0;
    feed({ type: 'disconnect', conn: 2 });
    assert.deepEqual(calls, []);
    assert.ok(!input.focused(2, 5));
    await new Promise((r) => setTimeout(r, 0)); // the sink's blur checks run in microtasks
  } finally {
    dom.uninstall();
  }
});

test('createWland: an embedder onEvent that throws keeps neither the others from the event nor the frame loop from starting', async () => {
  const dom = installFakeDom();
  try {
    const link = scriptedLink();
    const frames: number[] = [];
    const caught = await catchAsyncThrows(async () => {
      await createWland({
        container: dom.container(), wasm, link, webgl: 'never', scale: 1,
        onEvent() { throw new Error('embedder bug'); },
      });
      link.cb!.onOpen();
      frames.push(dom.leftovers().frames);
      dom.frame();
      frames.push(dom.leftovers().frames);
    });
    assert.ok(caught.length >= 1 && caught.every((e) => e.message === 'embedder bug'));
    assert.deepEqual(frames, [1, 1], 'the rAF loop starts and keeps running');
  } finally {
    dom.uninstall();
  }
});

test('createWland dispose(): unmounts everything and leaves no listener, observer, watcher or frame behind', async () => {
  const dom = installFakeDom();
  try {
    const before = dom.leftovers();
    const container = dom.container();
    const link = scriptedLink();
    let linkClosed = 0;
    link.close = () => { linkClosed++; };
    const changes: (number | undefined)[] = [];
    const wl: Wland = await createWland({ container, wasm, link, webgl: 'never', onWindowsChange: () => changes.push(wl && wl.windows().length) });
    link.cb!.onOpen();
    // a mapped window (the view is fed directly; its pixels are irrelevant here)
    wl.view.handle({
      type: 'commit', conn: 1, surface: 5, role: 1, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 1, height: 1 },
      width: 1, height: 1, logicalWidth: 1, logicalHeight: 1, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 1, 1]), pixels: new Uint8Array(4),
    });
    assert.equal(wl.windows().length, 1);
    const during = dom.leftovers();
    assert.ok(during.documentListeners > 0 && during.observers === 1 && during.mediaListeners === 1 && during.frames === 1);
    assert.equal(container.children.length, 2); // the IME sink and the window

    wl.dispose();
    wl.dispose();
    assert.deepEqual(dom.leftovers(), before);
    assert.equal(container.children.length, 0);
    assert.equal(linkClosed, 1);
    assert.equal(wl.windows().length, 0);
    assert.equal(changes.at(-1), 0);
    // a late link callback reaches nothing
    link.cb!.onClose({ takenOver: false });
    assert.equal(dom.leftovers().frames, 0);
  } finally {
    dom.uninstall();
  }
});

test('watchOutput: follows the container (a hidden one keeps the last size) and devicePixelRatio; setSize / setScale pin either, null follows again', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const calls: unknown[][] = [];
    const engine = new Proxy({} as Engine, { get: (_, name) => (...args: unknown[]) => { if (name !== 'setSuspended') calls.push([name, ...args]); } });
    const before = dom.leftovers();
    const out = watchOutput(engine, container);
    const take = () => calls.splice(0);
    assert.deepEqual(take(), [['setOutput', 800, 600], ['setScale', 1, 120]]);
    assert.deepEqual(out.state(), { width: 800, height: 600, scale: 1, sizePinned: false, scalePinned: false });

    // the page's layout: a container resize is the output's
    dom.resize(container, 1024, 700);
    dom.resize(container, 1024, 700); // unchanged: nothing new
    assert.deepEqual(take(), [['setOutput', 1024, 700]]);
    dom.resize(container, 0, 0); // display: none — not an output size
    dom.resize(container, 0, 500);
    assert.deepEqual(take(), []);
    assert.equal(out.state().width, 1024);
    dom.resize(container, 1000, 640);
    assert.deepEqual(take(), [['setOutput', 1000, 640]]);
    // zoom / another display, fractional too
    dom.setDpr(1.5);
    dom.setDpr(2);
    assert.deepEqual(take(), [['setScale', 1.5, 180], ['setScale', 2, 240]]);

    // pinned: the page's changes no longer reach the engine
    out.setScale(1.25);
    out.setSize({ width: 1280, height: 720 });
    assert.deepEqual(take(), [['setScale', 1.25, 150], ['setOutput', 1280, 720]]);
    dom.setDpr(3);
    dom.resize(container, 900, 600);
    assert.deepEqual(take(), []);
    assert.deepEqual(out.state(), { width: 1280, height: 720, scale: 1.25, sizePinned: true, scalePinned: true });
    out.setScale(2); // re-pinned
    assert.deepEqual(take(), [['setScale', 2, 240]]);
    // unpinned: back to what the page says now
    out.setScale(null);
    out.setSize(null);
    assert.deepEqual(take(), [['setScale', 3, 360], ['setOutput', 900, 600]]);
    dom.setDpr(1);
    assert.deepEqual(take(), [['setScale', 1, 120]]);
    assert.throws(() => out.setSize({ width: 0, height: 10 }), RangeError);
    assert.throws(() => out.setScale(NaN), RangeError);
    assert.throws(() => out.setScale(-1), RangeError);
    assert.deepEqual(take(), []);

    out();
    assert.deepEqual(dom.leftovers(), before);
    dom.resize(container, 640, 480);
    dom.setDpr(2);
    assert.deepEqual(take(), []);
  } finally {
    dom.uninstall();
  }
});

test('createWland output: a fractional scale pinned at start; output.setSize / setScale after start reach the engine and survive resizes', async () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const link = scriptedLink();
    const wl = await createWland({ container, wasm, link, webgl: 'never', scale: 1.5 });
    link.cb!.onOpen();
    assert.deepEqual(wl.output.state(), { width: 800, height: 600, scale: 1.5, sizePinned: false, scalePinned: true });
    const calls: unknown[][] = [];
    const engine = wl.engine as any;
    for (const name of ['setOutput', 'setScale']) {
      const real = engine[name];
      engine[name] = (...args: unknown[]) => { calls.push([name, ...args]); real(...args); };
    }
    dom.setDpr(2); // pinned: ignored
    dom.resize(container, 1200, 800);
    wl.output.setSize({ width: 1920, height: 1080 });
    dom.resize(container, 1300, 800); // pinned now
    wl.output.setScale(null);
    wl.output.setSize(null);
    assert.deepEqual(calls, [['setOutput', 1200, 800], ['setOutput', 1920, 1080], ['setScale', 2, 240], ['setOutput', 1300, 800]]);
    wl.dispose();
    calls.length = 0;
    dom.resize(container, 10, 10);
    assert.deepEqual(calls, []);
  } finally {
    dom.uninstall();
  }
});

test('output: invalid values throw and change nothing (a scale before anything is set up, a size rounding below 1 px, NaN / Infinity)', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const calls: unknown[][] = [];
    const engine = new Proxy({} as Engine, { get: (_, name) => (...args: unknown[]) => { if (name !== 'setSuspended') calls.push([name, ...args]); } });
    const before = dom.leftovers();
    for (const bad of [-1, 0, NaN, Infinity]) {
      assert.throws(() => watchOutput(engine, container, bad), RangeError);
      assert.deepEqual(dom.leftovers(), before, `scale ${bad}: no observer or listener left`);
    }
    assert.deepEqual(calls, []);
    const out = watchOutput(engine, container);
    calls.length = 0;
    for (const bad of [{ width: 0.4, height: 0.4 }, { width: 800, height: 0.49 }, { width: NaN, height: 10 },
      { width: Infinity, height: 10 }, { width: 10, height: -3 }]) {
      assert.throws(() => out.setSize(bad), RangeError, `${bad.width} × ${bad.height}`);
    }
    assert.throws(() => out.setScale(Infinity), RangeError);
    assert.throws(() => out.setScale(0), RangeError);
    assert.deepEqual(calls, []);
    assert.equal(out.state().sizePinned, false);
    out.setSize({ width: 0.5, height: 99.6 }); // rounds to 1 × 100: a real size
    assert.deepEqual(calls, [['setOutput', 1, 100]]);
    out();
  } finally {
    dom.uninstall();
  }
});

test('createWland: an invalid scale or a failed start rejects and leaves nothing behind (no listener, observer, element)', async () => {
  const dom = installFakeDom();
  try {
    const before = dom.leftovers();
    const container = dom.container();
    let closed = 0;
    for (const scale of [-1, 0, NaN]) {
      const link = scriptedLink();
      link.close = () => { closed++; };
      await assert.rejects(createWland({ container, wasm, link, webgl: 'never', scale }), RangeError);
      assert.deepEqual(dom.leftovers(), before);
      assert.equal(container.children.length, 0);
    }
    assert.equal(closed, 0, 'the link was never started');
    // a wasm that doesn't load: the view existed already, and is undone
    await assert.rejects(createWland({ container, wasm: new Uint8Array([0, 1, 2, 3]), link: scriptedLink(), webgl: 'never' }));
    assert.deepEqual(dom.leftovers(), before);
    assert.equal(container.children.length, 0);
    // a later failure (here: the output watch, the last part), after the
    // engine, input and window manager exist: all of it is undone and the
    // engine disposed (its link closed)
    const link = scriptedLink();
    link.close = () => { closed++; };
    const g = globalThis as any;
    const RO = g.ResizeObserver;
    g.ResizeObserver = class { constructor() { throw new Error('no ResizeObserver'); } };
    try {
      await assert.rejects(createWland({ container, wasm, link, webgl: 'never' }), /no ResizeObserver/);
    } finally {
      g.ResizeObserver = RO;
    }
    assert.equal(closed, 1, 'the engine was disposed: its link closed');
    assert.deepEqual(dom.leftovers(), before);
    assert.equal(container.children.length, 0);
    // and the container is free for a working createWland
    const wl = await createWland({ container, wasm, link: scriptedLink(), webgl: 'never' });
    wl.dispose();
    assert.deepEqual(dom.leftovers(), before);
  } finally {
    dom.uninstall();
  }
});

test('createWland output: inert after dispose (no engine call, no media watch re-armed)', async () => {
  const dom = installFakeDom();
  try {
    const before = dom.leftovers();
    const container = dom.container();
    const wl = await createWland({ container, wasm, link: scriptedLink(), webgl: 'never', scale: 2 });
    const calls: unknown[][] = [];
    const engine = wl.engine as any;
    for (const name of ['setOutput', 'setScale']) engine[name] = (...args: unknown[]) => { calls.push([name, ...args]); };
    wl.dispose();
    const state = wl.output.state();
    wl.output.setScale(null);
    wl.output.setScale(3);
    wl.output.setSize({ width: 100, height: 100 });
    wl.output.setSize(null);
    assert.deepEqual(calls, []);
    assert.deepEqual(dom.leftovers(), before);
    assert.deepEqual(wl.output.state(), state);
  } finally {
    dom.uninstall();
  }
});

test('createWland onWindowsChange: a window whose subsurface commits first is announced at the toplevel commit', async () => {
  const dom = installFakeDom();
  try {
    const link = scriptedLink();
    const seen: string[] = [];
    const wl: Wland = await createWland({ container: dom.container(), wasm, link, webgl: 'never', onWindowsChange: () => seen.push(wl.windows().map((w) => w.focused ? 'focused' : 'listed').join() || 'none') });
    link.cb!.onOpen();
    const commit = (surface: number, role: Role) => wl.view.handle({
      type: 'commit', conn: 1, surface, role, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 1, height: 1 },
      width: 1, height: 1, logicalWidth: 1, logicalHeight: 1, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 1, 1]), pixels: new Uint8Array(4),
    });
    commit(6, 2); // a decoration subsurface of 5: the window element exists, not listed yet
    assert.equal(wl.windows().length, 0);
    commit(5, 1); // the toplevel
    assert.equal(wl.windows().length, 1);
    // announced by the commit itself, not only by the keyboard focus it then
    // takes (a page without focus, e.g. headless, gets no focusin)
    assert.ok(seen.includes('listed'), `notifications: ${seen.join(' ')}`);
    wl.dispose();
  } finally {
    dom.uninstall();
  }
});

test('createWland: the frame loop ticks with rAF timestamps and the display interval they measure', async () => {
  const dom = installFakeDom();
  try {
    const link = scriptedLink();
    const wl: Wland = await createWland({ container: dom.container(), wasm, link, webgl: 'never', scale: 1 });
    const ticks: [number, number | undefined][] = [];
    const tick = wl.engine.tick;
    wl.engine.tick = (time, refresh) => { ticks.push([time, refresh]); tick(time, refresh); };
    link.cb!.onOpen();
    const hz60 = 1000 / 60;
    let t = 1000;
    for (let i = 0; i < 8; i++) { dom.frame(t); t += hz60; }
    assert.deepEqual(ticks.slice(0, 5).map((x) => x[1]), [0, 0, 0, 0, 0], 'not known before 5 intervals');
    assert.ok(Math.abs(ticks[5][1]! - hz60) < 1e-9 && Math.abs(ticks[7][1]! - hz60) < 1e-9);
    assert.equal(ticks[0][0], 1000);
    // a hidden tab's gap and a dropped frame don't move it
    t += 5000;
    dom.frame(t);
    t += 2 * hz60;
    dom.frame(t);
    assert.ok(Math.abs(ticks.at(-1)![1]! - hz60) < 1e-9, `${ticks.at(-1)}`);
    wl.dispose();
  } finally {
    dom.uninstall();
  }
});

// --- window states: the view, input and window manager on a recording
// engine; the states arrive as events, as the core sends them ---------------
type Ev = Parameters<ReturnType<typeof createView>['handle']>[0];
function wmRig(dom: ReturnType<typeof installFakeDom>,
  opts: Pick<WindowManagerOptions, 'browserFullscreen' | 'shortcuts' | 'interactive'> & { autoFocus?: boolean } = {}) {
  const { autoFocus, ...wmOpts } = opts;
  const container = dom.container();
  const view = createView({ container, webgl: 'never', focusOnMap: autoFocus !== false });
  const calls: unknown[][] = [];
  const engine = new Proxy({} as Engine, {
    get: (_, name) => (...args: unknown[]) => { calls.push([name, ...args]); },
  });
  const input = createInput({ engine, view, container, autoFocus });
  const wm = createWindowManager({ engine, view, input, container, ...wmOpts });
  const feed = (ev: Ev) => { view.handle(ev); input.handle(ev); wm.handle(ev); };
  const commit = (conn: number, surface: number, st: { maximized?: boolean; fullscreen?: boolean; minimized?: boolean } = {},
    geometry = { x: 0, y: 0, width: 40, height: 30 }) => feed({
    type: 'commit', conn, surface, role: 1, root: surface, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false, ...st,
    geometry, width: 40, height: 30, logicalWidth: 40, logicalHeight: 30, format: 'rgba', stride: 0,
    damage: new Int32Array(0), pixels: new Uint8Array(0),
  });
  const el = (conn: number, surface: number) => view.window(conn, surface)!.element as any;
  const z = (conn: number, surface: number) => Number(el(conn, surface).style.zIndex);
  const key = (code: string, mods: { ctrlKey?: boolean; shiftKey?: boolean } = {}, type = 'keydown') => {
    let stopped = false;
    dom.document.dispatch(type, { altKey: true, ctrlKey: false, metaKey: false, shiftKey: false, repeat: false, ...mods, code,
      stopPropagation() { stopped = true; } });
    return stopped;
  };
  return {
    container, view, input, wm, calls, feed, commit, el, z, key,
    dispose() { wm.dispose(); input.dispose(); view.dispose(); },
  };
}

test('view + wm: fullscreen fills the container, the geometry centred on black, raised and focused; back to its box and place; maximized under it stays at the origin', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    r.commit(2, 5);
    const el = r.el(1, 5), st = el.style, origin = el.children[0].style;
    assert.deepEqual([st.left, st.top], ['24px', '48px']);
    r.calls.length = 0;
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: true });
    assert.deepEqual([st.left, st.top, st.width, st.height, st.background, st.overflow], ['0px', '0px', '100%', '100%', '#000', 'hidden']);
    assert.equal(st.pointerEvents, 'auto', 'the black backdrop covers the windows below: presses on it stop there');
    assert.equal(el.dataset.wlandFullscreen, '', 'a hook for page CSS (no shadows)');
    assert.deepEqual([origin.left, origin.top], ['calc(50% - 20px)', 'calc(50% - 15px)'], 'the 40×30 box centred');
    assert.ok(r.z(1, 5) > r.z(2, 5), 'on top');
    assert.deepEqual(r.calls, [['keyboardLeave', 2], ['keyboardEnter', 1, 5]]);
    assert.equal(r.view.window(1, 5)!.fullscreen, true);
    // the app's fullscreen buffer, its geometry inside a shadow margin
    r.commit(1, 5, { fullscreen: true }, { x: 10, y: 5, width: 800, height: 600 });
    assert.deepEqual([origin.left, origin.top, st.width], ['calc(50% - 410px)', 'calc(50% - 305px)', '100%']);

    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: false });
    r.commit(1, 5);
    assert.deepEqual([st.left, st.top, st.width, st.height, st.background, st.overflow], ['24px', '48px', '40px', '30px', '', 'visible']);
    assert.equal(st.pointerEvents, 'none');
    assert.ok(!('wlandFullscreen' in el.dataset));
    assert.deepEqual([origin.left, origin.top], ['0px', '0px']);

    r.feed({ type: 'maximize', conn: 1, surface: 5, maximized: true });
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: true });
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: false });
    assert.deepEqual([st.left, st.top], ['0px', '0px'], 'still maximized');
    r.feed({ type: 'maximize', conn: 1, surface: 5, maximized: false });
    assert.deepEqual([st.left, st.top], ['24px', '48px']);
    r.dispose();
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('input: KeyboardEvent.code → evdev, the keypad and the rest of a full keyboard included', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    const sink = r.container.children.find((c: any) => c.contentEditable === 'true');
    r.calls.length = 0;
    const codes: Record<string, number> = { KeyA: 30, Enter: 28, NumpadEnter: 96, Numpad0: 82, Numpad7: 71, NumpadDecimal: 83,
      NumpadAdd: 78, NumpadSubtract: 74, NumpadMultiply: 55, NumpadDivide: 98, NumLock: 69, IntlBackslash: 86, ContextMenu: 127, PrintScreen: 99 };
    for (const code of Object.keys(codes)) {
      sink.dispatch('keydown', { code, isComposing: false, keyCode: 0 });
      sink.dispatch('keyup', { code, isComposing: false, keyCode: 0 });
    }
    sink.dispatch('keydown', { code: 'Unidentified', isComposing: false, keyCode: 0 });
    assert.deepEqual(r.calls.filter((c) => c[0] === 'key').map((c) => [c[3], c[4]]),
      Object.values(codes).flatMap((k) => [[k, true], [k, false]]));
    r.dispose();
    await new Promise((res) => setTimeout(res, 0));
  } finally {
    dom.uninstall();
  }
});

test('input: the browser\'s Caps Lock / NumLock state reaches the core before each key and at enter (a keypad digit means NumLock; macOS reports none)', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    const sink = r.container.children.find((c: any) => c.contentEditable === 'true');
    // an event as a browser makes it: getModifierState answers from `on`
    const press = (code: string, key: string, on: string[] = [], shiftKey = false) => {
      const ev = { code, key, shiftKey, isComposing: false, keyCode: 0, getModifierState: (m: string) => on.includes(m) };
      sink.dispatch('keydown', ev);
      sink.dispatch('keyup', ev);
    };
    const seen = () => r.calls.splice(0).filter((c) => c[0] === 'key' || c[0] === 'keyboardLocks')
      .map((c) => c[0] === 'key' ? `key ${c[3]}${c[4] ? '' : ' up'}` : `locks caps=${c[1]} num=${c[2]}`);
    r.calls.length = 0;
    // events without getModifierState (old fakes, synthetic): the core's state stays
    sink.dispatch('keydown', { code: 'KeyA', isComposing: false, keyCode: 0 });
    assert.deepEqual(seen(), ['key 30']);
    // Linux / Windows, NumLock on: Numpad7 types '7'; the locks go first, every time
    press('Numpad7', '7', ['NumLock']);
    assert.deepEqual(seen(), ['locks caps=false num=true', 'key 71', 'locks caps=false num=true', 'key 71 up']);
    // NumLock off: the keypad navigates (Home), and the core is told before the key
    press('Numpad7', 'Home');
    assert.deepEqual(seen()[0], 'locks caps=false num=false');
    // with Shift held the keymap navigates whatever NumLock is: no word on it
    // from the key (here the NumLock modifier state says on)
    press('Numpad7', 'Home', ['NumLock'], true);
    assert.deepEqual(seen()[0], 'locks caps=false num=true');
    press('Numpad7', 'Home', [], true); // (a false keeps it, as on any key)
    assert.deepEqual(seen()[0], 'locks caps=false num=true');
    // macOS: getModifierState('NumLock') is always false, the keypad types digits
    press('KeyB', 'b'); // a false NumLock on another key keeps what was known
    assert.deepEqual(seen()[0], 'locks caps=false num=true');
    press('NumpadDecimal', '.', ['CapsLock']);
    assert.deepEqual(seen()[0], 'locks caps=true num=true');
    // the lock keys' own events don't sync (the core toggles on the press;
    // what their events report differs between browsers) …
    press('CapsLock', 'CapsLock', []);
    press('NumLock', 'NumLock', []);
    assert.deepEqual(seen(), ['key 58', 'key 58 up', 'key 69', 'key 69 up']);
    // … and the next key brings the browser's word again (both toggled off
    // here, as the core has them: no change to tell)
    press('KeyC', 'c', []);
    assert.deepEqual(seen()[0], 'locks caps=false num=false');
    // a click focusing another window: its enter is preceded by the click's state
    r.commit(2, 5);
    r.calls.length = 0;
    r.input.focus(1, 5);
    assert.deepEqual(r.calls.filter((c) => c[0] !== 'pointerButton').map((c) => c[0]),
      ['keyboardLeave', 'keyboardLocks', 'keyboardEnter']);
    r.dispose();
    await new Promise((res) => setTimeout(res, 0));
  } finally {
    dom.uninstall();
  }
});

test('view + input + wm: a minimized window hides, keyboard focus passes to the topmost one left; restored, it shows raised and focused', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    r.commit(2, 5);
    r.commit(3, 5);
    r.view.raise(1, 5);
    assert.ok(r.input.focused(3, 5));
    r.calls.length = 0;
    r.feed({ type: 'minimize', conn: 3, surface: 5, minimized: true });
    assert.equal(r.el(3, 5).style.display, 'none');
    assert.deepEqual(r.calls, [['keyboardLeave', 3], ['keyboardEnter', 1, 5]], 'the leave is a no-op in the core, which sent its own');
    assert.deepEqual(r.view.windows().map((w) => w.minimized), [false, false, true], 'still listed');
    r.commit(3, 5, { minimized: true });
    assert.equal(r.el(3, 5).style.display, 'none', 'a commit meanwhile keeps it hidden');
    r.calls.length = 0;
    r.input.focus(3, 5);
    assert.deepEqual(r.calls, [], 'no focus for a hidden window');

    r.feed({ type: 'minimize', conn: 3, surface: 5, minimized: false });
    assert.equal(r.el(3, 5).style.display, '');
    assert.ok(r.z(3, 5) > r.z(1, 5));
    assert.deepEqual(r.calls, [['keyboardLeave', 1], ['keyboardEnter', 3, 5]]);
    r.dispose();
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('wm: Alt+F11 / F10 / F9 act on the focused window, swallowed with their keyup; other modifiers pass; the API calls the engine', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    r.calls.length = 0;
    assert.equal(r.key('F11'), true);
    assert.equal(r.key('F11', {}, 'keyup'), true);
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: true });
    r.calls.length = 0;
    r.key('F11');
    r.key('F10');
    r.key('F9');
    assert.deepEqual(r.calls, [['setFullscreen', 1, 5, false], ['setMaximized', 1, 5, true], ['setMinimized', 1, 5, true]]);
    r.calls.length = 0;
    assert.equal(r.key('F11', { ctrlKey: true }), false);
    assert.equal(r.key('F4'), false);
    assert.equal(r.key('F4', {}, 'keyup'), false);
    assert.deepEqual(r.calls, []);
    r.wm.minimize(1, 5);
    r.wm.restore(1, 5);
    r.wm.setFullscreen(1, 5, true);
    r.wm.setMaximized(1, 5, false);
    assert.deepEqual(r.calls, [['setMinimized', 1, 5, true], ['setMinimized', 1, 5, false], ['setFullscreen', 1, 5, true], ['setMaximized', 1, 5, false]]);
    r.dispose();
    const off = wmRig(dom, { shortcuts: false });
    off.commit(1, 5);
    off.calls.length = 0;
    assert.equal(off.key('F11'), false);
    assert.deepEqual(off.calls, []);
    off.dispose();
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('wm browserFullscreen: the container goes fullscreen with a window (at once with a gesture, else at the next press in it); the browser leaving it ends the windows\' fullscreen; left when none is shown', async () => {
  const dom = installFakeDom();
  try {
    const doc = dom.document;
    const before = dom.leftovers();
    const r = wmRig(dom, { browserFullscreen: true });
    r.commit(1, 5);
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: true });
    assert.equal(r.container.fullscreenRequests, 1);
    assert.equal(doc.fullscreenElement, r.container);
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: false });
    assert.equal(doc.fullscreenExits, 1);
    assert.equal(doc.fullscreenElement, null);

    // no user activation: the next press in the container
    dom.activation.isActive = false;
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: true });
    assert.equal(r.container.fullscreenRequests, 1);
    dom.activation.isActive = true;
    doc.dispatch('pointerdown', { target: r.view.canvas(1, 5), clientX: 1, clientY: 1, button: 0, pointerId: 1 });
    assert.equal(r.container.fullscreenRequests, 2);
    assert.equal(doc.fullscreenElement, r.container);

    // the browser leaves it on its own (Esc): the window leaves fullscreen
    r.calls.length = 0;
    doc.fullscreenElement = null;
    doc.dispatch('fullscreenchange');
    assert.deepEqual(r.calls, [['setFullscreen', 1, 5, false]]);
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: false });

    // minimizing the fullscreen window leaves it too; restoring asks again
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: true });
    const exits = doc.fullscreenExits;
    r.feed({ type: 'minimize', conn: 1, surface: 5, minimized: true });
    assert.equal(doc.fullscreenExits, exits + 1);
    r.feed({ type: 'minimize', conn: 1, surface: 5, minimized: false });
    assert.equal(doc.fullscreenElement, r.container);
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: false });
    assert.equal(doc.fullscreenElement, null);
    // the page's own fullscreen of the container: not the wm's to end
    r.calls.length = 0;
    r.container.requestFullscreen();
    assert.equal(doc.fullscreenElement, r.container);
    r.feed({ type: 'maximize', conn: 1, surface: 5, maximized: true });
    assert.equal(doc.fullscreenElement, r.container, 'left alone');
    doc.exitFullscreen();
    assert.deepEqual(r.calls, [], 'its exit ends nothing');
    r.feed({ type: 'fullscreen', conn: 1, surface: 5, fullscreen: true });
    r.dispose();
    assert.equal(doc.fullscreenElement, null, 'dispose leaves the fullscreen it entered');
    await new Promise((res) => setTimeout(res, 0));
    assert.equal(dom.leftovers().documentListeners, before.documentListeners);
  } finally {
    dom.uninstall();
  }
});

test('createWland windows(): the states per entry; raise() on a minimized window restores it (the core then raises and focuses)', async () => {
  const dom = installFakeDom();
  try {
    const link = scriptedLink();
    const wl: Wland = await createWland({ container: dom.container(), wasm, link, webgl: 'never', scale: 1 });
    link.cb!.onOpen();
    const feed = (ev: Ev) => { wl.view.handle(ev); wl.input.handle(ev); wl.wm.handle(ev); };
    feed({
      type: 'commit', conn: 1, surface: 5, role: 1, root: 5, x: 0, y: 0, maximized: true, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 1, height: 1 },
      width: 1, height: 1, logicalWidth: 1, logicalHeight: 1, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 1, 1]), pixels: new Uint8Array(4),
    });
    feed({ type: 'minimize', conn: 1, surface: 5, minimized: true });
    const [w] = wl.windows();
    assert.deepEqual([w.maximized, w.fullscreen, w.minimized], [true, false, true]);
    const asked: unknown[][] = [];
    wl.engine.setMinimized = (...a) => { asked.push(a); };
    w.raise();
    assert.deepEqual(asked, [[1, 5, false]]);
    wl.dispose();
  } finally {
    dom.uninstall();
  }
});

test('createWland: mount / unmount and onFocusChange are passed on; app id and size hints on the window; close() asks the engine', async () => {
  const dom = installFakeDom();
  try {
    const link = scriptedLink();
    const frame = dom.container(); // the embedder's own window frame
    const mounted: ViewWindow[] = [], unmounted: string[] = [];
    let windowsChanges = 0, focusChanges = 0;
    const wl: Wland = await createWland({
      container: dom.container(), wasm, link, webgl: 'never', scale: 1,
      mount: (win) => { mounted.push(win); frame.appendChild(win.element); },
      unmount: (win) => { unmounted.push(win.key); win.element.remove(); },
      onWindowsChange: () => { windowsChanges++; },
      onFocusChange: () => { focusChanges++; },
    });
    link.cb!.onOpen();
    const feed = (ev: Ev) => { wl.view.handle(ev); wl.input.handle(ev); wl.wm.handle(ev); };
    // the app id and hints may come before the window exists
    feed({ type: 'app-id', conn: 1, surface: 5, appId: 'org.example.App' });
    feed({ type: 'size-limits', conn: 1, surface: 5, minW: 100, minH: 50, maxW: 0, maxH: 400 });
    feed({
      type: 'commit', conn: 1, surface: 5, role: 1, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 1, height: 1 },
      width: 1, height: 1, logicalWidth: 1, logicalHeight: 1, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 1, 1]), pixels: new Uint8Array(4),
    });
    assert.equal(mounted.length, 1);
    assert.equal(mounted[0].element.parentElement, frame, 'the embedder\'s mount put it there');
    assert.deepEqual([mounted[0].appId, mounted[0].minW, mounted[0].minH, mounted[0].maxW, mounted[0].maxH], ['org.example.App', 100, 50, 0, 400]);
    const [w] = wl.windows();
    assert.equal(w.appId, 'org.example.App');
    // hints that change are announced; all zero is none again
    const before = windowsChanges;
    feed({ type: 'size-limits', conn: 1, surface: 5, minW: 0, minH: 0, maxW: 0, maxH: 0 });
    assert.ok(windowsChanges > before);
    assert.deepEqual([wl.view.window(1, 5)!.minW, wl.view.window(1, 5)!.maxH], [0, 0]);
    // focus has its own callback: a second window took it at its map, the
    // first one raised takes it back
    assert.equal(focusChanges, 1, 'the first window took focus at its map');
    feed({
      type: 'commit', conn: 1, surface: 6, role: 1, root: 6, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 1, height: 1 },
      width: 1, height: 1, logicalWidth: 1, logicalHeight: 1, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 1, 1]), pixels: new Uint8Array(4),
    });
    assert.equal(focusChanges, 2);
    const focusBefore = focusChanges, windowsBefore = windowsChanges;
    w.raise();
    assert.equal(focusChanges, focusBefore + 1);
    assert.equal(windowsChanges, windowsBefore, 'not onWindowsChange when onFocusChange is given');
    // close() is engine.close, nothing else
    const asked: unknown[][] = [];
    wl.engine.close = (...a) => { asked.push(a); };
    w.close();
    assert.deepEqual(asked, [[1, 5]]);
    assert.equal(wl.windows().length, 2, 'the app decides');
    feed({ type: 'destroy', conn: 1, surface: 5 });
    assert.deepEqual(unmounted, ['c1s5']);
    wl.dispose();
    await new Promise((r) => setTimeout(r, 0)); // the IME sink's blur check (a microtask) runs on the fake DOM
  } finally {
    dom.uninstall();
  }
});

test('createWland: `decorated` is on the window mount gets when the decoration event came first, on windows(), and a change after the mount is announced through onWindowsChange', async () => {
  const dom = installFakeDom();
  try {
    const link = scriptedLink();
    const mounted: ViewWindow[] = [];
    let windowsChanges = 0;
    const wl: Wland = await createWland({
      container: dom.container(), wasm, link, webgl: 'never', scale: 1, decorations: 'server',
      mount: (win) => { mounted.push(win); dom.container().appendChild(win.element); },
      onWindowsChange: () => { windowsChanges++; },
    });
    link.cb!.onOpen();
    const feed = (ev: Ev) => { wl.view.handle(ev); wl.input.handle(ev); wl.wm.handle(ev); };
    const commit = (surface: number): Ev => ({
      type: 'commit', conn: 1, surface, role: 1, root: surface, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 1, height: 1 },
      width: 1, height: 1, logicalWidth: 1, logicalHeight: 1, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 1, 1]), pixels: new Uint8Array(4),
    });
    // the core tells it at the initial configure, before the first buffer
    feed({ type: 'decoration', conn: 1, surface: 5, decorated: true });
    feed(commit(5));
    feed(commit(6)); // never asked: client-side
    assert.deepEqual(mounted.map((w) => [w.key, w.decorated]), [['c1s5', true], ['c1s6', false]]);
    assert.deepEqual(wl.windows().map((w) => [w.key, w.decorated]), [['c1s5', true], ['c1s6', false]]);
    const before = windowsChanges;
    feed({ type: 'decoration', conn: 1, surface: 5, decorated: false });
    assert.ok(windowsChanges > before);
    assert.equal(wl.view.window(1, 5)!.decorated, false);
    assert.equal(wl.windows().find((w) => w.key === 'c1s5')!.decorated, false);
    wl.dispose();
    await new Promise((r) => setTimeout(r, 0)); // the IME sink's blur check (a microtask) runs on the fake DOM
  } finally {
    dom.uninstall();
  }
});

test('wm: a move/resize or drag asked for after the release starts nothing; a grab ends at a release it never saw (a move with no button down), a pointercancel or the window blur; Alt+drag ends with its capture', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    const canvas = r.view.canvas(1, 5) as any;
    const el = r.el(1, 5);
    const doc = dom.document;
    const down = (x = 10, y = 10) => doc.dispatch('pointerdown', { target: canvas, button: 0, buttons: 1, pointerId: 1, clientX: x, clientY: y });
    const up = (x = 10, y = 10) => doc.dispatch('pointerup', { target: canvas, button: 0, buttons: 0, pointerId: 1, clientX: x, clientY: y });
    const move = (x: number, y: number, buttons: number) => doc.dispatch('pointermove', { target: canvas, pointerId: 1, clientX: x, clientY: y, buttons });
    const names = () => r.calls.map((c) => c[0]);

    // foot at x=24: a quick click on its left border, the resize request
    // after the release (a slow guest) — no grab, the window stays put
    const left = el.style.left;
    down(21, 300);
    up(21, 300);
    r.calls.length = 0;
    r.feed({ type: 'resize', conn: 1, surface: 5, edges: 4 });
    move(300, 350, 0);
    assert.equal(el.style.left, left, 'not following the pointer');
    assert.deepEqual(names(), ['pointerMotion'], 'no leave, no resize: the app keeps the pointer');
    assert.ok(!doc.body.style.cursor);

    // held: a grab; a move that shows no button down is its release
    down(10, 10);
    r.calls.length = 0;
    r.feed({ type: 'move', conn: 1, surface: 5 });
    assert.ok(names().includes('pointerLeave'), 'the grab took the pointer');
    move(30, 10, 1);
    assert.equal(el.style.left, '20px');
    move(300, 350, 0);
    assert.equal(el.style.left, '20px', 'ended where the button was last seen down');
    assert.ok(!doc.body.style.cursor);
    r.calls.length = 0;
    move(400, 400, 0);
    assert.equal(el.style.left, '20px', 'and over');
    assert.deepEqual(names(), ['pointerMotion'], 'the app gets the pointer again');

    // a resize grab: the window's blur ends it, with the size so far
    down(10, 10);
    r.feed({ type: 'resize', conn: 1, surface: 5, edges: 8 });
    move(200, 10, 1);
    r.calls.length = 0;
    (globalThis as any).window.dispatch('blur');
    assert.deepEqual(r.calls.filter((c) => c[0] === 'requestResize'), [['requestResize', 1, 5, 190, 60]]);
    r.calls.length = 0;
    move(500, 10, 1);
    assert.ok(!names().includes('requestResize'), 'over');

    // a pointercancel ends one too
    down(10, 10);
    r.feed({ type: 'move', conn: 1, surface: 5 });
    doc.dispatch('pointercancel', { target: canvas, pointerId: 1 });
    const at = el.style.left;
    move(600, 10, 1);
    assert.equal(el.style.left, at);
    up();

    // a drag asked for after the release is cancelled at once (it would
    // wedge the seat)
    down();
    up();
    r.calls.length = 0;
    r.feed({ type: 'drag-start', conn: 1, surface: 5, icon: 0 });
    assert.deepEqual(r.calls, [['dragCancel']]);

    // Alt+drag ends at the release, or when its capture goes another way
    // (events at the box, which holds the capture: the document's capture
    // listeners — input's grab — see them first)
    const atBox = (type: string, ev: Record<string, unknown>) => { doc.dispatch(type, { target: el, ...ev }); el.dispatch(type, ev); };
    doc.dispatch('pointerdown', { target: canvas, altKey: true, button: 0, buttons: 1, pointerId: 2, clientX: 0, clientY: 0 });
    assert.equal(el.captured, 2);
    atBox('pointermove', { pointerId: 2, clientX: 50, clientY: 40, buttons: 1 });
    assert.deepEqual([el.style.left, el.style.top], ['50px', '40px']);
    el.captured = null;
    atBox('lostpointercapture', { pointerId: 2 });
    atBox('pointermove', { pointerId: 2, clientX: 90, clientY: 90, buttons: 0 });
    assert.deepEqual([el.style.left, el.style.top], ['50px', '40px'], 'hovering moves it no more');
    doc.dispatch('pointerdown', { target: canvas, altKey: true, button: 0, buttons: 1, pointerId: 3, clientX: 0, clientY: 0 });
    atBox('pointermove', { pointerId: 3, clientX: 10, clientY: 10, buttons: 0 });
    atBox('pointermove', { pointerId: 3, clientX: 70, clientY: 70, buttons: 1 });
    assert.deepEqual([el.style.left, el.style.top], ['50px', '40px'], 'a move with no button down ends it');
    assert.equal(el.captured, null);

    r.dispose();
    assert.equal(dom.leftovers().windowListeners, 0, 'the blur listener is removed');
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('wm: a grab or drag follows the pointer that pressed — another pointer\'s buttonless move, release or cancel (a hovering pen, a mouse beside a touch) neither moves nor ends it', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    const canvas = r.view.canvas(1, 5) as any;
    const el = r.el(1, 5);
    const doc = dom.document;
    const ev = (type: string, pointerId: number, x: number, y: number, buttons: number) =>
      doc.dispatch(type, { target: canvas, button: 0, buttons, pointerId, clientX: x, clientY: y });
    const names = () => r.calls.map((c) => c[0]);

    // a touch (id 7) presses the titlebar; the app asks for a move
    ev('pointerdown', 7, 10, 10, 1);
    r.feed({ type: 'move', conn: 1, surface: 5 });
    ev('pointermove', 7, 30, 10, 1);
    assert.equal(el.style.left, '20px');
    // the mouse (id 1) hovers: no button down, but not the grab's pointer
    ev('pointermove', 1, 400, 400, 0);
    assert.equal(el.style.left, '20px', 'not moved by the mouse');
    ev('pointermove', 7, 50, 10, 1);
    assert.equal(el.style.left, '40px', 'still the touch\'s grab');
    // a pen (id 3) taps and lifts, then is cancelled: the grab goes on
    ev('pointerdown', 3, 300, 300, 1);
    ev('pointerup', 3, 300, 300, 0);
    ev('pointercancel', 3, 300, 300, 0);
    ev('pointermove', 7, 60, 10, 1);
    assert.equal(el.style.left, '50px');
    // the touch lifts: the grab ends there
    ev('pointerup', 7, 60, 10, 0);
    assert.ok(!doc.body.style.cursor, 'ended');
    ev('pointermove', 7, 90, 10, 1);
    assert.equal(el.style.left, '50px');

    // a drag from the touch: the mouse's buttonless move doesn't cancel it,
    // the touch's cancel does
    ev('pointerdown', 8, 10, 10, 1);
    r.feed({ type: 'drag-start', conn: 1, surface: 5, icon: 0 });
    r.calls.length = 0;
    ev('pointermove', 1, 200, 200, 0);
    ev('pointerup', 1, 200, 200, 0);
    assert.deepEqual(names().filter((n) => n === 'dragCancel' || n === 'dragDrop'), [], 'the mouse ends nothing');
    ev('pointercancel', 8, 10, 10, 0);
    assert.deepEqual(names().filter((n) => n === 'dragCancel'), ['dragCancel']);
    r.feed({ type: 'drag-end' } as Ev);

    // and a resize from the mouse: another pointer's cancel ends nothing,
    // the mouse's own buttonless move (its release unseen) ends it
    ev('pointerdown', 1, 10, 10, 1);
    r.feed({ type: 'resize', conn: 1, surface: 5, edges: 8 });
    ev('pointercancel', 9, 0, 0, 0);
    ev('pointermove', 1, 110, 10, 1);
    r.calls.length = 0;
    ev('pointermove', 1, 300, 10, 0);
    assert.deepEqual(r.calls.filter((c) => c[0] === 'requestResize'), [['requestResize', 1, 5, 100, 60]], 'ended with the size so far');
    r.dispose();
  } finally {
    dom.uninstall();
  }
});

test('view: the container is made touch-ready (touch-action none, no selection or callout, its own stacking context) and put back on dispose; the IME sink stays selectable', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    container.style.touchAction = 'pan-y';
    const view = createView({ container, webgl: 'never' });
    assert.deepEqual([container.style.touchAction, container.style.userSelect, container.style.webkitUserSelect,
      container.style.webkitTouchCallout, container.style.isolation], ['none', 'none', 'none', 'none', 'isolate']);
    const engine = new Proxy({} as Engine, { get: () => () => {} });
    const input = createInput({ engine, view, container });
    const sink = container.children.find((c: any) => c.contentEditable === 'true');
    assert.deepEqual([sink.style.userSelect, sink.style.webkitUserSelect], ['text', 'text']);
    input.dispose();
    view.dispose();
    assert.deepEqual([container.style.touchAction, container.style.userSelect, container.style.isolation], ['pan-y', '', '']);
  } finally {
    dom.uninstall();
  }
});

test('view: popups and subsurfaces follow a \'position\' event (a parent\'s geometry changed under an open menu); a popup\'s subsurfaces stack above it, its child popup above both', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const commit = (surface: number, role: Role, x: number, y: number, parent?: number) => view.handle({
      type: 'commit', conn: 1, surface, role, root: 5, ...(parent === undefined ? {} : { parent }), x, y,
      maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 23, y: 21, width: 60, height: 40 },
      width: 20, height: 20, logicalWidth: 20, logicalHeight: 20, format: 'rgba', stride: 0,
      damage: new Int32Array(0), pixels: new Uint8Array(0),
    });
    commit(5, 1, 0, 0, 0);
    commit(6, 2, 0, -10, 5);   // the toplevel's titlebar subsurface
    commit(7, 4, 40, 30, 5);   // a menu
    view.handle({ type: 'input-region', conn: 1, surface: 7, region: new Int32Array([0, 0, 10, 10]) });
    commit(8, 2, 42, 32, 7);   // the menu's subsurface (committed after the menu)
    commit(9, 4, 60, 30, 7);   // a submenu
    commit(10, 2, 2, 2, 5);    // a toplevel subsurface mapped while the menu is open
    const z = (s: number) => Number(view.canvas(1, s)!.style.zIndex || 0);
    assert.ok(z(5) < z(6) && z(6) < z(10) && z(10) < z(7), 'toplevel < its subsurfaces < its popup');
    assert.ok(z(7) < z(8) && z(8) < z(9), 'popup < its subsurface < its child popup');
    // the hit element stacks with its canvas
    const pop = view.canvas(1, 7) as any;
    const hit = pop.parentElement.children[pop.parentElement.children.indexOf(pop) + 1];
    assert.equal(hit.style.zIndex, pop.style.zIndex);

    // the window maximizes: its geometry goes to 0,0 and the core moves the
    // popups by that much without a commit of theirs
    view.handle({ type: 'position', conn: 1, surface: 7, x: 17, y: 9 });
    view.handle({ type: 'position', conn: 1, surface: 8, x: 19, y: 11 });
    assert.deepEqual([pop.style.left, pop.style.top], ['17px', '9px']);
    assert.deepEqual([hit.style.left, hit.style.top], ['17px', '9px'], 'the hit element follows');
    const sub = view.canvas(1, 8) as any;
    assert.deepEqual([sub.style.left, sub.style.top], ['19px', '11px']);
    // not for a toplevel (it sits at its window's origin)
    view.handle({ type: 'position', conn: 1, surface: 5, x: 50, y: 50 });
    assert.equal(view.canvas(1, 5)!.style.left, '0px');

    // the submenu closes (destroyed): the rest keep their order
    view.handle({ type: 'destroy', conn: 1, surface: 9 });
    assert.ok(z(10) < z(7) && z(7) < z(8));
    view.dispose();
  } finally {
    dom.uninstall();
  }
});

test('view: subsurfaces stack by their z (place_above / place_below) — one placed below the toplevel goes under its canvas — and restack on a \'position\' event carrying a new z, hit elements with them', () => {
  const dom = installFakeDom();
  try {
    const container = dom.container();
    const view = createView({ container, webgl: 'never' });
    const commit = (surface: number, role: Role, parent: number, z: number) => view.handle({
      type: 'commit', conn: 1, surface, role, root: 5, parent, z, x: 0, y: 0,
      maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 60, height: 40 },
      width: 20, height: 20, logicalWidth: 20, logicalHeight: 20, format: 'rgba', stride: 0,
      damage: new Int32Array(0), pixels: new Uint8Array(0),
    });
    commit(5, 1, 0, 0);
    commit(6, 2, 5, 2);   // above the toplevel, second
    commit(7, 2, 5, 1);   // above it, first: under 6 although newer
    commit(8, 4, 5, 0);   // a popup
    const z = (s: number) => Number(view.canvas(1, s)!.style.zIndex || 0);
    assert.ok(z(5) < z(7) && z(7) < z(6) && z(6) < z(8), 'toplevel < 7 < 6 < popup');
    assert.equal(view.canvas(1, 5)!.style.zIndex, '', 'the toplevel at the bottom: no z-index of its own');
    view.handle({ type: 'input-region', conn: 1, surface: 7, region: new Int32Array([0, 0, 10, 10]) });
    const c7 = view.canvas(1, 7) as any;
    const hit7 = c7.parentElement.children[c7.parentElement.children.indexOf(c7) + 1];
    assert.equal(hit7.style.zIndex, c7.style.zIndex);

    // the parent's commit restacked them: 7 below the toplevel (a video
    // under its frame), 6 just above it
    view.handle({ type: 'position', conn: 1, surface: 7, x: 0, y: 0, z: -1 });
    view.handle({ type: 'position', conn: 1, surface: 6, x: 0, y: 0, z: 1 });
    assert.ok(z(7) < z(5) && z(5) < z(6) && z(6) < z(8), '7 < toplevel < 6 < popup');
    assert.notEqual(view.canvas(1, 5)!.style.zIndex, '', 'the toplevel now has one, above 7');
    assert.equal(hit7.style.zIndex, c7.style.zIndex, 'the hit element restacks with its canvas');
    // a 'position' without z (an embedder's) leaves the order alone
    view.handle({ type: 'position', conn: 1, surface: 7, x: 3, y: 3 });
    assert.ok(z(7) < z(5));
    // a subsurface of the one below: still under the toplevel
    commit(9, 2, 7, 1);
    assert.ok(z(7) < z(9) && z(9) < z(5));
    view.dispose();
  } finally {
    dom.uninstall();
  }
});

// --- the embedder's window manager: input grabs, the interactive hook,
// autoFocus off ---------------------------------------------------------------
test('input grab: the apps lose the pointer from a held press until its release (not forwarded), a cancel, a lost capture, a move with no button down, the window blur or end(); then the surface under it is entered; a released pointer gets none; suppress() is one', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom);
    r.commit(1, 5);
    const canvas = r.view.canvas(1, 5) as any;
    const doc = dom.document;
    doc.elementFromPoint = () => canvas; // what surfaceAt hit-tests
    const ev = (type: string, id: number, x: number, y: number, buttons: number) =>
      doc.dispatch(type, { target: canvas, button: 0, buttons, pointerId: id, clientX: x, clientY: y });
    const names = () => r.calls.map((c) => c[0]);
    const ended: unknown[] = [];
    const onEnd = (reason: string, e?: { type: string }) => { ended.push(e ? `${reason}:${e.type}` : reason); };

    assert.equal(r.input.grab(4).active, false, 'a pointer not down: over at once');

    // a press on the app (the implicit grab captures), then a grab of it
    ev('pointerover', 1, 5, 5, 0);
    ev('pointerdown', 1, 5, 5, 1);
    assert.equal(canvas.captured, 1);
    r.calls.length = 0;
    const g = r.input.grab(1, { onEnd });
    assert.deepEqual([g.active, g.pointerId, canvas.captured], [true, 1, null], 'the implicit grab let go');
    assert.deepEqual(r.calls, [['pointerLeave', 1]], 'the app under the pointer lost it');
    r.calls.length = 0;
    ev('pointermove', 1, 20, 5, 1);
    ev('pointermove', 2, 30, 5, 0); // another pointer: held off too
    doc.dispatch('lostpointercapture', { target: canvas, pointerId: 1 }); // the implicit grab's own
    assert.deepEqual([r.calls, g.active], [[], true]);
    ev('pointerup', 1, 25, 6, 0);
    assert.deepEqual([g.active, ended], [false, ['release:pointerup']]);
    assert.deepEqual(r.calls, [['pointerEnter', 1, 5, 25, 6]], 'no release reaches the app; the pointer is entered again');
    g.end();
    assert.equal(ended.length, 1, 'end() after the end: nothing');

    // the window's blur mid-drag (no pointerup, no pointercancel: touch)
    ev('pointerdown', 1, 5, 5, 1);
    const g2 = r.input.grab(1, { onEnd });
    (globalThis as any).window.dispatch('blur');
    assert.deepEqual([g2.active, ended.at(-1)], [false, 'blur']);
    r.calls.length = 0;
    ev('pointermove', 1, 30, 5, 1);
    assert.deepEqual(names(), ['pointerMotion'], 'the apps have the pointer again');
    assert.equal(r.input.grab(1).active, false, 'the blur forgot the press');
    ev('pointerup', 1, 30, 5, 0);
    // ... and the next drag grabs again
    ev('pointerdown', 1, 5, 5, 1);
    const g3 = r.input.grab(1, { onEnd });
    assert.equal(g3.active, true);
    ev('pointercancel', 1, 5, 5, 0);
    assert.equal(ended.at(-1), 'cancel:pointercancel');
    // a capture the drag took ends any other way
    ev('pointerdown', 1, 5, 5, 1);
    r.input.grab(1, { onEnd });
    doc.dispatch('lostpointercapture', { target: doc.createElement('div'), pointerId: 1 });
    assert.equal(ended.at(-1), 'capture:lostpointercapture');
    // a move with no button down: a release the page didn't see
    r.input.grab(1, { onEnd });
    ev('pointermove', 1, 9, 9, 0);
    assert.equal(ended.at(-1), 'release:pointermove');
    // end()
    ev('pointerdown', 1, 5, 5, 1);
    r.input.grab(1, { onEnd }).end();
    assert.equal(ended.at(-1), 'end');
    r.calls.length = 0;
    ev('pointerup', 1, 5, 5, 0);
    assert.deepEqual(names(), ['pointerButton'], 'over: the release is the app\'s again');

    // suppress(true): a grab of the press held, ending with it
    ev('pointerdown', 1, 5, 5, 1);
    r.input.suppress(true);
    r.calls.length = 0;
    ev('pointermove', 1, 6, 6, 1);
    ev('pointerup', 1, 6, 6, 0);
    ev('pointermove', 1, 7, 7, 0);
    assert.deepEqual(names(), ['pointerEnter', 'pointerMotion'], 'held off until the release, entered after it');
    r.input.suppress(false);
    // no press held: until suppress(false)
    r.input.suppress(true);
    r.calls.length = 0;
    ev('pointermove', 1, 8, 8, 0);
    assert.deepEqual(r.calls, []);
    r.input.suppress(false);
    ev('pointermove', 1, 9, 9, 0);
    assert.deepEqual(names(), ['pointerEnter', 'pointerMotion']);
    r.dispose();
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('wm interactive: the embedder takes an app\'s move/resize, handed the press it came from (no grab here; one after the release is dropped first), and Alt+drag as an \'alt-drag\'; false keeps the default grab; shortcuts { drag: false } hands an Alt+press to the app and keeps the keys, false the reverse', async () => {
  const dom = installFakeDom();
  try {
    const asked: unknown[][] = [];
    let take = true;
    const r = wmRig(dom, { interactive: (ev, press) => { asked.push([ev, press]); return take; } });
    r.commit(1, 5);
    const canvas = r.view.canvas(1, 5) as any;
    const el = r.el(1, 5);
    const doc = dom.document;
    const ev = (type: string, id: number, x: number, y: number, buttons: number, more: Record<string, unknown> = {}) =>
      doc.dispatch(type, { target: canvas, button: 0, buttons, pointerId: id, clientX: x, clientY: y, pointerType: 'mouse', ...more });
    const names = () => r.calls.map((c) => c[0]);
    const left = el.style.left;

    ev('pointerdown', 7, 10, 12, 1, { pointerType: 'touch' });
    r.calls.length = 0;
    r.feed({ type: 'move', conn: 1, surface: 5 });
    assert.deepEqual(asked, [[{ type: 'move', conn: 1, surface: 5 },
      { pointerId: 7, pointerType: 'touch', clientX: 10, clientY: 12, button: 0, buttons: 1 }]]);
    assert.deepEqual(r.calls, [], 'no leave: no grab of its own');
    ev('pointermove', 7, 60, 12, 1);
    assert.equal(el.style.left, left, 'the window is the embedder\'s to move');
    assert.deepEqual(names(), ['pointerMotion'], 'the app keeps the pointer (the embedder did not grab)');
    ev('pointerup', 7, 60, 12, 0);
    asked.length = 0;
    r.feed({ type: 'resize', conn: 1, surface: 5, edges: 8 });
    assert.deepEqual(asked, [], 'after the release: never asked');
    ev('pointerdown', 1, 10, 10, 1);
    r.feed({ type: 'resize', conn: 1, surface: 5, edges: 8 });
    assert.deepEqual(asked.map((a) => a[0]), [{ type: 'resize', conn: 1, surface: 5, edges: 8 }]);
    ev('pointerup', 1, 10, 10, 0);

    // declined: the default grab
    take = false;
    ev('pointerdown', 1, 10, 10, 1);
    r.feed({ type: 'move', conn: 1, surface: 5 });
    ev('pointermove', 1, 30, 10, 1);
    assert.equal(el.style.left, '20px', 'moved by the wm (from offsetLeft, 0 here)');
    ev('pointerup', 1, 30, 10, 0);

    // Alt+press: an 'alt-drag', its press with it; taken, no Alt+drag here
    take = true;
    asked.length = 0;
    ev('pointerdown', 2, 5, 5, 1, { altKey: true });
    assert.deepEqual(asked, [[{ type: 'alt-drag', conn: 1, surface: 5 },
      { pointerId: 2, pointerType: 'mouse', clientX: 5, clientY: 5, button: 0, buttons: 1 }]]);
    assert.equal(el.captured, null, 'the box took no capture');
    ev('pointerup', 2, 5, 5, 0);
    r.dispose();

    // { drag: false }: an Alt+press is the app's (the button goes to it); Alt+F10 still works
    const off = wmRig(dom, { shortcuts: { drag: false } });
    off.commit(1, 5);
    const offCanvas = off.view.canvas(1, 5) as any;
    off.calls.length = 0;
    doc.dispatch('pointerdown', { target: offCanvas, altKey: true, button: 0, buttons: 1, pointerId: 1, clientX: 5, clientY: 5 });
    assert.ok(off.calls.some((c) => c[0] === 'pointerButton'), 'forwarded');
    assert.deepEqual([off.el(1, 5).captured, offCanvas.captured], [null, 1], 'no Alt+drag: the implicit grab');
    doc.dispatch('pointerup', { target: offCanvas, button: 0, buttons: 0, pointerId: 1, clientX: 5, clientY: 5 });
    off.calls.length = 0;
    assert.equal(off.key('F10'), true);
    assert.deepEqual(off.calls, [['setMaximized', 1, 5, true]]);
    off.dispose();
    // false: the keys off, Alt+drag on
    const keys = wmRig(dom, { shortcuts: false });
    keys.commit(1, 5);
    doc.dispatch('pointerdown', { target: keys.view.canvas(1, 5), altKey: true, button: 0, buttons: 1, pointerId: 1, clientX: 5, clientY: 5 });
    assert.equal(keys.el(1, 5).captured, 1, 'Alt+drag');
    assert.equal(keys.key('F10'), false);
    keys.dispose();
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('input autoFocus false: focus only when told — none at map or press, none passed on when the focused window goes or is minimized, the wm focuses nothing it restores or makes fullscreen; focus() gives it, blur() takes it; a canvas taking the page\'s focus moves none', async () => {
  const dom = installFakeDom();
  try {
    const r = wmRig(dom, { autoFocus: false });
    const doc = dom.document;
    r.commit(1, 5);
    r.commit(2, 5);
    r.commit(3, 5);
    assert.equal(r.input.autoFocus, false);
    assert.deepEqual(r.calls.filter((c) => c[0] === 'keyboardEnter'), [], 'a new window takes nothing');
    assert.equal(doc.activeElement, doc.body);
    const sink = r.container.children.find((c: any) => c.contentEditable === 'true');
    const press = (conn: number) => {
      const canvas = r.view.canvas(conn, 5);
      doc.dispatch('pointerdown', { target: canvas, button: 0, buttons: 1, pointerId: 1, clientX: 1, clientY: 1 });
      doc.dispatch('pointerup', { target: canvas, button: 0, buttons: 0, pointerId: 1, clientX: 1, clientY: 1 });
    };
    r.calls.length = 0;
    press(1);
    assert.deepEqual(r.calls.map((c) => c[0]), ['pointerButton', 'pointerButton'], 'a press is forwarded, focusing nothing');

    r.input.focus(1, 5);
    assert.deepEqual(r.calls.slice(2), [['keyboardEnter', 1, 5]]);
    assert.equal(doc.activeElement, sink);
    r.calls.length = 0;
    r.feed({ type: 'destroy', conn: 1, surface: 5 });
    assert.deepEqual(r.calls, [], 'closed: nobody gets it');
    assert.ok(!r.input.focused(2, 5) && !r.input.focused(3, 5));

    r.input.focus(2, 5);
    r.calls.length = 0;
    r.feed({ type: 'minimize', conn: 2, surface: 5, minimized: true });
    assert.deepEqual(r.calls, [['keyboardLeave', 2]], 'minimized: its leave, nobody else');
    r.calls.length = 0;
    r.feed({ type: 'minimize', conn: 2, surface: 5, minimized: false });
    r.feed({ type: 'fullscreen', conn: 3, surface: 5, fullscreen: true });
    assert.deepEqual(r.calls, [], 'restored, made fullscreen: raised, not focused');
    assert.ok(r.z(3, 5) > r.z(2, 5));

    // a canvas taking the page's focus (Tab): the sink takes it back while
    // a window has the keyboard, which stays where it was
    r.input.focus(2, 5);
    r.calls.length = 0;
    (r.view.canvas(3, 5) as any).focus();
    assert.equal(doc.activeElement, sink);
    assert.ok(r.input.focused(2, 5));
    assert.deepEqual(r.calls, []);

    r.input.blur();
    assert.deepEqual(r.calls, [['keyboardLeave', 2]]);
    assert.equal(doc.activeElement, doc.body, 'the sink let go of the page\'s focus');
    assert.ok(!r.input.focused(2, 5));
    r.calls.length = 0;
    r.input.blur();
    assert.deepEqual(r.calls, []);
    r.dispose();
    await new Promise((res) => setTimeout(res, 0)); // the sink's blur checks
  } finally {
    dom.uninstall();
  }
});

test('createWland: interactive, shortcuts and autoFocus are passed on', async () => {
  const dom = installFakeDom();
  try {
    const link = scriptedLink();
    const asked: unknown[] = [];
    const wl: Wland = await createWland({ container: dom.container(), wasm, link, webgl: 'never', scale: 1,
      autoFocus: false, shortcuts: { drag: false }, interactive: (ev) => { asked.push(ev.type); return true; } });
    link.cb!.onOpen();
    const feed = (ev: Ev) => { wl.view.handle(ev); wl.input.handle(ev); wl.wm.handle(ev); };
    feed({
      type: 'commit', conn: 1, surface: 5, role: 1, root: 5, x: 0, y: 0, maximized: false, fullscreen: false, minimized: false,
      geometry: { x: 0, y: 0, width: 1, height: 1 },
      width: 1, height: 1, logicalWidth: 1, logicalHeight: 1, format: 'rgba', stride: 0,
      damage: new Int32Array([0, 0, 1, 1]), pixels: new Uint8Array(4),
    });
    assert.equal(wl.input.autoFocus, false);
    assert.deepEqual(wl.windows().map((w) => w.focused), [false], 'not focused at map');
    const canvas = wl.view.canvas(1, 5);
    dom.document.dispatch('pointerdown', { target: canvas, altKey: true, button: 0, buttons: 1, pointerId: 1, clientX: 0, clientY: 0 });
    feed({ type: 'move', conn: 1, surface: 5 });
    assert.deepEqual(asked, ['move'], 'no alt-drag (drag off); the move asked');
    wl.dispose();
  } finally {
    dom.uninstall();
  }
});
