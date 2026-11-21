// wland engine: the compositor half of wland with no DOM.
//
// Loads the core wasm (core/src/wasm.zig is its ABI), owns the link to the
// relay (protocol/STREAM.md frames) and the buffer source (EngineOptions.
// buffers), and turns everything the compositor does into plain-data events;
// takes plain-data calls for input and output state. It touches no DOM and no
// window globals, so it runs on a page, in a Worker or in Node. The types
// below are the contract; the rules that matter:
//
// - Every event and every call argument is structured-cloneable. A Worker
//   adapter posts events across and turns calls into messages; nothing here
//   returns a value a caller depends on.
// - A commit event's `pixels` is a VIEW (into the link message, into wasm
//   memory or into the staging buffer), valid only while the event is being
//   dispatched. Consume it synchronously (paint, upload, or copy); a Worker
//   adapter copies it and may transfer the copy. No second copy is made on
//   the same-thread path. The same goes for a GPU commit's `image` (what
//   EngineOptions.gpu resolved): draw it during dispatch; the ACK that lets
//   the guest reuse the resource follows the dispatch.
// - Events raised while the core is running (role changes, titles, grabs...)
//   are queued and dispatched as soon as the wasm call returns, so a handler
//   may call back into the engine without re-entering the core. Order is
//   preserved, and a commit is always dispatched after the events of the WIRE
//   frames that precede it.
// - Link messages are processed strictly in order, one at a time. A message
//   that arrives while another is being processed (a handler that makes the
//   link deliver synchronously, or a pending buffer-source promise) waits in
//   the inbox.
// - A link may open again after it closed (createStreamLink over a stream of
//   connections). Every open starts a fresh compositor; every close first
//   ends each app conn of the old link the way a relay CONN_CLOSE would (the
//   relay has dropped them), so consumers see a 'disconnect' per conn before
//   'close' and keep no state for apps that are gone.
// - dispose() ends it all for good: the link is closed, every buffer token
//   closed, and nothing is emitted or sent afterwards.

export { createWsLink } from './link-ws.ts';
export { createStreamLink } from './link-stream.ts';
export type { ByteStream, StreamSource } from './link-stream.ts';

// --- the contract ---------------------------------------------------------
//
// The engine/view boundary is message-passable: every Event below and every
// argument of every Engine call is structured-cloneable plain data, and no
// call returns a value a caller depends on. Running the engine in a Worker is
// an adapter: post events to the page, post calls to the worker.
//
// Pixel lifetime: CommitEvent.pixels is a VIEW into the link message, into
// wasm memory or into the engine's staging buffer. It is valid only while the
// event is being dispatched (inside onEvent). Consume it synchronously — paint
// it, upload it, or copy it. A Worker adapter copies it (`ev.pixels.slice()`)
// and may transfer the copy. Everything else in an event (including `damage`)
// is owned by the event. Read the pixels BEFORE calling back into the engine
// from the same dispatch: any engine call (input, focus, output...) may run
// the core and grow its memory, which detaches a `pixels` that views wasm
// memory (BUFFER_LZ commits, and buffer-source commits with `rgba`) — it then
// reads as empty. (createWland's view presents before it focuses a new
// window for that reason.)

/** Surface role: 0 none (unmapped), 1 toplevel, 2 subsurface, 3 cursor
 *  image, 4 popup, 5 dnd icon. */
export type Role = 0 | 1 | 2 | 3 | 4 | 5;

/** The transport to the relay. `createWsLink` is the WebSocket one. */
export interface Link {
  /** Begin connecting; drive the callbacks from then on. */
  start(callbacks: LinkCallbacks): void;
  /** Engine → relay: packed STREAM frames (protocol/STREAM.md). The bytes are
   *  a fresh copy the link may keep or transfer. */
  send(bytes: Uint8Array<ArrayBuffer>): void;
  /** Bytes queued but not yet sent; pointer motion is held back above 256 KiB. */
  readonly bufferedAmount: number;
  /** End for good (Engine.dispose calls it): close the connection, open no
   *  other, and call no callback from then on. Optional for a link of your
   *  own: the engine ignores its callbacks after dispose either way. */
  close?(): void;
}

/** A Link that can always be ended (what createWsLink and createStreamLink
 *  return). */
export type ClosableLink = Link & { close(): void };

/** Open → messages → close, in that order. A link MAY open again after it
 *  closed (createStreamLink over several streams); each open starts a fresh
 *  compositor in the engine, and before each 'close' event the engine ends
 *  the old link's app conns ('disconnect' per conn), since the relay dropped
 *  them. onClose may also come without an onOpen (the connection failed). */
export interface LinkCallbacks {
  onOpen(): void;
  /** One or more packed STREAM frames. */
  onMessage(data: ArrayBuffer): void;
  onClose(info: { takenOver: boolean }): void;
  onError(detail: string): void;
}

export interface EngineOptions {
  link: Link;
  /** Every event, in order. Events raised while the core runs are queued and
   *  dispatched when it returns, so a handler may call back into the engine.
   *  A throwing handler is reported asynchronously and does not stop dispatch. */
  onEvent(event: Event): void;
  /** The core: a URL, the bytes, or a compiled module. Defaults to
   *  `wland.wasm` next to this module (bundlers emit it as an asset). A
   *  `file:` URL (the default in Node) is read with node:fs; others are
   *  fetched. */
  wasm?: string | URL | BufferSource | WebAssembly.Module;
  /** Resolves the buffer handles a relay running a handle backend (kwshm,
   *  procfd) announces; see HandleSource. Not needed with the copy backend
   *  (the native server: pixels travel in the stream). Without it, every
   *  HANDLE_OPEN raises an 'error' event and the commits that use the handle
   *  are acknowledged without presenting. */
  buffers?: HandleSource;
  /** Resolves the GPU resources a relay names instead of shipping pixels
   *  (COMMIT kind virtgpu; wlandr doesn't emit it yet); see GpuSource.
   *  Without it, the first such commit raises an 'error' event; every one
   *  is still dispatched (format 'gpu', `image` null: the surface
   *  is laid out, its content not updated) and acknowledged. */
  gpu?: GpuSource;
  /** Deliver buffer-source commits as 'rgba' (packed per damage rect, the
   *  layout BUFFER frames carry) instead of 'bgra'/'bgrx' rows: the core's
   *  `wland_swizzle` converts them while staging (alpha forced for XRGB), so
   *  a 2D canvas paints them with putImageData and nothing else. For a view
   *  that presents with 2D only (createWland sets it when its view has no
   *  WebGL). Default false: rows as the client wrote them, which a GL
   *  presenter uploads without any per-pixel CPU work. */
  rgba?: boolean;
}

// --- buffer handles (STREAM.md v2: HANDLE_OPEN / HANDLE_CLOSE / COMMIT / ACK)

/** A buffer handle the relay announced (STREAM.md HANDLE_OPEN), decoded by
 *  the core. It names `size` bytes of shared memory, handle bytes
 *  0 … size−1. Sizes and offsets are exact integers (< 2^53). */
export type BufferHandle =
  /** An unkernel kwshm guest export: `id` is what KWSHM_IOC_EXPORT returned
   *  in the guest (unkernel: `vm.shm.openId(id)`); handle byte i = export
   *  byte i. */
  | { kind: 'kwshm'; id: number; size: number }
  /** Debug/tests, same machine and user as the relay: handle byte i is byte
   *  `offset + i` of the file open as `/proc/<pid>/fd/<fd>`. Open that path
   *  in open() and keep the fd until close(). */
  | { kind: 'procfd'; pid: number; fd: number; offset: number; size: number };

/**
 * The embedder's access to buffer memory the relay shares by handle (EngineOptions.buffers). The engine reads committed
 * pixels in place through it instead of receiving them in the stream.
 *
 * Calls: always from the engine's own thread, while it processes a link
 * message, one at a time, never re-entrantly.
 *
 * - open(): when HANDLE_OPEN arrives. Return a token (any value) that the
 *   other calls get back, or throw/reject: the handle is then broken, an
 *   'error' event reports it, and commits that use it are acknowledged
 *   without presenting.
 * - read(): while processing a COMMIT that names the handle. Copy
 *   `dst.length` bytes starting at handle byte `offset` into `dst`, the
 *   engine's staging memory. Always in range: offset + dst.length ≤ size.
 *   Per COMMIT: one call per damage rect's span (its first to its last
 *   byte, the rows between whole; spans that overlap or lie within 4 KiB
 *   merge) — or a single call over all of them once the source has answered
 *   any read with a promise (each read is then a round trip).
 *   Throw/reject if the memory is gone (only happens while the app's
 *   connection is ending): that commit is skipped and acknowledged.
 * - close(): on HANDLE_CLOSE, for every handle of a connection when the app
 *   disconnects, and for all handles when the link closes — exactly once per
 *   token open() returned, and never while a read() of that token is pending
 *   (a close that falls due meanwhile, e.g. the link closing, waits until the
 *   read's promise settles). Never throws, also when the memory is already gone
 *   (export released, process exited); fire-and-forget any async work. Must
 *   not disturb other tokens: the same memory may be open under two handles.
 *
 * Sync or async: open() and read() may return a Promise. While one is
 * pending the engine processes no further link frames (later frames and
 * messages queue, in order; input calls carry on, tick() ships motion but
 * fires no frame callbacks), so ordering is kept. A plain return value takes
 * the synchronous path: no promise is made and nothing is copied twice.
 * Prefer synchronous: each pending promise stalls presentation. With
 * unkernel:
 *   - kernel on the engine's thread (inline mode, or the engine running in
 *     the kernel's worker): open = check the export exists (a guest export's
 *     page list is at the host before its id can arrive); read = copy the
 *     page runs into `dst` synchronously (kwshm's `views()` are scattered page
 *     runs, valid only until the kernel runs again — use them inside read()
 *     and keep nothing). A token must stay bound to its export: once the
 *     guest releases it, read() fails rather than resolving the id again.
 *   - kernel in a worker, engine on the page: the host only gets copies,
 *     asynchronously (`ShmFile.read()` resolves when the kernel next yields):
 *     open = `vm.shm.openId(id)`, read = `dst.set(await file.read(offset,
 *     dst.length))`.
 * No change notification and no refresh: the engine reads at commit time, and
 * a handle's size never changes (the relay opens a new handle instead).
 */
export interface HandleSource<T = any> {
  open(handle: BufferHandle, conn: number): T | Promise<T>;
  read(token: T, offset: number, dst: Uint8Array): void | Promise<void>;
  close(token: T): void;
}

// --- GPU buffers (STREAM.md COMMIT kind virtgpu) ---------------------------

/** A GPU buffer the relay named instead of shipping its pixels (STREAM.md
 *  COMMIT, buffer kind virtgpu), decoded by the core: a resource the
 *  embedder's renderer holds that a client rendered into. */
export interface GpuRef {
  kind: 'virtgpu';
  /** The resource id: whatever the embedder's renderer and its guest side
   *  agree on (e.g. a virgl resource id). The guest may reuse an id once
   *  the resource is gone, which never happens before this commit's ACK. */
  resource: number;
  /** The wl_buffer's size in buffer px (what the surface shows). */
  width: number;
  height: number;
  /** DRM fourcc, e.g. 0x34325241 ARGB8888 'AR24', 0x34325258 XRGB8888
   *  'XR24', 0x34324241 ABGR8888 'AB24', 0x34324258 XBGR8888 'XB24'.
   *  X formats are opaque: their alpha byte is undefined. */
  format: number;
  /** zwp_linux_buffer_params_v1 flags: 1 y_invert (row 0 is the bottom),
   *  2 interlaced, 4 bottom_first. */
  flags: number;
  /** Plane 0's offset and stride as the client gave them (informational). */
  offset: number;
  stride: number;
  /** DRM format modifier; 0x00ffffffffffffffn (DRM_FORMAT_MOD_INVALID) =
   *  the driver's implicit layout; 0n = LINEAR. */
  modifier: bigint;
}

/**
 * The embedder's access to GPU buffers (EngineOptions.gpu): turns a GpuRef
 * into something its consumers draw — for createWland's view a
 * CanvasImageSource (an ImageBitmap, OffscreenCanvas, canvas or VideoFrame:
 * WebGL textures can't be shared across contexts, images can), for
 * wland/headless an RgbaImage.
 *
 * - resolve(): while the engine processes the COMMIT naming the resource,
 *   from its own thread, one at a time. Return the resource's CURRENT
 *   content (what the guest rendered before this commit), or null to show
 *   nothing new (the surface keeps its last content). Throwing counts as
 *   null and is logged. May return a Promise: the engine then processes no
 *   further link frames until it settles (as with HandleSource), so order
 *   holds; prefer synchronous.
 * - The result rides the commit event (`image`). Consumers draw it during
 *   that event's dispatch and never keep it; after the dispatch the engine
 *   calls release(image) (if given) and then ACKs the commit, which lets the
 *   relay hand the buffer back to the client — so the page must not read
 *   the resource for this commit after resolve()'s result has been drawn.
 *   Copy-on-commit: nothing samples the resource later.
 * - Orientation: the image's row 0 is the buffer's top row (flip a GL
 *   framebuffer's bottom-up rows, and honour `flags & 1`, y_invert, here).
 *   Size: width × height of the ref (a different size is scaled to it).
 *   Alpha: drawn as the browser treats the image (an ImageBitmap's alpha is
 *   straight to a 2D canvas); X formats must come out opaque.
 */
export interface GpuSource<T = unknown> {
  resolve(ref: GpuRef, commit: { conn: number; surface: number; damage: Int32Array }): T | null | Promise<T | null>;
  /** The image resolve() returned has been drawn (its commit's dispatch
   *  returned): close it (ImageBitmap/VideoFrame) or recycle it. Not called
   *  for an image whose commit was never dispatched (the link closed
   *  while the promise was pending) — that one is simply dropped. */
  release?(image: T): void;
}

export interface EngineStats {
  bytesIn: number;
  bytesOut: number;
  /** Commit events emitted (presented buffer frames). */
  commits: number;
  /** pointerMotion calls received. */
  motions: number;
  /** Coalesced motions actually sent to the core. */
  sentMotions: number;
  /** Ticks where a pending motion was held back by link backpressure. */
  backpressured: number;
}

export interface Engine {
  /** Core version (`wland_version`). */
  readonly version: number;
  /** Cumulative counters; a plain object (a Worker adapter posts snapshots). */
  readonly stats: Readonly<EngineStats>;

  /** Start the link. Call once, after wiring onEvent's consumers. */
  start(): void;
  /** End for good: close the link (Link.close), close every buffer token
   *  (HandleSource.close, once each, as usual), emit and send nothing from
   *  then on; every call becomes a no-op. No 'disconnect'/'close' events:
   *  whoever disposes is tearing its consumers down too. Safe inside a
   *  dispatch, and to call twice. */
  dispose(): void;

  // --- output (may be called before the link opens; re-applied on open) ---
  /** Device pixel ratio: integer wl_output scale (clamped 1..4) and the
   *  fractional preferred scale in 120ths. */
  setScale(scale: number, scale120: number): void;
  /** The output (desktop) size in logical px; maximize and fullscreen fill it. */
  setOutput(width: number, height: number): void;
  /** Hidden tab: suspends mapped toplevels. */
  setSuspended(suspended: boolean): void;
  /** Frame clock (ms): what was committed since the last tick is now on
   *  screen. Ends presentation feedback (wp_presentation: presented or
   *  discarded), fires frame callbacks and ships coalesced motion. Drive
   *  it from the host's presentation (requestAnimationFrame). Frame
   *  callbacks are the engine's to fire only on stream links (STREAM.md
   *  "Frame callbacks"); while a buffer-source promise is pending nothing
   *  is presented: feedback and frame callbacks wait for a later tick.
   *
   *  `refresh`: pass it when `time` is a display frame's timestamp on
   *  the engine's performance.now() clock (rAF's argument; an engine in a
   *  worker has its own time origin: shift `time` by the difference of
   *  the two `performance.timeOrigin`s) — the display's frame interval in
   *  ms, 0 while not known. Feedback then says `vsync`,
   *  carries the interval, and is dated to the frame's start (the relay
   *  subtracts how long ago that was). Omit it for a clock that drives no
   *  display (wland/headless's timer): no vsync, refresh 0, dated to the
   *  tick. */
  tick(time: number, refresh?: number): void;

  // --- input (dropped while the link is not open). Coordinates are
  // surface-local logical px; times are ms. ---
  /** Coalesced: only the newest position is kept until tick() or the next
   *  order-sensitive pointer call; the relative parts add up meanwhile.
   *  `relative` (zwp_relative_pointer_v1) is the movement behind it: pass
   *  it with every motion, also while the pointer is locked (then x, y stay
   *  where the lock froze them and only the relative motion reaches the
   *  app). */
  pointerMotion(conn: number, time: number, x: number, y: number, relative?: RelativeMotion): void;
  pointerEnter(conn: number, surface: number, x: number, y: number): void;
  pointerLeave(conn: number): void;
  /** button: linux evdev code (BTN_LEFT 0x110, BTN_RIGHT 0x111, BTN_MIDDLE 0x112). */
  pointerButton(conn: number, time: number, button: number, pressed: boolean): void;
  /** axis 0 vertical, 1 horizontal; value in surface units; value120 high-res
   *  wheel steps (120 per detent). */
  pointerAxis(conn: number, time: number, axis: 0 | 1, value: number, value120: number): void;
  keyboardEnter(conn: number, surface: number): void;
  keyboardLeave(conn: number): void;
  /** code: linux evdev keycode. */
  key(conn: number, time: number, code: number, pressed: boolean): void;
  /** The browser locked its pointer for the lock a 'pointer-lock' event
   *  asked for (pointerlockchange to that surface's element): the app is
   *  told `locked`. Report only grants of the lock asked for last. */
  pointerLockGranted(conn: number, surface: number): void;
  /** The browser's pointer lock ended without a 'pointer-lock' release
   *  asking for it (Esc, the tab lost focus): the app is told `unlocked`. A
   *  persistent lock stays wanted (no new event): request it again at the
   *  next user gesture on its surface. */
  pointerLockLost(conn: number): void;
  /** zwp_text_input_v3 preedit (cursor at the end); '' clears it. */
  textInputPreedit(conn: number, text: string): void;
  textInputCommit(conn: number, text: string): void;

  // --- window management ---
  /** Outside click while a popup is up → xdg_popup.popup_done. */
  popupDismiss(conn: number, surface: number): void;
  /** xdg_toplevel.configure with this size (clamped to the app's hints).
   *  Ignored while the window is maximized or fullscreen. */
  requestResize(conn: number, surface: number, width: number, height: number): void;
  /** Maximize / unmaximize a toplevel from the embedder's side (its UI):
   *  the configure the app's own request would get, and a 'maximize' event. */
  setMaximized(conn: number, surface: number, maximized: boolean): void;
  /** Put a toplevel in or out of fullscreen from the embedder's side (a key
   *  binding, the browser's own fullscreen ending): a configure of the
   *  output's size with the fullscreen state (or back to what it was), and
   *  a 'fullscreen' event. */
  setFullscreen(conn: number, surface: number, fullscreen: boolean): void;
  /** Minimize (hide) or restore a mapped toplevel — restoring is only ever
   *  the embedder's: xdg_toplevel has set_minimized and no way back. A
   *  'minimize' event follows; see MinimizeEvent. */
  setMinimized(conn: number, surface: number, minimized: boolean): void;
  /** During a drag ('drag-start'): the surface under the pointer (0, 0 =
   *  none), then dragDrop or dragCancel exactly once. */
  dragMotion(conn: number, surface: number, time: number, x: number, y: number): void;
  dragDrop(): void;
  dragCancel(): void;
}

// --- events ---------------------------------------------------------------

export type Event =
  | OpenEvent | ErrorEvent | CloseEvent | LogEvent
  | SurfaceEvent | CommitEvent | DestroyEvent | DisconnectEvent
  | TitleEvent | CursorEvent | TextInputEvent | InputRegionEvent | PointerLockEvent
  | MoveEvent | ResizeEvent | MaximizeEvent | FullscreenEvent | MinimizeEvent | DragStartEvent | DragEndEvent;

/** The link is up and the compositor initialised; input calls work now. */
export interface OpenEvent { type: 'open' }
export interface ErrorEvent { type: 'error'; detail: string }
/** The link closed. takenOver: another tab claimed the session. Every app
 *  conn of the link got its 'disconnect' first. A stream link over an
 *  iterable source may 'open' again (a fresh compositor, no apps yet). */
export interface CloseEvent { type: 'close'; takenOver: boolean }
/** Wire-level debug line (every decoded message). */
export interface LogEvent { type: 'log'; line: string }

/** A surface's role was assigned or changed (None = unmapped). */
export interface SurfaceEvent {
  type: 'surface';
  conn: number;
  surface: number;
  role: Role;
  /** The toplevel at the top of its parent chain (itself if none). */
  root: number;
}

/** Pixel formats a commit can carry ('gpu': none — see CommitEvent.gpu):
 *  - 'rgba': canvas-ready RGBA, packed per damage rect: BUFFER frames (copy
 *    backend), or buffer-source commits with EngineOptions.rgba (swizzled by
 *    the core's `wland_swizzle`). Alpha already forced opaque for xrgb.
 *  - 'bgra' (wl_shm ARGB8888) / 'bgrx' (XRGB8888): wl_shm memory as the
 *    client wrote it, read through the buffer source: bytes B, G, R, A|X per
 *    pixel, rows `stride` bytes apart. 'bgra' alpha is premultiplied; 'bgrx'
 *    X is undefined — present it as 255. Presenters keep the copy path's
 *    alpha policy: bgrx → opaque, bgra alpha passed through unchanged (the
 *    view's GL presenter swaps channels and forces alpha in its shader; its
 *    2D presenter swizzles in JS — normally it gets 'rgba' instead, see
 *    EngineOptions.rgba). */
export type PixelFormat = 'rgba' | 'bgra' | 'bgrx' | 'gpu';

/** A rectangle in a surface's local logical px. */
export interface WindowGeometry { x: number; y: number; width: number; height: number }

/** A wl_surface.commit that latched new pixels. */
export interface CommitEvent {
  type: 'commit';
  conn: number;
  surface: number;
  role: Role;
  root: number;
  /** Position relative to the root's origin (subsurfaces, popups), logical px. */
  x: number;
  y: number;
  /** The window (`root`, a toplevel) is maximized / fullscreen /
   *  minimized as of this commit (see the 'maximize', 'fullscreen' and
   *  'minimize' events). Carried by every commit because an app can map in
   *  any of these states, before its window existed for the event. */
  maximized: boolean;
  fullscreen: boolean;
  minimized: boolean;
  /** The window geometry of `root`, in the root surface's local logical px:
   *  the box the window is placed, sized and maximized by (what
   *  xdg_toplevel.configure sizes and requestResize mean). It is what the
   *  app set (xdg_surface.set_window_geometry: its frame, shadows left
   *  outside), else the bounds of the toplevel and its subsurfaces — so it
   *  can change with any commit in the window. Width 0: not known yet. */
  geometry: WindowGeometry;
  /** Buffer size, buffer px. */
  width: number;
  height: number;
  /** Surface-local size, logical px: the CSS box (viewport destination, else
   *  buffer / buffer scale). Pointer coordinates are in this space. */
  logicalWidth: number;
  logicalHeight: number;
  format: PixelFormat;
  /** Bytes per row of `pixels` for 'bgra'/'bgrx'; 0 for 'rgba' (packed per
   *  rect, no common stride). */
  stride: number;
  /** Damage rects in buffer px, [x, y, w, h] per rect. Owned by the event. */
  damage: Int32Array;
  /** A VIEW valid only during dispatch, and only until the dispatch calls
   *  back into the engine (see "Pixel lifetime" at the top).
   *  - 'rgba': the damaged pixels, packed: each rect's rows tight (w*4
   *    bytes), rects concatenated in `damage` order.
   *  - 'bgra'/'bgrx': the whole buffer's rows — pixel (x, y) is the 4 bytes
   *    at `y * stride + x * 4`, length ≥ (height − 1) * stride + width * 4 —
   *    but only bytes inside the damage rects are defined (a Worker adapter
   *    need copy only the damage's bounding rows).
   *  - 'gpu': empty; the content is `image`. */
  pixels: Uint8Array;
  /** format 'gpu': the GPU buffer the relay named (STREAM.md COMMIT kind
   *  virtgpu). */
  gpu?: GpuRef;
  /** format 'gpu': what EngineOptions.gpu resolved `gpu` to, valid only
   *  during dispatch (draw it, don't keep it); null without a resolver or
   *  when it found nothing (keep showing the last content). */
  image?: unknown;
}

export interface DestroyEvent { type: 'destroy'; conn: number; surface: number }
/** The app hung up; drop everything for this conn. */
export interface DisconnectEvent { type: 'disconnect'; conn: number }
export interface TitleEvent { type: 'title'; conn: number; surface: number; title: string }
/** The pointer image `conn` set while its surface holds the pointer; the
 *  last of these wins until the pointer leaves the client's surfaces.
 *  - wp_cursor_shape: `cursor` is a CSS cursor name, `surface` 0.
 *  - wl_pointer.set_cursor with a surface: `surface` is the cursor surface
 *    (role 3); the image is its committed buffer (its commit events, also
 *    every later one: animated cursors), the hotspot `hotspotX/Y` in its
 *    surface-local logical px. `cursor` is 'default', what to show if you
 *    don't draw the image. Re-sent when the hotspot moves; a cursor surface
 *    without a buffer (yet, or any more) or destroyed reads as hidden.
 *  - set_cursor NULL: `cursor` 'none' (hidden), `surface` 0.
 *  - the pointer left: `cursor` '' (default), `surface` 0. */
export interface CursorEvent {
  type: 'cursor';
  conn: number;
  cursor: string;
  surface: number;
  hotspotX: number;
  hotspotY: number;
}
/** zwp_text_input_v3 enabled/disabled; x/y/width/height is the surface-local
 *  text cursor rect (where an IME candidate window belongs). */
export interface TextInputEvent {
  type: 'text-input';
  conn: number;
  active: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
}
/** A commit changed where a surface takes pointer input
 *  (wl_surface.set_input_region). The embedder picks, so it applies it: a
 *  point outside the region does not hit the surface and falls through to
 *  whatever is below. `region`: disjoint [x, y, w, h] rects in surface-local
 *  logical px (owned by the event; they may reach past the surface — clip
 *  to it; empty = no input at all), or null = the whole surface, which is
 *  also what a surface that never got this event has. See inRegion. */
export interface InputRegionEvent { type: 'input-region'; conn: number; surface: number; region: Int32Array | null }
/** The pointer lock `conn` wants changed (zwp_pointer_constraints_v1
 *  lock_pointer; the core decides when it applies: the surface holds the
 *  pointer, which is inside the lock's region). `surface`: lock the
 *  browser's pointer to that surface (Element.requestPointerLock on its
 *  hit target — browsers grant it only during or shortly after a user
 *  gesture, so retry at the next press on the surface while it is still
 *  wanted) and report the grant with pointerLockGranted, a loss with
 *  pointerLockLost. 0: the lock is not wanted any more — exit the
 *  browser's pointer lock (no report needed). */
export interface PointerLockEvent { type: 'pointer-lock'; conn: number; surface: number }
/** xdg_toplevel.move: start an interactive move grab. */
export interface MoveEvent { type: 'move'; conn: number; surface: number }
/** xdg_toplevel.resize: edges bitmask 1 top, 2 bottom, 4 left, 8 right. */
export interface ResizeEvent { type: 'resize'; conn: number; surface: number; edges: number }
/** The toplevel was maximized or unmaximized (its request or setMaximized):
 *  a maximized window's box sits at the output's origin and fills it. It
 *  can also be fullscreen, which wins while it lasts. */
export interface MaximizeEvent { type: 'maximize'; conn: number; surface: number; maximized: boolean }
/** The toplevel went fullscreen or back (xdg_toplevel.set_fullscreen /
 *  unset_fullscreen or setFullscreen): its box fills the output, above the
 *  other windows, centred on black when it is smaller (the spec's border
 *  fill), clipped when larger. Back from fullscreen it is maximized again
 *  if it still is (CommitEvent.maximized), else where it was. Move/resize
 *  requests are ignored meanwhile. */
export interface FullscreenEvent { type: 'fullscreen'; conn: number; surface: number; fullscreen: boolean }
/** The toplevel was minimized (xdg_toplevel.set_minimized or setMinimized)
 *  or restored (setMinimized(…, false) — the app has no way back). The core
 *  has already taken the pointer and keyboard from it (and ended a pointer
 *  lock, and dismissed its popups): hide its window and hand keyboard focus
 *  to another one. Restored: show it, raise it, focus it. While minimized
 *  its frame callbacks wait (stream links; over a WebSocket the relay keeps
 *  firing them), its presentation feedback is discarded and a v6 client is
 *  `suspended`. */
export interface MinimizeEvent { type: 'minimize'; conn: number; surface: number; minimized: boolean }
/** wl_data_device.start_drag: a dnd session began; icon = icon surface or 0.
 *  Drive it with dragMotion/dragDrop/dragCancel until 'drag-end'. */
export interface DragStartEvent { type: 'drag-start'; conn: number; surface: number; icon: number }
/** The dnd session ended (dropped, cancelled, or the source died). */
export interface DragEndEvent { type: 'drag-end' }

/** A motion's relative part (zwp_relative_pointer_v1.relative_motion):
 *  the movement in logical px, unclipped by surface or screen edges and
 *  undisturbed by a lock or confinement (the browser's movementX/Y).
 *  `dxUnaccel`/`dyUnaccel` default to dx/dy (the browser has one stream);
 *  `time` is µs on the motion's clock (default: the motion's time × 1000). */
export interface RelativeMotion { dx: number; dy: number; dxUnaccel?: number; dyUnaccel?: number; time?: number }

/** Whether surface-local point (x, y) is in an input region
 *  (InputRegionEvent.region; null = the whole surface). Bounds against the
 *  surface itself are the caller's. */
export function inRegion(region: Int32Array | null, x: number, y: number): boolean {
  if (!region) return true;
  for (let i = 0; i + 3 < region.length; i += 4) {
    if (x >= region[i] && y >= region[i + 1] && x < region[i] + region[i + 2] && y < region[i + 1] + region[i + 3]) return true;
  }
  return false;
}

// --- implementation ---------------------------------------------------------

// wp_cursor_shape_device_v1.shape (1..34) → CSS cursor name. The enum was
// designed to mirror CSS, so most map 1:1. Shape 0 (the pointer left) maps
// to '' = default.
const CURSORS = [
  '', 'default', 'context-menu', 'help', 'pointer', 'progress',
  'wait', 'cell', 'crosshair', 'text', 'vertical-text',
  'alias', 'copy', 'move', 'no-drop', 'not-allowed',
  'grab', 'grabbing', 'e-resize', 'n-resize', 'ne-resize',
  'nw-resize', 's-resize', 'se-resize', 'sw-resize', 'w-resize',
  'ew-resize', 'ns-resize', 'nesw-resize', 'nwse-resize',
  'col-resize', 'row-resize', 'all-scroll', 'zoom-in', 'zoom-out',
];

const SURFACE_DESTROYED = 0xffffffff;
const BACKPRESSURE_BYTES = 256 * 1024;

// STREAM.md frame types the engine handles itself (the rest go to the core)
const FRAME_BUFFER = 0x02;
const FRAME_CONN_OPEN = 0x03;
const FRAME_CONN_CLOSE = 0x04;
const FRAME_BUFFER_LZ = 0x07;
const FRAME_HANDLE_OPEN = 0x08;
const FRAME_COMMIT = 0x0a;
const BUFFER_HEADER = 21; // type + conn + surface + width + height + n_rects
const NOTICE_WORDS = 14;  // wland_commit_notice's fixed words (wasm.zig)
const EMPTY = new Uint8Array(0);
const WL_SHM_ARGB8888 = 0;

const fixed = (v: number) => Math.round(v * 256); // wl_fixed 24.8
const thenable = <T>(v: T | PromiseLike<T>): v is PromiseLike<T> =>
  v !== null && typeof v === 'object' && typeof (v as PromiseLike<T>).then === 'function';

// The core's exports (core/src/wasm.zig): memory plus `wland_*` functions,
// every argument and result a wasm i32/u32 (or f64) number.
type CoreFn = (...args: number[]) => number;
interface CoreExports {
  memory: WebAssembly.Memory;
  [name: `wland_${string}`]: CoreFn;
}
type CoreImports = { env: Record<`js_${string}`, (...args: number[]) => void> };

/** A handle the relay announced: its token once open() returned one. */
interface HandleEntry { conn: number; size: number; token: unknown; ok: boolean }
/** A COMMIT being read through the buffer source. */
interface PendingCommit {
  conn: number; surface: number; serial: number;
  width: number; height: number; stride: number; format: number;
  damage: Int32Array; size: number;
}
/** A pending motion: the newest position, the relative parts summed. */
interface Motion { conn: number; time: number; x: number; y: number; dx: number; dy: number; dxu: number; dyu: number; utime: number }

export async function createEngine(options: EngineOptions): Promise<Engine> {
  const { link, onEvent } = options;
  if (!link) throw new Error('createEngine: options.link is required');
  if (typeof onEvent !== 'function') throw new Error('createEngine: options.onEvent is required');
  const buffers = options.buffers || null;
  const gpu = options.gpu || null;
  let gpuWarned = false; // the no-resolver error, once per link
  const wantRgba = !!options.rgba;

  const dec = new TextDecoder();
  const enc = new TextEncoder();
  const stats = { bytesIn: 0, bytesOut: 0, commits: 0, motions: 0, sentMotions: 0, backpressured: 0 };

  // output state, kept so it can be set before the link opens and re-applied
  // when it does (wland_init resets the compositor)
  const output = { scale: 1, scale120: 120, width: 0, height: 0, suspended: false };
  let live = false; // link open and compositor initialised
  let disposed = false;
  const conns = new Set<number>(); // app conns the core holds (CONN_OPEN seen, not yet closed)
  let ex: CoreExports; // wasm exports (core/src/wasm.zig)

  // --- event dispatch: queue while the core runs, drain when it returns ---
  const queue: Event[] = [];
  let depth = 0;
  let draining = false;
  // a throwing handler must not cut the dispatch short (or unwind the core):
  // report it asynchronously and carry on
  const dispatch = (ev: Event) => {
    try { onEvent(ev); } catch (e) { queueMicrotask(() => { throw e; }); }
  };
  const emit = (ev: Event) => {
    if (disposed) return;
    if (depth > 0 || draining) queue.push(ev);
    else dispatch(ev);
  };
  const log = (line: string) => emit({ type: 'log', line });
  function drain() {
    if (draining) return;
    draining = true;
    // handlers may call back in (run → drain is then a no-op) and append;
    // the loop picks those up in order
    for (let i = 0; i < queue.length; i++) dispatch(queue[i]);
    queue.length = 0;
    draining = false;
  }
  // every call into the core goes through here
  function run<A extends unknown[]>(fn: (...args: A) => unknown, ...args: A) {
    depth++;
    try { fn(...args); } finally { depth--; }
    if (depth === 0) {
      drain();
      if (inbox.length) pump(); // a message arrived while the core ran
    }
  }

  const str = (ptr: number, len: number) => dec.decode(new Uint8Array(ex.memory.buffer, ptr, len));

  // --- buffer handles (STREAM.md HANDLE_OPEN / HANDLE_CLOSE) ---------------
  // handle_id → {conn, size, token, ok}. ok = false: broken (never opened, or
  // its open failed); kept so COMMITs naming it are told apart from unknown
  // ones in the log and HANDLE_CLOSE can forget it.
  const handles = new Map<number, HandleEntry>();
  let gen = 0;       // link generation: bumped on close, voids pending promises
  let stall = false; // a buffer-source promise is pending: frames wait

  // The read whose promise is pending (frames stall meanwhile, so at most
  // one): its token is not closed under it — a close that comes meanwhile
  // (the link closing, dispose) waits until the read settles.
  let reading: { token: unknown; close: boolean } | null = null; // close: a close is waiting

  function closeToken(token: unknown) {
    if (reading && reading.token === token) { reading.close = true; return; }
    // exactly once per token open() returned; close never throws by contract
    try { buffers!.close(token); } catch (e) { emit({ type: 'error', detail: `buffer source close: ${e}` }); }
  }
  function broken(h: HandleEntry, handle: number, why: string) {
    h.ok = false;
    emit({ type: 'error', detail: `buffer handle ${handle} (conn ${h.conn}): ${why}` });
  }
  function closeHandles(match: (h: HandleEntry) => boolean) {
    for (const [id, h] of handles) {
      if (!match(h)) continue;
      handles.delete(id);
      if (h.ok) closeToken(h.token);
    }
  }

  // Called by the core while it processes HANDLE_OPEN: open the handle now
  // (a COMMIT naming it may follow in the same message). kind 1 kwshm (a =
  // export id), 2 procfd (a = pid, b = fd), 0 unusable (a = the raw kind).
  function handleOpen(conn: number, handle: number, kind: number, a: number, b: number, offset: number, size: number) {
    const old = handles.get(handle); // ids are never reused; if a relay does, the token still closes once
    if (old && old.ok) closeToken(old.token);
    const h: HandleEntry = { conn, size, token: undefined, ok: false };
    handles.set(handle, h);
    if (kind !== 1 && kind !== 2) return broken(h, handle, `unusable (kind ${a}, or bad handle bytes)`);
    if (!buffers) return broken(h, handle, `kind ${kind === 1 ? 'kwshm' : 'procfd'} from the relay, but this engine has no buffer source`);
    const desc: BufferHandle = kind === 1 ? { kind: 'kwshm', id: a, size } : { kind: 'procfd', pid: a, fd: b, offset, size };
    let r: unknown;
    try { r = buffers.open(desc, conn); } catch (e) { return broken(h, handle, `open failed: ${e}`); }
    if (!thenable(r)) { h.token = r; h.ok = true; return; }
    const g = gen;
    stall = true;
    r.then((token) => {
      if (g !== gen) { closeToken(token); return; } // the link closed meanwhile
      h.token = token;
      h.ok = true;
      resume();
    }, (e) => {
      if (g !== gen) return;
      broken(h, handle, `open failed: ${e}`);
      resume();
    });
  }

  const imports: CoreImports = {
    env: {
      js_send: (ptr, len) => {
        if (!live) return;
        stats.bytesOut += len;
        // a copy: links may queue or transfer it, wasm memory is reused
        link.send(new Uint8Array(ex.memory.buffer, ptr, len).slice());
      },
      // wasm passes u32 args as i32: 0xffffffff arrives as -1, hence >>> 0
      // (conn ids are u32 everywhere else: the frames, the caller's calls)
      js_log: (ptr, len) => log(str(ptr, len)),
      js_set_title: (conn, surface, ptr, len) =>
        emit({ type: 'title', conn: conn >>> 0, surface, title: str(ptr, len) }),
      js_conn_close: (conn) => {
        conn >>>= 0;
        conns.delete(conn);
        if (pending && pending.conn === conn) pending = null;
        closeHandles((h) => h.conn === conn);
        emit({ type: 'disconnect', conn });
      },
      js_surface_event: (conn, surface, value) => {
        conn >>>= 0;
        if (value >>> 0 === SURFACE_DESTROYED) emit({ type: 'destroy', conn, surface });
        else emit({ type: 'surface', conn, surface, role: value as Role, root: ex.wland_surface_root(conn, surface) });
      },
      js_cursor_shape: (conn, shape) =>
        emit({ type: 'cursor', conn: conn >>> 0, cursor: CURSORS[shape] ?? 'default', surface: 0, hotspotX: 0, hotspotY: 0 }),
      js_cursor_surface: (conn, surface, hotspotX, hotspotY) =>
        emit({ type: 'cursor', conn: conn >>> 0, cursor: surface ? 'default' : 'none', surface: surface >>> 0, hotspotX, hotspotY }),
      js_text_input: (conn, active, x, y, width, height) =>
        emit({ type: 'text-input', conn: conn >>> 0, active: active !== 0, x, y, width, height }),
      js_pointer_lock: (conn, surface) => emit({ type: 'pointer-lock', conn: conn >>> 0, surface: surface >>> 0 }),
      js_input_region: (conn, surface, infinite, ptr, n) =>
        emit({ type: 'input-region', conn: conn >>> 0, surface,
               region: infinite ? null : new Int32Array(ex.memory.buffer, ptr, n * 4).slice() }),
      js_interactive: (conn, surface, kind, value) => {
        conn >>>= 0;
        switch (kind) {
          case 0: emit({ type: 'move', conn, surface }); break;
          case 1: emit({ type: 'resize', conn, surface, edges: value }); break;
          case 2: emit({ type: 'maximize', conn, surface, maximized: true }); break;
          case 3: emit({ type: 'maximize', conn, surface, maximized: false }); break;
          case 4: emit({ type: 'drag-start', conn, surface, icon: value }); break;
          case 5: emit({ type: 'drag-end' }); break;
          case 6: emit({ type: 'fullscreen', conn, surface, fullscreen: true }); break;
          case 7: emit({ type: 'fullscreen', conn, surface, fullscreen: false }); break;
          case 8: emit({ type: 'minimize', conn, surface, minimized: true }); break;
          case 9: emit({ type: 'minimize', conn, surface, minimized: false }); break;
        }
      },
      js_handle_open: (conn, handle, kind, a, b, offset, size) =>
        handleOpen(conn >>> 0, handle >>> 0, kind, a >>> 0, b >>> 0, offset, size),
      // unknown, broken or another conn's: ignored (STREAM.md HANDLE_CLOSE)
      js_handle_close: (conn, handle) => {
        const h = handles.get(handle >>> 0);
        if (!h || h.conn !== conn >>> 0) return;
        handles.delete(handle >>> 0);
        if (h.ok) closeToken(h.token);
      },
    },
  };

  ex = await instantiate(options.wasm ?? new URL('wland.wasm', import.meta.url), imports);
  const version = ex.wland_version();

  // one reusable region of wasm memory for bytes JS hands the core (frame
  // spans, BUFFER_LZ input, COMMIT frames). Pointers survive memory.grow;
  // views do not, so callers take a fresh view after every call that may
  // allocate.
  let scratch = 0, scratchLen = 0;
  function toWasm(src: Uint8Array, start: number, end: number): number {
    const len = end - start;
    if (len > scratchLen) {
      if (scratch) ex.wland_free(scratch, scratchLen);
      scratchLen = Math.max(len, scratchLen * 2, 64 * 1024);
      scratch = ex.wland_alloc(scratchLen);
      if (!scratch) { scratchLen = 0; log('wland_alloc failed'); return 0; }
    }
    new Uint8Array(ex.memory.buffer, scratch, len).set(src.subarray(start, end));
    return scratch;
  }

  // --- commits -------------------------------------------------------------
  // The one place a commit event is built, for every pixel frame: BUFFER /
  // BUFFER_LZ ('rgba' packed per rect) and COMMIT (read through the buffer
  // source: 'bgra'/'bgrx' strided, or 'rgba' when options.rgba).
  function commit(conn: number, surface: number, width: number, height: number, format: PixelFormat,
    stride: number, damage: Int32Array, pixels: Uint8Array, extra?: { gpu: GpuRef; image: unknown }) {
    // surface sizes make up the window geometry read below
    ex.wland_note_buffer_size(conn, surface, width, height);
    // the commit's WIRE frame was processed first (STREAM.md ordering), so
    // these read the state this buffer belongs with
    let logicalWidth = ex.wland_surface_view_w(conn, surface);
    let logicalHeight = ex.wland_surface_view_h(conn, surface);
    if (!(logicalWidth > 0 && logicalHeight > 0)) {
      const s = ex.wland_surface_scale(conn, surface) || 1;
      logicalWidth = width / s;
      logicalHeight = height / s;
    }
    stats.commits++;
    const root = ex.wland_surface_root(conn, surface);
    const state = ex.wland_toplevel_state(conn, root); // bits: maximized, fullscreen, minimized
    const g = new Int32Array(ex.memory.buffer, ex.wland_window_geometry(conn, root), 4);
    emit({
      type: 'commit', conn, surface,
      role: ex.wland_surface_role(conn, surface) as Role,
      root,
      geometry: { x: g[0], y: g[1], width: g[2], height: g[3] },
      x: ex.wland_surface_abs_x(conn, surface),
      y: ex.wland_surface_abs_y(conn, surface),
      maximized: (state & 1) !== 0,
      fullscreen: (state & 2) !== 0,
      minimized: (state & 4) !== 0,
      width, height, logicalWidth, logicalHeight,
      format, stride, damage, pixels,
      ...extra,
    });
  }

  // BUFFER (0x02) at `base` of a DataView: canvas-ready RGBA packed per rect
  function commitBuffer(dv: DataView, base: number) {
    const conn = dv.getUint32(base + 1, true), surface = dv.getUint32(base + 5, true);
    const width = dv.getUint32(base + 9, true), height = dv.getUint32(base + 13, true);
    const n = dv.getUint32(base + 17, true);
    // rects sit at an arbitrary byte offset: copy them (tiny) into an
    // aligned array the event owns
    const damage = new Int32Array(n * 4);
    for (let i = 0; i < n * 4; i++) damage[i] = dv.getInt32(base + BUFFER_HEADER + i * 4, true);
    let len = 0;
    for (let i = 0; i < n; i++) len += damage[i * 4 + 2] * damage[i * 4 + 3] * 4;
    const pixOff = base + BUFFER_HEADER + n * 16;
    if (pixOff + len > dv.byteLength || damage.some((v, i) => i % 4 >= 2 && v <= 0)) {
      log(`bad BUFFER frame c${conn}s${surface}: ${n} rects, ${len} bytes`);
      return;
    }
    commit(conn, surface, width, height, 'rgba', 0, damage,
      new Uint8Array(dv.buffer, dv.byteOffset + pixOff, len));
  }

  // BUFFER_LZ: inflate inside wasm into a raw BUFFER frame (in wasm memory),
  // then present that. Synchronous, so ordering vs WIRE frames holds.
  function commitCompressed(bytes: Uint8Array, off: number, len: number) {
    const ptr = toWasm(bytes, off, off + len);
    if (!ptr) return;
    const out = ex.wland_decode_buffer(ptr, len);
    // read memory.buffer AFTER decode: growing memory replaces it
    if (out) commitBuffer(new DataView(ex.memory.buffer), out);
    else log('BUFFER_LZ decode failed');
  }

  // COMMIT (0x0a): decode in the core, read the damaged bytes through the
  // buffer source, present, ACK. Exactly one ACK per notice; a notice that
  // cannot be presented is ACKed right away.
  let stage = new Uint8Array(0); // handle reads land here; reused across commits
  let asyncSource = false;       // the source has answered a read with a promise
  let wstage = 0, wstageLen = 0; // wasm region for the rgba swizzle; reused

  const ack = (conn: number, serial: number) => run(ex.wland_commit_ack, conn, serial);

  function onCommit(bytes: Uint8Array, off: number, len: number) {
    const ptr = toWasm(bytes, off, off + len);
    const p = ptr ? ex.wland_commit_notice(ptr, len) : 0;
    if (!p) { log(`bad COMMIT frame (${len} bytes): not acked`); return; }
    const w = new Uint32Array(ex.memory.buffer, p, NOTICE_WORDS);
    const conn = w[0], surface = w[1], serial = w[2], kind = w[3], n = w[4];
    if (kind !== 1 && kind !== 2) return ack(conn, serial); // unknown kind / invalid: core logged why
    const damage = new Int32Array(n * 4);
    damage.set(new Int32Array(ex.memory.buffer, p + NOTICE_WORDS * 4, n * 4));
    if (kind === 2) {
      const ref: GpuRef = {
        kind: 'virtgpu', resource: w[5], width: w[6], height: w[7], format: w[8], flags: w[9],
        offset: w[10], stride: w[11], modifier: (BigInt(w[13]) << 32n) | BigInt(w[12]),
      };
      return gpuCommit(conn, surface, serial, ref, damage);
    }
    const handle = w[5], offset = w[6], width = w[7], height = w[8], stride = w[9], format = w[10];
    const h = handles.get(handle);
    if (!h || h.conn !== conn || !h.ok) {
      log(`COMMIT c${conn} serial ${serial}: handle ${handle} ${h && h.conn === conn ? 'broken' : 'not open'}, not presented`);
      return ack(conn, serial);
    }
    if (offset + stride * height > h.size) {
      log(`COMMIT c${conn} serial ${serial}: buffer past the end of handle ${handle}, not presented`);
      return ack(conn, serial);
    }
    const size = (height - 1) * stride + width * 4; // what pixel (x,y) indexing needs
    if (stage.length < size) {
      try {
        stage = new Uint8Array(Math.max(size, Math.ceil(stage.length * 1.5)));
      } catch (e) {
        log(`COMMIT c${conn} serial ${serial}: no memory for ${size} bytes, not presented`);
        return ack(conn, serial);
      }
    }
    const c: PendingCommit = { conn, surface, serial, width, height, stride, format, damage, size };
    readSpans(c, h.token, offset, spansOf(damage, stride, asyncSource), 0);
  }

  // Read spans[i…] into the staging buffer, then present. Returns true when
  // done (presented or failed), false while a read's promise is pending.
  function readSpans(c: PendingCommit, token: unknown, base: number, spans: number[], i: number): boolean {
    for (; i < spans.length; i += 2) {
      const start = spans[i], end = spans[i + 1];
      let r: void | Promise<void>;
      try {
        r = buffers!.read(token, base + start, stage.subarray(start, end));
      } catch (e) {
        readFailed(c, e);
        return true;
      }
      if (thenable(r)) {
        asyncSource = true;
        const g = gen, next = i + 2;
        stall = true;
        const rd = reading = { token, close: false };
        // true if the token was closed meanwhile (closed now, for good)
        const settled = () => {
          reading = null;
          if (rd.close) closeToken(token);
          return rd.close;
        };
        r.then(() => {
          const closed = settled();
          if (g !== gen) return; // link closed: nothing to present or ACK
          if (closed) readFailed(c, 'handle closed');
          else if (!readSpans(c, token, base, spans, next)) return;
          resume();
        }, (e) => {
          settled();
          if (g !== gen) return;
          readFailed(c, e);
          resume();
        });
        return false;
      }
    }
    present(c);
    return true;
  }

  function readFailed(c: PendingCommit, e: unknown) {
    log(`COMMIT c${c.conn} serial ${c.serial}: read failed (${e}), not presented`);
    ack(c.conn, c.serial);
  }

  function present(c: PendingCommit) {
    const { conn, surface, serial, width, height, damage } = c;
    if (!wantRgba) {
      commit(conn, surface, width, height, c.format === WL_SHM_ARGB8888 ? 'bgra' : 'bgrx', c.stride,
        damage, stage.subarray(0, c.size));
    } else {
      const pixels = swizzle(c);
      if (pixels) commit(conn, surface, width, height, 'rgba', 0, damage, pixels);
    }
    // the commit event's dispatch has returned: the pixels are consumed
    ack(conn, serial);
  }

  // COMMIT kind virtgpu: resolve the resource through options.gpu (a promise
  // stalls the walk, as a buffer-source read does), dispatch the commit
  // with the image, release the image, ACK. No resolver: the commit still
  // goes out (layout, the ref for scripts) with image null.
  function gpuCommit(conn: number, surface: number, serial: number, ref: GpuRef, damage: Int32Array) {
    if (!gpu) {
      if (!gpuWarned) {
        gpuWarned = true;
        emit({ type: 'error', detail: 'GPU buffers (COMMIT kind virtgpu) from the relay, but this engine has no gpu source: their surfaces show nothing' });
      }
      return gpuPresent(conn, surface, serial, ref, damage, null);
    }
    let r: unknown;
    try {
      r = gpu.resolve(ref, { conn, surface, damage });
    } catch (e) {
      log(`COMMIT c${conn} serial ${serial}: gpu resolve of resource ${ref.resource} failed (${e})`);
      r = null;
    }
    if (!thenable(r)) return gpuPresent(conn, surface, serial, ref, damage, r ?? null);
    const g = gen;
    stall = true;
    r.then((image) => {
      if (g !== gen) return; // link closed: nothing to present or ACK
      gpuPresent(conn, surface, serial, ref, damage, image ?? null);
      resume();
    }, (e) => {
      if (g !== gen) return;
      log(`COMMIT c${conn} serial ${serial}: gpu resolve of resource ${ref.resource} failed (${e})`);
      gpuPresent(conn, surface, serial, ref, damage, null);
      resume();
    });
  }

  function gpuPresent(conn: number, surface: number, serial: number, ref: GpuRef, damage: Int32Array, image: unknown) {
    commit(conn, surface, ref.width, ref.height, 'gpu', 0, damage, EMPTY, { gpu: ref, image });
    // the dispatch returned: the image is drawn, the resource no longer read
    if (image !== null && gpu && gpu.release) {
      try { gpu.release(image); } catch (e) { emit({ type: 'error', detail: `gpu source release: ${e}` }); }
    }
    ack(conn, serial);
  }

  // options.rgba: each damage rect's rows go packed into wasm memory, then
  // wland_swizzle converts them in place to canvas-ready RGBA (alpha forced
  // for XRGB) — the BUFFER layout, so a 2D presenter paints it directly.
  function swizzle(c: PendingCommit): Uint8Array | null {
    const { damage, stride } = c;
    let total = 0;
    for (let i = 0; i < damage.length; i += 4) total += damage[i + 2] * damage[i + 3] * 4;
    if (total > wstageLen) {
      if (wstage) ex.wland_free(wstage, wstageLen);
      wstageLen = Math.max(total, Math.ceil(wstageLen * 1.5));
      wstage = ex.wland_alloc(wstageLen);
      if (!wstage) { wstageLen = 0; log('wland_alloc failed (swizzle)'); return null; }
    }
    const mem = new Uint8Array(ex.memory.buffer); // after the alloc: it may grow memory
    const opaque = c.format === WL_SHM_ARGB8888 ? 0 : 1;
    let out = wstage;
    for (let i = 0; i < damage.length; i += 4) {
      const x = damage[i], y = damage[i + 1], w = damage[i + 2], h = damage[i + 3];
      const row = w * 4, src = y * stride + x * 4;
      if (row === stride) mem.set(stage.subarray(src, src + row * h), out);
      else for (let r = 0; r < h; r++) mem.set(stage.subarray(src + r * stride, src + r * stride + row), out + r * row);
      ex.wland_swizzle(out, row, out, w, h, opaque);
      out += row * h;
    }
    return new Uint8Array(ex.memory.buffer, wstage, total);
  }

  // --- link messages: an inbox processed strictly in order -----------------
  // inbox[0] is the message being walked, `pos` the next frame in it. Runs of
  // ordinary frames go to the core as one wland_on_frame call; BUFFER,
  // BUFFER_LZ and COMMIT are handled here, between those runs, so their
  // position relative to the WIRE frames is kept. A HANDLE_OPEN ends its run
  // (the core opens it synchronously); when the buffer source answers with a
  // promise the walk stops right there and resumes when it settles.
  const inbox: ArrayBuffer[] = [];
  let pos = 0;
  let pumping = false;

  function onMessage(data: ArrayBuffer) {
    stats.bytesIn += data.byteLength;
    inbox.push(data);
    pump();
  }

  function resume() {
    stall = false;
    pump();
  }

  function pump() {
    // never inside a core call or a dispatch (an event handler that makes
    // the link deliver synchronously): run() pumps once those return
    if (pumping || stall || depth > 0 || draining) return;
    pumping = true;
    try {
      while (inbox.length && !stall) {
        if (walk(inbox[0])) { inbox.shift(); pos = 0; }
      }
    } finally {
      pumping = false;
    }
  }

  // returns true when the message is done, false when the walk stopped early
  // (a pending promise, or the link closed under it)
  function walk(data: ArrayBuffer): boolean {
    const bytes = new Uint8Array(data);
    const dv = new DataView(data);
    const total = data.byteLength;
    const g = gen;
    let off = pos, span = -1;
    const toCore = (end: number) => {
      const p = toWasm(bytes, span, end);
      if (p) run(ex.wland_on_frame, p, end - span);
      span = -1;
    };
    while (off < total) {
      const len = frameLen(dv, off, total);
      if (len <= 0 || off + len > total) {
        if (span >= 0) toCore(off);
        log(`bad frame at ${off} (${total}B message): rest dropped`);
        break;
      }
      const t = bytes[off];
      if (t === FRAME_BUFFER || t === FRAME_BUFFER_LZ || t === FRAME_COMMIT) {
        if (span >= 0) toCore(off);
        if (g !== gen) return false;
        if (t === FRAME_BUFFER) commitBuffer(dv, off);
        else if (t === FRAME_BUFFER_LZ) commitCompressed(bytes, off, len);
        else onCommit(bytes, off, len);
        off += len;
      } else {
        if (span < 0) span = off;
        if (t === FRAME_CONN_OPEN) conns.add(dv.getUint32(off + 1, true));
        off += len;
        if (t === FRAME_HANDLE_OPEN) toCore(off);
      }
      if (g !== gen) return false;
      if (stall) { pos = off; return off >= total; }
    }
    if (span >= 0) toCore(off);
    return g === gen;
  }

  // --- pointer motion: coalesced here, next to the link -------------------
  // Only the newest motion is kept; it ships on tick() unless the link's send
  // buffer is backed up (then it waits for a later tick), and always right
  // before any order-sensitive pointer call so the app sees the position
  // first.
  let pending: Motion | null = null;
  function flushMotion(ordered: boolean) {
    if (!pending) return;
    if (!ordered && link.bufferedAmount > BACKPRESSURE_BYTES) { stats.backpressured++; return; }
    const m = pending;
    pending = null;
    stats.sentMotions++;
    run(ex.wland_pointer_motion, m.conn, m.time, fixed(m.x), fixed(m.y),
      fixed(m.dx), fixed(m.dy), fixed(m.dxu), fixed(m.dyu), m.utime);
  }
  // a call into the core: dropped unless the compositor is live; pointer
  // calls ship the pending motion first
  const call = <A extends unknown[]>(fn: (...args: A) => unknown, pointer = false) => (...args: A): void => {
    if (!live) return;
    if (pointer) flushMotion(true);
    run(fn, ...args);
  };

  function withUtf8(text: string, fn: (ptr: number, len: number) => void) {
    const bytes = enc.encode(text);
    const size = Math.max(1, bytes.length);
    const ptr = ex.wland_alloc(size);
    if (!ptr) return;
    new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
    fn(ptr, bytes.length);
    ex.wland_free(ptr, size);
  }

  // the link's callbacks; none of them does anything once disposed (a link
  // without close() may still call them)
  const callbacks: LinkCallbacks = {
    onOpen() {
      if (disposed) return;
      live = true;
      gpuWarned = false;
      run(ex.wland_init, output.scale, output.scale120);
      if (output.width > 0 && output.height > 0) run(ex.wland_desktop_size, output.width, output.height);
      if (output.suspended) run(ex.wland_set_suspended, 1);
      emit({ type: 'open' });
    },
    onMessage(data) {
      if (!disposed) onMessage(data);
    },
    onError(detail) {
      if (!disposed) emit({ type: 'error', detail });
    },
    onClose(info) {
      if (disposed) return;
      halt();
      // the relay dropped every app of this link: close them in the core
      // as its CONN_CLOSE would (drags, selections and focus end there;
      // each emits 'disconnect' and closes the conn's handles)
      for (const conn of [...conns]) {
        const f = new Uint8Array(5);
        f[0] = FRAME_CONN_CLOSE;
        new DataView(f.buffer).setUint32(1, conn, true);
        const p = toWasm(f, 0, 5);
        if (p) run(ex.wland_on_frame, p, 5);
      }
      conns.clear();
      closeHandles(() => true);
      emit({ type: 'close', takenOver: !!(info && info.takenOver) });
    },
  };

  // the link is gone: nothing reaches it from here on, pending promises and
  // unprocessed frames are void
  function halt() {
    live = false;
    pending = null;
    gen++;
    stall = false;
    inbox.length = 0;
    pos = 0;
  }

  const engine: Engine = {
    version,
    stats,
    start() {
      if (!disposed) link.start(callbacks);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      halt();
      conns.clear();
      closeHandles(() => true);
      queue.length = 0;
      if (typeof link.close === 'function') link.close();
    },

    // output
    setScale(scale, scale120) {
      output.scale = Math.max(1, Math.min(4, Math.round(scale)));
      output.scale120 = Math.max(1, Math.round(scale120));
      if (live) run(ex.wland_set_dpr, output.scale, output.scale120);
    },
    setOutput(width, height) {
      output.width = Math.round(width);
      output.height = Math.round(height);
      if (live) run(ex.wland_desktop_size, output.width, output.height);
    },
    setSuspended(suspended) {
      output.suspended = !!suspended;
      if (live) run(ex.wland_set_suspended, output.suspended ? 1 : 0);
    },
    tick(time, refresh) {
      if (!live) return;
      flushMotion(false);
      // presentation is stalled on the buffer source: nothing new is
      // drawn, so feedback and frame callbacks wait (apps render at most
      // one frame ahead of what is shown)
      if (stall) return;
      const display = refresh !== undefined;
      // a display frame began a little before its callback runs: how long
      // ago, so the relay can date presentation to the frame (not after 1 s:
      // then `time` is no rAF timestamp of now)
      const age = display ? performance.now() - time : 0;
      const ageUs = age > 0 && age < 1000 ? Math.round(age * 1000) : 0;
      const refreshNs = display && refresh > 0 && refresh < 1000 ? Math.round(refresh * 1e6) : 0;
      run(ex.wland_tick, time >>> 0, ageUs, refreshNs, display ? 1 : 0);
    },

    // pointer
    pointerMotion(conn, time, x, y, relative) {
      if (!live) return;
      stats.motions++;
      if (pending && pending.conn !== conn) flushMotion(true);
      const dx = relative ? relative.dx || 0 : 0, dy = relative ? relative.dy || 0 : 0;
      const dxu = relative ? relative.dxUnaccel ?? dx : 0, dyu = relative ? relative.dyUnaccel ?? dy : 0;
      const utime = relative && Number.isFinite(relative.time) ? relative.time! : time * 1000;
      if (!pending) pending = { conn, time: 0, x: 0, y: 0, dx: 0, dy: 0, dxu: 0, dyu: 0, utime: 0 };
      pending.time = time >>> 0;
      pending.x = x;
      pending.y = y;
      pending.dx += dx;
      pending.dy += dy;
      pending.dxu += dxu;
      pending.dyu += dyu;
      pending.utime = Math.max(0, Math.round(utime));
    },
    pointerEnter: call((conn, surface, x, y) => ex.wland_pointer_enter(conn, surface, fixed(x), fixed(y)), true),
    pointerLeave: call((conn) => ex.wland_pointer_leave(conn), true),
    pointerButton: call((conn, time, button, pressed) =>
      ex.wland_pointer_button(conn, time >>> 0, button, pressed ? 1 : 0), true),
    pointerAxis: call((conn, time, axis, value, value120) =>
      ex.wland_pointer_axis(conn, time >>> 0, axis, fixed(value), value120), true),
    pointerLockGranted: call((conn, surface) => ex.wland_pointer_lock_granted(conn, surface), true),
    pointerLockLost: call((conn) => ex.wland_pointer_lock_lost(conn), true),

    // keyboard + text input
    keyboardEnter: call((conn, surface) => ex.wland_keyboard_enter(conn, surface)),
    keyboardLeave: call((conn) => ex.wland_keyboard_leave(conn)),
    key: call((conn, time, code, pressed) => ex.wland_key(conn, time >>> 0, code, pressed ? 1 : 0)),
    textInputPreedit: call((conn, text) => withUtf8(text, (ptr, len) =>
      ex.wland_text_input_preedit(conn, ptr, len, len, len))),
    textInputCommit: call((conn, text) => withUtf8(text, (ptr, len) =>
      ex.wland_text_input_commit_string(conn, ptr, len))),

    // window management
    popupDismiss: call((conn, surface) => ex.wland_popup_dismiss(conn, surface), true),
    requestResize: call((conn, surface, width, height) =>
      ex.wland_request_resize(conn, surface, Math.round(width), Math.round(height))),
    setMaximized: call((conn, surface, on) => ex.wland_set_maximized(conn, surface, on ? 1 : 0)),
    setFullscreen: call((conn, surface, on) => ex.wland_set_fullscreen(conn, surface, on ? 1 : 0)),
    // minimizing sends a pointer leave: after any pending motion
    setMinimized: call((conn, surface, on) => ex.wland_set_minimized(conn, surface, on ? 1 : 0), true),
    dragMotion: call((conn, surface, time, x, y) =>
      ex.wland_drag_motion(conn, surface, time >>> 0, fixed(x), fixed(y)), true),
    dragDrop: call(() => ex.wland_drag_drop(), true),
    dragCancel: call(() => ex.wland_drag_cancel(), true),
  };
  return engine;
}

// node:fs/promises in Node (Bun, Deno), else undefined. Through
// process.getBuiltinModule, not import(): a bundler sees no import to
// externalize (and warn about) in a browser build.
function nodeFs(): typeof import('node:fs/promises') | undefined {
  const proc = (globalThis as { process?: { getBuiltinModule?(id: string): unknown } }).process;
  return proc?.getBuiltinModule?.('node:fs/promises') as typeof import('node:fs/promises') | undefined;
}

async function instantiate(src: NonNullable<EngineOptions['wasm']>, imports: CoreImports): Promise<CoreExports> {
  let exports: WebAssembly.Exports;
  if (src instanceof WebAssembly.Module) exports = (await WebAssembly.instantiate(src, imports)).exports;
  else if (src instanceof ArrayBuffer || ArrayBuffer.isView(src)) {
    exports = (await WebAssembly.instantiate(src, imports)).instance.exports;
  } else if (String(src).startsWith('file:') && nodeFs()) {
    // Node's fetch can't load file: URLs
    exports = (await WebAssembly.instantiate(await nodeFs()!.readFile(new URL(src)), imports)).instance.exports;
  } else exports = (await WebAssembly.instantiateStreaming(fetch(src), imports)).instance.exports;
  return exports as unknown as CoreExports;
}

// What to read for a COMMIT, as [start, end, start, end, …] byte offsets
// from pixel (0, 0): each damage rect's span (its first to its last byte —
// the rows in between whole), sorted, merged where spans overlap or lie
// within MERGE_GAP of each other (a page: copying it costs about what another
// call does). An async source gets one span over everything: each of its
// reads is a round trip. Bytes outside the spans stay undefined.
const MERGE_GAP = 4096;
function spansOf(damage: Int32Array, stride: number, single: boolean): number[] {
  const n = damage.length / 4;
  const order: number[] = [];
  for (let i = 0; i < n; i++) order.push(i);
  const start = (i: number) => damage[i * 4 + 1] * stride + damage[i * 4] * 4;
  const end = (i: number) => (damage[i * 4 + 1] + damage[i * 4 + 3] - 1) * stride + (damage[i * 4] + damage[i * 4 + 2]) * 4;
  if (n > 1) order.sort((a, b) => start(a) - start(b));
  const out = [start(order[0]), end(order[0])];
  for (let k = 1; k < n; k++) {
    const s = start(order[k]), e = end(order[k]);
    if (single || s <= out[out.length - 1] + MERGE_GAP) out[out.length - 1] = Math.max(out[out.length - 1], e);
    else out.push(s, e);
  }
  return out;
}

// A link message packs one or more self-delimiting frames (STREAM.md);
// returns the byte length of the frame at `off`, or -1 if unknown/short.
function frameLen(dv: DataView, off: number, total: number): number {
  const room = total - off;
  const u32 = (at: number) => (at + 4 <= total ? dv.getUint32(at, true) : -1);
  const t = dv.getUint8(off);
  switch (t) {
    case 0x01: return room < 9 ? -1 : 9 + u32(off + 5);                  // WIRE
    case 0x03: case 0x04: return 5;                                      // CONN_OPEN/CLOSE
    case FRAME_BUFFER: {
      if (room < BUFFER_HEADER) return -1;
      const n = u32(off + 17);
      if (room < BUFFER_HEADER + n * 16) return -1;
      let len = BUFFER_HEADER + n * 16;
      for (let i = 0; i < n; i++) {
        const r = off + BUFFER_HEADER + i * 16;
        len += dv.getInt32(r + 8, true) * dv.getInt32(r + 12, true) * 4;
      }
      return len;
    }
    case 0x05: {                                                         // FDMSG
      const bl = u32(off + 9);
      if (bl < 0) return -1;
      const al = u32(off + 13 + bl);
      return al < 0 ? -1 : 13 + bl + 4 + al;
    }
    case 0x06: return 13;                                                // SRVOBJ
    case FRAME_BUFFER_LZ: {
      const n = u32(off + 17);
      if (n < 0) return -1;
      const comp = u32(off + BUFFER_HEADER + n * 16 + 4);
      return comp < 0 ? -1 : BUFFER_HEADER + n * 16 + 8 + comp;          // + raw_len + comp_len + comp
    }
    case FRAME_HANDLE_OPEN: return room < 17 ? -1 : 17 + u32(off + 13);
    case 0x09: case 0x0b: return 9;                                      // HANDLE_CLOSE, ACK
    case 0x0c: return room < 9 ? -1 : 9 + u32(off + 5);                  // FEATURE
    case FRAME_COMMIT: return room < 25 ? -1 : 25 + u32(off + 21) + u32(off + 13) * 16;
    default: return -1;
  }
}
