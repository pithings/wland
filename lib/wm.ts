// wland window manager: what a desktop compositor does around the surfaces.
// App-initiated move/resize grabs (xdg_toplevel.move/.resize), maximize and
// fullscreen placement, minimize/restore (focus and stacking), Alt+drag
// move, the window key bindings, popup dismissal on outside click, and the
// dnd session (wl_data_device.start_drag). Window positions are DOM state:
// the core has none. It moves the view's window elements, so it assumes the
// view's default mount (windows absolutely positioned in one container); an
// embedder hosting windows in its own frames brings its own window manager.
//
// Window states are the core's (maximized, fullscreen, minimized): the app
// asks, or the embedder does through this module (setFullscreen, minimize,
// restore, …), and either way the core answers with an event this module
// acts on. Fullscreen means the window fills the container, stacked on top
// when it goes fullscreen; another window raised later stacks above it
// without ending its fullscreen. With `browserFullscreen` the container
// also goes into the browser's fullscreen (Element.requestFullscreen, which
// needs a user gesture: at once when the page has one, else at the next
// press in the container), and the browser leaving it (Esc) takes every
// window out of fullscreen.
//
// Key bindings (Alt, as Alt+drag; the keys are swallowed, the app sees the
// Alt alone): Alt+F11 toggles fullscreen, Alt+F10 maximize, Alt+F9
// minimizes — on the window holding keyboard focus.
//
// The types below are the contract.

import type { Engine, Event as WlandEvent } from './engine.ts';
import type { Input } from './input.ts';
import type { View, ViewWindow } from './view.ts';

export interface WindowManagerOptions {
  engine: Engine;
  view: View;
  /** Suppressed while a grab or a drag owns the pointer. */
  input: Input;
  /** The windows' container: maximize and fullscreen fill it, Alt+drag
   *  stays inside it, browserFullscreen puts it in the browser's
   *  fullscreen. */
  container: HTMLElement;
  /** A fullscreen window also takes the browser's fullscreen (the
   *  container's; see the file comment). Default false: fullscreen fills
   *  the container only. */
  browserFullscreen?: boolean;
  /** The Alt+F9/F10/F11 bindings. Default true. */
  shortcuts?: boolean;
  log?(line: string): void;
}

export interface WindowManager {
  /** Feed every engine event. */
  handle(event: WlandEvent): void;
  /** Fullscreen or back (engine.setFullscreen; the 'fullscreen' event does
   *  the rest). */
  setFullscreen(conn: number, surface: number, fullscreen: boolean): void;
  /** Maximize or back (engine.setMaximized). */
  setMaximized(conn: number, surface: number, maximized: boolean): void;
  /** Hide a window (engine.setMinimized): focus passes to the topmost one
   *  left. */
  minimize(conn: number, surface: number): void;
  /** Bring a minimized window back where it was, raised and focused. */
  restore(conn: number, surface: number): void;
  /** Remove its document listeners; a grab or drag in progress just ends.
   *  DOM only: the engine is not told. */
  dispose(): void;
}

const ROLE_TOPLEVEL = 1, ROLE_POPUP = 4, ROLE_DND_ICON = 5;
const EDGE_CURSORS: Record<number, string | undefined> = { 1: 'n-resize', 2: 's-resize', 4: 'w-resize', 8: 'e-resize',
                       5: 'nw-resize', 9: 'ne-resize', 6: 'sw-resize', 10: 'se-resize' };

const now = () => performance.now() >>> 0;
const keyOf = (conn: number, surface: number) => `c${conn}s${surface}`;

/** An app-initiated move/resize in progress. */
interface Grab {
  el: HTMLElement; conn: number; surface: number; mode: 'move' | 'resize'; edges: number;
  startX: number; startY: number; startL: number; startT: number; startW: number; startH: number;
  lastW: number; lastH: number; queued: boolean;
}
type Target = { conn: number; surface: number; x: number; y: number };
/** A dnd session in progress. */
interface Dnd { conn: number; icon: number; queued: boolean; last: Target | null }
type Listener = [type: string, fn: (ev: any) => void, opts?: boolean | AddEventListenerOptions];

export function createWindowManager(options: WindowManagerOptions): WindowManager {
  const { engine, view, input, container } = options;
  const log = options.log || (() => {});
  let lastPointer = { x: 0, y: 0 };
  let grab: Grab | null = null;
  let dnd: Dnd | null = null;
  const popups = new Map<string, { conn: number; surface: number }>(); // mapped popups
  const restore = new Map<string, { left: string; top: string }>(); // window key → position before maximize/fullscreen
  // window key → its states as the core last said (events and commits)
  const states = new Map<string, { conn: number; surface: number; maximized: boolean; fullscreen: boolean; minimized: boolean }>();
  // wanted: a fullscreen window waits for it (retried at the next press);
  // requested: a request of ours is out; ours: the browser's fullscreen is
  // one we asked for (a page's own fullscreen of the container is left alone)
  const browserFs = { wanted: false, requested: false, ours: false };
  const swallowed = new Set<string>(); // key codes whose keyup is ours too
  // document listeners, kept for dispose()
  const listening: Listener[] = [];
  const on = <K extends keyof DocumentEventMap>(type: K, fn: (ev: DocumentEventMap[K]) => void,
    opts?: boolean | AddEventListenerOptions) => {
    document.addEventListener(type, fn, opts);
    listening.push([type, fn, opts]);
  };

  // the pointer goes back to whatever surface is under it after a grab
  function reenter(x: number, y: number) {
    const t = view.surfaceAt(x, y);
    if (t) engine.pointerEnter(t.conn, t.surface, t.x, t.y);
  }

  // --- move/resize grabs: the app got the press that triggered its request;
  // from here the WM owns the drag. App pointer events are suppressed until
  // release, bracketed by pointer leave/enter.
  function beginGrab(conn: number, surface: number, mode: Grab['mode'], edges: number) {
    const win = view.window(conn, surface);
    if (!win || grab || dnd) return;
    engine.pointerLeave(conn); // ends the app's own gesture
    input.suppress(true);
    const el = win.element;
    grab = { el, conn, surface, mode, edges,
      startX: lastPointer.x, startY: lastPointer.y,
      startL: el.offsetLeft, startT: el.offsetTop,
      startW: el.offsetWidth, startH: el.offsetHeight,
      lastW: el.offsetWidth, lastH: el.offsetHeight, queued: false };
    view.raise(conn, surface);
    document.body.style.cursor = mode === 'move' ? 'grabbing' : (EDGE_CURSORS[edges] || 'default');
  }

  function grabMove(ev: PointerEvent) {
    const g = grab!;
    const dx = ev.clientX - g.startX, dy = ev.clientY - g.startY;
    if (g.mode === 'move') {
      g.el.style.left = `${g.startL + dx}px`;
      g.el.style.top = `${Math.max(0, g.startT + dy)}px`;
      return;
    }
    // edges: 1 top, 2 bottom, 4 left, 8 right. Left/top also shift the box;
    // the far edge wobbles until the app's re-rendered buffer catches up
    // (positions are ours, sizes are the app's)
    let w = g.startW, h = g.startH;
    if (g.edges & 8) w += dx;
    if (g.edges & 4) { w -= dx; g.el.style.left = `${g.startL + dx}px`; }
    if (g.edges & 2) h += dy;
    if (g.edges & 1) { h -= dy; g.el.style.top = `${Math.max(0, g.startT + dy)}px`; }
    g.lastW = Math.max(80, w);
    g.lastH = Math.max(60, h);
    if (!g.queued) {
      g.queued = true;
      requestAnimationFrame(() => {
        g.queued = false;
        if (grab === g) engine.requestResize(g.conn, g.surface, g.lastW, g.lastH);
      });
    }
  }

  function endGrab(ev: PointerEvent) {
    const g = grab!;
    grab = null;
    document.body.style.cursor = '';
    if (g.mode === 'resize') engine.requestResize(g.conn, g.surface, g.lastW, g.lastH);
    input.suppress(false);
    reenter(ev.clientX, ev.clientY);
  }

  // Alt+drag anywhere on a window moves it; purely DOM-side (not a
  // fullscreen window: it fills the container)
  function altMove(ev: PointerEvent, win: ViewWindow) {
    if (win.fullscreen) return;
    ev.preventDefault();
    ev.stopPropagation();
    view.raise(win.conn, win.surface);
    const el = win.element;
    el.setPointerCapture(ev.pointerId);
    const startX = ev.clientX, startY = ev.clientY;
    const startL = el.offsetLeft, startT = el.offsetTop;
    const onMove = (mv: PointerEvent) => {
      // clamp so a grabbable corner always stays inside the container
      const l = Math.min(Math.max(startL + mv.clientX - startX, 40 - el.offsetWidth), container.clientWidth - 40);
      const t = Math.min(Math.max(startT + mv.clientY - startY, 0), container.clientHeight - 24);
      el.style.left = `${l}px`;
      el.style.top = `${t}px`;
    };
    const onUp = (up: PointerEvent) => {
      el.releasePointerCapture(up.pointerId);
      el.removeEventListener('pointermove', onMove);
      el.removeEventListener('pointerup', onUp);
    };
    el.addEventListener('pointermove', onMove);
    el.addEventListener('pointerup', onUp);
  }

  // --- maximize / fullscreen: windows sit at the container origin --------
  function stateOf(conn: number, surface: number) {
    const key = keyOf(conn, surface);
    let st = states.get(key);
    if (!st) states.set(key, st = { conn, surface, maximized: false, fullscreen: false, minimized: false });
    return st;
  }
  function place(conn: number, surface: number) {
    const st = stateOf(conn, surface);
    if (st.maximized || st.fullscreen) snap(conn, surface);
    else unsnap(conn, surface);
  }
  function snap(conn: number, surface: number) {
    const win = view.window(conn, surface);
    if (!win) return;
    const st = win.element.style;
    if (st.left === '0px' && st.top === '0px') return;
    if (!restore.has(win.key)) restore.set(win.key, { left: st.left, top: st.top });
    st.left = '0px';
    st.top = '0px';
  }
  function unsnap(conn: number, surface: number) {
    const win = view.window(conn, surface);
    if (!win) return;
    const pos = restore.get(win.key);
    restore.delete(win.key);
    if (pos) { win.element.style.left = pos.left; win.element.style.top = pos.top; }
  }

  // --- the browser's fullscreen (browserFullscreen) -------------------------
  // wanted while a fullscreen window is shown; entered with a user gesture
  // (now if the page has one, else at the next press in the container);
  // left when none is, and leaving it unasked (Esc) ends theirs
  const showingFullscreen = () => [...states.values()].some((s) => s.fullscreen && !s.minimized);
  function requestBrowserFs() {
    if (!options.browserFullscreen || document.fullscreenElement === container) return;
    if (typeof container.requestFullscreen !== 'function') return;
    browserFs.wanted = true;
    if (browserFs.requested) return; // one out already
    const act = (navigator as { userActivation?: { isActive: boolean } }).userActivation;
    if (act && !act.isActive) return; // at the next press
    let p: unknown;
    browserFs.requested = true;
    try { p = container.requestFullscreen(); } catch { browserFs.requested = false; return; }
    if (p && typeof (p as Promise<void>).catch === 'function') {
      (p as Promise<void>).catch(() => { browserFs.requested = false; /* the next press */ });
    }
  }
  function syncBrowserFs() {
    if (!options.browserFullscreen) return;
    if (showingFullscreen()) return requestBrowserFs();
    browserFs.wanted = false;
    if (browserFs.ours && document.fullscreenElement === container) {
      browserFs.ours = false;
      document.exitFullscreen().catch(() => {});
    }
  }
  if (options.browserFullscreen) {
    on('fullscreenerror', () => { browserFs.requested = false; }); // refused: the next press
    on('fullscreenchange', () => {
      if (document.fullscreenElement === container) {
        if (!browserFs.requested) return; // the page's own
        browserFs.requested = false;
        browserFs.ours = true;
        browserFs.wanted = false;
        // a grant after the windows left fullscreen meanwhile
        if (!showingFullscreen()) syncBrowserFs();
        return;
      }
      if (!browserFs.ours) return;
      // the browser left it on its own (Esc, a tab switch): the windows too
      browserFs.ours = false;
      for (const s of states.values()) if (s.fullscreen) engine.setFullscreen(s.conn, s.surface, false);
    });
  }

  // --- key bindings ---------------------------------------------------------
  const BINDINGS: Record<string, ((s: { conn: number; surface: number; maximized: boolean; fullscreen: boolean }) => void) | undefined> = {
    F11: (s) => engine.setFullscreen(s.conn, s.surface, !s.fullscreen),
    F10: (s) => engine.setMaximized(s.conn, s.surface, !s.maximized),
    F9: (s) => engine.setMinimized(s.conn, s.surface, true),
  };
  function focusedWindow() {
    for (const w of view.windows()) if (!w.minimized && input.focused(w.conn, w.surface)) return w;
    return null;
  }

  // --- dnd: like a grab, but the compositor drives the session and closes
  // it ('drag-end'): drops, cancels and app deaths all funnel through that.
  function placeIcon() {
    if (!dnd || !dnd.icon) return;
    const icon = view.canvas(dnd.conn, dnd.icon);
    if (icon) {
      icon.style.left = `${lastPointer.x + 4}px`;
      icon.style.top = `${lastPointer.y + 4}px`;
    }
  }
  function dndTarget(x: number, y: number): Target {
    return view.surfaceAt(x, y) || { conn: 0, surface: 0, x: 0, y: 0 }; // 0,0 = over nothing
  }
  function dndMove(ev: PointerEvent) {
    placeIcon();
    const d = dnd!;
    d.last = dndTarget(ev.clientX, ev.clientY);
    if (!d.queued) {
      d.queued = true;
      requestAnimationFrame(() => {
        d.queued = false;
        const t = d.last!; // the newest target, not the one that queued the frame
        if (dnd === d) engine.dragMotion(t.conn, t.surface, now(), t.x, t.y);
      });
    }
  }

  on('pointermove', (ev) => {
    lastPointer = { x: ev.clientX, y: ev.clientY };
    if (dnd) dndMove(ev);
    else if (grab) grabMove(ev);
  }, true);

  on('pointerup', (ev) => {
    if (dnd) {
      // final position, then the drop; the compositor answers with
      // 'drag-end' whether it lands or cancels
      const t = dndTarget(ev.clientX, ev.clientY);
      engine.dragMotion(t.conn, t.surface, now(), t.x, t.y);
      engine.dragDrop();
      ev.stopPropagation();
      reenter(ev.clientX, ev.clientY);
    } else if (grab) {
      // the release belongs to the grab, not to the app under the pointer
      ev.stopPropagation();
      endGrab(ev);
    }
  }, true);

  on('pointerdown', (ev) => {
    // a grab starts from here: a touch has no hover moves before its press,
    // so without this lastPointer is where the previous touch ended
    lastPointer = { x: ev.clientX, y: ev.clientY };
    // fake popup grab: a press anywhere but on an open popup dismisses it
    // (its canvas or, with an input region, its hit element: a press in a
    // popover's shadow misses it)
    const pressed = view.surfaceOf(ev.target);
    for (const [key, p] of popups) {
      const canvas = view.canvas(p.conn, p.surface);
      if (!canvas || !canvas.isConnected) { popups.delete(key); continue; }
      if (!pressed || pressed.conn !== p.conn || pressed.surface !== p.surface) {
        log(`popup dismiss → ${key}`);
        popups.delete(key);
        engine.popupDismiss(p.conn, p.surface);
      }
    }
    if (ev.altKey && !grab && !dnd) {
      const s = view.surfaceOf(ev.target);
      const win = s && view.window(s.conn, s.root);
      if (win) altMove(ev, win);
    }
    // the user gesture the browser's fullscreen waited for
    if (browserFs.wanted && container.contains(ev.target as Node)) requestBrowserFs();
  }, true);

  on('keydown', (ev) => {
    if (dnd && ev.key === 'Escape') {
      engine.dragCancel();
      ev.preventDefault();
      ev.stopPropagation();
      return;
    }
    // window bindings: Alt and nothing else, on the focused window; the key
    // (down and up) never reaches the app
    const bind = options.shortcuts !== false && ev.altKey && !ev.ctrlKey && !ev.metaKey && !ev.shiftKey
      ? BINDINGS[ev.code] : undefined;
    const win = bind && focusedWindow();
    if (!bind || !win) return;
    ev.preventDefault();
    ev.stopPropagation();
    swallowed.add(ev.code);
    if (!ev.repeat) bind(stateOf(win.conn, win.surface));
  }, true);
  on('keyup', (ev) => {
    if (!swallowed.delete(ev.code)) return;
    ev.preventDefault();
    ev.stopPropagation();
  }, true);

  function handle(ev: WlandEvent) {
    switch (ev.type) {
      case 'move': beginGrab(ev.conn, ev.surface, 'move', 0); break;
      case 'resize': beginGrab(ev.conn, ev.surface, 'resize', ev.edges); break;
      case 'maximize':
        stateOf(ev.conn, ev.surface).maximized = ev.maximized;
        place(ev.conn, ev.surface);
        break;
      case 'fullscreen': {
        const st = stateOf(ev.conn, ev.surface);
        st.fullscreen = ev.fullscreen;
        place(ev.conn, ev.surface);
        // it covers the container: on top, and the keyboard's (once mapped:
        // an app may ask before its first commit)
        if (ev.fullscreen && !st.minimized && view.window(ev.conn, ev.surface)) {
          view.raise(ev.conn, ev.surface);
          input.focus(ev.conn, ev.surface);
        }
        if (grab && grab.conn === ev.conn && grab.surface === ev.surface) cancelGrab();
        syncBrowserFs();
        break;
      }
      case 'minimize': {
        stateOf(ev.conn, ev.surface).minimized = ev.minimized;
        if (ev.minimized) {
          // (input hands the keyboard on; the view hides it)
          if (grab && grab.conn === ev.conn && grab.surface === ev.surface) cancelGrab();
          for (const [key, p] of popups) if (p.conn === ev.conn) popups.delete(key); // the core dismissed them
        } else {
          view.raise(ev.conn, ev.surface);
          input.focus(ev.conn, ev.surface);
        }
        syncBrowserFs();
        break;
      }
      case 'commit':
        // enforced per commit too: apps can START maximized or fullscreen
        // (saved session state) before their window existed for the event
        if (ev.role === ROLE_TOPLEVEL) {
          const st = stateOf(ev.conn, ev.surface);
          const was = st.fullscreen;
          st.maximized = ev.maximized;
          st.fullscreen = ev.fullscreen;
          st.minimized = ev.minimized;
          if (ev.maximized || ev.fullscreen) snap(ev.conn, ev.surface);
          if (ev.fullscreen && !was) { view.raise(ev.conn, ev.surface); syncBrowserFs(); }
        } else if (ev.role === ROLE_POPUP) popups.set(keyOf(ev.conn, ev.surface), { conn: ev.conn, surface: ev.surface });
        else if (ev.role === ROLE_DND_ICON) placeIcon();
        break;
      case 'surface':
        if (ev.role === ROLE_DND_ICON) placeIcon();
        else if (ev.role !== ROLE_POPUP) popups.delete(keyOf(ev.conn, ev.surface));
        // an unmapped toplevel's states went with its xdg_toplevel
        if (ev.role !== ROLE_TOPLEVEL && states.delete(keyOf(ev.conn, ev.surface))) syncBrowserFs();
        break;
      case 'destroy':
        popups.delete(keyOf(ev.conn, ev.surface));
        restore.delete(keyOf(ev.conn, ev.surface));
        if (states.delete(keyOf(ev.conn, ev.surface))) syncBrowserFs();
        break;
      case 'disconnect':
        for (const [key, p] of popups) if (p.conn === ev.conn) popups.delete(key);
        for (const key of restore.keys()) if (key.startsWith(`c${ev.conn}s`)) restore.delete(key);
        for (const [key, s] of states) if (s.conn === ev.conn) states.delete(key);
        syncBrowserFs();
        if (grab && grab.conn === ev.conn) cancelGrab();
        break;
      case 'drag-start':
        if (dnd || grab) break;
        engine.pointerLeave(ev.conn); // the drag grab steals the pointer
        input.suppress(true);
        dnd = { conn: ev.conn, icon: ev.icon, queued: false, last: null };
        placeIcon();
        document.body.style.cursor = 'grabbing';
        break;
      case 'drag-end':
        dnd = null;
        input.suppress(false);
        document.body.style.cursor = '';
        break;
    }
  }

  // a grab whose window went away or can't move any more: no re-enter
  function cancelGrab() {
    grab = null;
    document.body.style.cursor = '';
    input.suppress(false);
  }

  return {
    handle,
    setFullscreen: (conn, surface, on) => engine.setFullscreen(conn, surface, on),
    setMaximized: (conn, surface, on) => engine.setMaximized(conn, surface, on),
    minimize: (conn, surface) => engine.setMinimized(conn, surface, true),
    restore: (conn, surface) => engine.setMinimized(conn, surface, false),
    // DOM only: a grab or drag in progress just ends (the engine is not
    // told); the browser's fullscreen, if it was ours, is left
    dispose() {
      for (const [type, fn, opts] of listening.splice(0)) document.removeEventListener(type, fn, opts);
      if (grab || dnd) document.body.style.cursor = '';
      grab = null;
      dnd = null;
      popups.clear();
      restore.clear();
      states.clear();
      if (browserFs.ours && document.fullscreenElement === container) document.exitFullscreen().catch(() => {});
      browserFs.ours = browserFs.wanted = browserFs.requested = false;
    },
  };
}
