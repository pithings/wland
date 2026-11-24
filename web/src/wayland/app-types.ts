// The contract between the toolkit (toolkit.ts) and the apps (src/apps/).
// An app module describes a window; the toolkit makes it a Wayland client
// and calls back into what create() returns. Coordinates are logical
// (surface-local, below the title bar for decorated apps); the toolkit
// scales for HiDPI.

/** [x, y, width, height] in content coordinates. */
export type Rect = readonly [x: number, y: number, w: number, h: number];

/** wp_cursor_shape_v1 shapes the toolkit maps (CSS cursor names). */
export type CursorName =
  | 'default' | 'context-menu' | 'help' | 'pointer' | 'progress' | 'wait' | 'cell' | 'crosshair'
  | 'text' | 'move' | 'not-allowed' | 'grab' | 'grabbing'
  | 'n-resize' | 'ne-resize' | 'nw-resize' | 's-resize' | 'se-resize' | 'sw-resize' | 'e-resize' | 'w-resize'
  | 'ew-resize' | 'ns-resize' | 'zoom-in' | 'zoom-out';

export type Ctx = OffscreenCanvasRenderingContext2D;

/** A client-drawn cursor (a wl_surface given to wl_pointer.set_cursor):
 *  painted once in logical pixels; keep the object to reuse its surface. */
export interface CursorImage {
  width: number;
  height: number;
  hotX: number;
  hotY: number;
  paint(ctx: Ctx, w: number, h: number): void;
}

/** Pointer input. `button`: 0 left, 1 middle, 2 right (meaningful on
 *  down/up). `dx`/`dy`: wheel deltas (0 otherwise).
 *  `touch`: a finger the toolkit plays as the pointer (a wl_touch point the
 *  app's touch() did not take): move, down (left), moves, up, then leave —
 *  no hover before or after it, cursors ignored. A press that is abandoned
 *  (wl_touch.cancel, e.g. the window started moving) ends with a leave and
 *  no up; a finger held still in the content turns into a right-button
 *  press (leave, then down with button 2: context menus). */
export interface AppPointerEvent {
  type: 'move' | 'down' | 'up' | 'leave' | 'wheel';
  x: number;
  y: number;
  button: 0 | 1 | 2;
  shift: boolean;
  dx: number;
  dy: number;
  touch: boolean;
}

/** A wl_touch point's event, in content coordinates (relative to the
 *  content all along, also outside it). `id` is the point's, unique among
 *  the points down. Events that happened together arrive back to back and
 *  end with a 'frame' (id -1). 'cancel' ends a point without its up: the
 *  compositor took the touch sequence (a window move, minimize…) — undo
 *  what it started. */
export interface AppTouchEvent {
  type: 'down' | 'move' | 'up' | 'cancel' | 'frame';
  id: number;
  x: number;
  y: number;
}

/** A key press, through the US keymap. `key` follows DOM names ('a', 'A',
 *  'Enter', 'ArrowLeft', …); `text` is what to insert ('' for non-printing
 *  keys and with Ctrl/Alt/Meta held). */
export interface AppKeyEvent {
  key: string;
  text: string;
  shift: boolean;
  ctrl: boolean;
  alt: boolean;
  meta: boolean;
}

export interface PopupOptions {
  width: number;
  height: number;
  paint(ctx: Ctx, w: number, h: number): void;
  pointer?(ev: AppPointerEvent): void;
  /** Return true when handled. Escape always closes the popup. */
  key?(ev: AppKeyEvent): boolean;
}

export interface PopupHandle {
  close(): void;
  invalidate(rect?: Rect): void;
}

/** The handle an app gets in create(). */
export interface WindowApi {
  /** Content size (excluding the title bar). */
  readonly width: number;
  readonly height: number;
  /** Buffer scale (integer device pixel ratio). */
  readonly scale: number;
  /** Has keyboard focus. */
  readonly focused: boolean;
  readonly maximized: boolean;
  /** In the fullscreen state (no title bar: the content is the whole surface). */
  readonly fullscreen: boolean;
  /** Repaint a content rect, or everything. */
  invalidate(rect?: Rect): void;
  /** While on, tick(ms) runs before every frame (frame-callback paced). */
  animate(on: boolean): void;
  /** Cursor over the content (ignored elsewhere): a shape, or a
   *  client-drawn image. */
  cursor(name: CursorName | CursorImage): void;
  /** Open an xdg_popup at content (x, y). One at a time. */
  popup(x: number, y: number, opts: PopupOptions): PopupHandle;
  closePopup(): void;
  /** Start an interactive move (from a pointer press, or a touch point
   *  still down: the compositor then cancels the touch sequence). */
  move(): void;
  /** The client holds a wl_touch (the seat has touch): fingers arrive as
   *  touch points, else the page plays them as the pointer. */
  readonly touch: boolean;
  /** Toggle maximized. */
  maximize(): void;
  /** xdg_toplevel.set_maximized / unset_maximized. */
  setMaximized(on: boolean): void;
  /** xdg_toplevel.set_fullscreen / unset_fullscreen; the configure that
   *  follows resizes the window and repaints it. */
  setFullscreen(on: boolean): void;
  /** xdg_toplevel.set_minimized (the page restores it, from its docks). */
  minimize(): void;
  /** A oneshot zwp_locked_pointer_v1 over a content rect (or the whole
   *  surface); the app hears locked(true) when it applies, locked(false)
   *  when it ends (Esc, focus loss, unlockPointer). False when unsupported
   *  or already asked. */
  lockPointer(rect?: Rect): boolean;
  unlockPointer(): void;
  close(): void;
  setTitle(title: string): void;
}

/** What create() returns. */
export interface AppInstance {
  paint(ctx: Ctx, w: number, h: number): void;
  pointer?(ev: AppPointerEvent): void;
  /** Raw touch (multi-touch). Each point that goes down on the content is
   *  offered here first: return true from its 'down' to take it (its moves,
   *  up or cancel then come here too); a point not taken is the toolkit's —
   *  the first finger down plays the pointer (AppPointerEvent.touch), the
   *  others are dropped. Without touch(), every finger is that pointer. */
  touch?(ev: AppTouchEvent): boolean | void;
  key?(ev: AppKeyEvent): void;
  tick?(ms: number): void;
  focus?(on: boolean): void;
  /** zwp_relative_pointer_v1.relative_motion (keeps coming while locked). */
  relative?(dx: number, dy: number): void;
  /** The pointer lock from lockPointer applied (true) or ended (false). */
  locked?(on: boolean): void;
  /** wp_presentation_feedback for each of the window's commits: when it
   *  reached the screen (the presentation clock, in ms) and the refresh
   *  period (ms, 0 = unknown), or discarded. */
  presented?(fb: { ms: number; refresh: number; discarded: boolean }): void;
  /** The toplevel's input region in surface coordinates (title bar
   *  included), asked before every commit and re-sent when it changes:
   *  pointer input outside it falls through to what is below. */
  inputRegion?(w: number, h: number): { add: readonly Rect[]; subtract?: readonly Rect[] };
  closed?(): void;
  /** The text cursor, for apps with `textInput` (where the IME and the
   *  on-screen keyboard's candidates go). */
  caret?(): Rect;
}

/** Live numbers the session samples twice a second. */
export interface Metrics {
  fps: number;
  commitsPerSec: number;
  kibPerSec: number;     // damage clients declared
  readKibPerSec: number; // read by handle from shared memory
  clients: number;
  windows: number;
  scale: number;
}

/** What apps may ask of the page. */
export interface Services {
  metrics?(): Metrics;
  /** Focus the app's window, or launch it. */
  open?(id: string): void;
}

export interface AppModule {
  id: string;
  name: string;
  /** One line for launchers. */
  blurb: string;
  width: number;
  height: number;
  minWidth?: number;
  minHeight?: number;
  /** No decorations: the app paints every pixel, alpha included. */
  frameless?: boolean;
  /** Initial title (default: name). */
  title?: string;
  /** Takes text: enables zwp_text_input_v3 while focused, so touch devices
   *  show the on-screen keyboard (others don't) and composed text arrives as
   *  key events with `text` set. */
  textInput?: boolean;
  create(win: WindowApi, services: Services): AppInstance;
}

/** The apps' palette (follows the page's theme). */
export interface Theme {
  bg: string;
  chrome: string;
  fg: string;
  muted: string;
  faint: string;
  border: string;
  hover: string;
  accent: string;
  card: string;
  dark: boolean;
}
