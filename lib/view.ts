// wland view: engine events → canvases. One canvas per surface, grouped into
// one window element per toplevel (the window geometry's box; the toplevel,
// subsurfaces and popups are positioned inside it), painted by the
// presenters in present.ts, stacked and placed. The DOM does the pointer
// picking: a surface canvas is its own hit target, unless the surface set an
// input region — then the canvas is inert and a transparent hit element over
// it, clipped to the region, takes the pointer (outside it events fall
// through to whatever is below: a GTK shadow no longer swallows clicks). The
// window element itself takes no pointer (`pointer-events: none`; canvases
// and hit elements say `auto`), so a hole in a region inside the geometry
// lets the click through to the window or page behind — except a fullscreen
// window's black backdrop, which covers what is below.
//
// Pointer images ('cursor' events) are CSS on the client's window elements:
// a named shape as is, a cursor surface's buffer as `cursor: image-set(url(
// data:…) Nx) hx hy` — the browser draws it, so it never lags the pointer.
// Browsers refuse cursor images above 128 CSS px (and image-set may be
// missing): then the cursor canvas itself follows the pointer instead
// (`cursor: none`, input-inert), a frame behind. So it is under Pointer
// Lock, which hides the pointer whatever CSS says: the locked client's
// cursor surface stays drawn where the lock froze the pointer.
//
// Window states come from the core ('maximize' / 'fullscreen' / 'minimize'
// events, and every commit's flags): a minimized window's element is hidden
// (display: none); a fullscreen one fills its parent (`inset: 0`, black,
// clipping) with the window geometry centred in it — the spec's border fill
// around a smaller buffer — and carries `data-wland-fullscreen` so page CSS
// can drop whatever it dresses windows in (shadows). Positions stay the
// window manager's (wm.ts puts maximized and fullscreen windows at 0,0).
//
// The view only consumes events (handle) and never calls the engine, so the
// engine may live on another thread. Where window elements go is the
// embedder's call: by default they are cascaded inside `container`, or pass
// `mount`/`unmount` to host each one in your own window frame. The types
// below are the contract.

import type { CommitEvent, Engine, Event, Role } from './engine.ts';
import { make2DPresenter, makeGLPresenter, probeWebGL, type Pixels, type Presenter } from './present.ts';

export interface ViewWindow {
  /** `c<conn>s<surface>`, also the element's data-wland-window. */
  key: string;
  conn: number;
  /** The toplevel surface. */
  surface: number;
  /** The window element (class `wland-window`): the window's box. The view
   *  sizes it to the window geometry (CommitEvent.geometry) and positions
   *  the surface canvases inside it, in a child element at the toplevel
   *  surface's origin; what lies outside the geometry (shadows) overflows.
   *  It is `pointer-events: none` (but while fullscreen: its backdrop takes
   *  the press); its canvases and hit elements set `auto` explicitly, so
   *  anything an embedder adds inside it takes no pointer unless it does. */
  element: HTMLElement;
  title: string;
  /** Window states as of the last event or commit (CommitEvent.maximized,
   *  .fullscreen, .minimized). A minimized window is hidden but still
   *  listed (a taskbar restores it). */
  maximized: boolean;
  fullscreen: boolean;
  minimized: boolean;
}

export interface ViewOptions {
  /** Default home of window elements; dnd icons are always placed here. */
  container: HTMLElement;
  /** Put a new window's element in the page. Default: cascade it inside
   *  `container` (absolute left/top), stack it on top, raise it on
   *  pointerdown. Supply this to host windows in your own window frames. */
  mount?(win: ViewWindow): void;
  /** Take a window's element out of the page. Default: element.remove(). */
  unmount?(win: ViewWindow): void;
  /** Window list changed: a window came or went, a title or role changed. */
  onWindowsChange?(): void;
  /** WebGL present for toplevels: 'auto' (only on hardware-accelerated
   *  WebGL), 'always', or 'never'. Default 'auto'. */
  webgl?: 'auto' | 'always' | 'never';
  log?(line: string): void;
}

/** What view.surfaceOf reports for a surface canvas. */
export interface SurfaceRef {
  conn: number;
  surface: number;
  root: number;
  role: Role;
}

export interface View {
  readonly stats: Readonly<{ webgl: number; canvas2d: number }>;
  /** Whether new toplevels get a WebGL presenter (false for 2D-only, and
   *  from the first context loss on). Every other surface is 2D. */
  readonly webgl: boolean;
  /** Feed every engine event, view first: commit pixels are only valid
   *  during dispatch. */
  handle(event: Event): void;
  /** Mapped toplevel windows, in creation order. */
  windows(): ViewWindow[];
  /** The window whose toplevel is (conn, surface). */
  window(conn: number, surface: number): ViewWindow | undefined;
  canvas(conn: number, surface: number): HTMLCanvasElement | undefined;
  /** The surface an element (event target) is the canvas or the hit
   *  element of (the input region's: see 'input-region'), or null. Hit
   *  elements share their canvas's box, so surface-local coordinates are
   *  measured the same way on both. */
  surfaceOf(element: Element | EventTarget | null | undefined): SurfaceRef | null;
  /** The element taking a surface's pointer input: its input region's hit
   *  element, else its canvas (where a pointer lock goes). */
  hitTarget(conn: number, surface: number): HTMLElement | undefined;
  /** The surface under a viewport point, with surface-local coordinates. */
  surfaceAt(clientX: number, clientY: number): { conn: number; surface: number; x: number; y: number } | null;
  /** Stack a window on top. */
  raise(conn: number, surface: number): void;
  /** The surface's current pixels (GL readback rows are bottom-up), or null
   *  before its first commit. */
  readPixels(conn: number, surface: number): Pixels | null;
  /** Unmount every window and drop every canvas and presenter (WebGL
   *  contexts included), and remove its document listeners (pointermove/
   *  pointerdown: the pointer position, for a cursor image drawn as an
   *  element; pointerlockchange). */
  dispose(): void;
}

const ROLE_NONE = 0, ROLE_TOPLEVEL = 1, ROLE_SUBSURFACE = 2, ROLE_CURSOR = 3, ROLE_POPUP = 4, ROLE_DND_ICON = 5;

const keyOf = (conn: number, surface: number) => `c${conn}s${surface}`;

/** A window element per toplevel (title lives in `titles`). `origin` is the
 *  toplevel surface's origin inside it: the canvases' parent, offset by the
 *  window geometry's position. `g` is the last box laid out (the geometry,
 *  or the toplevel's size while none is known; w 0 = nothing yet). */
interface Win {
  key: string; conn: number; surface: number; element: HTMLElement; origin: HTMLElement;
  g: { x: number; y: number; w: number; h: number };
  maximized: boolean; fullscreen: boolean; minimized: boolean;
}
/** A surface and its canvas. `region` is its input region (null: the whole
 *  surface; the canvas is the hit target), `hit` the element standing in
 *  for the canvas as hit target while there is one. */
interface Surface {
  key: string; conn: number; surface: number; role: Role; root: number;
  canvas: HTMLCanvasElement; presenter: Presenter | null; force2d: boolean; focusable: boolean;
  region: Int32Array | null; hit: HTMLElement | null;
  /** Presents so far and the last one's logical size (cursor images). */
  frames: number; lw: number; lh: number;
  /** The canvas as a PNG data URL, as of present number `urlFrame`. */
  url: string; urlFrame: number;
}
/** A client's pointer image: `css` is what its window elements show;
 *  `surface` the cursor surface (0: a shape, hidden or default) with its
 *  hotspot; `image`/`prev` the last two image entries (see cursorCss). */
interface Cursor { css: string; surface: number; hx: number; hy: number; image: string; prev: string }

/** Browsers' cap on a CSS cursor image, CSS px a side (Chromium and Firefox
 *  ignore larger ones); above it the image is drawn as an element. */
const CURSOR_MAX = 128;

// image-set() for a hi-dpi cursor image: the unprefixed or the -webkit-
// spelling, '' when neither parses (then only a 1:1 image goes to CSS)
function imageSetFn(): string {
  const css = (globalThis as { CSS?: { supports?(p: string, v: string): boolean } }).CSS;
  if (!css || typeof css.supports !== 'function') return '';
  for (const fn of ['image-set', '-webkit-image-set']) {
    if (css.supports('cursor', `${fn}(url("data:,") 1x) 0 0, default`)) return fn;
  }
  return '';
}

export function createView(options: ViewOptions): View {
  const { container } = options;
  if (!container) throw new Error('createView: options.container is required');
  const log = options.log || (() => {});
  const onWindowsChange = options.onWindowsChange || (() => {});
  const mode = options.webgl || 'auto';
  // probe now, while the page is calm (no apps, a tiny off-DOM canvas) —
  // never lazily during an app's first large present
  let useGL = mode === 'always' || (mode === 'auto' && probeWebGL(log));

  const surfaces = new Map<string, Surface>(); // key → record
  const byCanvas = new WeakMap<object, Surface>(); // canvas or hit element → record
  const windows = new Map<string, Win>(); // root key → window
  const titles = new Map<string, string>(); // toplevel key → title (titles can precede the window)
  const cursors = new Map<number, Cursor>(); // conn → its pointer image
  const imageSet = imageSetFn();
  let overlay: { s: Surface; hx: number; hy: number } | null = null; // the cursor canvas following the pointer
  const pointer = { x: 0, y: 0 }; // last viewport position (the overlay's anchor)
  const track = (ev: PointerEvent) => {
    pointer.x = ev.clientX;
    pointer.y = ev.clientY;
    if (overlay) moveOverlay();
  };
  document.addEventListener('pointermove', track, { capture: true, passive: true });
  document.addEventListener('pointerdown', track, { capture: true, passive: true });
  // Under Pointer Lock the browser hides the pointer whatever CSS says: the
  // locked client's cursor surface is drawn as the element instead, where
  // the lock froze the pointer (clientX/Y stop moving under a lock)
  let lockedConn = -1;
  const lockChange = () => {
    const el = document.pointerLockElement;
    const s = el ? byCanvas.get(el) : undefined;
    const conn = s ? s.conn : -1;
    if (conn === lockedConn) return;
    const was = lockedConn;
    lockedConn = conn;
    if (was >= 0) showCursor(was);
    if (conn >= 0) showCursor(conn);
  };
  document.addEventListener('pointerlockchange', lockChange);
  const stats = { webgl: 0, canvas2d: 0 };
  let zTop = 100;
  let placed = 0;

  function raiseWindow(win: { element: HTMLElement }) {
    win.element.style.zIndex = String(++zTop);
  }

  // default placement: cascade inside the container; 48px top headroom keeps
  // what an app draws above its window geometry on-screen
  const mount = options.mount || ((win: ViewWindow) => {
    const el = win.element;
    el.style.left = `${24 + (placed % 8) * 40}px`;
    el.style.top = `${48 + (placed % 6) * 36}px`;
    placed++;
    raiseWindow(win);
    el.addEventListener('pointerdown', () => raiseWindow(win), true);
    container.appendChild(el);
  });
  const unmount = options.unmount || ((win: ViewWindow) => win.element.remove());

  function windowFor(conn: number, root: number): Win {
    const key = keyOf(conn, root);
    let win = windows.get(key);
    if (!win) {
      const element = document.createElement('div');
      element.className = 'wland-window';
      element.dataset.wlandWindow = key;
      element.style.position = 'absolute';
      element.style.overflow = 'visible';
      // not a hit target: where no surface takes the pointer (a hole in an
      // input region) it goes to what is behind; canvases and hit elements
      // set `auto` (pointer-events is inherited)
      element.style.pointerEvents = 'none';
      const origin = document.createElement('div');
      origin.style.position = 'absolute';
      origin.style.left = '0px';
      origin.style.top = '0px';
      element.appendChild(origin);
      const cursor = cursors.get(conn);
      if (cursor) element.style.cursor = cursor.css;
      win = { key, conn, surface: root, element, origin, g: { x: 0, y: 0, w: 0, h: 0 },
        maximized: false, fullscreen: false, minimized: false };
      windows.set(key, win);
      mount(publicWindow(win));
      onWindowsChange();
    }
    return win;
  }

  function dropWindow(key: string) {
    const win = windows.get(key);
    if (!win) return;
    windows.delete(key);
    unmount(publicWindow(win));
  }

  function recordFor(conn: number, surface: number): Surface {
    const key = keyOf(conn, surface);
    let s = surfaces.get(key);
    if (!s) {
      s = { key, conn, surface, role: ROLE_NONE, root: surface, canvas: newCanvas(key),
            presenter: null, force2d: false, focusable: false, region: null, hit: null,
            frames: 0, lw: 0, lh: 0, url: '', urlFrame: 0 };
      surfaces.set(key, s);
      byCanvas.set(s.canvas, s);
    }
    return s;
  }

  function newCanvas(key: string): HTMLCanvasElement {
    const canvas = document.createElement('canvas');
    canvas.dataset.wland = key;
    canvas.style.display = 'none';
    canvas.style.outline = 'none';
    return canvas;
  }

  function dropSurface(s: Surface) {
    if (overlay && overlay.s === s) overlay = null;
    try { if (s.presenter) s.presenter.dispose(); } catch { /* */ }
    s.canvas.remove();
    if (s.hit) s.hit.remove();
    surfaces.delete(s.key);
    dropWindow(s.key);
    titles.delete(s.key);
  }

  // dnd icons live in the container itself (no window), fixed, input-inert;
  // the window manager pins them to the pointer
  function layoutIcon(s: Surface) {
    const st = s.canvas.style;
    if (s.canvas.parentElement !== container) container.appendChild(s.canvas);
    st.display = 'block';
    st.position = 'fixed';
    st.pointerEvents = 'none';
    st.zIndex = '30';
  }

  // The window's box is its geometry: the element takes its size, and the
  // surface origin sits at minus its position (a titlebar subsurface above
  // the toplevel is inside the box, a shadow margin outside). Any commit in
  // the window can change it. Until the core knows one, the box is the
  // toplevel's.
  function box(win: Win, ev: CommitEvent) {
    const g = ev.geometry;
    const known = g.width > 0 && g.height > 0;
    if (!known && ev.role !== ROLE_TOPLEVEL) return;
    win.g = known ? { x: g.x, y: g.y, w: g.width, h: g.height } : { x: 0, y: 0, w: ev.logicalWidth, h: ev.logicalHeight };
    applyBox(win);
  }

  // The element's box and the origin inside it, from win.g and the states.
  // Fullscreen: the element fills its parent, black and clipping, and the
  // geometry sits centred in it (calc: no layout read per commit).
  function applyBox(win: Win) {
    const st = win.element.style, ost = win.origin.style, { x, y, w, h } = win.g;
    const fs = win.fullscreen;
    const set = (style: CSSStyleDeclaration, k: 'width' | 'height' | 'left' | 'top' | 'background' | 'overflow' | 'pointerEvents', v: string) => {
      if (style[k] !== v) style[k] = v;
    };
    set(st, 'width', fs ? '100%' : `${w}px`);
    set(st, 'height', fs ? '100%' : `${h}px`);
    set(st, 'background', fs ? '#000' : '');
    set(st, 'overflow', fs ? 'hidden' : 'visible');
    set(st, 'pointerEvents', fs ? 'auto' : 'none'); // the backdrop covers what is below
    set(ost, 'left', fs ? `calc(50% - ${w / 2 + x}px)` : `${-x}px`);
    set(ost, 'top', fs ? `calc(50% - ${h / 2 + y}px)` : `${-y}px`);
    if (fs) win.element.dataset.wlandFullscreen = '';
    else delete win.element.dataset.wlandFullscreen;
  }

  // a window state changed ('maximize' / 'fullscreen' / 'minimize' events,
  // or a commit's flags)
  function setStates(win: Win, maximized: boolean, fullscreen: boolean, minimized: boolean) {
    if (win.maximized === maximized && win.fullscreen === fullscreen && win.minimized === minimized) return;
    if (win.minimized !== minimized) win.element.style.display = minimized ? 'none' : '';
    win.maximized = maximized;
    win.fullscreen = fullscreen;
    win.minimized = minimized;
    applyBox(win);
    onWindowsChange();
  }

  // Place and style a surface's canvas for a commit. Sizes: the backing
  // store is buffer px; the CSS box is surface-local (logical) px, which is
  // also what pointer coordinates are measured in. role/geometry can change
  // after creation, so this runs per commit. Returns true for a toplevel's
  // first commit: its canvas is to take keyboard focus once presented.
  function layout(s: Surface, ev: CommitEvent): boolean {
    const { canvas } = s;
    const st = canvas.style;
    const cssW = `${ev.logicalWidth}px`, cssH = `${ev.logicalHeight}px`;
    if (st.width !== cssW) st.width = cssW;
    if (st.height !== cssH) st.height = cssH;
    if (canvas.width !== ev.width) canvas.width = ev.width;
    if (canvas.height !== ev.height) canvas.height = ev.height;

    switch (ev.role) {
      case ROLE_TOPLEVEL: {
        const win = windowFor(s.conn, s.root);
        if (canvas.parentElement !== win.origin) win.origin.appendChild(canvas);
        st.display = 'block';
        st.position = 'absolute';
        st.left = '0px';
        st.top = '0px';
        win.element.style.display = win.minimized ? 'none' : '';
        box(win, ev);
        if (!s.focusable) {
          s.focusable = true;
          canvas.tabIndex = 0;
          return true;
        }
        break;
      }
      case ROLE_SUBSURFACE:
      case ROLE_POPUP: {
        // CSD decorations / popups: absolute from the root surface's origin
        const win = windowFor(s.conn, s.root);
        if (canvas.parentElement !== win.origin) win.origin.appendChild(canvas);
        st.display = 'block';
        st.position = 'absolute';
        st.left = `${ev.x}px`;
        st.top = `${ev.y}px`;
        st.zIndex = ev.role === ROLE_POPUP ? '20' : '10';
        box(win, ev);
        break;
      }
      case ROLE_DND_ICON:
        layoutIcon(s);
        break;
      default:
        // no role yet, or a cursor image: not shown in place (a cursor image
        // is CSS on its client's windows, or the overlay: showCursor)
        if (!overlay || overlay.s !== s) st.display = 'none';
    }
    return false;
  }

  // The input region as hit target. With none (the whole surface) the
  // canvas takes the pointer itself. With one, the canvas is inert and a
  // transparent element with the canvas's box, clipped to the region
  // (clip-path clips hit-testing too), sits right after it — same stacking.
  // Only for the roles that take input; a cursor or dnd icon has none (and
  // its canvas stays inert). pointer-events is spelled out on both, never
  // '': the window element they inherit from is `none`.
  function applyRegion(s: Surface) {
    const { canvas } = s;
    const takesInput = s.role === ROLE_TOPLEVEL || s.role === ROLE_SUBSURFACE || s.role === ROLE_POPUP;
    const own = takesInput && !s.region ? 'auto' : 'none'; // the canvas as its own hit target
    if (canvas.style.pointerEvents !== own) canvas.style.pointerEvents = own;
    if (!s.region || !takesInput) {
      if (s.hit) {
        s.hit.remove();
        byCanvas.delete(s.hit);
        s.hit = null;
      }
      return;
    }
    let hit = s.hit;
    if (!hit) {
      hit = document.createElement('div');
      hit.dataset.wlandHit = s.key;
      hit.style.position = 'absolute';
      hit.style.pointerEvents = 'auto';
      s.hit = hit;
      byCanvas.set(hit, s);
    }
    if (canvas.parentElement && hit.previousSibling !== canvas) canvas.after(hit);
    const cs = canvas.style, hs = hit.style;
    const w = parseFloat(cs.width) || 0, h = parseFloat(cs.height) || 0;
    const clip = regionPath(s.region, w, h);
    const display = cs.display === 'none' || !clip ? 'none' : 'block';
    for (const [k, v] of [['left', cs.left], ['top', cs.top], ['width', cs.width], ['height', cs.height],
                          ['zIndex', cs.zIndex], ['display', display], ['clipPath', clip || '']] as const) {
      if (hs[k] !== v) hs[k] = v;
    }
  }

  // --- pointer images ------------------------------------------------------

  function setCursorCss(conn: number, css: string) {
    const c = cursors.get(conn);
    if (c) c.css = css;
    for (const win of windows.values()) {
      if (win.conn === conn && win.element.style.cursor !== css) win.element.style.cursor = css;
    }
  }

  // The cursor surface's image as a CSS cursor value, or null when CSS
  // can't show it as the client meant (too big, a hotspot outside it —
  // browsers ignore or move those —, a non-uniform scale, a hi-dpi image
  // without image-set). The hotspot is in CSS px, the image-set resolution
  // is buffer px per logical px (buffer scale, or a viewport). The previous
  // image stays in the list as the fallback while the browser decodes the
  // new one (an image not loaded yet is skipped — no default-arrow flicker
  // between the frames of an animated cursor), then 'default' (Chromium
  // also skips an image not wholly inside the viewport: at the page edges).
  function cursorCss(s: Surface, c: Cursor): string | null {
    const { canvas, lw, lh } = s;
    if (!(lw > 0 && lh > 0) || lw > CURSOR_MAX || lh > CURSOR_MAX) return null;
    if (c.hx < 0 || c.hy < 0 || c.hx >= lw || c.hy >= lh) return null;
    const sx = canvas.width / lw, sy = canvas.height / lh;
    if (Math.abs(sx - sy) > 0.01 || (!imageSet && sx !== 1)) return null;
    if (s.urlFrame !== s.frames) {
      try { s.url = canvas.toDataURL('image/png'); } catch { return null; }
      s.urlFrame = s.frames;
    }
    const image = imageSet ? `${imageSet}(url("${s.url}") ${+sx.toFixed(4)}x)` : `url("${s.url}")`;
    const entry = `${image} ${c.hx} ${c.hy}`;
    if (entry !== c.image) { c.prev = c.image; c.image = entry; }
    return c.prev ? `${entry}, ${c.prev}, default` : `${entry}, default`;
  }

  // Show conn's cursor surface (after its 'cursor' event, and after each of
  // its commits): CSS, else the overlay. Before its first present there is
  // nothing to show; the windows keep their cursor until it comes.
  function showCursor(conn: number) {
    const c = cursors.get(conn);
    const s = c && c.surface ? surfaces.get(keyOf(conn, c.surface)) : undefined;
    if (!c || !s || !s.frames) return;
    const css = conn === lockedConn ? null : cursorCss(s, c);
    if (css !== null) {
      dropOverlay(conn);
      setCursorCss(conn, css);
      return;
    }
    c.image = c.prev = '';
    setCursorCss(conn, 'none');
    if (overlay && overlay.s !== s) overlay.s.canvas.style.display = 'none';
    overlay = { s, hx: c.hx, hy: c.hy };
    const st = s.canvas.style;
    if (s.canvas.parentElement !== container) container.appendChild(s.canvas);
    st.position = 'fixed';
    st.pointerEvents = 'none';
    st.zIndex = '2147483647';
    st.display = 'block';
    moveOverlay();
  }

  function moveOverlay() {
    const { s, hx, hy } = overlay!;
    s.canvas.style.left = `${pointer.x - hx}px`;
    s.canvas.style.top = `${pointer.y - hy}px`;
  }

  function dropOverlay(conn: number) {
    if (!overlay || overlay.s.conn !== conn) return;
    overlay.s.canvas.style.display = 'none';
    overlay = null;
  }

  function presenterFor(s: Surface): Presenter {
    if (s.presenter) return s.presenter;
    // GL only for toplevels. A surface still role-less at its first commit
    // (a cursor buffer before set_cursor) never becomes a toplevel — xdg
    // forbids a buffer before the first configure — so caching 2d is safe.
    let p = null;
    if (s.role === ROLE_TOPLEVEL && useGL && !s.force2d) {
      p = makeGLPresenter(s.canvas, log, () => downgrade(s));
      if (p) { stats.webgl++; log(`present: ${s.key} → ${p.kind}`); }
    }
    if (!p) { p = make2DPresenter(s.canvas); stats.canvas2d++; }
    s.presenter = p;
    return p;
  }

  // WebGL context lost: stop making GL contexts and swap this canvas for a
  // fresh 2d one in place (a GL canvas can't get a 2d context). It starts
  // blank and repaints as the app damages it.
  function downgrade(s: Surface) {
    useGL = false;
    log(`webgl context lost on ${s.key} — falling back to 2d`);
    try { s.presenter?.dispose(); } catch { /* */ }
    const fresh = s.canvas.cloneNode(false) as HTMLCanvasElement; // attrs: data-wland, size, style, tabindex
    s.canvas.replaceWith(fresh);
    byCanvas.delete(s.canvas);
    s.canvas = fresh;
    byCanvas.set(fresh, s);
    s.presenter = null;
    s.force2d = true;
  }

  function handle(ev: Event) {
    switch (ev.type) {
      case 'commit': {
        const s = recordFor(ev.conn, ev.surface);
        const listed = s.role === ROLE_TOPLEVEL;
        s.role = ev.role;
        s.root = ev.root;
        const mapped = layout(s, ev);
        // windows() lists a window once its root is a toplevel: a window made
        // by its decorations' commits (subsurfaces, foot's order) shows up
        // only at the toplevel's own first commit
        if (listed !== (ev.role === ROLE_TOPLEVEL)) onWindowsChange();
        // the window's states as of this commit (an app may map in them,
        // before its window existed for the event)
        const w = windows.get(keyOf(ev.conn, ev.root));
        if (w && (ev.role === ROLE_TOPLEVEL || ev.role === ROLE_SUBSURFACE || ev.role === ROLE_POPUP)) {
          setStates(w, ev.maximized, ev.fullscreen, ev.minimized);
        }
        presenterFor(s).present(ev);
        s.frames++;
        s.lw = ev.logicalWidth;
        s.lh = ev.logicalHeight;
        applyRegion(s); // the hit element follows the canvas's box
        // a new frame of a client's pointer image (animated cursors)
        const cursor = cursors.get(ev.conn);
        if (cursor && cursor.surface === ev.surface) showCursor(ev.conn);
        // a new toplevel takes keyboard focus, AFTER presenting: input
        // listens for focusin and calls the engine, which can detach a
        // wasm-backed ev.pixels (engine.ts, pixel lifetime)
        if (mapped) s.canvas.focus({ preventScroll: true });
        break;
      }
      case 'input-region': {
        // applied now if the canvas is laid out, else at its first commit
        const s = recordFor(ev.conn, ev.surface);
        s.region = ev.region;
        applyRegion(s);
        break;
      }
      case 'surface': {
        // role learned/changed, possibly after the canvas exists (GTK commits
        // its cursor buffer before set_cursor; dnd icons commit before
        // start_drag; popup roles die while the surface lives on)
        const s = surfaces.get(keyOf(ev.conn, ev.surface));
        if (s) {
          s.role = ev.role;
          s.root = ev.root;
          if (ev.role === ROLE_DND_ICON) layoutIcon(s);
          else if ((ev.role === ROLE_CURSOR || ev.role === ROLE_NONE) && (!overlay || overlay.s !== s)) s.canvas.style.display = 'none';
          applyRegion(s);
        }
        // an unmapped toplevel's window must not linger as an invisible
        // hit target; its next toplevel commit shows it again (its states
        // went with its xdg_toplevel)
        const win = windows.get(keyOf(ev.conn, ev.surface));
        if (win && ev.role !== ROLE_TOPLEVEL) {
          setStates(win, false, false, false);
          win.element.style.display = 'none';
        }
        onWindowsChange();
        break;
      }
      case 'destroy': {
        const key = keyOf(ev.conn, ev.surface);
        const s = surfaces.get(key);
        if (s) dropSurface(s);
        else { dropWindow(key); titles.delete(key); }
        onWindowsChange();
        break;
      }
      case 'disconnect': {
        cursors.delete(ev.conn);
        for (const s of surfaces.values()) if (s.conn === ev.conn) dropSurface(s);
        for (const win of windows.values()) if (win.conn === ev.conn) dropWindow(win.key);
        onWindowsChange();
        break;
      }
      case 'title':
        titles.set(keyOf(ev.conn, ev.surface), ev.title);
        onWindowsChange();
        break;
      case 'maximize':
      case 'fullscreen':
      case 'minimize': {
        const win = windows.get(keyOf(ev.conn, ev.surface));
        if (!win) break;
        setStates(win,
          ev.type === 'maximize' ? ev.maximized : win.maximized,
          ev.type === 'fullscreen' ? ev.fullscreen : win.fullscreen,
          ev.type === 'minimize' ? ev.minimized : win.minimized);
        // (a pointer image the client set went with the core's leave: a
        // 'cursor' reset event)
        break;
      }
      case 'cursor': {
        // per window, so it works wherever the embedder mounted them; '' (the
        // pointer left) lets a window manager's grab cursor show through
        let c = cursors.get(ev.conn);
        if (!c) cursors.set(ev.conn, c = { css: '', surface: 0, hx: 0, hy: 0, image: '', prev: '' });
        c.surface = ev.surface;
        c.hx = ev.hotspotX;
        c.hy = ev.hotspotY;
        if (ev.surface) { showCursor(ev.conn); break; }
        c.image = c.prev = '';
        dropOverlay(ev.conn);
        setCursorCss(ev.conn, ev.cursor);
        break;
      }
    }
  }

  const publicWindow = (win: Win): ViewWindow => ({
    key: win.key, conn: win.conn, surface: win.surface, element: win.element,
    title: titles.get(win.key) || win.key,
    maximized: win.maximized, fullscreen: win.fullscreen, minimized: win.minimized,
  });

  return {
    stats,
    get webgl() { return useGL; },
    handle,
    windows() {
      const out: ViewWindow[] = [];
      for (const win of windows.values()) {
        const root = surfaces.get(win.key);
        if (root && root.role === ROLE_TOPLEVEL) out.push(publicWindow(win));
      }
      return out;
    },
    window(conn, surface) {
      const win = windows.get(keyOf(conn, surface));
      return win ? publicWindow(win) : undefined;
    },
    canvas(conn, surface) {
      const s = surfaces.get(keyOf(conn, surface));
      return s ? s.canvas : undefined;
    },
    surfaceOf(element) {
      const s = element ? byCanvas.get(element) : undefined;
      return s ? { conn: s.conn, surface: s.surface, root: s.root, role: s.role } : null;
    },
    hitTarget(conn, surface) {
      const s = surfaces.get(keyOf(conn, surface));
      return s ? s.hit || s.canvas : undefined;
    },
    surfaceAt(clientX, clientY) {
      // the browser's hit-test: inert canvases and clipped-out hit elements
      // are passed over, so input regions hold here too
      const el = document.elementFromPoint(clientX, clientY);
      const s = el ? byCanvas.get(el) : undefined;
      if (!el || !s) return null;
      const r = el.getBoundingClientRect();
      return { conn: s.conn, surface: s.surface, x: clientX - r.left, y: clientY - r.top };
    },
    raise(conn, surface) {
      const win = windows.get(keyOf(conn, surface));
      if (win) raiseWindow(win);
    },
    readPixels(conn, surface) {
      const s = surfaces.get(keyOf(conn, surface));
      return s && s.presenter ? s.presenter.readback() : null;
    },
    // every window unmounted, every canvas and presenter gone
    dispose() {
      document.removeEventListener('pointermove', track, { capture: true });
      document.removeEventListener('pointerdown', track, { capture: true });
      document.removeEventListener('pointerlockchange', lockChange);
      cursors.clear();
      for (const s of [...surfaces.values()]) dropSurface(s);
      for (const key of [...windows.keys()]) dropWindow(key);
      titles.clear();
      onWindowsChange();
    },
  };
}

/** A CSS clip-path for an input region inside a w × h surface: one closed
 *  subpath per rect, clipped to the surface (the rects are disjoint, so the
 *  default nonzero fill is their union); '' when nothing is left. */
function regionPath(region: Int32Array, w: number, h: number): string {
  let d = '';
  for (let i = 0; i + 3 < region.length; i += 4) {
    const x0 = Math.max(0, region[i]), y0 = Math.max(0, region[i + 1]);
    const x1 = Math.min(w, region[i] + region[i + 2]), y1 = Math.min(h, region[i + 1] + region[i + 3]);
    if (x1 > x0 && y1 > y0) d += `M${x0} ${y0}H${x1}V${y1}H${x0}Z`;
  }
  return d && `path('${d}')`;
}

/**
 * Keep the engine's output in step with the page: `container`'s size
 * (ResizeObserver → setOutput; what maximize fills), tab visibility (→
 * setSuspended) and the device pixel ratio (→ setScale: integer wl_output
 * scale + the fractional preferred scale, tracked live). `scale` pins an
 * integer scale instead of tracking devicePixelRatio. Returns the function
 * that stops watching (observer, listeners).
 */
export function watchOutput(engine: Engine, container: HTMLElement, scale?: number): () => void {
  const sendSize = () => engine.setOutput(container.clientWidth, container.clientHeight);
  const resize = new ResizeObserver(sendSize);
  resize.observe(container);
  sendSize();

  const sendVisibility = () => engine.setSuspended(document.hidden);
  document.addEventListener('visibilitychange', sendVisibility);
  sendVisibility();

  let media: MediaQueryList | null = null; // the armed resolution query
  const stop = () => {
    resize.disconnect();
    document.removeEventListener('visibilitychange', sendVisibility);
    if (media) media.removeEventListener('change', watch);
    media = null;
  };
  if (scale) {
    engine.setScale(scale, scale * 120);
    return stop;
  }
  // a `(resolution: Ndppx)` query flips exactly when dpr leaves its current
  // value (browser zoom, moving the tab across displays); re-arm each time
  const dpr = () => window.devicePixelRatio || 1;
  function watch() {
    engine.setScale(dpr(), dpr() * 120);
    media = matchMedia(`(resolution: ${dpr()}dppx)`);
    media.addEventListener('change', watch, { once: true });
  }
  watch();
  return stop;
}
