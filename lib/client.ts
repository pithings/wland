// wland client: the engine, view, input and window manager composed on one
// thread, for a page that just wants windows in a container.
//
//   import { createWland } from 'wland/client';
//   const wl = await createWland({ container: document.getElementById('desktop') });
//
// This entry also re-exports each part (engine, view, input, window manager)
// for embedders that compose differently: their own window frames (view
// `mount`, their own window manager). The engine alone, e.g. in a Worker, is
// also wland/engine. This file is the reference for how they fit together.
// The types below are the contract.

import { createEngine, createWsLink, type Engine, type Event, type GpuSource, type HandleSource, type Link } from './engine.ts';
import { createView, watchOutput, type OutputControl, type OutputWatch, type View } from './view.ts';
import { createInput, type Input } from './input.ts';
import { createWindowManager, type WindowManager } from './wm.ts';
import { createClipboardBridge, type ClipboardBridge } from './clipboard.ts';
import { reconnecting } from './link-ws.ts';

export * from './engine.ts';
export * from './view.ts';
export * from './input.ts';
export * from './wm.ts';
export * from './clipboard.ts';

export interface WlandOptions {
  /** Windows live in here. A positioned, fixed-size box: its client size is
   *  the output size reported to apps. Its children belong to wland. */
  container: HTMLElement;
  /** Default: createWsLink(`ws(s)://<location.host>/ws`), dialled again
   *  after a drop while it is a session link (see `reconnect`). */
  link?: Link;
  /** The default link only: when a session link (Engine.session(): a
   *  `wlandr --profile session`, whose apps outlive the link) closes other
   *  than by a takeover, connect again (backing off from 0.5 s to 10 s);
   *  the relay sends the scene again. Default true. A passthrough link is
   *  never reconnected (its apps went with it). */
  reconnect?: boolean;
  /** The embedder's access to buffer handles (EngineOptions.buffers), for a
   *  relay running a handle backend. Buffer-source commits reach the view
   *  swizzled by the core when it presents with 2D only (EngineOptions.rgba),
   *  as written when it uses WebGL. */
  buffers?: HandleSource;
  /** The embedder's access to GPU buffers (EngineOptions.gpu), for a relay
   *  that names GPU resources (COMMIT kind virtgpu): resolve one to a
   *  CanvasImageSource (ImageBitmap, OffscreenCanvas, canvas, VideoFrame)
   *  holding its current content, row 0 at the top. The view draws it into
   *  the surface's canvas during the commit's dispatch (2D: the damaged
   *  rects; WebGL: the whole image as the texture), then the engine calls
   *  release(image) and ACKs. Without it, apps on `wlandr --dmabuf virtgpu`
   *  are offered no linux-dmabuf and render in software (wl_shm). */
  gpu?: GpuSource<CanvasImageSource>;
  /** Default: wland.wasm next to the engine module. */
  wasm?: string | URL | BufferSource | WebAssembly.Module;
  /** Pin the scale apps render at: a device pixel ratio, integer or
   *  fractional (1.5), finite and > 0 (anything else rejects createWland
   *  with a RangeError, as output.setScale throws one). Default:
   *  devicePixelRatio, tracked live. Either way `output.setScale` changes it
   *  after start. */
  scale?: number;
  /** See ViewOptions.webgl. */
  webgl?: 'auto' | 'always' | 'never';
  /** A fullscreen window also puts `container` into the browser's
   *  fullscreen (WindowManagerOptions.browserFullscreen). Default false:
   *  fullscreen windows fill the container. */
  browserFullscreen?: boolean;
  /** The window manager's Alt+F9/F10/F11 bindings (minimize, maximize,
   *  fullscreen). Default true. */
  shortcuts?: boolean;
  /** Bridge the Wayland clipboard and the page's clipboard (plain text,
   *  both ways; lib/clipboard.ts): an app's copy made while the desktop has
   *  focus reaches the page clipboard when the browser allows a write (a
   *  key or click in the desktop), a paste in the desktop (Ctrl+V,
   *  Shift+Insert; Cmd+V on Apple platforms) hands the page clipboard's
   *  text to the focused app. It never reads the page clipboard outside a
   *  paste unless the browser already granted clipboard-read. Default true;
   *  false: the Wayland clipboard stays inside the desktop (and the copy /
   *  paste chords go to the apps as plain keys). */
  clipboard?: boolean;
  /** Every engine event (after the view, input and window manager saw it),
   *  plus the view's and window manager's log lines as 'log' events. A
   *  commit's `pixels` may no longer be readable here (the view presented
   *  them, and input may have called the engine since). A consumer that
   *  throws (this one included) is reported asynchronously and does not keep
   *  the others from the event. */
  onEvent?(event: Event): void;
  /** The window list (windows()) changed: windows, titles, roles, focus,
   *  window states (maximized, fullscreen, minimized). */
  onWindowsChange?(): void;
}

/** A row of a taskbar / window list. Minimized windows are listed too
 *  (hidden; restore() or raise() brings them back). */
export interface WindowEntry {
  key: string;
  title: string;
  focused: boolean;
  maximized: boolean;
  fullscreen: boolean;
  minimized: boolean;
  /** Stack on top and take keyboard focus; a minimized window is restored
   *  (which raises and focuses it). */
  raise(): void;
  minimize(): void;
  restore(): void;
  setMaximized(maximized: boolean): void;
  setFullscreen(fullscreen: boolean): void;
}

export interface Wland {
  engine: Engine;
  view: View;
  input: Input;
  wm: WindowManager;
  /** The output apps see. It follows `container`'s client size (a
   *  ResizeObserver: resizing the container is all a page's layout has to
   *  do) and devicePixelRatio; setSize / setScale pin either one from
   *  then on, null follows the page again. Don't call engine.setOutput /
   *  setScale yourself: the next resize or dpr change would undo it. */
  output: OutputControl;
  windows(): WindowEntry[];
  /** Unmount wland without a page reload: disposes the engine (closes the
   *  link and every buffer token; nothing is emitted after it), stops the
   *  frame loop and the output watch, removes every document listener, the
   *  IME sink and every window. Then `container` is wland's no more, and a
   *  new createWland may take it (or another). */
  dispose(): void;
}

/** The display's frame interval (ms) from successive rAF timestamps: the
 *  median of the last 15 deltas, so dropped frames and a hidden tab's gap
 *  don't move it; 0 until 5 are known. rAF follows the display's refresh
 *  (timestamps are frame starts), which a page has no other way to learn. */
function frameInterval(): (time: number) => number {
  const deltas: number[] = [];
  let last = -1, estimate = 0;
  return (time) => {
    if (last >= 0 && time > last) {
      deltas.push(time - last);
      if (deltas.length > 15) deltas.shift();
      if (deltas.length >= 5) {
        const sorted = [...deltas].sort((a, b) => a - b);
        estimate = sorted[sorted.length >> 1];
      }
    }
    last = time;
    return estimate;
  };
}

/** Resolves once the core is loaded and the link is starting; rejects if the
 *  wasm can't load or an option is invalid, having undone everything it set
 *  up (no listener, observer, element or link is left behind). */
export async function createWland(options: WlandOptions): Promise<Wland> {
  const { container, scale } = options;
  if (!container) throw new Error('createWland: options.container is required');
  // checked before anything exists (watchOutput would throw it too, later)
  if (scale != null && !(typeof scale === 'number' && Number.isFinite(scale) && scale > 0)) {
    throw new RangeError(`createWland: scale ${scale} is not a positive number`);
  }
  const onEvent = options.onEvent || (() => {});
  const onWindowsChange = options.onWindowsChange || (() => {});
  // a throwing consumer must not cost the others the event: report it
  // asynchronously (as the engine does for its own onEvent) and carry on
  const each = (handle: (ev: Event) => void, ev: Event) => {
    try { handle(ev); } catch (e) { queueMicrotask(() => { throw e; }); }
  };
  const log = (line: string) => each(onEvent, { type: 'log', line });

  const view = createView({ container, webgl: options.webgl, log, onWindowsChange });
  // set before the link starts: events only flow after engine.start()
  let engine: Engine | undefined, input: Input | undefined, wm: WindowManager | undefined;
  let clip: ClipboardBridge | null = null;
  let output: OutputWatch | undefined;
  let raf = 0; // the frame loop's pending request; 0 = not running
  let disposed = false;
  // undo whatever exists, in dispose order; safe at any point of construction
  const teardown = () => {
    disposed = true;
    engine?.dispose(); // first: no event reaches the parts below any more
    cancelAnimationFrame(raf);
    output?.();
    wm?.dispose();
    clip?.dispose();
    input?.dispose();
    view.dispose();
  };
  // the link is a session one (its scene synced since it opened): the
  // default link reconnects after a drop while this holds (a failed
  // attempt opens nothing and keeps it)
  let sessionLink = false;
  const defaultLink = () => {
    const ws = createWsLink(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
    return options.reconnect === false ? ws : reconnecting(ws, () => sessionLink && !disposed);
  };
  try {
    engine = await createEngine({
      wasm: options.wasm,
      link: options.link || defaultLink(),
      buffers: options.buffers,
      gpu: options.gpu,
      // a 2D-only view takes buffer-source commits swizzled by the core; a GL
      // view takes the rows as written (its shader swaps channels)
      rgba: !view.webgl,
      onEvent(ev) {
        if (ev.type === 'open') sessionLink = false;
        else if (ev.type === 'synced') sessionLink = true;
        // the view first: a commit's pixels are only valid during dispatch,
        // and may be invalid once anything has called back into the engine
        each(view.handle, ev);
        each(input!.handle, ev);
        each(wm!.handle, ev);
        if (clip) each(clip.handle, ev);
        each(onEvent, ev);
        // one frame loop for the engine's life (a stream link may open again)
        if (ev.type === 'open' && !raf && !disposed) raf = requestAnimationFrame(frame);
      },
    });
    if (options.clipboard !== false) clip = createClipboardBridge({ engine, container, log });
    input = createInput({ engine, view, container, onFocusChange: onWindowsChange, clipboard: clip?.hooks });
    wm = createWindowManager({ engine, view, input, container, log,
      browserFullscreen: options.browserFullscreen, shortcuts: options.shortcuts });
    output = watchOutput(engine, container, scale);
  } catch (e) {
    teardown();
    throw e;
  }
  const eng = engine, inp = input, mgr = wm, out = output;

  // frame callbacks and presentation feedback follow the page's frame
  // clock; rAF's timestamps also measure the display's frame interval
  const interval = frameInterval();
  const frame = (t: number) => {
    eng.tick(t, interval(t));
    if (!disposed) raf = requestAnimationFrame(frame); // (an event may have disposed us)
  };

  eng.start();

  return {
    engine: eng, view, input: inp, wm: mgr,
    // inert after dispose (watchOutput's stop makes them no-ops)
    output: { setSize: out.setSize, setScale: out.setScale, state: out.state },
    dispose() {
      if (disposed) return;
      teardown();
    },
    windows: () => view.windows().map((w) => ({
      key: w.key,
      title: w.title,
      focused: inp.focused(w.conn, w.surface),
      maximized: w.maximized,
      fullscreen: w.fullscreen,
      minimized: w.minimized,
      raise() {
        if (view.window(w.conn, w.surface)?.minimized) return mgr.restore(w.conn, w.surface);
        view.raise(w.conn, w.surface);
        inp.focus(w.conn, w.surface);
      },
      minimize: () => mgr.minimize(w.conn, w.surface),
      restore: () => mgr.restore(w.conn, w.surface),
      setMaximized: (on: boolean) => mgr.setMaximized(w.conn, w.surface, on),
      setFullscreen: (on: boolean) => mgr.setFullscreen(w.conn, w.surface, on),
    })),
  };
}
