// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! wasm32-freestanding glue: STREAM frames in/out ↔ Compositor. This file is
//! the core's public ABI (consumed by lib/engine.ts).
//!
//! JS calls wland_init, then, per received link message, routes its frames:
//! runs of ordinary frames go to wland_on_frame; three frame types JS handles
//! itself, between those runs, so their position relative to the WIRE frames
//! is kept:
//!   0x02 BUFFER     — canvas-ready RGBA painted straight from the message
//!   0x07 BUFFER_LZ  — wland_decode_buffer, then presented like 0x02
//!   0x0a COMMIT     — wland_commit_notice decodes it, JS reads the pixels
//!                     through its buffer source (shm) or resolves the GPU
//!                     resource through its gpu source (virtgpu), dispatches
//!                     the commit, then wland_commit_ack
//! wland_tick runs from the host's frame clock (rAF). Outgoing frames go
//! through the imported js_send; log lines through js_log.

const std = @import("std");
const core = @import("core");

extern "env" fn js_send(ptr: [*]const u8, len: usize) void;
extern "env" fn js_log(ptr: [*]const u8, len: usize) void;
extern "env" fn js_set_title(conn_id: u32, surface_id: u32, ptr: [*]const u8, len: usize) void;
/// xdg_toplevel.set_app_id (ptr/len valid only during the call).
extern "env" fn js_set_app_id(conn_id: u32, surface_id: u32, ptr: [*]const u8, len: usize) void;
/// A commit changed a toplevel's size hints (set_min_size / set_max_size),
/// window geometry px, 0 = unset; all 0 when its xdg_toplevel went.
extern "env" fn js_size_limits(conn_id: u32, surface_id: u32, min_w: i32, min_h: i32, max_w: i32, max_h: i32) void;
/// A toplevel's decoration mode changed: decorated 1 = server_side (the
/// embedder draws its frame), 0 = client-side again.
extern "env" fn js_decoration(conn_id: u32, surface_id: u32, decorated: u32) void;
/// The core sent a toplevel an xdg_toplevel configure: its xdg_surface
/// serial, the size it asks (0 = the client decides), its states as bits
/// (1 maximized, 2 fullscreen, 4 activated, 8 suspended, the tiled edges
/// << 4) and the token of the embedder call that made it (0 = none).
extern "env" fn js_configure(conn_id: u32, surface_id: u32, serial: u32, w: i32, h: i32, states: u32, cause: u32) void;
/// A commit applied the configure `serial` the app acked (w×h: what it
/// asked).
extern "env" fn js_acked(conn_id: u32, surface_id: u32, serial: u32, w: i32, h: i32) void;
extern "env" fn js_conn_close(conn_id: u32) void;
/// value = role (0-4) on role change, 0xffffffff when the surface is destroyed.
extern "env" fn js_surface_event(conn_id: u32, surface_id: u32, value: u32) void;
/// App-initiated interactive request (window positions live in the DOM):
/// kind 0 = start move drag, 1 = start resize drag (value = edges bitmask),
/// 2 = maximized (fill the desktop), 3 = unmaximized (restore position),
/// 4 = dnd session started (value = icon surface id, 0 none) — JS drives it
/// via wland_drag_motion/_drop/_cancel, 5 = dnd session ended, 6 =
/// fullscreen, 7 = unfullscreen, 8 = minimized (hide the window), 9 =
/// restored (show, raise, focus it). The state kinds (2/3, 6–9) follow
/// every change, the app's request or JS's wland_set_* alike.
extern "env" fn js_interactive(conn_id: u32, surface_id: u32, kind: u32, value: u32) void;
/// wp_cursor_shape_device_v1.set_shape accepted (shape 1..34) or the pointer
/// left (shape 0 = reset to default). JS maps it to a CSS cursor.
extern "env" fn js_cursor_shape(conn_id: u32, shape: u32) void;
/// wl_pointer.set_cursor: the pointer image is surface_id's committed buffer,
/// hotspot hx,hy (surface-local logical px); surface_id 0 = hidden.
extern "env" fn js_cursor_surface(conn_id: u32, surface_id: u32, hx: i32, hy: i32) void;
/// zwp_text_input_v3 (M12): active=1 when the focused client ENABLED its text
/// input (JS routes browser composition to this conn + places its hidden IME
/// sink at x,y,w,h, the surface-local cursor rect), 0 when disabled/unfocused.
extern "env" fn js_text_input(conn_id: u32, active: u32, x: i32, y: i32, w: i32, h: i32) void;
/// A commit changed the surface's input region (where it takes pointer
/// input; JS does the picking): infinite = 1 for the whole surface (n = 0),
/// else n disjoint rects at ptr as i32 {x, y, w, h}, surface-local logical
/// px, valid only during the call (n = 0: no input at all).
extern "env" fn js_input_region(conn_id: u32, surface_id: u32, infinite: u32, ptr: [*]const i32, n: u32) void;
/// The pointer lock the conn wants changed: surface_id is the surface a
/// zwp_locked_pointer_v1 waits on or holds (JS locks the browser's pointer
/// to it and reports wland_pointer_lock_granted / _lost), 0 = none any more
/// (JS lets the browser's lock go).
extern "env" fn js_pointer_lock(conn_id: u32, surface_id: u32) void;
/// The conn has a wl_touch now (bound = 1: its first get_touch) or none any
/// more (0: its last released). The wland_touch_* calls for a conn without
/// one are ignored (JS sends that client the finger as a pointer). Not told
/// at the conn's close (js_conn_close is).
extern "env" fn js_touch_bound(conn_id: u32, bound: u32) void;
/// HANDLE_OPEN (STREAM.md 0x08), decoded. kind 1 = kwshm: a = export id,
/// b = 0, offset = 0. kind 2 = procfd: a = pid, b = fd, offset = file offset
/// of handle byte 0. size = the handle's length in bytes (< 2^53, exact as
/// f64). kind 0 = unusable — an unknown kind or handle bytes of the wrong
/// length (a = the frame's raw kind): JS records the handle as broken and
/// reports it; COMMITs naming it are acked without presenting.
/// Called during wland_on_frame: JS opens the handle synchronously.
extern "env" fn js_handle_open(conn_id: u32, handle_id: u32, kind: u32, a: u32, b: u32, offset: f64, size: f64) void;
/// HANDLE_CLOSE (0x09): JS closes the handle and forgets it.
extern "env" fn js_handle_close(conn_id: u32, handle_id: u32) void;
/// The clipboard selection changed: conn_id owns it now (0 = the embedder's
/// own, wland_set_selection, or none when len = 0; an app's conn with len 0:
/// it cleared the selection); ptr/len = the mime types it offers,
/// NUL-separated, valid only during the call.
extern "env" fn js_selection(conn_id: u32, ptr: [*]const u8, len: usize) void;
/// A wland_read_selection answered (FDMSG pipe_read from the relay): status
/// 0 = the bytes at ptr/len are all of it, 1 = too large, 2 = the source
/// timed out, 3 = failed. ptr valid only during the call.
extern "env" fn js_selection_data(read_id: u32, status: u32, ptr: [*]const u8, len: usize) void;

const gpa = std.heap.wasm_allocator;

var compositor: core.compositor.Compositor = undefined;
/// wland_init has run: a link that opens again re-inits, freeing the old one
var compositor_live = false;
/// wland_set_gpu_source's last word; outlives wland_init (every link's
/// compositor gets it). true until said otherwise.
var gpu_source = true;
/// A frame other than FEATURE arrived on this link: the relay's FEATURE
/// frames (all first on a link) are in, what it can't do is settled.
var features_settled = false;

export fn wland_version() u32 {
    return core.version;
}

/// scale = browser devicePixelRatio rounded to an integer (≥1), advertised as
/// wl_output.scale so apps render retina-crisp buffers; scale_120 = the
/// fractional preferred scale (round(dpr × 120)) for wp_fractional_scale;
/// decorations = 1 when the embedder draws window frames (toplevels that
/// ask through xdg-decoration are configured server_side), 0 = never.
export fn wland_init(scale: i32, scale_120: i32, decorations: u32) void {
    if (compositor_live) compositor.deinit();
    compositor = .init(gpa, null, sendWire, log);
    compositor_live = true;
    compositor.fdmsg_fn = sendFdMsg;
    compositor.srvobj_fn = sendSrvObj;
    compositor.dmabuf_created_fn = sendDmabufCreated;
    compositor.presented_fn = sendPresented;
    compositor.title_fn = setTitle;
    compositor.app_id_fn = setAppId;
    compositor.size_limits_fn = sizeLimits;
    compositor.decoration_fn = decoration;
    compositor.configure_fn = configure;
    compositor.acked_fn = acked;
    compositor.surface_fn = surfaceEvent;
    compositor.interactive_fn = interactive;
    compositor.cursor_shape_fn = cursorShape;
    compositor.cursor_surface_fn = cursorSurface;
    compositor.text_input_fn = textInput;
    compositor.input_region_fn = inputRegion;
    compositor.pointer_lock_fn = pointerLock;
    compositor.touch_bound_fn = touchBound;
    compositor.selection_fn = selectionEvent;
    compositor.output_scale = std.math.clamp(scale, 1, 4);
    compositor.scale_120 = @max(1, scale_120);
    compositor.gpu_source = gpu_source;
    compositor.decorations_server = decorations == 1;
    features_settled = false;
}

/// Whether this link's relay bridges the clipboard for the embedder
/// (FEATURE selection_cache: wland_read_selection / wland_set_selection
/// work): 1 yes, 0 no (its FEATURE frames are in without it: a relay that
/// predates it, wlandr 0.1.0), 2 not known yet (no frame but FEATURE has
/// arrived on this link). A getter: sends nothing.
export fn wland_selection_bridged() u32 {
    if (!compositor_live) return 2;
    if (compositor.selection_bridge) return 1;
    return if (features_settled) 0 else 2;
}

/// Whether the embedder can draw GPU buffers (COMMIT kind virtgpu; 1 yes,
/// 0 no). Without, a relay whose dmabuf commits are GPU resources (FEATURE
/// dmabuf_kind) gets no linux-dmabuf from the compositor: GPU clients fall
/// back to wl_shm instead of drawing windows nothing shows. Default 1 (an
/// embedder that never calls this is unchanged). Kept across wland_init;
/// call it before the link's FEATURE frames arrive. Sends nothing.
export fn wland_set_gpu_source(has: u32) void {
    gpu_source = has != 0;
    if (compositor_live) compositor.gpu_source = gpu_source;
}

/// Browser devicePixelRatio changed (matchMedia resolution listener): resend
/// wp_fractional_scale preferred_scale, wl_compositor v6 preferred_buffer_*
/// and the wl_output scale/mode. Removes the reload-on-dpr-change limit.
export fn wland_set_dpr(scale: i32, scale_120: i32) void {
    compositor.setScale(scale, scale_120);
    flushOut();
}

/// Logical desktop area (the page's #desktop); maximize configures use it.
/// Called at init and on browser window resize.
export fn wland_desktop_size(w: i32, h: i32) void {
    compositor.setDesktopSize(w, h);
    flushOut();
}

/// The work area for windows (configure_bounds, and a maximized toplevel's
/// size), logical px: w×h for client-side toplevels, dw×dh for decorated
/// ones (the embedder's workspace less its frame; 0×0 = w×h). 0×0 = the
/// desktop's size. Configured toplevels whose area changed are told.
export fn wland_set_bounds(w: i32, h: i32, dw: i32, dh: i32) void {
    compositor.setBounds(w, h, dw, dh);
    flushOut();
}

/// Browser tab visibility changed (visibilitychange listener): (un)suspend
/// mapped v6 toplevels so hidden tabs stop the app rendering.
export fn wland_set_suspended(suspended: u32) void {
    compositor.setSuspended(suspended != 0);
    flushOut();
}

// input entry points, called from DOM event handlers. Every export that can
// make the compositor send events must flushOut() before returning — a
// missed flush stalls those events until the next rAF tick.

export fn wland_pointer_enter(conn_id: u32, surface_id: u32, x_fixed: i32, y_fixed: i32) void {
    compositor.pointerEnter(conn_id, surface_id, x_fixed, y_fixed);
    flushOut();
}

export fn wland_pointer_leave(conn_id: u32) void {
    compositor.pointerLeave(conn_id);
    flushOut();
}

/// x,y = the position (surface-local, wl_fixed); dx..dyu = the motion's
/// relative part (wl_fixed; all 0 = none) for zwp_relative_pointer_v1,
/// utime its timestamp in µs (exact below 2^53).
export fn wland_pointer_motion(conn_id: u32, time_ms: u32, x_fixed: i32, y_fixed: i32, dx: i32, dy: i32, dxu: i32, dyu: i32, utime: f64) void {
    const us: u64 = if (utime > 0 and utime < 9007199254740992.0) @intFromFloat(utime) else 0;
    compositor.pointerMotion(conn_id, time_ms, x_fixed, y_fixed, .{ .dx = dx, .dy = dy, .dx_unaccel = dxu, .dy_unaccel = dyu, .utime = us });
    flushOut();
}

/// The browser locked its pointer to the surface the core asked for
/// (js_pointer_lock): `locked`.
export fn wland_pointer_lock_granted(conn_id: u32, surface_id: u32) void {
    compositor.pointerLockGranted(conn_id, surface_id);
    flushOut();
}

/// The browser's pointer lock ended without being asked to (Esc, blur):
/// `unlocked`.
export fn wland_pointer_lock_lost(conn_id: u32) void {
    compositor.pointerLockLost(conn_id);
    flushOut();
}

export fn wland_pointer_button(conn_id: u32, time_ms: u32, button: u32, pressed: u32) void {
    compositor.pointerButton(conn_id, time_ms, button, pressed != 0);
    flushOut();
}

/// value_fixed = continuous scroll vector (surface coords, wl_fixed);
/// value120 = high-resolution discrete component (120 per wheel detent).
export fn wland_pointer_axis(conn_id: u32, time_ms: u32, axis: u32, value_fixed: i32, value120: i32) void {
    compositor.pointerAxis(conn_id, time_ms, axis, value_fixed, value120);
    flushOut();
}

/// Touch point `id` (the embedder's, unique among the conn's points that
/// are down) went down on the surface at x,y (surface-local, wl_fixed).
export fn wland_touch_down(conn_id: u32, time_ms: u32, surface_id: u32, id: i32, x_fixed: i32, y_fixed: i32) void {
    compositor.touchDown(conn_id, time_ms, surface_id, id, x_fixed, y_fixed);
    flushOut();
}

/// x,y local to the surface the point went down on, wherever it is now.
export fn wland_touch_motion(conn_id: u32, time_ms: u32, id: i32, x_fixed: i32, y_fixed: i32) void {
    compositor.touchMotion(conn_id, time_ms, id, x_fixed, y_fixed);
    flushOut();
}

export fn wland_touch_up(conn_id: u32, time_ms: u32, id: i32) void {
    compositor.touchUp(conn_id, time_ms, id);
    flushOut();
}

/// The touch calls since the last frame happened together: wl_touch.frame.
export fn wland_touch_frame(conn_id: u32) void {
    compositor.touchFrame(conn_id);
    flushOut();
}

/// Every point of the conn ends without its up (wl_touch.cancel).
export fn wland_touch_cancel(conn_id: u32) void {
    compositor.touchCancel(conn_id);
    flushOut();
}

export fn wland_keyboard_enter(conn_id: u32, surface_id: u32) void {
    compositor.keyboardEnter(conn_id, surface_id);
    flushOut();
}

export fn wland_keyboard_leave(conn_id: u32) void {
    compositor.keyboardLeave(conn_id);
    flushOut();
}

export fn wland_key(conn_id: u32, time_ms: u32, evdev_key: u32, pressed: u32) void {
    compositor.keyboardKey(conn_id, time_ms, evdev_key, pressed != 0);
    flushOut();
}

/// The browser's Caps Lock / NumLock state (bit 0 Caps Lock, bit 1 NumLock):
/// the seat's locked modifiers follow it (focused clients get `modifiers`).
export fn wland_keyboard_locks(locks: u32) void {
    compositor.keyboardLocks(locks & 1 != 0, locks & 2 != 0);
    flushOut();
}

/// The seat's lock state now, as wland_keyboard_locks takes it (bit 0 Caps
/// Lock, bit 1 NumLock): its last word or the lock keys' toggles since.
/// JS reads it as a link closes, to carry it over to the next compositor.
export fn wland_keyboard_locks_state() u32 {
    const l = compositor.lockState();
    return @as(u32, @intFromBool(l.caps_lock)) | @as(u32, @intFromBool(l.num_lock)) << 1;
}

// zwp_text_input_v3 composition, pushed from the browser (M12). The string
// is UTF-8 bytes JS wrote into wasm memory (wland_alloc); only an entered +
// enabled text input is fed, so plain keystrokes (which never compose) keep
// flowing through wland_key exactly as before.

/// compositionupdate → preedit_string(text, cursor_begin, cursor_end) + done.
export fn wland_text_input_preedit(conn_id: u32, ptr: [*]const u8, len: usize, cursor_begin: i32, cursor_end: i32) void {
    compositor.textInputPreedit(conn_id, ptr[0..len], cursor_begin, cursor_end);
    flushOut();
}

/// compositionend / committed char → commit_string(text) + done (also clears
/// any standing preedit).
export fn wland_text_input_commit_string(conn_id: u32, ptr: [*]const u8, len: usize) void {
    compositor.textInputCommitString(conn_id, ptr[0..len]);
    flushOut();
}

/// 0 none, 1 toplevel, 2 subsurface, 3 cursor, 4 popup, 5 dnd icon — JS
/// gates input/visibility.
export fn wland_surface_role(conn_id: u32, surface_id: u32) u32 {
    return @intFromEnum(compositor.surfaceRole(conn_id, surface_id));
}

/// Buffer px per logical px (set_buffer_scale); JS sizes the canvas CSS box
/// at buffer_size/scale so retina buffers map 1:1 to device pixels.
export fn wland_surface_scale(conn_id: u32, surface_id: u32) i32 {
    return compositor.surfaceScale(conn_id, surface_id);
}

/// wp_viewport surface-local size (logical px): 0 = no viewport, use
/// buffer/scale. When set, the embedder's CSS box uses this size instead of
/// buffer/scale — the browser scales the buffer-sized canvas to fit.
export fn wland_surface_view_w(conn_id: u32, surface_id: u32) i32 {
    return compositor.surfaceViewSize(conn_id, surface_id).w;
}

export fn wland_surface_view_h(conn_id: u32, surface_id: u32) i32 {
    return compositor.surfaceViewSize(conn_id, surface_id).h;
}

/// A toplevel's window states: bit 0 maximized, bit 1 fullscreen, bit 2
/// minimized (0 for other roles) — JS pins a maximized/fullscreen box to the
/// desktop origin and hides a minimized one, per commit.
export fn wland_toplevel_state(conn_id: u32, surface_id: u32) u32 {
    return compositor.toplevelState(conn_id, surface_id);
}

/// The embedder's window management (its UI, key bindings): the same
/// configures as the app's own requests; the change comes back through
/// js_interactive. on = 0/1. `cause`: the embedder's token, told with the
/// configure it makes (js_configure; 0 = none).
export fn wland_set_maximized(conn_id: u32, surface_id: u32, on: u32, cause: u32) void {
    compositor.cause = cause;
    compositor.setMaximized(conn_id, surface_id, on != 0);
    compositor.cause = 0;
    flushOut();
}

export fn wland_set_fullscreen(conn_id: u32, surface_id: u32, on: u32, cause: u32) void {
    compositor.cause = cause;
    compositor.setFullscreen(conn_id, surface_id, on != 0);
    compositor.cause = 0;
    flushOut();
}

/// The window is snapped against `edges` (1 top, 2 bottom, 4 left, 8
/// right; 0 none): the tiled_* states (v2) in its configures from now on;
/// w×h > 0 rides the same configure (as wland_request_resize), else it
/// repeats the size. `cause` as wland_set_maximized's.
export fn wland_set_tiled(conn_id: u32, surface_id: u32, edges: u32, w: i32, h: i32, cause: u32) void {
    compositor.cause = cause;
    compositor.setTiled(conn_id, surface_id, edges, w, h);
    compositor.cause = 0;
    flushOut();
}

/// Minimize (1) or restore (0) a mapped toplevel; restoring is only ever
/// the embedder's (xdg_toplevel has no unset_minimized).
export fn wland_set_minimized(conn_id: u32, surface_id: u32, on: u32) void {
    compositor.setMinimized(conn_id, surface_id, on != 0);
    flushOut();
}

/// Show (visible 1) or hide (0) a toplevel's window for the embedder's own
/// reasons: hidden, it is rendered for like a minimized one (frame
/// callbacks held, feedback discarded, v6 `suspended`) without being
/// minimized or losing focus (Compositor.setVisible).
export fn wland_set_visible(conn_id: u32, surface_id: u32, visible: u32) void {
    compositor.setVisible(conn_id, surface_id, visible != 0);
    flushOut();
}

/// Where the toplevel's window-geometry origin is in the output (logical
/// px), kept up to date by the embedder's window manager: popups are
/// constrained to the output from then on (xdg_positioner constraint
/// adjustment); reactive ones are placed again.
export fn wland_set_window_position(conn_id: u32, surface_id: u32, x: i32, y: i32) void {
    compositor.setWindowPosition(conn_id, surface_id, x, y);
    flushOut();
}

/// Ask a toplevel to close (xdg_toplevel.close); the app decides what to do.
export fn wland_close(conn_id: u32, surface_id: u32) void {
    compositor.closeToplevel(conn_id, surface_id);
    flushOut();
}

/// Root toplevel surface id (parent chain walked); JS groups canvases per root.
export fn wland_surface_root(conn_id: u32, surface_id: u32) u32 {
    return compositor.surfaceRoot(conn_id, surface_id);
}

/// What the surface hangs from (a subsurface's parent, a popup's parent
/// xdg surface), 0 if nothing: the embedder stacks a window's surfaces by it.
export fn wland_surface_parent(conn_id: u32, surface_id: u32) u32 {
    return compositor.surfaceParent(conn_id, surface_id);
}

/// A subsurface's rank in its parent's stack: 1, 2, … above the parent,
/// −1, −2, … below it; 0 for any other surface.
export fn wland_surface_z(conn_id: u32, surface_id: u32) i32 {
    return compositor.surfaceZ(conn_id, surface_id);
}

/// 1 when a subsurface's or popup's position or rank may have changed
/// since the last call (Compositor.positions_dirty), else 0; clears it.
/// The embedder re-reads its placed surfaces only then.
export fn wland_take_positions_dirty() u32 {
    return @intFromBool(compositor.takePositionsDirty());
}

/// A placed surface's abs x, abs y and rank (wland_surface_abs_x/_y,
/// wland_surface_z) in one call: a pointer to 3 × i32, valid until the
/// next call. What the embedder re-reads for every subsurface and popup.
var place_out: [3]i32 = @splat(0);
export fn wland_surface_place(conn_id: u32, surface_id: u32) usize {
    const abs = compositor.surfaceAbs(conn_id, surface_id);
    place_out = .{ abs.x, abs.y, compositor.surfaceZ(conn_id, surface_id) };
    return @intFromPtr(&place_out);
}

export fn wland_surface_abs_x(conn_id: u32, surface_id: u32) i32 {
    return compositor.surfaceAbs(conn_id, surface_id).x;
}

export fn wland_surface_abs_y(conn_id: u32, surface_id: u32) i32 {
    return compositor.surfaceAbs(conn_id, surface_id).y;
}

/// Window geometry of an xdg surface in its wl_surface's local px
/// (Compositor.windowGeometry): a pointer to 4 × i32 {x, y, w, h}, valid
/// until the next call. All zero while nothing is known.
var geometry_out: [4]i32 = @splat(0);
export fn wland_window_geometry(conn_id: u32, surface_id: u32) usize {
    const g = compositor.windowGeometry(conn_id, surface_id);
    geometry_out = .{ g.x, g.y, g.w, g.h };
    return @intFromPtr(&geometry_out);
}

/// Outside-click while a popup is up → xdg_popup.popup_done.
export fn wland_popup_dismiss(conn_id: u32, surface_id: u32) void {
    compositor.popupDismiss(conn_id, surface_id);
    flushOut();
}

/// Resize-grip drag → xdg_toplevel.configure(w,h) (clamped to size hints).
/// `cause` as wland_set_maximized's.
export fn wland_request_resize(conn_id: u32, surface_id: u32, w: i32, h: i32, cause: u32) void {
    compositor.cause = cause;
    compositor.requestResize(conn_id, surface_id, w, h);
    compositor.cause = 0;
    flushOut();
}

/// dnd session driving (js_interactive kind 4 opened it): the surface under
/// the pointer per rAF (0,0 = over nothing), then drop or cancel exactly once.
export fn wland_drag_motion(conn_id: u32, surface_id: u32, time_ms: u32, x_fixed: i32, y_fixed: i32) void {
    compositor.dragMotion(conn_id, surface_id, time_ms, x_fixed, y_fixed);
    flushOut();
}

export fn wland_drag_drop() void {
    compositor.dragDrop();
    flushOut();
}

export fn wland_drag_cancel() void {
    compositor.dragCancel();
    flushOut();
}

/// JS allocates a buffer inside wasm memory, fills it, then calls wland_on_frame.
export fn wland_alloc(len: usize) ?[*]u8 {
    const slice = gpa.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wland_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// One or more packed frames (STREAM.md: senders batch; receivers loop).
export fn wland_on_frame(ptr: [*]const u8, len: usize) void {
    var rest = ptr[0..len];
    while (rest.len > 0) {
        const p = core.stream.parseNext(rest) catch |err| {
            logf("bad frame: {t}", .{err});
            break;
        };
        rest = rest[p.consumed..];
        if (p.frame != .feature) features_settled = true;
        switch (p.frame) {
            .conn_open => |conn_id| compositor.connOpen(conn_id) catch |err| logf("conn_open: {t}", .{err}),
            .conn_close => |conn_id| {
                compositor.connClose(conn_id);
                js_conn_close(conn_id);
            },
            .wire => |w| compositor.onWire(w.conn_id, w.bytes) catch |err| logf("onWire: {t}", .{err}),
            // fd itself stays in the server; the wire message keeps our object map correct
            .fdmsg => |f| if (f.kind == @intFromEnum(core.stream.FdMsgKind.pipe_read)) {
                // a wland_read_selection's answer: aux = read id ++ status ++ bytes
                if (f.aux.len >= 8) {
                    js_selection_data(std.mem.readInt(u32, f.aux[0..4], .little), std.mem.readInt(u32, f.aux[4..8], .little), f.aux[8..].ptr, f.aux.len - 8);
                } else {
                    logf("pipe_read fdmsg with bad aux len {d}", .{f.aux.len});
                }
            } else if (f.kind == 3) { // pipe: clipboard receive, aux = fd token
                if (f.aux.len == 4) {
                    compositor.onPipeReceive(f.conn_id, f.wire_bytes, std.mem.readInt(u32, f.aux[0..4], .little));
                } else {
                    logf("pipe fdmsg with bad aux len {d}", .{f.aux.len});
                }
            } else {
                compositor.onWire(f.conn_id, f.wire_bytes) catch |err| logf("fdmsg: {t}", .{err});
            },
            // BUFFER frames are presented entirely in JS (canvas-ready RGBA
            // painted straight from the WS message; pixels never enter wasm
            // memory) — JS routes only the other frame types here
            .buffer => logf("BUFFER frame reached wasm — JS presents 0x02 itself", .{}),
            // BUFFER_LZ is decoded via wland_decode_buffer (JS calls it, then
            // presents the reconstructed 0x02) — never routed here.
            .buffer_lz => logf("BUFFER_LZ frame reached wasm on_frame — use wland_decode_buffer", .{}),
            // SRVOBJ is browser→server only (the browser is the sender)
            .srvobj => logf("SRVOBJ frame reached wasm — browser→server only", .{}),
            .handle_open => |h| handleOpen(h),
            .handle_close => |h| js_handle_close(h.conn_id, h.handle_id),
            // JS routes COMMIT to wland_commit_notice. One that lands here
            // anyway is acked unpresented: an unacked notice would hold the
            // client's buffer forever.
            .commit => |c| {
                logf("COMMIT frame reached wland_on_frame (c{d} serial {d}) — acked unpresented", .{ c.conn_id, c.serial });
                appendAck(c.conn_id, c.serial);
            },
            .ack => logf("ACK frame reached wasm — engine→relay only", .{}),
            .feature => |f| compositor.applyFeature(f.feature, f.bytes), // FEATURE: what the relay can do
            .dmabuf_created => logf("DMABUF_CREATED frame reached wasm — engine→relay only", .{}),
            .presented => logf("PRESENTED frame reached wasm — engine→relay only", .{}),
            // session-profile frames: a session relay's (FEATURE session),
            // whose compositor is its own — this core never takes part
            .call, .event, .surface => logf("{t} frame reached wasm — session profile only (a session relay needs a viewer, not this core)", .{std.meta.activeTag(p.frame)}),
        }
    }
    flushOut();
}

/// The embedder's own clipboard selection (Compositor.setOwnSelection: the
/// packed { u32 mime_len, mime, u32 data_len | 0xffffffff, data } entries;
/// len 0 clears it if it is the embedder's). 1 = set, 0 = refused (bad, too
/// large, or the relay can't bridge it — wland_selection_bridged: the
/// selection is unchanged).
export fn wland_set_selection(ptr: [*]const u8, len: usize) u32 {
    defer flushOut();
    compositor.setOwnSelection(ptr[0..len]) catch |err| {
        logf("set_selection: {t}", .{err});
        return 0;
    };
    return 1;
}

/// Ask the clipboard selection's source client for `mime` (ptr/len); the
/// answer comes as js_selection_data(read_id, ...). 1 = asked, 0 = nothing
/// to ask (no client selection, it does not offer `mime`, or the relay
/// can't read it — wland_selection_bridged).
export fn wland_read_selection(ptr: [*]const u8, len: usize, read_id: u32, max_bytes: u32) u32 {
    defer flushOut();
    return @intFromBool(compositor.readSelection(ptr[0..len], read_id, max_bytes));
}

/// Largest integer an f64 holds exactly; handle sizes/offsets past it are
/// treated as malformed.
const max_exact_f64: u64 = 1 << 53;

fn handleOpen(h: core.stream.HandleOpenFrame) void {
    const kinds = core.stream.HandleKind;
    switch (h.kind) {
        @intFromEnum(kinds.kwshm) => if (core.stream.KwshmHandle.decode(h.bytes)) |k| {
            if (k.size <= max_exact_f64) {
                js_handle_open(h.conn_id, h.handle_id, 1, k.id, 0, 0, @floatFromInt(k.size));
                return;
            }
        } else |_| {},
        @intFromEnum(kinds.procfd) => if (core.stream.ProcfdHandle.decode(h.bytes)) |p| {
            if (p.size <= max_exact_f64 and p.offset <= max_exact_f64) {
                js_handle_open(h.conn_id, h.handle_id, 2, p.pid, p.fd, @floatFromInt(p.offset), @floatFromInt(p.size));
                return;
            }
        } else |_| {},
        else => {},
    }
    logf("HANDLE_OPEN c{d} handle {d}: unusable (kind {d}, {d} bytes)", .{ h.conn_id, h.handle_id, h.kind, h.bytes.len });
    js_handle_open(h.conn_id, h.handle_id, 0, h.kind, 0, 0, 0);
}

// The decoded COMMIT notice handed to JS (wland_commit_notice): u32 words,
// 4-byte aligned, valid until the next call. Layout (word index):
//   0 conn_id   1 surface_id   2 serial
//   3 kind      1 = shm, 2 = virtgpu (both validated, presentable); 0 = not
//               presentable (unknown buffer kind or failed validation, see
//               CommitFrame.shm/virtgpu) — ack only
//   4 n_rects   (0 when kind = 0)
//   5 …13       kind-specific:
//               shm      5 handle_id  6 offset  7 width  8 height  9 stride
//                        10 format (wl_shm)
//               virtgpu  5 resource  6 width  7 height  8 format (DRM fourcc)
//                        9 flags  10 offset  11 stride  12 modifier low 32
//                        13 modifier high 32
//  14 …         n_rects × {i32 x, y, w, h}, buffer px
// Words 4–13 are 0 when kind = 0, and unused kind-specific words are 0.
pub const notice_words = 14;
var notice: std.ArrayList(u32) = .empty;

/// Decode the COMMIT frame (STREAM.md 0x0a) at ptr[0..len] in wasm memory —
/// exactly one whole frame, as JS split it out of the link message. Returns
/// a pointer to the decoded notice (layout above), or 0 if the bytes do not
/// frame as one COMMIT (a corrupt link: nothing can be acked). Touches no
/// compositor state and sends nothing → no flush. JS must call
/// wland_commit_ack(conn_id, serial) for every notice this returns, once the
/// commit is consumed (or right away when kind = 0).
export fn wland_commit_notice(ptr: [*]const u8, len: usize) usize {
    const f = switch (core.stream.parse(ptr[0..len]) catch return 0) {
        .commit => |c| c,
        else => return 0,
    };
    var head: [notice_words]u32 = @splat(0);
    head[0] = f.conn_id;
    head[1] = f.surface_id;
    head[2] = f.serial;
    switch (f.kind) {
        @intFromEnum(core.stream.BufferKind.virtgpu) => if (f.virtgpu()) |r| {
            head[3] = 2;
            head[5..14].* = .{ r.resource, r.width, r.height, r.format, r.flags, r.offset, r.stride, @truncate(r.modifier), @truncate(r.modifier >> 32) };
        } else |err| logf("COMMIT c{d} serial {d}: not presentable ({t}, kind virtgpu)", .{ f.conn_id, f.serial, err }),
        else => if (f.shm()) |r| {
            head[3] = 1;
            head[5..11].* = .{ r.handle_id, r.offset, r.width, r.height, r.stride, r.format };
        } else |err| logf("COMMIT c{d} serial {d}: not presentable ({t}, kind {d})", .{ f.conn_id, f.serial, err, f.kind }),
    }
    const n: usize = if (head[3] != 0) f.n_rects else 0;
    head[4] = @intCast(n);
    notice.resize(gpa, notice_words + n * 4) catch return 0;
    const w = notice.items;
    w[0..notice_words].* = head;
    for (0..n) |i| {
        const rect = f.rectAt(@intCast(i));
        w[notice_words + i * 4 ..][0..4].* = .{ @bitCast(rect.x), @bitCast(rect.y), @bitCast(rect.w), @bitCast(rect.h) };
    }
    return @intFromPtr(w.ptr);
}

/// The notice `serial` on `conn_id` is consumed: send ACK (0x0b) to the
/// relay, which may then release the buffer. Exactly once per notice.
export fn wland_commit_ack(conn_id: u32, serial: u32) void {
    appendAck(conn_id, serial);
    flushOut();
}

fn appendAck(conn_id: u32, serial: u32) void {
    closeWireRun();
    const start = out_buf.items.len;
    out_buf.resize(gpa, start + core.stream.ack_len) catch return;
    core.stream.writeAck(out_buf.items[start..][0..core.stream.ack_len], conn_id, serial);
}

/// 2D presenter helper: convert a width×height rect of wl_shm BGRA/BGRX
/// pixels (rows src_stride bytes apart) at src into tight RGBA rows at dst,
/// both in wasm memory. opaque = 1 for XRGB8888 (alpha forced to 0xff);
/// ARGB8888 alpha passes through (core/src/pixels.zig). dst may equal src
/// (in-place compaction); otherwise they must not overlap. Stateless (needs
/// no wland_init) and sends nothing → no flush.
export fn wland_swizzle(src: [*]const u8, src_stride: u32, dst: [*]u8, width: u32, height: u32, @"opaque": u32) void {
    core.pixels.bgraToRgba(src, src_stride, dst, width, height, @"opaque" != 0);
}

// Scratch holding the reconstructed raw 0x02 BUFFER frame from the last
// wland_decode_buffer call. Reused each call: within one WS message JS decodes
// and presents each BUFFER_LZ synchronously before moving on, so one buffer is
// enough (and the pointer is consumed before the next decode overwrites it).
var decode_buf: std.ArrayList(u8) = .empty;

/// Decompress a BUFFER_LZ frame (the LZ4 pixel path, STREAM.md 0x07) sitting at
/// ptr[0..len] in wasm memory into a raw BUFFER (0x02) frame, also in wasm
/// memory, and return a pointer to it. JS then presents it exactly like a
/// server-sent 0x02 frame (presentBuffer over exports.memory.buffer). Returns 0
/// on malformed input. Touches no compositor state and sends nothing → no flush.
export fn wland_decode_buffer(ptr: [*]const u8, len: usize) usize {
    const p = core.stream.parseNext(ptr[0..len]) catch return 0;
    const f = switch (p.frame) {
        .buffer_lz => |bl| bl,
        else => return 0,
    };
    const prefix = core.stream.buffer_header_len + @as(usize, f.n_rects) * 16;
    const out_total = prefix + f.raw_len;
    // resize may grow wasm memory, but memory.grow never moves existing data,
    // so `ptr`/`f.comp` (a wland_alloc'd region, not decode_buf) stay valid.
    decode_buf.resize(gpa, out_total) catch return 0;
    // header + rects are byte-identical to a 0x02 frame apart from the type tag
    @memcpy(decode_buf.items[0..prefix], ptr[0..prefix]);
    decode_buf.items[0] = @intFromEnum(core.stream.FrameType.buffer);
    // the 0x02 frame must frame as exactly what it holds: raw_len = Σ w·h·4
    // of its rects (all non-empty). Else JS would present pixels past the
    // decoded ones — whatever wasm heap follows.
    const back = core.stream.parseNext(decode_buf.items) catch return 0;
    if (back.consumed != out_total) return 0;
    const pixels = decode_buf.items[prefix..][0..f.raw_len];
    const dlen = core.lz4.decompress(f.comp, pixels) orelse return 0;
    if (dlen != f.raw_len) return 0;
    return @intFromPtr(decode_buf.items.ptr);
}

/// The frame clock (rAF): presentation feedback and frame callbacks.
/// time_ms = the frame's time; age_us = how long ago it began; refresh_ns =
/// the display's frame interval (0 = unknown); flags bit 0 = a display
/// frame (presented says vsync). See Compositor.Tick.
export fn wland_tick(time_ms: u32, age_us: u32, refresh_ns: u32, flags: u32) void {
    compositor.tick(.{ .time_ms = time_ms, .age_us = age_us, .refresh_ns = refresh_ns, .vsync = flags & 1 != 0 });
    flushOut();
}

/// JS bookkeeping hook while presenting a buffer: surface sizes make up
/// window geometry, floating window sizes feed the unmaximize restore
/// configure. Sends nothing → no flush.
export fn wland_note_buffer_size(conn_id: u32, surface_id: u32, buf_w: u32, buf_h: u32) void {
    compositor.noteBufferSize(conn_id, surface_id, buf_w, buf_h);
}

// Outgoing frames accumulate here and go out as ONE WS message when the
// wasm entry point that produced them returns (flushOut in every export
// that can send) — bursts like configure storms or frame-callback fanout
// cost one send instead of dozens. Consecutive events for the same conn
// coalesce into a single WIRE frame (multiple whole messages per frame are
// legal, STREAM.md). The same coalescing as stream.Batch (the relay's and
// the native harness's), kept as globals here: through Batch it measured
// 135 B more wasm for the same bytes out.
var out_buf: std.ArrayList(u8) = .empty;
var wire_run: ?struct { conn_id: u32, off: usize } = null;

fn sendWire(ctx: ?*anyopaque, conn_id: u32, bytes: []const u8) void {
    _ = ctx;
    if (wire_run) |run| {
        if (run.conn_id != conn_id) closeWireRun();
    }
    if (wire_run == null) {
        var header: [core.stream.wire_overhead]u8 = undefined;
        core.stream.writeWireHeader(&header, conn_id, 0); // byte_len patched at close
        wire_run = .{ .conn_id = conn_id, .off = out_buf.items.len };
        out_buf.appendSlice(gpa, &header) catch return;
    }
    out_buf.appendSlice(gpa, bytes) catch return;
}

fn closeWireRun() void {
    const run = wire_run orelse return;
    wire_run = null;
    const byte_len: u32 = @intCast(out_buf.items.len - run.off - core.stream.wire_overhead);
    std.mem.writeInt(u32, out_buf.items[run.off + 5 ..][0..4], byte_len, .little);
}

fn flushOut() void {
    closeWireRun();
    if (out_buf.items.len == 0) return;
    js_send(out_buf.items.ptr, out_buf.items.len);
    out_buf.clearRetainingCapacity();
}

/// Wrap an fd-carrying wire message in an FDMSG frame (heap: keymap aux is ~68K).
fn sendFdMsg(ctx: ?*anyopaque, conn_id: u32, kind: u32, wire_bytes: []const u8, aux: []const u8) void {
    _ = ctx;
    closeWireRun();
    const total = 13 + wire_bytes.len + 4 + aux.len;
    const start = out_buf.items.len;
    out_buf.resize(gpa, start + total) catch return;
    _ = core.stream.encodeFdMsg(out_buf.items[start..], conn_id, @enumFromInt(kind), wire_bytes, aux);
}

/// Emit a SRVOBJ frame registering a server-allocated object's type with the
/// server (M13 primary offers). Goes out in the same burst as the events that
/// introduce the object, so the server records the type before the app acts.
fn sendSrvObj(ctx: ?*anyopaque, conn_id: u32, object_id: u32, kind: u32) void {
    _ = ctx;
    closeWireRun();
    const start = out_buf.items.len;
    out_buf.resize(gpa, start + core.stream.srvobj_len) catch return;
    core.stream.writeSrvObj(out_buf.items[start..][0..core.stream.srvobj_len], conn_id, object_id, kind);
}

/// DMABUF_CREATED (0x0d): a params.create made server wl_buffer `buffer_id`.
/// Same burst as (just before) the `created` event, like SRVOBJ.
fn sendDmabufCreated(ctx: ?*anyopaque, conn_id: u32, params_id: u32, buffer_id: u32) void {
    _ = ctx;
    closeWireRun();
    const start = out_buf.items.len;
    out_buf.resize(gpa, start + core.stream.dmabuf_created_len) catch return;
    core.stream.writeDmabufCreated(out_buf.items[start..][0..core.stream.dmabuf_created_len], conn_id, params_id, buffer_id);
}

/// PRESENTED (0x0e): a presented event the relay stamps with its clock.
/// In order with the WIRE around it (its sync_output events precede it).
fn sendPresented(ctx: ?*anyopaque, conn_id: u32, age_us: u32, msg: []const u8) void {
    _ = ctx;
    closeWireRun();
    const start = out_buf.items.len;
    out_buf.resize(gpa, start + core.stream.presented_header_len + msg.len) catch return;
    _ = core.stream.encodePresented(out_buf.items[start..], conn_id, age_us, msg);
}

fn selectionEvent(ctx: ?*anyopaque, conn_id: u32, mimes: []const []const u8) void {
    _ = ctx;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (mimes, 0..) |m, i| {
        if (i > 0) joined.append(gpa, 0) catch return;
        joined.appendSlice(gpa, m) catch return;
    }
    js_selection(conn_id, joined.items.ptr, joined.items.len);
}

fn surfaceEvent(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, value: u32) void {
    _ = ctx;
    js_surface_event(conn_id, surface_id, value);
}

fn interactive(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, kind: u32, value: u32) void {
    _ = ctx;
    js_interactive(conn_id, surface_id, kind, value);
}

fn cursorShape(ctx: ?*anyopaque, conn_id: u32, shape: u32) void {
    _ = ctx;
    js_cursor_shape(conn_id, shape);
}

fn cursorSurface(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, hx: i32, hy: i32) void {
    _ = ctx;
    js_cursor_surface(conn_id, surface_id, hx, hy);
}

fn textInput(ctx: ?*anyopaque, conn_id: u32, active: u32, x: i32, y: i32, w: i32, h: i32) void {
    _ = ctx;
    js_text_input(conn_id, active, x, y, w, h);
}

var region_out: [core.compositor.Region.max * 4]i32 = undefined;
fn inputRegion(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, region: ?*const core.compositor.Region) void {
    _ = ctx;
    const r = region orelse return js_input_region(conn_id, surface_id, 1, &region_out, 0);
    for (r.slice(), 0..) |b, i| {
        region_out[i * 4 ..][0..4].* = .{ b.x0, b.y0, b.x1 -| b.x0, b.y1 -| b.y0 };
    }
    js_input_region(conn_id, surface_id, 0, &region_out, @intCast(r.slice().len));
}

fn pointerLock(ctx: ?*anyopaque, conn_id: u32, surface_id: u32) void {
    _ = ctx;
    js_pointer_lock(conn_id, surface_id);
}

fn touchBound(ctx: ?*anyopaque, conn_id: u32, bound: bool) void {
    _ = ctx;
    js_touch_bound(conn_id, @intFromBool(bound));
}

fn setTitle(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, title: []const u8) void {
    _ = ctx;
    js_set_title(conn_id, surface_id, title.ptr, title.len);
}

fn setAppId(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, app_id: []const u8) void {
    _ = ctx;
    js_set_app_id(conn_id, surface_id, app_id.ptr, app_id.len);
}

fn sizeLimits(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, min_w: i32, min_h: i32, max_w: i32, max_h: i32) void {
    _ = ctx;
    js_size_limits(conn_id, surface_id, min_w, min_h, max_w, max_h);
}

fn configure(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, cfg: core.compositor.Configure, cause: u32) void {
    _ = ctx;
    js_configure(conn_id, surface_id, cfg.serial, cfg.w, cfg.h, cfg.states, cause);
}

fn acked(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, serial: u32, w: i32, h: i32) void {
    _ = ctx;
    js_acked(conn_id, surface_id, serial, w, h);
}

fn decoration(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, decorated: bool) void {
    _ = ctx;
    js_decoration(conn_id, surface_id, @intFromBool(decorated));
}

fn log(ctx: ?*anyopaque, text: []const u8) void {
    _ = ctx;
    js_log(text.ptr, text.len);
}

fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    js_log(text.ptr, text.len);
}
