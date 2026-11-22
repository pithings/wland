// wland headless: the engine plus a scene with no DOM, for Node scripts,
// tests and bots that drive Wayland apps and look at what they draw.
//
//   import { createHeadless, encodePNG } from 'wland/headless';
//   const hl = await createHeadless({ link: 'ws://localhost:8080/ws' });
//   // … an app connects and maps a window …
//   hl.click(200, 150);
//   hl.type('ls -l\n');
//   await writeFile('shot.png', await encodePNG(hl.screenshot()));
//   hl.dispose();
//
// It is client.ts's composition (view + input + wm) redone on plain numbers:
// per-surface RGBA buffers instead of canvases, window positions and a
// z-order instead of DOM boxes, a hit-tester instead of elementFromPoint,
// method calls instead of pointer and keyboard events. The policy mirrors
// view.ts / input.ts / wm.ts (cascade placement of the window geometry's
// box, click-to-focus-and-raise, focus forgotten silently with its surface
// and handed to the topmost window left, popup dismiss on an outside press,
// maximize snap, fullscreen filling the output centred on black and raised,
// minimized windows hidden and skipped by focus, the Alt+F9/F10/F11
// bindings) so a script sees what a page would show. The types below are
// the contract.
//
// Runtime: no DOM and no Node built-in import (the engine's default wasm
// loading gets node:fs via process.getBuiltinModule, for a file: URL).

import {
  createEngine, createStreamLink, createWsLink, inRegion, readSelectionText, setSelectionText, stackOrder,
  type CommitEvent, type Engine, type Event, type GpuRef, type GpuSource, type HandleSource, type Link, type Role,
  type StreamSource,
} from './engine.ts';
import { swizzleRect } from './present.ts';

export type * from './engine.ts';
export { NO_SELECTION_BRIDGE, readSelectionText, setSelectionText, TEXT_MIMES } from './engine.ts';

export interface HeadlessOptions {
  /** The relay: a Link, a WebSocket URL (`ws://host:port/ws` →
   *  createWsLink; Node ≥ 22 has WebSocket), or a StreamSource for a relay
   *  started with `--link` (→ createStreamLink: a ByteStream, a promise of
   *  one, or an async iterable of them, e.g. a unix-socket server's
   *  connections as `Duplex.toWeb(socket)`). */
  link: Link | string | URL | StreamSource;
  /** EngineOptions.buffers, for a relay running a handle backend. */
  buffers?: HandleSource;
  /** EngineOptions.gpu, for a relay that names GPU resources (COMMIT kind
   *  virtgpu): resolve a GPU buffer to its pixels as an RgbaImage of the
   *  ref's size (row 0 at the top; a different size is cropped, not scaled), copied
   *  into the scene during the commit. Without it a GPU surface is laid out
   *  but stays empty, and in front of `wlandr --dmabuf virtgpu` apps are
   *  offered no linux-dmabuf (they render in software over wl_shm); either
   *  way HeadlessSurface.gpu names the buffer. */
  gpu?: GpuSource<RgbaImage>;
  /** EngineOptions.wasm (default: wland.wasm next to the engine module). */
  wasm?: string | URL | BufferSource | WebAssembly.Module;
  /** Output size in logical px (what maximize and fullscreen fill).
   *  Default 1280×720. */
  width?: number;
  height?: number;
  /** Output scale (wl_output integer scale, clamped 1..4, and the fractional
   *  preferred scale). Default 1. Screenshots are rendered at it. */
  scale?: number;
  /** Frame clock period in ms: engine.tick() on a timer (fires frame
   *  callbacks on stream links, presents what was committed — presentation
   *  feedback, with no vsync flag and refresh 0: a timer drives no display —
   *  ships coalesced motion). 0 = no timer; call tick() yourself
   *  (deterministic tests). Default 16. */
  frameInterval?: number;
  /** A newly mapped toplevel takes keyboard focus, as on a page. Default
   *  true (wl-copy, for one, waits for focus). */
  focusOnMap?: boolean;
  /** A pointer lock an app asks for (zwp_pointer_constraints_v1
   *  lock_pointer) is granted at once, and again at the next press on its
   *  surface after breakLock(), as a page grants it on a user gesture.
   *  false: it waits for grantLock(). Default true. */
  autoLock?: boolean;
  /** keyDown's window bindings, as the page's window manager has them:
   *  Alt+F11 fullscreen, Alt+F10 maximize (toggles), Alt+F9 minimize, on
   *  the focused window, the key swallowed (the Alt reaches the app).
   *  Default true. */
  shortcuts?: boolean;
  /** Screenshot background, RGBA 0..255. Default opaque black. */
  background?: [number, number, number, number];
  /** Every engine event, after the scene took it and BEFORE the window
   *  policy calls back into the engine: a commit's `pixels` is still
   *  readable here. A throwing consumer is reported asynchronously. */
  onEvent?(event: Event): void;
  /** The window list changed: windows, titles, roles, focus, stacking. */
  onWindowsChange?(): void;
}

/** A surface the scene holds (it has committed at least once). */
export interface HeadlessSurface {
  /** `c<conn>s<surface>`. */
  key: string;
  conn: number;
  surface: number;
  role: Role;
  /** The toplevel at the top of its parent chain (itself if none). */
  root: number;
  /** Position relative to the root surface's origin
   *  (HeadlessWindow.originX/Y), logical px. */
  x: number;
  y: number;
  /** Buffer size, buffer px. */
  width: number;
  height: number;
  /** Surface-local size, logical px (pointer coordinates live here). */
  logicalWidth: number;
  logicalHeight: number;
  commits: number;
  /** Where it takes pointer input (wl_surface.set_input_region): [x, y, w,
   *  h] rects, surface-local logical px; null = the whole surface. Hit-testing
   *  (surfaceAt, and so every scripted pointer call) passes over the rest. */
  inputRegion: Int32Array | null;
  /** The GPU buffer (resource) its last commit named; undefined
   *  when that commit carried pixels. */
  gpu?: GpuRef;
}

/** A mapped toplevel and its placement. Positions are the scene's: the core
 *  has none. The window's box is its geometry (CommitEvent.geometry): the
 *  frame the app declared, or the toplevel together with its subsurfaces. */
export interface HeadlessWindow {
  key: string;
  conn: number;
  /** The toplevel surface. */
  surface: number;
  title: string;
  /** The box's top-left in the output, logical px. What the app draws
   *  outside its geometry (shadows) extends beyond the box. A fullscreen
   *  window's box is the whole output (black where the app's geometry
   *  doesn't cover it: centred, and clipped when larger). */
  x: number;
  y: number;
  /** The box's size: what resize() asks for and maximize fills. */
  width: number;
  height: number;
  /** The toplevel surface's origin in the output: the box's top-left minus
   *  the geometry's offset in the surface. HeadlessSurface positions are
   *  relative to it. */
  originX: number;
  originY: number;
  /** Stacking: higher is above. */
  z: number;
  maximized: boolean;
  fullscreen: boolean;
  /** Hidden (not drawn, not hit, never focused) until restore(). */
  minimized: boolean;
  focused: boolean;
}

/** A window by key, or anything naming its toplevel (a HeadlessWindow). */
export type WindowRef = string | { conn: number; surface: number };

/** Tight RGBA rows, 4 bytes per pixel, row 0 at the top; straight alpha as
 *  a canvas has it (bgra's premultiplied alpha passes through unchanged,
 *  the approximation the browser view makes too). */
export interface RgbaImage {
  width: number;
  height: number;
  data: Uint8Array<ArrayBuffer>;
}

export interface ScreenshotOptions {
  /** Device px per logical px. Default: the output scale. */
  scale?: number;
  /** Only this window (toplevel, subsurfaces, popups), cropped to their
   *  bounds, on a transparent background. */
  window?: WindowRef;
}

/** What surfaceAt finds: the surface and the point in its local px. */
export interface SurfaceHit {
  conn: number;
  surface: number;
  root: number;
  role: Role;
  x: number;
  y: number;
}

/** The pointer image a client set while its surface holds the pointer
 *  (CursorEvent): what a page would show over that client. */
export interface HeadlessCursor {
  /** The client that set it. */
  conn: number;
  /** A CSS cursor name: the wp_cursor_shape shape, 'none' (hidden:
   *  set_cursor NULL, or a cursor surface without a buffer), or 'default'
   *  with a cursor surface. */
  cursor: string;
  /** The cursor surface (wl_pointer.set_cursor), 0 for a shape or none.
   *  Its image is surfacePixels(conn, surface), shown at
   *  HeadlessSurface.logicalWidth × logicalHeight. */
  surface: number;
  /** The hotspot in the cursor surface's local logical px: the image is
   *  drawn with this point at the pointer. */
  hotspotX: number;
  hotspotY: number;
}

/** The pointer lock an app wants (PointerLockEvent) and whether it is
 *  granted: while it is, the pointer stays where it is and pointer moves
 *  reach the app as relative motion only. */
export interface HeadlessPointerLock {
  conn: number;
  surface: number;
  locked: boolean;
}

/** A linux evdev button code, or its name. */
export type Button = 'left' | 'middle' | 'right' | number;
/** A linux evdev key code, or a KeyboardEvent.code name ('Enter', 'KeyA',
 *  'ControlLeft', …). */
export type Key = number | string;

export interface Headless {
  readonly engine: Engine;
  readonly output: Readonly<{ width: number; height: number; scale: number }>;
  /** Resize the output (and optionally rescale it). */
  setOutput(width: number, height: number, scale?: number): void;
  /** One frame: engine.tick(time ?? performance.now()). With frameInterval
   *  0 this is the only clock. */
  tick(time?: number): void;

  /** Mapped toplevels, in creation order (minimized ones too). */
  windows(): HeadlessWindow[];
  window(ref: WindowRef): HeadlessWindow | undefined;
  /** Every surface that has committed, any role. */
  surfaces(): HeadlessSurface[];
  /** The window holding keyboard focus. */
  focused(): HeadlessWindow | undefined;

  /** Stack on top and take keyboard focus (a taskbar click); a minimized
   *  window is restored (which raises and focuses it). */
  raise(ref: WindowRef): void;
  /** Keyboard focus only: leave for the old window, enter for this one
   *  (not a minimized one). */
  focus(ref: WindowRef): void;
  /** Fullscreen or back (engine.setFullscreen; the app's answer and the
   *  'fullscreen' event do the rest). */
  setFullscreen(ref: WindowRef, fullscreen: boolean): void;
  /** Maximize or back (engine.setMaximized). */
  setMaximized(ref: WindowRef, maximized: boolean): void;
  /** Hide the window (engine.setMinimized): keyboard focus passes to the
   *  topmost window left, the pointer to what is under it now. */
  minimize(ref: WindowRef): void;
  /** Bring a minimized window back where it was, raised and focused. */
  restore(ref: WindowRef): void;
  /** Place the window's box at (x, y), output logical px. */
  move(ref: WindowRef, x: number, y: number): void;
  /** Ask the app for a new size (xdg_toplevel.configure, clamped to its
   *  hints); the scene follows its next commit. */
  resize(ref: WindowRef, width: number, height: number): void;

  /** Keys go to the focused window; dropped while none has focus. Escape
   *  during a drag cancels it instead, and while the pointer is locked
   *  breaks the lock (breakLock), as a browser does — swallowed either way;
   *  so are the window bindings (HeadlessOptions.shortcuts). NumLock is
   *  on and Caps Lock off until 'NumLock' / 'CapsLock' is pressed (or
   *  engine.keyboardLocks sets them): 'Numpad7' types a 7. */
  keyDown(key: Key): void;
  keyUp(key: Key): void;
  /** Press the keys in order, release them in reverse: press('ControlLeft',
   *  'KeyC') is a chord. */
  press(...keys: Key[]): void;
  /** Type text on a US layout (shift handled). A character with no key goes
   *  through text-input when the focused app has it enabled; otherwise
   *  type throws before sending anything. */
  type(text: string): void;

  /** Pointer at (x, y), output logical px: enter/leave as the surface under
   *  it changes, motion while it stays. While a button is held the pressed
   *  surface keeps the pointer (an implicit grab, as Wayland seats do; the
   *  page does it with pointer capture), until a popup of its client maps
   *  (a popup grab: its surfaces get the pointer by position again). Each
   *  motion carries the move as its relative part (zwp_relative_pointer_v1).
   *  While the pointer is locked it does not move: the app gets the move
   *  (x, y minus where the pointer is) as relative motion only. */
  pointerMove(x: number, y: number): void;
  /** Move the pointer by (dx, dy): pointerMove relative to where it is —
   *  what a locked pointer's moves are. */
  pointerMoveBy(dx: number, dy: number): void;
  /** A press where the pointer is: dismisses open popups it misses, focuses
   *  and raises the window it hits. Default button: left. */
  pointerDown(button?: Button): void;
  pointerUp(button?: Button): void;
  /** pointerMove, pointerDown, pointerUp. */
  click(x: number, y: number, button?: Button): void;
  /** Wheel detents where the pointer is (positive: down / right). */
  scroll(deltaY: number, deltaX?: number): void;
  /** The topmost surface at an output point: popups above subsurfaces above
   *  their toplevel, windows by z. Cursor, dnd-icon and role-less surfaces
   *  never hit, nor a surface where the point is outside its input region
   *  (the point falls through to what is below). */
  surfaceAt(x: number, y: number): SurfaceHit | null;
  /** End a drag in progress (as Escape does). */
  cancelDrag(): void;
  /** The pointer image the client under the pointer set (a shape, a cursor
   *  surface, or hidden), or null: the default pointer (no client set one
   *  since the pointer entered its surface). Leaving resets it. */
  cursor(): HeadlessCursor | null;
  /** The pointer lock an app wants, granted or not; null: none. */
  pointerLock(): HeadlessPointerLock | null;
  /** Grant the wanted pointer lock (what a page does when the browser
   *  locks): the app gets `locked`. */
  grantLock(): void;
  /** The user broke the pointer lock (Esc, the tab losing focus): the app
   *  gets `unlocked`; a persistent lock stays wanted (re-granted at the
   *  next press on its surface with autoLock). */
  breakLock(): void;

  /** The scene composited at the output size × scale (device px). Each
   *  surface lands at its logical box × scale: a buffer of exactly that size
   *  (the app rendered at the output scale) is copied 1:1, any other is
   *  resampled nearest-neighbour. The dnd icon follows the pointer. */
  screenshot(options?: ScreenshotOptions): RgbaImage;
  /** A copy of a surface's buffer (buffer px), or null before its first
   *  commit. */
  surfacePixels(conn: number, surface: number): RgbaImage | null;

  /** The clipboard (wl_data_device selection) as text: read from the app
   *  that owns it through the relay (readSelectionText; the best text type
   *  it offers), or null — empty, no text, over `maxBytes` (default 16
   *  MiB), no answer within `timeout` ms. The selection's owner and types:
   *  engine.selection(); its changes: 'selection' events. Rejects at once
   *  with Error(NO_SELECTION_BRIDGE) when the relay can't bridge the
   *  clipboard (engine.selectionBridged() false: wlandr 0.1.0). */
  readClipboard(options?: { maxBytes?: number; timeout?: number }): Promise<string | null>;
  /** Make `text` the clipboard selection (setSelectionText: the
   *  compositor's own source, under every text type), as a page paste does;
   *  like any selection only the focused window is offered it. '' or null
   *  clears it if it is still this one. False while the link is not open,
   *  or when the relay can't bridge the clipboard (logged once per link:
   *  NO_SELECTION_BRIDGE; no app is offered it). */
  writeClipboard(text: string | null): boolean;

  /** Dispose the engine (closes the link; nothing is emitted after it) and
   *  stop the clock. */
  dispose(): void;
}

const ROLE_TOPLEVEL = 1, ROLE_SUBSURFACE = 2, ROLE_POPUP = 4, ROLE_DND_ICON = 5;
const KEY_ESC = 1, KEY_SHIFT = 42;
const KEY_ALT = new Set([56, 100]), KEY_OTHER_MODS = new Set([29, 97, 42, 54, 125, 126]); // ctrl, shift, meta
const KEY_F9 = 67, KEY_F10 = 68, KEY_F11 = 87;
const BUTTONS: Record<string, number | undefined> = { left: 0x110, right: 0x111, middle: 0x112 };

// KeyboardEvent.code → linux evdev keycode (input.ts's table)
const EVDEV: Record<string, number | undefined> = {
  Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6, Digit6: 7, Digit7: 8,
  Digit8: 9, Digit9: 10, Digit0: 11, Minus: 12, Equal: 13, Backspace: 14, Tab: 15,
  KeyQ: 16, KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22, KeyI: 23, KeyO: 24,
  KeyP: 25, BracketLeft: 26, BracketRight: 27, Enter: 28, ControlLeft: 29, KeyA: 30,
  KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36, KeyK: 37, KeyL: 38,
  Semicolon: 39, Quote: 40, Backquote: 41, ShiftLeft: 42, Backslash: 43, KeyZ: 44,
  KeyX: 45, KeyC: 46, KeyV: 47, KeyB: 48, KeyN: 49, KeyM: 50, Comma: 51, Period: 52,
  Slash: 53, ShiftRight: 54, NumpadMultiply: 55, AltLeft: 56, Space: 57, CapsLock: 58,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68,
  F11: 87, F12: 88, ControlRight: 97, AltRight: 100, Home: 102, ArrowUp: 103,
  PageUp: 104, ArrowLeft: 105, ArrowRight: 106, End: 107, ArrowDown: 108,
  PageDown: 109, Insert: 110, Delete: 111, MetaLeft: 125, MetaRight: 126,
  // the keypad and the rest of a full keyboard (all in the core's keymap)
  NumLock: 69, ScrollLock: 70, Numpad7: 71, Numpad8: 72, Numpad9: 73, NumpadSubtract: 74,
  Numpad4: 75, Numpad5: 76, Numpad6: 77, NumpadAdd: 78, Numpad1: 79, Numpad2: 80,
  Numpad3: 81, Numpad0: 82, NumpadDecimal: 83, IntlBackslash: 86, NumpadEnter: 96,
  NumpadDivide: 98, PrintScreen: 99, NumpadEqual: 117, Pause: 119, ContextMenu: 127,
};

// character → [evdev code, shift] on the US layout (the core's canned keymap)
const CHARS = new Map<string, [number, boolean]>();
{
  const plain = '1234567890-=qwertyuiop[]asdfghjkl;\'`\\zxcvbnm,./';
  const shifted = '!@#$%^&*()_+QWERTYUIOP{}ASDFGHJKL:"~|ZXCVBNM<>?';
  const codes = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53];
  codes.forEach((code, i) => {
    CHARS.set(plain[i], [code, false]);
    CHARS.set(shifted[i], [code, true]);
  });
  CHARS.set(' ', [57, false]);
  CHARS.set('\n', [28, false]);
  CHARS.set('\t', [15, false]);
}

const keyOf = (conn: number, surface: number) => `c${conn}s${surface}`;
const refKey = (ref: WindowRef) => (typeof ref === 'string' ? ref : keyOf(ref.conn, ref.surface));
const now = () => performance.now() >>> 0;

/** A surface and its pixels. `parent` (CommitEvent.parent), `z`
 *  (CommitEvent.z) and `seq`, the first-commit order, are its stacking
 *  (engine stackOrder, as the view's). */
interface Surf {
  key: string; conn: number; surface: number; role: Role; root: number; parent: number; z: number;
  x: number; y: number; width: number; height: number; logicalWidth: number; logicalHeight: number;
  data: Uint8Array<ArrayBuffer>; commits: number; seq: number; mapped: boolean; gpu?: GpuRef;
}
/** A toplevel's placement: x, y is the top-left of its box, the window
 *  geometry g* (in the toplevel surface's px; gw 0 = not known yet, the box
 *  is the toplevel's). `restore` is the position before a maximize or
 *  fullscreen. */
interface Win {
  key: string; conn: number; surface: number; x: number; y: number; z: number;
  gx: number; gy: number; gw: number; gh: number;
  maximized: boolean; fullscreen: boolean; minimized: boolean; restore: { x: number; y: number } | null;
}
type Target = { key: string; conn: number; surface: number };
/** An app-initiated move/resize, driven by the scripted pointer. */
interface Grab {
  win: Win; mode: 'move' | 'resize'; edges: number;
  px: number; py: number; x: number; y: number; w: number; h: number; lastW: number; lastH: number;
}

function toLink(link: HeadlessOptions['link']): Link {
  if (typeof link === 'string' || link instanceof URL) return createWsLink(link);
  const l = link as Partial<Link>;
  if (typeof l.start === 'function' && typeof l.send === 'function') return link as Link;
  return createStreamLink(link as StreamSource);
}

/** Resolves once the core is loaded and the link is starting; rejects if the
 *  wasm can't load. */
export async function createHeadless(options: HeadlessOptions): Promise<Headless> {
  if (!options || !options.link) throw new Error('createHeadless: options.link is required');
  const onEvent = options.onEvent || (() => {});
  const onWindowsChange = options.onWindowsChange || (() => {});
  const focusOnMap = options.focusOnMap !== false;
  const background = options.background || [0, 0, 0, 255];
  const output = { width: options.width ?? 1280, height: options.height ?? 720, scale: options.scale ?? 1 };
  const each = (fn: () => void) => {
    try { fn(); } catch (e) { queueMicrotask(() => { throw e; }); }
  };
  const changed = () => each(onWindowsChange);

  const surfaces = new Map<string, Surf>();
  const wins = new Map<string, Win>();   // root key → placement (titles can precede it)
  const titles = new Map<string, string>();
  const popups = new Map<string, { conn: number; surface: number }>(); // mapped popups (wm.ts)
  const textInput = new Set<number>(); // conns with text-input enabled
  const regions = new Map<string, Int32Array>(); // surface key → input region (absent: the whole surface)
  let seq = 0, zTop = 0, placed = 0;
  let active: { conn: number; surface: number } | null = null; // keyboard focus
  let orphaned = false; // the focused window just went away: focus passes on (policy)
  let pointer = { x: 0, y: 0 };
  let hover: Target | null = null;  // the surface holding pointer focus, as we told the engine
  let pressed: Target | null = null; // the implicit grab's surface while buttons are held
  const held = new Set<number>();
  let grab: Grab | null = null;
  let dnd: { conn: number; icon: number } | null = null;
  let cursor: HeadlessCursor | null = null; // the pointer image (CursorEvent)
  const autoLock = options.autoLock !== false;
  let lock: HeadlessPointerLock | null = null; // the pointer lock an app wants (PointerLockEvent)
  let escHeld = false; // an Escape that broke the lock: its release is swallowed too
  const keysHeld = new Set<number>(); // for the window bindings' modifiers
  const swallowed = new Set<number>(); // binding keys whose release is ours too
  const shortcuts = options.shortcuts !== false;
  let disposed = false;
  let engine: Engine;

  // --- scene: event → state, no engine calls (pixels must be copied before
  // any: an engine call may detach a wasm-backed `pixels`) -----------------

  function windowFor(conn: number, root: number): Win {
    const key = keyOf(conn, root);
    let win = wins.get(key);
    if (!win) {
      // view.ts's default mount: cascade; the 48px headroom keeps what an
      // app draws above its window geometry on-screen
      win = { key, conn, surface: root, x: 24 + (placed % 8) * 40, y: 48 + (placed % 6) * 36, z: ++zTop,
        gx: 0, gy: 0, gw: 0, gh: 0, maximized: false, fullscreen: false, minimized: false, restore: null };
      placed++;
      wins.set(key, win);
      changed();
    }
    return win;
  }

  // windows sit at the output origin while maximized or fullscreen (wm.ts
  // place/snap/unsnap)
  function place(win: Win) {
    if (win.maximized || win.fullscreen) {
      if (win.x === 0 && win.y === 0) return;
      if (!win.restore) win.restore = { x: win.x, y: win.y };
      win.x = 0;
      win.y = 0;
      return;
    }
    if (win.restore) { win.x = win.restore.x; win.y = win.restore.y; }
    win.restore = null;
  }

  // the toplevel surface's origin in the output: the box's top-left less
  // the geometry's offset; fullscreen, the geometry centred in the output
  function originOfWin(win: Win): { x: number; y: number } {
    if (!win.fullscreen) return { x: win.x - win.gx, y: win.y - win.gy };
    const root = surfaces.get(win.key);
    const gw = win.gw || (root ? root.logicalWidth : 0), gh = win.gh || (root ? root.logicalHeight : 0);
    return { x: (output.width - gw) / 2 - win.gx, y: (output.height - gh) / 2 - win.gy };
  }

  // a minimized window took the pointer and keyboard with it (the core
  // sent the leaves): forget them here, quietly; focus passes on (policy)
  function hide(win: Win) {
    const inWin = (t: { conn: number; surface: number } | null) => {
      if (!t || t.conn !== win.conn) return false;
      const s = surfaces.get(keyOf(t.conn, t.surface));
      return t.surface === win.surface || (!!s && s.root === win.surface);
    };
    if (active && inWin(active)) { active = null; orphaned = true; }
    if (hover && inWin(hover)) hover = null;
    if (pressed && inWin(pressed)) pressed = null;
    if (grab && grab.win === win) grab = null;
    for (const [key, p] of popups) if (inWin(p)) popups.delete(key); // the core dismissed them
  }

  // Copy the damaged pixels into the surface's RGBA buffer. A size change
  // starts a fresh (transparent) buffer: the app damages all of it then.
  function latch(s: Surf, ev: CommitEvent) {
    const w = ev.width, h = ev.height;
    if (s.width !== w || s.height !== h) {
      s.data = new Uint8Array(w * h * 4);
      s.width = w;
      s.height = h;
    }
    s.gpu = ev.gpu;
    if (ev.format === 'gpu') return latchImage(s, ev);
    const { damage: d, pixels: src, stride } = ev;
    let off = 0; // 'rgba': the rect's first byte in the packed pixels
    for (let i = 0; i < d.length; i += 4) {
      const rx = d[i], ry = d[i + 1], rw = d[i + 2], rh = d[i + 3];
      // rects are the core's word; clip anyway so a bad one can't throw here
      const x0 = Math.max(0, rx), y0 = Math.max(0, ry), x1 = Math.min(w, rx + rw), y1 = Math.min(h, ry + rh);
      if (ev.format === 'rgba') {
        for (let y = y0; x1 > x0 && y < y1; y++) {
          const so = off + ((y - ry) * rw + (x0 - rx)) * 4;
          s.data.set(src.subarray(so, so + (x1 - x0) * 4), (y * w + x0) * 4);
        }
        off += rw * rh * 4;
      } else if (x1 > x0 && y1 > y0) {
        const opaque = ev.format === 'bgrx';
        if (x0 === 0 && x1 === w) swizzleRect(src, y0 * stride, stride, w, y1 - y0, opaque, s.data.subarray(y0 * w * 4));
        else for (let y = y0; y < y1; y++) swizzleRect(src, y * stride + x0 * 4, stride, x1 - x0, 1, opaque, s.data.subarray((y * w + x0) * 4));
      }
    }
  }

  // A GPU commit: the damaged rects of the resolved image (tight RGBA rows
  // of its own width), cropped to both sizes. No image: nothing changes
  // (and the engine makes the surface's next commit's damage whole).
  function latchImage(s: Surf, ev: CommitEvent) {
    const img = ev.image as RgbaImage | null | undefined;
    if (!img) return;
    const d = ev.damage, w = s.width, h = s.height;
    for (let i = 0; i < d.length; i += 4) {
      const x0 = Math.max(0, d[i]), y0 = Math.max(0, d[i + 1]);
      const x1 = Math.min(w, img.width, d[i] + d[i + 2]), y1 = Math.min(h, img.height, d[i + 1] + d[i + 3]);
      for (let y = y0; x1 > x0 && y < y1; y++) {
        s.data.set(img.data.subarray((y * img.width + x0) * 4, (y * img.width + x1) * 4), (y * w + x0) * 4);
      }
    }
  }

  // returns true for a toplevel's first commit (it takes focus once the
  // event has been dispatched)
  function commit(ev: CommitEvent): boolean {
    const key = keyOf(ev.conn, ev.surface);
    let s = surfaces.get(key);
    if (!s) {
      s = { key, conn: ev.conn, surface: ev.surface, role: ev.role, root: ev.root, parent: 0, z: 0, x: 0, y: 0, width: 0, height: 0,
        logicalWidth: 0, logicalHeight: 0, data: new Uint8Array(0), commits: 0, seq: seq++, mapped: false };
      surfaces.set(key, s);
    }
    latch(s, ev);
    s.role = ev.role;
    s.root = ev.root;
    s.parent = ev.parent ?? (ev.role === ROLE_TOPLEVEL ? 0 : ev.root);
    s.z = ev.z ?? 0;
    s.x = ev.x;
    s.y = ev.y;
    s.logicalWidth = ev.logicalWidth;
    s.logicalHeight = ev.logicalHeight;
    s.commits++;
    if (ev.role === ROLE_TOPLEVEL || ev.role === ROLE_SUBSURFACE || ev.role === ROLE_POPUP) {
      const win = windowFor(ev.conn, ev.root);
      // the box follows the window geometry, which any commit in the window
      // can change (view.ts box())
      const g = ev.geometry;
      if (g.width > 0 && g.height > 0) { win.gx = g.x; win.gy = g.y; win.gw = g.width; win.gh = g.height; }
      // the window's states as of this commit: apps can START maximized
      // or fullscreen, before their window existed for the event
      if (ev.role === ROLE_TOPLEVEL) {
        if (ev.fullscreen && !win.fullscreen) win.z = ++zTop; // on top, as the wm raises it
        win.maximized = ev.maximized;
        win.fullscreen = ev.fullscreen;
        if (ev.minimized && !win.minimized) hide(win);
        win.minimized = ev.minimized;
        if (win.maximized || win.fullscreen) place(win);
      }
    }
    if (ev.role === ROLE_POPUP) popups.set(key, { conn: ev.conn, surface: ev.surface });
    if (ev.role === ROLE_TOPLEVEL && !s.mapped) {
      s.mapped = true;
      changed();
      return true;
    }
    return false;
  }

  function dropConn(conn: number) {
    for (const [key, s] of surfaces) if (s.conn === conn) surfaces.delete(key);
    for (const key of wins.keys()) if (wins.get(key)!.conn === conn) wins.delete(key);
    for (const key of titles.keys()) if (key.startsWith(`c${conn}s`)) titles.delete(key);
    for (const [key, p] of popups) if (p.conn === conn) popups.delete(key);
    for (const key of regions.keys()) if (key.startsWith(`c${conn}s`)) regions.delete(key);
    textInput.delete(conn);
  }

  // the pointer and keyboard targets die silently with their surface or
  // conn: a leave naming a dead surface kills the client
  function forget(dead: (conn: number, surface: number) => boolean) {
    if (active && dead(active.conn, active.surface)) { active = null; orphaned = true; changed(); }
    if (hover && dead(hover.conn, hover.surface)) hover = null;
    if (pressed && dead(pressed.conn, pressed.surface)) pressed = null;
    if (grab && dead(grab.win.conn, grab.win.surface)) grab = null;
  }

  function scene(ev: Event): boolean {
    switch (ev.type) {
      case 'commit': return commit(ev);
      case 'surface': {
        // a role learned late or lost (cursor buffers committed before
        // set_cursor, dnd icons, popup roles dying while the surface lives):
        // drawing and hit-testing gate on the current role
        const s = surfaces.get(keyOf(ev.conn, ev.surface));
        if (s) { s.role = ev.role; s.root = ev.root; s.parent = ev.parent ?? (ev.role === ROLE_TOPLEVEL ? 0 : ev.root); s.z = ev.z ?? 0; }
        if (ev.role !== ROLE_POPUP) popups.delete(keyOf(ev.conn, ev.surface));
        // an unmapped toplevel's states went with its xdg_toplevel
        const win = wins.get(keyOf(ev.conn, ev.surface));
        if (win && ev.role !== ROLE_TOPLEVEL) { win.maximized = win.fullscreen = win.minimized = false; place(win); }
        changed();
        break;
      }
      case 'position': {
        // moved by another surface's commit (a popup following its
        // parent's window geometry), or restacked by its parent's
        const s = surfaces.get(keyOf(ev.conn, ev.surface));
        if (s && (s.role === ROLE_SUBSURFACE || s.role === ROLE_POPUP)) {
          s.x = ev.x;
          s.y = ev.y;
          if (ev.z !== undefined) s.z = ev.z;
        }
        break;
      }
      case 'destroy': {
        const key = keyOf(ev.conn, ev.surface);
        surfaces.delete(key);
        wins.delete(key);
        titles.delete(key);
        popups.delete(key);
        regions.delete(key);
        forget((c, s) => c === ev.conn && s === ev.surface);
        changed();
        break;
      }
      case 'disconnect':
        dropConn(ev.conn);
        forget((c) => c === ev.conn);
        if (cursor && cursor.conn === ev.conn) cursor = null;
        if (lock && lock.conn === ev.conn) lock = null;
        changed();
        break;
      case 'close':
        // every conn got its 'disconnect' first; the next open is a fresh
        // compositor with no session state
        hover = pressed = grab = dnd = cursor = lock = null;
        held.clear();
        break;
      case 'pointer-lock':
        if (ev.surface) lock = { conn: ev.conn, surface: ev.surface, locked: !!lock && lock.locked && lock.conn === ev.conn && lock.surface === ev.surface };
        else if (lock && lock.conn === ev.conn) lock = null;
        break;
      case 'cursor':
        // '' with no surface: the pointer left, back to the default
        cursor = ev.cursor || ev.surface
          ? { conn: ev.conn, cursor: ev.cursor, surface: ev.surface, hotspotX: ev.hotspotX, hotspotY: ev.hotspotY }
          : null;
        break;
      case 'title':
        titles.set(keyOf(ev.conn, ev.surface), ev.title);
        changed();
        break;
      case 'text-input':
        if (ev.active) textInput.add(ev.conn); else textInput.delete(ev.conn);
        break;
      case 'input-region':
        // may precede the surface's first commit; kept apart from Surf
        if (ev.region) regions.set(keyOf(ev.conn, ev.surface), ev.region);
        else regions.delete(keyOf(ev.conn, ev.surface));
        break;
      case 'maximize': {
        const win = wins.get(keyOf(ev.conn, ev.surface));
        if (win) { win.maximized = ev.maximized; place(win); changed(); }
        break;
      }
      case 'fullscreen': {
        const win = wins.get(keyOf(ev.conn, ev.surface));
        if (win) { win.fullscreen = ev.fullscreen; place(win); changed(); }
        break;
      }
      case 'minimize': {
        const win = wins.get(keyOf(ev.conn, ev.surface));
        if (!win) break;
        if (ev.minimized && !win.minimized) hide(win);
        win.minimized = ev.minimized;
        changed();
        break;
      }
      case 'drag-end':
        dnd = null;
        break;
    }
    return false;
  }

  // --- window policy: may call the engine, so it runs after dispatch ------

  function policy(ev: Event, mapped: boolean) {
    // the focused toplevel unmapped (its xdg_toplevel went) while its
    // wl_surface lives on: that one can, and does, get its leave
    if (ev.type === 'surface' && ev.role !== ROLE_TOPLEVEL && active && active.conn === ev.conn && active.surface === ev.surface) {
      engine.keyboardLeave(active.conn);
      active = null;
      orphaned = true;
      changed();
    }
    // the focused window closed: focus passes to the topmost one left, as on
    // a desktop (input.ts does the same on a page)
    if (orphaned) {
      orphaned = false;
      const next = stacked().pop();
      if (next && !active) focusSurface(next.conn, next.surface);
    }
    switch (ev.type) {
      case 'pointer-lock':
        // a page with a user gesture to hand: the browser locks at once
        if (autoLock && lock && !lock.locked) grantLock();
        break;
      case 'fullscreen': {
        // it covers the output: on top, and the keyboard's (wm.ts)
        const win = wins.get(keyOf(ev.conn, ev.surface));
        if (ev.fullscreen && win && visible(win) && !win.minimized) {
          raiseWin(win);
          focusSurface(win.conn, win.surface);
        }
        track(false); // the scene moved under the pointer
        break;
      }
      case 'maximize':
        track(false);
        break;
      case 'minimize': {
        const win = wins.get(keyOf(ev.conn, ev.surface));
        if (!ev.minimized && win && visible(win)) {
          raiseWin(win);
          focusSurface(win.conn, win.surface);
        }
        track(false); // what is under the pointer now gets it
        break;
      }
      case 'commit':
        if (mapped && focusOnMap && !ev.minimized) focusSurface(ev.conn, ev.surface);
        // a popup grab replaces the implicit grab (input.ts): the pressed
        // client's surfaces get the pointer by position again
        if (ev.role === ROLE_POPUP && pressed && pressed.conn === ev.conn && pressed.surface !== ev.surface) {
          pressed = null;
          track(false);
        }
        break;
      case 'move':
      case 'resize': {
        // the app asks for a grab after the press that started it: with the
        // button still held, the scripted pointer drives it to release (like
        // wm.ts); once released there is nothing to grab
        const win = wins.get(keyOf(ev.conn, ev.surface));
        if (!win || !held.size || grab || dnd) break;
        engine.pointerLeave(ev.conn); // ends the app's own gesture
        hover = pressed = null;
        const root = surfaces.get(win.key);
        grab = { win, mode: ev.type, edges: ev.type === 'resize' ? ev.edges : 0, px: pointer.x, py: pointer.y,
          x: win.x, y: win.y, w: win.gw || (root ? root.logicalWidth : 0), h: win.gh || (root ? root.logicalHeight : 0),
          lastW: 0, lastH: 0 };
        raiseWin(win);
        break;
      }
      case 'drag-start':
        // An unanswered drag wedges the seat: the core drops every pointer
        // enter/motion/button/axis while it lasts and ignores further
        // start_drag. Drive it from the scripted pointer while the button
        // that started it is held; otherwise cancel at once.
        if (!held.size || grab || dnd) { engine.dragCancel(); break; }
        engine.pointerLeave(ev.conn); // the drag grab steals the pointer
        hover = pressed = null;
        dnd = { conn: ev.conn, icon: ev.icon };
        break;
    }
  }

  // --- geometry -------------------------------------------------------------

  // a mapped toplevel (listed); `shown`: and not minimized (drawn, hit, focused)
  const visible = (win: Win) => {
    const root = surfaces.get(win.key);
    return !!root && root.role === ROLE_TOPLEVEL && root.commits > 0;
  };
  const shown = (win: Win) => visible(win) && !win.minimized;
  // a window's surfaces bottom to top, as Wayland stacks them (engine
  // stackOrder): drawn in this order, hit-tested in reverse
  function layers(win: Win): Surf[] {
    const members: Surf[] = [surfaces.get(win.key)!];
    for (const s of surfaces.values()) {
      if (s.conn !== win.conn || s.root !== win.surface || s.surface === win.surface) continue;
      if (s.role === ROLE_SUBSURFACE || s.role === ROLE_POPUP) members.push(s);
    }
    return stackOrder(members, win.surface);
  }
  const stacked = () => [...wins.values()].filter(shown).sort((a, b) => a.z - b.z);

  function surfaceAt(x: number, y: number): SurfaceHit | null {
    const ws = stacked();
    for (let i = ws.length - 1; i >= 0; i--) {
      const win = ws[i], ls = layers(win), o = originOfWin(win);
      for (let j = ls.length - 1; j >= 0; j--) {
        const s = ls[j];
        const lx = x - (o.x + s.x), ly = y - (o.y + s.y);
        if (lx >= 0 && ly >= 0 && lx < s.logicalWidth && ly < s.logicalHeight && inRegion(regions.get(s.key) ?? null, lx, ly)) {
          return { conn: s.conn, surface: s.surface, root: s.root, role: s.role, x: lx, y: ly };
        }
      }
      // a fullscreen window's black backdrop covers what is below
      if (win.fullscreen) return null;
    }
    return null;
  }
  // a surface's origin in the output, if it is on screen
  function originOf(t: Target): { x: number; y: number } | null {
    const s = surfaces.get(t.key);
    const win = s && wins.get(keyOf(s.conn, s.root));
    if (!s || !win) return null;
    const o = originOfWin(win);
    return { x: o.x + s.x, y: o.y + s.y };
  }

  // --- input ----------------------------------------------------------------

  function focusSurface(conn: number, surface: number) {
    if (active && active.conn === conn && active.surface === surface) return;
    if (active) engine.keyboardLeave(active.conn);
    active = { conn, surface };
    engine.keyboardEnter(conn, surface);
    changed();
  }
  function raiseWin(win: Win) {
    if (win.z === zTop) return;
    win.z = ++zTop;
    changed();
  }
  const toplevel = (ref: WindowRef) => {
    const win = wins.get(refKey(ref));
    return win && visible(win) ? win : undefined;
  };
  // the focused window, shown (the bindings' target)
  const focusedWin = () => {
    const win = active && toplevel(active);
    return win && !win.minimized ? win : undefined;
  };

  // enter/leave when the surface under the pointer changes (pointerover /
  // pointerout on a page), motion while it stays
  function track(motion: boolean, rel?: { dx: number; dy: number }) {
    if (grab || dnd || pressed || (lock && lock.locked)) return;
    const hit = surfaceAt(pointer.x, pointer.y);
    const t = hit && { key: keyOf(hit.conn, hit.surface), conn: hit.conn, surface: hit.surface };
    if (t && hover && t.key === hover.key) {
      if (motion) engine.pointerMotion(t.conn, now(), hit!.x, hit!.y, rel);
      return;
    }
    if (hover) engine.pointerLeave(hover.conn);
    hover = t;
    if (t) engine.pointerEnter(t.conn, t.surface, hit!.x, hit!.y);
  }

  function dragTarget() {
    const t = surfaceAt(pointer.x, pointer.y);
    engine.dragMotion(t ? t.conn : 0, t ? t.surface : 0, now(), t ? t.x : 0, t ? t.y : 0); // 0,0 = over nothing
  }

  function grabMove() {
    const g = grab!;
    const dx = pointer.x - g.px, dy = pointer.y - g.py;
    if (g.mode === 'move') {
      g.win.x = g.x + dx;
      g.win.y = Math.max(0, g.y + dy);
      return;
    }
    // edges: 1 top, 2 bottom, 4 left, 8 right; left/top also shift the box
    let w = g.w, h = g.h;
    if (g.edges & 8) w += dx;
    if (g.edges & 4) { w -= dx; g.win.x = g.x + dx; }
    if (g.edges & 2) h += dy;
    if (g.edges & 1) { h -= dy; g.win.y = Math.max(0, g.y + dy); }
    g.lastW = Math.max(80, w);
    g.lastH = Math.max(60, h);
    engine.requestResize(g.win.conn, g.win.surface, g.lastW, g.lastH);
  }

  const button = (b: Button = 'left') => {
    const code = typeof b === 'number' ? b : BUTTONS[b];
    if (code === undefined) throw new Error(`headless: unknown button ${JSON.stringify(b)}`);
    return code;
  };
  const evdev = (k: Key) => {
    const code = typeof k === 'number' ? k : EVDEV[k];
    if (code === undefined) throw new Error(`headless: unknown key ${JSON.stringify(k)}`);
    return code;
  };

  function keyDown(k: Key) {
    const code = evdev(k);
    if (dnd && code === KEY_ESC) { engine.dragCancel(); return; }
    if (lock && lock.locked && code === KEY_ESC) { escHeld = true; breakLock(); return; }
    // the window bindings (wm.ts): Alt and no other modifier
    const win = shortcuts && (code === KEY_F9 || code === KEY_F10 || code === KEY_F11) &&
      [...keysHeld].some((c) => KEY_ALT.has(c)) && ![...keysHeld].some((c) => KEY_OTHER_MODS.has(c)) ? focusedWin() : undefined;
    if (win) {
      swallowed.add(code);
      if (code === KEY_F11) engine.setFullscreen(win.conn, win.surface, !win.fullscreen);
      else if (code === KEY_F10) engine.setMaximized(win.conn, win.surface, !win.maximized);
      else engine.setMinimized(win.conn, win.surface, true);
      return;
    }
    keysHeld.add(code);
    if (active) engine.key(active.conn, now(), code, true);
  }
  function keyUp(k: Key) {
    const code = evdev(k);
    if (escHeld && code === KEY_ESC) { escHeld = false; return; }
    if (swallowed.delete(code)) return;
    keysHeld.delete(code);
    if (active) engine.key(active.conn, now(), code, false);
  }

  function grantLock() {
    if (!lock || lock.locked) return;
    lock.locked = true;
    engine.pointerLockGranted(lock.conn, lock.surface);
  }
  function breakLock() {
    if (!lock || !lock.locked) return;
    lock.locked = false;
    engine.pointerLockLost(lock.conn);
  }

  function pointerMove(x: number, y: number) {
    const rel = { dx: x - pointer.x, dy: y - pointer.y };
    if (lock && lock.locked) {
      // the pointer stays put: the move is relative motion only, to the
      // locked surface (the core ignores the position meanwhile)
      const t = hover || pressed;
      const o = t && originOf(t);
      if (t && o) engine.pointerMotion(t.conn, now(), pointer.x - o.x, pointer.y - o.y, rel);
      return;
    }
    pointer = { x, y };
    if (dnd) dragTarget();
    else if (grab) grabMove();
    else if (pressed) {
      // the implicit grab: motion stays with the pressed surface, in its
      // local px even outside it
      const o = originOf(pressed);
      if (o) engine.pointerMotion(pressed.conn, now(), x - o.x, y - o.y, rel);
    } else track(true, rel);
  }

  function pointerDown(b?: Button) {
    const code = button(b);
    if (grab || dnd) { held.add(code); return; }
    track(false); // the scene may have changed under a still pointer
    const t = pressed || hover;
    // fake popup grab: a press anywhere but on an open popup dismisses it
    for (const [key, p] of popups) {
      const s = surfaces.get(key);
      if (!s || s.role !== ROLE_POPUP) { popups.delete(key); continue; }
      if (!t || t.key !== key) {
        popups.delete(key);
        engine.popupDismiss(p.conn, p.surface);
      }
    }
    held.add(code);
    if (!t) return;
    // a press anywhere in a window raises it and focuses its toplevel
    const s = surfaces.get(t.key);
    const win = s && toplevel(keyOf(s.conn, s.root));
    if (win) {
      raiseWin(win);
      focusSurface(win.conn, win.surface);
    }
    pressed = t;
    engine.pointerButton(t.conn, now(), code, true);
    // the press is the user gesture a page gets the lock with again
    if (autoLock && lock && !lock.locked && lock.conn === t.conn && lock.surface === t.surface) grantLock();
  }

  function pointerUp(b?: Button) {
    const code = button(b);
    held.delete(code);
    if (dnd) {
      // final position, then the drop; the release belongs to the drag
      dragTarget();
      engine.dragDrop();
      dnd = null;
      held.clear();
      track(false);
      return;
    }
    if (grab) {
      const g = grab;
      grab = null;
      held.clear();
      if (g.mode === 'resize' && g.lastW) engine.requestResize(g.win.conn, g.win.surface, g.lastW, g.lastH);
      track(false); // the pointer goes back to whatever is under it
      return;
    }
    const t = pressed || hover;
    if (t) engine.pointerButton(t.conn, now(), code, false);
    if (!held.size && pressed) {
      pressed = null;
      track(false);
    }
  }

  // --- screenshots ------------------------------------------------------------

  // Paint a surface with its logical box at (ox, oy) × scale into fb:
  // straight-alpha source-over, the way stacked canvases composite.
  function paint(fb: Uint8Array, fw: number, fh: number, s: Surf, ox: number, oy: number, scale: number) {
    if (!s.width || !s.height) return;
    const dx = Math.round(ox * scale), dy = Math.round(oy * scale);
    const dw = Math.round(s.logicalWidth * scale), dh = Math.round(s.logicalHeight * scale);
    if (dw <= 0 || dh <= 0) return;
    const exact = dw === s.width && dh === s.height;
    const x0 = Math.max(0, dx), x1 = Math.min(fw, dx + dw), y0 = Math.max(0, dy), y1 = Math.min(fh, dy + dh);
    const src = s.data;
    for (let y = y0; y < y1; y++) {
      const sy = exact ? y - dy : Math.min(s.height - 1, Math.floor((y - dy + 0.5) * s.height / dh));
      for (let x = x0; x < x1; x++) {
        const sx = exact ? x - dx : Math.min(s.width - 1, Math.floor((x - dx + 0.5) * s.width / dw));
        const si = (sy * s.width + sx) * 4, di = (y * fw + x) * 4;
        const a = src[si + 3];
        if (a === 255) {
          fb[di] = src[si]; fb[di + 1] = src[si + 1]; fb[di + 2] = src[si + 2]; fb[di + 3] = 255;
        } else if (a !== 0) {
          const da = fb[di + 3] * (255 - a) / 255, oa = a + da;
          fb[di] = Math.round((src[si] * a + fb[di] * da) / oa);
          fb[di + 1] = Math.round((src[si + 1] * a + fb[di + 1] * da) / oa);
          fb[di + 2] = Math.round((src[si + 2] * a + fb[di + 2] * da) / oa);
          fb[di + 3] = Math.round(oa);
        }
      }
    }
  }

  function screenshot(opts: ScreenshotOptions = {}): RgbaImage {
    const scale = opts.scale ?? output.scale;
    if (opts.window !== undefined) {
      const win = toplevel(opts.window);
      if (!win) throw new Error(`headless: no window ${JSON.stringify(refKey(opts.window))}`);
      const ls = layers(win);
      const minX = Math.min(...ls.map((s) => s.x)), minY = Math.min(...ls.map((s) => s.y));
      const maxX = Math.max(...ls.map((s) => s.x + s.logicalWidth)), maxY = Math.max(...ls.map((s) => s.y + s.logicalHeight));
      const width = Math.round((maxX - minX) * scale), height = Math.round((maxY - minY) * scale);
      const data = new Uint8Array(width * height * 4);
      for (const s of ls) paint(data, width, height, s, s.x - minX, s.y - minY, scale);
      return { width, height, data };
    }
    const width = Math.round(output.width * scale), height = Math.round(output.height * scale);
    const data = new Uint8Array(width * height * 4);
    const bg = (background[0] & 255) | (background[1] & 255) << 8 | (background[2] & 255) << 16 | (background[3] & 255) << 24;
    const px = new Uint32Array(data.buffer);
    px.fill(bg >>> 0); // little-endian: byte 0 = R
    for (const win of stacked()) {
      if (win.fullscreen) px.fill(0xff000000); // the border fill: opaque black under it, nothing below shows
      const o = originOfWin(win);
      for (const s of layers(win)) paint(data, width, height, s, o.x + s.x, o.y + s.y, scale);
    }
    if (dnd && dnd.icon) {
      // the icon follows the pointer (wm.ts placeIcon)
      const icon = surfaces.get(keyOf(dnd.conn, dnd.icon));
      if (icon && icon.role === ROLE_DND_ICON) paint(data, width, height, icon, pointer.x + 4, pointer.y + 4, scale);
    }
    return { width, height, data };
  }

  // --- the engine -------------------------------------------------------------

  engine = await createEngine({
    wasm: options.wasm,
    link: toLink(options.link),
    buffers: options.buffers,
    gpu: options.gpu,
    onEvent(ev) {
      // the scene first: it copies a commit's pixels, which may die at the
      // first engine call; the embedder next, while they are still valid;
      // then the policy, which calls the engine
      let mapped = false;
      each(() => { mapped = scene(ev); });
      each(() => onEvent(ev));
      if (!disposed) each(() => policy(ev, mapped));
    },
  });
  engine.setOutput(output.width, output.height);
  engine.setScale(output.scale, output.scale * 120);
  engine.start();
  const interval = options.frameInterval ?? 16;
  const clock = interval > 0 ? setInterval(() => engine.tick(performance.now()), interval) : null;

  const snapshot = (win: Win): HeadlessWindow => {
    const root = surfaces.get(win.key)!;
    const o = originOfWin(win);
    return {
      key: win.key, conn: win.conn, surface: win.surface, title: titles.get(win.key) ?? win.key,
      x: win.x, y: win.y,
      width: win.fullscreen ? output.width : win.gw || root.logicalWidth,
      height: win.fullscreen ? output.height : win.gh || root.logicalHeight,
      originX: o.x, originY: o.y, z: win.z,
      maximized: win.maximized, fullscreen: win.fullscreen, minimized: win.minimized,
      focused: !!active && active.conn === win.conn && active.surface === win.surface,
    };
  };

  return {
    engine,
    output: {
      get width() { return output.width; },
      get height() { return output.height; },
      get scale() { return output.scale; },
    },
    setOutput(width, height, scale) {
      output.width = width;
      output.height = height;
      engine.setOutput(width, height);
      if (scale !== undefined) {
        output.scale = scale;
        engine.setScale(scale, scale * 120);
      }
    },
    tick(time) {
      engine.tick(time ?? performance.now());
    },

    windows: () => [...wins.values()].filter(visible).map(snapshot),
    window(ref) {
      const win = toplevel(ref);
      return win && snapshot(win);
    },
    surfaces: () => [...surfaces.values()].map((s) => ({
      key: s.key, conn: s.conn, surface: s.surface, role: s.role, root: s.root, x: s.x, y: s.y,
      width: s.width, height: s.height, logicalWidth: s.logicalWidth, logicalHeight: s.logicalHeight, commits: s.commits,
      inputRegion: regions.get(s.key)?.slice() ?? null,
      ...(s.gpu ? { gpu: s.gpu } : {}),
    })),
    focused() {
      const win = active && toplevel(active);
      return win ? snapshot(win) : undefined;
    },

    raise(ref) {
      const win = toplevel(ref);
      if (!win) return;
      if (win.minimized) { engine.setMinimized(win.conn, win.surface, false); return; } // raises + focuses
      raiseWin(win);
      focusSurface(win.conn, win.surface);
    },
    focus(ref) {
      const win = toplevel(ref);
      if (win && !win.minimized) focusSurface(win.conn, win.surface);
    },
    setFullscreen(ref, on) {
      const win = toplevel(ref);
      if (win) engine.setFullscreen(win.conn, win.surface, on);
    },
    setMaximized(ref, on) {
      const win = toplevel(ref);
      if (win) engine.setMaximized(win.conn, win.surface, on);
    },
    minimize(ref) {
      const win = toplevel(ref);
      if (win) engine.setMinimized(win.conn, win.surface, true);
    },
    restore(ref) {
      const win = toplevel(ref);
      if (win) engine.setMinimized(win.conn, win.surface, false);
    },
    move(ref, x, y) {
      const win = wins.get(refKey(ref));
      if (win) { win.x = x; win.y = y; }
    },
    resize(ref, width, height) {
      const win = wins.get(refKey(ref));
      if (win) engine.requestResize(win.conn, win.surface, width, height);
    },

    keyDown,
    keyUp,
    press(...keys) {
      for (const k of keys) keyDown(k);
      for (let i = keys.length - 1; i >= 0; i--) keyUp(keys[i]);
    },
    type(text) {
      const chars = [...text];
      const conn = active ? active.conn : 0;
      const missing = chars.find((ch) => !CHARS.has(ch));
      if (missing !== undefined && !textInput.has(conn)) {
        throw new Error(`headless: no US-layout key for ${JSON.stringify(missing)} and no text-input enabled`);
      }
      for (const ch of chars) {
        if (!active) return; // focus died mid-way (an event handler)
        const k = CHARS.get(ch);
        if (!k) { engine.textInputCommit(active.conn, ch); continue; }
        if (k[1]) keyDown(KEY_SHIFT);
        keyDown(k[0]);
        keyUp(k[0]);
        if (k[1]) keyUp(KEY_SHIFT);
      }
    },

    pointerMove,
    pointerMoveBy(dx, dy) { pointerMove(pointer.x + dx, pointer.y + dy); },
    pointerDown,
    pointerUp,
    click(x, y, b) {
      pointerMove(x, y);
      pointerDown(b);
      pointerUp(b);
    },
    scroll(deltaY, deltaX = 0) {
      if (grab || dnd) return;
      track(false);
      const t = pressed || hover;
      if (!t) return;
      // a detent is 120 high-res units and ≈ 10 surface units (input.ts)
      const axis = (n: 0 | 1, delta: number) => {
        if (!delta) return;
        let v120 = Math.round(delta * 120);
        if (v120 === 0) v120 = delta > 0 ? 1 : -1;
        engine.pointerAxis(t.conn, now(), n, v120 / 12, v120);
      };
      axis(0, deltaY);
      axis(1, deltaX);
    },
    surfaceAt,
    cancelDrag() {
      if (dnd) engine.dragCancel();
    },
    cursor: () => (cursor ? { ...cursor } : null),
    pointerLock: () => (lock ? { ...lock } : null),
    grantLock,
    breakLock,

    screenshot,
    surfacePixels(conn, surface) {
      const s = surfaces.get(keyOf(conn, surface));
      return s ? { width: s.width, height: s.height, data: s.data.slice() } : null;
    },

    readClipboard: (opts) => readSelectionText(engine, opts),
    writeClipboard: (text) => setSelectionText(engine, text),

    dispose() {
      if (disposed) return;
      disposed = true;
      engine.dispose(); // first: no event reaches the scene any more
      if (clock) clearInterval(clock);
      surfaces.clear();
      wins.clear();
      titles.clear();
      popups.clear();
      regions.clear();
      active = hover = pressed = grab = dnd = lock = null;
    },
  };
}

// --- PNG ----------------------------------------------------------------------

let crcTable: Uint32Array | null = null;
function crc32(bytes: Uint8Array, start: number, end: number): number {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (let i = start; i < end; i++) c = crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** An RgbaImage as a PNG file (8-bit RGBA, no filtering). Deflate goes
 *  through CompressionStream (zlib format, what IDAT holds), which pages,
 *  Workers, Node ≥ 18, Deno and Bun all have: no dependency, no node:zlib. */
export async function encodePNG(image: RgbaImage): Promise<Uint8Array<ArrayBuffer>> {
  const { width, height, data } = image;
  const row = width * 4;
  const raw = new Uint8Array((row + 1) * height); // each row: filter byte 0 (None), then the pixels
  for (let y = 0; y < height; y++) raw.set(data.subarray(y * row, y * row + row), y * (row + 1) + 1);
  const deflated = new Uint8Array(await new Response(
    new Blob([raw]).stream().pipeThrough(new CompressionStream('deflate'))).arrayBuffer());

  const chunks: [string, Uint8Array][] = [];
  const ihdr = new Uint8Array(13);
  const dv = new DataView(ihdr.buffer);
  dv.setUint32(0, width);
  dv.setUint32(4, height);
  ihdr.set([8, 6, 0, 0, 0], 8); // 8 bits, RGBA, deflate, adaptive filtering, no interlace
  chunks.push(['IHDR', ihdr], ['IDAT', deflated], ['IEND', new Uint8Array(0)]);
  const size = 8 + chunks.reduce((n, [, b]) => n + 12 + b.length, 0);
  const out = new Uint8Array(size);
  const odv = new DataView(out.buffer);
  out.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  let off = 8;
  for (const [type, body] of chunks) {
    odv.setUint32(off, body.length);
    for (let i = 0; i < 4; i++) out[off + 4 + i] = type.charCodeAt(i);
    out.set(body, off + 8);
    odv.setUint32(off + 8 + body.length, crc32(out, off + 4, off + 8 + body.length));
    off += 12 + body.length;
  }
  return out;
}
