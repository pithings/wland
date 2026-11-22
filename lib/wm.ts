// wland window manager: what a desktop compositor does around the surfaces.
// App-initiated move/resize grabs (xdg_toplevel.move/.resize), maximize and
// fullscreen placement, minimize/restore (focus and stacking), Alt+drag
// move, the window key bindings, popup dismissal on outside click, and the
// dnd session (wl_data_device.start_drag). Window positions are DOM state;
// the core is only told them (Engine.setWindowPosition, `positions`: it
// constrains popups to the output with them). It moves the view's window
// elements, so it assumes the view's default mount (windows absolutely
// positioned in one container); an embedder hosting windows in its own
// frames brings its own window manager, or keeps this one for the rest
// and takes interactive move/resize
// (`interactive`: the app's requests and Alt+drag, with the press they came
// from) and focus (input's `autoFocus: false`: this module then focuses
// nothing either — not a window it restores or makes fullscreen, nor the
// top window at 'synced').
//
// Every drag here (move/resize grab, Alt+drag, dnd) holds an input grab
// (Input.grab): it ends at its pointer's release, cancel or lost capture or
// the window's blur, whoever sees it first, and the pointer is entered into
// the surface under it again after.
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
// On a session link (engine.session(): the compositor is the relay's, the
// apps outlive the page) window positions and their stacking are kept in
// sessionStorage, `wland.win:<session id>:<conn>:<surface>` → {x, y, z}:
// written after each press, window state change and scene sync and as the
// page goes (pagehide), put back when the scene the relay replays to the
// reloaded page maps the windows again (positions at their first commit,
// the stacking at 'synced', which also focuses the top window unless
// input's autoFocus is off), dropped
// when the window or its app really goes. Window states are not kept: they
// are the relay's and come back with the scene. Nothing of this runs on a
// passthrough link.
//
// The types below are the contract.

import { ROLE_DND_ICON, ROLE_POPUP, ROLE_TOPLEVEL, type Engine, type Event as WlandEvent } from './engine.ts';
import type { MoveEvent, ResizeEvent } from './engine.ts';
import type { GrabEndReason, Input, PointerGrab } from './input.ts';
import type { View, ViewWindow } from './view.ts';

export interface WindowManagerOptions {
  engine: Engine;
  view: View;
  /** Grabbed (Input.grab) while a grab or a drag owns the pointer; its
   *  autoFocus is this module's too. */
  input: Input;
  /** The windows' container: maximize and fullscreen fill it, Alt+drag
   *  stays inside it, browserFullscreen puts it in the browser's
   *  fullscreen. */
  container: HTMLElement;
  /** A fullscreen window also takes the browser's fullscreen (the
   *  container's; see the file comment). Default false: fullscreen fills
   *  the container only. */
  browserFullscreen?: boolean;
  /** The window bindings. A boolean is the Alt+F9/F10/F11 keys alone
   *  (Alt+drag stays, as it always did); `{ keys, drag }` sets the keys and
   *  Alt+drag apart (each default true). With `drag: false` an Alt+press
   *  goes to the app like any other press. Default true. */
  shortcuts?: boolean | { keys?: boolean; drag?: boolean };
  /** An embedder's window manager owning interactive move and resize: an
   *  app's xdg_toplevel.move / .resize (the engine's 'move' / 'resize'
   *  event as is), and the Alt+drag binding (an 'alt-drag': no app asked).
   *  Called only while `press`, the pointer press it came from, is still
   *  down (a request after its release is dropped first, as always);
   *  return true when you handle it — this window manager then starts no
   *  grab of its own (for Alt+drag: nor stops the press, so your frame's
   *  listeners see it too). Take the pointer from the apps for your drag
   *  with `input.grab(press.pointerId)`: it ends at that pointer's release
   *  whatever happens. False or absent: the default grab. */
  interactive?(ev: InteractiveEvent, press: PointerPress): boolean;
  /** Tell the core where each window is (Engine.setWindowPosition: the
   *  window element's left/top, the window geometry's top-left in the
   *  container), so the apps' popups are constrained to the output — at
   *  its first commit and whenever this module moves it. Right for the
   *  view's default mount (windows absolutely positioned in `container`,
   *  whose box is the output); default true. createWland turns it off with
   *  a `mount` of the embedder's, whose frames put the element elsewhere:
   *  that window manager calls setWindowPosition itself. */
  positions?: boolean;
  log?(line: string): void;
}

/** What WindowManagerOptions.interactive is asked about. */
export type InteractiveEvent = MoveEvent | ResizeEvent | AltDragEvent;

/** The Alt+drag binding: an Alt+press on a window (any surface of it);
 *  the user's move, not the app's request. */
export interface AltDragEvent { type: 'alt-drag'; conn: number; surface: number }

/** The pointer press an interactive move/resize started from (the
 *  pointerdown's fields; client px are viewport px). */
export interface PointerPress {
  pointerId: number;
  /** 'mouse' | 'pen' | 'touch' */
  pointerType: string;
  clientX: number;
  clientY: number;
  /** PointerEvent.button: 0 primary, 1 middle, 2 secondary */
  button: number;
  /** PointerEvent.buttons at the press */
  buttons: number;
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
   *  left (autoFocus; else no window has it). */
  minimize(conn: number, surface: number): void;
  /** Bring a minimized window back where it was, raised and focused (not
   *  focused without autoFocus). */
  restore(conn: number, surface: number): void;
  /** Remove its document listeners; a grab or drag in progress just ends.
   *  DOM only: the engine is not told. */
  dispose(): void;
}

const EDGE_CURSORS: Record<number, string | undefined> = { 1: 'n-resize', 2: 's-resize', 4: 'w-resize', 8: 'e-resize',
                       5: 'nw-resize', 9: 'ne-resize', 6: 'sw-resize', 10: 'se-resize' };

const now = () => performance.now() >>> 0;
const pressOf = (ev: PointerEvent): PointerPress => ({ pointerId: ev.pointerId, pointerType: ev.pointerType || 'mouse',
  clientX: ev.clientX, clientY: ev.clientY, button: ev.button, buttons: ev.buttons });
const keyOf = (conn: number, surface: number) => `c${conn}s${surface}`;

// sessionStorage for the session's window places (see the file comment);
// every access may throw (storage disabled) or find none (Node)
const PLACE_PREFIX = 'wland.win:';
interface Place { x: number; y: number; z: number }
function store(): Storage | null {
  try { return typeof sessionStorage === 'undefined' ? null : sessionStorage; } catch { return null; }
}
function loadPlace(key: string): Place | null {
  try {
    const v = JSON.parse(store()?.getItem(key) ?? 'null');
    return v && Number.isFinite(v.x) && Number.isFinite(v.y) && Number.isFinite(v.z) ? v : null;
  } catch { return null; }
}
function savePlace(key: string, place: Place) {
  try { store()?.setItem(key, JSON.stringify(place)); } catch { /* full or disabled */ }
}
// remove the keys `drop` picks
function dropPlaces(drop: (key: string) => boolean) {
  try {
    const st = store();
    if (!st) return;
    const keys: string[] = [];
    for (let i = 0; i < st.length; i++) {
      const k = st.key(i);
      if (k && k.startsWith(PLACE_PREFIX) && drop(k)) keys.push(k);
    }
    for (const k of keys) st.removeItem(k);
  } catch { /* */ }
}

/** An app-initiated move/resize in progress; `pointer` the pointerId it
 *  follows (the press that made the app ask). */
interface Grab {
  el: HTMLElement; conn: number; surface: number; mode: 'move' | 'resize'; edges: number; pointer: number;
  startX: number; startY: number; startL: number; startT: number; startW: number; startH: number;
  lastW: number; lastH: number; queued: boolean; hold: PointerGrab;
}
type Target = { conn: number; surface: number; x: number; y: number };
/** A dnd session in progress, following pointerId `pointer`. */
interface Dnd { conn: number; icon: number; queued: boolean; last: Target | null; pointer: number; hold?: PointerGrab }
type Listener = [type: string, fn: (ev: any) => void, opts?: boolean | AddEventListenerOptions];

export function createWindowManager(options: WindowManagerOptions): WindowManager {
  const { engine, view, input, container } = options;
  const log = options.log || (() => {});
  // the bindings (`shortcuts`: a boolean is the keys alone)
  const sc = options.shortcuts;
  const keysOn = typeof sc === 'object' && sc ? sc.keys !== false : sc !== false;
  const altDragOn = typeof sc === 'object' && sc ? sc.drag !== false : true;
  const positionsOn = options.positions !== false;
  // window key → the position last told the core ('x,y'): told again only
  // when it changed; forgotten when the core forgets it (a new link, the
  // toplevel unmapped, a session's new viewer)
  const told = new Map<string, string>();
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
  // pointers with a button down (pointerdown → pointerup/cancel; a window
  // blur forgets them), each with its press: a grab or drag the app asks
  // for after the release never starts (see beginGrab), and `interactive`
  // is handed the press
  const held = new Map<number, PointerPress>();
  // the pointer pressed last, while it is held: the press a grab or drag the
  // app asks for came from, so the one that pointer's events drive and end
  // (another pointer — a hovering pen, a mouse beside a touch — does nothing
  // to it)
  let lastPressed = -1;
  // document listeners (and the window's blur), kept for dispose()
  const listening: Listener[] = [];
  const on = <K extends keyof DocumentEventMap>(type: K, fn: (ev: DocumentEventMap[K]) => void,
    opts?: boolean | AddEventListenerOptions) => {
    document.addEventListener(type, fn, opts);
    listening.push([type, fn, opts]);
  };
  // (whatever owns the pointer lets go at the blur through its input grab)
  const onBlur = () => held.clear();
  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') window.addEventListener('blur', onBlur);

  // --- window positions for the core (popup constraints; `positions`) -----
  // the element's left/top (a fullscreen window's 0,0: its geometry centred
  // in the container when smaller is not accounted for)
  function tellPosition(conn: number, surface: number) {
    if (!positionsOn) return;
    const win = view.window(conn, surface);
    if (!win) return;
    const x = parseFloat(win.element.style.left), y = parseFloat(win.element.style.top);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    const at = `${Math.round(x)},${Math.round(y)}`;
    if (told.get(win.key) === at) return;
    told.set(win.key, at);
    engine.setWindowPosition(conn, surface, x, y);
  }

  // --- session: window places across reloads (see the file comment) -------
  // sid: the session id as of the last 'synced' (null: passthrough, or the
  // link closed); checked: window elements whose saved place was looked up
  let sid: string | null = null;
  const checked = new WeakSet<HTMLElement>();
  let persistTimer: ReturnType<typeof setTimeout> | undefined;
  const placeKey = (conn: number, surface: number) => `${PLACE_PREFIX}${sid}:${conn}:${surface}`;
  // every window's floating position (where it goes back to while
  // maximized or fullscreen) and its z-index, written
  function persist() {
    if (!sid) return;
    for (const w of view.windows()) {
      const pos = restore.get(w.key) ?? { left: w.element.style.left, top: w.element.style.top };
      const x = parseFloat(pos.left), y = parseFloat(pos.top);
      if (Number.isFinite(x) && Number.isFinite(y)) {
        savePlace(placeKey(w.conn, w.surface), { x, y, z: Number(w.element.style.zIndex) || 0 });
      }
    }
  }
  // after the press's own work (a click's raise comes after the pointerup)
  function persistSoon() {
    if (!sid || persistTimer !== undefined) return;
    persistTimer = setTimeout(() => { persistTimer = undefined; persist(); }, 0);
  }
  // a window the scene mapped again: back where it was (its restore
  // position while maximized or fullscreen — the wm snapped it already, or
  // will at this commit)
  function placeSaved(w: ViewWindow) {
    if (checked.has(w.element)) return;
    checked.add(w.element);
    const saved = loadPlace(placeKey(w.conn, w.surface));
    if (!saved) return;
    const pos = { left: `${saved.x}px`, top: `${saved.y}px` };
    if (restore.has(w.key)) restore.set(w.key, pos);
    else { w.element.style.left = pos.left; w.element.style.top = pos.top; tellPosition(w.conn, w.surface); }
  }
  // the scene is all there: places for the windows mapped before the id
  // was known, the saved stacking, the keyboard to the top window
  function synced() {
    sid = engine.session?.()?.id ?? null;
    // a new viewer: the relay forgot the positions the last one told
    told.clear();
    for (const w of view.windows()) tellPosition(w.conn, w.surface);
    if (!sid) return;
    const current = `${PLACE_PREFIX}${sid}:`;
    dropPlaces((k) => !k.startsWith(current)); // an earlier relay run's
    const stack: { w: ViewWindow; z: number }[] = [];
    for (const w of view.windows()) {
      placeSaved(w);
      const saved = loadPlace(placeKey(w.conn, w.surface));
      if (saved) stack.push({ w, z: saved.z });
    }
    if (stack.length) {
      stack.sort((a, b) => a.z - b.z);
      for (const { w } of stack) view.raise(w.conn, w.surface);
      const top = [...stack].reverse().find(({ w }) => !w.minimized);
      if (top && input.autoFocus) input.focus(top.w.conn, top.w.surface);
    }
    persist();
  }
  const onPageHide = () => persist();
  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') window.addEventListener('pagehide', onPageHide);

  // --- move/resize grabs: the app got the press that triggered its request;
  // from here the WM owns the drag — unless the embedder's `interactive`
  // takes it. App pointer events are held off by an input grab until
  // release, bracketed by pointer leave/enter. Only while a button is still
  // down: the core drops a request whose press was released, but the
  // engine may sit behind a link or a worker, and a grab started after
  // the release would follow a pointer with no button down. It ends at
  // the release — a pointerup, a pointercancel, a move that shows no
  // button down (a release the page didn't see), or the window's blur:
  // input's grab sees each first and ends it (endGrab).
  function beginGrab(ev: MoveEvent | ResizeEvent) {
    const { conn, surface } = ev, mode = ev.type, edges = ev.type === 'resize' ? ev.edges : 0;
    const win = view.window(conn, surface);
    if (!win || grab || dnd) return;
    const pointer = grabPointer(), press = held.get(pointer);
    if (!press) {
      log(`${mode} for c${conn}s${surface} after the release — ignored`);
      return;
    }
    if (options.interactive?.(ev, press)) return; // the embedder's drag
    const el = win.element;
    const g: Grab = { el, conn, surface, mode, edges, pointer,
      startX: lastPointer.x, startY: lastPointer.y,
      startL: el.offsetLeft, startT: el.offsetTop,
      startW: el.offsetWidth, startH: el.offsetHeight,
      lastW: el.offsetWidth, lastH: el.offsetHeight, queued: false,
      hold: input.grab(pointer, { onEnd: () => { if (grab === g) endGrab(g); } }) };
    if (!g.hold.active) return; // (input saw the release go by)
    engine.pointerLeave(conn); // ends the app's own gesture (the grab left whoever had the pointer)
    grab = g;
    view.raise(conn, surface);
    document.body.style.cursor = mode === 'move' ? 'grabbing' : (EDGE_CURSORS[edges] || 'default');
  }

  function grabMove(ev: PointerEvent) {
    const g = grab!;
    const dx = ev.clientX - g.startX, dy = ev.clientY - g.startY;
    if (g.mode === 'move') {
      g.el.style.left = `${g.startL + dx}px`;
      g.el.style.top = `${Math.max(0, g.startT + dy)}px`;
      tellPosition(g.conn, g.surface);
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
    if (g.edges & 5) tellPosition(g.conn, g.surface);
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

  // the grab's release (its input grab ended; input enters the pointer
  // into the surface under it next)
  function endGrab(g: Grab) {
    grab = null;
    document.body.style.cursor = '';
    if (g.mode === 'resize') engine.requestResize(g.conn, g.surface, g.lastW, g.lastH);
  }

  // Alt+drag anywhere on a window moves it; purely DOM-side (not a
  // fullscreen window: it fills the container). The embedder's
  // `interactive` may take it instead (then the press goes on its way:
  // its frame sees it, and input forwards it unless the embedder grabbed)
  let alt: PointerGrab | null = null;
  function altDrag(ev: PointerEvent, win: ViewWindow) {
    if (options.interactive?.({ type: 'alt-drag', conn: win.conn, surface: win.surface }, held.get(ev.pointerId) ?? pressOf(ev))) {
      ev.preventDefault();
      return;
    }
    if (win.fullscreen) return;
    ev.preventDefault();
    ev.stopPropagation();
    view.raise(win.conn, win.surface);
    const el = win.element;
    const startX = ev.clientX, startY = ev.clientY;
    const startL = el.offsetLeft, startT = el.offsetTop;
    const id = ev.pointerId;
    const onMove = (mv: PointerEvent) => {
      if (mv.pointerId !== id) return;
      // clamp so a grabbable corner always stays inside the container
      const l = Math.min(Math.max(startL + mv.clientX - startX, 40 - el.offsetWidth), container.clientWidth - 40);
      const t = Math.min(Math.max(startT + mv.clientY - startY, 0), container.clientHeight - 24);
      el.style.left = `${l}px`;
      el.style.top = `${t}px`;
      tellPosition(win.conn, win.surface);
    };
    // ends with its input grab: at the release (seen or not), a cancel, or
    // the capture lost any other way (otherwise hovering the window would go
    // on moving it), the blur
    const hold: PointerGrab = alt = input.grab(id, { onEnd() {
      if (alt === hold) alt = null;
      el.removeEventListener('pointermove', onMove);
      try { if (el.hasPointerCapture(id)) el.releasePointerCapture(id); } catch { /* gone */ }
    } });
    if (!hold.active) return;
    el.setPointerCapture(id);
    el.addEventListener('pointermove', onMove);
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
    tellPosition(conn, surface);
  }
  function unsnap(conn: number, surface: number) {
    const win = view.window(conn, surface);
    if (!win) return;
    const pos = restore.get(win.key);
    restore.delete(win.key);
    if (pos) { win.element.style.left = pos.left; win.element.style.top = pos.top; }
    tellPosition(conn, surface);
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

  // the pointer a grab or drag starting now follows: the last one pressed
  // (still held: beginGrab and drag-start check held)
  const grabPointer = () => (held.has(lastPressed) ? lastPressed : held.keys().next().value ?? -1);
  const ours = (ev: PointerEvent) => {
    const p = grab ? grab.pointer : dnd ? dnd.pointer : null;
    return p !== null && ev.pointerId === p;
  };

  // --- dnd: like a grab, but the compositor drives the session and closes
  // it ('drag-end'): drops, cancels and app deaths all funnel through that.
  // Its input grab ending is the drop (its pointer's pointerup) or a cancel
  // (anything else: a release the page didn't see, a pointercancel, the
  // blur); input then enters the pointer into the surface under it — after
  // the drop, which ends the core's drag (it drops pointer enters till then)
  function dndEnd(d: Dnd, reason: GrabEndReason, ev?: PointerEvent) {
    if (dnd !== d) return; // over already ('drag-end')
    if (reason === 'release' && ev?.type === 'pointerup') {
      // final position, then the drop; the compositor answers with
      // 'drag-end' whether it lands or cancels
      const t = dndTarget(ev.clientX, ev.clientY);
      engine.dragMotion(t.conn, t.surface, now(), t.x, t.y);
      engine.dragDrop();
    } else engine.dragCancel();
  }
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

  // While a grab or drag is on, only its own pointer moves it; the others'
  // events are left alone (and don't move lastPointer, the grab's
  // position). Its own pointer's release, cancel, or a move that shows no
  // button down ended it already: input's grab listeners run first (input
  // is created before this module), and its release is not forwarded.
  on('pointermove', (ev) => {
    if (ev.buttons === 0) held.delete(ev.pointerId); // its release went unseen
    if ((grab || dnd) && !ours(ev)) return;
    lastPointer = { x: ev.clientX, y: ev.clientY };
    if (dnd) dndMove(ev);
    else if (grab) grabMove(ev);
  }, true);

  on('pointercancel', (ev) => { held.delete(ev.pointerId); }, true);

  on('pointerup', (ev) => {
    held.delete(ev.pointerId);
    persistSoon(); // a move, a raise
  }, true);

  on('pointerdown', (ev) => {
    // a grab starts from here: a touch has no hover moves before its press,
    // so without this lastPointer is where the previous touch ended
    if (!grab && !dnd) lastPointer = { x: ev.clientX, y: ev.clientY };
    held.set(ev.pointerId, pressOf(ev));
    lastPressed = ev.pointerId;
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
    if (altDragOn && ev.altKey && !grab && !dnd && !alt) {
      const s = view.surfaceOf(ev.target);
      const win = s && view.window(s.conn, s.root);
      if (win) altDrag(ev, win);
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
    const bind = keysOn && ev.altKey && !ev.ctrlKey && !ev.metaKey && !ev.shiftKey
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
      case 'move': case 'resize': beginGrab(ev); break;
      case 'maximize':
        stateOf(ev.conn, ev.surface).maximized = ev.maximized;
        place(ev.conn, ev.surface);
        persistSoon();
        break;
      case 'fullscreen': {
        const st = stateOf(ev.conn, ev.surface);
        st.fullscreen = ev.fullscreen;
        place(ev.conn, ev.surface);
        // it covers the container: on top, and the keyboard's (once mapped:
        // an app may ask before its first commit; autoFocus)
        if (ev.fullscreen && !st.minimized && view.window(ev.conn, ev.surface)) {
          view.raise(ev.conn, ev.surface);
          if (input.autoFocus) input.focus(ev.conn, ev.surface);
        }
        if (grab && grab.conn === ev.conn && grab.surface === ev.surface) cancelGrab();
        syncBrowserFs();
        persistSoon();
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
          if (input.autoFocus) input.focus(ev.conn, ev.surface);
        }
        syncBrowserFs();
        persistSoon();
        break;
      }
      case 'commit':
        // enforced per commit too: apps can START maximized or fullscreen
        // (saved session state) before their window existed for the event
        if (ev.role === ROLE_TOPLEVEL) {
          if (sid) { const w = view.window(ev.conn, ev.surface); if (w) placeSaved(w); } // (before the snap below)
          const st = stateOf(ev.conn, ev.surface);
          const was = st.fullscreen;
          st.maximized = ev.maximized;
          st.fullscreen = ev.fullscreen;
          st.minimized = ev.minimized;
          if (ev.maximized || ev.fullscreen) snap(ev.conn, ev.surface);
          if (ev.fullscreen && !was) { view.raise(ev.conn, ev.surface); syncBrowserFs(); }
          tellPosition(ev.conn, ev.surface); // (the mount placed it; told once)
        } else if (ev.role === ROLE_POPUP) popups.set(keyOf(ev.conn, ev.surface), { conn: ev.conn, surface: ev.surface });
        else if (ev.role === ROLE_DND_ICON) placeIcon();
        break;
      case 'surface':
        if (ev.role === ROLE_DND_ICON) placeIcon();
        else if (ev.role !== ROLE_POPUP) popups.delete(keyOf(ev.conn, ev.surface));
        // an unmapped toplevel's states went with its xdg_toplevel (and the
        // position the core had)
        if (ev.role !== ROLE_TOPLEVEL) told.delete(keyOf(ev.conn, ev.surface));
        if (ev.role !== ROLE_TOPLEVEL && states.delete(keyOf(ev.conn, ev.surface))) syncBrowserFs();
        break;
      case 'destroy':
        // (a closing link's apps live on in the relay: session() null then)
        if (sid && engine.session()) dropPlaces((k) => k === placeKey(ev.conn, ev.surface));
        popups.delete(keyOf(ev.conn, ev.surface));
        restore.delete(keyOf(ev.conn, ev.surface));
        told.delete(keyOf(ev.conn, ev.surface));
        if (states.delete(keyOf(ev.conn, ev.surface))) syncBrowserFs();
        break;
      case 'disconnect':
        if (sid && engine.session()) dropPlaces((k) => k.startsWith(`${PLACE_PREFIX}${sid}:${ev.conn}:`));
        for (const [key, p] of popups) if (p.conn === ev.conn) popups.delete(key);
        for (const key of restore.keys()) if (key.startsWith(`c${ev.conn}s`)) restore.delete(key);
        for (const key of told.keys()) if (key.startsWith(`c${ev.conn}s`)) told.delete(key);
        for (const [key, s] of states) if (s.conn === ev.conn) states.delete(key);
        syncBrowserFs();
        if (grab && grab.conn === ev.conn) cancelGrab();
        break;
      case 'drag-start':
        // an unanswered drag wedges the seat (the core drops pointer input
        // while it lasts): one asked for after the release is cancelled
        if (!held.size && !dnd && !grab) { engine.dragCancel(); break; }
        if (dnd || grab) break;
        {
          const d: Dnd = { conn: ev.conn, icon: ev.icon, queued: false, last: null, pointer: grabPointer() };
          d.hold = input.grab(d.pointer, { onEnd: (reason, pev) => dndEnd(d, reason, pev) });
          if (!d.hold.active) { engine.dragCancel(); break; } // (input saw the release go by)
          engine.pointerLeave(ev.conn); // the drag grab steals the pointer
          dnd = d;
        }
        placeIcon();
        document.body.style.cursor = 'grabbing';
        break;
      case 'drag-end': {
        const d = dnd;
        dnd = null;
        d?.hold?.end();
        document.body.style.cursor = '';
        break;
      }
      case 'synced': synced(); break;
      case 'open': told.clear(); break; // a fresh compositor
      case 'close': sid = null; told.clear(); break; // (the next link's 'synced' says again)
    }
  }

  // a grab whose window went away or can't move any more: over, with no
  // final resize (input still enters the pointer into what is under it)
  function cancelGrab() {
    const g = grab;
    grab = null;
    document.body.style.cursor = '';
    g?.hold.end();
  }

  return {
    handle,
    setFullscreen: (conn, surface, on) => engine.setFullscreen(conn, surface, on),
    setMaximized: (conn, surface, on) => engine.setMaximized(conn, surface, on),
    minimize: (conn, surface) => engine.setMinimized(conn, surface, true),
    restore: (conn, surface) => engine.setMinimized(conn, surface, false),
    // DOM only: a grab or drag in progress just ends (the engine is not
    // told, but its input grab is let go: input enters the pointer); the
    // browser's fullscreen, if it was ours, is left
    dispose() {
      for (const [type, fn, opts] of listening.splice(0)) document.removeEventListener(type, fn, opts);
      if (typeof window !== 'undefined' && typeof window.removeEventListener === 'function') {
        window.removeEventListener('blur', onBlur);
        window.removeEventListener('pagehide', onPageHide);
      }
      sid = null;
      clearTimeout(persistTimer);
      persistTimer = undefined;
      held.clear();
      if (grab || dnd) document.body.style.cursor = '';
      const holds = [grab?.hold, dnd?.hold, alt];
      grab = null;
      dnd = null;
      for (const h of holds) h?.end();
      popups.clear();
      restore.clear();
      states.clear();
      told.clear();
      if (browserFs.ours && document.fullscreenElement === container) document.exitFullscreen().catch(() => {});
      browserFs.ours = browserFs.wanted = browserFs.requested = false;
    },
  };
}
