// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! The browser-side wayland implementation. Transport-agnostic: consumes raw
//! wire bytes per app connection, emits wire bytes + log lines through
//! callbacks (the wasm glue wraps these in STREAM frames; native unit tests
//! capture them directly). It never touches sockets or fds; the relay does.

const std = @import("std");
const wire = @import("wire.zig");
const protocol = @import("protocol_gen.zig");
const objects = @import("objects.zig");
const stream = @import("stream.zig");

pub const Global = struct { name: u32, interface: []const u8, version: u32 };

/// Globals advertised to every app. Versions are deliberately modest — only
/// what the POC implements. All are fd-free at these versions except wl_shm
/// (create_pool) and wl_keyboard.keymap, whose fd paths the server intercepts.
pub const globals = [_]Global{
    // v5 adds wl_surface.offset (fd-free); v6 adds the preferred_buffer_scale
    // (integer fallback for non-fractional clients) and preferred_buffer_
    // transform (normal) events, sent per v6 surface at creation and resent on
    // dpr change (M11) — both fd-free.
    .{ .name = 1, .interface = "wl_compositor", .version = 6 },
    .{ .name = 2, .interface = "wl_subcompositor", .version = 1 },
    // v2 adds only the `release` request (a destructor) — the generic
    // destructor path removes the wl_shm object and answers delete_id; pools
    // are refcounted under wl_shm_pool ids, so they outlive it (spec)
    .{ .name = 3, .interface = "wl_shm", .version = 2 },
    // v8 axis_value120 (smooth wheel), v9 axis_relative_direction — all
    // fd-free (the only seat-family fd is wl_keyboard.keymap, intercepted)
    .{ .name = 4, .interface = "wl_seat", .version = 9 },
    // v3 release, v4 name/description — fd-free. The mode reports the real
    // desktop size (live-updated on resize), not a fixed fiction.
    .{ .name = 5, .interface = "wl_output", .version = 4 },
    // v3 xdg_popup.reposition, v4 configure_bounds, v5 wm_capabilities
    // (maximize only), v6 suspended toplevel state — all fd-free
    .{ .name = 6, .interface = "xdg_wm_base", .version = 6 },
    // v3: foot refuses to start below that. Selection (clipboard) works via
    // the FDMSG pipe path; dnd requests are decoded but ignored.
    .{ .name = 7, .interface = "wl_data_device_manager", .version = 3 },
    // the core draws no window decorations: with decorations_server unset
    // (the default) every toplevel is answered client_side (SSD-preferring
    // apps such as foot draw their own CSD, as they would without the
    // global); set, the embedder draws the frames and toplevels that hold a
    // decoration object are answered server_side unless they ask otherwise
    .{ .name = 8, .interface = "zxdg_decoration_manager_v1", .version = 1 },
    // M9: named cursor shapes (fd-free). Apps name a shape; the browser maps
    // it to a CSS cursor on #desktop. v1 only — the XML is upstream's v2,
    // but the two v2 shapes (35, 36) are rejected: the valid range is
    // default(1)..zoom_out(34), enforced by cursor_shape_max below.
    .{ .name = 9, .interface = "wp_cursor_shape_manager_v1", .version = 1 },
    // M11: wp_viewporter lets a surface set a destination size ≠ its buffer
    // size (the browser CSS-scales the buffer-sized canvas) — the present-path
    // half of fractional scaling. fd-free.
    .{ .name = 10, .interface = "wp_viewporter", .version = 1 },
    // M11: wp_fractional_scale_manager_v1 tells each surface the preferred
    // scale as 120ths (round(devicePixelRatio × 120)); resent live on dpr
    // change (removes the reload-on-dpr-change limit). fd-free.
    .{ .name = 11, .interface = "wp_fractional_scale_manager_v1", .version = 1 },
    // M12: zwp_text_input_manager_v3 — IME / composition. enter/leave follows
    // keyboard focus; the browser's composition events (dead keys, CJK, emoji
    // picker) become preedit_string/commit_string. fd-free.
    .{ .name = 12, .interface = "zwp_text_input_manager_v3", .version = 1 },
    // M13: zwp_primary_selection_device_manager_v1 — middle-click paste. A
    // protocol clone of wl_data_device clipboard: per-conn sources, one global
    // primary selection, offers announced on keyboard enter, receive → pipe fd
    // token (FDMSG kind 3). Its offer.receive + source.send carry fds — the
    // ONLY fd paths, both intercepted exactly like the clipboard (offers use
    // the upper server-id partition; see objects.zig).
    .{ .name = 13, .interface = "zwp_primary_selection_device_manager_v1", .version = 1 },
    // (14 is zwp_linux_dmabuf_v1, below: advertised per link)
    // zwp_relative_pointer_v1.relative_motion on every pointer motion of the
    // focused client, locked or not (pointerMotion). fd-free.
    .{ .name = 15, .interface = "zwp_relative_pointer_manager_v1", .version = 1 },
    // lock_pointer (the embedder's Pointer Lock: wanted → granted → locked,
    // see Constraint) and confine_pointer (motion clamped to the region
    // while the surface holds the pointer). fd-free.
    .{ .name = 16, .interface = "zwp_pointer_constraints_v1", .version = 1 },
    // presentation-time (Feedback, tick): feedback latched by commit, then
    // presented at the next tick or discarded. v2 only tightened what
    // `refresh` may say, v3 added the fixed_rate/variable_rate flags, which
    // are never set: the page can't tell which kind of display it is on.
    // fd-free at every version.
    .{ .name = 17, .interface = "wp_presentation", .version = 3 },
    // (18 is wland_external_buffer_manager_v1, below: advertised per link)
};

/// linux-dmabuf, advertised only when the relay takes dmabufs: it says so
/// with a FEATURE frame first on the link (setDmabuf). Not in `globals`,
/// which every link offers. FD RULE: the fds are params.add (client →
/// relay, FDMSG kind dmabuf here) and feedback.format_table (sent as FDMSG
/// kind memfd, the relay makes the fd) — both intercepted. v4 = feedback
/// (Mesa finds its render node through main_device); v5 adds only the
/// same-modifier rule, v6 set_sampling_device (fd-free, not offered).
pub const dmabuf_global: Global = .{ .name = 14, .interface = "zwp_linux_dmabuf_v1", .version = 4 };

/// wland-private: wl_buffers named by an opaque u64 the embedder resolves
/// at each commit (no fd, no pixels: FD RULE holds trivially). Advertised
/// only on a link whose relay sent FEATURE external_buffer AND whose
/// embedder resolves such ids (`external_source`): `externalOffered`.
pub const external_global: Global = .{ .name = 18, .interface = "wland_external_buffer_manager_v1", .version = 1 };

// wland_external_buffer_manager_v1.error
const external_err_invalid_format: u32 = 0;
const external_err_invalid_dimensions: u32 = 1;
const external_err_invalid_flags: u32 = 2;

// zwp_linux_buffer_params_v1.error
const dmabuf_err_already_used: u32 = 0;
const dmabuf_err_plane_idx: u32 = 1;
const dmabuf_err_plane_set: u32 = 2;
const dmabuf_err_incomplete: u32 = 3;
const dmabuf_err_invalid_format: u32 = 4;
const dmabuf_err_invalid_dimensions: u32 = 5;
const dmabuf_max_planes = 4;
/// DRM_FORMAT_MOD_INVALID: the implicit modifier (a table entry with it
/// offers the driver's own layout)
const dmabuf_mod_invalid: u64 = 0x00ff_ffff_ffff_ffff;
// wl_display.error
const display_err_invalid_object: u32 = 0;
// wl_subsurface.error
const subsurface_err_bad_surface: u32 = 0;

/// Planes a DRM format takes (create/create_immed: a mismatch is
/// `incomplete`). Single-plane unless listed; extend with the format table.
fn dmabufFormatPlanes(format: u32) u32 {
    return switch (format) {
        0x3231564e, 0x3132564e => 2, // NV12, NV21
        0x32315559, 0x32315659 => 3, // YUV420, YVU420
        else => 1,
    };
}

// wp_cursor_shape_device_v1.shape valid range at v1 (default..zoom_out) and
// the invalid_shape protocol error code. A value out of range is a protocol
// error; a stale serial is silently ignored (spec).
const cursor_shape_min: u32 = 1;
const cursor_shape_max: u32 = 34;
const cursor_shape_err_invalid_shape: u32 = 1;
/// cursor_shape_fn value meaning "no shape — reset to the default pointer"
/// (sent on pointer leave / client disconnect). App shapes are 1..34.
pub const cursor_shape_reset: u32 = 0;

// wp_viewporter.error / wp_viewport.error codes (M11)
const viewporter_err_viewport_exists: u32 = 0;
const viewport_err_bad_value: u32 = 0;
const viewport_err_bad_size: u32 = 1;
const viewport_err_no_surface: u32 = 3;
/// wp_viewport set_source unset sentinel: all four args == -1.0 in wl_fixed.
const fixed_neg_one: i32 = -256;
// wp_fractional_scale_manager_v1.error
const frac_err_fractional_scale_exists: u32 = 0;
// xdg_surface.error
const xdg_surface_err_invalid_size: u32 = 5;
// xdg_toplevel.error
const xdg_toplevel_err_invalid_size: u32 = 2;
// zwp_pointer_constraints_v1.error / .lifetime
const constraints_err_already_constrained: u32 = 1;
const constraint_lifetime_oneshot: u32 = 1;
/// wp_presentation.clock_id: CLOCK_MONOTONIC (Linux's clockid_t). The
/// timestamps come from the relay, which stamps them on its own clock as
/// they pass (STREAM.md PRESENTED) — the apps' machine, so the clients can
/// read it; the core's own clock is the page's.
const presentation_clock_monotonic: u32 = 1;
// wp_presentation_feedback.kind
const presentation_kind_vsync: u32 = 0x1;
/// preferred_scale is a fraction over this denominator (120ths).
const fractional_scale_denom: i32 = 120;

// wl_shm.format values (from wayland.xml enum)
const shm_format_argb8888: u32 = 0;
const shm_format_xrgb8888: u32 = 1;

const seat_capability_pointer: u32 = 1;
const seat_capability_keyboard: u32 = 2;
const seat_capability_touch: u32 = 4;

// wl_pointer.axis_source: our browser wheel input is always a physical wheel
const axis_source_wheel: u32 = 0;
// wl_pointer.axis_relative_direction: physical motion matches axis direction
const axis_direction_identical: u32 = 0;
// one logical wheel detent in value120 units
const value120_per_notch: i32 = 120;

// zxdg_toplevel_decoration_v1.mode
const decoration_mode_client_side: u32 = 1;
const decoration_mode_server_side: u32 = 2;
// zxdg_toplevel_decoration_v1.error
const decoration_err_unconfigured_buffer: u32 = 0;
const decoration_err_already_constructed: u32 = 1;
const decoration_err_orphaned: u32 = 2;
const decoration_err_invalid_mode: u32 = 3;

pub const output_width: i32 = 1280;
pub const output_height: i32 = 720;

pub const SendFn = *const fn (ctx: ?*anyopaque, conn_id: u32, bytes: []const u8) void;
pub const LogFn = *const fn (ctx: ?*anyopaque, text: []const u8) void;
/// Emit an fd-carrying wire message: the transport must synthesize the fd
/// (keymap: server memfd_creates from aux). See STREAM.md FDMSG.
pub const FdMsgFn = *const fn (ctx: ?*anyopaque, conn_id: u32, kind: u32, wire_bytes: []const u8, aux: []const u8) void;
/// Register the interface-kind of a server-allocated object id with the
/// transport (SRVOBJ frame). The server's fd interception can't infer the type
/// from the id (server ids are one contiguous space — objects.zig), so the
/// browser announces each primary-selection offer. See STREAM.md SRVOBJ.
pub const SrvObjFn = *const fn (ctx: ?*anyopaque, conn_id: u32, object_id: u32, kind: u32) void;
/// SRVOBJ kind: this server id is a zwp_primary_selection_offer_v1 (the server
/// then watches primary_offer.receive = opcode 0 on it). Unregistered server
/// ids default to wl_data_offer (data_offer.receive = opcode 1) in the relay.
pub const srvobj_kind_primary_offer: u32 = 1;

/// Canned us-layout xkb keymap shipped to every keyboard client.
pub const keymap_text = @embedFile("us.xkb");

// linux evdev codes the modifier tracker cares about
const key_leftshift = 42;
const key_rightshift = 54;
const key_leftctrl = 29;
const key_rightctrl = 97;
const key_leftalt = 56;
const key_rightalt = 100;
const key_leftmeta = 125;
const key_rightmeta = 126;
const key_capslock = 58;
const key_numlock = 69;

// mod masks matching the canned us keymap
const mod_shift: u32 = 1 << 0;
const mod_lock: u32 = 1 << 1;
const mod_ctrl: u32 = 1 << 2;
const mod_alt: u32 = 1 << 3;
const mod_num: u32 = 1 << 4; // Mod2: `modifier_map Mod2 { <NMLK> }`, the keypad types' NumLock
const mod_super: u32 = 1 << 6;

pub const Role = enum(u32) { none = 0, toplevel = 1, subsurface = 2, cursor = 3, popup = 4, dnd_icon = 5 };

// wl_data_device_manager.dnd_action bits
const dnd_action_copy: u32 = 1;
const dnd_action_move: u32 = 2;

/// surface_fn value meaning "this surface is gone".
pub const surface_destroyed_code: u32 = 0xffffffff;

const Surface = struct {
    xdg_surface_id: u32 = 0,
    toplevel_id: u32 = 0,
    /// xdg_popup object id when role == .popup
    popup_id: u32 = 0,
    /// wl_subsurface object id when role == .subsurface (set_position arrives on it)
    sub_obj_id: u32 = 0,
    /// parent wl_surface id for subsurfaces and popups
    parent_id: u32 = 0,
    /// role .subsurface: its place in the parent's stack (wl_subsurface
    /// z-order), as an ordering key — the parent is 0, a sibling below it
    /// negative, above it positive; only the order counts (gaps are left
    /// where siblings went). A new subsurface goes on top. place_above /
    /// place_below edit `z_pending`, which the PARENT's commit latches into
    /// `z` (double-buffered state of the parent; `stack_pending` on it).
    /// surfaceZ hands the embedder the rank, not the key.
    z: i64 = 0,
    z_pending: i64 = 0,
    /// `z` as a rank among its siblings (surfaceZ's answer), cached:
    /// valid while the conn's `ranks_dirty` is clear (rerank)
    z_rank: i32 = 0,
    /// a child's place_above / place_below since this surface last committed
    stack_pending: bool = false,
    /// offset relative to parent (subsurface set_position / popup positioner)
    x: i32 = 0,
    y: i32 = 0,
    /// wl_surface.offset (v5) / attach dx,dy — the surface-local buffer
    /// offset latched by the last commit that carried one (pending in
    /// offset_pending until then). Only a cursor surface uses it (its
    /// hotspot moves by it); canvases are not placed by it.
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    offset_pending: ?[2]i32 = null,
    /// pending popup size from the positioner (0 = client decides)
    popup_w: i32 = 0,
    popup_h: i32 = 0,
    /// role .popup: the positioner it was placed by (get_popup, its last
    /// reposition) — a reactive one is placed again when the conditions
    /// change (replaceReactive)
    rules: Positioner = .{},
    /// role .toplevel: where its window-geometry origin sits in the
    /// output, logical px, as the embedder last said (setWindowPosition);
    /// null = unknown (popups are then placed without constraint
    /// adjustment). The embedder's: reset when the xdg_toplevel goes and
    /// at a new embedder (resetEmbedderWindows).
    win_pos: ?[2]i32 = null,
    /// xdg_toplevel size hints (0 = unset), window geometry px; resize
    /// requests are clamped. set_min_size / set_max_size are double-
    /// buffered: they write the pending pair, wl_surface.commit latches it
    /// (and tells the embedder, size_limits_fn). xdg_toplevel state: reset
    /// when it goes.
    min_w: i32 = 0,
    min_h: i32 = 0,
    max_w: i32 = 0,
    max_h: i32 = 0,
    min_pending: ?[2]i32 = null,
    max_pending: ?[2]i32 = null,
    configured: bool = false,
    role: Role = .none,
    /// wl_surface.set_buffer_scale — buffer px per logical px; the browser
    /// displays the canvas at buffer_size/scale CSS px (retina crispness)
    buffer_scale: i32 = 1,
    /// xdg_toplevel window states (toplevel role only; reset when the
    /// xdg_toplevel goes). maximized and fullscreen are independent and may
    /// both be set: fullscreen wins the size, and unset_fullscreen goes
    /// back to maximized when that is still set. Both are the desktop's
    /// size; neither is "floating". minimized hides the window (no
    /// protocol state; only the embedder restores it; v6 clients get
    /// `suspended` meanwhile).
    maximized: bool = false,
    fullscreen: bool = false,
    minimized: bool = false,
    /// The embedder hides the window (setVisible false: its own window
    /// manager's reasons — a minimize effect, a compact mode showing one
    /// window): rendered for like a minimized one (frame callbacks held,
    /// presentation feedback discarded, v6 `suspended`, its subsurfaces
    /// and popups alike) without being minimized — no protocol state, no
    /// focus change, popups kept, input delivered as the embedder routes
    /// it. Only the embedder sets and clears it; reset when the
    /// xdg_toplevel goes.
    hidden: bool = false,
    /// The edges the embedder tiled the window against (setTiled; 1 top,
    /// 2 bottom, 4 left, 8 right — resize edges' bits), sent as the
    /// tiled_* states (xdg_wm_base v2) in every configure. Independent of
    /// maximized and fullscreen, as the protocol's states are. Only the
    /// embedder sets and clears it; reset when the xdg_toplevel goes.
    tiled: u32 = 0,
    /// The toplevel configures sent lately, newest at `cfg_head - 1` (a
    /// ring): what an ack_configure's serial asked for. Clients ack the
    /// latest they have seen, a few behind the newest at most.
    cfgs: [cfg_ring]Configure = undefined,
    cfg_head: u8 = 0,
    cfg_len: u8 = 0,
    /// The configure the last ack_configure named, until the commit that
    /// applies it (acked_fn); `acked` is that configure once committed.
    ack_pending: ?Configure = null,
    acked: ?Configure = null,
    /// the window's size (its geometry) when it last floated — what the
    /// unmaximize / unfullscreen configure restores (0 = never presented,
    /// client decides)
    last_w: i32 = 0,
    last_h: i32 = 0,
    /// serial of the last configure that carried a floating size the client
    /// has not applied yet (acked, then committed): until then its geometry
    /// is the old one and must not be read back as the floating size
    size_serial: ?u32 = null,
    size_acked: bool = false,
    /// zxdg_toplevel_decoration_v1 object id (0 = none)
    decoration_id: u32 = 0,
    /// The mode the client asked for (set_mode: client_side / server_side),
    /// 0 = no preference (none yet, unset_mode, or its decoration went)
    decoration_pref: u32 = 0,
    /// The last mode configured was server_side: the embedder draws the
    /// frame (what decoration_fn last told it). Back to false at the commit
    /// after the decoration object goes, and when the xdg_toplevel goes.
    decorated: bool = false,
    /// wp_viewport object id (0 = none). Crop+scale state below is
    /// double-buffered: set_source/set_destination write the *pending* copy,
    /// wl_surface.commit latches it into the *current* copy the embedder reads.
    viewport_id: u32 = 0,
    // pending viewport state (dirty = changed since the last commit)
    vp_pending_src: [4]i32 = .{ 0, 0, 0, 0 }, // x,y,w,h in wl_fixed (24.8)
    vp_pending_src_set: bool = false,
    vp_src_dirty: bool = false,
    vp_pending_dst_w: i32 = 0,
    vp_pending_dst_h: i32 = 0,
    vp_pending_dst_set: bool = false,
    vp_dst_dirty: bool = false,
    // current viewport state (post-commit) — surfaceViewSize reads these
    vp_src: [4]i32 = .{ 0, 0, 0, 0 },
    vp_src_set: bool = false,
    vp_dst_w: i32 = 0,
    vp_dst_h: i32 = 0,
    vp_dst_set: bool = false,
    /// wp_fractional_scale_v1 object id (0 = none). preferred_scale is
    /// (re)sent to it on creation and whenever the dpr changes.
    fractional_id: u32 = 0,
    /// bound wl_compositor version that created this surface — v6+ surfaces
    /// get preferred_buffer_scale/transform on creation and on dpr change.
    wl_compositor_version: u32 = 0,
    /// wl_surface.attach since the last commit: the buffer id it named
    /// (0 = attach(NULL)), or null when there was none.
    pending_attach: ?u32 = null,
    /// The surface has content — its last attach-latching commit named a
    /// buffer — and so sits on the output: wl_surface.enter was sent to
    /// every wl_output the client has bound (see setOnOutput).
    on_output: bool = false,
    /// Logical size of the last presented buffer (viewport destination, else
    /// buffer px / buffer scale), from the embedder's noteBufferSize; 0 = no
    /// content. Window geometry is computed from these.
    log_w: i32 = 0,
    log_h: i32 = 0,
    /// xdg_surface.set_window_geometry {x, y, w, h}, surface-local:
    /// double-buffered, latched by wl_surface.commit. Unset = the bounds of
    /// the surface and its subsurfaces (see windowGeometry).
    geom_pending: ?[4]i32 = null,
    geom: [4]i32 = .{ 0, 0, 0, 0 },
    geom_set: bool = false,
    /// wl_surface.set_input_region: double-buffered, latched by commit.
    /// null = infinite (the whole surface accepts pointer input): the
    /// initial value, and what a NULL wl_region sets. The region is copied
    /// at request time, so later wl_region requests don't reach it.
    input_pending: ?Region = null,
    input_pending_set: bool = false,
    input: ?Region = null,
    /// The last value surface_fn told the embedder for this surface (a
    /// Role; 0 = none, also before anything was told): what replaySurfaces
    /// tells an embedder that attaches later. Differs from `role` while a
    /// surface is unmapped (role kept, embedder told none).
    notified: u32 = 0,
};

/// A toplevel configure as the embedder hears of it (configure_fn): its
/// xdg_surface serial, the size it asked (0 = the client decides) and its
/// states as `configure_*` bits.
pub const Configure = struct { serial: u32, w: i32, h: i32, states: u32 };
/// Configure bits (configure_fn's `states`): the states the configure
/// carried, as the app was told (version-gated); the tiled edges are
/// `tiled << configure_tiled_shift` (1 top, 2 bottom, 4 left, 8 right).
pub const configure_maximized: u32 = 1;
pub const configure_fullscreen: u32 = 2;
pub const configure_activated: u32 = 4;
pub const configure_suspended: u32 = 8;
pub const configure_tiled_shift: u5 = 4;
/// Window edges, as xdg_toplevel.resize_edge's bits and setTiled's.
pub const edge_top: u32 = 1;
pub const edge_bottom: u32 = 2;
pub const edge_left: u32 = 4;
pub const edge_right: u32 = 8;
/// How many recent configures a toplevel remembers for its acks.
const cfg_ring = 8;

/// A rectangle in a surface's local coordinates, logical px.
pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

/// A wl_region's content, or a surface's input region: disjoint boxes in
/// surface-local logical px (x1/y1 exclusive), built by add/subtract in
/// request order. Fixed capacity, so it needs no heap. An add that would not
/// fit becomes the bounding box and a subtract that would not fit is
/// dropped: both keep a superset (input accepted where the client wanted
/// none — what ignoring input regions did) rather than refuse input.
pub const Region = struct {
    pub const max = 32;
    pub const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

    boxes: [max]Box = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Region) []const Box {
        return self.boxes[0..self.len];
    }

    /// A wire rect as a box; null when empty (w or h ≤ 0). Edges saturate:
    /// clients send INT32_MAX sizes for "everything".
    fn boxOf(x: i32, y: i32, w: i32, h: i32) ?Box {
        if (w <= 0 or h <= 0) return null;
        return .{ .x0 = x, .y0 = y, .x1 = x +| w, .y1 = y +| h };
    }

    /// The pieces of `b` outside `r` (0…4, disjoint) appended to out[n..].
    fn cut(b: Box, r: Box, out: []Box, n: *usize) void {
        if (r.x0 >= b.x1 or r.x1 <= b.x0 or r.y0 >= b.y1 or r.y1 <= b.y0) {
            out[n.*] = b;
            n.* += 1;
            return;
        }
        const my0 = @max(b.y0, r.y0);
        const my1 = @min(b.y1, r.y1);
        const pieces = [_]Box{
            .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = r.y0 }, // above
            .{ .x0 = b.x0, .y0 = r.y1, .x1 = b.x1, .y1 = b.y1 }, // below
            .{ .x0 = b.x0, .y0 = my0, .x1 = r.x0, .y1 = my1 }, // left
            .{ .x0 = r.x1, .y0 = my0, .x1 = b.x1, .y1 = my1 }, // right
        };
        for (pieces) |p| {
            if (p.x1 <= p.x0 or p.y1 <= p.y0) continue;
            out[n.*] = p;
            n.* += 1;
        }
    }

    /// Union with a rect. False when it had to fall back to the bounding box.
    pub fn add(self: *Region, x: i32, y: i32, w: i32, h: i32) bool {
        const r = boxOf(x, y, w, h) orelse return true;
        var out: [max * 4 + 1]Box = undefined;
        var n: usize = 0;
        for (self.slice()) |b| cut(b, r, &out, &n);
        out[n] = r;
        n += 1;
        if (n <= max) {
            @memcpy(self.boxes[0..n], out[0..n]);
            self.len = @intCast(n);
            return true;
        }
        var bb = r;
        for (self.slice()) |b| bb = .{ .x0 = @min(bb.x0, b.x0), .y0 = @min(bb.y0, b.y0), .x1 = @max(bb.x1, b.x1), .y1 = @max(bb.y1, b.y1) };
        self.boxes[0] = bb;
        self.len = 1;
        return false;
    }

    /// Difference with a rect. False when it was dropped (would not fit).
    pub fn subtract(self: *Region, x: i32, y: i32, w: i32, h: i32) bool {
        const r = boxOf(x, y, w, h) orelse return true;
        var out: [max * 4]Box = undefined;
        var n: usize = 0;
        for (self.slice()) |b| cut(b, r, &out, &n);
        if (n > max) return false;
        @memcpy(self.boxes[0..n], out[0..n]);
        self.len = @intCast(n);
        return true;
    }

    pub fn contains(self: *const Region, x: i32, y: i32) bool {
        for (self.slice()) |b| {
            if (x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1) return true;
        }
        return false;
    }

    /// Same boxes in the same order (what the same requests produce); a
    /// false "different" only costs the embedder a redundant update.
    fn eql(a: ?Region, b: ?Region) bool {
        const ra = a orelse return b == null;
        const rb = b orelse return false;
        return std.mem.eql(u8, std.mem.sliceAsBytes(ra.slice()), std.mem.sliceAsBytes(rb.slice()));
    }
};

/// xdg_positioner state: the placement rules of a popup (set_parent_size
/// and set_parent_configure, v3 hints for a parent mid-resize, are not
/// kept: placement uses the parent as it is).
const Positioner = struct {
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    anchor_w: i32 = 0,
    anchor_h: i32 = 0,
    anchor: u32 = 0,
    gravity: u32 = 0,
    dx: i32 = 0,
    dy: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    /// set_constraint_adjustment bits (adjust_*)
    adjust: u32 = 0,
    /// set_reactive (v3): placed again when the parent's window moves or
    /// the output changes
    reactive: bool = false,

    // xdg_positioner.constraint_adjustment
    const adjust_slide_x: u32 = 1;
    const adjust_slide_y: u32 = 2;
    const adjust_flip_x: u32 = 4;
    const adjust_flip_y: u32 = 8;
    const adjust_resize_x: u32 = 16;
    const adjust_resize_y: u32 = 32;

    // xdg_positioner.anchor/gravity enum: 0 none, 1 top, 2 bottom, 3 left,
    // 4 right, 5 top_left, 6 bottom_left, 7 top_right, 8 bottom_right
    fn isLeft(v: u32) bool {
        return v == 3 or v == 5 or v == 6;
    }
    fn isRight(v: u32) bool {
        return v == 4 or v == 7 or v == 8;
    }
    fn isTop(v: u32) bool {
        return v == 1 or v == 5 or v == 7;
    }
    fn isBottom(v: u32) bool {
        return v == 2 or v == 6 or v == 8;
    }

    /// Popup position: the top-left of the popup's window geometry from the
    /// parent's window geometry (xdg-shell; the anchor rect counts from it
    /// too) — what xdg_popup.configure says. Where that puts the surfaces
    /// is surfaceAbs's. Without constraint adjustment: placeWithin adds
    /// it once the embedder said where the window is (setWindowPosition).
    /// Every input is a client's i32, so the sums saturate (as does every
    /// step of the placement chain: surfaceAbs, windowGeometry).
    fn place(p: *const Positioner) struct { x: i32, y: i32 } {
        const ax = p.anchor_x +| if (isRight(p.anchor)) p.anchor_w else if (isLeft(p.anchor)) 0 else @divTrunc(p.anchor_w, 2);
        const ay = p.anchor_y +| if (isBottom(p.anchor)) p.anchor_h else if (isTop(p.anchor)) 0 else @divTrunc(p.anchor_h, 2);
        const x = (ax +| p.dx) -| (if (isLeft(p.gravity)) p.w else if (isRight(p.gravity)) 0 else @divTrunc(p.w, 2));
        const y = (ay +| p.dy) -| (if (isTop(p.gravity)) p.h else if (isBottom(p.gravity)) 0 else @divTrunc(p.h, 2));
        return .{ .x = x, .y = y };
    }

    // anchor/gravity mirrored on one axis (flip_x / flip_y)
    fn invertX(v: u32) u32 {
        return switch (v) {
            3 => 4, 4 => 3, 5 => 7, 7 => 5, 6 => 8, 8 => 6,
            else => v,
        };
    }
    fn invertY(v: u32) u32 {
        return switch (v) {
            1 => 2, 2 => 1, 5 => 6, 6 => 5, 7 => 8, 8 => 7,
            else => v,
        };
    }

    /// place() with xdg-shell's constraint adjustment against `bounds` —
    /// the output as x0, y0, x1, y1 (exclusive) in the same space as the
    /// placement (from the parent's window geometry). Per axis, only when
    /// the popup leaves the bounds on it, in the spec's order: flip
    /// (anchor and gravity mirrored, the offset too as mutter does; kept
    /// only if the flipped box fits on that axis), then slide (toward the
    /// gravity first, then back, never past the edge it came from), then
    /// resize (cut to the bounds). The size is the positioner's unless a
    /// resize cut it. An invalid positioner (no size) is placed as is.
    fn placeWithin(p: *const Positioner, bounds: [4]i32) Placed {
        const at = p.place();
        var r: Placed = .{ .x = at.x, .y = at.y, .w = p.w, .h = p.h };
        if (p.w <= 0 or p.h <= 0) return r;
        p.adjustAxis(&r.x, &r.w, bounds[0], bounds[2], true);
        p.adjustAxis(&r.y, &r.h, bounds[1], bounds[3], false);
        return r;
    }

    fn outside(pos: i32, len: i32, lo: i32, hi: i32) bool {
        return pos < lo or pos +| len > hi;
    }

    fn adjustAxis(p: *const Positioner, pos: *i32, len: *i32, lo: i32, hi: i32, comptime x_axis: bool) void {
        if (!outside(pos.*, len.*, lo, hi)) return;
        const flip = if (x_axis) adjust_flip_x else adjust_flip_y;
        const slide = if (x_axis) adjust_slide_x else adjust_slide_y;
        const resize = if (x_axis) adjust_resize_x else adjust_resize_y;
        if (p.adjust & flip != 0) {
            var q = p.*;
            if (x_axis) {
                q.anchor = invertX(q.anchor);
                q.gravity = invertX(q.gravity);
                q.dx = 0 -| q.dx;
            } else {
                q.anchor = invertY(q.anchor);
                q.gravity = invertY(q.gravity);
                q.dy = 0 -| q.dy;
            }
            const f = q.place();
            const fpos = if (x_axis) f.x else f.y;
            if (!outside(fpos, len.*, lo, hi)) {
                pos.* = fpos;
                return;
            }
        }
        if (p.adjust & slide != 0) {
            // the gravity's direction first: toward lo for left/top
            // gravity, toward hi otherwise (centred too)
            const low_first = if (x_axis) isLeft(p.gravity) else isTop(p.gravity);
            for (0..2) |pass| {
                const toward_hi = (pass == 0) != low_first;
                const end = pos.* +| len.*;
                if (toward_hi) {
                    // until the low edge is in, or the high edge would leave
                    if (pos.* < lo and end < hi) pos.* +|= @min(lo -| pos.*, hi -| end);
                } else {
                    if (end > hi and pos.* > lo) pos.* -|= @min(end -| hi, pos.* -| lo);
                }
            }
            if (!outside(pos.*, len.*, lo, hi)) return;
        }
        if (p.adjust & resize != 0) {
            const a = @max(pos.*, lo);
            const e = @min(pos.* +| len.*, hi);
            if (e > a) {
                pos.* = a;
                len.* = e -| a;
            }
        }
    }
};

/// A popup's placement: its configure's x, y, width, height.
const Placed = struct { x: i32, y: i32, w: i32, h: i32 };

/// The selection: which conn's wl_data_source currently owns the clipboard.
/// conn 0 (no relay conn has it) = the embedder's own selection
/// (setOwnSelection), `source` then its generation (`own_gen`). Also what
/// an offer proxies (Conn.offers): `dnd` marks an offer of the embedder's
/// own drag (beginOwnDrag; conn 0, `source` = its generation).
const Selection = struct { conn: u32, source: u32, dnd: bool = false };

/// The embedder's own drag (beginOwnDrag: an HTML drag from the page): the
/// types it offers and the source actions, from its start; the payloads
/// only once the embedder has them (setOwnDragData — a page's drop event
/// is the first time it can read them). A receive on one of its offers
/// before that is held (`held`) and answered when they come, or read EOF
/// when its offer stops being the drag's target or the drag ends without
/// them. Kept past the drop (receives come after it) until the next own
/// drag, the drop target's `finish`, or its conn closing.
const OwnDrag = struct {
    gen: u32,
    /// owned, offered in this order
    mimes: std.ArrayList([]u8) = .empty,
    /// dnd_action_copy / dnd_action_move bits
    actions: u32,
    /// the payloads (null: not given yet); an empty one = none at all
    data: ?OwnSelection = null,
    held: std.ArrayList(HeldReceive) = .empty,
    /// the conn the drop went to (0: not dropped)
    dropped_conn: u32 = 0,
    /// the drop went with its bytes still to come (dragDropBytes(true)):
    /// receives on the drop's offers (`drop_offers`) wait for them
    awaiting: bool = false,
    drop_offers: [max_seat_objects]u32 = undefined,
    drop_offer_n: u8 = 0,
    /// the action the embedder was last told (drag_action_fn)
    told: u32 = 0,

    const HeldReceive = struct { conn: u32, offer: u32, token: u32, mime: []u8 };

    fn deinit(self: *OwnDrag, gpa: std.mem.Allocator) void {
        for (self.mimes.items) |m| gpa.free(m);
        self.mimes.deinit(gpa);
        if (self.data) |*d| d.deinit(gpa);
        for (self.held.items) |h| gpa.free(h.mime);
        self.held.deinit(gpa);
    }

    fn offers(self: *const OwnDrag, mime: []const u8) bool {
        for (self.mimes.items) |m| if (std.mem.eql(u8, m, mime)) return true;
        return false;
    }

    /// `offer` of `conn` was one the drop went to, and its bytes are still
    /// to come: a receive on it waits
    fn awaitsOn(self: *const OwnDrag, conn: u32, offer: u32) bool {
        return self.awaiting and self.data == null and conn == self.dropped_conn and offer != 0 and
            std.mem.indexOfScalar(u32, self.drop_offers[0..self.drop_offer_n], offer) != null;
    }
};
/// Most receives an own drag holds while its payloads are not known (one
/// per offered type of each data device, comfortably); one more reads EOF.
pub const own_drag_max_held = 64;

/// The embedder's own clipboard selection (setOwnSelection): data the core
/// holds; the relay writes it into a receiver's pipe from its copy (FDMSG
/// own_pipe — STREAM.md). Mime types may share a blob.
const OwnSelection = struct {
    /// owned copies, one per distinct payload
    blobs: std.ArrayList([]u8) = .empty,
    /// mime (owned) → index into `blobs`
    entries: std.ArrayList(struct { mime: []u8, blob: u32 }) = .empty,
    /// bit i: blob i went to the relay on this link (FDMSG own_pipe with
    /// its bytes; the relay keeps it). At most
    /// own_selection_max_mimes blobs exist (one per distinct mime at most).
    sent: u32 = 0,

    fn deinit(self: *OwnSelection, gpa: std.mem.Allocator) void {
        for (self.blobs.items) |b| gpa.free(b);
        for (self.entries.items) |e| gpa.free(e.mime);
        self.blobs.deinit(gpa);
        self.entries.deinit(gpa);
    }

    fn data(self: *const OwnSelection, mime: []const u8) ?[]const u8 {
        return self.blobs.items[self.blobOf(mime) orelse return null];
    }

    fn blobOf(self: *const OwnSelection, mime: []const u8) ?u32 {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.mime, mime)) return e.blob;
        return null;
    }
};

/// Largest own selection (all its blobs) the embedder may set: a pipe write
/// is one FDMSG frame, well inside a link record (256 MiB).
pub const own_selection_max: usize = 64 << 20;
/// Most mime types an own selection may offer.
pub const own_selection_max_mimes = 32;
/// Longest mime type (bytes) the core keeps or routes: a source's longer
/// `offer` is ignored, a `receive` naming one reads EOF. Mime types are
/// echoed in events (offer, target, send) whose encode buffers are fixed;
/// RFC 6838 allows 127 + "/" + 127.
pub const max_mime_len = 256;
/// Most mime types one client source keeps (each is an event per offer).
pub const max_source_mimes = 128;
/// Most objects of one seat kind (wl_pointer, wl_keyboard, wl_data_device,
/// primary selection device, relative pointer) a client gets events on.
/// Every one of them gets every event (SeatObjects), so the cap bounds both
/// the core's memory and the fan-out; a toolkit makes one per wl_seat
/// binding (Firefox: GTK's and its own = 2). One beyond it is ignored like
/// the spec's other bad requests without an error code: the object exists
/// and stays silent.
pub const max_seat_objects = 8;
/// Most touch points one client has down at once (a touchscreen's ten
/// fingers); a down beyond them is ignored, its motion and up too.
pub const max_touch_points = 10;

/// A touch point of a client's (Conn.touch_points): the embedder's id from
/// its touchDown to its touchUp, the surface it went down on (motion keeps
/// naming it, wherever the finger goes) and the down's serial — what a
/// move/resize may name while the point is down (touchGrab).
const TouchPoint = struct { id: i32, surface: u32, serial: u32 };

/// The objects of one kind a client made for the one seat — from every
/// wl_seat binding it holds (Firefox binds wl_seat twice: GTK's, whose
/// objects its input handling listens on, and its own) — in creation
/// order, each with its version (the binding's it came from): seat events
/// go to every one, version-gated per object, with one serial. Released or
/// destroyed objects leave it. Fixed-size: at most max_seat_objects.
const SeatObjects = struct {
    items: [max_seat_objects]Obj = undefined,
    len: u8 = 0,

    const Obj = struct { id: u32, version: u32 };

    fn slice(s: *const SeatObjects) []const Obj {
        return s.items[0..s.len];
    }

    /// false: full (the object is ignored)
    fn add(s: *SeatObjects, id: u32, version: u32) bool {
        for (s.items[0..s.len]) |*o| if (o.id == id) {
            o.version = version; // a reused id (the old object went unseen)
            return true;
        };
        if (s.len == max_seat_objects) return false;
        s.items[s.len] = .{ .id = id, .version = version };
        s.len += 1;
        return true;
    }

    /// Order-preserving: events keep going out in creation order.
    fn remove(s: *SeatObjects, id: u32) void {
        for (s.items[0..s.len], 0..) |o, i| if (o.id == id) {
            std.mem.copyForwards(Obj, s.items[i .. s.len - 1], s.items[i + 1 .. s.len]);
            s.len -= 1;
            return;
        };
    }
};

/// An in-flight dnd session (wl_data_device.start_drag). The embedder owns
/// pointer tracking — it drives dragMotion/dragDrop/dragCancel like a
/// move/resize grab — and the compositor owns all protocol sequencing.
/// Offers allocated at each target register in `Conn.offers` exactly like
/// selection offers, so the server's receive/pipe interception carries dnd
/// transfers with no server change.
const Drag = struct {
    /// conn that requested start_drag (the origin surface's owner); 0 for
    /// the embedder's own drag (`own`)
    source_conn: u32,
    /// wl_data_source id; 0 = client-internal drag (null source): only the
    /// source client's own surfaces are entered, and nothing transfers
    source_id: u32,
    origin_surface: u32,
    /// dnd_icon-role surface on source_conn (0 = none)
    icon_surface: u32,
    focus_conn: u32 = 0,
    focus_surface: u32 = 0,
    /// server-allocated wl_data_offers at the current target, one per
    /// wl_data_device of its client (none over nothing or during a
    /// null-source drag); accept / set_actions count on any of them
    focus_offers: [max_seat_objects]u32 = undefined,
    focus_offer_n: u8 = 0,
    /// last wl_data_offer.accept named a mime (a drop without this cancels)
    accepted: bool = false,
    /// The embedder's own drag (beginOwnDrag; Compositor.own_drag holds its
    /// types and payloads): no source client to tell anything, no origin or
    /// icon surface, no drag-start/drag-end for the embedder (it began it).
    own: bool = false,
    /// own drags: the target's set_actions came (`action` is what was
    /// negotiated, 0 = none), since its enter
    negotiated: bool = false,
    action: u32 = 0,

    fn isFocusOffer(d: *const Drag, offer_id: u32) bool {
        return offer_id != 0 and std.mem.indexOfScalar(u32, d.focus_offers[0..d.focus_offer_n], offer_id) != null;
    }

    /// The target went (left, destroyed, its conn closed): no focus.
    fn clearFocus(d: *Drag) void {
        d.focus_conn = 0;
        d.focus_surface = 0;
        d.focus_offer_n = 0;
        d.accepted = false;
        d.negotiated = false;
        d.action = 0;
    }
};

const Conn = struct {
    objects: objects.ObjectMap = .{},
    serial: u32 = 0,
    /// The output scale this app is shown, pinned (1…4) whatever the page's
    /// (`setConnScale`; a CONN_SCALE: wlandr `--lodpi` pins 1); 0 = the
    /// page's (`output_scale`, `scale_120`). See `scaleOf`.
    scale_pin: i32 = 0,
    surfaces: std.AutoHashMapUnmanaged(u32, Surface) = .empty,
    /// a subsurface's current stack (z), parent or role changed since the
    /// cached ranks (`Surface.z_rank`) were computed (restacked)
    ranks_dirty: bool = false,
    positioners: std.AutoHashMapUnmanaged(u32, Positioner) = .empty,
    /// wl_region id → its content (copied into a surface by set_input_region)
    regions: std.AutoHashMapUnmanaged(u32, Region) = .empty,
    /// wl_surface.frame callbacks, in request order (see tick). Only reached
    /// on links where the engine paces apps (STREAM.md "Frame callbacks").
    frame_callbacks: std.ArrayList(FrameCallback) = .empty,
    /// wp_presentation_feedback objects, in request order (see Feedback)
    feedbacks: std.ArrayList(Feedback) = .empty,
    /// bound wl_output object ids — the embedder pushes a fresh mode + done
    /// to each when the desktop resizes (live mode)
    output_ids: std.ArrayList(u32) = .empty,
    /// wl_pointer / wl_keyboard objects, from every wl_seat binding (see
    /// SeatObjects). Focus is the conn's, held whether or not it has any:
    /// one made while its client has focus is sent the enter at once.
    pointers: SeatObjects = .{},
    keyboards: SeatObjects = .{},
    /// wl_touch objects (every one gets every touch event). Points exist
    /// only while there is one: the last released forgets them.
    touches: SeatObjects = .{},
    /// the points down now (TouchPoint), in down order
    touch_points: [max_touch_points]TouchPoint = undefined,
    touch_n: u8 = 0,
    /// a touch event went out since the last wl_touch.frame (touchFrame
    /// sends one only then)
    touch_unframed: bool = false,
    pointer_focus: u32 = 0,
    /// serial of the latest pointer enter (one serial, sent to every
    /// wl_pointer; a late wl_pointer's enter repeats it) —
    /// wp_cursor_shape_device_v1.set_shape and wl_pointer.set_cursor must
    /// echo it or be ignored
    pointer_enter_serial: u32 = 0,
    /// serial of the latest keyboard enter (a late wl_keyboard's repeats it)
    keyboard_enter_serial: u32 = 0,
    /// The implicit grab (see `inImplicitGrab`): the buttons this conn saw
    /// pressed and not yet released (bit = evdev code & 31), the serials of
    /// the presses that made it (first and latest: wrapping range) and the
    /// surface the first went to. An enter or leave ends it (the embedder
    /// handed the pointer elsewhere: the release goes elsewhere too).
    buttons_held: u32 = 0,
    grab_serial_first: u32 = 0,
    grab_serial_last: u32 = 0,
    grab_surface: u32 = 0,
    /// The serials of this conn's latest input events (key, button,
    /// keyboard and pointer enter), a ring written at input_serial_next:
    /// what a selection request from it may name once it lost keyboard
    /// focus (maySetSelection). 0 = unused (serials start at 1).
    input_serials: [8]u32 = @splat(0),
    input_serial_next: u8 = 0,
    /// The cursor surface set_cursor named for the current enter (0 = none:
    /// a shape, hidden, or nothing set yet) and its hotspot, surface-local
    /// logical px (offsets committed to the surface move it, per spec).
    /// Cleared on leave: the next enter needs a fresh set_cursor.
    cursor_surface: u32 = 0,
    cursor_hx: i32 = 0,
    cursor_hy: i32 = 0,
    /// The shape set_shape last set for the current enter (0 = none: a
    /// cursor surface, or nothing set yet), for replaySeat.
    cursor_shape: u32 = 0,
    /// xdg_toplevel.set_title and set_app_id, by wl_surface id (owned
    /// copies), for replaySurfaces; dropped with the surface or its
    /// xdg_toplevel.
    titles: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    app_ids: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// where the pointer is in pointer_focus's local px (wl_fixed): the
    /// last enter or motion as the client saw it (clamped while confined,
    /// frozen while locked), and that motion's time
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    pointer_time: u32 = 0,
    /// zwp_relative_pointer_v1 objects (they share the seat's pointer
    /// focus, whichever wl_pointer each was made for)
    relative_pointers: SeatObjects = .{},
    /// pointer constraint object id → its state (see Constraint)
    constraints: std.AutoHashMapUnmanaged(u32, Constraint) = .empty,
    /// the surface whose lock the embedder was last told this conn wants (0 none)
    lock_surface: u32 = 0,
    keyboard_focus: u32 = 0,
    mods_depressed: u32 = 0,
    /// wl_data_device objects (one per get_data_device: GTK and Firefox
    /// make one per wl_seat binding); each gets its own wl_data_offers
    data_devices: SeatObjects = .{},
    /// wl_data_source id → MIME types it offered (owned copies)
    source_mimes: std.AutoHashMapUnmanaged(u32, std.ArrayList([]u8)) = .empty,
    /// wl_data_source id → dnd action bitmask from set_actions (v3)
    source_actions: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// wl_data_offer ids we allocated for this conn → the selection each
    /// proxies (selection may move on; stale offers keep routing to their
    /// original source)
    offers: std.AutoHashMapUnmanaged(u32, Selection) = .empty,
    /// server-allocated object ids for THIS conn — wl_data_offer AND
    /// zwp_primary_selection_offer_v1 both draw from this ONE contiguous
    /// counter (libwayland requires dense server ids — objects.zig). The two
    /// types are told apart by which map an id lands in (offers vs
    /// primary_offers), and the server learns primary offers via a SRVOBJ frame.
    next_server_id: u32 = objects.server_id_base,
    // ---- primary selection (M13), a mirror of the clipboard fields above ----
    /// zwp_primary_selection_device_v1 objects (each gets its own offers)
    primary_devices: SeatObjects = .{},
    /// zwp_primary_selection_source_v1 id → MIME types it offered (owned copies)
    primary_source_mimes: std.AutoHashMapUnmanaged(u32, std.ArrayList([]u8)) = .empty,
    /// server-allocated zwp_primary_selection_offer_v1 id → the primary
    /// selection it proxies (mirrors `offers`, stale offers keep routing)
    primary_offers: std.AutoHashMapUnmanaged(u32, Selection) = .empty,
    /// wp_viewport / wp_fractional_scale_v1 object id → its wl_surface id.
    /// Kept separate from the Surface (which dies with its wl_surface) so a
    /// request on a viewport whose surface was destroyed can raise no_surface.
    viewports: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    frac_scales: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// zwp_text_input_v3 object id (one seat → at most one text input; 0 none).
    text_input_id: u32 = 0,
    /// surface the text input is entered on (follows keyboard focus; 0 = not
    /// entered). enter/leave events reference it — cleared SILENTLY (no leave)
    /// when its surface is destroyed, mirroring the keyboard-focus gotcha.
    ti_focus_surface: u32 = 0,
    /// current (committed) enabled state and the pending copy applied on commit
    ti_enabled: bool = false,
    ti_pending_enable: bool = false,
    /// commit count — echoed as the serial of every done event (spec)
    ti_serial: u32 = 0,
    /// current + pending set_cursor_rectangle (surface-local px); surfaced to
    /// the embedder so the OS IME candidate window can sit by the text cursor
    ti_cursor: TextCursorRect = .{},
    ti_pending_cursor: TextCursorRect = .{},
    /// zwp_linux_buffer_params_v1 id → the planes `add` set so far. The fds
    /// and plane geometry are the relay's; only what protocol errors need
    /// lives here.
    dmabuf_params: std.AutoHashMapUnmanaged(u32, DmabufParams) = .empty,
};

const DmabufParams = struct {
    /// bit i = plane i was added
    planes: u8 = 0,
    modifiers: [dmabuf_max_planes]u64 = @splat(0),
    /// create/create_immed was issued: only destroy is legal now
    used: bool = false,
};

const TextCursorRect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

/// A wl_surface.frame callback. The request is double-buffered surface
/// state: `committed` flips when its surface commits, and only committed
/// callbacks fire at the next tick (presentation).
const FrameCallback = struct { surface: u32, id: u32, committed: bool = false };

/// A wp_presentation_feedback. Double-buffered like a frame callback:
/// `latched` flips at its surface's next commit (the content update it
/// reports on). A latched one ends at the next tick — presented when the
/// surface is on screen then (surfaceShown), else discarded — or earlier,
/// discarded, when its surface commits again first (superseded: the view
/// draws a commit when it arrives, so only the last one before a frame is
/// ever composited) or is destroyed. Every one ends with exactly one of
/// the two destructor events, then delete_id. On every link type: nothing
/// intercepts it in the relay, which only stamps the time (STREAM.md
/// PRESENTED).
const Feedback = struct { surface: u32, id: u32, latched: bool = false };

/// A zwp_locked_pointer_v1 or zwp_confined_pointer_v1 (keyed by its object
/// id in Conn.constraints). The core decides when it applies; only a lock
/// needs the embedder, whose browser grants Pointer Lock asynchronously:
///   inactive → (its surface has pointer focus, the pointer inside region ∩
///   input region) → lock: wanted (pointer_lock_fn names the surface; the
///   embedder asks the browser) → granted (pointerLockGranted): active,
///   `locked` · confine: active at once, `confined`
///   active → (focus lost, the surface destroyed, the browser lost the lock:
///   pointerLockLost) → `unlocked`/`unconfined`, then inactive again when
///   persistent, defunct when oneshot (the object lives on, inert).
/// A wanted lock whose conditions stop holding goes back to inactive.
const Constraint = struct {
    surface: u32,
    lock: bool,
    persistent: bool,
    state: enum { inactive, wanted, active, defunct } = .inactive,
    /// where the pointer must be (with the surface's input region); null =
    /// the input region alone. Copied at request time, like set_input_region.
    region: ?Region = null,
    /// set_region, latched by its surface's commit
    region_pending: ?Region = null,
    region_pending_set: bool = false,
    /// zwp_locked_pointer_v1.set_cursor_position_hint (wl_fixed, surface-
    /// local), latched by commit. Advisory, and unused: a page can't move
    /// the OS pointer when the lock ends.
    hint: ?[2]i32 = null,
    hint_pending: ?[2]i32 = null,
};

/// A motion's relative part (zwp_relative_pointer_v1.relative_motion):
/// deltas in wl_fixed logical px, unclipped (they keep coming while the
/// pointer is locked), and the timestamp in µs.
pub const Relative = struct { dx: i32, dy: i32, dx_unaccel: i32, dy_unaccel: i32, utime: u64 };

pub const Compositor = struct {
    gpa: std.mem.Allocator,
    ctx: ?*anyopaque,
    send_fn: SendFn,
    log_fn: LogFn,
    fdmsg_fn: ?FdMsgFn = null,
    /// Announce a server-allocated object's type to the transport (M13 primary
    /// offers). Null in tests that don't exercise the primary receive path.
    srvobj_fn: ?SrvObjFn = null,
    /// Toplevel title changed (xdg_toplevel.set_title); surface_id lets the
    /// embedder label each window (taskbar) rather than just the page.
    title_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, title: []const u8) void = null,
    /// Toplevel app id changed (xdg_toplevel.set_app_id): the embedder
    /// matches a window to its app (a dock's icon, a launcher).
    app_id_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, app_id: []const u8) void = null,
    /// A commit changed a toplevel's size hints (set_min_size /
    /// set_max_size, double-buffered), window geometry px, 0 = unset; all
    /// four 0 again when its xdg_toplevel goes (if any was set).
    size_limits_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, min_w: i32, min_h: i32, max_w: i32, max_h: i32) void = null,
    /// A toplevel's decoration mode changed (Surface.decorated): true =
    /// server_side was configured, the embedder draws its frame; false =
    /// client-side again (set_mode, the embedder's setDecorations, its
    /// decoration object or xdg_toplevel gone). Told at the configure that
    /// carries the mode, so before the first buffer of a toplevel that made
    /// its decoration object before its initial commit.
    decoration_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, decorated: bool) void = null,
    /// Every xdg_toplevel configure the core sends (with its xdg_surface
    /// serial): the size it asks (0 = the client decides) and the states
    /// as `configure_*` bits. `cause` is the embedder's token for the call
    /// that made it (`cause` below; 0 = anything else: the app's request,
    /// focus, bounds, the initial configure). The embedder learns the
    /// serial its own call produced from it (a session call returns
    /// nothing).
    configure_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, cfg: Configure, cause: u32) void = null,
    /// A commit applied a toplevel configure the app acked since its last
    /// commit (ack_configure, then wl_surface.commit): which one, and the
    /// size it had asked. Told before what the commit shows reaches the
    /// embedder (its pixel frames follow the WIRE that carried it).
    acked_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, serial: u32, w: i32, h: i32) void = null,
    /// Surface role changed (value = Role) or surface destroyed (value = destroyed_code).
    surface_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, value: u32) void = null,
    /// App-initiated interactive request the embedder must act on (window
    /// positions live browser-side): kind 0 = start move drag (CSD titlebar),
    /// kind 1 = start resize drag (value = edges bitmask: 1 top, 2 bottom,
    /// 4 left, 8 right), kind 2 = maximized, kind 3 = unmaximized, kind 6
    /// = fullscreen, kind 7 = unfullscreen, kind 8 = minimized (hide the
    /// window), kind 9 = restored (show, raise and focus it) — state kinds
    /// on every change, whoever asked (the app's request or the embedder's
    /// setMaximized/setFullscreen/setMinimized). Kinds 4/5 are dnd.
    interactive_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, kind: u32, value: u32) void = null,
    /// wp_cursor_shape_device_v1.set_shape accepted (value = shape 1..34) or
    /// the pointer left (value = cursor_shape_reset = 0). The embedder maps
    /// the shape to a CSS cursor on the client's windows.
    cursor_shape_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, shape: u32) void = null,
    /// The pointer image is a cursor surface (wl_pointer.set_cursor, see
    /// Conn.cursor_surface): surface_id's committed buffer, hotspot hx,hy in
    /// its surface-local logical px. surface_id 0 = no image: the pointer is
    /// hidden (set_cursor NULL, the surface has no buffer yet or any more,
    /// or it was destroyed). Re-sent when the hotspot or the content state
    /// changes; new pixels alone arrive as the surface's commits.
    cursor_surface_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, hx: i32, hy: i32) void = null,
    /// zwp_text_input_v3 focus/enable state changed for the given conn (M12).
    /// active = 1 when the focused client has an ENABLED text input (the
    /// embedder should route composition to this conn and place its hidden IME
    /// sink at the cursor rect), 0 when disabled / focus lost. x/y/w/h are the
    /// current set_cursor_rectangle (surface-local px; 0 = unset).
    text_input_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, active: u32, x: i32, y: i32, w: i32, h: i32) void = null,
    /// A commit changed a surface's input region (wl_surface.set_input_region):
    /// null = infinite (the whole surface), else the region's boxes. The
    /// embedder does pointer picking, so it is the one that applies it;
    /// the pointer is valid only during the call.
    input_region_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32, region: ?*const Region) void = null,
    /// The pointer lock the conn wants changed (see Constraint): surface_id
    /// is the surface a lock_pointer is waiting on or active for, 0 = none
    /// any more. The embedder locks the browser's pointer to that surface
    /// and reports the grant (pointerLockGranted) and the loss
    /// (pointerLockLost); `locked` goes out only on the grant.
    pointer_lock_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, surface_id: u32) void = null,
    /// The conn now has a wl_touch (bound: its first get_touch) or none any
    /// more (its last released). Touch calls for a conn without one are
    /// ignored: the embedder sends that client the finger as a pointer.
    /// Nothing is told when the conn closes (its CONN_CLOSE says it).
    touch_bound_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, bound: bool) void = null,
    /// A wp_presentation_feedback.presented event (`msg`, one whole wire
    /// message) whose timestamp the transport must replace: the core's is
    /// the page's frame time, which no client can read. The transport
    /// sends it as a PRESENTED frame and the relay writes its own
    /// CLOCK_MONOTONIC less `age_us` (how long before the tick the frame
    /// began, on the page's clock). Null: sent as is (unit tests).
    presented_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, age_us: u32, msg: []const u8) void = null,
    conns: std.AutoHashMapUnmanaged(u32, *Conn) = .empty,
    /// Something a subsurface's or popup's place hangs on may have changed
    /// since takePositionsDirty last cleared it: an offset (set_position,
    /// a popup's placement), a window-geometry offset, a stack order, a
    /// role or parent, a surface made or destroyed. The embedder reads
    /// positions and ranks again only then (its 'position' events).
    positions_dirty: bool = false,
    /// clipboard: the current selection source, if any
    selection: ?Selection = null,
    /// primary selection (M13): the current source, if any. Independent of the
    /// clipboard selection but structurally identical.
    primary_selection: ?Selection = null,
    /// The conn the latest key, button or keyboard enter went to (0: none
    /// yet): a selection request without keyboard focus is honoured only
    /// from it (maySetSelection).
    last_input_conn: u32 = 0,
    /// The embedder's own clipboard selection, while `selection` names it
    /// (conn 0, source = own_gen); freed when a client replaces it.
    own_selection: ?OwnSelection = null,
    /// Generation of the own selection (never 0: offer source 0 = orphaned).
    own_gen: u32 = 0,
    /// The clipboard selection changed (a client set or cleared it, its
    /// source or conn went, or the embedder set its own): `conn_id` owns it
    /// now (0 = the embedder's own, or none when `mimes` is empty; a client
    /// with no `mimes`: it cleared the selection), `mimes` what it offers,
    /// valid only during the call. Not the primary.
    selection_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, mimes: []const []const u8) void = null,
    /// in-flight dnd session, if any (normal pointer delivery is suppressed)
    drag: ?Drag = null,
    /// The embedder's own drag's types and payloads (beginOwnDrag): while
    /// `drag.own` and after its drop (see OwnDrag).
    own_drag: ?OwnDrag = null,
    /// Generation of the last own drag (never 0).
    own_drag_gen: u32 = 0,
    /// What the target of the embedder's own drag would do with a drop
    /// now changed: `action` dnd_action_copy / dnd_action_move, 0 = nothing
    /// (no target, not accepted, no common action) — a page's dropEffect.
    /// Told on changes only, and 0 when the drag ends.
    drag_action_fn: ?*const fn (ctx: ?*anyopaque, action: u32) void = null,
    /// wl_output scale advertised to clients (browser devicePixelRatio,
    /// rounded to an integer). Set before any conn binds wl_output.
    output_scale: i32 = 1,
    /// wp_fractional_scale preferred scale as 120ths (round(dpr × 120)); the
    /// non-integer companion to output_scale. Updated live on dpr change.
    scale_120: i32 = fractional_scale_denom,
    /// Logical desktop area available to windows (the browser #desktop);
    /// maximize configures use it. Updated by the embedder on window resize.
    desk_w: i32 = output_width,
    desk_h: i32 = output_height,
    /// The embedder draws window frames (setDecorations; lib's
    /// `decorations: 'server'`): a toplevel holding a decoration object is
    /// configured server_side unless it asks for client_side. false (the
    /// default): every toplevel is client_side.
    decorations_server: bool = false,
    /// The work area the embedder set (setBounds), w×h, 0×0 = unset (the
    /// desktop's size): configure_bounds, and a maximized toplevel's size.
    /// `deco_bounds` is the same for decorated toplevels (smaller by the
    /// embedder's frame; 0×0 = `bounds`). The core adds no frame itself.
    bounds: [2]i32 = .{ 0, 0 },
    deco_bounds: [2]i32 = .{ 0, 0 },
    /// true while the browser tab is hidden — mapped v6 toplevels are told
    /// via the xdg_toplevel suspended state so they can stop rendering.
    suspended: bool = false,
    /// The embedder call being made carries this token (wasm and session
    /// set it around requestResize / setMaximized / setFullscreen /
    /// setTiled): every toplevel configure it produces is told with it
    /// (configure_fn). 0 between calls.
    cause: u32 = 0,
    /// linux-dmabuf as the relay offers it (its FEATURE frame); null = the
    /// relay takes no dmabufs and zwp_linux_dmabuf_v1 is not advertised.
    dmabuf: ?Dmabuf = null,
    /// The embedder can draw GPU buffers (COMMIT kind virtgpu: lib/engine.ts
    /// `EngineOptions.gpu`). false: a relay whose dmabuf commits are GPU
    /// resources (FEATURE dmabuf_kind) gets no linux-dmabuf here, so GPU
    /// clients fall back to wl_shm instead of drawing windows nobody can
    /// show. Default true: an embedder that doesn't say is trusted to.
    gpu_source: bool = true,
    /// The relay bridges the clipboard for the embedder (FEATURE
    /// selection_cache, first on the link): it reads selections for it
    /// (FDMSG pipe_read) and serves receives of its own selection from a
    /// copy (own_pipe; serveOwn sends each payload once). false (a relay
    /// that predates it, wlandr 0.1.0): neither frame is ever sent —
    /// readSelection is false, setOwnSelection refuses, so no client is
    /// offered a selection the relay can't serve (its paste would block on
    /// a pipe nobody writes).
    selection_bridge: bool = false,
    /// FEATURE dmabuf_kind named a buffer kind this embedder can't show
    /// (the kind): linux-dmabuf is not offered on this link.
    dmabuf_unshowable: ?u32 = null,
    /// The embedder resolves external buffer ids to images (COMMIT kind
    /// external; wasm `wland_set_gpu_source` bit 1). Default false: native
    /// users (the session relay, harnesses) never offer it by accident.
    external_source: bool = false,
    /// The relay tracks external buffers (FEATURE external_buffer, first
    /// on the link). With `external_source`: `externalOffered`.
    external_relay: bool = false,
    /// The seat's locked modifiers (wl_keyboard.modifiers `locked`): Caps
    /// Lock (mod_lock) and NumLock (mod_num), one keyboard for every client.
    /// NumLock starts on (a PC's usual state; keypad keys type digits), the
    /// lock keys toggle them, and the embedder sets both from the browser's
    /// real state (keyboardLocks) before the keys that depend on them.
    mods_locked: u32 = mod_num,
    /// zwp_linux_buffer_params_v1.create made server-allocated wl_buffer
    /// `buffer_id` from `params_id` (the transport sends DMABUF_CREATED:
    /// the relay ties the params' fds to the new id). Called just before
    /// the `created` event.
    dmabuf_created_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, params_id: u32, buffer_id: u32) void = null,

    pub const Dmabuf = struct {
        /// dev_t of the device clients allocate on (feedback main_device)
        main_device: u64,
        /// the format table (stream.DmabufFeature layout: 16-byte entries
        /// {u32 fourcc, u32 0, u64 modifier}), owned
        table: []u8,

        fn count(self: Dmabuf) usize {
            return self.table.len / 16;
        }

        fn entry(self: Dmabuf, i: usize) struct { format: u32, modifier: u64 } {
            const e = self.table[i * 16 ..][0..16];
            return .{ .format = std.mem.readInt(u32, e[0..4], .little), .modifier = std.mem.readInt(u64, e[8..16], .little) };
        }

        fn supports(self: Dmabuf, format: u32, modifier: u64) bool {
            for (0..self.count()) |i| {
                const e = self.entry(i);
                if (e.format == format and e.modifier == modifier) return true;
            }
            return false;
        }
    };

    pub fn init(gpa: std.mem.Allocator, ctx: ?*anyopaque, send_fn: SendFn, log_fn: LogFn) Compositor {
        return .{ .gpa = gpa, .ctx = ctx, .send_fn = send_fn, .log_fn = log_fn };
    }

    pub fn deinit(self: *Compositor) void {
        var it = self.conns.valueIterator();
        while (it.next()) |conn| {
            self.destroyConn(conn.*);
        }
        self.conns.deinit(self.gpa);
        if (self.dmabuf) |d| self.gpa.free(d.table);
        if (self.own_selection) |*own| own.deinit(self.gpa);
        if (self.own_drag) |*own| own.deinit(self.gpa);
    }

    /// The relay takes dmabufs (FEATURE linux_dmabuf, before any conn):
    /// advertise zwp_linux_dmabuf_v1 with this device and format table
    /// (whole 16-byte entries, 1…256 of them — stream.DmabufFeature.decode
    /// checked). Registries already sent don't learn of it.
    pub fn setDmabuf(self: *Compositor, main_device: u64, table: []const u8) !void {
        if (table.len < 16 or table.len % 16 != 0 or table.len / 16 > 256) return error.BadFormatTable;
        const owned = try self.gpa.dupe(u8, table);
        if (self.dmabuf) |d| self.gpa.free(d.table);
        self.dmabuf = .{ .main_device = main_device, .table = owned };
        self.logf("linux-dmabuf: {d} formats, main device 0x{x}", .{ owned.len / 16, main_device });
    }

    /// A FEATURE frame (STREAM.md 0x0c), `kind` and `bytes` raw: what the
    /// relay can do. linux_dmabuf → setDmabuf, unless dmabuf_kind named a
    /// buffer kind this embedder can't show (then linux-dmabuf stays off,
    /// whichever of the two came first; one log line). Unknown kinds and
    /// bad bytes are logged and skipped — never fatal to the link.
    pub fn applyFeature(self: *Compositor, kind: u32, bytes: []const u8) void {
        switch (kind) {
            @intFromEnum(stream.FeatureKind.linux_dmabuf) => {
                const d = stream.DmabufFeature.decode(bytes) catch {
                    self.logf("FEATURE linux_dmabuf: bad bytes ({d}); dmabuf not offered", .{bytes.len});
                    return;
                };
                if (self.dmabuf_unshowable != null) return; // logged at dmabuf_kind
                self.setDmabuf(d.main_device, d.table) catch |err| self.logf("FEATURE linux_dmabuf: {t}", .{err});
            },
            @intFromEnum(stream.FeatureKind.dmabuf_kind) => {
                // bad bytes: how dmabuf commits arrive is unknown — don't offer it
                const k: u32 = if (stream.DmabufKindFeature.decode(bytes)) |f| f.buffer_kind else |_| 0;
                const showable = switch (k) {
                    @intFromEnum(stream.BufferKind.shm) => true,
                    @intFromEnum(stream.BufferKind.virtgpu) => self.gpu_source,
                    else => false,
                };
                if (showable or self.dmabuf_unshowable != null) return;
                self.dmabuf_unshowable = k;
                if (self.dmabuf) |d| self.gpa.free(d.table);
                self.dmabuf = null;
                if (k == @intFromEnum(stream.BufferKind.virtgpu)) {
                    self.logf("linux-dmabuf not offered: the relay's dmabuf buffers are GPU resources (COMMIT kind virtgpu) and this embedder has no GPU source; GPU clients fall back to wl_shm", .{});
                } else {
                    self.logf("linux-dmabuf not offered: the relay's dmabuf commits are buffer kind {d}, which this engine cannot show ({d} feature bytes)", .{ k, bytes.len });
                }
            },
            @intFromEnum(stream.FeatureKind.selection_cache) => {
                self.selection_bridge = true;
                // a new link's relay holds nothing yet
                if (self.own_selection) |*own| own.sent = 0;
            },
            @intFromEnum(stream.FeatureKind.external_buffer) => {
                self.external_relay = true;
                if (self.external_source) {
                    self.logf("wland_external_buffer_manager_v1 offered", .{});
                } else {
                    self.logf("wland_external_buffer_manager_v1 not offered: the relay names external buffers but this embedder resolves none", .{});
                }
            },
            else => self.logf("FEATURE {d}: unknown, skipped", .{kind}),
        }
    }

    /// wland_external_buffer_manager_v1 is advertised (and bindable) on
    /// this link: the relay tracks such buffers and the embedder resolves
    /// them. Read at each get_registry and bind, so the two facts may
    /// arrive in either order (both come before any conn on a link).
    pub fn externalOffered(self: *const Compositor) bool {
        return self.external_relay and self.external_source;
    }

    fn destroyConn(self: *Compositor, conn: *Conn) void {
        inline for (.{ &conn.titles, &conn.app_ids }) |map| {
            var it = map.valueIterator();
            while (it.next()) |t| self.gpa.free(t.*);
            map.deinit(self.gpa);
        }
        conn.objects.deinit(self.gpa);
        conn.surfaces.deinit(self.gpa);
        conn.positioners.deinit(self.gpa);
        conn.regions.deinit(self.gpa);
        conn.frame_callbacks.deinit(self.gpa);
        conn.feedbacks.deinit(self.gpa);
        conn.output_ids.deinit(self.gpa);
        var mimes_it = conn.source_mimes.valueIterator();
        while (mimes_it.next()) |list| self.freeMimes(list);
        conn.source_mimes.deinit(self.gpa);
        conn.source_actions.deinit(self.gpa);
        conn.offers.deinit(self.gpa);
        var primary_mimes_it = conn.primary_source_mimes.valueIterator();
        while (primary_mimes_it.next()) |list| self.freeMimes(list);
        conn.primary_source_mimes.deinit(self.gpa);
        conn.primary_offers.deinit(self.gpa);
        conn.viewports.deinit(self.gpa);
        conn.frac_scales.deinit(self.gpa);
        conn.dmabuf_params.deinit(self.gpa);
        conn.constraints.deinit(self.gpa);
        self.gpa.destroy(conn);
    }

    fn freeMimes(self: *Compositor, list: *std.ArrayList([]u8)) void {
        for (list.items) |mime| self.gpa.free(mime);
        list.deinit(self.gpa);
    }

    /// A CONN_OPEN. conn 0 is never a client (STREAM.md: it names the
    /// embedder's own selection — Selection.conn, the 'selection' event)
    /// and an open conn can't be opened again (its state would leak).
    pub fn connOpen(self: *Compositor, conn_id: u32) !void {
        if (conn_id == 0) return error.ReservedConnId;
        if (self.conns.contains(conn_id)) return error.ConnAlreadyOpen;
        const conn = try self.gpa.create(Conn);
        errdefer self.gpa.destroy(conn);
        conn.* = .{};
        errdefer conn.objects.deinit(self.gpa);
        try conn.objects.put(self.gpa, 1, protocol.find("wl_display").?, 1);
        try self.conns.put(self.gpa, conn_id, conn);
        self.logf("conn {d} open", .{conn_id});
    }

    pub fn connClose(self: *Compositor, conn_id: u32) void {
        if (self.last_input_conn == conn_id) self.last_input_conn = 0;
        if (self.conns.fetchRemove(conn_id)) |kv| {
            // a lock it wanted or held is the embedder's to let go
            if (kv.value.lock_surface != 0) {
                if (self.pointer_lock_fn) |f| f(self.ctx, conn_id, 0);
            }
            self.destroyConn(kv.value);
        }
        if (self.selection) |sel| {
            if (sel.conn == conn_id) {
                self.selection = null;
                self.broadcastSelection();
                self.notifySelection();
            }
        }
        if (self.primary_selection) |sel| {
            if (sel.conn == conn_id) {
                self.primary_selection = null;
                self.broadcastPrimarySelection();
            }
        }
        if (self.drag) |*drag| {
            if (!drag.own and drag.source_conn == conn_id) {
                drag.source_id = 0; // conn (and its source) already gone
                self.dragCancel();
            } else if (drag.focus_conn == conn_id) {
                drag.clearFocus();
            }
        }
        // the embedder's drag: the conn's held receives read EOF (the relay
        // parks their fds by token, not by conn); a drop it took is over
        if (self.own_drag) |*own| {
            if (own.dropped_conn == conn_id) {
                self.dropOwnDrag();
            } else self.settleOwnDrag();
        }
        self.logf("conn {d} closed", .{conn_id});
    }

    // wl_buffer.release never originates here: the server releases buffers
    // itself right after snapshotting the commit's pixels (see STREAM.md).

    /// Surface role for the embedder: input must only target toplevels, and
    /// cursor surfaces must not be shown as windows.
    pub fn surfaceRole(self: *Compositor, conn_id: u32, surface_id: u32) Role {
        const conn = self.conns.get(conn_id) orelse return .none;
        const surface = conn.surfaces.get(surface_id) orelse return .none;
        return surface.role;
    }

    /// Buffer px per logical px (wl_surface.set_buffer_scale); the embedder
    /// displays the canvas at buffer_size/scale logical px.
    pub fn surfaceScale(self: *Compositor, conn_id: u32, surface_id: u32) i32 {
        const conn = self.conns.get(conn_id) orelse return 1;
        const surface = conn.surfaces.get(surface_id) orelse return 1;
        return surface.buffer_scale;
    }

    /// wp_viewport-imposed surface-local size (logical px), or {0,0} when no
    /// viewport constrains it (the embedder then falls back to buffer/scale).
    /// destination size wins; else a set source rectangle's size (integer,
    /// enforced by bad_size). This size IS the surface-local coordinate space,
    /// so the embedder's CSS box = this size keeps pointer coords correct.
    pub fn surfaceViewSize(self: *Compositor, conn_id: u32, surface_id: u32) struct { w: i32, h: i32 } {
        const conn = self.conns.get(conn_id) orelse return .{ .w = 0, .h = 0 };
        const surface = conn.surfaces.get(surface_id) orelse return .{ .w = 0, .h = 0 };
        if (surface.vp_dst_set) return .{ .w = surface.vp_dst_w, .h = surface.vp_dst_h };
        if (surface.vp_src_set) return .{ .w = @divTrunc(surface.vp_src[2], 256), .h = @divTrunc(surface.vp_src[3], 256) };
        return .{ .w = 0, .h = 0 };
    }

    pub const toplevel_maximized: u32 = 1;
    pub const toplevel_fullscreen: u32 = 2;
    pub const toplevel_minimized: u32 = 4;

    /// A toplevel's window states as bits (toplevel_maximized | _fullscreen
    /// | _minimized; 0 for any other surface). Maximized and fullscreen
    /// toplevels sit at the desktop origin, a minimized one is hidden: the
    /// embedder enforces it on every present because apps can START
    /// maximized or fullscreen (saved session state) before any window
    /// container exists.
    pub fn toplevelState(self: *Compositor, conn_id: u32, surface_id: u32) u32 {
        const conn = self.conns.get(conn_id) orelse return 0;
        const surface = conn.surfaces.get(surface_id) orelse return 0;
        if (surface.role != .toplevel) return 0;
        var bits: u32 = 0;
        if (surface.maximized) bits |= toplevel_maximized;
        if (surface.fullscreen) bits |= toplevel_fullscreen;
        if (surface.minimized) bits |= toplevel_minimized;
        return bits;
    }

    /// What the embedder knows about the frame a tick stands for.
    pub const Tick = struct {
        /// the frame's time, ms on the embedder's clock: wl_callback.done's
        /// argument, and the placeholder in `presented` (presented_fn)
        time_ms: u32,
        /// µs between the frame's start and this tick (rAF runs a little
        /// after the frame's timestamp); the relay subtracts it
        age_us: u32 = 0,
        /// the display's frame interval, ns; 0 = unknown (no display)
        refresh_ns: u32 = 0,
        /// the frame is a display's (the browser's rAF, composited without
        /// tearing): presented says vsync. Not for a timer (headless).
        vsync: bool = false,
    };

    /// Presentation tick (the embedder calls it from its frame clock, rAF):
    /// the content committed since the last tick is now on screen. Ends
    /// every latched wp_presentation_feedback (presented or discarded, see
    /// Feedback), then fires wl_callback.done + delete_id for every frame
    /// callback whose surface has committed since the request. Callbacks
    /// still pending (no commit yet) wait for a later tick — wl_surface.frame
    /// is double-buffered state, latched by wl_surface.commit (wayland.xml).
    ///
    /// Frame callbacks reach here only on links whose frame callbacks the
    /// engine fires (byte-stream links, STREAM.md "Frame callbacks"). Over
    /// WebSocket the relay intercepts wl_surface.frame and fires done
    /// itself, so that half is a no-op there — never both, or the app gets a
    /// fatal double done. Presentation feedback is the core's on every link.
    /// A minimized or hidden window's callbacks are held until it is
    /// restored or shown — on stream links only: the relay's own (WS) keep
    /// their 16 ms pace.
    pub fn tick(self: *Compositor, t: Tick) void {
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn_id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            if (conn.feedbacks.items.len > 0) self.presentFeedbacks(conn_id, conn, t);
            var keep: usize = 0;
            for (conn.frame_callbacks.items) |cb| {
                // a minimized (or hidden) window's surfaces are not
                // repainted: their callbacks wait for the window to come
                // back (the client's render loop stops, as on any
                // compositor)
                if (!cb.committed or underHidden(conn, cb.surface)) {
                    conn.frame_callbacks.items[keep] = cb;
                    keep += 1;
                    continue;
                }
                self.sendEvent(conn_id, cb.id, "wl_callback", "done", &.{.{ .uint = t.time_ms }});
                conn.objects.remove(cb.id);
                self.deleteId(conn_id, cb.id);
            }
            conn.frame_callbacks.shrinkRetainingCapacity(keep);
        }
    }

    /// wl_surface.commit latches the surface's pending frame callbacks.
    fn latchFrameCallbacks(conn: *Conn, surface_id: u32) void {
        for (conn.frame_callbacks.items) |*cb| {
            if (cb.surface == surface_id) cb.committed = true;
        }
    }

    /// wl_surface.destroy: its frame callbacks (pending or committed) die
    /// with it — delete_id, no done, like weston/wlroots destroying the
    /// callback resources.
    fn dropFrameCallbacks(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        var keep: usize = 0;
        for (conn.frame_callbacks.items) |cb| {
            if (cb.surface != surface_id) {
                conn.frame_callbacks.items[keep] = cb;
                keep += 1;
                continue;
            }
            conn.objects.remove(cb.id);
            self.deleteId(conn_id, cb.id);
        }
        conn.frame_callbacks.shrinkRetainingCapacity(keep);
    }

    /// tick: every latched feedback ends — presented if its surface is on
    /// screen now (sync_output per bound wl_output, then presented), else
    /// discarded. Pending ones (no commit yet) wait.
    fn presentFeedbacks(self: *Compositor, conn_id: u32, conn: *Conn, t: Tick) void {
        const presented_op = comptime protocol.find("wp_presentation_feedback").?.eventIndex("presented").?;
        var keep: usize = 0;
        for (conn.feedbacks.items) |fb| {
            if (!fb.latched) {
                conn.feedbacks.items[keep] = fb;
                keep += 1;
                continue;
            }
            if (!surfaceShown(conn, fb.surface)) {
                self.endFeedback(conn_id, conn, fb.id);
                continue;
            }
            for (conn.output_ids.items) |output_id| {
                self.sendEvent(conn_id, fb.id, "wp_presentation_feedback", "sync_output", &.{.{ .object = output_id }});
            }
            // the page's time as a placeholder: the relay writes its own
            // (presented_fn). seq 0: a page has no vblank counter.
            var buf: [wire.header_size + 7 * 4]u8 = undefined;
            const msg = wire.encodeMessage(&buf, fb.id, presented_op, &.{
                .{ .uint = 0 },
                .{ .uint = t.time_ms / 1000 },
                .{ .uint = (t.time_ms % 1000) * std.time.ns_per_ms },
                .{ .uint = t.refresh_ns },
                .{ .uint = 0 },
                .{ .uint = 0 },
                .{ .uint = if (t.vsync) presentation_kind_vsync else 0 },
            });
            if (self.presented_fn) |f| f(self.ctx, conn_id, t.age_us, msg) else self.send_fn(self.ctx, conn_id, msg);
            conn.objects.remove(fb.id);
            self.deleteId(conn_id, fb.id);
        }
        conn.feedbacks.shrinkRetainingCapacity(keep);
    }

    /// `discarded` + delete_id: the feedback's content update never showed.
    fn endFeedback(self: *Compositor, conn_id: u32, conn: *Conn, id: u32) void {
        self.sendEvent(conn_id, id, "wp_presentation_feedback", "discarded", &.{});
        conn.objects.remove(id);
        self.deleteId(conn_id, id);
    }

    /// wl_surface.commit: the surface's pending feedbacks latch to this
    /// content update; those still waiting for an earlier one of this
    /// surface are discarded — it was superseded before any frame showed it.
    fn latchFeedbacks(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        var keep: usize = 0;
        for (conn.feedbacks.items) |fb| {
            if (fb.surface == surface_id and fb.latched) {
                self.endFeedback(conn_id, conn, fb.id);
                continue;
            }
            var kept = fb;
            if (kept.surface == surface_id) kept.latched = true;
            conn.feedbacks.items[keep] = kept;
            keep += 1;
        }
        conn.feedbacks.shrinkRetainingCapacity(keep);
    }

    /// wl_surface.destroy: its feedbacks, latched or not, are discarded.
    fn dropFeedbacks(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        var keep: usize = 0;
        for (conn.feedbacks.items) |fb| {
            if (fb.surface == surface_id) {
                self.endFeedback(conn_id, conn, fb.id);
                continue;
            }
            conn.feedbacks.items[keep] = fb;
            keep += 1;
        }
        conn.feedbacks.shrinkRetainingCapacity(keep);
    }

    /// The surface's content is on screen: it has some (on_output) and a
    /// role the embedder shows — a toplevel, popup or dnd icon, the conn's
    /// current cursor image, or a subsurface of a surface that is shown.
    fn surfaceShown(conn: *const Conn, surface_id: u32) bool {
        if (underHidden(conn, surface_id)) return false;
        var id = surface_id;
        // a subsurface chain is acyclic (wl_subcompositor's bad_parent);
        // the bound only guards the walk
        for (0..32) |_| {
            const surface = conn.surfaces.get(id) orelse return false;
            if (!surface.on_output) return false;
            switch (surface.role) {
                .toplevel, .popup, .dnd_icon => return true,
                .cursor => return id == conn.cursor_surface,
                .subsurface => id = surface.parent_id,
                .none => return false,
            }
        }
        return false;
    }

    /// The toplevel at the root of a surface's parent chain (subsurfaces
    /// and popups alike), or null (no toplevel there).
    fn rootToplevel(conn: *const Conn, surface_id: u32) ?*const Surface {
        var id = surface_id;
        for (0..32) |_| {
            const surface = conn.surfaces.getPtr(id) orelse return null;
            if (surface.parent_id == 0) return if (surface.role == .toplevel) surface else null;
            id = surface.parent_id;
        }
        return null;
    }

    /// The surface belongs to a minimized window.
    fn underMinimized(conn: *const Conn, surface_id: u32) bool {
        const top = rootToplevel(conn, surface_id) orelse return false;
        return top.minimized;
    }

    /// The surface belongs to a window that is not on screen: minimized,
    /// or hidden by the embedder (setVisible). Its frame callbacks wait and
    /// its presentation feedback is discarded.
    fn underHidden(conn: *const Conn, surface_id: u32) bool {
        const top = rootToplevel(conn, surface_id) orelse return false;
        return top.minimized or top.hidden;
    }

    /// Process a batch of whole wire messages from an app.
    pub fn onWire(self: *Compositor, conn_id: u32, bytes: []const u8) !void {
        const conn = self.conns.get(conn_id) orelse {
            self.logf("wire for unknown conn {d}", .{conn_id});
            return;
        };
        var rest = bytes;
        while (rest.len > 0) {
            const header = wire.Header.parse(rest) catch |err| {
                self.logf("c{d}: bad header: {t}", .{ conn_id, err });
                return;
            };
            if (rest.len < header.size) {
                self.logf("c{d}: split message (len {d} < {d})", .{ conn_id, rest.len, header.size });
                return;
            }
            const msg_bytes = rest[0..header.size];
            rest = rest[header.size..];
            try self.handleMessage(conn_id, conn, header, msg_bytes[wire.header_size..]);
        }
    }

    fn handleMessage(self: *Compositor, conn_id: u32, conn: *Conn, header: wire.Header, body: []const u8) !void {
        const entry = conn.objects.get(header.object_id) orelse {
            self.logf("c{d}: unknown@{d} opcode {d}", .{ conn_id, header.object_id, header.opcode });
            return;
        };
        const iface = entry.iface;
        if (header.opcode >= iface.requests.len) {
            self.logf("c{d}: {s}@{d} bad opcode {d}", .{ conn_id, iface.name, header.object_id, header.opcode });
            return;
        }
        const msg = &iface.requests[header.opcode];
        var vals: [wire.max_args]wire.Value = undefined;
        const args = wire.decodeArgs(body, msg.args, &vals) catch |err| {
            self.logf("c{d}: {s}@{d}.{s} decode failed: {t}", .{ conn_id, iface.name, header.object_id, msg.name, err });
            return;
        };

        var log_buf: [512]u8 = undefined;
        self.log_fn(self.ctx, formatMessage(&log_buf, conn_id, iface, header.object_id, msg, args));

        try conn.objects.trackNewIds(self.gpa, msg, args, entry.version);

        if (std.mem.eql(u8, iface.name, "wl_display")) {
            if (std.mem.eql(u8, msg.name, "sync")) {
                const cb = args[0].new_id;
                conn.serial += 1;
                self.sendEvent(conn_id, cb, "wl_callback", "done", &.{.{ .uint = conn.serial }});
                conn.objects.remove(cb);
                self.deleteId(conn_id, cb);
            } else if (std.mem.eql(u8, msg.name, "get_registry")) {
                self.sendGlobals(conn_id, args[0].new_id);
            }
            return;
        }
        if (std.mem.eql(u8, iface.name, "wl_registry") and std.mem.eql(u8, msg.name, "bind")) {
            const bound = args[1].new_id_dynamic;
            if (std.mem.eql(u8, bound.interface, dmabuf_global.interface) and self.dmabuf == null) {
                // never advertised on this link: the relay could not take its fds
                self.sendError(conn_id, header.object_id, display_err_invalid_object, "zwp_linux_dmabuf_v1 is not advertised");
                return;
            }
            if (std.mem.eql(u8, bound.interface, external_global.interface) and !self.externalOffered()) {
                // the relay would not name its buffers, or nothing on the page resolves them
                self.sendError(conn_id, header.object_id, display_err_invalid_object, "wland_external_buffer_manager_v1 is not advertised");
                return;
            }
            self.onBind(conn_id, conn, bound.interface, bound.version, bound.id);
            return;
        }
        if (std.mem.eql(u8, iface.name, "wl_seat")) {
            // every wl_seat binding's objects get the seat's events (a
            // client may bind it twice: Firefox), at their binding's version
            const id = args[0].new_id;
            if (std.mem.eql(u8, msg.name, "get_pointer")) {
                if (!conn.pointers.add(id, entry.version)) return self.seatObjectIgnored(conn_id, "wl_pointer", id);
                self.latePointerEnter(conn_id, conn, id, entry.version);
            } else if (std.mem.eql(u8, msg.name, "get_keyboard")) {
                if (!conn.keyboards.add(id, entry.version)) return self.seatObjectIgnored(conn_id, "wl_keyboard", id);
                self.sendKeymap(conn_id, id, entry.version);
                self.lateKeyboardEnter(conn_id, conn, id);
            } else if (std.mem.eql(u8, msg.name, "get_touch")) {
                // (no late downs: a point already down stays the other
                // objects'; the next down reaches this one too)
                const was = conn.touches.len;
                if (!conn.touches.add(id, entry.version)) return self.seatObjectIgnored(conn_id, "wl_touch", id);
                if (was == 0) {
                    if (self.touch_bound_fn) |f| f(self.ctx, conn_id, true);
                }
            }
            return;
        }
        if (std.mem.eql(u8, iface.name, "wl_compositor") and std.mem.eql(u8, msg.name, "create_surface")) {
            const surface_id = args[0].new_id;
            try conn.surfaces.put(self.gpa, surface_id, .{ .wl_compositor_version = entry.version });
            // v6: tell the surface our preferred integer buffer scale + transform
            if (entry.version >= 6) self.sendPreferredBuffer(conn_id, surface_id);
        } else if (std.mem.eql(u8, iface.name, "wl_compositor") and std.mem.eql(u8, msg.name, "create_region")) {
            try conn.regions.put(self.gpa, args[0].new_id, .{});
        } else if (std.mem.eql(u8, iface.name, "wl_region") and
            (std.mem.eql(u8, msg.name, "add") or std.mem.eql(u8, msg.name, "subtract")))
        {
            if (conn.regions.getPtr(header.object_id)) |region| {
                const add = std.mem.eql(u8, msg.name, "add");
                const exact = if (add)
                    region.add(args[0].int, args[1].int, args[2].int, args[3].int)
                else
                    region.subtract(args[0].int, args[1].int, args[2].int, args[3].int);
                if (!exact) self.logf("c{d}: wl_region@{d} over {d} boxes: {s} approximated (a superset)", .{ conn_id, header.object_id, Region.max, msg.name });
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_wm_base") and std.mem.eql(u8, msg.name, "get_xdg_surface")) {
            const xdg_id = args[0].new_id;
            const surface_id = args[1].object;
            if (conn.surfaces.getPtr(surface_id)) |surface| surface.xdg_surface_id = xdg_id;
        } else if (std.mem.eql(u8, iface.name, "xdg_surface") and std.mem.eql(u8, msg.name, "set_window_geometry")) {
            if (args[2].int <= 0 or args[3].int <= 0) {
                self.sendError(conn_id, header.object_id, xdg_surface_err_invalid_size, "window geometry size must be positive");
            } else if (surfaceByXdgId(conn, header.object_id)) |surface| {
                surface.geom_pending = .{ args[0].int, args[1].int, args[2].int, args[3].int };
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and std.mem.eql(u8, msg.name, "set_title")) {
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                const surface_id = surfaceIdOf(conn, surface);
                const title = args[0].string orelse "";
                self.keepString(&conn.titles, surface_id, title);
                if (self.title_fn) |title_fn| title_fn(self.ctx, conn_id, surface_id, title);
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and std.mem.eql(u8, msg.name, "set_app_id")) {
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                const surface_id = surfaceIdOf(conn, surface);
                const app_id = args[0].string orelse "";
                self.keepString(&conn.app_ids, surface_id, app_id);
                if (self.app_id_fn) |f| f(self.ctx, conn_id, surface_id, app_id);
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and
            (std.mem.eql(u8, msg.name, "set_min_size") or std.mem.eql(u8, msg.name, "set_max_size")))
        {
            // pending until commit (min > max is checked there: the pair
            // may change in either order before it)
            if (args[0].int < 0 or args[1].int < 0) {
                self.sendError(conn_id, header.object_id, xdg_toplevel_err_invalid_size, "min/max size must not be negative");
            } else if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                const size: [2]i32 = .{ args[0].int, args[1].int };
                if (msg.name[5] == 'i') surface.min_pending = size else surface.max_pending = size;
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and
            (std.mem.eql(u8, msg.name, "move") or std.mem.eql(u8, msg.name, "resize")))
        {
            // CSD titlebar / border drag; args = seat, serial[, edges]. The
            // embedder owns the drag, and starts it only for a press still
            // held on this window (inImplicitGrab) or a touch point still
            // down on it (touchGrab): the request of a slow
            // client can arrive after the release, and a grab started then
            // follows a pointer with no button down until the next click.
            // Not while fullscreen (it neither moves nor resizes).
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                const id = surfaceIdOf(conn, surface);
                const is_move = msg.name[0] == 'm';
                if (surface.fullscreen) {
                    // its size and place are the desktop's
                } else if (inImplicitGrab(conn, args[1].uint, id) or touchGrab(conn, args[1].uint, id)) {
                    // a finger's: the embedder's drag follows it from here,
                    // so the client's touch sequence ends (as a gesture's).
                    // (touchGrab first: a down's serial between two held
                    // presses also passes inImplicitGrab's range test)
                    if (touchGrab(conn, args[1].uint, id)) self.cancelTouches(conn_id, conn);
                    if (self.interactive_fn) |f| f(self.ctx, conn_id, id, if (is_move) 0 else 1, if (is_move) 0 else args[2].uint);
                } else {
                    self.logf("c{d}: xdg_toplevel.{s} with serial {d} outside a held press or touch — ignored", .{ conn_id, msg.name, args[1].uint });
                }
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and
            (std.mem.eql(u8, msg.name, "set_maximized") or std.mem.eql(u8, msg.name, "unset_maximized")))
        {
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                self.applyMaximized(conn_id, conn, surface, msg.name[0] == 's');
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and
            (std.mem.eql(u8, msg.name, "set_fullscreen") or std.mem.eql(u8, msg.name, "unset_fullscreen")))
        {
            // set_fullscreen's output (nullable) is a preference; there is
            // one output, the desktop
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                self.applyFullscreen(conn_id, conn, surface, msg.name[0] == 's');
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and std.mem.eql(u8, msg.name, "set_minimized")) {
            // no protocol state and no unset: the window hides until the
            // embedder restores it (setMinimized). Ignored before the
            // initial configure (applyMinimized).
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                if (!surface.configured) self.logf("c{d}: set_minimized before the initial commit, ignored", .{conn_id});
                self.applyMinimized(conn_id, conn, surface, true);
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_surface") and std.mem.eql(u8, msg.name, "ack_configure")) {
            // a floating size we sent is applied by the commit after its ack
            // (or the ack of a later configure)
            if (surfaceByXdgId(conn, header.object_id)) |surface| {
                if (surface.size_serial) |serial| {
                    if (args[0].uint -% serial < 0x8000_0000) surface.size_acked = true;
                }
                // what it asked, for the embedder at the commit (acked_fn)
                if (surface.role == .toplevel) {
                    if (configureOf(surface, args[0].uint)) |cfg| surface.ack_pending = cfg;
                }
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_surface") and std.mem.eql(u8, msg.name, "get_toplevel")) {
            if (surfaceByXdgId(conn, header.object_id)) |surface| {
                surface.toplevel_id = args[0].new_id;
                surface.role = .toplevel;
                self.positions_dirty = true;
                self.notifySurface(conn_id, surfaceIdOf(conn, surface), @intFromEnum(Role.toplevel));
            }
        } else if (std.mem.eql(u8, iface.name, "wl_subcompositor") and std.mem.eql(u8, msg.name, "get_subsurface")) {
            if (conn.surfaces.getPtr(args[1].object)) |surface| {
                surface.role = .subsurface;
                surface.sub_obj_id = args[0].new_id;
                surface.parent_id = args[2].object;
                // on top of its siblings and parent, in the current stack
                // and the pending one alike
                var top: i64 = 0;
                var top_pending: i64 = 0;
                var it = conn.surfaces.iterator();
                while (it.next()) |kv| {
                    const sib = kv.value_ptr;
                    if (kv.key_ptr.* == args[1].object or sib.role != .subsurface or sib.parent_id != surface.parent_id) continue;
                    top = @max(top, sib.z);
                    top_pending = @max(top_pending, sib.z_pending);
                }
                surface.z = top + 1;
                surface.z_pending = top_pending + 1;
                self.restacked(conn);
                self.notifySurface(conn_id, args[1].object, @intFromEnum(Role.subsurface));
            }
        } else if (std.mem.eql(u8, iface.name, "wl_subsurface") and std.mem.eql(u8, msg.name, "set_position")) {
            if (surfaceBySubObjId(conn, header.object_id)) |surface| {
                // applied at once, not at the parent's commit (plan.md
                // "Current limits")
                surface.x = args[0].int;
                surface.y = args[1].int;
                self.positions_dirty = true;
            }
        } else if (std.mem.eql(u8, iface.name, "wl_subsurface") and
            (std.mem.eql(u8, msg.name, "place_above") or std.mem.eql(u8, msg.name, "place_below")))
        {
            self.placeSubsurface(conn_id, conn, header.object_id, args[0].object, std.mem.eql(u8, msg.name, "place_above"));
        } else if (std.mem.eql(u8, iface.name, "xdg_wm_base") and std.mem.eql(u8, msg.name, "create_positioner")) {
            try conn.positioners.put(self.gpa, args[0].new_id, .{});
        } else if (std.mem.eql(u8, iface.name, "xdg_positioner")) {
            if (conn.positioners.getPtr(header.object_id)) |pos| {
                if (std.mem.eql(u8, msg.name, "set_size")) {
                    pos.w = args[0].int;
                    pos.h = args[1].int;
                } else if (std.mem.eql(u8, msg.name, "set_anchor_rect")) {
                    pos.anchor_x = args[0].int;
                    pos.anchor_y = args[1].int;
                    pos.anchor_w = args[2].int;
                    pos.anchor_h = args[3].int;
                } else if (std.mem.eql(u8, msg.name, "set_anchor")) {
                    pos.anchor = args[0].uint;
                } else if (std.mem.eql(u8, msg.name, "set_gravity")) {
                    pos.gravity = args[0].uint;
                } else if (std.mem.eql(u8, msg.name, "set_offset")) {
                    pos.dx = args[0].int;
                    pos.dy = args[1].int;
                } else if (std.mem.eql(u8, msg.name, "set_constraint_adjustment")) {
                    pos.adjust = args[0].uint;
                } else if (std.mem.eql(u8, msg.name, "set_reactive")) {
                    pos.reactive = true;
                } else if (std.mem.eql(u8, msg.name, "destroy")) {
                    _ = conn.positioners.remove(header.object_id);
                }
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_surface") and std.mem.eql(u8, msg.name, "get_popup")) {
            if (surfaceByXdgId(conn, header.object_id)) |surface| {
                surface.role = .popup;
                surface.popup_id = args[0].new_id;
                self.positions_dirty = true;
                self.notifySurface(conn_id, surfaceIdOf(conn, surface), @intFromEnum(Role.popup));
                if (args[1].object != 0) { // parent xdg_surface is nullable
                    if (surfaceByXdgId(conn, args[1].object)) |parent| {
                        surface.parent_id = surfaceIdOf(conn, parent);
                    }
                }
                if (conn.positioners.get(args[2].object)) |pos| {
                    surface.rules = pos;
                    const placed = self.placePopup(conn, surface.parent_id, &pos);
                    surface.x = placed.x;
                    surface.y = placed.y;
                    surface.popup_w = placed.w;
                    surface.popup_h = placed.h;
                }
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_popup") and std.mem.eql(u8, msg.name, "reposition")) {
            // v3: re-place an already-mapped popup from a fresh positioner
            // (GTK submenus/reactive menus). args = positioner, token.
            self.repositionPopup(conn_id, conn, header.object_id, args[0].object, args[1].uint);
        } else if (std.mem.eql(u8, iface.name, "wl_pointer") and std.mem.eql(u8, msg.name, "set_cursor")) {
            if (args[1].object != 0) {
                if (conn.surfaces.getPtr(args[1].object)) |surface| {
                    // GTK commits the cursor buffer BEFORE set_cursor — the
                    // canvas may already exist, so the embedder must be told.
                    // The role sticks even when the request is stale: the
                    // surface is the client's cursor image either way.
                    if (surface.role != .cursor) {
                        surface.role = .cursor;
                        self.notifySurface(conn_id, args[1].object, @intFromEnum(Role.cursor));
                    }
                }
            }
            self.setCursorSurface(conn_id, conn, args[0].uint, args[1].object, args[2].int, args[3].int);
        } else if (std.mem.eql(u8, iface.name, "wl_data_device_manager")) {
            if (std.mem.eql(u8, msg.name, "create_data_source")) {
                try conn.source_mimes.put(self.gpa, args[0].new_id, .empty);
            } else if (std.mem.eql(u8, msg.name, "get_data_device")) {
                const id = args[0].new_id;
                if (!conn.data_devices.add(id, entry.version)) return self.seatObjectIgnored(conn_id, "wl_data_device", id);
                // made while its client has keyboard focus: the selection now
                if (conn.keyboard_focus != 0) self.offerSelection(conn_id, conn, .{ .id = id, .version = entry.version });
            }
        } else if (std.mem.eql(u8, iface.name, "wl_data_source")) {
            if (std.mem.eql(u8, msg.name, "offer")) {
                if (conn.source_mimes.getPtr(header.object_id)) |list| try self.addSourceMime(conn_id, list, args[0].string);
            } else if (std.mem.eql(u8, msg.name, "set_actions")) {
                try conn.source_actions.put(self.gpa, header.object_id, args[0].uint);
            }
        } else if (std.mem.eql(u8, iface.name, "wl_data_device")) {
            if (std.mem.eql(u8, msg.name, "set_selection")) {
                // args: source (nullable: 0 = clear), serial
                if (self.maySetSelection(conn_id, conn, args[1].uint)) {
                    self.setSelection(conn_id, args[0].object);
                } else self.logf("c{d}: set_selection without keyboard focus (serial {d}) — ignored", .{ conn_id, args[1].uint });
            } else if (std.mem.eql(u8, msg.name, "start_drag")) {
                // args: source (nullable), origin, icon (nullable), serial —
                // a press of this client's, still held (like move/resize).
                // Not a touch point's: the dnd session follows the pointer
                // (touch-driven dnd is not done), so a touch serial is as
                // stale as any — even one between two held presses
                if (pressHeld(conn, args[3].uint) and touchBySerial(conn, args[3].uint) == null) {
                    self.startDrag(conn_id, conn, args[0].object, args[1].object, args[2].object);
                } else self.logf("c{d}: start_drag with serial {d} outside a held press — ignored", .{ conn_id, args[3].uint });
            }
        } else if (std.mem.eql(u8, iface.name, "wl_data_offer")) {
            // requests on drag offers (selection offers only ever get
            // receive, which the server intercepts and never forwards)
            if (std.mem.eql(u8, msg.name, "accept")) {
                self.dragAccept(conn_id, header.object_id, args[1].string);
            } else if (std.mem.eql(u8, msg.name, "set_actions")) {
                self.dragOfferActions(conn_id, header.object_id, args[0].uint, args[1].uint);
            } else if (std.mem.eql(u8, msg.name, "finish")) {
                self.dragFinish(conn_id, conn, header.object_id);
            }
        } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_device_manager_v1")) {
            // M13, mirror of wl_data_device_manager. destroy is a generic
            // destructor (removes the object); no dnd counterpart exists.
            if (std.mem.eql(u8, msg.name, "create_source")) {
                try conn.primary_source_mimes.put(self.gpa, args[0].new_id, .empty);
            } else if (std.mem.eql(u8, msg.name, "get_device")) {
                const id = args[0].new_id;
                if (!conn.primary_devices.add(id, entry.version)) return self.seatObjectIgnored(conn_id, "zwp_primary_selection_device_v1", id);
                if (conn.keyboard_focus != 0) self.offerPrimarySelection(conn_id, conn, id);
            }
        } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_source_v1")) {
            // only `offer` (no set_actions — primary selection has no dnd)
            if (std.mem.eql(u8, msg.name, "offer")) {
                if (conn.primary_source_mimes.getPtr(header.object_id)) |list| try self.addSourceMime(conn_id, list, args[0].string);
            }
        } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_device_v1")) {
            if (std.mem.eql(u8, msg.name, "set_selection")) {
                // args: source (nullable), serial — gated exactly like
                // wl_data_device.set_selection above
                if (self.maySetSelection(conn_id, conn, args[1].uint)) {
                    self.setPrimarySelection(conn_id, args[0].object);
                } else self.logf("c{d}: primary set_selection without keyboard focus (serial {d}) — ignored", .{ conn_id, args[1].uint });
            }
        }
        // zwp_primary_selection_offer_v1 requests never reach here: `receive`
        // is intercepted server-side (FDMSG pipe → onPipeReceive), and `destroy`
        // is handled by the generic destructor block below.
        else if (std.mem.eql(u8, iface.name, "zxdg_decoration_manager_v1") and std.mem.eql(u8, msg.name, "get_toplevel_decoration")) {
            if (surfaceByToplevelId(conn, args[1].object)) |surface| {
                // (the new object is already tracked: the error names it)
                if (surface.decoration_id != 0) {
                    return self.sendError(conn_id, args[0].new_id, decoration_err_already_constructed, "xdg_toplevel already has a decoration object");
                }
                // v1: not on a toplevel with a buffer attached or committed
                if (surface.on_output or (surface.pending_attach orelse 0) != 0) {
                    return self.sendError(conn_id, args[0].new_id, decoration_err_unconfigured_buffer, "xdg_toplevel has a buffer attached");
                }
                surface.decoration_id = args[0].new_id;
                surface.decoration_pref = 0;
                // configured toplevels learn the mode now; the others get it
                // with their first configure (configureIfNeeded)
                if (surface.configured) self.sendDecorationConfigure(conn_id, conn, surface);
            }
        } else if (std.mem.eql(u8, iface.name, "zxdg_toplevel_decoration_v1") and
            (std.mem.eql(u8, msg.name, "set_mode") or std.mem.eql(u8, msg.name, "unset_mode")))
        {
            // a preference: the mode is ours to pick (decorationMode), and
            // every request is answered with a configure once configured
            const pref: u32 = if (std.mem.eql(u8, msg.name, "set_mode")) args[0].uint else 0;
            if (pref != 0 and pref != decoration_mode_client_side and pref != decoration_mode_server_side) {
                return self.sendError(conn_id, header.object_id, decoration_err_invalid_mode, "invalid decoration mode");
            }
            if (surfaceByDecorationId(conn, header.object_id)) |surface| {
                surface.decoration_pref = pref;
                if (surface.configured) self.sendDecorationConfigure(conn_id, conn, surface);
            }
        } else if (std.mem.eql(u8, iface.name, "wp_cursor_shape_device_v1") and std.mem.eql(u8, msg.name, "set_shape")) {
            // get_pointer/get_tablet_tool_v2 need no handling: the device is
            // auto-tracked by trackNewIds, destroy is a generic destructor,
            // and we never advertise tablet-v2 so get_tablet_tool_v2 is dead.
            self.setCursorShape(conn_id, conn, header.object_id, args[0].uint, args[1].uint);
        } else if (std.mem.eql(u8, iface.name, "wp_viewporter") and std.mem.eql(u8, msg.name, "get_viewport")) {
            // args: new_id viewport, object surface. The viewport is
            // auto-tracked by trackNewIds; wire it to its surface here.
            self.getViewport(conn_id, conn, header.object_id, args[0].new_id, args[1].object);
        } else if (std.mem.eql(u8, iface.name, "wp_viewport")) {
            if (std.mem.eql(u8, msg.name, "set_source")) {
                self.viewportSetSource(conn_id, conn, header.object_id, args[0].fixed, args[1].fixed, args[2].fixed, args[3].fixed);
            } else if (std.mem.eql(u8, msg.name, "set_destination")) {
                self.viewportSetDestination(conn_id, conn, header.object_id, args[0].int, args[1].int);
            }
        } else if (std.mem.eql(u8, iface.name, "wp_fractional_scale_manager_v1") and std.mem.eql(u8, msg.name, "get_fractional_scale")) {
            self.getFractionalScale(conn_id, conn, header.object_id, args[0].new_id, args[1].object);
        } else if (std.mem.eql(u8, iface.name, "zwp_text_input_manager_v3") and std.mem.eql(u8, msg.name, "get_text_input")) {
            // one seat → one text input; the object is auto-tracked by
            // trackNewIds. If keyboard focus is already on a toplevel, the
            // enter must fire now (enter follows keyboard focus, spec).
            conn.text_input_id = args[0].new_id;
            conn.ti_enabled = false;
            conn.ti_pending_enable = false;
            conn.ti_cursor = .{};
            conn.ti_pending_cursor = .{};
            conn.ti_focus_surface = 0;
            if (conn.keyboard_focus != 0) self.textInputEnter(conn_id, conn, conn.keyboard_focus);
        } else if (std.mem.eql(u8, iface.name, "zwp_text_input_v3")) {
            if (std.mem.eql(u8, msg.name, "enable")) {
                // enable resets ALL double-buffered state (spec); it is applied
                // on the next commit
                conn.ti_pending_enable = true;
                conn.ti_pending_cursor = .{};
            } else if (std.mem.eql(u8, msg.name, "disable")) {
                conn.ti_pending_enable = false;
            } else if (std.mem.eql(u8, msg.name, "set_cursor_rectangle")) {
                conn.ti_pending_cursor = .{ .x = args[0].int, .y = args[1].int, .w = args[2].int, .h = args[3].int };
            } else if (std.mem.eql(u8, msg.name, "commit")) {
                // atomically latch pending → current and bump the done serial.
                // set_surrounding_text/_text_change_cause/_content_type are
                // decoded (opaque) but unused — we drive composition from the
                // browser, not from surrounding-text-aware input methods.
                conn.ti_serial +%= 1;
                conn.ti_enabled = conn.ti_pending_enable;
                conn.ti_cursor = conn.ti_pending_cursor;
                self.textInputNotify(conn_id, conn);
            }
            // set_surrounding_text / set_text_change_cause / set_content_type
            // fall through: decoded, no state we act on.
        } else if (std.mem.eql(u8, iface.name, "zwp_linux_dmabuf_v1")) {
            if (std.mem.eql(u8, msg.name, "create_params")) {
                try conn.dmabuf_params.put(self.gpa, args[0].new_id, .{});
            } else if (std.mem.eql(u8, msg.name, "get_default_feedback") or std.mem.eql(u8, msg.name, "get_surface_feedback")) {
                // one device, one tranche: a surface's feedback is the
                // default one, sent once (it never changes on this link)
                self.sendDmabufFeedback(conn_id, args[0].new_id);
            }
        } else if (std.mem.eql(u8, iface.name, "wland_external_buffer_manager_v1") and std.mem.eql(u8, msg.name, "create_buffer")) {
            // args: buffer, id_hi, id_lo, width, height, format, flags.
            // trackNewIds made the wl_buffer (client id, like create_immed);
            // the core tracks buffers only as objects: what it holds reaches
            // the embedder in the COMMIT (kind external), sizes through
            // noteBufferSize. An error is fatal, so the stray object never matters.
            stream.ExternalRef.checkArgs(args[3].int, args[4].int, args[5].uint, args[6].uint) catch |err| switch (err) {
                error.BadFormat => return self.sendError(conn_id, header.object_id, external_err_invalid_format, "format is not ARGB8888, XRGB8888, ABGR8888 or XBGR8888"),
                error.BadDimensions => return self.sendError(conn_id, header.object_id, external_err_invalid_dimensions, "width and height must be within 1..16384"),
                error.BadFlags => return self.sendError(conn_id, header.object_id, external_err_invalid_flags, "unknown flags"),
            };
        } else if (std.mem.eql(u8, iface.name, "zwp_linux_buffer_params_v1")) {
            // `add` arrives as FDMSG kind dmabuf: the relay kept the fd
            try self.dmabufParamsRequest(conn_id, conn, header.object_id, msg.name, args);
        } else if (std.mem.eql(u8, iface.name, "zwp_relative_pointer_manager_v1") and std.mem.eql(u8, msg.name, "get_relative_pointer")) {
            // one seat: every relative pointer shares its pointer focus
            if (!conn.relative_pointers.add(args[0].new_id, entry.version)) return self.seatObjectIgnored(conn_id, "zwp_relative_pointer_v1", args[0].new_id);
        } else if (std.mem.eql(u8, iface.name, "zwp_pointer_constraints_v1") and
            (std.mem.eql(u8, msg.name, "lock_pointer") or std.mem.eql(u8, msg.name, "confine_pointer")))
        {
            // args: new_id, surface, pointer, region (nullable), lifetime
            try self.createConstraint(conn_id, conn, header.object_id, args[0].new_id, args[1].object, args[3].object, args[4].uint, std.mem.eql(u8, msg.name, "lock_pointer"));
        } else if (std.mem.eql(u8, iface.name, "zwp_locked_pointer_v1") or std.mem.eql(u8, iface.name, "zwp_confined_pointer_v1")) {
            // double-buffered: latched by the surface's commit
            if (conn.constraints.getPtr(header.object_id)) |c| {
                if (std.mem.eql(u8, msg.name, "set_region")) {
                    c.region_pending = if (args[0].object == 0) null else conn.regions.get(args[0].object);
                    c.region_pending_set = true;
                } else if (std.mem.eql(u8, msg.name, "set_cursor_position_hint")) {
                    c.hint_pending = .{ args[0].fixed, args[1].fixed };
                }
            }
        } else if (std.mem.eql(u8, iface.name, "wp_presentation") and std.mem.eql(u8, msg.name, "feedback")) {
            // args: surface, new_id. Pending until the surface's next
            // commit (Feedback); a surface that is already gone shows nothing.
            const fb: Feedback = .{ .surface = args[0].object, .id = args[1].new_id };
            if (conn.surfaces.contains(fb.surface)) {
                try conn.feedbacks.append(self.gpa, fb);
            } else {
                self.endFeedback(conn_id, conn, fb.id);
            }
        } else if (std.mem.eql(u8, iface.name, "wl_surface")) {
            if (std.mem.eql(u8, msg.name, "frame")) {
                // pending until this surface commits (see tick). Over WS the
                // relay intercepts the request and it never gets here.
                try conn.frame_callbacks.append(self.gpa, .{ .surface = header.object_id, .id = args[0].new_id });
            } else if (std.mem.eql(u8, msg.name, "attach")) {
                // only whether a buffer is attached matters here (pixels are
                // the relay's and the embedder's): it decides enter/leave.
                // x,y is the pre-v5 buffer offset (v5+ sends 0,0 and uses
                // wl_surface.offset, which a 0,0 attach must not undo).
                if (conn.surfaces.getPtr(header.object_id)) |surface| {
                    surface.pending_attach = args[0].object;
                    if (args[1].int != 0 or args[2].int != 0) surface.offset_pending = .{ args[1].int, args[2].int };
                }
            } else if (std.mem.eql(u8, msg.name, "commit")) {
                // latch double-buffered state: frame callbacks and
                // presentation feedback, then viewport crop+scale (spec)
                latchFrameCallbacks(conn, header.object_id);
                if (conn.feedbacks.items.len > 0) self.latchFeedbacks(conn_id, conn, header.object_id);
                self.applyViewport(conn_id, conn, header.object_id);
                if (conn.surfaces.getPtr(header.object_id)) |surface| {
                    // xdg-decoration v1: no buffer before the first
                    // decoration configure
                    if (surface.decoration_id != 0 and !surface.configured and (surface.pending_attach orelse 0) != 0) {
                        return self.sendError(conn_id, surface.decoration_id, decoration_err_unconfigured_buffer, "buffer attached before the first decoration configure");
                    }
                }
                self.configureIfNeeded(conn_id, conn, header.object_id);
                if (conn.surfaces.getPtr(header.object_id)) |surface| {
                    // its decoration object went: client-side from here
                    if (surface.decorated and surface.decoration_id == 0) self.setDecorated(conn_id, header.object_id, surface, false);
                    if (surface.geom_pending) |geom| {
                        // popups are placed from it (surfaceAbs)
                        if (!surface.geom_set or !std.mem.eql(i32, &surface.geom, &geom)) self.positions_dirty = true;
                        surface.geom = geom;
                        surface.geom_set = true;
                        surface.geom_pending = null;
                    }
                    if (surface.min_pending != null or surface.max_pending != null) {
                        self.latchSizeLimits(conn_id, header.object_id, surface);
                    }
                    // its subsurfaces' z-order (place_above / place_below)
                    if (surface.stack_pending) {
                        surface.stack_pending = false;
                        latchStack(conn, header.object_id);
                        self.restacked(conn);
                    }
                    if (surface.input_pending_set) {
                        surface.input_pending_set = false;
                        const changed = !Region.eql(surface.input, surface.input_pending);
                        surface.input = surface.input_pending;
                        if (changed) {
                            if (self.input_region_fn) |f| f(self.ctx, conn_id, header.object_id, if (surface.input) |*r| r else null);
                        }
                    }
                    if (surface.size_acked) {
                        surface.size_acked = false;
                        surface.size_serial = null;
                    }
                    if (surface.ack_pending) |cfg| {
                        surface.ack_pending = null;
                        surface.acked = cfg;
                        if (self.acked_fn) |f| f(self.ctx, conn_id, header.object_id, cfg.serial, cfg.w, cfg.h);
                    }
                    const had_content = surface.on_output;
                    if (surface.pending_attach) |buffer_id| {
                        surface.pending_attach = null;
                        self.setOnOutput(conn_id, conn, header.object_id, surface, buffer_id != 0);
                    }
                    if (had_content and !surface.on_output) self.unmapped(conn_id, surface, header.object_id);
                    var hotspot_moved = false;
                    if (surface.offset_pending) |o| {
                        surface.offset_pending = null;
                        surface.offset_x = o[0];
                        surface.offset_y = o[1];
                        // the pointer surface's hotspot moves against the
                        // offset (wl_pointer.set_cursor), applied at commit
                        if (header.object_id == conn.cursor_surface) {
                            conn.cursor_hx -%= o[0];
                            conn.cursor_hy -%= o[1];
                            hotspot_moved = true;
                        }
                    }
                    if (header.object_id == conn.cursor_surface and (hotspot_moved or had_content != surface.on_output)) {
                        self.emitCursorSurface(conn_id, conn);
                    }
                }
                // pointer constraints: their regions latch, and the input
                // region may have changed under them
                if (conn.constraints.count() > 0) self.commitConstraints(conn_id, conn, header.object_id);
            } else if (std.mem.eql(u8, msg.name, "set_input_region")) {
                // pending until commit; a copy of the region as it is now
                // (the client may change or destroy it right after)
                if (conn.surfaces.getPtr(header.object_id)) |surface| {
                    const region_id = args[0].object;
                    if (region_id == 0) {
                        surface.input_pending = null;
                        surface.input_pending_set = true;
                    } else if (conn.regions.get(region_id)) |region| {
                        surface.input_pending = region;
                        surface.input_pending_set = true;
                    }
                }
            } else if (std.mem.eql(u8, msg.name, "set_buffer_scale")) {
                if (conn.surfaces.getPtr(header.object_id)) |surface| {
                    surface.buffer_scale = @max(1, args[0].int);
                }
            } else if (std.mem.eql(u8, msg.name, "offset")) {
                // wl_compositor v5: the surface-local buffer offset, the
                // replacement for wl_surface.attach's x/y; pending until
                // commit like attach's. Only a cursor surface's hotspot uses
                // it (canvases are placed by role / subsurface position).
                if (conn.surfaces.getPtr(header.object_id)) |surface| {
                    surface.offset_pending = .{ args[0].int, args[1].int };
                }
            }
        }
        if (msg.destructor) {
            if (std.mem.eql(u8, iface.name, "wl_surface")) {
                _ = conn.surfaces.remove(header.object_id);
                self.dropToplevelStrings(conn, header.object_id);
                self.restacked(conn); // it, or its children, may have been placed
                // its touch points and its subsurfaces' (still chained to
                // it here) go silently, like focus below: no up for them
                dropTouchesOn(conn, header.object_id);
                // its subsurfaces are unmapped with it, their role objects
                // inert (the id may name another surface right after)
                var child_it = conn.surfaces.iterator();
                while (child_it.next()) |kv| {
                    const child = kv.value_ptr;
                    if (child.role != .subsurface or child.parent_id != header.object_id) continue;
                    child.role = .none;
                    child.sub_obj_id = 0;
                    child.parent_id = 0;
                    self.setOnOutput(conn_id, conn, kv.key_ptr.*, child, false);
                    self.notifySurface(conn_id, kv.key_ptr.*, @intFromEnum(Role.none));
                }
                self.dropFrameCallbacks(conn_id, conn, header.object_id);
                self.dropFeedbacks(conn_id, conn, header.object_id);
                // focus dies with the surface, SILENTLY — a later enter/leave
                // referencing the destroyed id is a client-killing protocol
                // error (wl-copy's hidden-surface trick trips this)
                if (conn.keyboard_focus == header.object_id) conn.keyboard_focus = 0;
                if (conn.pointer_focus == header.object_id) conn.pointer_focus = 0;
                // its pointer constraints end (an active one says so) and
                // are defunct: the objects live on, inert
                var cit = conn.constraints.iterator();
                while (cit.next()) |kv| {
                    const c = kv.value_ptr;
                    if (c.surface != header.object_id or c.state == .defunct) continue;
                    if (c.state == .active) self.sendDeactivated(conn_id, kv.key_ptr.*, c);
                    c.state = .defunct;
                }
                self.syncLockDesire(conn_id, conn);
                // text-input focus dies with its surface just as silently — a
                // leave referencing the destroyed id would kill the client
                if (conn.ti_focus_surface == header.object_id) {
                    conn.ti_focus_surface = 0;
                    conn.ti_enabled = false;
                    conn.ti_pending_enable = false;
                    self.textInputNotify(conn_id, conn);
                }
                // drag focus dies just as silently (enter references ids)
                if (self.drag) |*drag| {
                    if (conn_id == drag.focus_conn and header.object_id == drag.focus_surface) {
                        drag.clearFocus();
                        if (drag.own) self.settleOwnDrag();
                    }
                    if (conn_id == drag.source_conn and header.object_id == drag.icon_surface) {
                        drag.icon_surface = 0;
                    }
                    // last: cancels the drag and nulls self.drag
                    if (conn_id == drag.source_conn and header.object_id == drag.origin_surface) {
                        self.dragCancel();
                    }
                }
                self.notifySurface(conn_id, header.object_id, surface_destroyed_code);
                // the pointer image dies with its surface: hidden, as when
                // the client sets a NULL cursor (until it sets another)
                // (the id may be reused for another surface right after)
                if (conn.cursor_surface == header.object_id) {
                    conn.cursor_surface = 0;
                    self.emitCursorSurface(conn_id, conn);
                }
            } else if (std.mem.eql(u8, iface.name, "wl_region")) {
                _ = conn.regions.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "xdg_popup") or std.mem.eql(u8, iface.name, "xdg_toplevel")) {
                // role object destroyed but the wl_surface may live on (GTK
                // reuses popover surfaces) — unmap: role back to none
                var it = conn.surfaces.iterator();
                while (it.next()) |kv| {
                    const surface = kv.value_ptr;
                    const match = (surface.role == .popup and surface.popup_id == header.object_id) or
                        (surface.role == .toplevel and surface.toplevel_id == header.object_id);
                    if (match) {
                        self.positions_dirty = true;
                        dropTouchesOn(conn, kv.key_ptr.*); // unmapped: silently, as unmapped() does
                        if (surface.role == .toplevel) {
                            self.dropToplevelStrings(conn, kv.key_ptr.*);
                            // its size hints are the xdg_toplevel's too
                            const had_limits = surface.min_w != 0 or surface.min_h != 0 or surface.max_w != 0 or surface.max_h != 0;
                            surface.min_w = 0;
                            surface.min_h = 0;
                            surface.max_w = 0;
                            surface.max_h = 0;
                            surface.min_pending = null;
                            surface.max_pending = null;
                            if (had_limits) {
                                if (self.size_limits_fn) |f| f(self.ctx, conn_id, kv.key_ptr.*, 0, 0, 0, 0);
                            }
                            // its decoration object must have gone first
                            if (surface.decoration_id != 0) {
                                self.sendError(conn_id, surface.decoration_id, decoration_err_orphaned, "xdg_toplevel destroyed before its decoration object");
                                surface.decoration_id = 0;
                                surface.decoration_pref = 0;
                            }
                            self.setDecorated(conn_id, kv.key_ptr.*, surface, false);
                        }
                        surface.role = .none;
                        surface.popup_id = 0;
                        surface.toplevel_id = 0;
                        surface.configured = false;
                        // window states are the xdg_toplevel's: a new one
                        // on this wl_surface starts floating and shown
                        surface.maximized = false;
                        surface.fullscreen = false;
                        surface.minimized = false;
                        surface.hidden = false;
                        surface.tiled = 0;
                        surface.win_pos = null;
                        surface.cfg_len = 0;
                        surface.ack_pending = null;
                        surface.acked = null;
                        surface.size_serial = null;
                        surface.size_acked = false;
                        // unmapped: its content is gone until the next
                        // attach + commit (xdg-shell), so it left the output
                        self.setOnOutput(conn_id, conn, kv.key_ptr.*, surface, false);
                        self.notifySurface(conn_id, kv.key_ptr.*, @intFromEnum(Role.none));
                        break;
                    }
                }
            } else if (std.mem.eql(u8, iface.name, "wl_subsurface")) {
                // the role object gone unmaps the surface at once
                // (wl_subsurface.destroy), while the wl_surface may live on:
                // Chromium's omnibox dropdown is a subsurface it keeps
                var it = conn.surfaces.iterator();
                while (it.next()) |kv| {
                    const surface = kv.value_ptr;
                    if (surface.role != .subsurface or surface.sub_obj_id != header.object_id) continue;
                    self.restacked(conn); // its siblings' ranks close up
                    surface.role = .none;
                    surface.sub_obj_id = 0;
                    surface.parent_id = 0;
                    dropTouchesOn(conn, kv.key_ptr.*); // (its own subsurfaces stop at it now)
                    self.setOnOutput(conn_id, conn, kv.key_ptr.*, surface, false);
                    self.notifySurface(conn_id, kv.key_ptr.*, @intFromEnum(Role.none));
                    break;
                }
            } else if (std.mem.eql(u8, iface.name, "xdg_surface")) {
                var it = conn.surfaces.valueIterator();
                while (it.next()) |surface| {
                    if (surface.xdg_surface_id == header.object_id) {
                        surface.xdg_surface_id = 0;
                        // window geometry is xdg_surface state (popups
                        // are placed from it)
                        if (surface.geom_set) self.positions_dirty = true;
                        surface.geom_set = false;
                        surface.geom_pending = null;
                        break;
                    }
                }
            } else if (std.mem.eql(u8, iface.name, "wl_data_source")) {
                if (conn.source_mimes.fetchRemove(header.object_id)) |kv| {
                    var list = kv.value;
                    self.freeMimes(&list);
                }
                _ = conn.source_actions.remove(header.object_id);
                self.orphanOffers(conn_id, header.object_id, false);
                if (self.selection) |sel| {
                    if (sel.conn == conn_id and sel.source == header.object_id) {
                        self.selection = null;
                        self.broadcastSelection();
                        self.notifySelection();
                    }
                }
                if (self.drag) |*drag| {
                    if (drag.source_conn == conn_id and drag.source_id == header.object_id) {
                        drag.source_id = 0; // no cancelled to a destroyed source
                        self.dragCancel();
                    }
                }
            } else if (std.mem.eql(u8, iface.name, "wl_data_offer")) {
                _ = conn.offers.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_source_v1")) {
                // mirror of wl_data_source destructor (no dnd/actions branch)
                if (conn.primary_source_mimes.fetchRemove(header.object_id)) |kv| {
                    var list = kv.value;
                    self.freeMimes(&list);
                }
                self.orphanOffers(conn_id, header.object_id, true);
                if (self.primary_selection) |sel| {
                    if (sel.conn == conn_id and sel.source == header.object_id) {
                        self.primary_selection = null;
                        self.broadcastPrimarySelection();
                    }
                }
            } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_offer_v1")) {
                _ = conn.primary_offers.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "wp_viewport")) {
                // destroying the viewport removes crop+scale from the surface
                // at the next commit (spec) — reset the pending state now
                if (conn.viewports.fetchRemove(header.object_id)) |kv| {
                    if (conn.surfaces.getPtr(kv.value)) |surface| {
                        surface.viewport_id = 0;
                        surface.vp_pending_src_set = false;
                        surface.vp_src_dirty = true;
                        surface.vp_pending_dst_set = false;
                        surface.vp_dst_dirty = true;
                    }
                }
            } else if (std.mem.eql(u8, iface.name, "wp_fractional_scale_v1")) {
                if (conn.frac_scales.fetchRemove(header.object_id)) |kv| {
                    if (conn.surfaces.getPtr(kv.value)) |surface| surface.fractional_id = 0;
                }
            } else if (std.mem.eql(u8, iface.name, "zwp_text_input_v3")) {
                // the client destroyed its text input — no leave to send (the
                // object is gone). Drop composition routing.
                if (conn.text_input_id == header.object_id) {
                    conn.text_input_id = 0;
                    conn.ti_focus_surface = 0;
                    conn.ti_enabled = false;
                    conn.ti_pending_enable = false;
                    self.textInputNotify(conn_id, conn);
                }
            } else if (std.mem.eql(u8, iface.name, "zxdg_toplevel_decoration_v1")) {
                // client-side again at the next commit (setDecorated there)
                if (surfaceByDecorationId(conn, header.object_id)) |surface| {
                    surface.decoration_id = 0;
                    surface.decoration_pref = 0;
                }
            } else if (std.mem.eql(u8, iface.name, "zwp_relative_pointer_v1")) {
                conn.relative_pointers.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "wl_pointer")) {
                // v3 release: the others keep the seat's events (and its
                // focus, serials and implicit grab, which are the conn's)
                conn.pointers.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "wl_keyboard")) {
                conn.keyboards.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "wl_touch")) {
                // the last one: its points have nobody left to end them for
                const was = conn.touches.len;
                conn.touches.remove(header.object_id);
                if (was > 0 and conn.touches.len == 0) {
                    conn.touch_n = 0;
                    conn.touch_unframed = false;
                    if (self.touch_bound_fn) |f| f(self.ctx, conn_id, false);
                }
            } else if (std.mem.eql(u8, iface.name, "wl_data_device")) {
                // v2 release; its offers live on (the client destroys them)
                conn.data_devices.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_device_v1")) {
                conn.primary_devices.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "zwp_locked_pointer_v1") or std.mem.eql(u8, iface.name, "zwp_confined_pointer_v1")) {
                // destroying it unlocks / unconfines (no event: it is gone);
                // a lock the embedder holds or asked for is let go
                _ = conn.constraints.remove(header.object_id);
                self.syncLockDesire(conn_id, conn);
            } else if (std.mem.eql(u8, iface.name, "zwp_linux_buffer_params_v1")) {
                _ = conn.dmabuf_params.remove(header.object_id);
            } else if (std.mem.eql(u8, iface.name, "wl_output")) {
                // v3 release: drop it from the live-mode broadcast set
                for (conn.output_ids.items, 0..) |oid, i| {
                    if (oid == header.object_id) {
                        _ = conn.output_ids.swapRemove(i);
                        break;
                    }
                }
            }
            conn.objects.remove(header.object_id);
            self.deleteId(conn_id, header.object_id);
        }
    }

    /// attach(NULL) + commit took a mapped surface's content away: the
    /// embedder hears role none (= unmapped; no commit event carries a
    /// NULL buffer) and learns the role again from the next commit with
    /// content. The role object lives on. A toplevel is back to where
    /// get_toplevel left it (xdg-shell): states gone, and its next commit
    /// starts with an initial configure. Pointer images and dnd icons have
    /// paths of their own.
    fn unmapped(self: *Compositor, conn_id: u32, surface: *Surface, surface_id: u32) void {
        switch (surface.role) {
            .toplevel => {
                surface.configured = false;
                surface.maximized = false;
                surface.fullscreen = false;
                surface.minimized = false;
                surface.size_serial = null;
                surface.size_acked = false;
            },
            .subsurface, .popup => {},
            else => return,
        }
        // off screen: its touch points (and its subsurfaces') end
        // silently, as for a destroyed surface
        if (self.conns.get(conn_id)) |conn| dropTouchesOn(conn, surface_id);
        self.notifySurface(conn_id, surface_id, @intFromEnum(Role.none));
    }

    fn notifySurface(self: *Compositor, conn_id: u32, surface_id: u32, value: u32) void {
        if (self.conns.get(conn_id)) |conn| {
            if (conn.surfaces.getPtr(surface_id)) |s| s.notified = if (value == surface_destroyed_code) 0 else value;
        }
        if (self.surface_fn) |surface_fn| surface_fn(self.ctx, conn_id, surface_id, value);
    }

    /// set_title's title or set_app_id's id kept for replaySurfaces (a
    /// failed copy just drops the old one: the replay then sends none).
    fn keepString(self: *Compositor, map: *std.AutoHashMapUnmanaged(u32, []u8), surface_id: u32, value: []const u8) void {
        if (map.fetchRemove(surface_id)) |kv| self.gpa.free(kv.value);
        const copy = self.gpa.dupe(u8, value) catch return;
        map.put(self.gpa, surface_id, copy) catch self.gpa.free(copy);
    }

    fn dropToplevelStrings(self: *Compositor, conn: *Conn, surface_id: u32) void {
        if (conn.titles.fetchRemove(surface_id)) |kv| self.gpa.free(kv.value);
        if (conn.app_ids.fetchRemove(surface_id)) |kv| self.gpa.free(kv.value);
    }

    /// wl_surface.commit with a set_min_size / set_max_size pending: the
    /// pair takes effect (min above max in a dimension where both are set
    /// is invalid_size, nothing applied) and the embedder hears of a change.
    fn latchSizeLimits(self: *Compositor, conn_id: u32, surface_id: u32, surface: *Surface) void {
        const min = surface.min_pending orelse [2]i32{ surface.min_w, surface.min_h };
        const max = surface.max_pending orelse [2]i32{ surface.max_w, surface.max_h };
        surface.min_pending = null;
        surface.max_pending = null;
        if (surface.role != .toplevel) return; // (its xdg_toplevel went: reset)
        for (0..2) |i| {
            if (min[i] > 0 and max[i] > 0 and min[i] > max[i]) {
                return self.sendError(conn_id, surface.toplevel_id, xdg_toplevel_err_invalid_size, "min size larger than max size");
            }
        }
        if (min[0] == surface.min_w and min[1] == surface.min_h and max[0] == surface.max_w and max[1] == surface.max_h) return;
        surface.min_w = min[0];
        surface.min_h = min[1];
        surface.max_w = max[0];
        surface.max_h = max[1];
        if (self.size_limits_fn) |f| f(self.ctx, conn_id, surface_id, min[0], min[1], max[0], max[1]);
    }

    /// Embedder: ask a toplevel to close (its close button, a taskbar's
    /// "close window"): xdg_toplevel.close, nothing else — the app decides
    /// (a dialog about unsaved work, or it destroys the window).
    pub fn closeToplevel(self: *Compositor, conn_id: u32, surface_id: u32) void {
        const t = self.toplevelSurface(conn_id, surface_id) orelse return;
        self.sendEvent(conn_id, t.surface.toplevel_id, "xdg_toplevel", "close", &.{});
    }

    fn surfaceByXdgId(conn: *Conn, xdg_id: u32) ?*Surface {
        var it = conn.surfaces.valueIterator();
        while (it.next()) |surface| {
            if (surface.xdg_surface_id == xdg_id) return surface;
        }
        return null;
    }

    fn surfaceByToplevelId(conn: *Conn, toplevel_id: u32) ?*Surface {
        var it = conn.surfaces.valueIterator();
        while (it.next()) |surface| {
            if (surface.toplevel_id == toplevel_id) return surface;
        }
        return null;
    }

    fn surfaceByPopupId(conn: *Conn, popup_id: u32) ?*Surface {
        var it = conn.surfaces.valueIterator();
        while (it.next()) |surface| {
            if (surface.role == .popup and surface.popup_id == popup_id) return surface;
        }
        return null;
    }

    fn surfaceByDecorationId(conn: *Conn, decoration_id: u32) ?*Surface {
        var it = conn.surfaces.valueIterator();
        while (it.next()) |surface| {
            if (surface.decoration_id == decoration_id) return surface;
        }
        return null;
    }

    fn surfaceBySubObjId(conn: *Conn, sub_obj_id: u32) ?*Surface {
        var it = conn.surfaces.valueIterator();
        while (it.next()) |surface| {
            if (surface.role == .subsurface and surface.sub_obj_id == sub_obj_id) return surface;
        }
        return null;
    }

    /// wl_subsurface.place_above / place_below: the surface of role object
    /// `sub_obj_id` goes just above / below `ref_id` — its parent or a
    /// sibling, else bad_surface (itself included) — in the parent's
    /// PENDING stack; the parent's next commit latches it (latchStack). Keys
    /// on the side it lands shift by one to make room, so the parent stays 0.
    fn placeSubsurface(self: *Compositor, conn_id: u32, conn: *Conn, sub_obj_id: u32, ref_id: u32, above: bool) void {
        var self_id: u32 = 0;
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.role == .subsurface and kv.value_ptr.sub_obj_id == sub_obj_id) self_id = kv.key_ptr.*;
        }
        if (self_id == 0) return; // inert: its parent went (the surface is unmapped)
        const parent_id = conn.surfaces.get(self_id).?.parent_id;
        // the reference's key: the parent is 0
        const k: i64 = blk: {
            if (ref_id == parent_id) break :blk 0;
            if (ref_id != self_id) {
                if (conn.surfaces.get(ref_id)) |sib| {
                    if (sib.role == .subsurface and sib.parent_id == parent_id) break :blk sib.z_pending;
                }
            }
            return self.sendError(conn_id, sub_obj_id, subsurface_err_bad_surface, "wl_surface is not a sibling or the parent");
        };
        // where it goes (`at`), and which siblings move a step away from
        // the parent to make room: above k ≥ 0 → k+1, the ones above k up;
        // above k < 0 → k, k and the ones below it down; below mirrors it
        const at: i64, const lo: i64, const hi: i64, const step: i64 = if (above)
            (if (k >= 0) .{ k + 1, k + 1, std.math.maxInt(i64), 1 } else .{ k, std.math.minInt(i64), k, -1 })
        else
            (if (k <= 0) .{ k - 1, std.math.minInt(i64), k - 1, -1 } else .{ k, k, std.math.maxInt(i64), 1 });
        it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            const sib = kv.value_ptr;
            if (kv.key_ptr.* == self_id or sib.role != .subsurface or sib.parent_id != parent_id) continue;
            if (sib.z_pending >= lo and sib.z_pending <= hi) sib.z_pending += step;
        }
        conn.surfaces.getPtr(self_id).?.z_pending = at;
        if (conn.surfaces.getPtr(parent_id)) |parent| parent.stack_pending = true;
    }

    /// The parent's commit: its subsurfaces' pending z-order becomes theirs.
    fn latchStack(conn: *Conn, parent_id: u32) void {
        var it = conn.surfaces.valueIterator();
        while (it.next()) |sib| {
            if (sib.role == .subsurface and sib.parent_id == parent_id) sib.z = sib.z_pending;
        }
    }

    fn surfaceIdOf(conn: *Conn, target: *Surface) u32 {
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr == target) return kv.key_ptr.*;
        }
        return 0;
    }

    /// The surface `surface_id` hangs from: a subsurface's parent, a popup's
    /// parent xdg surface; 0 for anything else, or not known.
    pub fn surfaceParent(self: *Compositor, conn_id: u32, surface_id: u32) u32 {
        const conn = self.conns.get(conn_id) orelse return 0;
        const surface = conn.surfaces.get(surface_id) orelse return 0;
        return surface.parent_id;
    }

    /// A subsurface's place in its parent's current stack (wl_subsurface
    /// z-order) as a rank: 1, 2, … above the parent counting up from it,
    /// −1, −2, … below it counting down; 0 for anything not a subsurface.
    /// Dense, so it changes only when the order does. Cached per surface
    /// (`z_rank`), recomputed for the whole conn after a restack — the
    /// embedder reads every placed surface's after each change.
    pub fn surfaceZ(self: *Compositor, conn_id: u32, surface_id: u32) i32 {
        const conn = self.conns.get(conn_id) orelse return 0;
        const surface = conn.surfaces.getPtr(surface_id) orelse return 0;
        if (surface.role != .subsurface or surface.parent_id == 0) return 0;
        if (conn.ranks_dirty) self.rerank(conn) catch return scanZ(conn, surface_id, surface.*);
        return surface.z_rank;
    }

    /// surfaceZ the slow way, one sibling scan (rerank out of memory).
    fn scanZ(conn: *Conn, surface_id: u32, surface: Surface) i32 {
        // siblings between it and the parent (keys are distinct; the id
        // breaks a tie all the same)
        var n: i32 = 1;
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            const sib = kv.value_ptr;
            const id = kv.key_ptr.*;
            if (id == surface_id or sib.role != .subsurface or sib.parent_id != surface.parent_id) continue;
            const nearer = if (surface.z > 0)
                sib.z > 0 and (sib.z < surface.z or (sib.z == surface.z and id < surface_id))
            else
                sib.z < 0 and (sib.z > surface.z or (sib.z == surface.z and id > surface_id));
            if (nearer) n += 1;
        }
        return if (surface.z > 0) n else -n;
    }

    /// A subsurface's stack, parent or role changed (or one came or went):
    /// the conn's cached ranks are stale, and placed surfaces may have moved.
    fn restacked(self: *Compositor, conn: *Conn) void {
        conn.ranks_dirty = true;
        self.positions_dirty = true;
    }

    /// Every subsurface's `z_rank` from the current keys, in one sort: per
    /// parent, the ones above it counting up from it, the ones below it
    /// counting down (scanZ's order, ties by id the same way).
    fn rerank(self: *Compositor, conn: *Conn) !void {
        const Entry = struct { parent: u32, z: i64, id: u32, s: *Surface };
        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(self.gpa);
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            const s = kv.value_ptr;
            if (s.role != .subsurface or s.parent_id == 0) continue;
            try list.append(self.gpa, .{ .parent = s.parent_id, .z = s.z, .id = kv.key_ptr.*, .s = s });
        }
        std.mem.sort(Entry, list.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                if (a.parent != b.parent) return a.parent < b.parent;
                const a_up = a.z > 0;
                if (a_up != (b.z > 0)) return !a_up; // the ones below first
                // nearest the parent first
                if (a_up) return a.z < b.z or (a.z == b.z and a.id < b.id);
                return a.z > b.z or (a.z == b.z and a.id > b.id);
            }
        }.lessThan);
        var n: i32 = 0;
        for (list.items, 0..) |e, i| {
            const up = e.z > 0;
            if (i == 0 or e.parent != list.items[i - 1].parent or up != (list.items[i - 1].z > 0)) n = 0;
            n += 1;
            e.s.z_rank = if (up) n else -n;
        }
        conn.ranks_dirty = false;
    }

    /// Whether positions_dirty was raised since the last call; clears it.
    pub fn takePositionsDirty(self: *Compositor) bool {
        defer self.positions_dirty = false;
        return self.positions_dirty;
    }

    /// Walk parents to the root (toplevel) surface id.
    pub fn surfaceRoot(self: *Compositor, conn_id: u32, surface_id: u32) u32 {
        const conn = self.conns.get(conn_id) orelse return surface_id;
        var id = surface_id;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            const surface = conn.surfaces.get(id) orelse return id;
            if (surface.parent_id == 0) return id;
            id = surface.parent_id;
        }
        return id;
    }

    /// Offset of a surface's origin from its root toplevel's origin (sums
    /// the parent chain), logical px. A popup's x/y is its configured
    /// position, which xdg-shell counts from the parent's window geometry
    /// to the popup's own: its origin is that plus the parent's geometry
    /// offset minus its own (`popupGeomOffset`) — GTK3/4 CSD windows and
    /// menus both hang shadows outside their geometry.
    pub fn surfaceAbs(self: *Compositor, conn_id: u32, surface_id: u32) struct { x: i32, y: i32 } {
        const conn = self.conns.get(conn_id) orelse return .{ .x = 0, .y = 0 };
        var x: i32 = 0;
        var y: i32 = 0;
        var id = surface_id;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            const surface = conn.surfaces.get(id) orelse break;
            // every term is a client's i32 (positions, window geometry):
            // saturate, never overflow
            x +|= surface.x;
            y +|= surface.y;
            if (surface.parent_id == 0) break;
            if (surface.role == .popup) {
                const own = popupGeomOffset(surface);
                const parent = if (conn.surfaces.get(surface.parent_id)) |p| popupGeomOffset(p) else [2]i32{ 0, 0 };
                x +|= parent[0] -| own[0];
                y +|= parent[1] -| own[1];
            }
            id = surface.parent_id;
        }
        return .{ .x = x, .y = y };
    }

    /// Where an xdg surface's window geometry starts, for popup placement:
    /// what set_window_geometry named, else the surface origin. The default
    /// geometry (the bounds with subsurfaces, `windowGeometry`) is left out
    /// on purpose: xwayland-satellite sets none, hangs its titlebar above
    /// the surface as a subsurface and places menus from the X window's
    /// origin, i.e. the surface's (plan.md, the satellite entry).
    fn popupGeomOffset(surface: Surface) [2]i32 {
        return if (surface.geom_set) .{ surface.geom[0], surface.geom[1] } else .{ 0, 0 };
    }

    const state_maximized: u32 = 1;
    const state_fullscreen: u32 = 2;
    const state_activated: u32 = 4;
    // xdg_toplevel.state.tiled_* (since xdg_wm_base v2): the embedder
    // snapped the window against these edges (setTiled)
    const state_tiled_left: u32 = 5;
    const state_tiled_right: u32 = 6;
    const state_tiled_top: u32 = 7;
    const state_tiled_bottom: u32 = 8;
    // xdg_toplevel.state.suspended (since xdg_wm_base v6) — set while the
    // browser tab is hidden or the window is minimized, so apps can stop
    // rendering
    const state_suspended: u32 = 9;
    // xdg_wm_base.wm_capabilities we honour (no window_menu: the wm has no
    // menu to show)
    const wm_cap_maximize: u32 = 2;
    const wm_cap_fullscreen: u32 = 3;
    const wm_cap_minimize: u32 = 4;
    const wm_capabilities = [_]u32{ wm_cap_maximize, wm_cap_fullscreen, wm_cap_minimize };

    fn sendToplevelConfigure(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface, w: i32, h: i32, states: []const u32) void {
        if (surface.toplevel_id == 0 or surface.xdg_surface_id == 0) return;
        var state_bytes: [32]u8 = undefined;
        var bits: u32 = 0;
        for (states, 0..) |s, i| {
            std.mem.writeInt(u32, state_bytes[i * 4 ..][0..4], s, .little);
            bits |= switch (s) {
                state_maximized => configure_maximized,
                state_fullscreen => configure_fullscreen,
                state_activated => configure_activated,
                state_suspended => configure_suspended,
                state_tiled_top => @as(u32, edge_top) << configure_tiled_shift,
                state_tiled_bottom => @as(u32, edge_bottom) << configure_tiled_shift,
                state_tiled_left => @as(u32, edge_left) << configure_tiled_shift,
                state_tiled_right => @as(u32, edge_right) << configure_tiled_shift,
                else => 0,
            };
        }
        self.sendEvent(conn_id, surface.toplevel_id, "xdg_toplevel", "configure", &.{
            .{ .int = w }, .{ .int = h }, .{ .array = state_bytes[0 .. states.len * 4] },
        });
        const serial = nextSerial(conn);
        self.sendEvent(conn_id, surface.xdg_surface_id, "xdg_surface", "configure", &.{
            .{ .uint = serial },
        });
        if (w > 0 and h > 0 and !surface.maximized and !surface.fullscreen) {
            surface.size_serial = serial;
            surface.size_acked = false;
        }
        const cfg: Configure = .{ .serial = serial, .w = w, .h = h, .states = bits };
        surface.cfgs[surface.cfg_head] = cfg;
        surface.cfg_head = (surface.cfg_head + 1) % cfg_ring;
        surface.cfg_len = @min(surface.cfg_len + 1, cfg_ring);
        if (self.configure_fn) |f| f(self.ctx, conn_id, surfaceIdOf(conn, surface), cfg, self.cause);
    }

    /// The configure `serial` names among the toplevel's recent ones.
    fn configureOf(surface: *const Surface, serial: u32) ?Configure {
        for (0..surface.cfg_len) |i| {
            const c = surface.cfgs[(surface.cfg_head + cfg_ring - 1 - i) % cfg_ring];
            if (c.serial == serial) return c;
        }
        return null;
    }

    /// The states every configure of this toplevel carries now: maximized,
    /// fullscreen; activated while it holds the keyboard (Chromium takes
    /// "is this window active" from it, not from wl_keyboard); the tiled
    /// edges the embedder set (v2); suspended (v6) while the tab is hidden
    /// or the window minimized or hidden.
    fn toplevelStates(self: *Compositor, conn: *Conn, surface: *Surface, states: *[8]u32) []const u32 {
        var n: usize = 0;
        if (surface.maximized) {
            states[n] = state_maximized;
            n += 1;
        }
        if (surface.fullscreen) {
            states[n] = state_fullscreen;
            n += 1;
        }
        if (conn.keyboard_focus != 0 and conn.keyboard_focus == surfaceIdOf(conn, surface)) {
            states[n] = state_activated;
            n += 1;
        }
        if (surface.tiled != 0 and objVersion(conn, surface.toplevel_id) >= 2) {
            const edges = [_][2]u32{
                .{ edge_left, state_tiled_left },  .{ edge_right, state_tiled_right },
                .{ edge_top, state_tiled_top },    .{ edge_bottom, state_tiled_bottom },
            };
            for (edges) |e| {
                if (surface.tiled & e[0] == 0) continue;
                states[n] = e[1];
                n += 1;
            }
        }
        if ((self.suspended or surface.minimized or surface.hidden) and objVersion(conn, surface.toplevel_id) >= 6) {
            states[n] = state_suspended;
            n += 1;
        }
        return states[0..n];
    }

    /// Keyboard focus came or went: the toplevel's `activated` state follows
    /// it, in a configure that repeats its size.
    fn sendActivation(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        if (surface.role != .toplevel or !surface.configured or surface.toplevel_id == 0) return;
        self.refreshFloatingSize(conn_id, conn, surface);
        self.sendCurrentConfigure(conn_id, conn, surface);
    }

    /// The decoration mode a toplevel is configured with: server_side when
    /// the embedder draws frames and the toplevel holds a decoration object
    /// that didn't ask for client_side; client_side otherwise.
    fn decorationMode(self: *const Compositor, surface: *const Surface) u32 {
        if (!self.decorations_server or surface.decoration_id == 0) return decoration_mode_client_side;
        return if (surface.decoration_pref == decoration_mode_client_side) decoration_mode_client_side else decoration_mode_server_side;
    }

    /// The work area a toplevel's configure_bounds and maximized size name:
    /// the embedder's (setBounds; the decorated one for a decorated
    /// toplevel), else the desktop's size.
    fn boundsOf(self: *const Compositor, decorated: bool) [2]i32 {
        return self.workArea(self.bounds, self.deco_bounds, decorated);
    }

    fn workArea(self: *const Compositor, b: [2]i32, d: [2]i32, decorated: bool) [2]i32 {
        if (decorated and d[0] > 0) return d;
        if (b[0] > 0) return b;
        return .{ self.desk_w, self.desk_h };
    }

    fn sendBounds(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface) void {
        if (objVersion(conn, surface.toplevel_id) < 4) return;
        const b = self.boundsOf(surface.decorated);
        self.sendEvent(conn_id, surface.toplevel_id, "xdg_toplevel", "configure_bounds", &.{
            .{ .int = b[0] }, .{ .int = b[1] },
        });
    }

    /// zxdg_toplevel_decoration_v1.configure with the mode decorationMode
    /// picks, and the embedder told when that changes `decorated`. The
    /// caller sends the xdg_surface.configure that carries it.
    fn sendDecorationMode(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface) void {
        const mode = self.decorationMode(surface);
        self.sendEvent(conn_id, surface.decoration_id, "zxdg_toplevel_decoration_v1", "configure", &.{
            .{ .uint = mode },
        });
        self.setDecorated(conn_id, surfaceIdOf(conn, surface), surface, mode == decoration_mode_server_side);
    }

    fn setDecorated(self: *Compositor, conn_id: u32, surface_id: u32, surface: *Surface, on: bool) void {
        if (surface.decorated == on) return;
        surface.decorated = on;
        if (self.decoration_fn) |f| f(self.ctx, conn_id, surface_id, on);
    }

    /// Answer a decoration-mode request (or a mode the embedder changed) on
    /// a configured toplevel: the decoration configure, the new
    /// configure_bounds when the mode changed them (v4), then a toplevel
    /// configure repeating its size and states and the xdg_surface
    /// configure — a cycle of its own. During the INITIAL configure the
    /// mode is emitted inline instead (configureIfNeeded) so it shares the
    /// toplevel's first cycle.
    fn sendDecorationConfigure(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface) void {
        if (surface.decoration_id == 0 or surface.xdg_surface_id == 0 or surface.toplevel_id == 0) return;
        const before = self.boundsOf(surface.decorated);
        self.sendDecorationMode(conn_id, conn, surface);
        if (!std.mem.eql(i32, &before, &self.boundsOf(surface.decorated))) self.sendBounds(conn_id, conn, surface);
        self.refreshFloatingSize(conn_id, conn, surface);
        self.sendCurrentConfigure(conn_id, conn, surface);
    }

    /// Embedder: whether it draws window frames (lib's `decorations`).
    /// Configured toplevels holding a decoration object whose mode this
    /// changes are answered again at once (sendDecorationConfigure); the
    /// others pick it up at their initial configure.
    pub fn setDecorations(self: *Compositor, server: bool) void {
        if (self.decorations_server == server) return;
        self.decorations_server = server;
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn = kv.value_ptr.*;
            var sit = conn.surfaces.valueIterator();
            while (sit.next()) |surface| {
                if (surface.role != .toplevel or !surface.configured or surface.decoration_id == 0) continue;
                if ((self.decorationMode(surface) == decoration_mode_server_side) == surface.decorated) continue;
                self.sendDecorationConfigure(kv.key_ptr.*, conn, surface);
            }
        }
    }

    /// Embedder: the work area for windows (configure_bounds, v4, and the
    /// size a maximized toplevel is configured to): w×h for client-side
    /// toplevels, dw×dh for decorated ones (its workspace less its frame;
    /// 0×0 = w×h). 0×0 = the desktop's size again. Configured toplevels
    /// whose area changed get the new bounds and a configure (the size
    /// repeated; a maximized one's is the new area).
    pub fn setBounds(self: *Compositor, w: i32, h: i32, dw: i32, dh: i32) void {
        const b: [2]i32 = if (w > 0 and h > 0) .{ w, h } else .{ 0, 0 };
        const d: [2]i32 = if (dw > 0 and dh > 0) .{ dw, dh } else .{ 0, 0 };
        if (std.mem.eql(i32, &b, &self.bounds) and std.mem.eql(i32, &d, &self.deco_bounds)) return;
        const old_b = self.bounds;
        const old_d = self.deco_bounds;
        self.bounds = b;
        self.deco_bounds = d;
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn_id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            var sit = conn.surfaces.valueIterator();
            while (sit.next()) |surface| {
                if (surface.role != .toplevel or !surface.configured or surface.toplevel_id == 0) continue;
                const before = self.workArea(old_b, old_d, surface.decorated);
                if (std.mem.eql(i32, &before, &self.boundsOf(surface.decorated))) continue;
                // (a pre-v4 floating toplevel has nothing to hear)
                if (objVersion(conn, surface.toplevel_id) < 4 and !surface.maximized) continue;
                self.sendBounds(conn_id, conn, surface);
                self.refreshFloatingSize(conn_id, conn, surface);
                self.sendCurrentConfigure(conn_id, conn, surface);
            }
        }
    }

    /// Embedder resize handle dragged: ask the toplevel to adopt w×h
    /// (clamped to its min/max hints). The app answers with a re-rendered
    /// buffer; canvases follow buffer dims, so no embedder-side sizing here.
    pub fn requestResize(self: *Compositor, conn_id: u32, surface_id: u32, w: i32, h: i32) void {
        const conn = self.conns.get(conn_id) orelse return;
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        if (surface.role != .toplevel) return;
        // a maximized or fullscreen toplevel is the desktop's size
        if (surface.maximized or surface.fullscreen) return;
        var cw = w;
        var ch = h;
        if (surface.min_w > 0) cw = @max(cw, surface.min_w);
        if (surface.min_h > 0) ch = @max(ch, surface.min_h);
        if (surface.max_w > 0) cw = @min(cw, surface.max_w);
        if (surface.max_h > 0) ch = @min(ch, surface.max_h);
        // the floating size from now on (the client is still at the old one)
        surface.last_w = cw;
        surface.last_h = ch;
        var states: [8]u32 = undefined;
        self.sendToplevelConfigure(conn_id, conn, surface, cw, ch, self.toplevelStates(conn, surface, &states));
    }

    /// Browser tab visibility changed (visibilitychange): (un)suspend every
    /// mapped v6 toplevel via a configure carrying the suspended state. Apps
    /// stop rendering while hidden (bandwidth win); <v6 clients are skipped
    /// (they don't understand the state).
    pub fn setSuspended(self: *Compositor, value: bool) void {
        if (self.suspended == value) return;
        self.suspended = value;
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn_id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            var sit = conn.surfaces.iterator();
            while (sit.next()) |skv| {
                const surface = skv.value_ptr;
                if (surface.role != .toplevel or !surface.configured or surface.toplevel_id == 0) continue;
                if (objVersion(conn, surface.toplevel_id) < 6) continue;
                // a minimized or hidden window is suspended either way
                if (surface.minimized or surface.hidden) continue;
                self.refreshFloatingSize(conn_id, conn, surface);
                self.sendCurrentConfigure(conn_id, conn, surface);
            }
        }
    }

    /// Re-send a toplevel's configure with its CURRENT size and states:
    /// maximized and/or fullscreen (the desktop's size), else floating (the
    /// last floating size, 0 = the client decides); activated while it holds
    /// the keyboard; suspended
    /// (v6) while the tab is hidden or the window minimized. It doesn't
    /// re-read the floating size: right after leaving fullscreen or
    /// maximized the window's box is still the big one (refreshFloatingSize
    /// is for callers that know it has been floating all along).
    fn sendCurrentConfigure(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface) void {
        // fullscreen: the desktop; maximized: the work area (setBounds)
        const area = if (surface.fullscreen) [2]i32{ self.desk_w, self.desk_h } else self.boundsOf(surface.decorated);
        const big = surface.maximized or surface.fullscreen;
        const w = if (big) area[0] else surface.last_w;
        const h = if (big) area[1] else surface.last_h;
        var states: [8]u32 = undefined;
        self.sendToplevelConfigure(conn_id, conn, surface, w, h, self.toplevelStates(conn, surface, &states));
    }

    /// A floating window's box is its floating size: read it again before
    /// a configure that repeats the size (last_w/h may be stale after a
    /// resize the client did itself).
    fn refreshFloatingSize(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface) void {
        // (not while a size we sent is still on its way: the geometry is
        // the old one — just unmaximized, or mid resize)
        if (!surface.maximized and !surface.fullscreen and surface.size_serial == null) self.rememberFloatingSize(conn_id, conn, surface);
    }

    /// set_maximized / unset_maximized, or the embedder's setMaximized.
    /// Always answered with a configure (the spec's "will still emit"),
    /// the state change told to the embedder. While fullscreen it only
    /// changes what unset_fullscreen returns to: the configure keeps the
    /// fullscreen size and states (with maximized among them). Before the
    /// initial commit only the flag is set: the initial configure carries
    /// it (configureIfNeeded) — a configure before it would also precede
    /// wm_capabilities.
    fn applyMaximized(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface, on: bool) void {
        if (surface.role != .toplevel) return;
        const changed = surface.maximized != on;
        // the floating size to come back to: the window's box now
        if (on) self.refreshFloatingSize(conn_id, conn, surface);
        surface.maximized = on;
        if (surface.configured) self.sendCurrentConfigure(conn_id, conn, surface);
        if (changed) self.notifyInteractive(conn_id, conn, surface, if (on) 2 else 3);
    }

    /// set_fullscreen / unset_fullscreen, or the embedder's setFullscreen:
    /// a configure of the desktop's size with the fullscreen state; unset
    /// goes back to what the window was — maximized if that is (still)
    /// set, else the floating size it had. Before the initial commit, the
    /// flag only (as applyMaximized).
    fn applyFullscreen(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface, on: bool) void {
        if (surface.role != .toplevel) return;
        const changed = surface.fullscreen != on;
        if (on) self.refreshFloatingSize(conn_id, conn, surface);
        surface.fullscreen = on;
        if (surface.configured) self.sendCurrentConfigure(conn_id, conn, surface);
        if (changed) self.notifyInteractive(conn_id, conn, surface, if (on) 6 else 7);
    }

    /// set_minimized, or the embedder's setMinimized: the window hides (the
    /// embedder is told) or comes back. Hiding takes the pointer and the
    /// keyboard from its surfaces (an active pointer constraint ends first:
    /// unlocked/unconfined before the leave), cancels the client's touch
    /// points when one is on it and dismisses its popups; a
    /// v6 client gets `suspended` until it is restored. Its frame callbacks
    /// wait meanwhile (tick) and its presentation feedback is discarded
    /// (surfaceShown). Only for toplevels past their initial configure.
    fn applyMinimized(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface, on: bool) void {
        if (surface.role != .toplevel or !surface.configured or surface.minimized == on) return;
        const id = surfaceIdOf(conn, surface);
        var told = false;
        if (on) {
            self.refreshFloatingSize(conn_id, conn, surface);
            surface.minimized = true;
            if (conn.pointer_focus != 0 and underMinimized(conn, conn.pointer_focus)) self.pointerLeave(conn_id);
            // a finger on it: the client's touch sequence ends (one cancel
            // ends every point of the client's, as wl_touch has it)
            if (touchesUnder(conn, underMinimized)) self.cancelTouches(conn_id, conn);
            // (the leave's configure, no longer activated, carries `suspended`)
            told = conn.keyboard_focus == id;
            if (conn.keyboard_focus == id) self.keyboardLeave(conn_id);
            var it = conn.surfaces.iterator();
            while (it.next()) |kv| {
                const s = kv.value_ptr;
                if (s.role == .popup and s.popup_id != 0 and underMinimized(conn, kv.key_ptr.*)) {
                    self.sendEvent(conn_id, s.popup_id, "xdg_popup", "popup_done", &.{});
                }
            }
        } else {
            surface.minimized = false;
        }
        // only `suspended` changes, which a pre-v6 client doesn't know
        if (!told and objVersion(conn, surface.toplevel_id) >= 6) self.sendCurrentConfigure(conn_id, conn, surface);
        self.notifyInteractive(conn_id, conn, surface, if (on) 8 else 9);
    }

    fn notifyInteractive(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface, kind: u32) void {
        if (self.interactive_fn) |f| f(self.ctx, conn_id, surfaceIdOf(conn, surface), kind, 0);
    }

    fn toplevelSurface(self: *Compositor, conn_id: u32, surface_id: u32) ?struct { conn: *Conn, surface: *Surface } {
        const conn = self.conns.get(conn_id) orelse return null;
        const surface = conn.surfaces.getPtr(surface_id) orelse return null;
        if (surface.role != .toplevel) return null;
        return .{ .conn = conn, .surface = surface };
    }

    /// Embedder: maximize or unmaximize a toplevel (its own UI, a key
    /// binding) — the same configure as the app's request would get.
    pub fn setMaximized(self: *Compositor, conn_id: u32, surface_id: u32, on: bool) void {
        const t = self.toplevelSurface(conn_id, surface_id) orelse return;
        self.applyMaximized(conn_id, t.conn, t.surface, on);
    }

    /// Embedder: put a toplevel in or out of fullscreen (the user's key
    /// binding, the browser leaving its own fullscreen).
    pub fn setFullscreen(self: *Compositor, conn_id: u32, surface_id: u32, on: bool) void {
        const t = self.toplevelSurface(conn_id, surface_id) orelse return;
        self.applyFullscreen(conn_id, t.conn, t.surface, on);
    }

    /// Embedder: minimize or restore a mapped toplevel (a taskbar). The
    /// only way back from an app's set_minimized.
    pub fn setMinimized(self: *Compositor, conn_id: u32, surface_id: u32, on: bool) void {
        const t = self.toplevelSurface(conn_id, surface_id) orelse return;
        self.applyMinimized(conn_id, t.conn, t.surface, on);
    }

    /// A new embedder takes over (a session viewer's init): what the last
    /// one set per window for its own window manager goes — hidden windows
    /// are shown (setVisible true), tiled ones untiled (setTiled 0), window
    /// positions unknown again (open popups stay where they are). The new
    /// one sets its own.
    pub fn resetEmbedderWindows(self: *Compositor) void {
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            var sit = kv.value_ptr.*.surfaces.iterator();
            while (sit.next()) |skv| {
                if (skv.value_ptr.role != .toplevel) continue;
                skv.value_ptr.win_pos = null;
                if (skv.value_ptr.hidden) self.setVisible(kv.key_ptr.*, skv.key_ptr.*, true);
                if (skv.value_ptr.tiled != 0) self.setTiled(kv.key_ptr.*, skv.key_ptr.*, 0, 0, 0);
            }
        }
    }

    /// Embedder: the window is snapped against these edges (1 top, 2
    /// bottom, 4 left, 8 right; 0 = floating again) — the tiled_* states
    /// (xdg_wm_base v2; an older client hears nothing of them), so the app
    /// drops its shadows and rounded corners there. Core state like
    /// maximized: in every configure from now on, until the embedder says
    /// otherwise; independent of maximized and fullscreen. The size is the
    /// embedder's: w×h > 0 sends it in the same configure (clamped to the
    /// app's hints, as requestResize does: one configure per snap), else
    /// the configure repeats the current size — and none goes out when the
    /// edges did not change. While maximized or fullscreen the size is
    /// theirs (w×h ignored). Before the initial commit only the edges are
    /// kept: the initial configure carries them.
    pub fn setTiled(self: *Compositor, conn_id: u32, surface_id: u32, edges: u32, w: i32, h: i32) void {
        const t = self.toplevelSurface(conn_id, surface_id) orelse return;
        const surface = t.surface;
        const e = edges & (edge_top | edge_bottom | edge_left | edge_right);
        const changed = surface.tiled != e;
        surface.tiled = e;
        if (!surface.configured) return;
        const big = surface.maximized or surface.fullscreen;
        if (w > 0 and h > 0 and !big) return self.requestResize(conn_id, surface_id, w, h);
        // (a pre-v2 client has no tiled state to hear of)
        if (!changed or objVersion(t.conn, surface.toplevel_id) < 2) return;
        self.refreshFloatingSize(conn_id, t.conn, surface);
        self.sendCurrentConfigure(conn_id, t.conn, surface);
    }

    /// Embedder: show or hide a toplevel's window for its own reasons
    /// (Surface.hidden). Hidden, it is rendered for like a minimized one —
    /// frame callbacks held (tick), feedback discarded (surfaceShown), a
    /// v6 client `suspended` — but nothing else changes: not `minimized`,
    /// not keyboard or pointer focus, not its popups; only a finger on it
    /// is cancelled (wl_touch.cancel, the client's points). Shown again, the held
    /// callbacks fire at the next tick. Only `suspended` reaches the app,
    /// in a configure repeating its size, and only when it changes (not
    /// while the window is minimized or the tab hidden). Before the
    /// initial commit the flag alone: the initial configure carries it.
    pub fn setVisible(self: *Compositor, conn_id: u32, surface_id: u32, visible: bool) void {
        const t = self.toplevelSurface(conn_id, surface_id) orelse return;
        const surface = t.surface;
        if (surface.hidden == !visible) return;
        surface.hidden = !visible;
        // a finger on a window the user can't see any more: the client's
        // touch sequence ends (the only input change hiding makes)
        if (!visible and touchesUnder(t.conn, underHidden)) self.cancelTouches(conn_id, t.conn);
        if (!surface.configured or surface.minimized or self.suspended) return;
        if (objVersion(t.conn, surface.toplevel_id) < 6) return;
        self.refreshFloatingSize(conn_id, t.conn, surface);
        self.sendCurrentConfigure(conn_id, t.conn, surface);
    }

    /// Embedder saw a presented buffer: keep the surface's logical size.
    /// Window geometry is built from these, and from it the floating size
    /// the unmaximize configure restores.
    pub fn noteBufferSize(self: *Compositor, conn_id: u32, surface_id: u32, buf_w: u32, buf_h: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        const view = self.surfaceViewSize(conn_id, surface_id);
        if (view.w > 0 and view.h > 0) {
            surface.log_w = view.w;
            surface.log_h = view.h;
        } else {
            // the embedder's u32 (a buffer's size, a client's claim at heart)
            const max: u32 = std.math.maxInt(i32);
            surface.log_w = @divTrunc(@as(i32, @intCast(@min(buf_w, max))), surface.buffer_scale);
            surface.log_h = @divTrunc(@as(i32, @intCast(@min(buf_h, max))), surface.buffer_scale);
        }
    }

    /// A floating toplevel's size is its window geometry's: kept in
    /// last_w/last_h when it stops floating (set_maximized) and whenever a
    /// configure repeats it.
    fn rememberFloatingSize(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface) void {
        const geom = self.windowGeometry(conn_id, surfaceIdOf(conn, surface));
        if (geom.w > 0 and geom.h > 0) {
            surface.last_w = geom.w;
            surface.last_h = geom.h;
        }
    }

    /// The surface at the top of `surface_id`'s chain of subsurface parents
    /// (itself when it is not a subsurface). Popups are not followed: a
    /// popup is a window of its own.
    fn subsurfaceRoot(conn: *Conn, surface_id: u32) u32 {
        var id = surface_id;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            const surface = conn.surfaces.get(id) orelse break;
            if (surface.role != .subsurface or surface.parent_id == 0) break;
            id = surface.parent_id;
        }
        return id;
    }

    /// Window geometry of an xdg surface (xdg_surface.set_window_geometry),
    /// in its wl_surface's local px: the box the window is placed, sized and
    /// maximized by — xdg_toplevel.configure sizes are this box's. Content
    /// outside it (shadows) hangs outside. Never set, it is the bounds of
    /// the surface and its subsurfaces with content, tracking every commit
    /// (xwayland-satellite sets none and hangs its titlebar above the
    /// surface as a subsurface at y = -25). A set geometry is used as given,
    /// not clamped to those bounds. All zero before anything was presented.
    pub fn windowGeometry(self: *Compositor, conn_id: u32, surface_id: u32) Rect {
        const conn = self.conns.get(conn_id) orelse return .{};
        const surface = conn.surfaces.get(surface_id) orelse return .{};
        if (surface.geom_set) return .{ .x = surface.geom[0], .y = surface.geom[1], .w = surface.geom[2], .h = surface.geom[3] };
        var x0: i32 = 0;
        var y0: i32 = 0;
        var x1: i32 = surface.log_w;
        var y1: i32 = surface.log_h;
        var any = surface.log_w > 0 and surface.log_h > 0;
        const base = self.surfaceAbs(conn_id, surface_id); // non-zero for a popup
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            const sub = kv.value_ptr;
            if (sub.role != .subsurface or sub.log_w <= 0 or sub.log_h <= 0) continue;
            if (subsurfaceRoot(conn, kv.key_ptr.*) != surface_id) continue;
            const abs = self.surfaceAbs(conn_id, kv.key_ptr.*); // sums the chain up to the root
            // client positions and geometry: saturate (as surfaceAbs does)
            const at = .{ .x = abs.x -| base.x, .y = abs.y -| base.y };
            if (!any) {
                x0 = at.x;
                y0 = at.y;
                x1 = at.x +| sub.log_w;
                y1 = at.y +| sub.log_h;
                any = true;
                continue;
            }
            x0 = @min(x0, at.x);
            y0 = @min(y0, at.y);
            x1 = @max(x1, at.x +| sub.log_w);
            y1 = @max(y1, at.y +| sub.log_h);
        }
        if (!any) return .{};
        return .{ .x = x0, .y = y0, .w = x1 -| x0, .h = y1 -| y0 };
    }

    /// xdg_popup.reposition (v3): recompute the popup's placement from a new
    /// positioner and emit the reposition sequence — repositioned(token) then
    /// xdg_popup.configure then xdg_surface.configure (spec order).
    fn repositionPopup(self: *Compositor, conn_id: u32, conn: *Conn, popup_id: u32, positioner_id: u32, token: u32) void {
        const surface = surfaceByPopupId(conn, popup_id) orelse return;
        const pos = conn.positioners.get(positioner_id) orelse return;
        surface.rules = pos;
        const placed = self.placePopup(conn, surface.parent_id, &pos);
        surface.x = placed.x;
        surface.y = placed.y;
        surface.popup_w = placed.w;
        surface.popup_h = placed.h;
        self.positions_dirty = true;
        self.sendEvent(conn_id, popup_id, "xdg_popup", "repositioned", &.{.{ .uint = token }});
        self.sendEvent(conn_id, popup_id, "xdg_popup", "configure", &.{
            .{ .int = surface.x },       .{ .int = surface.y },
            .{ .int = surface.popup_w }, .{ .int = surface.popup_h },
        });
        self.sendEvent(conn_id, surface.xdg_surface_id, "xdg_surface", "configure", &.{
            .{ .uint = nextSerial(conn) },
        });
    }

    /// Where a popup with these rules goes (its configure): from the
    /// parent's window geometry, constrained to the output when the
    /// window's position in it is known (popupParentAt), else exactly as
    /// the positioner says.
    fn placePopup(self: *Compositor, conn: *const Conn, parent_id: u32, pos: *const Positioner) Placed {
        const at = popupParentAt(conn, parent_id) orelse {
            const p = pos.place();
            return .{ .x = p.x, .y = p.y, .w = pos.w, .h = pos.h };
        };
        // the output in the parent's window-geometry space (saturating:
        // positions are the embedder's, geometry offsets the client's)
        return pos.placeWithin(.{ 0 -| at[0], 0 -| at[1], self.desk_w -| at[0], self.desk_h -| at[1] });
    }

    /// The output position of an xdg surface's window-geometry origin, as
    /// popups count from it: its toplevel's (setWindowPosition) plus each
    /// popup's x/y down the chain (a popup's x/y runs from its parent's
    /// geometry to its own). null while the toplevel's position is unknown
    /// or the chain has no toplevel (a parentless popup).
    fn popupParentAt(conn: *const Conn, surface_id: u32) ?[2]i32 {
        var x: i32 = 0;
        var y: i32 = 0;
        var id = surface_id;
        for (0..8) |_| {
            const s = conn.surfaces.getPtr(id) orelse return null;
            switch (s.role) {
                .toplevel => {
                    const w = s.win_pos orelse return null;
                    return .{ x +| w[0], y +| w[1] };
                },
                .popup => {
                    x +|= s.x;
                    y +|= s.y;
                    if (s.parent_id == 0) return null;
                    id = s.parent_id;
                },
                else => return null,
            }
        }
        return null;
    }

    /// Embedder: the toplevel's window-geometry origin is at (x, y) in the
    /// output, logical px — where its window manager put it, kept up to
    /// date as it moves. Popups opened from then on (and repositioned) are
    /// constrained to the output by their positioner's constraint
    /// adjustment; open ones stay where they are relative to the window
    /// (they move with it), except reactive ones (set_reactive), which are
    /// placed again. Unknown until set: no adjustment.
    pub fn setWindowPosition(self: *Compositor, conn_id: u32, surface_id: u32, x: i32, y: i32) void {
        const t = self.toplevelSurface(conn_id, surface_id) orelse return;
        if (t.surface.win_pos) |p| {
            if (p[0] == x and p[1] == y) return;
        }
        t.surface.win_pos = .{ x, y };
        self.replaceReactive(conn_id, t.conn, surface_id);
    }

    /// The reactive popups of `root_id`'s window placed again (the window
    /// moved, the output changed), parents before their children (a
    /// child counts from its parent's new place): those whose placement
    /// changed get xdg_popup.configure + xdg_surface.configure (no
    /// repositioned: that answers a reposition request), and the embedder
    /// reads positions again.
    fn replaceReactive(self: *Compositor, conn_id: u32, conn: *Conn, root_id: u32) void {
        for (1..9) |depth| {
            var it = conn.surfaces.iterator();
            while (it.next()) |kv| {
                const s = kv.value_ptr;
                if (s.role != .popup or s.popup_id == 0 or !s.rules.reactive) continue;
                if (popupDepth(conn, kv.key_ptr.*, root_id) != depth) continue;
                const p = self.placePopup(conn, s.parent_id, &s.rules);
                if (p.x == s.x and p.y == s.y and p.w == s.popup_w and p.h == s.popup_h) continue;
                s.x = p.x;
                s.y = p.y;
                s.popup_w = p.w;
                s.popup_h = p.h;
                self.positions_dirty = true;
                if (!s.configured) continue; // its initial configure carries it
                self.sendEvent(conn_id, s.popup_id, "xdg_popup", "configure", &.{
                    .{ .int = s.x }, .{ .int = s.y }, .{ .int = s.popup_w }, .{ .int = s.popup_h },
                });
                self.sendEvent(conn_id, s.xdg_surface_id, "xdg_surface", "configure", &.{.{ .uint = nextSerial(conn) }});
            }
        }
    }

    /// How many popups down from `root_id` a popup hangs (1: the
    /// toplevel's own), 0 when it is not in that window.
    fn popupDepth(conn: *const Conn, surface_id: u32, root_id: u32) usize {
        var id = surface_id;
        for (0..9) |n| {
            const s = conn.surfaces.getPtr(id) orelse return 0;
            if (id == root_id) return n;
            if (s.role != .popup or s.parent_id == 0) return 0;
            id = s.parent_id;
        }
        return 0;
    }

    /// Embedder saw an outside-click while this popup was up.
    pub fn popupDismiss(self: *Compositor, conn_id: u32, surface_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        const surface = conn.surfaces.get(surface_id) orelse return;
        if (surface.role != .popup or surface.popup_id == 0) return;
        self.sendEvent(conn_id, surface.popup_id, "xdg_popup", "popup_done", &.{});
    }

    /// xdg-shell handshake: first commit on an unconfigured toplevel/popup gets
    /// its role configure + xdg_surface.configure. Size 0×0 = client picks.
    fn configureIfNeeded(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        if (surface.configured or surface.xdg_surface_id == 0) return;
        if (surface.role == .toplevel and surface.toplevel_id != 0) {
            surface.configured = true;
            const tlv = objVersion(conn, surface.toplevel_id);
            // wm_capabilities + configure_bounds must precede the first
            // xdg_surface.configure (spec) — they ride this initial cycle.
            if (tlv >= 5) {
                // what we honour: maximize, fullscreen, minimize (no window menu)
                var caps: [wm_capabilities.len * 4]u8 = undefined;
                for (wm_capabilities, 0..) |cap, i| std.mem.writeInt(u32, caps[i * 4 ..][0..4], cap, .little);
                self.sendEvent(conn_id, surface.toplevel_id, "xdg_toplevel", "wm_capabilities", &.{.{ .array = &caps }});
            }
            // recommend the work area so apps don't open oversized (the
            // decorated one if the mode below is server_side)
            self.setDecorated(conn_id, surface_id, surface, self.decorationMode(surface) == decoration_mode_server_side);
            if (tlv >= 4) self.sendBounds(conn_id, conn, surface);
            // decoration mode next, so it rides the initial configure cycle
            // (sendToplevelConfigure carries the xdg_surface.configure)
            if (surface.decoration_id != 0) self.sendDecorationMode(conn_id, conn, surface);
            if (surface.maximized or surface.fullscreen) {
                // the app maximized / fullscreened itself before its first
                // commit: it maps that way
                self.sendCurrentConfigure(conn_id, conn, surface);
            } else {
                var states: [8]u32 = undefined;
                self.sendToplevelConfigure(conn_id, conn, surface, 0, 0, self.toplevelStates(conn, surface, &states));
            }
        } else if (surface.role == .popup and surface.popup_id != 0) {
            surface.configured = true;
            conn.serial += 1;
            self.sendEvent(conn_id, surface.popup_id, "xdg_popup", "configure", &.{
                .{ .int = surface.x },       .{ .int = surface.y },
                .{ .int = surface.popup_w }, .{ .int = surface.popup_h },
            });
            self.sendEvent(conn_id, surface.xdg_surface_id, "xdg_surface", "configure", &.{
                .{ .uint = conn.serial },
            });
        }
    }

    fn sendGlobals(self: *Compositor, conn_id: u32, registry_id: u32) void {
        for (globals) |g| self.sendGlobal(conn_id, registry_id, g);
        if (self.dmabuf != null) self.sendGlobal(conn_id, registry_id, dmabuf_global);
        if (self.externalOffered()) self.sendGlobal(conn_id, registry_id, external_global);
    }

    fn sendGlobal(self: *Compositor, conn_id: u32, registry_id: u32, g: Global) void {
        self.sendEvent(conn_id, registry_id, "wl_registry", "global", &.{
            .{ .uint = g.name },
            .{ .string = g.interface },
            .{ .uint = g.version },
        });
    }

    /// zwp_linux_dmabuf_feedback_v1, all of it at once: the format table (an
    /// fd: FDMSG kind memfd, the relay makes it from the table bytes), the
    /// main device, one tranche on that device holding every table entry,
    /// done. Mesa's EGL/Vulkan WSI open their render node from main_device.
    fn sendDmabufFeedback(self: *Compositor, conn_id: u32, feedback_id: u32) void {
        const d = self.dmabuf orelse return; // bind refused without it
        const fdmsg_fn = self.fdmsg_fn orelse {
            self.logf("no fdmsg transport; dmabuf feedback has no format table", .{});
            return;
        };
        var buf: [32]u8 = undefined;
        const msg = wire.encodeMessage(&buf, feedback_id, comptime protocol.find("zwp_linux_dmabuf_feedback_v1").?.eventIndex("format_table").?, &.{
            .fd, .{ .uint = @intCast(d.table.len) },
        });
        fdmsg_fn(self.ctx, conn_id, 2, msg, d.table); // kind 2 = memfd
        // dev_t and the u16 indices are host-endian arrays (little endian
        // on every target wland runs on)
        var dev: [8]u8 = undefined;
        std.mem.writeInt(u64, &dev, d.main_device, .little);
        var indices: [2 * 256]u8 = undefined;
        for (0..d.count()) |i| std.mem.writeInt(u16, indices[i * 2 ..][0..2], @intCast(i), .little);
        self.sendEvent(conn_id, feedback_id, "zwp_linux_dmabuf_feedback_v1", "main_device", &.{.{ .array = &dev }});
        self.sendEvent(conn_id, feedback_id, "zwp_linux_dmabuf_feedback_v1", "tranche_target_device", &.{.{ .array = &dev }});
        self.sendEvent(conn_id, feedback_id, "zwp_linux_dmabuf_feedback_v1", "tranche_flags", &.{.{ .uint = 0 }});
        self.sendEvent(conn_id, feedback_id, "zwp_linux_dmabuf_feedback_v1", "tranche_formats", &.{.{ .array = indices[0 .. d.count() * 2] }});
        self.sendEvent(conn_id, feedback_id, "zwp_linux_dmabuf_feedback_v1", "tranche_done", &.{});
        self.sendEvent(conn_id, feedback_id, "zwp_linux_dmabuf_feedback_v1", "done", &.{});
    }

    /// zwp_linux_buffer_params_v1 requests: plane bookkeeping and the
    /// protocol errors of add/create/create_immed. Whether the dmabuf can
    /// actually be read is the relay's business (an import it can't do
    /// leaves the buffer unshown, released like an unfit shm buffer).
    fn dmabufParamsRequest(self: *Compositor, conn_id: u32, conn: *Conn, params_id: u32, name: []const u8, args: []const wire.Value) !void {
        const p = conn.dmabuf_params.getPtr(params_id) orelse return;
        const is_add = std.mem.eql(u8, name, "add");
        const is_create = std.mem.eql(u8, name, "create");
        const is_immed = std.mem.eql(u8, name, "create_immed");
        if (!is_add and !is_create and !is_immed) return; // destroy: the destructor block
        if (p.used) return self.sendError(conn_id, params_id, dmabuf_err_already_used, "params already used");
        if (is_add) {
            // args: fd, plane_idx, offset, stride, modifier_hi, modifier_lo
            const idx = args[1].uint;
            if (idx >= dmabuf_max_planes) return self.sendError(conn_id, params_id, dmabuf_err_plane_idx, "plane index out of bounds");
            const bit = @as(u8, 1) << @intCast(idx);
            if (p.planes & bit != 0) return self.sendError(conn_id, params_id, dmabuf_err_plane_set, "plane already set");
            p.planes |= bit;
            p.modifiers[idx] = (@as(u64, args[4].uint) << 32) | args[5].uint;
            return;
        }
        p.used = true;
        // create: width, height, format, flags; create_immed: buffer_id first
        const a = if (is_immed) args[1..] else args;
        const width = a[0].int;
        const height = a[1].int;
        const format = a[2].uint;
        const n = @popCount(p.planes);
        if (p.planes != (@as(u8, 1) << @intCast(n)) - 1 or n != dmabufFormatPlanes(format))
            return self.sendError(conn_id, params_id, dmabuf_err_incomplete, "missing or too many planes");
        for (p.modifiers[1..n]) |m| {
            if (m != p.modifiers[0]) return self.sendError(conn_id, params_id, dmabuf_err_invalid_format, "planes use different modifiers");
        }
        const supported = if (self.dmabuf) |d| d.supports(format, p.modifiers[0]) else false;
        if (!supported) return self.sendError(conn_id, params_id, dmabuf_err_invalid_format, "format + modifier not advertised");
        if (width < 1 or height < 1) return self.sendError(conn_id, params_id, dmabuf_err_invalid_dimensions, "width and height must be positive");
        if (is_create) {
            // the wl_buffer is ours to allocate: one dense server-id space
            // with the offers (objects.zig); the relay learns the id from
            // DMABUF_CREATED before the client can name it
            const buffer_id = conn.next_server_id;
            conn.next_server_id += 1;
            try conn.objects.put(self.gpa, buffer_id, comptime protocol.find("wl_buffer").?, 1);
            if (self.dmabuf_created_fn) |f| f(self.ctx, conn_id, params_id, buffer_id);
            self.sendEvent(conn_id, params_id, "zwp_linux_buffer_params_v1", "created", &.{.{ .new_id = buffer_id }});
        }
        // create_immed: trackNewIds already made the wl_buffer
    }

    /// Initial event burst for freshly bound globals. Objects the POC treats
    /// as inert stubs get nothing.
    fn onBind(self: *Compositor, conn_id: u32, conn: *Conn, interface: []const u8, version: u32, id: u32) void {
        if (std.mem.eql(u8, interface, "wl_shm")) {
            self.sendEvent(conn_id, id, "wl_shm", "format", &.{.{ .uint = shm_format_argb8888 }});
            self.sendEvent(conn_id, id, "wl_shm", "format", &.{.{ .uint = shm_format_xrgb8888 }});
        } else if (std.mem.eql(u8, interface, "zwp_linux_dmabuf_v1")) {
            // v4+: formats come with the feedback. v3: one modifier event per
            // table entry. v1/v2: a `format` event promises the implicit
            // modifier (DRM_FORMAT_MOD_INVALID), so one per format the table
            // offers with it (virtgpu's; readback's LINEAR-only table: none).
            if (self.dmabuf) |d| {
                if (version == 3) for (0..d.count()) |i| {
                    const e = d.entry(i);
                    self.sendEvent(conn_id, id, "zwp_linux_dmabuf_v1", "modifier", &.{
                        .{ .uint = e.format }, .{ .uint = @truncate(e.modifier >> 32) }, .{ .uint = @truncate(e.modifier) },
                    });
                };
                if (version < 3) for (0..d.count()) |i| {
                    const e = d.entry(i);
                    if (e.modifier != dmabuf_mod_invalid) continue;
                    const seen = for (0..i) |j| {
                        const o = d.entry(j);
                        if (o.format == e.format and o.modifier == dmabuf_mod_invalid) break true;
                    } else false;
                    if (!seen) self.sendEvent(conn_id, id, "zwp_linux_dmabuf_v1", "format", &.{.{ .uint = e.format }});
                };
            }
        } else if (std.mem.eql(u8, interface, "wp_presentation")) {
            self.sendEvent(conn_id, id, "wp_presentation", "clock_id", &.{.{ .uint = presentation_clock_monotonic }});
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            self.sendEvent(conn_id, id, "wl_seat", "capabilities", &.{
                .{ .uint = seat_capability_pointer | seat_capability_keyboard | seat_capability_touch },
            });
            if (version >= 2) {
                self.sendEvent(conn_id, id, "wl_seat", "name", &.{.{ .string = "wland-seat" }});
            }
        } else if (std.mem.eql(u8, interface, "wl_output")) {
            self.sendEvent(conn_id, id, "wl_output", "geometry", &.{
                .{ .int = 0 },    .{ .int = 0 }, // x, y
                .{ .int = 340 },  .{ .int = 190 }, // physical mm (~96dpi guess)
                .{ .int = 0 }, // subpixel unknown
                .{ .string = "wland" }, .{ .string = "canvas" },
                .{ .int = 0 }, // transform normal
            });
            self.sendOutputMode(conn_id, id);
            if (version >= 2) {
                self.sendEvent(conn_id, id, "wl_output", "scale", &.{.{ .int = self.scaleOf(conn).int }});
                if (version >= 4) {
                    // name/description precede done (v4); name is stable, so
                    // it's only ever sent here, not on the live-mode resend
                    self.sendEvent(conn_id, id, "wl_output", "name", &.{.{ .string = "WL-1" }});
                    self.sendEvent(conn_id, id, "wl_output", "description", &.{.{ .string = "wland virtual output" }});
                }
                self.sendEvent(conn_id, id, "wl_output", "done", &.{});
                // track for live-mode resends on desktop resize
                conn.output_ids.append(self.gpa, id) catch {};
                // surfaces that already have content are on this output too
                // (a client may bind wl_output late, or a second time)
                var it = conn.surfaces.iterator();
                while (it.next()) |kv| {
                    if (kv.value_ptr.on_output) {
                        self.sendEvent(conn_id, kv.key_ptr.*, "wl_surface", "enter", &.{.{ .object = id }});
                    }
                }
            }
        }
    }

    /// wl_surface.enter / leave. There is one output and every surface with
    /// content is on it, so a surface enters at the commit that gives it a
    /// buffer and leaves at the one that takes it away (attach(NULL), or its
    /// xdg role object destroyed) — once per wl_output object the client
    /// bound. Clients key per-output state on it: xwayland-satellite applies
    /// a surface's fractional preferred_scale to the X screen only once the
    /// surface has entered an output. A destroyed surface gets no leave.
    fn setOnOutput(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32, surface: *Surface, on: bool) void {
        if (!on) {
            // no content: it no longer counts towards its window's bounds
            surface.log_w = 0;
            surface.log_h = 0;
        }
        if (surface.on_output == on) return;
        surface.on_output = on;
        for (conn.output_ids.items) |output_id| {
            const args: []const wire.Value = &.{.{ .object = output_id }};
            if (on) {
                self.sendEvent(conn_id, surface_id, "wl_surface", "enter", args);
            } else {
                self.sendEvent(conn_id, surface_id, "wl_surface", "leave", args);
            }
        }
    }

    /// wl_output.mode = the real desktop size in hardware px (logical × scale),
    /// current | preferred. Sent on bind and re-sent on desktop resize.
    fn sendOutputMode(self: *Compositor, conn_id: u32, output_id: u32) void {
        const scale = self.scaleOfId(conn_id).int;
        self.sendEvent(conn_id, output_id, "wl_output", "mode", &.{
            .{ .uint = 0x1 | 0x2 }, // current | preferred
            .{ .int = self.desk_w *| scale }, .{ .int = self.desk_h *| scale },
            .{ .int = 60000 },
        });
    }

    /// Embedder: the logical desktop area changed (browser window resize,
    /// zoom, the browser's fullscreen). Push a fresh mode + done to every
    /// bound wl_output so apps re-layout (wl_output allows live mode
    /// changes), and reconfigure the maximized and fullscreen toplevels to
    /// the new size (new configure_bounds first, for v4+). Floating windows
    /// keep their size and are not sent the new bounds.
    pub fn setDesktopSize(self: *Compositor, w: i32, h: i32) void {
        const nw = @max(1, w);
        const nh = @max(1, h);
        if (nw == self.desk_w and nh == self.desk_h) return;
        self.desk_w = nw;
        self.desk_h = nh;
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn_id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            for (conn.output_ids.items) |output_id| {
                self.sendOutputMode(conn_id, output_id);
                self.sendEvent(conn_id, output_id, "wl_output", "done", &.{});
            }
            var sit = conn.surfaces.valueIterator();
            while (sit.next()) |surface| {
                if (surface.role != .toplevel or !surface.configured or surface.toplevel_id == 0) continue;
                if (!surface.maximized and !surface.fullscreen) continue;
                self.sendBounds(conn_id, conn, surface);
                self.sendCurrentConfigure(conn_id, conn, surface);
            }
            // the bounds popups are constrained to changed
            var rit = conn.surfaces.iterator();
            while (rit.next()) |skv| {
                if (skv.value_ptr.role == .toplevel and skv.value_ptr.win_pos != null) self.replaceReactive(conn_id, conn, skv.key_ptr.*);
            }
        }
    }

    /// wl_keyboard.keymap needs an fd; emit via the FDMSG path (each
    /// keyboard its own: the relay makes a memfd per FDMSG). Followed by
    /// repeat_info for v4+ keyboards.
    fn sendKeymap(self: *Compositor, conn_id: u32, keyboard_id: u32, version: u32) void {
        const fdmsg_fn = self.fdmsg_fn orelse {
            self.logf("no fdmsg transport; keyboard will not get a keymap", .{});
            return;
        };
        // format 1 = xkb_v1; size includes the terminating NUL the server appends
        var buf: [64]u8 = undefined;
        const iface = comptime protocol.find("wl_keyboard").?;
        const opcode = comptime iface.eventIndex("keymap").?;
        const msg = wire.encodeMessage(&buf, keyboard_id, opcode, &.{
            .{ .uint = 1 },
            .fd,
            .{ .uint = keymap_text.len + 1 },
        });
        fdmsg_fn(self.ctx, conn_id, 2, msg, keymap_text); // kind 2 = keymap
        if (version >= 4) {
            self.sendEvent(conn_id, keyboard_id, "wl_keyboard", "repeat_info", &.{
                .{ .int = 25 }, .{ .int = 400 },
            });
        }
    }

    /// A wl_keyboard made while its client holds keyboard focus (Firefox's
    /// own, after GTK's got the enter): the enter it missed — the focus's
    /// serial again, no keys held — and the modifiers, to it alone (weston
    /// does the same). A wl_pointer's twin is latePointerEnter.
    fn lateKeyboardEnter(self: *Compositor, conn_id: u32, conn: *Conn, keyboard_id: u32) void {
        if (conn.keyboard_focus == 0) return;
        self.sendEvent(conn_id, keyboard_id, "wl_keyboard", "enter", &.{
            .{ .uint = conn.keyboard_enter_serial }, .{ .object = conn.keyboard_focus }, .{ .array = &.{} },
        });
        self.sendModifiersTo(conn_id, conn, keyboard_id);
    }

    /// A wl_pointer made while its client holds pointer focus: the enter it
    /// missed, with the focus's serial (so a set_cursor naming it, from any
    /// of the client's pointers, still counts) and the pointer's position
    /// as the client last saw it, then a frame (v5+).
    fn latePointerEnter(self: *Compositor, conn_id: u32, conn: *Conn, pointer_id: u32, version: u32) void {
        if (conn.pointer_focus == 0) return;
        self.sendEvent(conn_id, pointer_id, "wl_pointer", "enter", &.{
            .{ .uint = conn.pointer_enter_serial }, .{ .object = conn.pointer_focus },
            .{ .fixed = conn.pointer_x },           .{ .fixed = conn.pointer_y },
        });
        if (version >= 5) self.sendEvent(conn_id, pointer_id, "wl_pointer", "frame", &.{});
    }

    /// A seat object over max_seat_objects: it exists (the client may use
    /// and destroy it) but is sent nothing.
    fn seatObjectIgnored(self: *Compositor, conn_id: u32, comptime iface_name: []const u8, id: u32) void {
        self.logf("c{d}: {s}@{d}: over {d} of them, it gets no events", .{ conn_id, iface_name, id, max_seat_objects });
    }

    /// One event to every object of `set` at version `min_version` or later
    /// (seat events fan out to every binding's objects; the version gate is
    /// per object, never per client).
    fn seatEvent(self: *Compositor, conn_id: u32, set: *const SeatObjects, comptime iface_name: []const u8, comptime event_name: []const u8, args: []const wire.Value, min_version: u32) void {
        for (set.slice()) |o| {
            if (o.version >= min_version) self.sendEvent(conn_id, o.id, iface_name, event_name, args);
        }
    }

    fn nextSerial(conn: *Conn) u32 {
        conn.serial += 1;
        return conn.serial;
    }

    // ------------------------------------------------------------------
    // clipboard (wl_data_device selection)
    // ------------------------------------------------------------------

    /// A source's `offer(mime)` (wl_data_source, primary source): kept
    /// unless over max_mime_len (it would be echoed in fixed-size events)
    /// or the source already offers max_source_mimes. Ignored, like the
    /// spec's other bad requests without an error code.
    fn addSourceMime(self: *Compositor, conn_id: u32, list: *std.ArrayList([]u8), mime: ?[]const u8) !void {
        const m = mime orelse "";
        if (m.len > max_mime_len) return self.logf("c{d}: offer of a {d}-byte mime type ignored", .{ conn_id, m.len });
        if (list.items.len >= max_source_mimes) return;
        const copy = try self.gpa.dupe(u8, m);
        list.append(self.gpa, copy) catch |err| {
            self.gpa.free(copy);
            return err;
        };
    }

    fn setSelection(self: *Compositor, conn_id: u32, source_id: u32) void {
        if (self.selection) |old| {
            // replaced (or cleared) → previous source is done; wl-copy exits on this
            if (old.conn == 0) {
                self.dropOwnSelection(); // the embedder's: nobody to cancel
            } else if (!(old.conn == conn_id and old.source == source_id)) {
                self.sendEvent(old.conn, old.source, "wl_data_source", "cancelled", &.{});
            }
        }
        self.selection = if (source_id != 0) .{ .conn = conn_id, .source = source_id } else null;
        self.broadcastSelection();
        // an explicit clear (set_selection(null)) names the client that
        // cleared it, with no types: the embedder tells it apart from the
        // owner going (conn 0, no types) — the page clipboard follows a clear
        if (source_id == 0) {
            if (self.selection_fn) |f| f(self.ctx, conn_id, &.{});
        } else self.notifySelection();
    }

    /// Tell the embedder what the clipboard selection is now (selection_fn).
    fn notifySelection(self: *Compositor) void {
        const f = self.selection_fn orelse return;
        const sel = self.selection orelse return f(self.ctx, 0, &.{});
        if (sel.conn == 0) {
            const own = &(self.own_selection orelse return f(self.ctx, 0, &.{}));
            var mimes: std.ArrayList([]const u8) = .empty;
            defer mimes.deinit(self.gpa);
            for (own.entries.items) |e| mimes.append(self.gpa, e.mime) catch return;
            return f(self.ctx, 0, mimes.items);
        }
        const src_conn = self.conns.get(sel.conn) orelse return f(self.ctx, sel.conn, &.{});
        const list = src_conn.source_mimes.get(sel.source) orelse return f(self.ctx, sel.conn, &.{});
        f(self.ctx, sel.conn, list.items);
    }

    fn dropOwnSelection(self: *Compositor) void {
        const own = &(self.own_selection orelse return);
        // the relay's copies of it go too (FDMSG own_pipe, generation 0)
        if (own.sent != 0) {
            if (self.fdmsg_fn) |f| {
                var aux: [stream.OwnPipe.header_len]u8 = undefined;
                (stream.OwnPipe{ .token = 0, .gen = 0, .blob = 0, .flags = 0, .bytes = &.{} }).writeHeader(&aux);
                f(self.ctx, 0, @intFromEnum(stream.FdMsgKind.own_pipe), &.{}, &aux);
            }
        }
        own.deinit(self.gpa);
        self.own_selection = null;
    }

    /// The embedder's own clipboard selection (the page's clipboard, say):
    /// it replaces whatever a client set (that source is cancelled) and is
    /// offered, like any selection, only to the keyboard-focused client.
    /// The core keeps the bytes and answers each `receive` (serveOwn: FDMSG
    /// own_pipe, the relay writes them into the receiver's pipe and closes
    /// it). Only on a link whose relay said it can (selection_bridge),
    /// else error.Unsupported and nothing changes. `entries`:
    /// repeated { u32 mime_len, mime, u32 data_len, data }, little-endian;
    /// data_len 0xffffffff = the previous entry's data again (aliases such
    /// as text/plain and UTF8_STRING share one copy). An empty `entries`
    /// clears the selection if it is the embedder's own (never a client's).
    /// Malformed input, an empty or NUL-holding mime, or more than
    /// own_selection_max bytes in all leave the selection unchanged.
    pub fn setOwnSelection(self: *Compositor, entries: []const u8) !void {
        if (!self.selection_bridge) return error.Unsupported;
        if (entries.len == 0) {
            const sel = self.selection orelse return;
            if (sel.conn != 0) return;
            self.dropOwnSelection();
            self.selection = null;
            self.broadcastSelection();
            self.notifySelection();
            return;
        }
        const own = try self.parseOwnEntries(entries);
        if (self.selection) |old| {
            if (old.conn != 0) self.sendEvent(old.conn, old.source, "wl_data_source", "cancelled", &.{});
        }
        self.dropOwnSelection();
        self.own_selection = own;
        self.own_gen +%= 1;
        if (self.own_gen == 0) self.own_gen = 1;
        self.selection = .{ .conn = 0, .source = self.own_gen };
        self.broadcastSelection();
        self.notifySelection();
    }

    /// setOwnSelection's packed entries (also setOwnDragData's) as owned
    /// payloads: repeated { u32 mime_len, mime, u32 data_len, data },
    /// little-endian, data_len 0xffffffff = the previous entry's data again;
    /// the first entry of a mime wins. Empty: none.
    fn parseOwnEntries(self: *Compositor, entries: []const u8) !OwnSelection {
        var own: OwnSelection = .{};
        errdefer own.deinit(self.gpa);
        var total: usize = 0;
        var rest = entries;
        while (rest.len > 0) {
            if (rest.len < 4) return error.BadSelection;
            const mime_len = std.mem.readInt(u32, rest[0..4], .little);
            if (mime_len == 0 or mime_len > max_mime_len or rest.len - 4 < @as(usize, mime_len) + 4) return error.BadSelection;
            const mime = rest[4..][0..mime_len];
            if (std.mem.indexOfScalar(u8, mime, 0) != null) return error.BadSelection;
            rest = rest[4 + mime_len ..];
            const data_len = std.mem.readInt(u32, rest[0..4], .little);
            rest = rest[4..];
            var blob: u32 = undefined;
            if (data_len == 0xffffffff) {
                if (own.blobs.items.len == 0) return error.BadSelection;
                blob = @intCast(own.blobs.items.len - 1);
            } else {
                if (rest.len < data_len) return error.BadSelection;
                total += data_len;
                if (total > own_selection_max) return error.SelectionTooLarge;
                // one payload a mime at most (OwnSelection.sent is a u32)
                if (own.blobs.items.len == own_selection_max_mimes) return error.BadSelection;
                const copy = try self.gpa.dupe(u8, rest[0..data_len]);
                own.blobs.append(self.gpa, copy) catch |err| {
                    self.gpa.free(copy);
                    return err;
                };
                blob = @intCast(own.blobs.items.len - 1);
                rest = rest[data_len..];
            }
            if (own.data(mime) != null) continue; // the first one of a mime wins
            if (own.entries.items.len == own_selection_max_mimes) return error.BadSelection;
            const m = try self.gpa.dupe(u8, mime);
            own.entries.append(self.gpa, .{ .mime = m, .blob = blob }) catch |err| {
                self.gpa.free(m);
                return err;
            };
        }
        return own;
    }

    /// Read the current clipboard selection as `mime` for the embedder:
    /// the source client is sent `send(mime, fd)` in an FDMSG pipe_read
    /// frame (aux = read_id ++ max_bytes) — the relay makes the pipe, reads
    /// it (bounded by `max_bytes` and its own deadline) and answers with
    /// pipe_read data for read_id. False (nothing sent): the relay can't
    /// (no selection_bridge), no selection, the embedder's own (it has the
    /// bytes), or `mime` not offered.
    pub fn readSelection(self: *Compositor, mime: []const u8, read_id: u32, max_bytes: u32) bool {
        if (!self.selection_bridge) return false;
        const sel = self.selection orelse return false;
        if (sel.conn == 0 or mime.len == 0 or mime.len > max_mime_len) return false;
        const src_conn = self.conns.get(sel.conn) orelse return false;
        const list = src_conn.source_mimes.get(sel.source) orelse return false;
        const offered = for (list.items) |m| {
            if (std.mem.eql(u8, m, mime)) break true;
        } else false;
        if (!offered) return false;
        const fdmsg_fn = self.fdmsg_fn orelse return false;
        const opcode = comptime protocol.find("wl_data_source").?.eventIndex("send").?;
        var buf: [512]u8 = undefined;
        const msg = wire.encode(&buf, sel.source, opcode, &.{ .{ .string = mime }, .fd }) catch return false;
        var aux: [8]u8 = undefined;
        std.mem.writeInt(u32, aux[0..4], read_id, .little);
        std.mem.writeInt(u32, aux[4..8], max_bytes, .little);
        fdmsg_fn(self.ctx, sel.conn, @intFromEnum(stream.FdMsgKind.pipe_read), msg, &aux);
        return true;
    }

    /// Deliver the current selection to every conn that holds keyboard focus
    /// (at most one in practice — the embedder moves focus with blur-first).
    fn broadcastSelection(self: *Compositor) void {
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.keyboard_focus != 0) {
                self.deliverSelection(kv.key_ptr.*, kv.value_ptr.*);
            }
        }
    }

    /// The selection to each of the conn's wl_data_devices (offerSelection).
    fn deliverSelection(self: *Compositor, conn_id: u32, conn: *Conn) void {
        for (conn.data_devices.slice()) |dev| self.offerSelection(conn_id, conn, dev);
    }

    /// Introduce a fresh wl_data_offer proxying the selection on `dev` (its
    /// own: an offer is the object of one data device), then the selection
    /// event (null when the clipboard is empty). Spec order: data_offer
    /// intro → offer(mime)* → selection. Offers are server ids of the
    /// default type (wl_data_offer): no SRVOBJ.
    fn offerSelection(self: *Compositor, conn_id: u32, conn: *Conn, dev: SeatObjects.Obj) void {
        const sel = self.selection orelse {
            self.sendEvent(conn_id, dev.id, "wl_data_device", "selection", &.{.{ .object = 0 }});
            return;
        };
        var own_mimes: [own_selection_max_mimes][]const u8 = undefined;
        const mimes: []const []const u8 = if (sel.conn == 0) blk: {
            const own = &(self.own_selection orelse return);
            const n = @min(own.entries.items.len, own_mimes.len);
            for (own.entries.items[0..n], 0..) |e, i| own_mimes[i] = e.mime;
            break :blk own_mimes[0..n];
        } else blk: {
            const src_conn = self.conns.get(sel.conn) orelse return;
            break :blk (src_conn.source_mimes.get(sel.source) orelse return).items;
        };

        const offer_id = self.newOffer(conn, dev.version, sel, false) orelse return;
        self.sendEvent(conn_id, dev.id, "wl_data_device", "data_offer", &.{.{ .new_id = offer_id }});
        for (mimes) |mime| {
            self.sendEvent(conn_id, offer_id, "wl_data_offer", "offer", &.{.{ .string = mime }});
        }
        self.sendEvent(conn_id, dev.id, "wl_data_device", "selection", &.{.{ .object = offer_id }});
    }

    /// A fresh server id (the conn's one dense counter, objects.zig) for a
    /// wl_data_offer — or a primary offer — proxying `sel`, at the version
    /// of the device it is introduced on (a new_id in an event inherits it).
    /// The id is spent only once both maps hold it. null: out of memory.
    fn newOffer(self: *Compositor, conn: *Conn, version: u32, sel: Selection, primary: bool) ?u32 {
        const offer_id = conn.next_server_id;
        const iface = if (primary) comptime protocol.find("zwp_primary_selection_offer_v1").? else comptime protocol.find("wl_data_offer").?;
        conn.objects.put(self.gpa, offer_id, iface, version) catch return null;
        const map = if (primary) &conn.primary_offers else &conn.offers;
        map.put(self.gpa, offer_id, sel) catch {
            conn.objects.remove(offer_id);
            return null;
        };
        conn.next_server_id += 1;
        return offer_id;
    }

    /// A `receive(mime, fd)` arrived on a server-allocated offer (via FDMSG
    /// pipe — the fd stayed in the server under `token`). Route to the source
    /// as `send(mime, fd)` on the SOURCE conn; the transport echoes the token
    /// so the server can attach the stored fd. The offer id lands in EITHER the
    /// clipboard (offers) or the primary (primary_offers) map — the map it's in
    /// selects wl_data_source vs zwp_primary_selection_source_v1 for the send.
    pub fn onPipeReceive(self: *Compositor, conn_id: u32, bytes: []const u8, token: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        const header = wire.Header.parse(bytes) catch return;
        // server ids are one contiguous space shared by both offer types; the
        // map membership (not the id value) tells them apart
        const is_primary = conn.primary_offers.contains(header.object_id);
        const offer = (if (is_primary)
            conn.primary_offers.get(header.object_id)
        else
            conn.offers.get(header.object_id)) orelse {
            self.logf("c{d}: receive on unknown offer @{d}", .{ conn_id, header.object_id });
            return self.dropPipe(conn_id, token);
        };
        var vals: [wire.max_args]wire.Value = undefined;
        const args = wire.decodeArgs(bytes[wire.header_size..], &.{ .string, .fd }, &vals) catch
            return self.dropPipe(conn_id, token);
        const mime = args[0].string orelse return self.dropPipe(conn_id, token);
        // no source offers a longer one (addSourceMime), and it would be
        // echoed in the source's send event
        if (mime.len > max_mime_len) return self.dropPipe(conn_id, token);
        if (offer.conn == 0 and !is_primary) {
            if (offer.dnd) return self.serveOwnDrag(conn_id, header.object_id, offer.source, mime, token);
            return self.serveOwn(conn_id, offer.source, mime, token);
        }
        // an offer outlives its source (the receiver may hold it past a
        // selection change): a receive on it reads EOF, it is not routed to
        // whatever the source's id names by now
        if (offer.source == 0 or self.conns.get(offer.conn) == null) return self.dropPipe(conn_id, token);
        const fdmsg_fn = self.fdmsg_fn orelse return;
        const opcode = if (is_primary)
            comptime protocol.find("zwp_primary_selection_source_v1").?.eventIndex("send").?
        else
            comptime protocol.find("wl_data_source").?.eventIndex("send").?;
        var buf: [512]u8 = undefined;
        const msg = wire.encode(&buf, offer.source, opcode, &.{ .{ .string = mime }, .fd }) catch
            return self.dropPipe(conn_id, token);
        var aux: [4]u8 = undefined;
        std.mem.writeInt(u32, &aux, token, .little);
        fdmsg_fn(self.ctx, offer.conn, 3, msg, &aux); // kind 3 = pipe
    }

    /// A receive on an offer of the embedder's own selection (generation
    /// `gen`), answered with the token and no wire message: FDMSG own_pipe
    /// naming the payload, its bytes along only the first time on this link
    /// (the relay keeps them and writes them into the parked fd itself).
    /// Own selections exist only on a selection_bridge link, so no other
    /// relay is ever sent one. A stale offer (the own selection changed
    /// since) or a mime it does not have reads EOF, as for a gone source.
    fn serveOwn(self: *Compositor, conn_id: u32, gen: u32, mime: []const u8, token: u32) void {
        const own = &(self.own_selection orelse return self.dropPipe(conn_id, token));
        if (gen != self.own_gen) return self.dropPipe(conn_id, token);
        const blob = own.blobOf(mime) orelse return self.dropPipe(conn_id, token);
        const data = own.blobs.items[blob];
        if (!self.selection_bridge) return self.dropPipe(conn_id, token);
        const fdmsg_fn = self.fdmsg_fn orelse return;
        const bit = @as(u32, 1) << @intCast(blob);
        const first = own.sent & bit == 0;
        const hlen = stream.OwnPipe.header_len;
        const aux = self.gpa.alloc(u8, hlen + if (first) data.len else 0) catch return self.dropPipe(conn_id, token);
        defer self.gpa.free(aux);
        (stream.OwnPipe{ .token = token, .gen = gen, .blob = blob, .flags = if (first) stream.OwnPipe.has_bytes else 0, .bytes = &.{} }).writeHeader(aux[0..hlen]);
        if (first) @memcpy(aux[hlen..], data);
        fdmsg_fn(self.ctx, conn_id, @intFromEnum(stream.FdMsgKind.own_pipe), &.{}, aux);
        own.sent |= bit;
    }

    /// A receive that has no source to go to: hand the token back with no
    /// wire message, which makes the server close the parked write end — the
    /// receiver reads EOF instead of blocking on a pipe nobody will write.
    fn dropPipe(self: *Compositor, conn_id: u32, token: u32) void {
        const fdmsg_fn = self.fdmsg_fn orelse return;
        var aux: [4]u8 = undefined;
        std.mem.writeInt(u32, &aux, token, .little);
        fdmsg_fn(self.ctx, conn_id, 3, &.{}, &aux);
    }

    /// A source was destroyed: the offers made from it (in any conn) stay
    /// valid objects but lose their source. Its id is the client's to reuse.
    fn orphanOffers(self: *Compositor, src_conn: u32, source_id: u32, primary: bool) void {
        var conns = self.conns.valueIterator();
        while (conns.next()) |c| {
            var it = if (primary) c.*.primary_offers.valueIterator() else c.*.offers.valueIterator();
            while (it.next()) |o| {
                if (o.conn == src_conn and o.source == source_id) o.source = 0;
            }
        }
    }

    // ------------------------------------------------------------------
    // primary selection (zwp_primary_selection_device; M13) — a structural
    // twin of the clipboard above, driven off keyboard focus. Offers share the
    // clipboard's contiguous server-id counter; each is announced to the server
    // with a SRVOBJ frame so its receive interception knows the offer's type.
    // receive/send route through the same FDMSG pipe path.
    // ------------------------------------------------------------------

    fn setPrimarySelection(self: *Compositor, conn_id: u32, source_id: u32) void {
        if (self.primary_selection) |old| {
            // replaced (or cleared) → previous source is cancelled
            if (!(old.conn == conn_id and old.source == source_id)) {
                self.sendEvent(old.conn, old.source, "zwp_primary_selection_source_v1", "cancelled", &.{});
            }
        }
        self.primary_selection = if (source_id != 0) .{ .conn = conn_id, .source = source_id } else null;
        self.broadcastPrimarySelection();
    }

    /// Deliver the current primary selection to every conn holding keyboard
    /// focus (at most one — the embedder moves focus blur-first).
    fn broadcastPrimarySelection(self: *Compositor) void {
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.keyboard_focus != 0) {
                self.deliverPrimarySelection(kv.key_ptr.*, kv.value_ptr.*);
            }
        }
    }

    /// Introduce a fresh primary offer proxying the selection, then the
    /// selection event (null when empty). Spec order: data_offer intro →
    /// offer(mime)* → selection. Mirror of deliverSelection.
    fn deliverPrimarySelection(self: *Compositor, conn_id: u32, conn: *Conn) void {
        for (conn.primary_devices.slice()) |dev| self.offerPrimarySelection(conn_id, conn, dev.id);
    }

    /// One primary device's own offer + selection (offerSelection's twin).
    fn offerPrimarySelection(self: *Compositor, conn_id: u32, conn: *Conn, device_id: u32) void {
        const sel = self.primary_selection orelse {
            self.sendEvent(conn_id, device_id, "zwp_primary_selection_device_v1", "selection", &.{.{ .object = 0 }});
            return;
        };
        const src_conn = self.conns.get(sel.conn) orelse return;
        const mimes = src_conn.primary_source_mimes.get(sel.source) orelse return;

        const offer_id = self.newOffer(conn, 1, sel, true) orelse return;
        // tell the server this server id is a PRIMARY offer (SRVOBJ frame) so
        // its fd interception watches primary_offer.receive (opcode 0), not
        // data_offer.receive (opcode 1). Must precede the data_offer event so
        // the server records the type before the app can send receive. One
        // per offer: each device's offer is an id of its own.
        if (self.srvobj_fn) |f| f(self.ctx, conn_id, offer_id, srvobj_kind_primary_offer);
        self.sendEvent(conn_id, device_id, "zwp_primary_selection_device_v1", "data_offer", &.{.{ .new_id = offer_id }});
        for (mimes.items) |mime| {
            self.sendEvent(conn_id, offer_id, "zwp_primary_selection_offer_v1", "offer", &.{.{ .string = mime }});
        }
        self.sendEvent(conn_id, device_id, "zwp_primary_selection_device_v1", "selection", &.{.{ .object = offer_id }});
    }

    // ------------------------------------------------------------------
    // dnd (wl_data_device.start_drag; the embedder drives the session)
    // ------------------------------------------------------------------

    fn startDrag(self: *Compositor, conn_id: u32, conn: *Conn, source_id: u32, origin_id: u32, icon_id: u32) void {
        if (self.drag != null) {
            self.logf("c{d}: start_drag during a drag — ignored", .{conn_id});
            return;
        }
        if (conn.surfaces.get(origin_id) == null) return;
        var icon_surface: u32 = 0;
        if (icon_id != 0) {
            if (conn.surfaces.getPtr(icon_id)) |icon| {
                // the icon is input-inert, exactly like cursor surfaces
                icon.role = .dnd_icon;
                self.notifySurface(conn_id, icon_id, @intFromEnum(Role.dnd_icon));
                icon_surface = icon_id;
            }
        }
        self.drag = .{
            .source_conn = conn_id,
            .source_id = source_id,
            .origin_surface = origin_id,
            .icon_surface = icon_surface,
        };
        // kind 4 = dnd session started (value = icon surface id, 0 = none):
        // the embedder steals the pointer like a move/resize grab and drives
        // dragMotion/dragDrop/dragCancel until kind 5 ends the session
        if (self.interactive_fn) |f| f(self.ctx, conn_id, origin_id, 4, icon_id);
    }

    /// The embedder's own drag (an HTML drag entering the page): a dnd
    /// session with no source client, driven like any (dragMotion /
    /// dragDrop / dragCancel) — no held press needed, no client asked.
    /// `mimes`: the types it offers, NUL-separated (1…own_selection_max_mimes,
    /// each 1…max_mime_len bytes); `actions`: dnd_action_copy /
    /// dnd_action_move bits it allows (others are dropped; none left is
    /// refused). The payloads come later (setOwnDragData), before the drop.
    /// Only on a link whose relay can write the embedder's bytes into an
    /// app's pipe (selection_bridge: error.Unsupported otherwise, nothing
    /// is offered); error.Busy during another drag. The embedder is not sent
    /// drag-start/drag-end for it; drag_action_fn tells it what the target
    /// would do with a drop.
    pub fn beginOwnDrag(self: *Compositor, mimes: []const u8, actions: u32) !void {
        if (!self.selection_bridge) return error.Unsupported;
        if (self.drag != null) return error.Busy;
        const acts = actions & (dnd_action_copy | dnd_action_move);
        if (acts == 0 or mimes.len == 0) return error.BadDrag;
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |m| self.gpa.free(m);
            list.deinit(self.gpa);
        }
        var it = std.mem.splitScalar(u8, mimes, 0);
        while (it.next()) |m| {
            if (m.len == 0 or m.len > max_mime_len) return error.BadDrag;
            const dup = for (list.items) |have| {
                if (std.mem.eql(u8, have, m)) break true;
            } else false;
            if (dup) continue;
            if (list.items.len == own_selection_max_mimes) return error.BadDrag;
            const copy = try self.gpa.dupe(u8, m);
            list.append(self.gpa, copy) catch |err| {
                self.gpa.free(copy);
                return err;
            };
        }
        self.dropOwnDrag(); // the last one's receives are over
        self.own_drag_gen +%= 1;
        if (self.own_drag_gen == 0) self.own_drag_gen = 1;
        self.own_drag = .{ .gen = self.own_drag_gen, .mimes = list, .actions = acts };
        self.drag = .{ .source_conn = 0, .source_id = 0, .origin_surface = 0, .icon_surface = 0, .own = true };
    }

    /// The payloads of the embedder's own drag (setOwnSelection's packed
    /// entries; empty: it has none — every receive reads EOF), once: before
    /// its drop, or after a drop whose bytes were to come
    /// (dragDropBytes(true): a page's files, read or uploaded once dropped).
    /// Held receives are answered now. error.NoDrag: no own drag (or it
    /// ended, or dropped without awaiting them); error.AlreadySet: given
    /// before.
    pub fn setOwnDragData(self: *Compositor, entries: []const u8) !void {
        const own = &(self.own_drag orelse return error.NoDrag);
        const active = if (self.drag) |d| d.own else false;
        if (!active and !own.awaiting) return error.NoDrag;
        if (own.data != null) return error.AlreadySet;
        own.data = try self.parseOwnEntries(entries);
        self.answerHeld();
    }

    /// Every held receive answered from the payloads (they are known now).
    fn answerHeld(self: *Compositor) void {
        const own = &(self.own_drag orelse return);
        const held = own.held;
        own.held = .empty;
        defer {
            for (held.items) |h| self.gpa.free(h.mime);
            var l = held;
            l.deinit(self.gpa);
        }
        for (held.items) |h| self.writeOwnDrag(h.conn, h.mime, h.token);
    }

    /// A receive on an offer of the embedder's own drag (generation `gen`):
    /// from its payloads when they are known; held while they are not and
    /// the offer is the drag's current target; else EOF (a stale offer, a
    /// type it does not offer, a target it left, the drag over without them).
    fn serveOwnDrag(self: *Compositor, conn_id: u32, offer_id: u32, gen: u32, mime: []const u8, token: u32) void {
        const own = &(self.own_drag orelse return self.dropPipe(conn_id, token));
        if (own.gen != gen or !own.offers(mime)) return self.dropPipe(conn_id, token);
        if (own.data != null) return self.writeOwnDrag(conn_id, mime, token);
        const on_target = if (self.drag) |d| d.own and d.focus_conn == conn_id and d.isFocusOffer(offer_id) else false;
        if (!on_target and !own.awaitsOn(conn_id, offer_id)) return self.dropPipe(conn_id, token);
        if (own.held.items.len >= own_drag_max_held) return self.dropPipe(conn_id, token);
        const m = self.gpa.dupe(u8, mime) catch return self.dropPipe(conn_id, token);
        own.held.append(self.gpa, .{ .conn = conn_id, .offer = offer_id, .token = token, .mime = m }) catch {
            self.gpa.free(m);
            return self.dropPipe(conn_id, token);
        };
    }

    /// Answer a receive with the own drag's payload for `mime` (FDMSG pipe,
    /// no wire message, aux = token ++ the bytes: the relay writes them into
    /// the parked fd on its writer thread, as an own selection's, and
    /// closes it), or EOF when it has none of that type. Each receive
    /// carries its bytes (a drop is read once, not like a clipboard).
    fn writeOwnDrag(self: *Compositor, conn_id: u32, mime: []const u8, token: u32) void {
        const own = &(self.own_drag orelse return self.dropPipe(conn_id, token));
        const data = &(own.data orelse return self.dropPipe(conn_id, token));
        const bytes = data.data(mime) orelse return self.dropPipe(conn_id, token);
        if (bytes.len == 0) return self.dropPipe(conn_id, token);
        const fdmsg_fn = self.fdmsg_fn orelse return;
        const aux = self.gpa.alloc(u8, 4 + bytes.len) catch return self.dropPipe(conn_id, token);
        defer self.gpa.free(aux);
        std.mem.writeInt(u32, aux[0..4], token, .little);
        @memcpy(aux[4..], bytes);
        fdmsg_fn(self.ctx, conn_id, @intFromEnum(stream.FdMsgKind.pipe), &.{}, aux);
    }

    /// After the own drag's target changed (or the drag ended): held
    /// receives of offers that are no longer its target read EOF, and the
    /// embedder hears of a changed drop action.
    fn settleOwnDrag(self: *Compositor) void {
        const own = &(self.own_drag orelse return);
        const drag: ?Drag = if (self.drag) |d| (if (d.own) d else null) else null;
        var i: usize = 0;
        while (i < own.held.items.len) {
            const h = own.held.items[i];
            const live = (if (drag) |d| d.focus_conn == h.conn and d.isFocusOffer(h.offer) else false) or
                own.awaitsOn(h.conn, h.offer);
            if (live) {
                i += 1;
                continue;
            }
            _ = own.held.orderedRemove(i);
            self.gpa.free(h.mime);
            self.dropPipe(h.conn, h.token);
        }
        const effect = self.ownDragEffect();
        if (effect != own.told) {
            own.told = effect;
            if (self.drag_action_fn) |f| f(self.ctx, effect);
        }
    }

    /// What the own drag's target would do with a drop now: its negotiated
    /// action (set_actions, v3), or the drag's preferred one if it accepted
    /// without negotiating (a v1/v2 target); 0 without a target or accept.
    fn ownDragEffect(self: *Compositor) u32 {
        const own = self.own_drag orelse return 0;
        const drag = self.drag orelse return 0;
        if (!drag.own or drag.focus_surface == 0 or !drag.accepted) return 0;
        if (drag.negotiated) return drag.action;
        return if (own.actions & dnd_action_copy != 0) dnd_action_copy else own.actions & dnd_action_move;
    }

    /// The own drag is over for good: held receives read EOF, the embedder
    /// is told 0 if it was told an action, the payloads go.
    fn dropOwnDrag(self: *Compositor) void {
        const own = &(self.own_drag orelse return);
        for (own.held.items) |h| self.dropPipe(h.conn, h.token);
        if (own.told != 0) {
            if (self.drag_action_fn) |f| f(self.ctx, 0);
        }
        own.deinit(self.gpa);
        self.own_drag = null;
    }

    /// Embedder: the pointer is over (target_conn, target_surface) at x,y —
    /// 0,0 for "over nothing". Sends enter/leave/motion + fresh offers.
    pub fn dragMotion(self: *Compositor, target_conn_id: u32, target_surface_id: u32, time_ms: u32, x_fixed: i32, y_fixed: i32) void {
        const drag = if (self.drag) |*d| d else return;
        defer if (drag.own) self.settleOwnDrag();
        var conn_id = target_conn_id;
        var surface_id = target_surface_id;
        // null-source drags are client-internal: other clients never see them
        if (!drag.own and drag.source_id == 0 and conn_id != drag.source_conn) {
            conn_id = 0;
            surface_id = 0;
        }
        // only surfaces that could hold pointer focus are dnd targets
        if (surface_id != 0) {
            switch (self.surfaceRole(conn_id, surface_id)) {
                .none, .cursor, .dnd_icon => {
                    conn_id = 0;
                    surface_id = 0;
                },
                else => {},
            }
        }
        if (conn_id == drag.focus_conn and surface_id == drag.focus_surface) {
            if (surface_id == 0) return;
            const conn = self.conns.get(conn_id) orelse return;
            self.seatEvent(conn_id, &conn.data_devices, "wl_data_device", "motion", &.{
                .{ .uint = time_ms }, .{ .fixed = x_fixed }, .{ .fixed = y_fixed },
            }, 1);
            return;
        }
        self.dragLeaveFocus(drag);
        if (surface_id == 0) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.data_devices.len == 0 or conn.surfaces.get(surface_id) == null) return;
        var mimes: []const []u8 = &.{};
        var actions: u32 = 0;
        var sel: Selection = .{ .conn = drag.source_conn, .source = drag.source_id };
        if (drag.own) {
            const own = &(self.own_drag orelse return);
            mimes = own.mimes.items;
            actions = own.actions;
            sel = .{ .conn = 0, .source = own.gen, .dnd = true };
        } else if (drag.source_id != 0) {
            const src_conn = self.conns.get(drag.source_conn) orelse return;
            mimes = (src_conn.source_mimes.get(drag.source_id) orelse return).items;
            actions = src_conn.source_actions.get(drag.source_id) orelse 0;
        }
        drag.focus_conn = conn_id;
        drag.focus_surface = surface_id;
        drag.focus_offer_n = 0;
        drag.accepted = false;
        drag.negotiated = false;
        drag.action = 0;
        // one enter serial for every data device of the target (wlroots:
        // each gets the enter, with an offer of its own)
        const serial = nextSerial(conn);
        for (conn.data_devices.slice()) |dev| {
            var offer_id: u32 = 0;
            if (drag.source_id != 0 or drag.own) {
                // fresh offer per enter, same recipe as offerSelection: intro
                // → offer(mime)* → source_actions (v3); registered in
                // conn.offers so the server's receive interception routes
                // transfers to the source — or, for the embedder's own drag,
                // the core answers them (serveOwnDrag) (out of memory: an
                // enter with none)
                if (self.newOffer(conn, dev.version, sel, false)) |id| {
                    offer_id = id;
                    self.sendEvent(conn_id, dev.id, "wl_data_device", "data_offer", &.{.{ .new_id = id }});
                    for (mimes) |mime| {
                        self.sendEvent(conn_id, id, "wl_data_offer", "offer", &.{.{ .string = mime }});
                    }
                    if (dev.version >= 3) self.sendEvent(conn_id, id, "wl_data_offer", "source_actions", &.{.{ .uint = actions }});
                    drag.focus_offers[drag.focus_offer_n] = id;
                    drag.focus_offer_n += 1;
                }
            }
            self.sendEvent(conn_id, dev.id, "wl_data_device", "enter", &.{
                .{ .uint = serial },   .{ .object = surface_id },
                .{ .fixed = x_fixed }, .{ .fixed = y_fixed },
                .{ .object = offer_id },
            });
        }
    }

    /// Embedder: button released. A drop lands only on an accepting target;
    /// anything else is a cancel. Transfer + finish route through Conn.offers
    /// afterwards — the session itself ends here either way.
    /// The embedder's own drag lands only where the target accepted and
    /// would act (ownDragEffect: what the page's dropEffect showed); its
    /// payloads must be in by now (setOwnDragData) — none given is none at
    /// all: held and later receives read EOF, never block. (dragDropBytes:
    /// the bytes may come after.)
    pub fn dragDrop(self: *Compositor) void {
        self.dragDropBytes(false);
    }

    /// dragDrop; `later` (the embedder's own drag only): its payloads come
    /// after the drop (setOwnDragData) — the drop target's receives on the
    /// drop's offers wait for them meanwhile. The embedder must give them
    /// (empty for none) or its receives wait until the next own drag, the
    /// target's conn closing, or the link going.
    pub fn dragDropBytes(self: *Compositor, later: bool) void {
        const drag = self.drag orelse return;
        if (drag.focus_surface == 0 or (drag.source_id != 0 and !drag.accepted) or
            (drag.own and self.ownDragEffect() == 0))
        {
            self.dragCancel();
            return;
        }
        if (drag.own) {
            const own = &self.own_drag.?;
            own.dropped_conn = drag.focus_conn;
            own.drop_offers = drag.focus_offers;
            own.drop_offer_n = drag.focus_offer_n;
            if (own.data == null) {
                if (later) {
                    own.awaiting = true;
                } else {
                    own.data = .{};
                    self.answerHeld();
                }
            }
        }
        if (self.conns.get(drag.focus_conn)) |conn| {
            self.seatEvent(drag.focus_conn, &conn.data_devices, "wl_data_device", "drop", &.{}, 1);
        }
        if (drag.own) {
            self.endDrag();
            self.settleOwnDrag(); // (told 0: the drag is over)
            return;
        }
        if (drag.source_id != 0) {
            if (self.conns.get(drag.source_conn)) |src_conn| {
                if (objVersion(src_conn, drag.source_id) >= 3) {
                    self.sendEvent(drag.source_conn, drag.source_id, "wl_data_source", "dnd_drop_performed", &.{});
                }
            }
        }
        self.endDrag();
    }

    /// Embedder (Escape) or compositor (source/origin died, conn closed).
    pub fn dragCancel(self: *Compositor) void {
        const drag = if (self.drag) |*d| d else return;
        self.dragLeaveFocus(drag);
        if (drag.own) {
            // no source to tell; its receives read EOF, its payloads go
            self.endDrag();
            self.dropOwnDrag();
            return;
        }
        if (drag.source_id != 0) {
            if (self.conns.get(drag.source_conn)) |_| {
                self.sendEvent(drag.source_conn, drag.source_id, "wl_data_source", "cancelled", &.{});
            }
        }
        self.endDrag();
    }

    /// Send leave to the current target, if any. wl_data_device.leave carries
    /// no surface id, so it is safe even mid-teardown.
    fn dragLeaveFocus(self: *Compositor, drag: *Drag) void {
        defer drag.clearFocus();
        if (drag.focus_surface == 0) return;
        const conn = self.conns.get(drag.focus_conn) orelse return;
        self.seatEvent(drag.focus_conn, &conn.data_devices, "wl_data_device", "leave", &.{}, 1);
    }

    /// Tear down the session: icon role reverts (the embedder re-hides it)
    /// and the embedder learns the session ended (kind 5) — it may have been
    /// compositor-initiated.
    fn endDrag(self: *Compositor) void {
        const drag = self.drag orelse return;
        self.drag = null;
        if (drag.own) return; // the embedder began it: nothing to revert or tell
        if (drag.icon_surface != 0) {
            if (self.conns.get(drag.source_conn)) |conn| {
                if (conn.surfaces.getPtr(drag.icon_surface)) |icon| {
                    if (icon.role == .dnd_icon) {
                        icon.role = .none;
                        self.notifySurface(drag.source_conn, drag.icon_surface, @intFromEnum(Role.none));
                    }
                }
            }
        }
        if (self.interactive_fn) |f| f(self.ctx, drag.source_conn, drag.origin_surface, 5, 0);
    }

    /// Target accepted (or revoked, mime == null) the drag offer.
    fn dragAccept(self: *Compositor, conn_id: u32, offer_id: u32, mime: ?[]const u8) void {
        const drag = if (self.drag) |*d| d else return;
        if (conn_id != drag.focus_conn or !drag.isFocusOffer(offer_id) or (drag.source_id == 0 and !drag.own)) return;
        // no source offers a mime over max_mime_len: such an accept names
        // none of the offer's types — a revoke (and `target` echoes it)
        const m: ?[]const u8 = if (mime) |s| (if (s.len > max_mime_len) null else s) else null;
        drag.accepted = m != null;
        if (drag.own) return self.settleOwnDrag();
        if (self.conns.get(drag.source_conn)) |_| {
            self.sendEvent(drag.source_conn, drag.source_id, "wl_data_source", "target", &.{.{ .string = m }});
        }
    }

    /// Target's wl_data_offer.set_actions: negotiate and announce the action
    /// to both ends (v3 flow; GTK will not complete a drop without it).
    fn dragOfferActions(self: *Compositor, conn_id: u32, offer_id: u32, actions: u32, preferred: u32) void {
        const drag = if (self.drag) |*d| d else return;
        if (conn_id != drag.focus_conn or !drag.isFocusOffer(offer_id) or (drag.source_id == 0 and !drag.own)) return;
        if (drag.own) {
            const both = actions & self.own_drag.?.actions;
            const chosen: u32 = if (preferred & both != 0 and @popCount(preferred) == 1)
                preferred
            else if (both & dnd_action_copy != 0)
                dnd_action_copy
            else if (both & dnd_action_move != 0)
                dnd_action_move
            else
                0;
            drag.negotiated = true;
            drag.action = chosen;
            self.sendEvent(conn_id, offer_id, "wl_data_offer", "action", &.{.{ .uint = chosen }});
            return self.settleOwnDrag();
        }
        const src_conn = self.conns.get(drag.source_conn) orelse return;
        const both = actions & (src_conn.source_actions.get(drag.source_id) orelse 0);
        const chosen: u32 = if (preferred & both != 0)
            preferred
        else if (both & dnd_action_copy != 0)
            dnd_action_copy
        else if (both & dnd_action_move != 0)
            dnd_action_move
        else
            0;
        self.sendEvent(conn_id, offer_id, "wl_data_offer", "action", &.{.{ .uint = chosen }});
        if (objVersion(src_conn, drag.source_id) >= 3) {
            self.sendEvent(drag.source_conn, drag.source_id, "wl_data_source", "action", &.{.{ .uint = chosen }});
        }
    }

    /// Target's wl_data_offer.finish after a completed transfer. Routed via
    /// the offers map, not drag state — the session is long gone by now.
    fn dragFinish(self: *Compositor, conn_id: u32, conn: *Conn, offer_id: u32) void {
        const offer = conn.offers.get(offer_id) orelse return;
        if (offer.dnd) {
            // the embedder's drop is read: its payloads can go (another
            // receive on it now reads EOF)
            if (self.own_drag) |own| {
                if (own.gen == offer.source and own.dropped_conn == conn_id) self.dropOwnDrag();
            }
            return;
        }
        const src_conn = self.conns.get(offer.conn) orelse return;
        if (objVersion(src_conn, offer.source) >= 3) {
            self.sendEvent(offer.conn, offer.source, "wl_data_source", "dnd_finished", &.{});
        }
    }

    fn objVersion(conn: *Conn, id: u32) u32 {
        const entry = conn.objects.get(id) orelse return 0;
        return entry.version;
    }

    // ------------------------------------------------------------------
    // input entry points (driven by DOM events via the wasm glue)
    // ------------------------------------------------------------------

    pub fn pointerEnter(self: *Compositor, conn_id: u32, surface_id: u32, x_fixed: i32, y_fixed: i32) void {
        if (self.drag != null) return; // the dnd grab owns the pointer
        const conn = self.conns.get(conn_id) orelse return;
        // (focus is the conn's whether or not it has a wl_pointer yet: one
        // made later is sent this enter then, latePointerEnter)
        // pointer may enter toplevels and subsurfaces (CSD hover), never
        // cursors or dnd icons
        switch (self.surfaceRole(conn_id, surface_id)) {
            .cursor, .dnd_icon => return,
            else => {},
        }
        // a minimized window is not on screen (an embedder lagging behind)
        if (underMinimized(conn, surface_id)) return;
        // an enter only ever follows a leave (Qt warns otherwise): one for
        // the surface that already holds the pointer is nothing new (a
        // pointerover after the embedder's own re-enter at a grab's end);
        // another surface's goes after the leave the embedder didn't ask for
        if (conn.pointer_focus == surface_id) return;
        if (conn.pointer_focus != 0) self.pointerLeave(conn_id);
        conn.pointer_focus = surface_id;
        conn.buttons_held = 0; // a new surface: no press of this conn is held on it
        const serial = nextSerial(conn);
        conn.pointer_enter_serial = serial; // set_shape/set_cursor must echo this serial
        noteInputSerial(conn, serial); // a hover alone doesn't make it the last input conn
        conn.cursor_surface = 0; // a new enter takes a fresh set_cursor
        conn.cursor_shape = 0;
        // one serial for every wl_pointer: set_cursor/set_shape from any
        // of them names it
        self.seatEvent(conn_id, &conn.pointers, "wl_pointer", "enter", &.{
            .{ .uint = serial }, .{ .object = surface_id },
            .{ .fixed = x_fixed }, .{ .fixed = y_fixed },
        }, 1);
        self.pointerFrame(conn_id, conn);
        conn.pointer_x = x_fixed;
        conn.pointer_y = y_fixed;
        // a constraint of the surface may apply now (after the enter, as
        // the spec has it); one of a surface it moved off ends
        self.updateConstraints(conn_id, conn);
    }

    pub fn pointerLeave(self: *Compositor, conn_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.pointer_focus == 0) return;
        const focus = conn.pointer_focus;
        conn.pointer_focus = 0;
        conn.buttons_held = 0; // the implicit grab is over (its release goes elsewhere)
        // its constraint ends first (unlocked/unconfined while the client
        // still sees its surface under the pointer), then the leave
        self.updateConstraints(conn_id, conn);
        self.seatEvent(conn_id, &conn.pointers, "wl_pointer", "leave", &.{
            .{ .uint = nextSerial(conn) }, .{ .object = focus },
        }, 1);
        self.pointerFrame(conn_id, conn);
        // the shape or cursor surface the client set applied only while its
        // surface held the pointer — reset to the default pointer now
        conn.cursor_surface = 0;
        conn.cursor_shape = 0;
        if (self.cursor_shape_fn) |f| f(self.ctx, conn_id, cursor_shape_reset);
    }

    // motion/button/axis are only valid while a surface holds pointer focus;
    // clients (foot) SIGSEGV on e.g. axis-after-leave, and the browser can
    // produce that (wheel is not a pointer event — it fires with no
    // pointerenter when the wheel lands on a canvas the pointer never
    // entered, e.g. CDP mouseWheel at fresh coords)

    /// A pointer motion: wl_pointer.motion at x,y (surface-local), then the
    /// relative part to every zwp_relative_pointer_v1, then one frame. While
    /// a lock is active the position is frozen and only the relative motion
    /// goes out (x,y are ignored); while a confinement is active the
    /// position the client sees is clamped into its region.
    pub fn pointerMotion(self: *Compositor, conn_id: u32, time_ms: u32, x_fixed: i32, y_fixed: i32, rel: ?Relative) void {
        if (self.drag != null) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.pointer_focus == 0) return;
        const c = activeConstraint(conn);
        const moved = rel != null and (rel.?.dx != 0 or rel.?.dy != 0 or rel.?.dx_unaccel != 0 or rel.?.dy_unaccel != 0);
        const locked = c != null and c.?.lock;
        if (locked and !moved) return;
        if (!locked) {
            var x = x_fixed;
            var y = y_fixed;
            if (c) |confine| {
                if (nearestIn(conn, confine, x, y)) |p| {
                    x = p[0];
                    y = p[1];
                }
            }
            conn.pointer_x = x;
            conn.pointer_y = y;
            conn.pointer_time = time_ms;
            self.seatEvent(conn_id, &conn.pointers, "wl_pointer", "motion", &.{
                .{ .uint = time_ms }, .{ .fixed = x }, .{ .fixed = y },
            }, 1);
        }
        if (moved) {
            const r = rel.?;
            self.seatEvent(conn_id, &conn.relative_pointers, "zwp_relative_pointer_v1", "relative_motion", &.{
                .{ .uint = @truncate(r.utime >> 32) }, .{ .uint = @truncate(r.utime) },
                .{ .fixed = r.dx },                    .{ .fixed = r.dy },
                .{ .fixed = r.dx_unaccel },            .{ .fixed = r.dy_unaccel },
            }, 1);
        }
        self.pointerFrame(conn_id, conn);
        // into a constraint's region (it may start), out of a wanted lock's
        if (!locked) self.updateConstraints(conn_id, conn);
    }

    pub fn pointerButton(self: *Compositor, conn_id: u32, time_ms: u32, button: u32, pressed: bool) void {
        if (self.drag != null) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.pointer_focus == 0) return;
        const serial = nextSerial(conn);
        noteInputSerial(conn, serial);
        self.last_input_conn = conn_id;
        const bit = @as(u32, 1) << @as(u5, @truncate(button));
        if (pressed) {
            if (conn.buttons_held == 0) {
                conn.grab_serial_first = serial;
                conn.grab_surface = conn.pointer_focus;
            }
            conn.grab_serial_last = serial;
            conn.buttons_held |= bit;
        } else conn.buttons_held &= ~bit;
        self.seatEvent(conn_id, &conn.pointers, "wl_pointer", "button", &.{
            .{ .uint = serial }, .{ .uint = time_ms },
            .{ .uint = button }, .{ .uint = if (pressed) 1 else 0 },
        }, 1);
        self.pointerFrame(conn_id, conn);
    }

    /// Is `serial` that of a press in the implicit grab still going on, on
    /// `toplevel_id`'s window (the toplevel or one of its subsurfaces: foot's
    /// borders)? What xdg_toplevel.move/resize must name to be honoured
    /// (xdg-shell: the compositor may ignore a request whose serial is no
    /// longer valid). Released — or the pointer handed elsewhere — it is
    /// over, whatever the serial.
    fn inImplicitGrab(conn: *Conn, serial: u32, toplevel_id: u32) bool {
        return pressHeld(conn, serial) and subsurfaceRoot(conn, conn.grab_surface) == toplevel_id;
    }

    /// Is `serial` that of a press of this conn's implicit grab, still
    /// held? What wl_data_device.start_drag must name (GTK, Chromium: the
    /// press that began the drag gesture).
    fn pressHeld(conn: *Conn, serial: u32) bool {
        if (conn.buttons_held == 0) return false;
        return serial -% conn.grab_serial_first <= conn.grab_serial_last -% conn.grab_serial_first;
    }

    /// Keep `serial` among the conn's recent input serials (key, button,
    /// keyboard or pointer enter) — see maySetSelection.
    fn noteInputSerial(conn: *Conn, serial: u32) void {
        conn.input_serials[conn.input_serial_next % conn.input_serials.len] = serial;
        conn.input_serial_next +%= 1;
    }

    /// May this conn set (or clear) the clipboard or primary selection now?
    /// Only while it holds keyboard focus (what wl-copy waits for: it maps
    /// a 1×1 surface and sets the selection at its keyboard enter; GTK,
    /// Qt and foot copy on a key or click of their own window), or — a slow
    /// client whose request arrives after the focus moved — when `serial`
    /// is one of its recent input serials and no other client has had a
    /// key, a button or keyboard focus since. Otherwise a client in the
    /// background could replace the selection at any moment (and the page
    /// bridge would mirror it to the host clipboard). Refused requests are
    /// ignored, as the protocol has it for invalid serials.
    fn maySetSelection(self: *Compositor, conn_id: u32, conn: *Conn, serial: u32) bool {
        if (conn.keyboard_focus != 0) return true;
        if (self.last_input_conn != conn_id or serial == 0) return false;
        for (conn.input_serials) |s| if (s == serial) return true;
        return false;
    }

    /// A wheel event. `value_fixed` is the continuous scroll vector (surface
    /// coords); `value120` is the high-resolution discrete component (120 per
    /// detent, browser fractional deltas → smooth scroll). One frame per axis:
    /// axis_source(wheel) [v5+] · axis_relative_direction(identical) [v9+] ·
    /// axis_value120 [v8+] or axis_discrete [v5-7] · axis · frame [v5+]. The
    /// high-res / discrete events are each coupled BEFORE their axis event.
    /// Each wl_pointer gets the whole frame its own version allows (a v9
    /// GTK pointer and a v5 one of the same client differ).
    pub fn pointerAxis(self: *Compositor, conn_id: u32, time_ms: u32, axis: u32, value_fixed: i32, value120: i32) void {
        if (self.drag != null) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.pointer_focus == 0) return;
        for (conn.pointers.slice()) |p| {
            const v = p.version;
            if (v >= 5) {
                self.sendEvent(conn_id, p.id, "wl_pointer", "axis_source", &.{.{ .uint = axis_source_wheel }});
            }
            if (v >= 9) {
                self.sendEvent(conn_id, p.id, "wl_pointer", "axis_relative_direction", &.{
                    .{ .uint = axis }, .{ .uint = axis_direction_identical },
                });
            }
            if (v >= 8) {
                // spec: value120 must not be zero — skip the high-res event on a
                // pure-continuous scroll rather than emit a zero
                if (value120 != 0) {
                    self.sendEvent(conn_id, p.id, "wl_pointer", "axis_value120", &.{
                        .{ .uint = axis }, .{ .int = value120 },
                    });
                }
            } else if (v >= 5) {
                // deprecated axis_discrete carries whole detents only; fractional
                // (trackpad-style) deltas stay purely continuous for old clients
                const steps = @divTrunc(value120, value120_per_notch);
                if (steps != 0) {
                    self.sendEvent(conn_id, p.id, "wl_pointer", "axis_discrete", &.{
                        .{ .uint = axis }, .{ .int = steps },
                    });
                }
            }
            self.sendEvent(conn_id, p.id, "wl_pointer", "axis", &.{
                .{ .uint = time_ms }, .{ .uint = axis }, .{ .fixed = value_fixed },
            });
            if (v >= 5) self.sendEvent(conn_id, p.id, "wl_pointer", "frame", &.{});
        }
    }

    /// wl_pointer.frame to every v5+ wl_pointer (the end of one logical
    /// pointer event; older pointers have no frames).
    fn pointerFrame(self: *Compositor, conn_id: u32, conn: *Conn) void {
        self.seatEvent(conn_id, &conn.pointers, "wl_pointer", "frame", &.{}, 5);
    }

    // ------------------------------------------------------------------
    // touch (wl_touch): the embedder's points, one table per conn
    // (Conn.touch_points). Unlike the pointer there is no focus: each point
    // stays with the surface it went down on until its up. Every event goes
    // to every wl_touch of the conn (SeatObjects); a group ends with frame.
    // ------------------------------------------------------------------

    /// A touch point went down on `surface_id` at x,y (surface-local
    /// wl_fixed): wl_touch.down, a serial of its own (an input serial, like
    /// a button press: set_selection, and move/resize while the point is
    /// down). Ignored for a conn with no wl_touch, a surface that is gone,
    /// a cursor or dnd icon, a minimized window, during a dnd drag (its
    /// grab owns input), for an id already down and beyond
    /// max_touch_points.
    pub fn touchDown(self: *Compositor, conn_id: u32, time_ms: u32, surface_id: u32, id: i32, x_fixed: i32, y_fixed: i32) void {
        if (self.drag != null) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.touches.len == 0) return;
        // the down names the surface: a gone one would kill the client
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        switch (surface.role) {
            .cursor, .dnd_icon => return,
            else => {},
        }
        if (underMinimized(conn, surface_id)) return; // an embedder lagging behind
        if (touchById(conn, id) != null or conn.touch_n == max_touch_points) return;
        const serial = nextSerial(conn);
        noteInputSerial(conn, serial);
        self.last_input_conn = conn_id;
        conn.touch_points[conn.touch_n] = .{ .id = id, .surface = surface_id, .serial = serial };
        conn.touch_n += 1;
        self.seatEvent(conn_id, &conn.touches, "wl_touch", "down", &.{
            .{ .uint = serial }, .{ .uint = time_ms }, .{ .object = surface_id },
            .{ .int = id },      .{ .fixed = x_fixed }, .{ .fixed = y_fixed },
        }, 1);
        conn.touch_unframed = true;
    }

    /// A point that is down moved: x,y local to the surface it went down
    /// on, wherever it is now. Ignored for an id that is not down.
    pub fn touchMotion(self: *Compositor, conn_id: u32, time_ms: u32, id: i32, x_fixed: i32, y_fixed: i32) void {
        const conn = self.conns.get(conn_id) orelse return;
        if (touchById(conn, id) == null) return;
        self.seatEvent(conn_id, &conn.touches, "wl_touch", "motion", &.{
            .{ .uint = time_ms }, .{ .int = id }, .{ .fixed = x_fixed }, .{ .fixed = y_fixed },
        }, 1);
        conn.touch_unframed = true;
    }

    /// A point went up: wl_touch.up with a serial of its own (an input
    /// serial, as a button release's), and the id is free again. Ignored
    /// for an id that is not down.
    pub fn touchUp(self: *Compositor, conn_id: u32, time_ms: u32, id: i32) void {
        const conn = self.conns.get(conn_id) orelse return;
        const i = touchById(conn, id) orelse return;
        const serial = nextSerial(conn);
        noteInputSerial(conn, serial);
        self.last_input_conn = conn_id;
        removeTouch(conn, i);
        self.seatEvent(conn_id, &conn.touches, "wl_touch", "up", &.{
            .{ .uint = serial }, .{ .uint = time_ms }, .{ .int = id },
        }, 1);
        conn.touch_unframed = true;
    }

    /// The embedder's touch calls since the last one happened together:
    /// wl_touch.frame, if any of them sent something.
    pub fn touchFrame(self: *Compositor, conn_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        if (!conn.touch_unframed) return;
        conn.touch_unframed = false;
        self.seatEvent(conn_id, &conn.touches, "wl_touch", "frame", &.{}, 1);
    }

    /// The embedder took the touch sequence (the browser's pointercancel,
    /// its own drag): every point of the conn ends without its up.
    pub fn touchCancel(self: *Compositor, conn_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        self.cancelTouches(conn_id, conn);
    }

    /// wl_touch.cancel if a point is down, and every point is forgotten
    /// (cancel ends them all: wl_touch has no per-point cancel). The
    /// embedder's later calls naming them are ignored.
    fn cancelTouches(self: *Compositor, conn_id: u32, conn: *Conn) void {
        if (conn.touch_n == 0) return;
        conn.touch_n = 0;
        conn.touch_unframed = false;
        self.seatEvent(conn_id, &conn.touches, "wl_touch", "cancel", &.{}, 1);
    }

    fn touchById(conn: *const Conn, id: i32) ?usize {
        for (conn.touch_points[0..conn.touch_n], 0..) |p, i| if (p.id == id) return i;
        return null;
    }

    /// The point whose down had `serial` (still down), or null.
    fn touchBySerial(conn: *const Conn, serial: u32) ?TouchPoint {
        if (serial == 0) return null;
        for (conn.touch_points[0..conn.touch_n]) |p| if (p.serial == serial) return p;
        return null;
    }

    /// Order-preserving, like SeatObjects.remove.
    fn removeTouch(conn: *Conn, i: usize) void {
        std.mem.copyForwards(TouchPoint, conn.touch_points[i .. conn.touch_n - 1], conn.touch_points[i + 1 .. conn.touch_n]);
        conn.touch_n -= 1;
    }

    /// Is `serial` the down of a point still down on `toplevel_id`'s window
    /// (the toplevel or one of its subsurfaces)? What move/resize may name
    /// besides a held press (inImplicitGrab).
    fn touchGrab(conn: *Conn, serial: u32, toplevel_id: u32) bool {
        const p = touchBySerial(conn, serial) orelse return false;
        return subsurfaceRoot(conn, p.surface) == toplevel_id;
    }

    /// Is a point of the conn's on a surface `pred` holds for?
    fn touchesUnder(conn: *const Conn, comptime pred: fn (*const Conn, u32) bool) bool {
        for (conn.touch_points[0..conn.touch_n]) |p| if (pred(conn, p.surface)) return true;
        return false;
    }

    /// `surface_id` was destroyed or unmapped: the points on it and on
    /// surfaces whose subsurface chain leads to it are forgotten, SILENTLY
    /// (no up: the client already dropped what it hung on that surface;
    /// the embedder's calls naming them are ignored). Call it while the
    /// subsurfaces are still chained to it.
    fn dropTouchesOn(conn: *Conn, surface_id: u32) void {
        var i: usize = 0;
        while (i < conn.touch_n) {
            const s = conn.touch_points[i].surface;
            if (s == surface_id or subsurfaceRoot(conn, s) == surface_id) removeTouch(conn, i) else i += 1;
        }
    }

    // ------------------------------------------------------------------
    // pointer constraints (lock + confine) — the state machine is the
    // core's (Constraint); the embedder only grants and loses Pointer Lock
    // ------------------------------------------------------------------

    /// The browser locked its pointer to `surface_id` for the lock the conn
    /// wants (pointer_lock_fn): `locked`. A grant nobody waits for any more
    /// (the lock was withdrawn meanwhile) is ignored — the embedder was
    /// already told to let go.
    pub fn pointerLockGranted(self: *Compositor, conn_id: u32, surface_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        var it = conn.constraints.iterator();
        while (it.next()) |kv| {
            const c = kv.value_ptr;
            if (!c.lock or c.surface != surface_id or c.state != .wanted) continue;
            c.state = .active;
            self.sendEvent(conn_id, kv.key_ptr.*, "zwp_locked_pointer_v1", "locked", &.{});
            return;
        }
        self.logf("c{d}: pointer lock granted on surface {d}, which no lock waits for", .{ conn_id, surface_id });
    }

    /// The browser's pointer lock ended without the core asking (Esc, the
    /// tab lost focus, another page element took it): the active lock gets
    /// `unlocked`. A persistent one is wanted again at once if the pointer
    /// is still where it may lock (the embedder retries at the next user
    /// gesture: the browser refuses a request without one); a oneshot one
    /// is defunct.
    pub fn pointerLockLost(self: *Compositor, conn_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        var it = conn.constraints.iterator();
        while (it.next()) |kv| {
            const c = kv.value_ptr;
            if (c.lock and c.state == .active) self.deactivate(conn_id, kv.key_ptr.*, c);
        }
        self.updateConstraints(conn_id, conn);
    }

    /// lock_pointer / confine_pointer: one constraint per surface (any
    /// state but defunct counts, any wl_pointer of the seat), else the
    /// already_constrained error. The region is copied as it is now.
    fn createConstraint(self: *Compositor, conn_id: u32, conn: *Conn, manager_id: u32, id: u32, surface_id: u32, region_id: u32, lifetime: u32, lock: bool) !void {
        var it = conn.constraints.valueIterator();
        while (it.next()) |c| {
            if (c.surface == surface_id and c.state != .defunct) {
                return self.sendError(conn_id, manager_id, constraints_err_already_constrained, "the surface already has a pointer constraint");
            }
        }
        var c: Constraint = .{ .surface = surface_id, .lock = lock, .persistent = lifetime != constraint_lifetime_oneshot };
        if (region_id != 0) c.region = conn.regions.get(region_id);
        // a surface that is already gone: never applies
        if (!conn.surfaces.contains(surface_id)) c.state = .defunct;
        try conn.constraints.put(self.gpa, id, c);
        self.updateConstraints(conn_id, conn);
    }

    /// The surface committed: its constraints' set_region / cursor hint
    /// latch. An active confinement whose area (region ∩ input region)
    /// moved off the pointer warps it inside — wl_pointer.motion, no
    /// relative motion (spec) — or ends if nothing is left of the area.
    fn commitConstraints(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        var it = conn.constraints.iterator();
        while (it.next()) |kv| {
            const c = kv.value_ptr;
            if (c.surface != surface_id) continue;
            if (c.region_pending_set) {
                c.region = c.region_pending;
                c.region_pending_set = false;
            }
            if (c.hint_pending) |h| {
                c.hint = h;
                c.hint_pending = null;
            }
            if (c.lock or c.state != .active) continue;
            const p = nearestIn(conn, c, conn.pointer_x, conn.pointer_y) orelse {
                self.deactivate(conn_id, kv.key_ptr.*, c);
                continue;
            };
            if (p[0] == conn.pointer_x and p[1] == conn.pointer_y) continue;
            conn.pointer_x = p[0];
            conn.pointer_y = p[1];
            self.seatEvent(conn_id, &conn.pointers, "wl_pointer", "motion", &.{
                .{ .uint = conn.pointer_time }, .{ .fixed = p[0] }, .{ .fixed = p[1] },
            }, 1);
            self.pointerFrame(conn_id, conn);
        }
        self.updateConstraints(conn_id, conn);
    }

    /// Bring the conn's constraints in line with the pointer (see
    /// Constraint): an active one lasts while its surface holds pointer
    /// focus; an inactive one starts — a lock as wanted, a confinement
    /// active — when its surface has focus and the pointer is in its area;
    /// a wanted lock whose conditions went goes back to inactive. Then the
    /// embedder hears of a change in the lock the conn wants.
    fn updateConstraints(self: *Compositor, conn_id: u32, conn: *Conn) void {
        var it = conn.constraints.iterator();
        while (it.next()) |kv| {
            const c = kv.value_ptr;
            const holds = conn.pointer_focus == c.surface and conn.pointer_focus != 0 and inArea(conn, c);
            switch (c.state) {
                .defunct => {},
                .active => if (conn.pointer_focus != c.surface) self.deactivate(conn_id, kv.key_ptr.*, c),
                .wanted => if (!holds) {
                    c.state = .inactive;
                },
                .inactive => if (holds) {
                    if (c.lock) {
                        c.state = .wanted;
                    } else {
                        c.state = .active;
                        self.sendEvent(conn_id, kv.key_ptr.*, "zwp_confined_pointer_v1", "confined", &.{});
                    }
                },
            }
        }
        self.syncLockDesire(conn_id, conn);
    }

    /// An active constraint ends: unlocked/unconfined, then inactive
    /// (persistent: it may start again) or defunct (oneshot).
    fn deactivate(self: *Compositor, conn_id: u32, id: u32, c: *Constraint) void {
        self.sendDeactivated(conn_id, id, c);
        c.state = if (c.persistent) .inactive else .defunct;
    }

    fn sendDeactivated(self: *Compositor, conn_id: u32, id: u32, c: *const Constraint) void {
        if (c.lock) {
            self.sendEvent(conn_id, id, "zwp_locked_pointer_v1", "unlocked", &.{});
        } else {
            self.sendEvent(conn_id, id, "zwp_confined_pointer_v1", "unconfined", &.{});
        }
    }

    /// Tell the embedder when the lock the conn wants (a wanted or active
    /// lock's surface; at most one: only the focused surface's can be)
    /// changed.
    fn syncLockDesire(self: *Compositor, conn_id: u32, conn: *Conn) void {
        var want: u32 = 0;
        var it = conn.constraints.valueIterator();
        while (it.next()) |c| {
            if (c.lock and (c.state == .wanted or c.state == .active)) {
                want = c.surface;
                break;
            }
        }
        if (want == conn.lock_surface) return;
        conn.lock_surface = want;
        if (self.pointer_lock_fn) |f| f(self.ctx, conn_id, want);
    }

    /// The active constraint of the surface holding pointer focus, if any.
    fn activeConstraint(conn: *Conn) ?*Constraint {
        var it = conn.constraints.valueIterator();
        while (it.next()) |c| {
            if (c.state == .active and c.surface == conn.pointer_focus) return c;
        }
        return null;
    }

    fn inArea(conn: *Conn, c: *const Constraint) bool {
        const p = nearestIn(conn, c, conn.pointer_x, conn.pointer_y) orelse return false;
        return p[0] == conn.pointer_x and p[1] == conn.pointer_y;
    }

    /// The point of a constraint's area — its region ∩ the surface's input
    /// region ∩ the surface's bounds (when known) — nearest to x,y (wl_fixed
    /// surface-local; x,y itself when inside), or null when the area is
    /// empty. Box edges are exclusive: the last fixed step inside them.
    fn nearestIn(conn: *Conn, c: *const Constraint, x: i32, y: i32) ?[2]i32 {
        const surface = conn.surfaces.getPtr(c.surface) orelse return null;
        const all: Region.Box = .{ .x0 = std.math.minInt(i32), .y0 = std.math.minInt(i32), .x1 = std.math.maxInt(i32), .y1 = std.math.maxInt(i32) };
        const bounds: Region.Box = if (surface.log_w > 0 and surface.log_h > 0)
            .{ .x0 = 0, .y0 = 0, .x1 = surface.log_w, .y1 = surface.log_h }
        else
            all;
        const whole = [1]Region.Box{all};
        const a: []const Region.Box = if (c.region) |*r| r.slice() else &whole;
        const b: []const Region.Box = if (surface.input) |*r| r.slice() else &whole;
        var best: ?[2]i32 = null;
        var best_d: f64 = std.math.inf(f64);
        for (a) |ra| for (b) |rb| {
            const x0 = @max(ra.x0, rb.x0, bounds.x0);
            const y0 = @max(ra.y0, rb.y0, bounds.y0);
            const x1 = @min(ra.x1, rb.x1, bounds.x1);
            const y1 = @min(ra.y1, rb.y1, bounds.y1);
            if (x1 <= x0 or y1 <= y0) continue;
            const px = std.math.clamp(x, x0 *| 256, (x1 *| 256) -| 1);
            const py = std.math.clamp(y, y0 *| 256, (y1 *| 256) -| 1);
            const dx: f64 = @floatFromInt(@as(i64, px) - x);
            const dy: f64 = @floatFromInt(@as(i64, py) - y);
            const d = dx * dx + dy * dy;
            if (d < best_d) {
                best_d = d;
                best = .{ px, py };
            }
        };
        return best;
    }

    // ------------------------------------------------------------------
    // wp_viewporter (M11): per-surface crop + scale, double-buffered
    // ------------------------------------------------------------------

    /// wp_viewporter.get_viewport — associate a fresh viewport with a surface.
    fn getViewport(self: *Compositor, conn_id: u32, conn: *Conn, viewporter_id: u32, viewport_id: u32, surface_id: u32) void {
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        if (surface.viewport_id != 0) {
            self.sendError(conn_id, viewporter_id, viewporter_err_viewport_exists, "surface already has a viewport");
            return;
        }
        surface.viewport_id = viewport_id;
        conn.viewports.put(self.gpa, viewport_id, surface_id) catch {};
    }

    /// Resolve a viewport object to its (still-alive) surface, or raise
    /// no_surface if the wl_surface has been destroyed (spec).
    fn viewportSurface(self: *Compositor, conn_id: u32, conn: *Conn, viewport_id: u32) ?*Surface {
        const surface_id = conn.viewports.get(viewport_id) orelse return null;
        return conn.surfaces.getPtr(surface_id) orelse {
            self.sendError(conn_id, viewport_id, viewport_err_no_surface, "wl_surface was destroyed");
            return null;
        };
    }

    /// wp_viewport.set_source (wl_fixed args). All -1.0 → unset; any negative
    /// x/y or non-positive w/h → bad_value. Pending until commit.
    fn viewportSetSource(self: *Compositor, conn_id: u32, conn: *Conn, viewport_id: u32, x: i32, y: i32, w: i32, h: i32) void {
        const surface = self.viewportSurface(conn_id, conn, viewport_id) orelse return;
        if (x == fixed_neg_one and y == fixed_neg_one and w == fixed_neg_one and h == fixed_neg_one) {
            surface.vp_pending_src_set = false;
        } else if (x < 0 or y < 0 or w <= 0 or h <= 0) {
            self.sendError(conn_id, viewport_id, viewport_err_bad_value, "invalid viewport source rect");
            return;
        } else {
            surface.vp_pending_src = .{ x, y, w, h };
            surface.vp_pending_src_set = true;
        }
        surface.vp_src_dirty = true;
    }

    /// wp_viewport.set_destination (int args). (-1,-1) → unset; any other
    /// non-positive value → bad_value. Pending until commit.
    fn viewportSetDestination(self: *Compositor, conn_id: u32, conn: *Conn, viewport_id: u32, w: i32, h: i32) void {
        const surface = self.viewportSurface(conn_id, conn, viewport_id) orelse return;
        if (w == -1 and h == -1) {
            surface.vp_pending_dst_set = false;
        } else if (w <= 0 or h <= 0) {
            self.sendError(conn_id, viewport_id, viewport_err_bad_value, "invalid viewport destination size");
            return;
        } else {
            surface.vp_pending_dst_w = w;
            surface.vp_pending_dst_h = h;
            surface.vp_pending_dst_set = true;
        }
        surface.vp_dst_dirty = true;
    }

    /// wl_surface.commit: latch pending viewport state → current. bad_size is
    /// checked here (spec: "when the surface state is applied"): a set source
    /// with a non-integer width/height and no destination is illegal.
    fn applyViewport(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        if (surface.vp_src_dirty) {
            surface.vp_src_set = surface.vp_pending_src_set;
            surface.vp_src = surface.vp_pending_src;
            surface.vp_src_dirty = false;
        }
        if (surface.vp_dst_dirty) {
            surface.vp_dst_set = surface.vp_pending_dst_set;
            surface.vp_dst_w = surface.vp_pending_dst_w;
            surface.vp_dst_h = surface.vp_pending_dst_h;
            surface.vp_dst_dirty = false;
        }
        if (surface.vp_src_set and !surface.vp_dst_set and
            ((surface.vp_src[2] & 0xff) != 0 or (surface.vp_src[3] & 0xff) != 0))
        {
            self.sendError(conn_id, surface.viewport_id, viewport_err_bad_size, "non-integer viewport source without destination");
        }
    }

    // ------------------------------------------------------------------
    // wp_fractional_scale_v1 (M11): preferred surface scale in 120ths
    // ------------------------------------------------------------------

    /// wp_fractional_scale_manager_v1.get_fractional_scale — one per surface.
    /// A duplicate is fractional_scale_exists; otherwise send the current
    /// preferred scale immediately (spec: initial preferred scale is 1 until
    /// the first event, so clients expect one promptly).
    fn getFractionalScale(self: *Compositor, conn_id: u32, conn: *Conn, manager_id: u32, frac_id: u32, surface_id: u32) void {
        const surface = conn.surfaces.getPtr(surface_id) orelse return;
        if (surface.fractional_id != 0) {
            self.sendError(conn_id, manager_id, frac_err_fractional_scale_exists, "surface already has a fractional_scale");
            return;
        }
        surface.fractional_id = frac_id;
        conn.frac_scales.put(self.gpa, frac_id, surface_id) catch {};
        self.sendPreferredScale(conn_id, frac_id);
    }

    fn sendPreferredScale(self: *Compositor, conn_id: u32, frac_id: u32) void {
        self.sendEvent(conn_id, frac_id, "wp_fractional_scale_v1", "preferred_scale", &.{
            .{ .uint = @intCast(self.scaleOfId(conn_id).s120) },
        });
    }

    /// The scale an app is shown: the integer one (wl_output.scale, its
    /// mode's hardware px, preferred_buffer_scale) and the fractional one in
    /// 120ths (preferred_scale) — its pin's, else the page's.
    const ConnScale = struct { int: i32, s120: i32 };
    fn scaleOf(self: *const Compositor, conn: *const Conn) ConnScale {
        if (conn.scale_pin != 0) return .{ .int = conn.scale_pin, .s120 = conn.scale_pin * fractional_scale_denom };
        return .{ .int = self.output_scale, .s120 = @max(1, self.scale_120) };
    }
    fn scaleOfId(self: *const Compositor, conn_id: u32) ConnScale {
        const conn = self.conns.get(conn_id) orelse return .{ .int = self.output_scale, .s120 = @max(1, self.scale_120) };
        return self.scaleOf(conn);
    }

    /// Embedder (a CONN_SCALE): show app `conn_id` output scale `scale`
    /// (clamped 1…4) whatever the page's devicePixelRatio, or the page's
    /// again (0). Its buffers are then drawn like any app's at that scale
    /// (a scale-1 app on a HiDPI page: upscaled, the right size); positions,
    /// sizes and input stay logical. What it was already told is resent
    /// when the scale it sees changed, as on a dpr change.
    pub fn setConnScale(self: *Compositor, conn_id: u32, scale: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        const before = self.scaleOf(conn);
        conn.scale_pin = if (scale == 0) 0 else @intCast(@min(scale, 4));
        const after = self.scaleOf(conn);
        if (before.int == after.int and before.s120 == after.s120) return;
        self.resendScale(conn_id, conn, before.int != after.int);
    }

    /// What tells one app its scale, sent again: preferred_scale to every
    /// fractional object, preferred_buffer_scale/transform to every v6
    /// surface, and (`int_changed`) the wl_output scale + mode.
    fn resendScale(self: *Compositor, conn_id: u32, conn: *Conn, int_changed: bool) void {
        var fit = conn.frac_scales.keyIterator();
        while (fit.next()) |frac_id| self.sendPreferredScale(conn_id, frac_id.*);
        self.sendPreferredBufferScaleAll(conn_id, conn);
        if (int_changed) {
            const scale = self.scaleOf(conn).int;
            for (conn.output_ids.items) |oid| {
                self.sendEvent(conn_id, oid, "wl_output", "scale", &.{.{ .int = scale }});
                self.sendOutputMode(conn_id, oid);
                self.sendEvent(conn_id, oid, "wl_output", "done", &.{});
            }
        }
    }

    /// Embedder: the browser devicePixelRatio changed (matchMedia resolution
    /// listener). `output_scale` is the integer scale (round(dpr), clamped),
    /// `scale_120` the fractional preferred scale (round(dpr × 120)). Resend
    /// wp_fractional_scale preferred_scale to every fractional object,
    /// wl_compositor v6 preferred_buffer_scale/transform to every v6 surface,
    /// and (when the integer scale changed) the wl_output scale + mode —
    /// to every app but a pinned one (`setConnScale`). This is what removes
    /// the reload-on-dpr-change limit.
    pub fn setScale(self: *Compositor, output_scale: i32, scale_120: i32) void {
        const os = std.math.clamp(output_scale, 1, 4);
        const s120 = @max(1, scale_120);
        if (os == self.output_scale and s120 == self.scale_120) return;
        const scale_changed = os != self.output_scale;
        self.output_scale = os;
        self.scale_120 = s120;
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            // a pinned app's scale didn't change
            if (kv.value_ptr.*.scale_pin != 0) continue;
            self.resendScale(kv.key_ptr.*, kv.value_ptr.*, scale_changed);
        }
    }

    /// wl_compositor v6: preferred_buffer_scale (integer fallback for
    /// non-fractional clients) + preferred_buffer_transform (normal) for one
    /// surface. Sent at creation and on dpr change.
    fn sendPreferredBuffer(self: *Compositor, conn_id: u32, surface_id: u32) void {
        self.sendEvent(conn_id, surface_id, "wl_surface", "preferred_buffer_scale", &.{.{ .int = self.scaleOfId(conn_id).int }});
        self.sendEvent(conn_id, surface_id, "wl_surface", "preferred_buffer_transform", &.{.{ .uint = 0 }}); // normal
    }

    /// Resend preferred_buffer_scale/transform to every v6 surface (dpr change).
    fn sendPreferredBufferScaleAll(self: *Compositor, conn_id: u32, conn: *Conn) void {
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.wl_compositor_version >= 6) self.sendPreferredBuffer(conn_id, kv.key_ptr.*);
        }
    }

    /// wp_cursor_shape_device_v1.set_shape. An out-of-range shape is a
    /// protocol error (invalid_shape) — raised unconditionally, per spec. A
    /// serial that doesn't match the latest wl_pointer.enter is IGNORED, not
    /// an error. The shape applies only while the client's surface holds the
    /// pointer; the embedder maps it to a CSS cursor.
    fn setCursorShape(self: *Compositor, conn_id: u32, conn: *Conn, device_id: u32, serial: u32, shape: u32) void {
        if (shape < cursor_shape_min or shape > cursor_shape_max) {
            self.sendError(conn_id, device_id, cursor_shape_err_invalid_shape, "invalid cursor shape");
            return;
        }
        if (serial != conn.pointer_enter_serial) return; // stale — ignore
        if (conn.pointer_focus == 0) return; // pointer isn't over our surface
        conn.cursor_surface = 0; // whichever the client used last wins
        conn.cursor_shape = shape;
        if (self.cursor_shape_fn) |f| f(self.ctx, conn_id, shape);
    }

    /// wl_pointer.set_cursor: the pointer image becomes `surface_id`'s
    /// buffer with the hotspot at hx,hy (surface-local), or is hidden
    /// (surface_id 0). Like set_shape, it applies only to the latest enter
    /// (a stale serial is ignored, not an error) and only while the client
    /// holds the pointer; it replaces a shape set before it. Naming the
    /// current cursor surface again just moves the hotspot.
    fn setCursorSurface(self: *Compositor, conn_id: u32, conn: *Conn, serial: u32, surface_id: u32, hx: i32, hy: i32) void {
        if (serial != conn.pointer_enter_serial) return;
        if (conn.pointer_focus == 0) return;
        if (surface_id != 0 and !conn.surfaces.contains(surface_id)) return;
        conn.cursor_surface = surface_id;
        conn.cursor_shape = 0;
        conn.cursor_hx = hx;
        conn.cursor_hy = hy;
        self.emitCursorSurface(conn_id, conn);
    }

    /// Tell the embedder the conn's cursor-surface image: the surface and
    /// hotspot while it has content (a committed buffer), else 0 = hidden.
    fn emitCursorSurface(self: *Compositor, conn_id: u32, conn: *Conn) void {
        const f = self.cursor_surface_fn orelse return;
        if (conn.cursor_surface != 0) {
            if (conn.surfaces.getPtr(conn.cursor_surface)) |s| {
                if (s.on_output) return f(self.ctx, conn_id, conn.cursor_surface, conn.cursor_hx, conn.cursor_hy);
            }
        }
        f(self.ctx, conn_id, 0, 0, 0);
    }

    /// Raise a wl_display.error (fatal protocol error — the client disconnects).
    fn sendError(self: *Compositor, conn_id: u32, object_id: u32, code: u32, comptime message: []const u8) void {
        self.sendEvent(conn_id, 1, "wl_display", "error", &.{
            .{ .object = object_id }, .{ .uint = code }, .{ .string = message },
        });
    }

    pub fn keyboardEnter(self: *Compositor, conn_id: u32, surface_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        // (focus is the conn's whether or not it has a wl_keyboard yet: one
        // made later is sent this enter then, lateKeyboardEnter)
        if (conn.keyboard_focus == surface_id) return;
        // keyboard focus only ever lands on toplevels — apps crash on focus
        // events for surfaces without window state (foot + cursor surface)
        if (self.surfaceRole(conn_id, surface_id) != .toplevel) return;
        if (underMinimized(conn, surface_id)) return; // hidden: restore it first
        const before = conn.keyboard_focus;
        conn.keyboard_focus = surface_id;
        if (before != 0) self.sendActivation(conn_id, conn, before);
        self.sendActivation(conn_id, conn, surface_id);
        const serial = nextSerial(conn);
        noteInputSerial(conn, serial);
        self.last_input_conn = conn_id;
        conn.keyboard_enter_serial = serial;
        self.seatEvent(conn_id, &conn.keyboards, "wl_keyboard", "enter", &.{
            .{ .uint = serial }, .{ .object = surface_id }, .{ .array = &.{} },
        }, 1);
        self.sendModifiers(conn_id, conn);
        // clipboard follows keyboard focus (wl_data_device.selection on enter)
        self.deliverSelection(conn_id, conn);
        // primary selection follows keyboard focus the same way (M13)
        self.deliverPrimarySelection(conn_id, conn);
        // text-input focus follows keyboard focus too (spec)
        self.textInputEnter(conn_id, conn, surface_id);
    }

    pub fn keyboardLeave(self: *Compositor, conn_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.keyboard_focus == 0) return;
        self.seatEvent(conn_id, &conn.keyboards, "wl_keyboard", "leave", &.{
            .{ .uint = nextSerial(conn) }, .{ .object = conn.keyboard_focus },
        }, 1);
        const before = conn.keyboard_focus;
        conn.keyboard_focus = 0;
        self.textInputLeave(conn_id, conn);
        self.sendActivation(conn_id, conn, before);
    }

    /// zwp_text_input_v3.enter: sent when keyboard focus lands on a toplevel and
    /// this conn has a text input. An enter invalidates all text-input state
    /// (spec) — the client must resend enable + state, so we reset to disabled.
    fn textInputEnter(self: *Compositor, conn_id: u32, conn: *Conn, surface_id: u32) void {
        if (conn.text_input_id == 0 or conn.ti_focus_surface == surface_id) return;
        conn.ti_focus_surface = surface_id;
        conn.ti_enabled = false;
        conn.ti_pending_enable = false;
        conn.ti_cursor = .{};
        conn.ti_pending_cursor = .{};
        self.sendEvent(conn_id, conn.text_input_id, "zwp_text_input_v3", "enter", &.{.{ .object = surface_id }});
        self.textInputNotify(conn_id, conn);
    }

    /// zwp_text_input_v3.leave: sent when keyboard focus leaves. The referenced
    /// surface is still alive here (destruction clears ti_focus_surface first,
    /// silently) so the leave is safe.
    fn textInputLeave(self: *Compositor, conn_id: u32, conn: *Conn) void {
        if (conn.text_input_id == 0 or conn.ti_focus_surface == 0) return;
        self.sendEvent(conn_id, conn.text_input_id, "zwp_text_input_v3", "leave", &.{.{ .object = conn.ti_focus_surface }});
        conn.ti_focus_surface = 0;
        conn.ti_enabled = false;
        conn.ti_pending_enable = false;
        self.textInputNotify(conn_id, conn);
    }

    /// Tell the embedder whether composition should route to this conn now.
    fn textInputNotify(self: *Compositor, conn_id: u32, conn: *Conn) void {
        const f = self.text_input_fn orelse return;
        const active = conn.text_input_id != 0 and conn.ti_focus_surface != 0 and conn.ti_enabled;
        const c = conn.ti_cursor;
        f(self.ctx, conn_id, @intFromBool(active), c.x, c.y, c.w, c.h);
    }

    /// Browser composition update → preedit_string + done. Only an entered,
    /// enabled text input is fed; done echoes the last commit serial (spec).
    pub fn textInputPreedit(self: *Compositor, conn_id: u32, text: []const u8, cursor_begin: i32, cursor_end: i32) void {
        const conn = self.conns.get(conn_id) orelse return;
        if (!self.textInputActive(conn)) return;
        self.sendEvent(conn_id, conn.text_input_id, "zwp_text_input_v3", "preedit_string", &.{
            .{ .string = clampUtf8(text) }, .{ .int = cursor_begin }, .{ .int = cursor_end },
        });
        self.sendEvent(conn_id, conn.text_input_id, "zwp_text_input_v3", "done", &.{.{ .uint = conn.ti_serial }});
    }

    /// Browser composition end (or a committed character) → commit_string +
    /// done. With no preceding preedit_string this done also clears any
    /// standing preedit (done sequence step 1), so composition ends cleanly.
    pub fn textInputCommitString(self: *Compositor, conn_id: u32, text: []const u8) void {
        const conn = self.conns.get(conn_id) orelse return;
        if (!self.textInputActive(conn)) return;
        self.sendEvent(conn_id, conn.text_input_id, "zwp_text_input_v3", "commit_string", &.{.{ .string = clampUtf8(text) }});
        self.sendEvent(conn_id, conn.text_input_id, "zwp_text_input_v3", "done", &.{.{ .uint = conn.ti_serial }});
    }

    fn textInputActive(self: *Compositor, conn: *Conn) bool {
        _ = self;
        return conn.text_input_id != 0 and conn.ti_focus_surface != 0 and conn.ti_enabled;
    }

    /// Composition strings are tiny, but sendEvent encodes into a fixed 1024B
    /// buffer with no bounds check — clamp to a safe UTF-8 boundary so a
    /// pathological source can't overrun it.
    fn clampUtf8(text: []const u8) []const u8 {
        const max = 800;
        if (text.len <= max) return text;
        var n: usize = max;
        while (n > 0 and (text[n] & 0xc0) == 0x80) n -= 1; // back up off a continuation byte
        return text[0..n];
    }

    pub fn keyboardKey(self: *Compositor, conn_id: u32, time_ms: u32, evdev_key: u32, pressed: bool) void {
        const conn = self.conns.get(conn_id) orelse return;
        const serial = nextSerial(conn);
        noteInputSerial(conn, serial);
        self.last_input_conn = conn_id;
        // one serial for every wl_keyboard
        self.seatEvent(conn_id, &conn.keyboards, "wl_keyboard", "key", &.{
            .{ .uint = serial },    .{ .uint = time_ms },
            .{ .uint = evdev_key }, .{ .uint = if (pressed) 1 else 0 },
        }, 1);
        // modifier bookkeeping (with no wl_keyboard too: the lock keys are
        // the seat's, and a keyboard made later is told the state)
        const mod: u32 = switch (evdev_key) {
            key_leftshift, key_rightshift => mod_shift,
            key_leftctrl, key_rightctrl => mod_ctrl,
            key_leftalt, key_rightalt => mod_alt,
            key_leftmeta, key_rightmeta => mod_super,
            else => 0,
        };
        var changed = false;
        if (mod != 0) {
            const before = conn.mods_depressed;
            if (pressed) conn.mods_depressed |= mod else conn.mods_depressed &= ~mod;
            changed = conn.mods_depressed != before;
        } else if ((evdev_key == key_capslock or evdev_key == key_numlock) and pressed) {
            self.mods_locked ^= if (evdev_key == key_capslock) mod_lock else mod_num;
            changed = true;
        }
        if (changed) self.sendModifiers(conn_id, conn);
    }

    /// The browser's lock state (getModifierState): Caps Lock and NumLock
    /// are set to it, and every client holding keyboard focus is told when
    /// that changed something. Unchanged: nothing is sent.
    pub fn keyboardLocks(self: *Compositor, caps_lock: bool, num_lock: bool) void {
        const locked = (if (caps_lock) mod_lock else 0) | (if (num_lock) mod_num else 0);
        if (locked == self.mods_locked) return;
        self.mods_locked = locked;
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn = kv.value_ptr.*;
            if (conn.keyboard_focus != 0) self.sendModifiers(kv.key_ptr.*, conn);
        }
    }

    /// The seat's lock state now — keyboardLocks' last word or the lock
    /// keys' toggles since — for an embedder that carries it over to the
    /// next link's compositor.
    pub fn lockState(self: *const Compositor) struct { caps_lock: bool, num_lock: bool } {
        return .{ .caps_lock = self.mods_locked & mod_lock != 0, .num_lock = self.mods_locked & mod_num != 0 };
    }

    // ------------------------------------------------------------------
    // a compositor that outlives its embedders (the relay's session host,
    // server/src/session.zig): an embedder that attaches later is told the
    // scene as it is now, one that goes lets go of what it held
    // ------------------------------------------------------------------

    /// The open conns' ids, ascending (owned by the caller).
    pub fn connIds(self: *Compositor, gpa: std.mem.Allocator) ![]u32 {
        const ids = try gpa.alloc(u32, self.conns.count());
        var it = self.conns.keyIterator();
        var i: usize = 0;
        while (it.next()) |id| : (i += 1) ids[i] = id.*;
        std.mem.sort(u32, ids, {}, std.sort.asc(u32));
        return ids;
    }

    /// A conn's surface ids (owned by the caller), parents before what
    /// hangs from them (by depth in the parent chain, then id); empty for
    /// an unknown conn.
    pub fn surfaceIds(self: *Compositor, gpa: std.mem.Allocator, conn_id: u32) ![]u32 {
        const conn = self.conns.get(conn_id) orelse return gpa.alloc(u32, 0);
        const Entry = struct { depth: u8, id: u32 };
        const list = try gpa.alloc(Entry, conn.surfaces.count());
        defer gpa.free(list);
        var it = conn.surfaces.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            var depth: u8 = 0;
            var parent = kv.value_ptr.parent_id;
            // bounded like surfaceRoot: a client's cycle can't hang it
            while (parent != 0 and depth < 8) : (depth += 1) {
                parent = (conn.surfaces.get(parent) orelse break).parent_id;
            }
            list[i] = .{ .depth = depth, .id = kv.key_ptr.* };
        }
        std.mem.sort(Entry, list, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.depth < b.depth or (a.depth == b.depth and a.id < b.id);
            }
        }.lessThan);
        const ids = try gpa.alloc(u32, list.len);
        for (list, ids) |e, *id| id.* = e.id;
        return ids;
    }

    /// The surface has content (its last attach-latching commit named a
    /// buffer): an embedder attaching now should be shown its pixels.
    pub fn surfaceHasContent(self: *Compositor, conn_id: u32, surface_id: u32) bool {
        const conn = self.conns.get(conn_id) orelse return false;
        const surface = conn.surfaces.get(surface_id) orelse return false;
        return surface.on_output;
    }

    /// Tell an embedder that attaches to a running compositor what describes
    /// each surface now, through the same callbacks the changes went
    /// through: per conn (ascending), per surface (parents first) the
    /// surface_fn value it was last told (unless none), its title and app
    /// id, its input region (unless infinite, the default), its size hints
    /// (unless none), its decoration (when decorated) and its set window
    /// states (interactive kinds 2, 6, 8).
    /// Pixels are the embedder's.
    pub fn replaySurfaces(self: *Compositor) void {
        const ids = self.connIds(self.gpa) catch return;
        defer self.gpa.free(ids);
        for (ids) |conn_id| {
            const surfaces = self.surfaceIds(self.gpa, conn_id) catch continue;
            defer self.gpa.free(surfaces);
            for (surfaces) |surface_id| {
                // re-fetched for every surface: the callbacks may read the
                // compositor (never change it)
                const conn = self.conns.get(conn_id) orelse break;
                const s = conn.surfaces.get(surface_id) orelse continue;
                if (s.notified != 0) {
                    if (self.surface_fn) |f| f(self.ctx, conn_id, surface_id, s.notified);
                }
                if (conn.titles.get(surface_id)) |t| {
                    if (self.title_fn) |f| f(self.ctx, conn_id, surface_id, t);
                }
                if (conn.app_ids.get(surface_id)) |a| {
                    if (self.app_id_fn) |f| f(self.ctx, conn_id, surface_id, a);
                }
                if (s.input) |*r| {
                    if (self.input_region_fn) |f| f(self.ctx, conn_id, surface_id, r);
                }
                if (s.role == .toplevel) {
                    if (s.min_w != 0 or s.min_h != 0 or s.max_w != 0 or s.max_h != 0) {
                        if (self.size_limits_fn) |f| f(self.ctx, conn_id, surface_id, s.min_w, s.min_h, s.max_w, s.max_h);
                    }
                    if (s.decorated) {
                        if (self.decoration_fn) |f| f(self.ctx, conn_id, surface_id, true);
                    }
                    if (s.acked) |cfg| {
                        if (self.acked_fn) |f| f(self.ctx, conn_id, surface_id, cfg.serial, cfg.w, cfg.h);
                    }
                    if (self.interactive_fn) |f| {
                        if (s.maximized) f(self.ctx, conn_id, surface_id, 2, 0);
                        if (s.fullscreen) f(self.ctx, conn_id, surface_id, 6, 0);
                        if (s.minimized) f(self.ctx, conn_id, surface_id, 8, 0);
                    }
                }
            }
        }
    }

    /// The seat half of an attaching embedder's replay: per conn
    /// (ascending) the pointer image while it holds the pointer, its text
    /// input while entered, the pointer lock it wants, whether it has a
    /// wl_touch (touch_bound_fn, only when it has); then the clipboard
    /// selection (selection_fn, always once).
    pub fn replaySeat(self: *Compositor) void {
        const ids = self.connIds(self.gpa) catch return;
        defer self.gpa.free(ids);
        for (ids) |conn_id| {
            const conn = self.conns.get(conn_id) orelse continue;
            if (conn.pointer_focus != 0) {
                if (conn.cursor_surface != 0) {
                    self.emitCursorSurface(conn_id, conn);
                } else if (conn.cursor_shape != 0) {
                    if (self.cursor_shape_fn) |f| f(self.ctx, conn_id, conn.cursor_shape);
                }
            }
            if (conn.text_input_id != 0 and conn.ti_focus_surface != 0) self.textInputNotify(conn_id, conn);
            if (conn.lock_surface != 0) {
                if (self.pointer_lock_fn) |f| f(self.ctx, conn_id, conn.lock_surface);
            }
            if (conn.touches.len > 0) {
                if (self.touch_bound_fn) |f| f(self.ctx, conn_id, true);
            }
        }
        self.notifySelection();
    }

    /// selection_fn with the clipboard selection as it is now (an embedder
    /// whose request changed nothing is told the outcome all the same).
    pub fn tellSelection(self: *Compositor) void {
        self.notifySelection();
    }

    /// The embedder went (a viewer closed): what only it held up ends —
    /// a drag is cancelled, every pointer lock is lost, the pointer and
    /// keyboard leave every client (held buttons and modifiers released:
    /// the next enter starts clean), touch points are cancelled, and the
    /// apps are told they are suspended until an embedder says otherwise. Clients stay connected.
    pub fn embedderGone(self: *Compositor) void {
        self.dragCancel();
        if (self.connIds(self.gpa)) |ids| {
            defer self.gpa.free(ids);
            for (ids) |conn_id| {
                self.pointerLockLost(conn_id);
                self.pointerLeave(conn_id);
                self.keyboardLeave(conn_id);
                self.touchCancel(conn_id);
                if (self.conns.get(conn_id)) |conn| {
                    conn.buttons_held = 0;
                    conn.mods_depressed = 0;
                }
            }
        } else |_| {}
        self.setSuspended(true);
    }

    /// wl_keyboard.modifiers to every wl_keyboard, one serial.
    fn sendModifiers(self: *Compositor, conn_id: u32, conn: *Conn) void {
        if (conn.keyboards.len == 0) return; // no serial spent on nobody
        self.seatEvent(conn_id, &conn.keyboards, "wl_keyboard", "modifiers", &self.modifierArgs(conn), 1);
    }

    /// wl_keyboard.modifiers to one wl_keyboard (a late one's).
    fn sendModifiersTo(self: *Compositor, conn_id: u32, conn: *Conn, keyboard_id: u32) void {
        self.sendEvent(conn_id, keyboard_id, "wl_keyboard", "modifiers", &self.modifierArgs(conn));
    }

    /// A fresh serial and the conn's modifier state, as modifiers' args.
    fn modifierArgs(self: *Compositor, conn: *Conn) [5]wire.Value {
        return .{
            .{ .uint = nextSerial(conn) },
            .{ .uint = conn.mods_depressed },
            .{ .uint = 0 },
            .{ .uint = self.mods_locked },
            .{ .uint = 0 },
        };
    }

    fn deleteId(self: *Compositor, conn_id: u32, id: u32) void {
        // only client-allocated ids participate in delete_id bookkeeping
        if (id >= objects.server_id_base) return;
        self.sendEvent(conn_id, 1, "wl_display", "delete_id", &.{.{ .uint = id }});
    }

    fn sendEvent(
        self: *Compositor,
        conn_id: u32,
        object_id: u32,
        comptime iface_name: []const u8,
        comptime event_name: []const u8,
        args: []const wire.Value,
    ) void {
        const iface = comptime protocol.find(iface_name).?;
        const opcode = comptime iface.eventIndex(event_name).?;
        var buf: [1024]u8 = undefined;
        // client-sized strings are capped where they enter (max_mime_len,
        // clampUtf8); this refusal is the backstop, never a write past buf
        const msg = wire.encode(&buf, object_id, opcode, args) catch {
            self.logf("c{d}: {s}.{s} over {d} B, not sent", .{ conn_id, iface_name, event_name, buf.len });
            return;
        };
        self.send_fn(self.ctx, conn_id, msg);
    }

    fn logf(self: *Compositor, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
        self.log_fn(self.ctx, text);
    }
};

/// Human-readable one-line dump of a decoded message.
pub fn formatMessage(
    buf: []u8,
    conn_id: u32,
    iface: *const protocol.Interface,
    id: u32,
    msg: *const protocol.Message,
    args: []const wire.Value,
) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("c{d}→ {s}@{d}.{s}(", .{ conn_id, iface.name, id, msg.name }) catch {};
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeAll(", ") catch {};
        switch (arg) {
            .int => |v| w.print("{d}", .{v}) catch {},
            .uint => |v| w.print("{d}u", .{v}) catch {},
            .fixed => |v| w.print("{d}.{d:0>2}f", .{ @divTrunc(v, 256), @abs(@rem(v, 256)) * 100 / 256 }) catch {},
            .string => |s| w.print("\"{s}\"", .{s orelse "<null>"}) catch {},
            .object => |v| w.print("obj@{d}", .{v}) catch {},
            .new_id => |v| w.print("new {s}@{d}", .{ msg.new_id_interface orelse "?", v }) catch {},
            .new_id_dynamic => |v| w.print("new {s}(v{d})@{d}", .{ v.interface, v.version, v.id }) catch {},
            .array => |a| w.print("array[{d}]", .{a.len}) catch {},
            .fd => w.writeAll("fd") catch {},
        }
    }
    w.writeAll(")") catch {};
    return w.buffered();
}

// ---------------------------------------------------------------------------
// tests: drive the compositor like wayland-info would, capture output wire
// ---------------------------------------------------------------------------

const TestSink = struct {
    events: std.ArrayList(struct { conn_id: u32, object_id: u32, opcode: u16, bytes: [128]u8, len: usize }),
    gpa: std.mem.Allocator,
    // last fdmsg emission (keymap / pipe)
    fdmsg_conn: u32 = 0,
    fdmsg_kind: u32 = 0,
    fdmsg_token: u32 = 0,
    fdmsg_bytes: [128]u8 = undefined,
    fdmsg_len: usize = 0,
    // log lines
    logs: u32 = 0,
    // surface_fn: last emission + call count
    surf_id: u32 = 0,
    surf_value: u32 = 0xfffffffe,
    surf_calls: u32 = 0,
    // last interactive_fn emission
    inter_surface: u32 = 0,
    inter_kind: u32 = 0xffffffff,
    inter_value: u32 = 0,
    inter_calls: u32 = 0,
    // cursor_shape_fn: last shape + call count
    shape_conn: u32 = 0,
    shape_value: u32 = 0xffffffff,
    shape_calls: u32 = 0,
    // cursor_surface_fn: last image + call count
    cursor_surface: u32 = 0xffffffff,
    cursor_hx: i32 = 0,
    cursor_hy: i32 = 0,
    cursor_calls: u32 = 0,
    // text_input_fn: last state + call count
    ti_conn: u32 = 0,
    ti_active: u32 = 0xffffffff,
    ti_x: i32 = 0,
    ti_y: i32 = 0,
    ti_calls: u32 = 0,
    // srvobj_fn: last registration + a small set of registered primary offers
    srvobj_conn: u32 = 0,
    srvobj_id: u32 = 0,
    srvobj_kind: u32 = 0,
    srvobj_calls: u32 = 0,
    primary_ids: [8]u32 = @splat(0),
    primary_ids_len: usize = 0,
    // last fdmsg aux length (keymap / format table bytes)
    fdmsg_aux_len: usize = 0,
    // dmabuf_created_fn: last call + count
    dmabuf_params: u32 = 0,
    dmabuf_buffer: u32 = 0,
    dmabuf_created_calls: u32 = 0,
    // input_region_fn: last call (a copy; null = infinite) + count
    region_surface: u32 = 0,
    region: ?Region = null,
    region_calls: u32 = 0,
    // pointer_lock_fn: last call + count
    lock_conn: u32 = 0,
    lock_surface: u32 = 0xffffffff,
    lock_calls: u32 = 0,
    // presented_fn: the last age + count (the event itself goes to `events`)
    presented_age: u32 = 0,
    presented_calls: u32 = 0,
    // last fdmsg aux bytes (first 128) — pipe writes carry token ++ data
    fdmsg_aux: [128]u8 = undefined,
    fdmsg_calls: u32 = 0,
    // selection_fn: last owner, its mimes joined with ',', + count
    sel_conn: u32 = 0xffffffff,
    sel_mimes: [128]u8 = undefined,
    sel_mimes_len: usize = 0,
    sel_calls: u32 = 0,
    // size_limits_fn: last hints + count
    limits_surface: u32 = 0,
    limits: [4]i32 = @splat(-1),
    limits_calls: u32 = 0,
    // app_id_fn: last id + count
    app_id: [64]u8 = undefined,
    app_id_len: usize = 0,
    app_id_calls: u32 = 0,
    // decoration_fn: last call + count
    deco_surface: u32 = 0,
    decorated: ?bool = null,
    deco_calls: u32 = 0,
    // configure_fn: last configure, its cause + count
    cfg: ?Configure = null,
    cfg_cause: u32 = 0,
    cfg_calls: u32 = 0,
    // acked_fn: last {serial, w, h} + count
    acked: ?[3]u32 = null,
    acked_calls: u32 = 0,
    // touch_bound_fn: last call + count
    touch_conn: u32 = 0,
    touch_bound: ?bool = null,
    touch_bound_calls: u32 = 0,
    // drag_action_fn: last action + count
    drag_action: u32 = 0xffffffff,
    drag_action_calls: u32 = 0,

    fn dragAction(ctx: ?*anyopaque, action: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.drag_action = action;
        self.drag_action_calls += 1;
    }

    fn touchBound(ctx: ?*anyopaque, conn_id: u32, bound: bool) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.touch_conn = conn_id;
        self.touch_bound = bound;
        self.touch_bound_calls += 1;
    }

    fn configure(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, cfg: Configure, cause: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        _ = surface_id;
        self.cfg = cfg;
        self.cfg_cause = cause;
        self.cfg_calls += 1;
    }

    fn ackedCb(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, serial: u32, w: i32, h: i32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        _ = surface_id;
        self.acked = .{ serial, @bitCast(w), @bitCast(h) };
        self.acked_calls += 1;
    }

    fn decoration(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, decorated: bool) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        self.deco_surface = surface_id;
        self.decorated = decorated;
        self.deco_calls += 1;
    }

    fn sizeLimits(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, min_w: i32, min_h: i32, max_w: i32, max_h: i32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        self.limits_surface = surface_id;
        self.limits = .{ min_w, min_h, max_w, max_h };
        self.limits_calls += 1;
    }

    fn appId(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, app_id: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        _ = surface_id;
        self.app_id_len = @min(app_id.len, self.app_id.len);
        @memcpy(self.app_id[0..self.app_id_len], app_id[0..self.app_id_len]);
        self.app_id_calls += 1;
    }

    fn selection(ctx: ?*anyopaque, conn_id: u32, mimes: []const []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.sel_conn = conn_id;
        self.sel_calls += 1;
        self.sel_mimes_len = 0;
        for (mimes, 0..) |m, i| {
            if (i > 0) {
                self.sel_mimes[self.sel_mimes_len] = ',';
                self.sel_mimes_len += 1;
            }
            @memcpy(self.sel_mimes[self.sel_mimes_len..][0..m.len], m);
            self.sel_mimes_len += m.len;
        }
    }

    fn presented(ctx: ?*anyopaque, conn_id: u32, age_us: u32, msg: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.presented_age = age_us;
        self.presented_calls += 1;
        send(ctx, conn_id, msg);
    }

    fn pointerLock(ctx: ?*anyopaque, conn_id: u32, surface_id: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.lock_conn = conn_id;
        self.lock_surface = surface_id;
        self.lock_calls += 1;
    }

    fn inputRegion(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, region: ?*const Region) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        self.region_surface = surface_id;
        self.region = if (region) |r| r.* else null;
        self.region_calls += 1;
    }

    fn dmabufCreated(ctx: ?*anyopaque, conn_id: u32, params_id: u32, buffer_id: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        self.dmabuf_params = params_id;
        self.dmabuf_buffer = buffer_id;
        self.dmabuf_created_calls += 1;
    }

    fn srvobj(ctx: ?*anyopaque, conn_id: u32, object_id: u32, kind: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.srvobj_conn = conn_id;
        self.srvobj_id = object_id;
        self.srvobj_kind = kind;
        self.srvobj_calls += 1;
        if (kind == srvobj_kind_primary_offer and self.primary_ids_len < self.primary_ids.len) {
            self.primary_ids[self.primary_ids_len] = object_id;
            self.primary_ids_len += 1;
        }
    }

    fn isPrimary(self: *const TestSink, id: u32) bool {
        for (self.primary_ids[0..self.primary_ids_len]) |p| if (p == id) return true;
        return false;
    }

    fn fdmsg(ctx: ?*anyopaque, conn_id: u32, kind: u32, wire_bytes: []const u8, aux: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.fdmsg_conn = conn_id;
        self.fdmsg_kind = kind;
        self.fdmsg_token = if (aux.len == 4) std.mem.readInt(u32, aux[0..4], .little) else 0;
        self.fdmsg_aux_len = aux.len;
        self.fdmsg_calls += 1;
        const n = @min(aux.len, self.fdmsg_aux.len);
        @memcpy(self.fdmsg_aux[0..n], aux[0..n]);
        const wn = @min(wire_bytes.len, self.fdmsg_bytes.len); // len stays real
        @memcpy(self.fdmsg_bytes[0..wn], wire_bytes[0..wn]);
        self.fdmsg_len = wire_bytes.len;
    }

    fn send(ctx: ?*anyopaque, conn_id: u32, bytes: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        const header = wire.Header.parse(bytes) catch unreachable;
        var entry: @TypeOf(self.events.items[0]) = .{
            .conn_id = conn_id,
            .object_id = header.object_id,
            .opcode = header.opcode,
            .bytes = undefined,
            .len = bytes.len,
        };
        // the first 128 bytes (a long mime's offer is longer; len is real)
        const n = @min(bytes.len, entry.bytes.len);
        @memcpy(entry.bytes[0..n], bytes[0..n]);
        self.events.append(self.gpa, entry) catch unreachable;
    }

    fn log(ctx: ?*anyopaque, text: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = text;
        self.logs += 1;
    }

    fn surfaceEvent(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, value: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        self.surf_id = surface_id;
        self.surf_value = value;
        self.surf_calls += 1;
    }

    fn interactive(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, kind: u32, value: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        self.inter_surface = surface_id;
        self.inter_kind = kind;
        self.inter_value = value;
        self.inter_calls += 1;
    }

    fn cursorShape(ctx: ?*anyopaque, conn_id: u32, shape: u32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.shape_conn = conn_id;
        self.shape_value = shape;
        self.shape_calls += 1;
    }

    fn cursorSurface(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, hx: i32, hy: i32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = conn_id;
        self.cursor_surface = surface_id;
        self.cursor_hx = hx;
        self.cursor_hy = hy;
        self.cursor_calls += 1;
    }

    fn textInput(ctx: ?*anyopaque, conn_id: u32, active: u32, x: i32, y: i32, w: i32, h: i32) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        _ = w;
        _ = h;
        self.ti_conn = conn_id;
        self.ti_active = active;
        self.ti_x = x;
        self.ti_y = y;
        self.ti_calls += 1;
    }
};

fn testSetup(sink: *TestSink) Compositor {
    sink.* = .{ .events = .empty, .gpa = std.testing.allocator };
    var comp = Compositor.init(std.testing.allocator, sink, TestSink.send, TestSink.log);
    comp.srvobj_fn = TestSink.srvobj;
    return comp;
}

/// Tests: `conn_id` just had input of its own (a key press, say) — the
/// serial a selection request of a client without keyboard focus names.
fn testInputSerial(comp: *Compositor, conn_id: u32) u32 {
    const conn = comp.conns.get(conn_id).?;
    const serial = Compositor.nextSerial(conn);
    Compositor.noteInputSerial(conn, serial);
    comp.last_input_conn = conn_id;
    return serial;
}

test "get_registry yields all globals, sync yields done+delete_id" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [64]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try std.testing.expectEqual(globals.len, sink.events.items.len);
    // first global event: registry object, opcode 0, name=1 "wl_compositor"
    const first = sink.events.items[0];
    try std.testing.expectEqual(@as(u32, 2), first.object_id);
    var vals: [wire.max_args]wire.Value = undefined;
    const args = try wire.decodeArgs(first.bytes[wire.header_size..first.len], &.{ .uint, .string, .uint }, &vals);
    try std.testing.expectEqualStrings("wl_compositor", args[1].string.?);

    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 0, &.{.{ .new_id = 3 }})); // sync
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 3), sink.events.items[0].object_id); // callback.done
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[1].object_id); // display.delete_id
    try std.testing.expectEqual(@as(u16, 1), sink.events.items[1].opcode);
}

test "binding wl_shm yields format events; destructor yields delete_id" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    sink.events.clearRetainingCapacity();

    // bind name=3 (wl_shm) as id 4
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{
        .{ .uint = 3 },
        .{ .new_id_dynamic = .{ .interface = "wl_shm", .version = 1, .id = 4 } },
    }));
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // two formats
    try std.testing.expectEqual(@as(u32, 4), sink.events.items[0].object_id);

    // bind xdg_wm_base (name=6) as id 5, then destroy it → delete_id(5)
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{
        .{ .uint = 6 },
        .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 5 } },
    }));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{})); // xdg_wm_base.destroy
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[0].object_id);
    try std.testing.expectEqual(@as(u16, 1), sink.events.items[0].opcode); // delete_id
}

test "wl_shm v2 release: destructor answers delete_id; a re-bind still works" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 3 }, .{ .new_id_dynamic = .{ .interface = "wl_shm", .version = 2, .id = 4 } } }));
    sink.events.clearRetainingCapacity();

    const release_op = comptime protocol.find("wl_shm").?.requestIndex("release").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 4, release_op, &.{})); // wl_shm.release
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[0].object_id); // wl_display
    try std.testing.expectEqual(@as(u16, 1), sink.events.items[0].opcode); // delete_id
    var vals: [wire.max_args]wire.Value = undefined;
    const ev = sink.events.items[0];
    const args = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.uint}, &vals);
    try std.testing.expectEqual(@as(u32, 4), args[0].uint); // the released id

    // re-binding wl_shm on the freed id still emits its formats (no stale state)
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 3 }, .{ .new_id_dynamic = .{ .interface = "wl_shm", .version = 2, .id = 4 } } }));
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
}

test "frame callbacks latch at commit and fire at the next tick; surface destroy drops them" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const s = comptime protocol.find("wl_surface").?;
    const frame_op = comptime s.requestIndex("frame").?;
    const commit_op = comptime s.requestIndex("commit").?;
    const destroy_op = comptime s.requestIndex("destroy").?;
    const done_op = comptime protocol.find("wl_callback").?.eventIndex("done").?;
    const delete_op = comptime protocol.find("wl_display").?.eventIndex("delete_id").?;
    const Count = struct {
        fn of(sk: *const TestSink, object_id: u32, opcode: u16) usize {
            var n: usize = 0;
            for (sk.events.items) |e| {
                if (e.object_id == object_id and e.opcode == opcode) n += 1;
            }
            return n;
        }
        /// delete_id events naming `id`
        fn deleted(sk: *const TestSink, id: u32) usize {
            var n: usize = 0;
            for (sk.events.items) |e| {
                if (e.object_id != 1 or e.opcode != delete_op) continue;
                if (std.mem.readInt(u32, e.bytes[wire.header_size..][0..4], .little) == id) n += 1;
            }
            return n;
        }
    };

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 6 }})); // surface 6
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 11 }})); // surface 11
    sink.events.clearRetainingCapacity();

    // frame without a commit: pending, a tick fires nothing
    try comp.onWire(1, wire.encodeMessage(&buf, 6, frame_op, &.{.{ .new_id = 7 }}));
    comp.tick(.{ .time_ms = 10 });
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // the commit latches it; the NEXT tick fires done(time) + delete_id, once
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(usize, 0), Count.of(&sink, 7, done_op));
    comp.tick(.{ .time_ms = 20 });
    try std.testing.expectEqual(@as(usize, 1), Count.of(&sink, 7, done_op));
    try std.testing.expectEqual(@as(usize, 1), Count.deleted(&sink, 7));
    for (sink.events.items) |e| {
        if (e.object_id == 7) try std.testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, e.bytes[wire.header_size..][0..4], .little));
    }
    comp.tick(.{ .time_ms = 30 });
    try std.testing.expectEqual(@as(usize, 1), Count.of(&sink, 7, done_op));

    // commit BEFORE the request: that commit does not latch it
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, frame_op, &.{.{ .new_id = 8 }}));
    comp.tick(.{ .time_ms = 40 });
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // per surface: committing 6 latches 8 and 9, not 11's callback 10
    try comp.onWire(1, wire.encodeMessage(&buf, 6, frame_op, &.{.{ .new_id = 9 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 11, frame_op, &.{.{ .new_id = 10 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    comp.tick(.{ .time_ms = 50 });
    try std.testing.expectEqual(@as(usize, 1), Count.of(&sink, 8, done_op));
    try std.testing.expectEqual(@as(usize, 1), Count.of(&sink, 9, done_op));
    try std.testing.expectEqual(@as(usize, 0), Count.of(&sink, 10, done_op));

    // destroying surface 11 drops its callback: delete_id, never done
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 11, destroy_op, &.{}));
    try std.testing.expectEqual(@as(usize, 1), Count.deleted(&sink, 10));
    comp.tick(.{ .time_ms = 60 });
    try std.testing.expectEqual(@as(usize, 0), Count.of(&sink, 10, done_op));

    // a committed-but-unfired callback dies with its surface too
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, frame_op, &.{.{ .new_id = 12 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, destroy_op, &.{}));
    comp.tick(.{ .time_ms = 70 });
    try std.testing.expectEqual(@as(usize, 0), Count.of(&sink, 12, done_op));
    try std.testing.expectEqual(@as(usize, 1), Count.deleted(&sink, 12));
}

test "presentation feedback: clock_id on bind, latched by commit, presented at the next tick or discarded" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.presented_fn = TestSink.presented;

    const surf = comptime protocol.find("wl_surface").?;
    const attach_op = comptime surf.requestIndex("attach").?;
    const commit_op = comptime surf.requestIndex("commit").?;
    const destroy_op = comptime surf.requestIndex("destroy").?;
    const pres = comptime protocol.find("wp_presentation").?;
    const feedback_op = comptime pres.requestIndex("feedback").?;
    const clock_op = comptime pres.eventIndex("clock_id").?;
    const fb_iface = comptime protocol.find("wp_presentation_feedback").?;
    const sync_op = comptime fb_iface.eventIndex("sync_output").?;
    const presented_op = comptime fb_iface.eventIndex("presented").?;
    const discarded_op = comptime fb_iface.eventIndex("discarded").?;
    const delete_op = comptime protocol.find("wl_display").?.eventIndex("delete_id").?;
    const H = struct {
        /// what feedback `id` got, in order: 's' sync_output, 'p' presented,
        /// 'x' discarded, 'd' its delete_id
        fn story(sk: *const TestSink, id: u32, out: []u8) []const u8 {
            var n: usize = 0;
            for (sk.events.items) |e| {
                const c: u8 = if (e.object_id == id) switch (e.opcode) {
                    sync_op => 's',
                    presented_op => 'p',
                    discarded_op => 'x',
                    else => '?',
                } else if (e.object_id == 1 and e.opcode == delete_op and std.mem.readInt(u32, e.bytes[wire.header_size..][0..4], .little) == id) 'd' else continue;
                out[n] = c;
                n += 1;
            }
            return out[0..n];
        }
        fn expect(sk: *const TestSink, id: u32, want: []const u8) !void {
            var out: [16]u8 = undefined;
            try std.testing.expectEqualStrings(want, story(sk, id, &out));
        }
        fn feedback(c: *Compositor, surface: u32, id: u32) !void {
            var b: [64]u8 = undefined;
            try c.onWire(1, wire.encodeMessage(&b, 12, feedback_op, &.{ .{ .object = surface }, .{ .new_id = id } }));
        }
        fn commit(c: *Compositor, surface: u32, buffer: ?u32) !void {
            var b: [64]u8 = undefined;
            if (buffer) |id| try c.onWire(1, wire.encodeMessage(&b, surface, attach_op, &.{ .{ .object = id }, .{ .int = 0 }, .{ .int = 0 } }));
            try c.onWire(1, wire.encodeMessage(&b, surface, commit_op, &.{}));
        }
    };

    // toplevel 6 (xdg_surface 7, xdg_toplevel 8), two wl_output binds,
    // wp_presentation 12, a subcompositor 13
    try wmBaseToplevel(&comp, 1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 4, .id = 9 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 4, .id = 10 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 13 } } }));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 17 }, .{ .new_id_dynamic = .{ .interface = "wp_presentation", .version = 3, .id = 12 } } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 12), sink.events.items[0].object_id);
    try std.testing.expectEqual(clock_op, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, sink.events.items[0].bytes[8..12], .little)); // CLOCK_MONOTONIC

    // pending until a commit: a tick ends nothing
    try H.feedback(&comp, 6, 20);
    comp.tick(.{ .time_ms = 1000 });
    try H.expect(&sink, 20, "");
    // the commit latches it (and maps the toplevel); the next tick: one
    // sync_output per bound wl_output, presented, delete_id
    try H.commit(&comp, 6, 30);
    try H.expect(&sink, 20, "");
    sink.events.clearRetainingCapacity();
    comp.tick(.{ .time_ms = 1234, .age_us = 2500, .refresh_ns = 16_666_667, .vsync = true });
    try H.expect(&sink, 20, "sspd");
    try std.testing.expectEqual(@as(u32, 1), sink.presented_calls); // through presented_fn
    try std.testing.expectEqual(@as(u32, 2500), sink.presented_age);
    var vals: [wire.max_args]wire.Value = undefined;
    for (sink.events.items) |e| {
        if (e.object_id != 20) continue;
        if (e.opcode == sync_op) {
            const a = try wire.decodeArgs(e.bytes[wire.header_size..e.len], &.{.object}, &vals);
            try std.testing.expect(a[0].object == 9 or a[0].object == 10);
        } else {
            const a = try wire.decodeArgs(e.bytes[wire.header_size..e.len], &.{ .uint, .uint, .uint, .uint, .uint, .uint, .uint }, &vals);
            // the page's time as the placeholder (the relay stamps its
            // own), the refresh, no vblank counter, vsync and nothing else
            try std.testing.expectEqual(@as(u32, 0), a[0].uint);
            try std.testing.expectEqual(@as(u32, 1), a[1].uint);
            try std.testing.expectEqual(@as(u32, 234_000_000), a[2].uint);
            try std.testing.expectEqual(@as(u32, 16_666_667), a[3].uint);
            try std.testing.expectEqual(@as(u32, 0), a[4].uint);
            try std.testing.expectEqual(@as(u32, 0), a[5].uint);
            try std.testing.expectEqual(@as(u32, 1), a[6].uint);
        }
    }
    comp.tick(.{ .time_ms = 1250 });
    try H.expect(&sink, 20, "sspd"); // once

    // superseded: a second commit before the tick discards the first's
    // feedback at once; several feedbacks for one commit all present
    sink.events.clearRetainingCapacity();
    try H.feedback(&comp, 6, 21);
    try H.commit(&comp, 6, null);
    try H.feedback(&comp, 6, 22);
    try H.feedback(&comp, 6, 23);
    try H.commit(&comp, 6, 31);
    try H.expect(&sink, 21, "xd");
    comp.tick(.{ .time_ms = 1300 });
    try H.expect(&sink, 22, "sspd");
    try H.expect(&sink, 23, "sspd");
    try std.testing.expectEqual(@as(u32, 0), sink.presented_age); // a tick without one

    // a subsurface shows while its parent does; a surface with no role never
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 40 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 41 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 13, 1, &.{ .{ .new_id = 42 }, .{ .object = 40 }, .{ .object = 6 } })); // get_subsurface
    sink.events.clearRetainingCapacity();
    try H.feedback(&comp, 40, 24);
    try H.feedback(&comp, 41, 25);
    try H.commit(&comp, 40, 32);
    try H.commit(&comp, 41, 33);
    comp.tick(.{ .time_ms = 1400 });
    try H.expect(&sink, 24, "sspd");
    try H.expect(&sink, 25, "xd");

    // unmapped (the role object gone) or attach(NULL): discarded, also
    // the subsurface of the unmapped parent
    sink.events.clearRetainingCapacity();
    try H.feedback(&comp, 6, 26);
    try H.feedback(&comp, 40, 27);
    try H.commit(&comp, 40, null);
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 0, &.{})); // xdg_toplevel.destroy
    try H.commit(&comp, 6, null);
    comp.tick(.{ .time_ms = 1500 });
    try H.expect(&sink, 26, "xd");
    try H.expect(&sink, 27, "xd");
    try H.feedback(&comp, 40, 28);
    try H.commit(&comp, 40, 0);
    comp.tick(.{ .time_ms = 1600 });
    try H.expect(&sink, 28, "xd");

    // a destroyed surface takes its feedbacks with it, latched or not;
    // feedback for a surface already gone ends at once
    sink.events.clearRetainingCapacity();
    try H.feedback(&comp, 41, 29);
    try H.commit(&comp, 41, null);
    try H.feedback(&comp, 41, 34);
    try comp.onWire(1, wire.encodeMessage(&buf, 41, destroy_op, &.{}));
    try H.expect(&sink, 29, "xd");
    try H.expect(&sink, 34, "xd");
    try H.feedback(&comp, 41, 35);
    try H.expect(&sink, 35, "xd");
    comp.tick(.{ .time_ms = 1700 });
    try H.expect(&sink, 29, "xd");
    try std.testing.expectEqual(@as(usize, 0), comp.conns.get(1).?.feedbacks.items.len);
}

test "subsurface position and root/abs tracking" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // registry
    // bind wl_compositor(name 1) as 4 and wl_subcompositor(name 2) as 5
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 5 } } }));
    // parent surface 6, child surface 7, subsurface object 8
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 6 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 7 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 8 }, .{ .object = 7 }, .{ .object = 6 } })); // get_subsurface
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 1, &.{ .{ .int = -5 }, .{ .int = 30 } })); // set_position

    try std.testing.expectEqual(Role.subsurface, comp.surfaceRole(1, 7));
    try std.testing.expectEqual(@as(u32, 6), comp.surfaceRoot(1, 7));
    try std.testing.expectEqual(@as(i32, -5), comp.surfaceAbs(1, 7).x);
    try std.testing.expectEqual(@as(i32, 30), comp.surfaceAbs(1, 7).y);

    // wl_subsurface.destroy unmaps: the surface lives on without a role
    // (Chromium's omnibox dropdown), and can become a subsurface again
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 0, &.{})); // destroy
    try std.testing.expectEqual(Role.none, comp.surfaceRole(1, 7));
    try std.testing.expectEqual(@as(u32, 7), comp.surfaceRoot(1, 7));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 9 }, .{ .object = 7 }, .{ .object = 6 } }));
    try std.testing.expectEqual(Role.subsurface, comp.surfaceRole(1, 7));
    try std.testing.expectEqual(@as(u32, 6), comp.surfaceRoot(1, 7));
}

test "subsurface z-order: new ones on top; place_above / place_below latch at the parent's commit, below the parent too; a stranger is bad_surface" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const sub = comptime protocol.find("wl_subsurface").?;
    const above_op = comptime sub.requestIndex("place_above").?;
    const below_op = comptime sub.requestIndex("place_below").?;
    const commit_op = comptime protocol.find("wl_surface").?.requestIndex("commit").?;
    const T = WinTest;
    try wmBaseToplevel(&comp, 1); // toplevel surface 6 (xdg_wm_base 4)
    try T.send(&comp, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 5 } } });
    // subsurfaces a=10, b=12, c=14 of the toplevel (role objects id+1)
    for ([_]u32{ 10, 12, 14 }) |s| {
        try T.send(&comp, 3, 0, &.{.{ .new_id = s }});
        try T.send(&comp, 5, 1, &.{ .{ .new_id = s + 1 }, .{ .object = s }, .{ .object = 6 } });
    }
    const Z = struct {
        fn of(c: *Compositor, s: u32) i32 {
            return c.surfaceZ(1, s);
        }
        fn expect(c: *Compositor, want: [3]i32) !void {
            try std.testing.expectEqual(want, [3]i32{ of(c, 10), of(c, 12), of(c, 14) });
        }
    };
    try Z.expect(&comp, .{ 1, 2, 3 }); // oldest at the bottom, all above the parent
    try std.testing.expectEqual(@as(u32, 6), comp.surfaceParent(1, 10));
    try std.testing.expectEqual(@as(i32, 0), Z.of(&comp, 6)); // not a subsurface
    try std.testing.expectEqual(@as(u32, 0), comp.surfaceParent(1, 6));

    // c just above the parent, a below it: pending until the parent commits
    // (the children's own commits don't apply it)
    try T.send(&comp, 15, above_op, &.{.{ .object = 6 }});
    try T.send(&comp, 11, below_op, &.{.{ .object = 6 }});
    try T.send(&comp, 14, commit_op, &.{});
    try T.send(&comp, 10, commit_op, &.{});
    try Z.expect(&comp, .{ 1, 2, 3 });
    try T.send(&comp, 6, commit_op, &.{});
    try Z.expect(&comp, .{ -1, 2, 1 }); // a | parent | c b

    // b below a: the bottom of the stack; then c just below b: between them
    try T.send(&comp, 13, below_op, &.{.{ .object = 10 }});
    try T.send(&comp, 15, below_op, &.{.{ .object = 10 }});
    try T.send(&comp, 6, commit_op, &.{});
    try Z.expect(&comp, .{ -1, -3, -2 }); // b c a | parent

    // a above b (below the parent, a step up from b): b a c | parent; then
    // b above c (c is a sibling): a c b | parent
    try T.send(&comp, 11, above_op, &.{.{ .object = 12 }});
    try T.send(&comp, 6, commit_op, &.{});
    try Z.expect(&comp, .{ -2, -3, -1 });
    try T.send(&comp, 13, above_op, &.{.{ .object = 14 }});
    try T.send(&comp, 6, commit_op, &.{});
    try Z.expect(&comp, .{ -3, -1, -2 });

    // a new subsurface goes on top, above the parent — pending moves
    // included: the latched order is the last one asked for
    try T.send(&comp, 11, above_op, &.{.{ .object = 12 }}); // c b a | parent (pending)
    try T.send(&comp, 3, 0, &.{.{ .new_id = 16 }});
    try T.send(&comp, 5, 1, &.{ .{ .new_id = 17 }, .{ .object = 16 }, .{ .object = 6 } });
    try std.testing.expectEqual(@as(i32, 1), Z.of(&comp, 16));
    try T.send(&comp, 11, above_op, &.{.{ .object = 16 }}); // c b | parent | d a
    try T.send(&comp, 6, commit_op, &.{});
    try Z.expect(&comp, .{ 2, -1, -2 });
    try std.testing.expectEqual(@as(i32, 1), Z.of(&comp, 16));

    // a nested subsurface's stack is its parent's own: e under b (12)
    try T.send(&comp, 3, 0, &.{.{ .new_id = 18 }});
    try T.send(&comp, 5, 1, &.{ .{ .new_id = 19 }, .{ .object = 18 }, .{ .object = 12 } });
    try std.testing.expectEqual(@as(i32, 1), Z.of(&comp, 18));
    try T.send(&comp, 19, below_op, &.{.{ .object = 12 }});
    try T.send(&comp, 6, commit_op, &.{}); // not its parent: nothing
    try std.testing.expectEqual(@as(i32, 1), Z.of(&comp, 18));
    try T.send(&comp, 12, commit_op, &.{});
    try std.testing.expectEqual(@as(i32, -1), Z.of(&comp, 18));
    try Z.expect(&comp, .{ 2, -1, -2 });

    // a sibling destroyed leaves the others' order (dense again)
    try T.send(&comp, 17, 0, &.{}); // d's wl_subsurface.destroy
    try Z.expect(&comp, .{ 1, -1, -2 });

    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
    // the reference must be the parent or a sibling: a child of a sibling
    // (e), itself, and a surface of no role are bad_surface
    try T.send(&comp, 11, above_op, &.{.{ .object = 18 }});
    try std.testing.expectEqual(@as(?u32, subsurface_err_bad_surface), lastErrorCode(&sink));
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 11, below_op, &.{.{ .object = 10 }});
    try std.testing.expectEqual(@as(?u32, subsurface_err_bad_surface), lastErrorCode(&sink));
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 11, above_op, &.{.{ .object = 16 }});
    try std.testing.expectEqual(@as(?u32, subsurface_err_bad_surface), lastErrorCode(&sink));
    try Z.expect(&comp, .{ 1, -1, -2 });
}

test "popup gets configure from positioner on first commit" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 5 } } }));
    // toplevel: surface 6 + xdg_surface 7 + toplevel 8, committed
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 6 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 2, &.{ .{ .new_id = 7 }, .{ .object = 6 } })); // get_xdg_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 1, &.{.{ .new_id = 8 }})); // get_toplevel
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 6, &.{})); // commit
    sink.events.clearRetainingCapacity();

    // positioner 9: menu popup at anchor rect (100,50,10,10), bottom_right, size 200x150
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 9 }})); // create_positioner
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 1, &.{ .{ .int = 200 }, .{ .int = 150 } })); // set_size
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 2, &.{ .{ .int = 100 }, .{ .int = 50 }, .{ .int = 10 }, .{ .int = 10 } })); // set_anchor_rect
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 3, &.{.{ .uint = 8 }})); // anchor bottom_right
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 4, &.{.{ .uint = 8 }})); // gravity bottom_right
    // popup surface 10 + xdg_surface 11 + popup 12
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 10 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 2, &.{ .{ .new_id = 11 }, .{ .object = 10 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 2, &.{ .{ .new_id = 12 }, .{ .object = 7 }, .{ .object = 9 } })); // get_popup
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 10, 6, &.{})); // popup commit

    try std.testing.expectEqual(Role.popup, comp.surfaceRole(1, 10));
    try std.testing.expectEqual(@as(u32, 6), comp.surfaceRoot(1, 10));
    // anchor point = (110, 60); gravity bottom_right → popup at anchor point
    try std.testing.expectEqual(@as(i32, 110), comp.surfaceAbs(1, 10).x);
    try std.testing.expectEqual(@as(i32, 60), comp.surfaceAbs(1, 10).y);
    // two configure events: xdg_popup.configure then xdg_surface.configure
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 12), sink.events.items[0].object_id);
    var vals: [wire.max_args]wire.Value = undefined;
    const args = try wire.decodeArgs(sink.events.items[0].bytes[wire.header_size..sink.events.items[0].len], &.{ .int, .int, .int, .int }, &vals);
    try std.testing.expectEqual(@as(i32, 110), args[0].int);
    try std.testing.expectEqual(@as(i32, 60), args[1].int);
    try std.testing.expectEqual(@as(i32, 200), args[2].int);
    try std.testing.expectEqual(@as(i32, 150), args[3].int);

    // outside click → popup_done on the popup object
    sink.events.clearRetainingCapacity();
    comp.popupDismiss(1, 10);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 12), sink.events.items[0].object_id);
}

test "requestResize sends clamped configure to toplevel" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 5 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 6 }})); // surface
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 2, &.{ .{ .new_id = 7 }, .{ .object = 6 } })); // xdg_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 1, &.{.{ .new_id = 8 }})); // toplevel
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 8, &.{ .{ .int = 300 }, .{ .int = 200 } })); // set_min_size
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 7, &.{ .{ .int = 800 }, .{ .int = 600 } })); // set_max_size
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 6, &.{})); // commit: the hints apply
    sink.events.clearRetainingCapacity();

    comp.requestResize(1, 6, 100, 900); // below min-w, above max-h
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 8), sink.events.items[0].object_id); // toplevel configure
    var vals: [wire.max_args]wire.Value = undefined;
    const ev = sink.events.items[0];
    const args = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .int, .int, .array }, &vals);
    try std.testing.expectEqual(@as(i32, 300), args[0].int); // clamped up to min_w
    try std.testing.expectEqual(@as(i32, 600), args[1].int); // clamped down to max_h
    try std.testing.expectEqual(@as(u32, 7), sink.events.items[1].object_id); // xdg_surface configure

    // non-toplevel target is ignored
    sink.events.clearRetainingCapacity();
    comp.requestResize(1, 999, 400, 400);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

test "set_min_size / set_max_size are double-buffered: a commit applies them and tells the embedder (size_limits_fn) once per change; the xdg_toplevel going resets them" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.size_limits_fn = TestSink.sizeLimits;

    try wmBaseToplevel(&comp, 1);
    const tl = comptime protocol.find("xdg_toplevel").?;
    const min_op = comptime tl.requestIndex("set_min_size").?;
    const max_op = comptime tl.requestIndex("set_max_size").?;
    const commit_op = comptime protocol.find("wl_surface").?.requestIndex("commit").?;
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 8, min_op, &.{ .{ .int = 300 }, .{ .int = 200 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 8, max_op, &.{ .{ .int = 800 }, .{ .int = 0 } }));
    try std.testing.expectEqual(@as(u32, 0), sink.limits_calls); // pending
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{})); // (the initial configure; latches)
    try std.testing.expectEqual(@as(u32, 1), sink.limits_calls);
    try std.testing.expectEqual(@as(u32, 6), sink.limits_surface);
    try std.testing.expectEqual([4]i32{ 300, 200, 800, 0 }, sink.limits);
    try std.testing.expectEqual(@as(i32, 300), comp.conns.get(1).?.surfaces.get(6).?.min_w);

    // a new max alone is pending until the next commit; min stays
    try comp.onWire(1, wire.encodeMessage(&buf, 8, max_op, &.{ .{ .int = 900 }, .{ .int = 700 } }));
    try std.testing.expectEqual(@as(i32, 800), comp.conns.get(1).?.surfaces.get(6).?.max_w);
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 2), sink.limits_calls);
    try std.testing.expectEqual([4]i32{ 300, 200, 900, 700 }, sink.limits);
    // the same values again: no news
    try comp.onWire(1, wire.encodeMessage(&buf, 8, min_op, &.{ .{ .int = 300 }, .{ .int = 200 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 2), sink.limits_calls);
    // max below min, then fixed before the commit: in either order, fine
    try comp.onWire(1, wire.encodeMessage(&buf, 8, max_op, &.{ .{ .int = 100 }, .{ .int = 100 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 8, min_op, &.{ .{ .int = 50 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual([4]i32{ 50, 0, 100, 100 }, sink.limits);
    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));

    // the toplevel goes: back to none, and the embedder is told
    try comp.onWire(1, wire.encodeMessage(&buf, 8, comptime tl.requestIndex("destroy").?, &.{}));
    try std.testing.expectEqual(@as(u32, 4), sink.limits_calls);
    try std.testing.expectEqual([4]i32{ 0, 0, 0, 0 }, sink.limits);
    try std.testing.expectEqual(@as(i32, 0), comp.conns.get(1).?.surfaces.get(6).?.min_w);
}

test "set_min_size / set_max_size: negative is invalid_size at once, min above max at the commit (nothing applied)" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.size_limits_fn = TestSink.sizeLimits;
    const tl = comptime protocol.find("xdg_toplevel").?;
    const min_op = comptime tl.requestIndex("set_min_size").?;
    const max_op = comptime tl.requestIndex("set_max_size").?;
    const commit_op = comptime protocol.find("wl_surface").?.requestIndex("commit").?;
    var buf: [128]u8 = undefined;

    try wmBaseToplevel(&comp, 1);
    try comp.onWire(1, wire.encodeMessage(&buf, 8, min_op, &.{ .{ .int = -1 }, .{ .int = 10 } }));
    try std.testing.expectEqual(@as(?u32, xdg_toplevel_err_invalid_size), lastErrorCode(&sink));

    try wmBaseToplevel(&comp, 2);
    try comp.onWire(2, wire.encodeMessage(&buf, 8, min_op, &.{ .{ .int = 0 }, .{ .int = 500 } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 8, max_op, &.{ .{ .int = 0 }, .{ .int = 400 } }));
    sink.events.clearRetainingCapacity();
    try comp.onWire(2, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(?u32, xdg_toplevel_err_invalid_size), lastErrorCode(&sink));
    try std.testing.expectEqual(@as(u32, 0), sink.limits_calls);
    try std.testing.expectEqual(@as(i32, 0), comp.conns.get(2).?.surfaces.get(6).?.max_h);
}

test "closeToplevel sends xdg_toplevel.close and nothing else; not to other roles; set_app_id reaches app_id_fn" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.app_id_fn = TestSink.appId;

    try wmBaseToplevel(&comp, 1);
    var buf: [128]u8 = undefined;
    const tl = comptime protocol.find("xdg_toplevel").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 8, comptime tl.requestIndex("set_app_id").?, &.{.{ .string = "org.example.App" }}));
    try std.testing.expectEqual(@as(u32, 1), sink.app_id_calls);
    try std.testing.expectEqualStrings("org.example.App", sink.app_id[0..sink.app_id_len]);
    try comp.onWire(1, wire.encodeMessage(&buf, 6, comptime protocol.find("wl_surface").?.requestIndex("commit").?, &.{}));
    sink.events.clearRetainingCapacity();

    comp.closeToplevel(1, 6);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 8), sink.events.items[0].object_id);
    try std.testing.expectEqual(comptime tl.eventIndex("close").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(usize, wire.header_size), sink.events.items[0].len);

    // the window stays (the app decides); a surface without the role, an
    // unknown one or conn: nothing
    try std.testing.expectEqual(Role.toplevel, comp.surfaceRole(1, 6));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }})); // create_surface 9
    comp.closeToplevel(1, 9);
    comp.closeToplevel(1, 99);
    comp.closeToplevel(5, 6);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

test "cursor-shape: set_shape validates serial and shape enum" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    comp.cursor_shape_fn = TestSink.cursorShape;
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    // bind wl_compositor(1)@3, wl_seat(4)@4, wp_cursor_shape_manager_v1(9)@5
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 9 }, .{ .new_id_dynamic = .{ .interface = "wp_cursor_shape_manager_v1", .version = 1, .id = 5 } } }));
    // surface 6, wl_pointer 7, cursor_shape_device 8 (for pointer 7)
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }})); // create_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 7 }})); // wl_seat.get_pointer
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 8 }, .{ .object = 7 } })); // manager.get_pointer

    // pointer enters surface 6 → capture the enter serial the client must echo
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(1, 6, 0, 0);
    var enter_serial: u32 = 0;
    for (sink.events.items) |ev| {
        if (ev.object_id == 7 and ev.opcode == 0) { // wl_pointer.enter
            var vals: [wire.max_args]wire.Value = undefined;
            const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .uint, .object, .fixed, .fixed }, &vals);
            enter_serial = a[0].uint;
        }
    }
    try std.testing.expect(enter_serial != 0);

    // valid: matching serial + focused → shape surfaced to the embedder
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 1, &.{ .{ .uint = enter_serial }, .{ .uint = 9 } })); // set_shape(text)
    try std.testing.expectEqual(@as(u32, 1), sink.shape_calls);
    try std.testing.expectEqual(@as(u32, 9), sink.shape_value);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // no protocol error

    // stale serial → silently ignored (not a protocol error)
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 1, &.{ .{ .uint = enter_serial +% 1000 }, .{ .uint = 4 } }));
    try std.testing.expectEqual(@as(u32, 1), sink.shape_calls); // unchanged
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // no error emitted

    // invalid shape (above v1 max 34) → invalid_shape protocol error, no callback
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 1, &.{ .{ .uint = enter_serial }, .{ .uint = 99 } }));
    try std.testing.expectEqual(@as(u32, 1), sink.shape_calls); // unchanged
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[0].object_id); // wl_display
    try std.testing.expectEqual(@as(u16, 0), sink.events.items[0].opcode); // .error
    var evals: [wire.max_args]wire.Value = undefined;
    const eargs = try wire.decodeArgs(sink.events.items[0].bytes[wire.header_size..sink.events.items[0].len], &.{ .object, .uint, .string }, &evals);
    try std.testing.expectEqual(@as(u32, 8), eargs[0].object); // the offending device id
    try std.testing.expectEqual(cursor_shape_err_invalid_shape, eargs[1].uint);

    // invalid shape 0 (below min) → also an error
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 1, &.{ .{ .uint = enter_serial }, .{ .uint = 0 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);

    // pointer leave resets the cursor to the default (shape 0)
    sink.shape_calls = 0;
    comp.pointerLeave(1);
    try std.testing.expectEqual(@as(u32, 1), sink.shape_calls);
    try std.testing.expectEqual(cursor_shape_reset, sink.shape_value);

    // after leave the same serial no longer applies (pointer_focus == 0)
    sink.shape_calls = 0;
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 1, &.{ .{ .uint = enter_serial }, .{ .uint = 9 } }));
    try std.testing.expectEqual(@as(u32, 0), sink.shape_calls);
}

test "text-input-v3: enter/leave follows focus, enable/commit serial, preedit/commit ordering" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    comp.text_input_fn = TestSink.textInput;
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const ti_iface = comptime protocol.find("zwp_text_input_v3").?;
    const op_enter = comptime ti_iface.eventIndex("enter").?;
    const op_leave = comptime ti_iface.eventIndex("leave").?;
    const op_preedit = comptime ti_iface.eventIndex("preedit_string").?;
    const op_commit_str = comptime ti_iface.eventIndex("commit_string").?;
    const op_done = comptime ti_iface.eventIndex("done").?;

    try comp.connOpen(1);
    var buf: [256]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    // bind wl_compositor@3, xdg_wm_base@4, wl_seat@5, text_input_manager@6
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 5 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 12 }, .{ .new_id_dynamic = .{ .interface = "zwp_text_input_manager_v3", .version = 1, .id = 6 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 7 }})); // get_keyboard
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 8 }})); // create_surface (id 8)
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 9 }, .{ .object = 8 } })); // get_xdg_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 1, &.{.{ .new_id = 10 }})); // get_toplevel → surface 8 is a toplevel

    const findEv = struct {
        fn f(s: *TestSink, obj: u32, opcode: u16) ?usize {
            for (s.events.items, 0..) |ev, i| if (ev.object_id == obj and ev.opcode == opcode) return i;
            return null;
        }
    }.f;

    // focus lands FIRST, before the text input object exists → no TI enter yet
    comp.keyboardEnter(1, 8);
    try std.testing.expect(findEv(&sink, 11, op_enter) == null);

    // get_text_input while focus is already on the toplevel → enter fires now
    sink.events.clearRetainingCapacity();
    sink.ti_calls = 0;
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 11 }, .{ .object = 5 } })); // manager.get_text_input
    const enter_i = findEv(&sink, 11, op_enter).?;
    var vals: [wire.max_args]wire.Value = undefined;
    const enter_args = try wire.decodeArgs(sink.events.items[enter_i].bytes[wire.header_size..sink.events.items[enter_i].len], &.{.object}, &vals);
    try std.testing.expectEqual(@as(u32, 8), enter_args[0].object); // entered on surface 8
    // not enabled yet → embedder told active=0
    try std.testing.expectEqual(@as(u32, 0), sink.ti_active);

    // enable + set_cursor_rectangle are double-buffered; NOT applied until commit
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 1, &.{})); // enable
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 6, &.{ .{ .int = 10 }, .{ .int = 20 }, .{ .int = 2 }, .{ .int = 16 } })); // set_cursor_rectangle
    sink.ti_calls = 0;
    // (no commit yet) nothing surfaced to the embedder
    try std.testing.expectEqual(@as(u32, 0), sink.ti_calls);

    // commit → enabled + cursor rect latched atomically; serial becomes 1
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 7, &.{})); // commit
    try std.testing.expectEqual(@as(u32, 1), sink.ti_active);
    try std.testing.expectEqual(@as(i32, 10), sink.ti_x);
    try std.testing.expectEqual(@as(i32, 20), sink.ti_y);

    // preedit_string → done, done echoes the commit count (1), ordering preedit-then-done
    sink.events.clearRetainingCapacity();
    comp.textInputPreedit(1, "か", 0, 3);
    const pre_i = findEv(&sink, 11, op_preedit).?;
    const done_i = findEv(&sink, 11, op_done).?;
    try std.testing.expect(pre_i < done_i); // event precedes its done
    const done_args = try wire.decodeArgs(sink.events.items[done_i].bytes[wire.header_size..sink.events.items[done_i].len], &.{.uint}, &vals);
    try std.testing.expectEqual(@as(u32, 1), done_args[0].uint);

    // commit_string → commit_string then done(1)
    sink.events.clearRetainingCapacity();
    comp.textInputCommitString(1, "神");
    try std.testing.expect(findEv(&sink, 11, op_commit_str).? < findEv(&sink, 11, op_done).?);

    // a second commit bumps the serial to 2 → next done echoes 2
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 7, &.{})); // commit
    sink.events.clearRetainingCapacity();
    comp.textInputPreedit(1, "x", 0, 1);
    const done2 = findEv(&sink, 11, op_done).?;
    const done2_args = try wire.decodeArgs(sink.events.items[done2].bytes[wire.header_size..sink.events.items[done2].len], &.{.uint}, &vals);
    try std.testing.expectEqual(@as(u32, 2), done2_args[0].uint);

    // keyboard leave → text-input leave(surface 8) + active=0; composition dropped after
    sink.events.clearRetainingCapacity();
    comp.keyboardLeave(1);
    const leave_i = findEv(&sink, 11, op_leave).?;
    const leave_args = try wire.decodeArgs(sink.events.items[leave_i].bytes[wire.header_size..sink.events.items[leave_i].len], &.{.object}, &vals);
    try std.testing.expectEqual(@as(u32, 8), leave_args[0].object);
    try std.testing.expectEqual(@as(u32, 0), sink.ti_active);
    sink.events.clearRetainingCapacity();
    comp.textInputPreedit(1, "y", 0, 1); // not entered → no events
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // re-enter (enter follows keyboard focus again); enable reset to disabled
    comp.keyboardEnter(1, 8);
    try std.testing.expect(findEv(&sink, 11, op_enter) != null);
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 1, &.{})); // enable
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 7, &.{})); // commit
    try std.testing.expectEqual(@as(u32, 1), sink.ti_active);

    // destroy the entered surface → NO leave event may reference the dead id
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 0, &.{})); // wl_surface.destroy
    try std.testing.expect(findEv(&sink, 11, op_leave) == null); // silent, not a protocol error
    try std.testing.expectEqual(@as(u32, 0), sink.ti_active);
}

test "wp_viewporter: destination/source double-buffering + protocol errors" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 5, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 10 }, .{ .new_id_dynamic = .{ .interface = "wp_viewporter", .version = 1, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 5 }})); // create_surface

    const commit_op = comptime protocol.find("wl_surface").?.requestIndex("commit").?;
    const surf_destroy_op = comptime protocol.find("wl_surface").?.requestIndex("destroy").?;

    // get_viewport(new_id 6, surface 5)
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 1, &.{ .{ .new_id = 6 }, .{ .object = 5 } }));

    // set_destination(200,100) is pending until commit
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 2, &.{ .{ .int = 200 }, .{ .int = 100 } }));
    try std.testing.expectEqual(@as(i32, 0), comp.surfaceViewSize(1, 5).w); // not latched yet
    try comp.onWire(1, wire.encodeMessage(&buf, 5, commit_op, &.{}));
    try std.testing.expectEqual(@as(i32, 200), comp.surfaceViewSize(1, 5).w);
    try std.testing.expectEqual(@as(i32, 100), comp.surfaceViewSize(1, 5).h);

    // unset destination (-1,-1) → back to no override after commit
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 2, &.{ .{ .int = -1 }, .{ .int = -1 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, commit_op, &.{}));
    try std.testing.expectEqual(@as(i32, 0), comp.surfaceViewSize(1, 5).w);

    // bad_value: negative destination
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 2, &.{ .{ .int = -5 }, .{ .int = 10 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[0].object_id); // wl_display.error
    var vals: [wire.max_args]wire.Value = undefined;
    {
        const ev = sink.events.items[0];
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals);
        try std.testing.expectEqual(@as(u32, 6), a[0].object); // offending viewport
        try std.testing.expectEqual(viewport_err_bad_value, a[1].uint);
    }

    // set_source: integer crop with NO destination → surface size = src size
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 1, &.{ .{ .fixed = 0 }, .{ .fixed = 0 }, .{ .fixed = 64 * 256 }, .{ .fixed = 48 * 256 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, commit_op, &.{}));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // integer src → no bad_size
    try std.testing.expectEqual(@as(i32, 64), comp.surfaceViewSize(1, 5).w);
    try std.testing.expectEqual(@as(i32, 48), comp.surfaceViewSize(1, 5).h);

    // set_source unset (all -1.0) → back to no override
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 1, &.{ .{ .fixed = -256 }, .{ .fixed = -256 }, .{ .fixed = -256 }, .{ .fixed = -256 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, commit_op, &.{}));
    try std.testing.expectEqual(@as(i32, 0), comp.surfaceViewSize(1, 5).w);

    // set_source bad_value: negative x
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 1, &.{ .{ .fixed = -128 }, .{ .fixed = 0 }, .{ .fixed = 256 }, .{ .fixed = 256 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);

    // bad_size: non-integer source (width 64.5) with no destination, at commit
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 1, &.{ .{ .fixed = 0 }, .{ .fixed = 0 }, .{ .fixed = 64 * 256 + 128 }, .{ .fixed = 48 * 256 } }));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // deferred to commit
    try comp.onWire(1, wire.encodeMessage(&buf, 5, commit_op, &.{}));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    {
        const ev = sink.events.items[0];
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals);
        try std.testing.expectEqual(viewport_err_bad_size, a[1].uint);
    }

    // duplicate get_viewport on the same surface → viewport_exists
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 1, &.{ .{ .new_id = 7 }, .{ .object = 5 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    {
        const ev = sink.events.items[0];
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals);
        try std.testing.expectEqual(@as(u32, 4), a[0].object); // the wp_viewporter
        try std.testing.expectEqual(viewporter_err_viewport_exists, a[1].uint);
    }

    // no_surface: destroy the wl_surface, then poke the still-live viewport
    try comp.onWire(1, wire.encodeMessage(&buf, 5, surf_destroy_op, &.{}));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 2, &.{ .{ .int = 10 }, .{ .int = 10 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    {
        const ev = sink.events.items[0];
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals);
        try std.testing.expectEqual(viewport_err_no_surface, a[1].uint);
    }
}

test "wl_compositor v6: preferred_buffer_scale/transform on create + dpr resend" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.output_scale = 2;

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    // bind wl_compositor at v6
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 6, .id = 3 } } }));

    const scale_op = comptime protocol.find("wl_surface").?.eventIndex("preferred_buffer_scale").?;
    const xform_op = comptime protocol.find("wl_surface").?.eventIndex("preferred_buffer_transform").?;

    // create_surface(6) → preferred_buffer_scale(2) + preferred_buffer_transform(normal)
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }}));
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 6), sink.events.items[0].object_id);
    try std.testing.expectEqual(scale_op, sink.events.items[0].opcode);
    try std.testing.expectEqual(xform_op, sink.events.items[1].opcode);
    var vals: [wire.max_args]wire.Value = undefined;
    {
        const a = try wire.decodeArgs(sink.events.items[0].bytes[wire.header_size..sink.events.items[0].len], &.{.int}, &vals);
        try std.testing.expectEqual(@as(i32, 2), a[0].int);
        const t = try wire.decodeArgs(sink.events.items[1].bytes[wire.header_size..sink.events.items[1].len], &.{.uint}, &vals);
        try std.testing.expectEqual(@as(u32, 0), t[0].uint); // normal transform
    }

    // dpr change → preferred_buffer_scale resent with the new integer scale
    sink.events.clearRetainingCapacity();
    comp.setScale(3, 360);
    var got_scale: i32 = 0;
    for (sink.events.items) |ev| {
        if (ev.object_id == 6 and ev.opcode == scale_op) {
            const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.int}, &vals);
            got_scale = a[0].int;
        }
    }
    try std.testing.expectEqual(@as(i32, 3), got_scale);

    // a surface created by a <v6 compositor gets nothing
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 5, .id = 4 } } }));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 7 }})); // create_surface on v5
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

test "setConnScale: a pinned app sees its scale everywhere, dpr changes pass it by, unpinning resends" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.output_scale = 2;
    comp.scale_120 = 240; // a retina page

    const output_scale_op = comptime protocol.find("wl_output").?.eventIndex("scale").?;
    const mode_op = comptime protocol.find("wl_output").?.eventIndex("mode").?;
    const pbs_op = comptime protocol.find("wl_surface").?.eventIndex("preferred_buffer_scale").?;
    const H = struct {
        /// conn's last wl_output.scale, mode width, preferred_buffer_scale
        /// and preferred_scale in the sink (-1: none)
        const Seen = struct { scale: i32 = -1, mode_w: i32 = -1, pbs: i32 = -1, frac: i64 = -1 };
        fn seen(s: *TestSink, conn: u32) !Seen {
            var r: Seen = .{};
            var vals: [wire.max_args]wire.Value = undefined;
            for (s.events.items) |ev| {
                if (ev.conn_id != conn) continue;
                const body = ev.bytes[wire.header_size..ev.len];
                if (ev.object_id == 4 and ev.opcode == output_scale_op) {
                    r.scale = (try wire.decodeArgs(body, &.{.int}, &vals))[0].int;
                } else if (ev.object_id == 4 and ev.opcode == mode_op) {
                    r.mode_w = (try wire.decodeArgs(body, &.{ .uint, .int, .int, .int }, &vals))[1].int;
                } else if (ev.object_id == 6 and ev.opcode == pbs_op) {
                    r.pbs = (try wire.decodeArgs(body, &.{.int}, &vals))[0].int;
                } else if (ev.object_id == 7 and ev.opcode == 0) {
                    r.frac = (try wire.decodeArgs(body, &.{.uint}, &vals))[0].uint;
                }
            }
            return r;
        }
    };

    var buf: [128]u8 = undefined;
    // conn 1 pinned to 1 before its first request (as a CONN_SCALE does);
    // conn 2 follows the page. Both: wl_compositor v6, wl_output v4, the
    // fractional manager, a surface (6) and its fractional object (7).
    try comp.connOpen(1);
    comp.setConnScale(1, 1);
    comp.setConnScale(99, 1); // no such conn: nothing
    try comp.connOpen(2);
    sink.events.clearRetainingCapacity();
    for ([_]u32{ 1, 2 }) |c| {
        try comp.onWire(c, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
        try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 6, .id = 3 } } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 4, .id = 4 } } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 11 }, .{ .new_id_dynamic = .{ .interface = "wp_fractional_scale_manager_v1", .version = 1, .id = 5 } } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }})); // create_surface
        try comp.onWire(c, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 7 }, .{ .object = 6 } })); // get_fractional_scale
    }
    try std.testing.expectEqual(H.Seen{ .scale = 1, .mode_w = output_width, .pbs = 1, .frac = 120 }, try H.seen(&sink, 1));
    try std.testing.expectEqual(H.Seen{ .scale = 2, .mode_w = output_width * 2, .pbs = 2, .frac = 240 }, try H.seen(&sink, 2));
    // sizes stay logical: what it attaches at scale 1 is its logical size
    try std.testing.expectEqual(@as(i32, 1), comp.surfaceScale(1, 6));

    // the page goes to dpr 3: conn 2 is told, conn 1 hears nothing
    sink.events.clearRetainingCapacity();
    comp.setScale(3, 360);
    try std.testing.expectEqual(H.Seen{}, try H.seen(&sink, 1));
    try std.testing.expectEqual(H.Seen{ .scale = 3, .mode_w = output_width * 3, .pbs = 3, .frac = 360 }, try H.seen(&sink, 2));

    // pinning to what it already sees resends nothing; unpinning tells it
    // the page's scale; a pin above 4 is 4
    sink.events.clearRetainingCapacity();
    comp.setConnScale(1, 1);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    comp.setConnScale(1, 0);
    try std.testing.expectEqual(H.Seen{ .scale = 3, .mode_w = output_width * 3, .pbs = 3, .frac = 360 }, try H.seen(&sink, 1));
    try std.testing.expectEqual(H.Seen{}, try H.seen(&sink, 2));
    sink.events.clearRetainingCapacity();
    comp.setConnScale(2, 9);
    try std.testing.expectEqual(H.Seen{ .scale = 4, .mode_w = output_width * 4, .pbs = 4, .frac = 480 }, try H.seen(&sink, 2));
}

test "wp_fractional_scale: preferred_scale on bind, resend on dpr change, exists error" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.output_scale = 1;
    comp.scale_120 = 180; // dpr 1.5

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 5, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 11 }, .{ .new_id_dynamic = .{ .interface = "wp_fractional_scale_manager_v1", .version = 1, .id = 4 } } }));
    // wl_output bound too, so dpr change also touches the integer scale path
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 4, .id = 12 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }})); // create_surface

    // get_fractional_scale(new_id 7, surface 6) → preferred_scale(180) at once
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 1, &.{ .{ .new_id = 7 }, .{ .object = 6 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 7), sink.events.items[0].object_id);
    try std.testing.expectEqual(@as(u16, 0), sink.events.items[0].opcode); // preferred_scale
    var vals: [wire.max_args]wire.Value = undefined;
    {
        const ev = sink.events.items[0];
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.uint}, &vals);
        try std.testing.expectEqual(@as(u32, 180), a[0].uint);
    }

    // duplicate get_fractional_scale on the same surface → fractional_scale_exists
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 1, &.{ .{ .new_id = 8 }, .{ .object = 6 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    {
        const ev = sink.events.items[0];
        try std.testing.expectEqual(@as(u32, 1), ev.object_id); // wl_display.error
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals);
        try std.testing.expectEqual(@as(u32, 4), a[0].object); // the manager
        try std.testing.expectEqual(frac_err_fractional_scale_exists, a[1].uint);
    }

    // dpr change to 2.0 → resend preferred_scale(240) + wl_output scale/mode/done
    sink.events.clearRetainingCapacity();
    comp.setScale(2, 240);
    var frac_resent = false;
    var output_scale_ev: i32 = 0;
    for (sink.events.items) |ev| {
        if (ev.object_id == 7 and ev.opcode == 0) {
            const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.uint}, &vals);
            try std.testing.expectEqual(@as(u32, 240), a[0].uint);
            frac_resent = true;
        }
        if (ev.object_id == 12 and ev.opcode == comptime protocol.find("wl_output").?.eventIndex("scale").?) {
            const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.int}, &vals);
            output_scale_ev = a[0].int;
        }
    }
    try std.testing.expect(frac_resent);
    try std.testing.expectEqual(@as(i32, 2), output_scale_ev); // integer scale updated too

    // an idempotent setScale (no change) emits nothing
    sink.events.clearRetainingCapacity();
    comp.setScale(2, 240);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // destroying the fractional object stops future resends
    const frac_destroy_op = comptime protocol.find("wp_fractional_scale_v1").?.requestIndex("destroy").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 7, frac_destroy_op, &.{}));
    sink.events.clearRetainingCapacity();
    comp.setScale(3, 360);
    for (sink.events.items) |ev| {
        try std.testing.expect(!(ev.object_id == 7 and ev.opcode == 0)); // no preferred_scale to a dead object
    }
}

/// wmBaseToplevel, plus zxdg_decoration_manager_v1 bound as 5 and, when
/// `deco`, a decoration object 9 for toplevel 8 — all before the initial
/// commit (the usual order: SDL, foot, Qt).
fn decoToplevel(comp: *Compositor, conn_id: u32, deco: bool) !void {
    var buf: [128]u8 = undefined;
    try wmBaseToplevel(comp, conn_id);
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 8 }, .{ .new_id_dynamic = .{ .interface = "zxdg_decoration_manager_v1", .version = 1, .id = 5 } } }));
    if (deco) try comp.onWire(conn_id, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 9 }, .{ .object = 8 } }));
}

const Deco = struct {
    const tl = protocol.find("xdg_toplevel").?;
    const caps: u32 = tl.eventIndex("wm_capabilities").?;
    const bounds: u32 = tl.eventIndex("configure_bounds").?;
    const cfg: u32 = tl.eventIndex("configure").?;
    const xdg_cfg: u32 = protocol.find("xdg_surface").?.eventIndex("configure").?;
    const deco_cfg: u32 = protocol.find("zxdg_toplevel_decoration_v1").?.eventIndex("configure").?;
    const set_mode: u16 = protocol.find("zxdg_toplevel_decoration_v1").?.requestIndex("set_mode").?;
    const unset_mode: u16 = protocol.find("zxdg_toplevel_decoration_v1").?.requestIndex("unset_mode").?;
    const commit: u16 = protocol.find("wl_surface").?.requestIndex("commit").?;
    const attach: u16 = protocol.find("wl_surface").?.requestIndex("attach").?;
    const set_maximized: u16 = tl.requestIndex("set_maximized").?;

    /// The sink's events to `conn_id` as (object, opcode) pairs.
    fn seq(sink: *const TestSink, conn_id: u32, out: [][2]u32) [][2]u32 {
        var n: usize = 0;
        for (sink.events.items) |ev| {
            if (ev.conn_id != conn_id) continue;
            out[n] = .{ ev.object_id, ev.opcode };
            n += 1;
        }
        return out[0..n];
    }

    fn expectSeq(sink: *const TestSink, conn_id: u32, want: []const [2]u32) !void {
        var buf: [32][2]u32 = undefined;
        const got = seq(sink, conn_id, &buf);
        errdefer for (got) |g| std.debug.print("got: {d}.{d}\n", .{ g[0], g[1] });
        try std.testing.expectEqualSlices([2]u32, want, got);
    }

    /// The first two 32-bit args of the last (object, opcode) event to `conn_id`.
    fn last2(sink: *const TestSink, conn_id: u32, object: u32, opcode: u32) ![2]i32 {
        var i = sink.events.items.len;
        while (i > 0) {
            i -= 1;
            const ev = sink.events.items[i];
            if (ev.conn_id != conn_id or ev.object_id != object or ev.opcode != opcode) continue;
            return .{ std.mem.readInt(i32, ev.bytes[8..12], .little), std.mem.readInt(i32, ev.bytes[12..16], .little) };
        }
        return error.NoEvent;
    }

    /// The mode of the last decoration configure to object `id` of `conn_id`.
    fn mode(sink: *const TestSink, conn_id: u32, id: u32) !u32 {
        return @intCast((try last2(sink, conn_id, id, deco_cfg))[0]);
    }

    fn send(comp: *Compositor, conn_id: u32, obj: u32, op: u16, args: []const wire.Value) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(conn_id, wire.encodeMessage(&buf, obj, op, args));
    }
};

test "decoration, client mode (the default): client_side rides the initial configure whatever the app asks; every request re-answered with a configure cycle; never decorated; destroy unhooks" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.decoration_fn = TestSink.decoration;

    try decoToplevel(&comp, 1, true);
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 9, Deco.set_mode, &.{.{ .uint = decoration_mode_server_side }}); // pre-map
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // nothing before the initial commit

    try Deco.send(&comp, 1, 6, Deco.commit, &.{});
    // caps, bounds, decoration.configure(client_side), xdg_toplevel.configure, xdg_surface.configure
    try Deco.expectSeq(&sink, 1, &.{ .{ 8, Deco.caps }, .{ 8, Deco.bounds }, .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_client_side, try Deco.mode(&sink, 1, 9));

    // post-map set_mode(server_side) → client_side again, in a cycle of its own
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 9, Deco.set_mode, &.{.{ .uint = decoration_mode_server_side }});
    try Deco.expectSeq(&sink, 1, &.{ .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_client_side, try Deco.mode(&sink, 1, 9));

    // destroy → just delete_id; a fresh decoration (no buffer yet: allowed
    // in v1) is answered at once, and its unset_mode too
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 9, 0, &.{}); // destroy
    try Deco.expectSeq(&sink, 1, &.{.{ 1, 1 }}); // wl_display.delete_id
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 5, 1, &.{ .{ .new_id = 10 }, .{ .object = 8 } });
    try Deco.send(&comp, 1, 10, Deco.unset_mode, &.{});
    try Deco.expectSeq(&sink, 1, &.{ .{ 10, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg }, .{ 10, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_client_side, try Deco.mode(&sink, 1, 10));
    try std.testing.expectEqual(@as(u32, 0), sink.deco_calls);
}

test "decoration, server mode: server_side by default at the initial configure (the embedder told then); set_mode(client_side) honoured, set_mode(server_side) and unset_mode give server_side; the object destroyed → client-side at the next commit" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.decoration_fn = TestSink.decoration;
    comp.setDecorations(true);

    try decoToplevel(&comp, 1, true);
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 6, Deco.commit, &.{});
    try Deco.expectSeq(&sink, 1, &.{ .{ 8, Deco.caps }, .{ 8, Deco.bounds }, .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_server_side, try Deco.mode(&sink, 1, 9));
    // known before the first buffer: an embedder picks its frame up front
    try std.testing.expectEqual(@as(u32, 1), sink.deco_calls);
    try std.testing.expectEqual(@as(?bool, true), sink.decorated);
    try std.testing.expectEqual(@as(u32, 6), sink.deco_surface);
    try Deco.send(&comp, 1, 6, Deco.attach, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } });
    try Deco.send(&comp, 1, 6, Deco.commit, &.{});
    try std.testing.expectEqual(@as(u32, 1), sink.deco_calls);

    // set_mode(client_side): honoured
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 9, Deco.set_mode, &.{.{ .uint = decoration_mode_client_side }});
    try Deco.expectSeq(&sink, 1, &.{ .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_client_side, try Deco.mode(&sink, 1, 9));
    try std.testing.expectEqual(@as(u32, 2), sink.deco_calls);
    try std.testing.expectEqual(@as(?bool, false), sink.decorated);
    // set_mode(server_side): server_side
    try Deco.send(&comp, 1, 9, Deco.set_mode, &.{.{ .uint = decoration_mode_server_side }});
    try std.testing.expectEqual(decoration_mode_server_side, try Deco.mode(&sink, 1, 9));
    try std.testing.expectEqual(@as(u32, 3), sink.deco_calls);
    try std.testing.expectEqual(@as(?bool, true), sink.decorated);
    // unset_mode: our pick, server_side (answered; nothing new to tell)
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 9, Deco.unset_mode, &.{});
    try Deco.expectSeq(&sink, 1, &.{ .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_server_side, try Deco.mode(&sink, 1, 9));
    try std.testing.expectEqual(@as(u32, 3), sink.deco_calls);

    // destroyed: client-side at the next commit, not before
    try Deco.send(&comp, 1, 9, 0, &.{});
    try std.testing.expectEqual(@as(u32, 3), sink.deco_calls);
    try Deco.send(&comp, 1, 6, Deco.commit, &.{});
    try std.testing.expectEqual(@as(u32, 4), sink.deco_calls);
    try std.testing.expectEqual(@as(?bool, false), sink.decorated);
    try Deco.send(&comp, 1, 6, Deco.commit, &.{});
    try std.testing.expectEqual(@as(u32, 4), sink.deco_calls);
}

test "decoration, server mode: a toplevel without a decoration object, or one asking client_side before its initial configure, is client-side; an xdg_toplevel going undecorates" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.decoration_fn = TestSink.decoration;
    comp.setDecorations(true);

    // no decoration object (GTK): nothing about decorations at all
    try decoToplevel(&comp, 1, false);
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 1, 6, Deco.commit, &.{});
    try Deco.expectSeq(&sink, 1, &.{ .{ 8, Deco.caps }, .{ 8, Deco.bounds }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(@as(u32, 0), sink.deco_calls);

    // set_mode(client_side) before the initial commit: it maps client_side
    try decoToplevel(&comp, 2, true);
    try Deco.send(&comp, 2, 9, Deco.set_mode, &.{.{ .uint = decoration_mode_client_side }});
    try Deco.send(&comp, 2, 6, Deco.commit, &.{});
    try std.testing.expectEqual(decoration_mode_client_side, try Deco.mode(&sink, 2, 9));
    try std.testing.expectEqual(@as(u32, 0), sink.deco_calls);

    // a decorated toplevel whose objects go in order (decoration, then
    // xdg_toplevel, no commit between): told false when the toplevel goes
    try decoToplevel(&comp, 3, true);
    try Deco.send(&comp, 3, 6, Deco.commit, &.{});
    try std.testing.expectEqual(@as(?bool, true), sink.decorated);
    try Deco.send(&comp, 3, 9, 0, &.{});
    try Deco.send(&comp, 3, 8, 0, &.{});
    try std.testing.expectEqual(@as(?bool, false), sink.decorated);
    try std.testing.expectEqual(@as(u32, 2), sink.deco_calls);
    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
}

test "decoration: setDecorations answers again the configured toplevels whose mode it changes, and only those" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.decoration_fn = TestSink.decoration;

    try decoToplevel(&comp, 1, true); // no preference
    try decoToplevel(&comp, 2, true);
    try Deco.send(&comp, 2, 9, Deco.set_mode, &.{.{ .uint = decoration_mode_client_side }});
    try decoToplevel(&comp, 3, false); // no decoration object
    try decoToplevel(&comp, 4, true); // not configured yet
    for ([_]u32{ 1, 2, 3 }) |c| try Deco.send(&comp, c, 6, Deco.commit, &.{});

    sink.events.clearRetainingCapacity();
    comp.setDecorations(true);
    try Deco.expectSeq(&sink, 1, &.{ .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_server_side, try Deco.mode(&sink, 1, 9));
    for ([_]u32{ 2, 3, 4 }) |c| try Deco.expectSeq(&sink, c, &.{});
    try std.testing.expectEqual(@as(u32, 1), sink.deco_calls);
    try std.testing.expectEqual(@as(?bool, true), sink.decorated);
    // the unconfigured one picks the mode up at its initial configure
    try Deco.send(&comp, 4, 6, Deco.commit, &.{});
    try std.testing.expectEqual(decoration_mode_server_side, try Deco.mode(&sink, 4, 9));
    try std.testing.expectEqual(@as(u32, 2), sink.deco_calls);

    sink.events.clearRetainingCapacity();
    comp.setDecorations(true); // unchanged: nothing
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    comp.setDecorations(false);
    try Deco.expectSeq(&sink, 1, &.{ .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try Deco.expectSeq(&sink, 4, &.{ .{ 9, Deco.deco_cfg }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual(decoration_mode_client_side, try Deco.mode(&sink, 1, 9));
    for ([_]u32{ 2, 3 }) |c| try Deco.expectSeq(&sink, c, &.{});
    try std.testing.expectEqual(@as(u32, 4), sink.deco_calls);
    try std.testing.expectEqual(@as(?bool, false), sink.decorated);
}

test "decoration errors: already_constructed, a buffer attached before it is made or before its first configure (v1), orphaned, invalid_mode" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    // a second decoration object for the toplevel
    try decoToplevel(&comp, 1, true);
    try Deco.send(&comp, 1, 5, 1, &.{ .{ .new_id = 10 }, .{ .object = 8 } });
    try std.testing.expectEqual(@as(?u32, decoration_err_already_constructed), lastErrorCode(&sink));

    // made with a buffer attached (pending), or committed
    sink.events.clearRetainingCapacity();
    try decoToplevel(&comp, 2, false);
    try Deco.send(&comp, 2, 6, Deco.attach, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } });
    try Deco.send(&comp, 2, 5, 1, &.{ .{ .new_id = 9 }, .{ .object = 8 } });
    try std.testing.expectEqual(@as(?u32, decoration_err_unconfigured_buffer), lastErrorCode(&sink));
    sink.events.clearRetainingCapacity();
    try decoToplevel(&comp, 3, false);
    try Deco.send(&comp, 3, 6, Deco.commit, &.{});
    try Deco.send(&comp, 3, 6, Deco.attach, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } });
    try Deco.send(&comp, 3, 6, Deco.commit, &.{});
    try Deco.send(&comp, 3, 5, 1, &.{ .{ .new_id = 9 }, .{ .object = 8 } });
    try std.testing.expectEqual(@as(?u32, decoration_err_unconfigured_buffer), lastErrorCode(&sink));

    // a buffer committed before the first decoration configure
    sink.events.clearRetainingCapacity();
    try decoToplevel(&comp, 4, true);
    try Deco.send(&comp, 4, 6, Deco.attach, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } });
    try Deco.send(&comp, 4, 6, Deco.commit, &.{});
    try std.testing.expectEqual(@as(?u32, decoration_err_unconfigured_buffer), lastErrorCode(&sink));

    // the xdg_toplevel destroyed before its decoration object
    sink.events.clearRetainingCapacity();
    try decoToplevel(&comp, 5, true);
    try Deco.send(&comp, 5, 6, Deco.commit, &.{});
    try Deco.send(&comp, 5, 8, 0, &.{});
    try std.testing.expectEqual(@as(?u32, decoration_err_orphaned), lastErrorCode(&sink));

    // a mode that is neither
    sink.events.clearRetainingCapacity();
    try decoToplevel(&comp, 6, true);
    try Deco.send(&comp, 6, 9, Deco.set_mode, &.{.{ .uint = 3 }});
    try std.testing.expectEqual(@as(?u32, decoration_err_invalid_mode), lastErrorCode(&sink));
}

test "configure_bounds: setBounds is the work area (client-side and decorated toplevels apart), re-sent with a configure when it changes; a maximized toplevel is configured to it; 0×0 is the desktop again" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.desk_w = 1500;
    comp.desk_h = 950;
    comp.setDecorations(true);

    try decoToplevel(&comp, 1, false); // client-side
    try decoToplevel(&comp, 2, true); // decorated
    sink.events.clearRetainingCapacity();
    comp.setBounds(1400, 900, 1380, 860); // nothing configured yet: nothing sent
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    for ([_]u32{ 1, 2 }) |c| try Deco.send(&comp, c, 6, Deco.commit, &.{});
    try std.testing.expectEqual([2]i32{ 1400, 900 }, try Deco.last2(&sink, 1, 8, Deco.bounds));
    try std.testing.expectEqual([2]i32{ 1380, 860 }, try Deco.last2(&sink, 2, 8, Deco.bounds));

    sink.events.clearRetainingCapacity();
    comp.setBounds(1400, 900, 1380, 860); // unchanged
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    // only the client-side area changes: only conn 1 hears of it, bounds
    // then a configure repeating its size (0×0: its own) and states
    comp.setBounds(1200, 800, 1380, 860);
    try Deco.expectSeq(&sink, 1, &.{ .{ 8, Deco.bounds }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual([2]i32{ 1200, 800 }, try Deco.last2(&sink, 1, 8, Deco.bounds));
    try std.testing.expectEqual([2]i32{ 0, 0 }, try Deco.last2(&sink, 1, 8, Deco.cfg));
    try Deco.expectSeq(&sink, 2, &.{});

    // maximized: the decorated area, not the desktop
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 2, 8, Deco.set_maximized, &.{});
    try std.testing.expectEqual([2]i32{ 1380, 860 }, try Deco.last2(&sink, 2, 8, Deco.cfg));
    // client_side asked: the client-side area, its bounds sent again with it
    sink.events.clearRetainingCapacity();
    try Deco.send(&comp, 2, 9, Deco.set_mode, &.{.{ .uint = decoration_mode_client_side }});
    try Deco.expectSeq(&sink, 2, &.{ .{ 9, Deco.deco_cfg }, .{ 8, Deco.bounds }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual([2]i32{ 1200, 800 }, try Deco.last2(&sink, 2, 8, Deco.bounds));
    try std.testing.expectEqual([2]i32{ 1200, 800 }, try Deco.last2(&sink, 2, 8, Deco.cfg));

    // 0×0: the desktop's size again, for both
    sink.events.clearRetainingCapacity();
    comp.setBounds(0, 0, 0, 0);
    try std.testing.expectEqual([2]i32{ 1500, 950 }, try Deco.last2(&sink, 1, 8, Deco.bounds));
    try std.testing.expectEqual([2]i32{ 1500, 950 }, try Deco.last2(&sink, 2, 8, Deco.bounds));
    try std.testing.expectEqual([2]i32{ 1500, 950 }, try Deco.last2(&sink, 2, 8, Deco.cfg));
    // and a desktop resize then reaches the maximized one as before
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1600, 1000);
    try Deco.expectSeq(&sink, 2, &.{ .{ 8, Deco.bounds }, .{ 8, Deco.cfg }, .{ 7, Deco.xdg_cfg } });
    try std.testing.expectEqual([2]i32{ 1600, 1000 }, try Deco.last2(&sink, 2, 8, Deco.cfg));
}

/// Map a v6 toplevel: registry 2, wl_compositor 3, xdg_wm_base(v6) 4,
/// surface 6, xdg_surface 7, toplevel 8. Leaves the toplevel UNcommitted.
fn wmBaseToplevel(comp: *Compositor, conn_id: u32) !void {
    return wmBaseToplevelAt(comp, conn_id, 6);
}

/// wmBaseToplevel with xdg_wm_base bound at `version`.
fn wmBaseToplevelAt(comp: *Compositor, conn_id: u32, version: u32) !void {
    var buf: [128]u8 = undefined;
    try comp.connOpen(conn_id);
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = version, .id = 4 } } }));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }})); // create_surface
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 7 }, .{ .object = 6 } })); // get_xdg_surface
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 7, 1, &.{.{ .new_id = 8 }})); // get_toplevel
}

test "xdg_wm_base v6: wm_capabilities + configure_bounds precede the first configure" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.desk_w = 1500;
    comp.desk_h = 950;

    try wmBaseToplevel(&comp, 1);
    var buf: [128]u8 = undefined;
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 6, &.{})); // first commit

    const tl = comptime protocol.find("xdg_toplevel").?;
    const caps_op = comptime tl.eventIndex("wm_capabilities").?;
    const bounds_op = comptime tl.eventIndex("configure_bounds").?;
    const cfg_op = comptime tl.eventIndex("configure").?;
    // order: wm_capabilities, configure_bounds, xdg_toplevel.configure,
    // xdg_surface.configure — the caps/bounds strictly before the configures
    try std.testing.expectEqual(@as(usize, 4), sink.events.items.len);
    try std.testing.expectEqual(caps_op, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 8), sink.events.items[0].object_id);
    var vals: [wire.max_args]wire.Value = undefined;
    const caps = sink.events.items[0];
    const caps_args = try wire.decodeArgs(caps.bytes[wire.header_size..caps.len], &.{.array}, &vals);
    // maximize, fullscreen, minimize — what the core honours, no window menu
    try std.testing.expectEqual(@as(usize, 12), caps_args[0].array.len);
    try std.testing.expectEqual(Compositor.wm_cap_maximize, std.mem.readInt(u32, caps_args[0].array[0..4], .little));
    try std.testing.expectEqual(Compositor.wm_cap_fullscreen, std.mem.readInt(u32, caps_args[0].array[4..8], .little));
    try std.testing.expectEqual(Compositor.wm_cap_minimize, std.mem.readInt(u32, caps_args[0].array[8..12], .little));
    try std.testing.expectEqual(bounds_op, sink.events.items[1].opcode);
    const bnd = sink.events.items[1];
    const bnd_args = try wire.decodeArgs(bnd.bytes[wire.header_size..bnd.len], &.{ .int, .int }, &vals);
    try std.testing.expectEqual(@as(i32, 1500), bnd_args[0].int);
    try std.testing.expectEqual(@as(i32, 950), bnd_args[1].int);
    try std.testing.expectEqual(cfg_op, sink.events.items[2].opcode); // xdg_toplevel.configure
    try std.testing.expectEqual(@as(u32, 8), sink.events.items[2].object_id);
    try std.testing.expectEqual(@as(u32, 7), sink.events.items[3].object_id); // xdg_surface.configure
}

/// The size of the last xdg_toplevel.configure in the sink (object 8).
fn lastConfigureSize(sink: *TestSink) ![2]i32 {
    const cfg_op = comptime protocol.find("xdg_toplevel").?.eventIndex("configure").?;
    var vals: [wire.max_args]wire.Value = undefined;
    var found: ?[2]i32 = null;
    for (sink.events.items) |ev| {
        if (ev.object_id != 8 or ev.opcode != cfg_op) continue;
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .int, .int, .array }, &vals);
        found = .{ a[0].int, a[1].int };
    }
    return found orelse error.NoConfigure;
}

test "window geometry: unset, it is the bounds of the toplevel and its subsurfaces" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const surf = comptime protocol.find("wl_surface").?;
    const attach_op = comptime surf.requestIndex("attach").?;
    const commit_op = comptime surf.requestIndex("commit").?;
    const tl = comptime protocol.find("xdg_toplevel").?;

    try wmBaseToplevel(&comp, 1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 5 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{})); // initial commit
    try std.testing.expectEqual(Rect{}, comp.windowGeometry(1, 6)); // nothing presented yet

    // the toplevel alone: its own box
    try comp.onWire(1, wire.encodeMessage(&buf, 6, attach_op, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    comp.noteBufferSize(1, 6, 700, 475);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 700, .h = 475 }, comp.windowGeometry(1, 6));

    // a titlebar subsurface above it (xwayland-satellite: y = -25) and a
    // nested one inside that: the box grows to hold them
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 10 }})); // create_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 11 }, .{ .object = 10 }, .{ .object = 6 } })); // get_subsurface
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 1, &.{ .{ .int = 0 }, .{ .int = -25 } })); // set_position
    try std.testing.expectEqual(@as(i32, 475), comp.windowGeometry(1, 6).h); // no content yet
    try comp.onWire(1, wire.encodeMessage(&buf, 10, attach_op, &.{ .{ .object = 31 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 10, commit_op, &.{}));
    comp.noteBufferSize(1, 10, 1400, 50); // drawn at 2×
    try comp.onWire(1, wire.encodeMessage(&buf, 10, comptime surf.requestIndex("set_buffer_scale").?, &.{.{ .int = 2 }}));
    comp.noteBufferSize(1, 10, 1400, 50);
    try std.testing.expectEqual(Rect{ .x = 0, .y = -25, .w = 700, .h = 500 }, comp.windowGeometry(1, 6));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 12 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 13 }, .{ .object = 12 }, .{ .object = 10 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 13, 1, &.{ .{ .int = 690 }, .{ .int = 5 } })); // relative to the titlebar
    comp.noteBufferSize(1, 12, 20, 10);
    try std.testing.expectEqual(Rect{ .x = 0, .y = -25, .w = 710, .h = 500 }, comp.windowGeometry(1, 6));
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{})); // wl_surface.destroy
    try std.testing.expectEqual(Rect{ .x = 0, .y = -25, .w = 700, .h = 500 }, comp.windowGeometry(1, 6));

    // the floating size restored by unmaximize is the window's, titlebar included
    try comp.onWire(1, wire.encodeMessage(&buf, 8, comptime tl.requestIndex("set_maximized").?, &.{}));
    comp.noteBufferSize(1, 6, 1280, 695); // the maximized size is not a floating size
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, comptime tl.requestIndex("unset_maximized").?, &.{}));
    try std.testing.expectEqual([2]i32{ 700, 500 }, try lastConfigureSize(&sink));

    // a subsurface without content (attach(NULL) + commit) no longer counts
    comp.noteBufferSize(1, 6, 700, 475);
    try comp.onWire(1, wire.encodeMessage(&buf, 10, attach_op, &.{ .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 10, commit_op, &.{}));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 700, .h = 475 }, comp.windowGeometry(1, 6));
}

test "Region: add/subtract in request order, disjoint boxes, saturating edges, superset on overflow" {
    var r: Region = .{};
    try std.testing.expect(!r.contains(0, 0));
    try std.testing.expect(r.add(0, 0, 100, 100));
    try std.testing.expect(r.subtract(40, 40, 20, 20)); // a hole
    try std.testing.expect(r.contains(39, 50) and !r.contains(40, 50) and !r.contains(59, 59) and r.contains(60, 59));
    try std.testing.expect(!r.contains(100, 0) and !r.contains(-1, 0)); // x1/y1 exclusive
    try std.testing.expect(r.add(45, 45, 5, 5)); // add after subtract refills part of the hole
    try std.testing.expect(r.contains(47, 47) and !r.contains(51, 51));
    // boxes stay disjoint: every point is covered at most once
    var y: i32 = -2;
    while (y < 102) : (y += 1) {
        var x: i32 = -2;
        while (x < 102) : (x += 1) {
            var hits: u32 = 0;
            for (r.slice()) |b| {
                if (x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1) hits += 1;
            }
            try std.testing.expect(hits <= 1);
        }
    }
    // order matters: subtract-then-add keeps the added rect
    var a: Region = .{};
    _ = a.subtract(0, 0, 10, 10);
    _ = a.add(0, 0, 10, 10);
    try std.testing.expect(a.contains(5, 5));
    // empty rects are no-ops; INT32_MAX sizes saturate instead of wrapping
    try std.testing.expect(a.add(0, 0, 0, 10) and a.add(0, 0, 10, -1));
    try std.testing.expectEqual(@as(usize, 1), a.slice().len);
    var big: Region = .{};
    _ = big.add(-5, -5, std.math.maxInt(i32), std.math.maxInt(i32));
    try std.testing.expect(big.contains(-5, -5) and big.contains(1 << 30, 1 << 30));
    // over capacity: an add becomes the bounding box, a subtract is dropped
    var many: Region = .{};
    var i: i32 = 0;
    while (i < Region.max) : (i += 1) try std.testing.expect(many.add(i * 10, 0, 5, 5));
    try std.testing.expect(!many.add(1000, 1000, 5, 5));
    try std.testing.expectEqual(@as(usize, 1), many.slice().len);
    try std.testing.expect(many.contains(7, 2) and many.contains(1004, 1004));
    var comb: Region = .{};
    i = 0;
    while (i < Region.max) : (i += 1) _ = comb.add(i * 10, 0, 5, 5);
    try std.testing.expect(!comb.subtract(-10, 1, 1000, 1)); // would split every box in three
    try std.testing.expectEqual(@as(usize, Region.max), comb.slice().len);
    try std.testing.expect(comb.contains(2, 1));
}

test "set_input_region: copied at request time, double-buffered, NULL = infinite; the embedder hears changes" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.input_region_fn = TestSink.inputRegion;

    const surf = comptime protocol.find("wl_surface").?;
    const commit_op = comptime surf.requestIndex("commit").?;
    const input_op = comptime surf.requestIndex("set_input_region").?;
    const create_region_op = comptime protocol.find("wl_compositor").?.requestIndex("create_region").?;
    const reg = comptime protocol.find("wl_region").?;
    const add_op = comptime reg.requestIndex("add").?;
    const sub_op = comptime reg.requestIndex("subtract").?;
    const rect = struct {
        fn args(x: i32, y: i32, w: i32, h: i32) [4]wire.Value {
            return .{ .{ .int = x }, .{ .int = y }, .{ .int = w }, .{ .int = h } };
        }
    };

    try wmBaseToplevel(&comp, 1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{})); // initial commit
    try std.testing.expectEqual(@as(u32, 0), sink.region_calls); // infinite from the start, nothing to say

    // GTK's shape: the frame plus a resize margin inside a shadow, built
    // with add then subtract (the shadow corners)
    try comp.onWire(1, wire.encodeMessage(&buf, 3, create_region_op, &.{.{ .new_id = 20 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 20, add_op, &rect.args(14, 11, 824, 630)));
    try comp.onWire(1, wire.encodeMessage(&buf, 20, sub_op, &rect.args(14, 11, 4, 4)));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, input_op, &.{.{ .object = 20 }}));
    // the client changes and destroys the region before committing: the
    // surface keeps the copy taken at set_input_region
    try comp.onWire(1, wire.encodeMessage(&buf, 20, add_op, &rect.args(0, 0, 852, 652)));
    try comp.onWire(1, wire.encodeMessage(&buf, 20, 0, &.{})); // wl_region.destroy
    try std.testing.expectEqual(@as(u32, 0), sink.region_calls); // pending until commit
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 1), sink.region_calls);
    try std.testing.expectEqual(@as(u32, 6), sink.region_surface);
    {
        const r = sink.region.?;
        try std.testing.expect(r.contains(20, 20) and r.contains(837, 640));
        try std.testing.expect(!r.contains(5, 5)); // the shadow
        try std.testing.expect(!r.contains(15, 12)); // the subtracted corner
        try std.testing.expect(!r.contains(840, 645)); // not the later add either
    }
    try std.testing.expect(!comp.conns.get(1).?.regions.contains(20));

    // a commit that doesn't touch the region, or sets an equal one, is silent
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, create_region_op, &.{.{ .new_id = 21 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 21, add_op, &rect.args(14, 11, 824, 630)));
    try comp.onWire(1, wire.encodeMessage(&buf, 21, sub_op, &rect.args(14, 11, 4, 4)));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, input_op, &.{.{ .object = 21 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 1), sink.region_calls);

    // an empty region: no input at all
    try comp.onWire(1, wire.encodeMessage(&buf, 3, create_region_op, &.{.{ .new_id = 22 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, input_op, &.{.{ .object = 22 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 2), sink.region_calls);
    try std.testing.expectEqual(@as(usize, 0), sink.region.?.slice().len);

    // NULL: back to infinite, on commit
    try comp.onWire(1, wire.encodeMessage(&buf, 6, input_op, &.{.{ .object = 0 }}));
    try std.testing.expectEqual(@as(u32, 2), sink.region_calls);
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 3), sink.region_calls);
    try std.testing.expect(sink.region == null);

    // the last set_input_region before a commit wins
    try comp.onWire(1, wire.encodeMessage(&buf, 6, input_op, &.{.{ .object = 21 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, input_op, &.{.{ .object = 0 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 3), sink.region_calls);

    // regions die with their conn (testing.allocator checks the leak)
    try comp.onWire(1, wire.encodeMessage(&buf, 3, create_region_op, &.{.{ .new_id = 23 }}));
}

test "window geometry: set_window_geometry is the box (shadows outside), latched by commit" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const commit_op = comptime protocol.find("wl_surface").?.requestIndex("commit").?;
    const geom_op = comptime protocol.find("xdg_surface").?.requestIndex("set_window_geometry").?;
    const tl = comptime protocol.find("xdg_toplevel").?;

    try wmBaseToplevel(&comp, 1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{})); // initial commit
    comp.noteBufferSize(1, 6, 852, 652); // an 800x600 window inside 26 px of shadow

    // pending until the surface commits
    try comp.onWire(1, wire.encodeMessage(&buf, 7, geom_op, &.{ .{ .int = 26 }, .{ .int = 23 }, .{ .int = 800 }, .{ .int = 600 } }));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 852, .h = 652 }, comp.windowGeometry(1, 6));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(Rect{ .x = 26, .y = 23, .w = 800, .h = 600 }, comp.windowGeometry(1, 6));

    // the restore size is the geometry's, not the buffer's
    comp.noteBufferSize(1, 6, 852, 652);
    try comp.onWire(1, wire.encodeMessage(&buf, 8, comptime tl.requestIndex("set_maximized").?, &.{}));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, comptime tl.requestIndex("unset_maximized").?, &.{}));
    try std.testing.expectEqual([2]i32{ 800, 600 }, try lastConfigureSize(&sink));

    // a size that is not positive is a protocol error (invalid_size)
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 7, geom_op, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .int = 600 } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    {
        var vals: [wire.max_args]wire.Value = undefined;
        const ev = sink.events.items[0];
        try std.testing.expectEqual(@as(u32, 1), ev.object_id); // wl_display.error
        const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals);
        try std.testing.expectEqual(@as(u32, 7), a[0].object);
        try std.testing.expectEqual(xdg_surface_err_invalid_size, a[1].uint);
    }
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(Rect{ .x = 26, .y = 23, .w = 800, .h = 600 }, comp.windowGeometry(1, 6)); // unchanged

    // it is xdg_surface state: gone with the xdg_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 0, &.{})); // xdg_toplevel.destroy
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 0, &.{})); // xdg_surface.destroy
    comp.noteBufferSize(1, 6, 400, 300);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 400, .h = 300 }, comp.windowGeometry(1, 6));
}

test "xdg_wm_base v6: suspended state set/cleared on visibility change" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try wmBaseToplevel(&comp, 1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 6, &.{})); // first commit → mapped
    comp.noteBufferSize(1, 6, 800, 600); // a floating size to restore into
    sink.events.clearRetainingCapacity();

    const tl = comptime protocol.find("xdg_toplevel").?;
    const cfg_op = comptime tl.eventIndex("configure").?;

    // hide → configure carries [suspended] (it holds no keyboard: not activated)
    comp.setSuspended(true);
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // toplevel + xdg_surface
    try std.testing.expectEqual(cfg_op, sink.events.items[0].opcode);
    var vals: [wire.max_args]wire.Value = undefined;
    const c1 = sink.events.items[0];
    const c1a = try wire.decodeArgs(c1.bytes[wire.header_size..c1.len], &.{ .int, .int, .array }, &vals);
    try std.testing.expectEqual(@as(i32, 800), c1a[0].int); // floating size
    try std.testing.expectEqual(@as(usize, 4), c1a[2].array.len);
    try std.testing.expectEqual(Compositor.state_suspended, std.mem.readInt(u32, c1a[2].array[0..4], .little));

    // idempotent: hiding again does nothing
    sink.events.clearRetainingCapacity();
    comp.setSuspended(true);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // show → configure with the suspended state gone
    comp.setSuspended(false);
    const c2 = sink.events.items[0];
    const c2a = try wire.decodeArgs(c2.bytes[wire.header_size..c2.len], &.{ .int, .int, .array }, &vals);
    try std.testing.expectEqual(@as(usize, 0), c2a[2].array.len);
}

/// Window-state tests: a v6 toplevel (wmBaseToplevel: surface 6,
/// xdg_surface 7, toplevel 8) mapped with an 800×600 buffer (its box) on a
/// 1500×950 desktop, interactive_fn recorded.
const WinTest = struct {
    const tl = protocol.find("xdg_toplevel").?;
    const surf = protocol.find("wl_surface").?;
    const cfg_ev = tl.eventIndex("configure").?;
    const caps_ev = tl.eventIndex("wm_capabilities").?;
    const bounds_ev = tl.eventIndex("configure_bounds").?;
    const xdg_cfg_ev = protocol.find("xdg_surface").?.eventIndex("configure").?;
    const commit_op = surf.requestIndex("commit").?;
    const attach_op = surf.requestIndex("attach").?;
    const frame_op = surf.requestIndex("frame").?;
    const M = Compositor.state_maximized;
    const F = Compositor.state_fullscreen;
    const A = Compositor.state_activated;
    const S = Compositor.state_suspended;

    fn setup(comp: *Compositor, sink: *TestSink) !void {
        comp.interactive_fn = TestSink.interactive;
        comp.desk_w = 1500;
        comp.desk_h = 950;
        try wmBaseToplevel(comp, 1);
        try send(comp, 6, commit_op, &.{}); // initial commit
        try send(comp, 6, attach_op, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } });
        try send(comp, 6, commit_op, &.{});
        comp.noteBufferSize(1, 6, 800, 600);
        sink.events.clearRetainingCapacity();
    }
    fn send(comp: *Compositor, obj: u32, op: u16, args: []const wire.Value) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, obj, op, args));
    }
    /// A left-button press held on the toplevel (wl_seat 9, wl_pointer 10
    /// bound on first use): its serial, what move/resize must name.
    fn press(comp: *Compositor) !u32 {
        if (comp.conns.get(1).?.pointers.len == 0) {
            try send(comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
            try send(comp, 9, 0, &.{.{ .new_id = 10 }}); // get_pointer
        }
        comp.pointerEnter(1, 6, 0, 0);
        comp.pointerButton(1, 0, 0x110, true);
        return comp.conns.get(1).?.serial;
    }
    fn req(comp: *Compositor, comptime name: []const u8) !void {
        const op = comptime tl.requestIndex(name).?;
        if (comptime std.mem.eql(u8, name, "set_fullscreen")) return send(comp, 8, op, &.{.{ .object = 0 }});
        return send(comp, 8, op, &.{});
    }
    /// the toplevel configures since the last clear (each followed by its
    /// xdg_surface.configure); the last one is w×h with exactly `states`
    fn expectConfigure(sink: *TestSink, n: usize, w: i32, h: i32, states: []const u32) !void {
        var vals: [wire.max_args]wire.Value = undefined;
        var count: usize = 0;
        var last: ?[2]i32 = null;
        var got: [8]u32 = undefined;
        var got_n: usize = 0;
        for (sink.events.items, 0..) |ev, i| {
            if (ev.object_id != 8 or ev.opcode != cfg_ev) continue;
            count += 1;
            const next = sink.events.items[i + 1];
            try std.testing.expect(next.object_id == 7 and next.opcode == xdg_cfg_ev);
            const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .int, .int, .array }, &vals);
            last = .{ a[0].int, a[1].int };
            got_n = a[2].array.len / 4;
            for (0..got_n) |k| got[k] = std.mem.readInt(u32, a[2].array[k * 4 ..][0..4], .little);
        }
        try std.testing.expectEqual(n, count);
        try std.testing.expectEqual([2]i32{ w, h }, last.?);
        try std.testing.expectEqualSlices(u32, states, got[0..got_n]);
        sink.events.clearRetainingCapacity();
    }
};

test "lock modifiers: NumLock (Mod2) starts locked; Caps Lock / NumLock keys toggle them; keyboardLocks sets both seat-wide, sent only on change" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, 1, &.{.{ .new_id = 11 }}); // get_keyboard
    const mods_ev = comptime protocol.find("wl_keyboard").?.eventIndex("modifiers").?;
    const S = struct {
        // the `locked` arg of each wl_keyboard.modifiers since the last clear
        fn locked(sink_: *TestSink, out: []u32) !usize {
            var vals: [wire.max_args]wire.Value = undefined;
            var n: usize = 0;
            for (sink_.events.items) |ev| {
                if (ev.object_id != 11 or ev.opcode != mods_ev) continue;
                const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .uint, .uint, .uint, .uint, .uint }, &vals);
                out[n] = a[3].uint;
                n += 1;
            }
            sink_.events.clearRetainingCapacity();
            return n;
        }
    };
    var got: [8]u32 = undefined;
    const lock: u32 = 1 << 1;
    const num: u32 = 1 << 4; // Mod2: us.xkb `modifier_map Mod2 { <NMLK> }`
    sink.events.clearRetainingCapacity();
    comp.keyboardEnter(1, 6);
    try std.testing.expectEqualSlices(u32, &.{num}, got[0..try S.locked(&sink, &got)]);
    comp.keyboardKey(1, 0, 58, true); // Caps Lock
    comp.keyboardKey(1, 0, 58, false);
    comp.keyboardKey(1, 0, 69, true); // NumLock
    comp.keyboardKey(1, 0, 69, false);
    comp.keyboardKey(1, 0, 71, true); // KP7: no modifier change
    try std.testing.expectEqualSlices(u32, &.{ num | lock, lock }, got[0..try S.locked(&sink, &got)]);
    // lockState follows the keys' toggles (what an embedder carries over a link reopen)
    try std.testing.expectEqual(true, comp.lockState().caps_lock);
    try std.testing.expectEqual(false, comp.lockState().num_lock);
    // the browser's state: unchanged → nothing; changed → one modifiers event
    comp.keyboardLocks(true, false);
    try std.testing.expectEqual(@as(usize, 0), try S.locked(&sink, &got));
    comp.keyboardLocks(false, true);
    try std.testing.expectEqualSlices(u32, &.{num}, got[0..try S.locked(&sink, &got)]);
    try std.testing.expectEqual(false, comp.lockState().caps_lock);
    try std.testing.expectEqual(true, comp.lockState().num_lock);
    // seat-wide: set while unfocused, a later enter carries it
    comp.keyboardLeave(1);
    sink.events.clearRetainingCapacity();
    comp.keyboardLocks(true, true);
    try std.testing.expectEqual(@as(usize, 0), try S.locked(&sink, &got));
    comp.keyboardEnter(1, 6);
    try std.testing.expectEqualSlices(u32, &.{ num | lock }, got[0..try S.locked(&sink, &got)]);
}

test "activated follows keyboard focus, in a configure that repeats the size; a size on its way is not read back" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, 1, &.{.{ .new_id = 11 }}); // get_keyboard
    sink.events.clearRetainingCapacity();

    comp.keyboardEnter(1, 6);
    try T.expectConfigure(&sink, 1, 800, 600, &.{T.A});
    // every configure carries it meanwhile: a grip resize, maximize
    comp.requestResize(1, 6, 700, 500);
    try T.expectConfigure(&sink, 1, 700, 500, &.{T.A});
    // the client is still 800×600: a focus change now repeats 700×500
    comp.keyboardLeave(1);
    try T.expectConfigure(&sink, 1, 700, 500, &.{});
    // acked and committed: its geometry is the floating size again
    const ack_op = comptime protocol.find("xdg_surface").?.requestIndex("ack_configure").?;
    try T.send(&comp, 7, ack_op, &.{.{ .uint = comp.conns.get(1).?.serial }});
    try T.send(&comp, 6, T.commit_op, &.{});
    comp.noteBufferSize(1, 6, 704, 496); // what it made of it (cell-rounded)
    sink.events.clearRetainingCapacity();
    comp.keyboardEnter(1, 6);
    try T.expectConfigure(&sink, 1, 704, 496, &.{T.A});
    try T.req(&comp, "set_maximized");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{ T.M, T.A });
    comp.keyboardLeave(1);
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.M});
}

test "attach(NULL) + commit unmaps: the embedder hears role none; a toplevel starts over with an initial configure" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    comp.surface_fn = TestSink.surfaceEvent;
    // a subsurface (10, role object 11) of the toplevel, with content
    try T.send(&comp, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 5 } } });
    try T.send(&comp, 3, 0, &.{.{ .new_id = 10 }});
    try T.send(&comp, 5, 1, &.{ .{ .new_id = 11 }, .{ .object = 10 }, .{ .object = 6 } });
    try T.send(&comp, 10, T.attach_op, &.{ .{ .object = 31 }, .{ .int = 0 }, .{ .int = 0 } });
    try T.send(&comp, 10, T.commit_op, &.{});

    // a commit that keeps the buffer says nothing
    var calls = sink.surf_calls;
    try T.send(&comp, 10, T.commit_op, &.{});
    try std.testing.expectEqual(calls, sink.surf_calls);
    // attach(NULL) + commit: unmapped, the role (and its object) kept
    try T.send(&comp, 10, T.attach_op, &.{ .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } });
    try T.send(&comp, 10, T.commit_op, &.{});
    try std.testing.expectEqual(calls + 1, sink.surf_calls);
    try std.testing.expectEqual([2]u32{ 10, @intFromEnum(Role.none) }, [2]u32{ sink.surf_id, sink.surf_value });
    try std.testing.expectEqual(Role.subsurface, comp.surfaceRole(1, 10));
    // again without content: nothing more to say
    try T.send(&comp, 10, T.commit_op, &.{});
    try std.testing.expectEqual(calls + 1, sink.surf_calls);

    // the toplevel: maximized, then unmapped — states gone, and its next
    // commit gets an initial configure (0×0, no states)
    try T.req(&comp, "set_maximized");
    calls = sink.surf_calls;
    try T.send(&comp, 6, T.attach_op, &.{ .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } });
    try T.send(&comp, 6, T.commit_op, &.{});
    try std.testing.expectEqual(calls + 1, sink.surf_calls);
    try std.testing.expectEqual([2]u32{ 6, @intFromEnum(Role.none) }, [2]u32{ sink.surf_id, sink.surf_value });
    try std.testing.expectEqual(@as(u32, 0), comp.toplevelState(1, 6));
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 6, T.commit_op, &.{});
    try T.expectConfigure(&sink, 1, 0, 0, &.{});

    // a destroyed parent unmaps its subsurfaces for good
    try T.send(&comp, 10, T.attach_op, &.{ .{ .object = 31 }, .{ .int = 0 }, .{ .int = 0 } });
    try T.send(&comp, 10, T.commit_op, &.{});
    try T.send(&comp, 6, comptime T.surf.requestIndex("destroy").?, &.{});
    try std.testing.expectEqual(Role.none, comp.surfaceRole(1, 10));
    try std.testing.expectEqual(@as(u32, 10), comp.surfaceRoot(1, 10));
}

test "fullscreen: the configure carries the state and the desktop size; move/resize ignored meanwhile; unset restores the floating size" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);

    try T.req(&comp, "set_fullscreen");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.F});
    try std.testing.expectEqual(@as(u32, 6), sink.inter_kind);
    try std.testing.expectEqual(Compositor.toplevel_fullscreen, comp.toplevelState(1, 6));

    // move/resize requests and grip resizes are ignored while fullscreen
    const held = try T.press(&comp);
    sink.events.clearRetainingCapacity();
    const calls = sink.inter_calls;
    try T.send(&comp, 8, comptime T.tl.requestIndex("move").?, &.{ .{ .object = 0 }, .{ .uint = held } });
    try T.send(&comp, 8, comptime T.tl.requestIndex("resize").?, &.{ .{ .object = 0 }, .{ .uint = held }, .{ .uint = 10 } });
    comp.requestResize(1, 6, 500, 400);
    try std.testing.expectEqual(calls, sink.inter_calls);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // the fullscreen buffer is not a floating size; a repeated set is still
    // answered (no state change to tell)
    comp.noteBufferSize(1, 6, 1500, 950);
    try T.req(&comp, "set_fullscreen");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.F});
    try std.testing.expectEqual(calls, sink.inter_calls);

    try T.req(&comp, "unset_fullscreen");
    try T.expectConfigure(&sink, 1, 800, 600, &.{});
    try std.testing.expectEqual(@as(u32, 7), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 0), comp.toplevelState(1, 6));
    try T.send(&comp, 8, comptime T.tl.requestIndex("move").?, &.{ .{ .object = 0 }, .{ .uint = held } });
    try std.testing.expectEqual(@as(u32, 0), sink.inter_kind); // moves again

    // the embedder's way in and out: the same configures
    comp.noteBufferSize(1, 6, 800, 600);
    comp.setFullscreen(1, 6, true);
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.F});
    try std.testing.expectEqual(@as(u32, 6), sink.inter_kind);
    comp.setFullscreen(1, 6, false);
    try T.expectConfigure(&sink, 1, 800, 600, &.{});
    comp.setFullscreen(1, 99, true); // not a toplevel: nothing
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

test "fullscreen and maximized coexist: unset_fullscreen goes back to maximized, unmaximize to the size from before both" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);

    // maximized, then fullscreen on top of it
    try T.req(&comp, "set_maximized");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.M});
    comp.noteBufferSize(1, 6, 1500, 950);
    try T.req(&comp, "set_fullscreen");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{ T.M, T.F });
    try std.testing.expectEqual(Compositor.toplevel_maximized | Compositor.toplevel_fullscreen, comp.toplevelState(1, 6));
    try T.req(&comp, "unset_fullscreen");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.M});
    try std.testing.expectEqual(@as(u32, 7), sink.inter_kind);
    try T.req(&comp, "unset_maximized");
    try T.expectConfigure(&sink, 1, 800, 600, &.{});
    try std.testing.expectEqual(@as(u32, 3), sink.inter_kind);

    // fullscreen first; set_maximized meanwhile has "no direct effect" (the
    // size stays the fullscreen one) but is where unset_fullscreen goes
    comp.noteBufferSize(1, 6, 800, 600);
    try T.req(&comp, "set_fullscreen");
    comp.noteBufferSize(1, 6, 1500, 950);
    sink.events.clearRetainingCapacity();
    try T.req(&comp, "set_maximized");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{ T.M, T.F });
    try std.testing.expectEqual(@as(u32, 2), sink.inter_kind);
    try T.req(&comp, "unset_fullscreen");
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.M});
    try T.req(&comp, "unset_maximized");
    try T.expectConfigure(&sink, 1, 800, 600, &.{});

    // unset_maximized while not maximized: still a configure (spec), no change told
    const calls = sink.inter_calls;
    try T.req(&comp, "unset_maximized");
    try T.expectConfigure(&sink, 1, 800, 600, &.{});
    try std.testing.expectEqual(calls, sink.inter_calls);

    // a new xdg_toplevel on the wl_surface starts with none of it
    try T.req(&comp, "set_fullscreen");
    try T.send(&comp, 8, 0, &.{}); // xdg_toplevel.destroy
    try T.send(&comp, 7, 1, &.{.{ .new_id = 9 }}); // get_toplevel
    try std.testing.expectEqual(@as(u32, 0), comp.toplevelState(1, 6));
}

test "fullscreen before the first commit: no configure until then; the initial one is fullscreen, after wm_capabilities" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.interactive_fn = TestSink.interactive;
    comp.desk_w = 1500;
    comp.desk_h = 950;
    try wmBaseToplevel(&comp, 1);
    sink.events.clearRetainingCapacity();

    try T.req(&comp, "set_fullscreen");
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 6), sink.inter_kind); // the embedder is told at once
    // minimizing an unmapped window: ignored
    const calls = sink.inter_calls;
    try T.req(&comp, "set_minimized");
    try std.testing.expectEqual(calls, sink.inter_calls);

    try T.send(&comp, 6, T.commit_op, &.{});
    const want = [_][2]u32{ .{ 8, T.caps_ev }, .{ 8, T.bounds_ev }, .{ 8, T.cfg_ev }, .{ 7, T.xdg_cfg_ev } };
    try std.testing.expectEqual(want.len, sink.events.items.len);
    for (want, sink.events.items) |w, ev| try std.testing.expectEqual(w, [2]u32{ ev.object_id, ev.opcode });
    try T.expectConfigure(&sink, 1, 1500, 950, &.{T.F});

    // it never floated: unfullscreen lets the client pick its size
    try T.req(&comp, "unset_fullscreen");
    try T.expectConfigure(&sink, 1, 0, 0, &.{});
}

test "desktop resize reconfigures fullscreen and maximized toplevels (bounds first), not floating ones" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);

    try T.req(&comp, "set_fullscreen");
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1000, 700);
    try std.testing.expectEqual(@as(u32, 8), sink.events.items[0].object_id);
    try std.testing.expectEqual(@as(u16, T.bounds_ev), sink.events.items[0].opcode);
    try T.expectConfigure(&sink, 1, 1000, 700, &.{T.F});

    try T.req(&comp, "set_maximized");
    try T.req(&comp, "unset_fullscreen");
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1100, 750);
    try T.expectConfigure(&sink, 1, 1100, 750, &.{T.M});

    try T.req(&comp, "unset_maximized");
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1200, 800);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // floating: left alone
}

test "minimize: pointer (unlocked first) and keyboard leave, popups dismissed, suspended; frame callbacks held, feedback discarded, input ignored; restore" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    comp.pointer_lock_fn = TestSink.pointerLock;

    const PTR = 10;
    const KBD = 11;
    const POPUP = 17;
    const LOCK = 20;
    const FEEDBACK = 19;
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, 0, &.{.{ .new_id = PTR }});
    try T.send(&comp, 9, 1, &.{.{ .new_id = KBD }});
    try T.send(&comp, 2, 0, &.{ .{ .uint = 16 }, .{ .new_id_dynamic = .{ .interface = "zwp_pointer_constraints_v1", .version = 1, .id = 12 } } });
    try T.send(&comp, 2, 0, &.{ .{ .uint = 18 }, .{ .new_id_dynamic = .{ .interface = "wp_presentation", .version = 1, .id = 13 } } });
    // a popup of the window: positioner 14, surface 15, xdg_surface 16, popup 17
    const pos = comptime protocol.find("xdg_positioner").?;
    try T.send(&comp, 4, comptime protocol.find("xdg_wm_base").?.requestIndex("create_positioner").?, &.{.{ .new_id = 14 }});
    try T.send(&comp, 14, comptime pos.requestIndex("set_size").?, &.{ .{ .int = 50 }, .{ .int = 40 } });
    try T.send(&comp, 14, comptime pos.requestIndex("set_anchor_rect").?, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } });
    try T.send(&comp, 3, 0, &.{.{ .new_id = 15 }});
    try T.send(&comp, 4, 2, &.{ .{ .new_id = 16 }, .{ .object = 15 } });
    try T.send(&comp, 16, comptime protocol.find("xdg_surface").?.requestIndex("get_popup").?, &.{ .{ .new_id = POPUP }, .{ .object = 7 }, .{ .object = 14 } });
    try T.send(&comp, 15, T.commit_op, &.{});
    // a persistent lock on the window, granted; keyboard focus on it
    try T.send(&comp, 12, comptime protocol.find("zwp_pointer_constraints_v1").?.requestIndex("lock_pointer").?, &.{
        .{ .new_id = LOCK }, .{ .object = 6 }, .{ .object = PTR }, .{ .object = 0 }, .{ .uint = 2 },
    });
    comp.pointerEnter(1, 6, 10 * 256, 10 * 256);
    comp.pointerLockGranted(1, 6);
    comp.keyboardEnter(1, 6);
    // a frame callback and a feedback latched by a commit
    try T.send(&comp, 6, T.frame_op, &.{.{ .new_id = 18 }});
    try T.send(&comp, 13, comptime protocol.find("wp_presentation").?.requestIndex("feedback").?, &.{ .{ .object = 6 }, .{ .new_id = FEEDBACK } });
    try T.send(&comp, 6, T.commit_op, &.{});
    sink.events.clearRetainingCapacity();

    comp.setMinimized(1, 6, true);
    const ptr = comptime protocol.find("wl_pointer").?;
    const want = [_][2]u32{
        .{ LOCK, comptime protocol.find("zwp_locked_pointer_v1").?.eventIndex("unlocked").? },
        .{ PTR, comptime ptr.eventIndex("leave").? },
        .{ PTR, comptime ptr.eventIndex("frame").? },
        .{ KBD, comptime protocol.find("wl_keyboard").?.eventIndex("leave").? },
        .{ 8, T.cfg_ev }, // no longer activated, and suspended
        .{ 7, T.xdg_cfg_ev },
        .{ POPUP, comptime protocol.find("xdg_popup").?.eventIndex("popup_done").? },
    };
    try std.testing.expectEqual(want.len, sink.events.items.len);
    for (want, sink.events.items) |w, ev| try std.testing.expectEqual(w, [2]u32{ ev.object_id, ev.opcode });
    try T.expectConfigure(&sink, 1, 800, 600, &.{T.S});
    try std.testing.expectEqual(@as(u32, 8), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface); // the embedder lets the browser's lock go
    try std.testing.expectEqual(Compositor.toplevel_minimized, comp.toplevelState(1, 6));

    // hidden: the frame callback waits, the feedback is discarded; input
    // aimed at it is dropped; minimizing again is a no-op
    comp.tick(.{ .time_ms = 100 });
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // discarded + delete_id
    try std.testing.expectEqual(@as(u32, FEEDBACK), sink.events.items[0].object_id);
    try std.testing.expectEqual(@as(u16, comptime protocol.find("wp_presentation_feedback").?.eventIndex("discarded").?), sink.events.items[0].opcode);
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(1, 6, 0, 0);
    comp.keyboardEnter(1, 6);
    comp.pointerEnter(1, 15, 0, 0); // its popup's surface too
    comp.setMinimized(1, 6, true);
    try T.req(&comp, "set_minimized");
    comp.tick(.{ .time_ms = 116 });
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // restored: suspended goes, the held callback fires at the next tick,
    // the pointer may come back (and the persistent lock is wanted again)
    comp.setMinimized(1, 6, false);
    try T.expectConfigure(&sink, 1, 800, 600, &.{});
    try std.testing.expectEqual(@as(u32, 9), sink.inter_kind);
    comp.tick(.{ .time_ms = 132 });
    try std.testing.expectEqual(@as(u32, 18), sink.events.items[0].object_id); // wl_callback.done
    comp.pointerEnter(1, 6, 10 * 256, 10 * 256);
    try std.testing.expectEqual(@as(u32, 6), sink.lock_surface);

    // the app's own set_minimized does the same; the tab being hidden
    // meanwhile doesn't touch it, and showing the tab keeps it suspended
    sink.events.clearRetainingCapacity();
    try T.req(&comp, "set_minimized");
    try std.testing.expectEqual(@as(u32, 8), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
    sink.events.clearRetainingCapacity();
    comp.setSuspended(true);
    comp.setSuspended(false);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    comp.setMinimized(1, 6, false);
    try T.expectConfigure(&sink, 1, 800, 600, &.{});
}

test "pointer: an enter only ever follows a leave — a repeated one is dropped, another surface's gets the leave first" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);

    const PTR = 10;
    const ptr = comptime protocol.find("wl_pointer").?;
    const enter_op = comptime ptr.eventIndex("enter").?;
    const leave_op = comptime ptr.eventIndex("leave").?;
    const frame_op = comptime ptr.eventIndex("frame").?;
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, 0, &.{.{ .new_id = PTR }});
    // a popup of the window (surface 15), mapped
    try PopupTest.positioner(&comp, 14, 10, 10, .{ 8, 8 }, 50, 40);
    try PopupTest.popup(&comp, 15, 7, 14);
    try T.send(&comp, 15, T.attach_op, &.{ .{ .object = 31 }, .{ .int = 0 }, .{ .int = 0 } });
    try T.send(&comp, 15, T.commit_op, &.{});
    sink.events.clearRetainingCapacity();

    comp.pointerEnter(1, 6, 10 * 256, 10 * 256);
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // enter, frame
    try std.testing.expectEqual(enter_op, sink.events.items[0].opcode);
    const serial = comp.conns.get(1).?.pointer_enter_serial;
    comp.pointerButton(1, 0, 0x110, true);
    sink.events.clearRetainingCapacity();

    // the same surface again (an embedder's re-enter at a grab's end, then
    // the browser's pointerover): nothing, and the press is still held
    comp.pointerEnter(1, 6, 20 * 256, 20 * 256);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expectEqual(serial, comp.conns.get(1).?.pointer_enter_serial);
    try std.testing.expect(comp.conns.get(1).?.buttons_held != 0);

    // another surface of the client with no leave asked: leave, then enter
    comp.pointerEnter(1, 15, 256, 256);
    var vals: [wire.max_args]wire.Value = undefined;
    const want = [_]struct { u16, u32 }{ .{ leave_op, 6 }, .{ frame_op, 0 }, .{ enter_op, 15 }, .{ frame_op, 0 } };
    try std.testing.expectEqual(want.len, sink.events.items.len);
    for (want, sink.events.items) |w, ev| {
        try std.testing.expectEqual(@as(u32, PTR), ev.object_id);
        try std.testing.expectEqual(w[0], ev.opcode);
        if (w[1] != 0) {
            const args = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .uint, .object }, &vals);
            try std.testing.expectEqual(w[1], args[1].object);
        }
    }
    try std.testing.expectEqual(@as(u32, 15), comp.conns.get(1).?.pointer_focus);
}

test "hidden by the embedder: suspended, frame callbacks held and feedback discarded (popups too), no focus change, popups kept, input delivered, not minimized; shown again" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);

    const PTR = 10;
    const KBD = 11;
    const FEEDBACK = 19;
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, 0, &.{.{ .new_id = PTR }});
    try T.send(&comp, 9, 1, &.{.{ .new_id = KBD }});
    try T.send(&comp, 2, 0, &.{ .{ .uint = 18 }, .{ .new_id_dynamic = .{ .interface = "wp_presentation", .version = 1, .id = 13 } } });
    // a popup of the window (surface 15), mapped
    try PopupTest.positioner(&comp, 14, 10, 10, .{ 8, 8 }, 50, 40);
    try PopupTest.popup(&comp, 15, 7, 14);
    try T.send(&comp, 15, T.attach_op, &.{ .{ .object = 31 }, .{ .int = 0 }, .{ .int = 0 } });
    try T.send(&comp, 15, T.commit_op, &.{});
    comp.pointerEnter(1, 6, 10 * 256, 10 * 256);
    comp.keyboardEnter(1, 6);
    // frame callbacks on the toplevel and the popup, a feedback, latched
    try T.send(&comp, 6, T.frame_op, &.{.{ .new_id = 18 }});
    try T.send(&comp, 15, T.frame_op, &.{.{ .new_id = 20 }});
    try T.send(&comp, 13, comptime protocol.find("wp_presentation").?.requestIndex("feedback").?, &.{ .{ .object = 6 }, .{ .new_id = FEEDBACK } });
    try T.send(&comp, 6, T.commit_op, &.{});
    try T.send(&comp, 15, T.commit_op, &.{});
    sink.events.clearRetainingCapacity();
    const inter_calls = sink.inter_calls;

    // hidden: one configure, still activated, now suspended; nothing else
    comp.setVisible(1, 6, false);
    try T.expectConfigure(&sink, 1, 800, 600, &.{ T.A, T.S });
    try std.testing.expectEqual(inter_calls, sink.inter_calls); // no state event
    try std.testing.expectEqual(@as(u32, 0), comp.toplevelState(1, 6)); // not minimized
    try std.testing.expectEqual(@as(u32, 6), comp.conns.get(1).?.keyboard_focus);
    try std.testing.expectEqual(@as(u32, 6), comp.conns.get(1).?.pointer_focus);
    comp.setVisible(1, 6, false); // again: nothing
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    // the tick: the feedback is discarded, both callbacks wait
    comp.tick(.{ .time_ms = 100 });
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // discarded + delete_id
    try std.testing.expectEqual(@as(u32, FEEDBACK), sink.events.items[0].object_id);
    sink.events.clearRetainingCapacity();
    // input still goes where the embedder sends it
    comp.keyboardKey(1, 0, 30, true);
    try std.testing.expectEqual(@as(u32, KBD), sink.events.items[0].object_id);
    comp.keyboardKey(1, 0, 30, false);
    sink.events.clearRetainingCapacity();
    // the tab hidden and shown meanwhile: it stays suspended
    comp.setSuspended(true);
    comp.setSuspended(false);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // shown: suspended goes, both held callbacks fire at the next tick
    comp.setVisible(1, 6, true);
    try T.expectConfigure(&sink, 1, 800, 600, &.{T.A});
    comp.tick(.{ .time_ms = 116 });
    var fired: usize = 0;
    for (sink.events.items) |ev| {
        if (ev.object_id == 18 or ev.object_id == 20) fired += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fired);

    // hidden and minimized: restoring keeps it suspended until it is shown
    comp.setVisible(1, 6, false);
    comp.setMinimized(1, 6, true);
    comp.setMinimized(1, 6, false);
    sink.events.clearRetainingCapacity();
    comp.setMinimized(1, 6, true);
    comp.setMinimized(1, 6, false);
    try T.expectConfigure(&sink, 2, 800, 600, &.{T.S});
    // a new embedder (a session viewer's init) shows it
    comp.resetEmbedderWindows();
    try T.expectConfigure(&sink, 1, 800, 600, &.{});

    // hidden before its initial commit: the initial configure carries it
    try wmBaseToplevel(&comp, 2);
    comp.setVisible(2, 6, false);
    sink.events.clearRetainingCapacity();
    var buf: [64]u8 = undefined;
    try comp.onWire(2, wire.encodeMessage(&buf, 6, T.commit_op, &.{}));
    var states: ?[]const u8 = null;
    var vals: [wire.max_args]wire.Value = undefined;
    for (sink.events.items) |*ev| {
        if (ev.conn_id != 2 or ev.object_id != 8 or ev.opcode != T.cfg_ev) continue;
        states = (try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .int, .int, .array }, &vals))[2].array;
    }
    try std.testing.expectEqual(Compositor.state_suspended, std.mem.readInt(u32, states.?[0..4], .little));
}

test "tiled: setTiled sets the tiled_* states (v2+) in every configure, with activated and maximized alike; a size rides the same configure; the same edges send nothing; a new embedder untiles" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    const L = Compositor.state_tiled_left;
    const R = Compositor.state_tiled_right;
    const TP = Compositor.state_tiled_top;
    const B = Compositor.state_tiled_bottom;

    comp.setTiled(1, 6, edge_left | edge_top | 0x30, 0, 0); // stray bits dropped
    try T.expectConfigure(&sink, 1, 800, 600, &.{ L, TP });
    comp.setTiled(1, 6, edge_left | edge_top, 0, 0); // the same: nothing
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    // a snap: the edges and the size in one configure, clamped to the hints
    comp.conns.get(1).?.surfaces.getPtr(6).?.max_w = 700;
    comp.setTiled(1, 6, edge_right | edge_top | edge_bottom, 750, 950);
    try T.expectConfigure(&sink, 1, 700, 950, &.{ R, TP, B });
    // every other configure carries them: focus, maximize (independent)
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, 1, &.{.{ .new_id = 11 }});
    sink.events.clearRetainingCapacity();
    comp.keyboardEnter(1, 6);
    try T.expectConfigure(&sink, 1, 700, 950, &.{ T.A, R, TP, B });
    comp.setMaximized(1, 6, true);
    try T.expectConfigure(&sink, 1, 1500, 950, &.{ T.M, T.A, R, TP, B });
    // while maximized a size is the maximized one's; the edges still change
    comp.setTiled(1, 6, edge_left, 300, 300);
    try T.expectConfigure(&sink, 1, 1500, 950, &.{ T.M, T.A, L });
    comp.setMaximized(1, 6, false);
    try T.expectConfigure(&sink, 1, 700, 950, &.{ T.A, L });
    comp.setVisible(1, 6, false);
    try T.expectConfigure(&sink, 1, 700, 950, &.{ T.A, L, T.S });
    comp.setVisible(1, 6, true);
    sink.events.clearRetainingCapacity();
    // a new embedder untiles
    comp.resetEmbedderWindows();
    try T.expectConfigure(&sink, 1, 700, 950, &.{T.A});

    // a v1 client is never told: no configure for the edges alone, none in
    // its states; a size still goes out
    var sink_buf: [64]u8 = undefined;
    try wmBaseToplevelAt(&comp, 2, 1);
    try comp.onWire(2, wire.encodeMessage(&sink_buf, 6, T.commit_op, &.{}));
    sink.events.clearRetainingCapacity();
    comp.setTiled(2, 6, edge_left, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    comp.setTiled(2, 6, edge_right, 400, 300);
    try T.expectConfigure(&sink, 1, 400, 300, &.{});
    // set before the initial commit: the initial configure carries it
    try wmBaseToplevel(&comp, 3);
    comp.setTiled(3, 6, edge_bottom, 10, 10);
    sink.events.clearRetainingCapacity();
    try comp.onWire(3, wire.encodeMessage(&sink_buf, 6, T.commit_op, &.{}));
    try T.expectConfigure(&sink, 1, 0, 0, &.{B});
}

test "configure_fn: every toplevel configure with its serial, size, states and the embedder call's token; acked_fn at the commit that applies an ack — the configure acked, skipped ones included; none without an ack, an unknown serial or a second commit" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.configure_fn = TestSink.configure;
    comp.acked_fn = TestSink.ackedCb;
    try T.setup(&comp, &sink);
    const conn = comp.conns.get(1).?;
    const ack_op = comptime protocol.find("xdg_surface").?.requestIndex("ack_configure").?;

    // (the initial configure: 0×0, no cause)
    try std.testing.expectEqual(@as(u32, 1), sink.cfg_calls);
    try std.testing.expectEqual(@as(u32, 0), sink.cfg_cause);
    comp.cause = 41;
    comp.requestResize(1, 6, 700, 500);
    comp.cause = 0;
    const s1 = conn.serial;
    try std.testing.expectEqual(Configure{ .serial = s1, .w = 700, .h = 500, .states = 0 }, sink.cfg.?);
    try std.testing.expectEqual(@as(u32, 41), sink.cfg_cause);
    comp.cause = 42;
    comp.setTiled(1, 6, edge_left | edge_bottom, 640, 480);
    comp.cause = 0;
    const s2 = conn.serial;
    try std.testing.expectEqual(Configure{ .serial = s2, .w = 640, .h = 480, .states = (edge_left | edge_bottom) << configure_tiled_shift }, sink.cfg.?);
    try std.testing.expectEqual(@as(u32, 42), sink.cfg_cause);
    comp.setVisible(1, 6, false); // not a token call: cause 0
    try std.testing.expectEqual(@as(u32, 0), sink.cfg_cause);
    try std.testing.expectEqual(configure_suspended | (edge_left | edge_bottom) << configure_tiled_shift, sink.cfg.?.states);
    const s3 = conn.serial;

    // the app acks the middle one (it hadn't seen the last yet), commits
    try T.send(&comp, 7, ack_op, &.{.{ .uint = s2 }});
    try std.testing.expectEqual(@as(u32, 0), sink.acked_calls); // at the commit
    try T.send(&comp, 6, T.commit_op, &.{});
    try std.testing.expectEqual([3]u32{ s2, 640, 480 }, sink.acked.?);
    try T.send(&comp, 6, T.commit_op, &.{}); // no new ack: nothing
    try std.testing.expectEqual(@as(u32, 1), sink.acked_calls);
    // two acks before a commit: the last one counts (the first skipped)
    try T.send(&comp, 7, ack_op, &.{.{ .uint = s1 }});
    try T.send(&comp, 7, ack_op, &.{.{ .uint = s3 }});
    try T.send(&comp, 6, T.commit_op, &.{});
    try std.testing.expectEqual([3]u32{ s3, 640, 480 }, sink.acked.?);
    // a serial never sent (or long gone): nothing
    try T.send(&comp, 7, ack_op, &.{.{ .uint = s3 +% 1000 }});
    try T.send(&comp, 6, T.commit_op, &.{});
    try std.testing.expectEqual(@as(u32, 2), sink.acked_calls);
    // the ring keeps the recent ones: the 8th back is still known
    var serials: [8]u32 = undefined;
    for (&serials, 0..) |*sr, i| {
        comp.requestResize(1, 6, 300 + @as(i32, @intCast(i)), 200);
        sr.* = conn.serial;
    }
    try T.send(&comp, 7, ack_op, &.{.{ .uint = serials[0] }});
    try T.send(&comp, 6, T.commit_op, &.{});
    try std.testing.expectEqual([3]u32{ serials[0], 300, 200 }, sink.acked.?);
    // the xdg_toplevel goes: its configures with it
    try T.send(&comp, 7, ack_op, &.{.{ .uint = serials[7] }});
    try T.send(&comp, 8, comptime T.tl.requestIndex("destroy").?, &.{});
    try T.send(&comp, 6, T.commit_op, &.{});
    try std.testing.expectEqual(@as(u32, 3), sink.acked_calls);
}

test "xdg_popup.reposition emits repositioned + configure sequence" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    var buf: [128]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 6, .id = 5 } } }));
    // toplevel parent: surface 6, xdg_surface 7, toplevel 8, committed
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 6 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 2, &.{ .{ .new_id = 7 }, .{ .object = 6 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 1, &.{.{ .new_id = 8 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 6, &.{}));
    // positioner 9, popup surface 10 + xdg_surface 11 + popup 12
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 9 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 1, &.{ .{ .int = 100 }, .{ .int = 80 } })); // set_size
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 2, &.{ .{ .int = 10 }, .{ .int = 10 }, .{ .int = 4 }, .{ .int = 4 } })); // anchor_rect
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 3, &.{.{ .uint = 8 }})); // anchor bottom_right
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 4, &.{.{ .uint = 8 }})); // gravity bottom_right
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 10 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 2, &.{ .{ .new_id = 11 }, .{ .object = 10 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 2, &.{ .{ .new_id = 12 }, .{ .object = 7 }, .{ .object = 9 } })); // get_popup
    try comp.onWire(1, wire.encodeMessage(&buf, 10, 6, &.{})); // popup commit

    // reposition with a fresh positioner 13 (anchor rect at 200,150)
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 13 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 13, 1, &.{ .{ .int = 90 }, .{ .int = 70 } })); // set_size
    try comp.onWire(1, wire.encodeMessage(&buf, 13, 2, &.{ .{ .int = 200 }, .{ .int = 150 }, .{ .int = 6 }, .{ .int = 6 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 13, 3, &.{.{ .uint = 8 }})); // anchor bottom_right
    try comp.onWire(1, wire.encodeMessage(&buf, 13, 4, &.{.{ .uint = 8 }})); // gravity bottom_right

    const popup = comptime protocol.find("xdg_popup").?;
    const reposition_op = comptime popup.requestIndex("reposition").?;
    const repositioned_op = comptime popup.eventIndex("repositioned").?;
    const pcfg_op = comptime popup.eventIndex("configure").?;
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 12, reposition_op, &.{ .{ .object = 13 }, .{ .uint = 777 } }));

    // repositioned(777) → xdg_popup.configure(new pos/size) → xdg_surface.configure
    try std.testing.expectEqual(@as(usize, 3), sink.events.items.len);
    try std.testing.expectEqual(repositioned_op, sink.events.items[0].opcode);
    var vals: [wire.max_args]wire.Value = undefined;
    const rep = sink.events.items[0];
    const rep_args = try wire.decodeArgs(rep.bytes[wire.header_size..rep.len], &.{.uint}, &vals);
    try std.testing.expectEqual(@as(u32, 777), rep_args[0].uint);
    try std.testing.expectEqual(pcfg_op, sink.events.items[1].opcode);
    const pc = sink.events.items[1];
    const pc_args = try wire.decodeArgs(pc.bytes[wire.header_size..pc.len], &.{ .int, .int, .int, .int }, &vals);
    // anchor bottom_right of (200,150,6,6) = (206,156); gravity bottom_right
    try std.testing.expectEqual(@as(i32, 206), pc_args[0].int);
    try std.testing.expectEqual(@as(i32, 156), pc_args[1].int);
    try std.testing.expectEqual(@as(i32, 90), pc_args[2].int);
    try std.testing.expectEqual(@as(i32, 70), pc_args[3].int);
    try std.testing.expectEqual(@as(u32, 11), sink.events.items[2].object_id); // xdg_surface.configure
    // and the popup surface now reports the new absolute position
    try std.testing.expectEqual(@as(i32, 206), comp.surfaceAbs(1, 10).x);
}

/// Popup tests on a WinTest toplevel: a positioner `id` with a 1×1 anchor
/// rect at (x, y), anchor and gravity `ag`, size w×h; a popup (surface `s`,
/// xdg_surface s+1, xdg_popup s+2) of xdg_surface `parent`, committed.
const PopupTest = struct {
    const pos = protocol.find("xdg_positioner").?;
    const wm = protocol.find("xdg_wm_base").?;
    const xs = protocol.find("xdg_surface").?;
    const pp = protocol.find("xdg_popup").?;
    const geom_op = xs.requestIndex("set_window_geometry").?;
    fn positioner(comp: *Compositor, id: u32, x: i32, y: i32, ag: [2]u32, w: i32, h: i32) !void {
        const T = WinTest;
        try T.send(comp, 4, comptime wm.requestIndex("create_positioner").?, &.{.{ .new_id = id }});
        try T.send(comp, id, comptime pos.requestIndex("set_size").?, &.{ .{ .int = w }, .{ .int = h } });
        try T.send(comp, id, comptime pos.requestIndex("set_anchor_rect").?, &.{ .{ .int = x }, .{ .int = y }, .{ .int = 1 }, .{ .int = 1 } });
        try T.send(comp, id, comptime pos.requestIndex("set_anchor").?, &.{.{ .uint = ag[0] }});
        try T.send(comp, id, comptime pos.requestIndex("set_gravity").?, &.{.{ .uint = ag[1] }});
    }
    fn popup(comp: *Compositor, s: u32, parent: u32, positioner_id: u32) !void {
        const T = WinTest;
        try T.send(comp, 3, 0, &.{.{ .new_id = s }}); // create_surface
        try T.send(comp, 4, comptime wm.requestIndex("get_xdg_surface").?, &.{ .{ .new_id = s + 1 }, .{ .object = s } });
        try T.send(comp, s + 1, comptime xs.requestIndex("get_popup").?, &.{ .{ .new_id = s + 2 }, .{ .object = parent }, .{ .object = positioner_id } });
        try T.send(comp, s, T.commit_op, &.{});
    }
    fn adjust(comp: *Compositor, id: u32, bits: u32) !void {
        try WinTest.send(comp, id, comptime pos.requestIndex("set_constraint_adjustment").?, &.{.{ .uint = bits }});
    }
    /// x, y, w, h of the last xdg_popup.configure to `popup_id`
    fn configuredBox(sink: *TestSink, popup_id: u32) ![4]i32 {
        var vals: [wire.max_args]wire.Value = undefined;
        var last: ?[4]i32 = null;
        for (sink.events.items) |ev| {
            if (ev.object_id != popup_id or ev.opcode != comptime pp.eventIndex("configure").?) continue;
            const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .int, .int, .int, .int }, &vals);
            last = .{ a[0].int, a[1].int, a[2].int, a[3].int };
        }
        return last orelse error.NoConfigure;
    }
    /// x, y of the last xdg_popup.configure to `popup_id`
    fn configured(sink: *TestSink, popup_id: u32) ![2]i32 {
        var vals: [wire.max_args]wire.Value = undefined;
        var last: ?[2]i32 = null;
        for (sink.events.items) |ev| {
            if (ev.object_id != popup_id or ev.opcode != comptime pp.eventIndex("configure").?) continue;
            const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .int, .int, .int, .int }, &vals);
            last = .{ a[0].int, a[1].int };
        }
        return last.?;
    }
    fn at(comp: *Compositor, surface: u32) [2]i32 {
        const p = comp.surfaceAbs(1, surface);
        return .{ p.x, p.y };
    }
};

test "positioner constraint adjustment: flip, slide, resize per axis in the spec's order; combinations; offsets mirror on a flip; invalid sizes and huge values" {
    const B = [4]i32{ 0, 0, 1000, 800 };
    const A = Positioner;
    // anchor rect 10×10 at (x, y), anchor/gravity, size, adjust bits
    const mk = struct {
        fn f(x: i32, y: i32, anchor: u32, gravity: u32, w: i32, h: i32, adjust: u32) Positioner {
            return .{ .anchor_x = x, .anchor_y = y, .anchor_w = 10, .anchor_h = 10, .anchor = anchor, .gravity = gravity, .w = w, .h = h, .adjust = adjust };
        }
    }.f;
    const eq = std.testing.expectEqual;
    // fits: as placed
    try eq(Placed{ .x = 110, .y = 110, .w = 100, .h = 50 }, mk(100, 100, 8, 8, 100, 50, 63).placeWithin(B));
    // past the right edge, nothing allowed: as placed
    try eq(Placed{ .x = 960, .y = 80, .w = 100, .h = 50 }, mk(950, 100, 4, 4, 100, 50, 0).placeWithin(B));
    // flip_x: to the anchor's other side
    try eq(Placed{ .x = 850, .y = 80, .w = 100, .h = 50 }, mk(950, 100, 4, 4, 100, 50, A.adjust_flip_x).placeWithin(B));
    // flip_x that does not fit either: kept as before the flip
    try eq(Placed{ .x = 960, .y = 80, .w = 960, .h = 50 }, mk(950, 100, 4, 4, 960, 50, A.adjust_flip_x).placeWithin(B));
    // the offset mirrors with it (a submenu's overlap stays an overlap)
    var off = mk(950, 100, 4, 4, 100, 50, A.adjust_flip_x);
    off.dx = 5;
    try eq(@as(i32, 845), off.placeWithin(B).x);
    // slide_x: right gravity slides back left until it fits
    try eq(Placed{ .x = 900, .y = 80, .w = 100, .h = 50 }, mk(950, 100, 4, 4, 100, 50, A.adjust_slide_x).placeWithin(B));
    // left gravity past the left edge: slides right
    try eq(Placed{ .x = 0, .y = 80, .w = 100, .h = 50 }, mk(20, 100, 3, 3, 100, 50, A.adjust_slide_x).placeWithin(B));
    // wider than the output: slid to the low edge (right gravity), then
    // resize_x cuts it to the output
    try eq(Placed{ .x = 0, .y = 80, .w = 1200, .h = 50 }, mk(100, 100, 3, 4, 1200, 50, A.adjust_slide_x).placeWithin(B));
    try eq(Placed{ .x = 0, .y = 80, .w = 1000, .h = 50 }, mk(100, 100, 3, 4, 1200, 50, A.adjust_slide_x | A.adjust_resize_x).placeWithin(B));
    // left gravity, wider than the output: slid to the high edge
    try eq(Placed{ .x = -200, .y = 80, .w = 1200, .h = 50 }, mk(900, 100, 4, 3, 1200, 50, A.adjust_slide_x).placeWithin(B));
    // resize_x alone: cut at the edge
    try eq(Placed{ .x = 960, .y = 80, .w = 40, .h = 50 }, mk(950, 100, 4, 4, 100, 50, A.adjust_resize_x).placeWithin(B));
    // flip first, slide when the flip does not fit
    try eq(Placed{ .x = 200, .y = 80, .w = 800, .h = 50 }, mk(700, 100, 4, 4, 800, 50, A.adjust_flip_x | A.adjust_slide_x).placeWithin(B));
    try eq(Placed{ .x = 600, .y = 80, .w = 100, .h = 50 }, mk(700, 100, 3, 3, 100, 50, A.adjust_flip_x | A.adjust_slide_x).placeWithin(B)); // fits: untouched
    // the y axis alike: flip_y over the anchor, slide_y up, resize_y
    try eq(Placed{ .x = 55, .y = 720, .w = 100, .h = 50 }, mk(100, 770, 2, 2, 100, 50, A.adjust_flip_y).placeWithin(B));
    try eq(Placed{ .x = 55, .y = 750, .w = 100, .h = 50 }, mk(100, 770, 2, 2, 100, 50, A.adjust_slide_y).placeWithin(B));
    try eq(Placed{ .x = 55, .y = 780, .w = 100, .h = 20 }, mk(100, 770, 2, 2, 100, 50, A.adjust_resize_y).placeWithin(B));
    try eq(Placed{ .x = 55, .y = 0, .w = 100, .h = 50 }, mk(100, 10, 1, 1, 100, 50, A.adjust_slide_y).placeWithin(B));
    // each axis on its own: x flips, y slides; a corner anchor flips both
    try eq(Placed{ .x = 855, .y = 750, .w = 100, .h = 50 }, mk(950, 770, 2, 8, 100, 50, A.adjust_flip_x | A.adjust_slide_y).placeWithin(B));
    try eq(Placed{ .x = 850, .y = 720, .w = 100, .h = 50 }, mk(950, 770, 8, 8, 100, 50, A.adjust_flip_x | A.adjust_flip_y).placeWithin(B));
    // a flip only on the axis that is out: y stays below the anchor
    try eq(Placed{ .x = 850, .y = 110, .w = 100, .h = 50 }, mk(950, 100, 8, 8, 100, 50, A.adjust_flip_x | A.adjust_flip_y).placeWithin(B));
    // no size (an invalid positioner): placed as is
    try eq(Placed{ .x = 960, .y = 80, .w = 0, .h = 50 }, mk(950, 100, 4, 4, 0, 50, 63).placeWithin(B));
    // client i32s at the limits: saturate, never overflow
    const max = std.math.maxInt(i32);
    var huge = mk(max - 5, -max, 8, 8, max, max, 63);
    huge.dx = max;
    _ = huge.placeWithin(B);
    _ = huge.placeWithin(.{ -max, -max, max, max });
}

test "popups constrained once the window's position is known: unknown = as the positioner says; flip / slide / resize in the configure, the resized size too; nested popups add up; reposition; reactive ones placed again as the window moves or the output changes, others not; a new embedder forgets positions" {
    const T = WinTest;
    const P = PopupTest;
    const A = Positioner;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink); // 800×600 on a 1500×950 desktop
    const br = [2]u32{ 8, 8 }; // anchor bottom_right, gravity bottom_right

    // a menu at the window's right edge, flip_x allowed: position unknown,
    // so placed as the positioner says
    try P.positioner(&comp, 20, 780, 100, br, 200, 150);
    try P.adjust(&comp, 20, A.adjust_flip_x | A.adjust_slide_y | A.adjust_resize_y);
    try P.popup(&comp, 21, 7, 20);
    try std.testing.expectEqual([4]i32{ 781, 101, 200, 150 }, try P.configuredBox(&sink, 23));
    try T.send(&comp, 23, 0, &.{});
    try T.send(&comp, 22, 0, &.{});

    // the window at (650, 700): its right edge at 1450, bottom at 1300
    // (past the output's 950); the menu flips left of the anchor and is
    // cut at the output's bottom (slide would leave its top edge, resize)
    comp.setWindowPosition(1, 6, 650, 700);
    sink.events.clearRetainingCapacity();
    try P.popup(&comp, 31, 7, 20);
    // x: 780 + 1 = 781 → 781 + 200 + 650 > 1500: flipped to 780 − 200 = 580
    // y: 101 + 700 = 801, + 150 = 951 > 950: slid up by 1 to 100
    try std.testing.expectEqual([4]i32{ 580, 100, 200, 150 }, try P.configuredBox(&sink, 33));
    try std.testing.expectEqual([2]i32{ 580, 100 }, P.at(&comp, 31));
    // a submenu of it near the bottom: nested positions add up — its parent
    // geometry is at (650 + 580, 700 + 100) = (1230, 800); anchor at (190,
    // 140) of the menu → y 940, 100 tall → past 950: resize_y cuts it to 10
    try P.positioner(&comp, 40, 190, 140, .{ 4, 8 }, 150, 100);
    try P.adjust(&comp, 40, A.adjust_slide_x | A.adjust_resize_y);
    try P.popup(&comp, 41, 32, 40);
    // x: 1230 + 191 + 150 = 1571 > 1500: slid left by 71 → 120
    try std.testing.expectEqual([4]i32{ 120, 140, 150, 10 }, try P.configuredBox(&sink, 43));
    // reposition: constrained the same way
    try P.positioner(&comp, 50, 10, 250, br, 200, 150);
    try P.adjust(&comp, 50, A.adjust_flip_x | A.adjust_flip_y);
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 33, comptime P.pp.requestIndex("reposition").?, &.{ .{ .object = 50 }, .{ .uint = 1 } });
    // the menu at (650 + 11, 700 + 251): past 950 → flipped above the anchor
    try std.testing.expectEqual([4]i32{ 11, 250 - 150, 200, 150 }, try P.configuredBox(&sink, 33));

    // the window moves: open non-reactive popups stay as they are
    sink.events.clearRetainingCapacity();
    _ = comp.takePositionsDirty();
    comp.setWindowPosition(1, 6, 100, 100);
    comp.setWindowPosition(1, 6, 100, 100); // the same: nothing
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expect(!comp.takePositionsDirty());

    // a reactive one is placed again: configure, no repositioned
    try P.positioner(&comp, 60, 780, 100, br, 200, 150);
    try P.adjust(&comp, 60, A.adjust_flip_x);
    try T.send(&comp, 60, comptime P.pos.requestIndex("set_reactive").?, &.{});
    try P.popup(&comp, 61, 7, 60);
    try std.testing.expectEqual([4]i32{ 781, 101, 200, 150 }, try P.configuredBox(&sink, 63)); // fits at x 100
    sink.events.clearRetainingCapacity();
    _ = comp.takePositionsDirty();
    comp.setWindowPosition(1, 6, 600, 100); // now 600 + 981 > 1500
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // xdg_popup + xdg_surface configure
    try std.testing.expectEqual([4]i32{ 580, 101, 200, 150 }, try P.configuredBox(&sink, 63));
    try std.testing.expectEqual(@as(u32, 62), sink.events.items[1].object_id);
    try std.testing.expect(comp.takePositionsDirty());
    // the output grows: placed again (it fits unflipped now)
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1700, 950);
    try std.testing.expectEqual([4]i32{ 781, 101, 200, 150 }, try P.configuredBox(&sink, 63));

    // a new embedder: positions unknown again — a new popup as placed
    comp.resetEmbedderWindows();
    sink.events.clearRetainingCapacity();
    try P.positioner(&comp, 70, 780, 900, br, 200, 150);
    try P.adjust(&comp, 70, 63);
    try P.popup(&comp, 71, 7, 70);
    try std.testing.expectEqual([4]i32{ 781, 901, 200, 150 }, try P.configuredBox(&sink, 73));
}

test "popups: placed from the parent's window geometry to their own (GTK CSD shadows) — nested and repositioned alike" {
    const T = WinTest;
    const P = PopupTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    const br = [2]u32{ 8, 8 }; // anchor bottom_right, gravity bottom_right

    // no geometry set: the configure position counts from the surface origin
    try P.positioner(&comp, 20, 100, 50, br, 200, 150);
    try P.popup(&comp, 21, 7, 20);
    try std.testing.expectEqual([2]i32{ 101, 51 }, try P.configured(&sink, 23));
    try std.testing.expectEqual([2]i32{ 101, 51 }, P.at(&comp, 21));
    try T.send(&comp, 23, 0, &.{}); // xdg_popup.destroy
    try T.send(&comp, 22, 0, &.{}); // xdg_surface.destroy

    // l3afpad: a GTK3 CSD window, its frame at (23,21) inside its shadow; a
    // right-click at (400,400) of the surface = (377,379) of the geometry,
    // which is what GTK's anchor rect says. The menu has a shadow of its
    // own: its geometry at (3,3) of its surface.
    try T.send(&comp, 7, P.geom_op, &.{ .{ .int = 23 }, .{ .int = 21 }, .{ .int = 754 }, .{ .int = 558 } });
    try T.send(&comp, 6, T.commit_op, &.{});
    sink.events.clearRetainingCapacity();
    try P.positioner(&comp, 30, 377, 379, br, 200, 300);
    try P.popup(&comp, 31, 7, 30);
    try std.testing.expectEqual([2]i32{ 378, 380 }, try P.configured(&sink, 33)); // geometry-relative, as sent
    try T.send(&comp, 32, P.geom_op, &.{ .{ .int = 3 }, .{ .int = 3 }, .{ .int = 200 }, .{ .int = 300 } });
    try T.send(&comp, 31, T.commit_op, &.{});
    // the menu's frame lands at the parent's (23+378, 21+380) = just past
    // the click; its surface 3 px up-left of that (it used to be 20 px off)
    try std.testing.expectEqual([2]i32{ 23 + 378 - 3, 21 + 380 - 3 }, P.at(&comp, 31));

    // a submenu off its item: anchor right of (190,40) of the menu's
    // geometry, its own frame at (3,3) too
    try P.positioner(&comp, 40, 190, 40, .{ 4, 8 }, 150, 100);
    try P.popup(&comp, 41, 32, 40);
    try std.testing.expectEqual([2]i32{ 191, 40 }, try P.configured(&sink, 43));
    try T.send(&comp, 42, P.geom_op, &.{ .{ .int = 3 }, .{ .int = 3 }, .{ .int = 150 }, .{ .int = 100 } });
    try T.send(&comp, 41, T.commit_op, &.{});
    try std.testing.expectEqual([2]i32{ 398 + 3 + 191 - 3, 398 + 3 + 40 - 3 }, P.at(&comp, 41));

    // xdg_popup.reposition: the same placement; the submenu follows
    try P.positioner(&comp, 50, 99, 99, br, 200, 300);
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 33, comptime P.pp.requestIndex("reposition").?, &.{ .{ .object = 50 }, .{ .uint = 1 } });
    try std.testing.expectEqual([2]i32{ 100, 100 }, try P.configured(&sink, 33));
    try std.testing.expectEqual([2]i32{ 23 + 100 - 3, 21 + 100 - 3 }, P.at(&comp, 31));
    try std.testing.expectEqual([2]i32{ 120 + 3 + 191 - 3, 118 + 3 + 40 - 3 }, P.at(&comp, 41));
}

test "positions dirty: raised by what moves or restacks a subsurface or popup (set_position, the parent's stack latch, geometry, popup placement, roles, destroys), not by plain commits or damage; ranks cached and redone after a restack" {
    const T = WinTest;
    const P = PopupTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    const sub = comptime protocol.find("wl_subsurface").?;
    const damage_op = comptime T.surf.requestIndex("damage").?;
    const Dirty = struct {
        fn expect(c: *Compositor, want: bool) !void {
            try std.testing.expectEqual(want, c.takePositionsDirty());
            try std.testing.expect(!c.takePositionsDirty()); // read clears it
        }
    };
    _ = comp.takePositionsDirty(); // the toplevel's setup

    // subsurfaces a=10, b=12 of the toplevel: each is made dirty, and its
    // rank is right at once
    try T.send(&comp, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 5 } } });
    try Dirty.expect(&comp, false); // a bind moves nothing
    for ([_]u32{ 10, 12 }, 1..) |s, n| {
        try T.send(&comp, 3, 0, &.{.{ .new_id = s }});
        try Dirty.expect(&comp, false); // a surface with no role
        try T.send(&comp, 5, 1, &.{ .{ .new_id = s + 1 }, .{ .object = s }, .{ .object = 6 } });
        try Dirty.expect(&comp, true);
        try std.testing.expectEqual(@as(i32, @intCast(n)), comp.surfaceZ(1, s));
    }

    // commits and damage with nothing pending: not dirty (the busy case)
    try T.send(&comp, 10, T.commit_op, &.{});
    try T.send(&comp, 6, damage_op, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } });
    try T.send(&comp, 6, T.commit_op, &.{});
    try Dirty.expect(&comp, false);

    // set_position applies at once: dirty without any commit
    try T.send(&comp, 11, comptime sub.requestIndex("set_position").?, &.{ .{ .int = 5 }, .{ .int = 7 } });
    try Dirty.expect(&comp, true);
    try std.testing.expectEqual([2]i32{ 5, 7 }, P.at(&comp, 10));

    // place_below is pending: dirty at the parent's commit, not before;
    // the cached ranks follow
    try T.send(&comp, 13, comptime sub.requestIndex("place_below").?, &.{.{ .object = 6 }});
    try Dirty.expect(&comp, false);
    try std.testing.expectEqual(@as(i32, 2), comp.surfaceZ(1, 12));
    try T.send(&comp, 6, T.commit_op, &.{});
    try Dirty.expect(&comp, true);
    try std.testing.expectEqual(@as(i32, -1), comp.surfaceZ(1, 12));
    try std.testing.expectEqual(@as(i32, 1), comp.surfaceZ(1, 10));

    // the toplevel's window geometry (popups are placed from it): dirty
    // when the commit latches a new one, not when it latches the same
    try T.send(&comp, 7, P.geom_op, &.{ .{ .int = 10 }, .{ .int = 10 }, .{ .int = 700 }, .{ .int = 500 } });
    try Dirty.expect(&comp, false);
    try T.send(&comp, 6, T.commit_op, &.{});
    try Dirty.expect(&comp, true);
    try T.send(&comp, 7, P.geom_op, &.{ .{ .int = 10 }, .{ .int = 10 }, .{ .int = 700 }, .{ .int = 500 } });
    try T.send(&comp, 6, T.commit_op, &.{});
    try Dirty.expect(&comp, false);

    // a popup: get_popup, then its reposition
    try P.positioner(&comp, 20, 100, 50, .{ 8, 8 }, 200, 150);
    try Dirty.expect(&comp, false);
    try P.popup(&comp, 21, 7, 20);
    try Dirty.expect(&comp, true);
    try P.positioner(&comp, 30, 40, 40, .{ 8, 8 }, 200, 150);
    try T.send(&comp, 23, comptime P.pp.requestIndex("reposition").?, &.{ .{ .object = 30 }, .{ .uint = 1 } });
    try Dirty.expect(&comp, true);
    // the popup's role object, then its xdg_surface (geometry unset: not
    // dirty again), then its wl_surface
    try T.send(&comp, 23, 0, &.{}); // xdg_popup.destroy
    try Dirty.expect(&comp, true);
    try T.send(&comp, 22, 0, &.{}); // xdg_surface.destroy, no geometry
    try Dirty.expect(&comp, false);
    try T.send(&comp, 21, 0, &.{}); // wl_surface.destroy
    try Dirty.expect(&comp, true);

    // wl_subsurface.destroy: dirty, and the sibling's rank closes up
    try T.send(&comp, 3, 0, &.{.{ .new_id = 14 }});
    try T.send(&comp, 5, 1, &.{ .{ .new_id = 15 }, .{ .object = 14 }, .{ .object = 6 } });
    try Dirty.expect(&comp, true);
    try std.testing.expectEqual(@as(i32, 2), comp.surfaceZ(1, 14));
    try T.send(&comp, 11, 0, &.{}); // a's wl_subsurface.destroy
    try Dirty.expect(&comp, true);
    try std.testing.expectEqual(@as(i32, 0), comp.surfaceZ(1, 10)); // no role now
    try std.testing.expectEqual(@as(i32, 1), comp.surfaceZ(1, 14));
    try std.testing.expectEqual(@as(i32, -1), comp.surfaceZ(1, 12));
    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
}

test "move/resize: honoured only with the serial of a press still held on the window — a request after the release (slow client) is ignored" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    const move_op = comptime T.tl.requestIndex("move").?;
    const resize_op = comptime T.tl.requestIndex("resize").?;
    var calls = sink.inter_calls;

    // no press at all
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = 1 } });
    try std.testing.expectEqual(calls, sink.inter_calls);

    // held: honoured
    const s1 = try T.press(&comp);
    try T.send(&comp, 8, resize_op, &.{ .{ .object = 0 }, .{ .uint = s1 }, .{ .uint = 4 } });
    try std.testing.expectEqual(calls + 1, sink.inter_calls);
    try std.testing.expectEqual(@as(u32, 1), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 4), sink.inter_value);
    calls = sink.inter_calls;

    // foot's quick click on its left border: the request comes after the
    // release — no grab (it used to follow the pointer until the next click)
    comp.pointerButton(1, 0, 0x110, false);
    try T.send(&comp, 8, resize_op, &.{ .{ .object = 0 }, .{ .uint = s1 }, .{ .uint = 4 } });
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = s1 } });
    try std.testing.expectEqual(calls, sink.inter_calls);

    // a new press: the old serial is stale, the new one good
    const s2 = try T.press(&comp);
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = s1 } });
    try std.testing.expectEqual(calls, sink.inter_calls);
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = s2 } });
    try std.testing.expectEqual(calls + 1, sink.inter_calls);
    try std.testing.expectEqual(@as(u32, 0), sink.inter_kind);
    calls = sink.inter_calls;

    // a second button joins the grab: both presses count until the last
    // goes up
    comp.pointerButton(1, 0, 0x111, true);
    const s3 = comp.conns.get(1).?.serial;
    comp.pointerButton(1, 0, 0x110, false);
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = s2 } });
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = s3 } });
    try std.testing.expectEqual(calls + 2, sink.inter_calls);
    calls = sink.inter_calls;
    comp.pointerButton(1, 0, 0x111, false);
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = s3 } });
    try std.testing.expectEqual(calls, sink.inter_calls);

    // the pointer handed elsewhere (a leave) ends the grab, button or not
    const s4 = try T.press(&comp);
    comp.pointerLeave(1);
    try T.send(&comp, 8, move_op, &.{ .{ .object = 0 }, .{ .uint = s4 } });
    try std.testing.expectEqual(calls, sink.inter_calls);
}

test "wl_output advertises output_scale, mode in hw px; set_buffer_scale tracked" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.output_scale = 2;

    var buf: [128]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 2, .id = 4 } } }));

    // geometry, mode, scale, done
    try std.testing.expectEqual(@as(usize, 4), sink.events.items.len);
    var vals: [wire.max_args]wire.Value = undefined;
    const mode_ev = sink.events.items[1];
    const mode_args = try wire.decodeArgs(mode_ev.bytes[wire.header_size..mode_ev.len], &.{ .uint, .int, .int, .int }, &vals);
    try std.testing.expectEqual(output_width * 2, mode_args[1].int); // hw px = logical × scale
    const scale_ev = sink.events.items[2];
    const scale_op = comptime protocol.find("wl_output").?.eventIndex("scale").?;
    try std.testing.expectEqual(scale_op, scale_ev.opcode);
    const scale_args = try wire.decodeArgs(scale_ev.bytes[wire.header_size..scale_ev.len], &.{.int}, &vals);
    try std.testing.expectEqual(@as(i32, 2), scale_args[0].int);

    // per-surface buffer scale, defaults to 1 until set_buffer_scale
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }})); // create_surface
    try std.testing.expectEqual(@as(i32, 1), comp.surfaceScale(1, 9));
    const sbs_op = comptime protocol.find("wl_surface").?.requestIndex("set_buffer_scale").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 9, sbs_op, &.{.{ .int = 2 }}));
    try std.testing.expectEqual(@as(i32, 2), comp.surfaceScale(1, 9));
}

test "wl_surface.enter/leave: a surface with content is on every bound wl_output" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const surf = comptime protocol.find("wl_surface").?;
    const attach_op = comptime surf.requestIndex("attach").?;
    const commit_op = comptime surf.requestIndex("commit").?;
    const destroy_op = comptime surf.requestIndex("destroy").?;
    const enter_op = comptime surf.eventIndex("enter").?;
    const leave_op = comptime surf.eventIndex("leave").?;
    const H = struct {
        /// the wl_surface events in the sink, as { opcode, output } pairs
        fn expect(s: *TestSink, surface: u32, want: []const [2]u32) !void {
            var vals: [wire.max_args]wire.Value = undefined;
            var n: usize = 0;
            for (s.events.items) |ev| {
                if (ev.object_id != surface) continue;
                try std.testing.expect(n < want.len);
                try std.testing.expectEqual(want[n][0], @as(u32, ev.opcode));
                const a = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.object}, &vals);
                try std.testing.expectEqual(want[n][1], a[0].object);
                n += 1;
            }
            try std.testing.expectEqual(want.len, n);
            s.events.clearRetainingCapacity();
        }
    };

    var buf: [128]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 4, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }})); // create_surface
    sink.events.clearRetainingCapacity();

    // no content yet: a bare commit, and an attach before its commit, enter nothing
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, attach_op, &.{ .{ .object = 20 }, .{ .int = 0 }, .{ .int = 0 } }));
    try H.expect(&sink, 6, &.{});
    // the commit that latches a buffer: enter(output)
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try H.expect(&sink, 6, &.{.{ enter_op, 4 }});
    // later frames (with or without attach) say nothing more
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, attach_op, &.{ .{ .object = 21 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try H.expect(&sink, 6, &.{});

    // an output bound late learns the surfaces already on it; a surface
    // without content is not among them
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 7 }})); // create_surface
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 4, .id = 5 } } }));
    for (sink.events.items) |ev| try std.testing.expect(ev.object_id != 7);
    try H.expect(&sink, 6, &.{.{ enter_op, 5 }});

    // attach(NULL) + commit unmaps: leave for both outputs; a released
    // output is named no more
    try comp.onWire(1, wire.encodeMessage(&buf, 6, attach_op, &.{ .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try H.expect(&sink, 6, &.{ .{ leave_op, 4 }, .{ leave_op, 5 } });
    const release_op = comptime protocol.find("wl_output").?.requestIndex("release").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 5, release_op, &.{}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, attach_op, &.{ .{ .object = 20 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try H.expect(&sink, 6, &.{.{ enter_op, 4 }});

    // a destroyed surface gets no leave (the id is dead)
    try comp.onWire(1, wire.encodeMessage(&buf, 6, destroy_op, &.{}));
    for (sink.events.items) |ev| try std.testing.expect(!(ev.object_id == 6 and ev.opcode == leave_op));
}

test "wl_surface.leave when the xdg role object goes; the reused surface enters again" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const surf = comptime protocol.find("wl_surface").?;
    const attach_op = comptime surf.requestIndex("attach").?;
    const commit_op = comptime surf.requestIndex("commit").?;
    const enter_op = comptime surf.eventIndex("enter").?;
    const leave_op = comptime surf.eventIndex("leave").?;
    const count = struct {
        fn of(s: *TestSink, surface: u32, opcode: u16) usize {
            var n: usize = 0;
            for (s.events.items) |ev| {
                if (ev.object_id == surface and ev.opcode == opcode) n += 1;
            }
            return n;
        }
    }.of;

    var buf: [128]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 3, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 2, .id = 5 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }})); // create_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 7 }, .{ .object = 6 } })); // get_xdg_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 1, &.{.{ .new_id = 8 }})); // get_toplevel
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{})); // initial commit → configure
    try std.testing.expectEqual(@as(usize, 0), count(&sink, 6, enter_op));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, attach_op, &.{ .{ .object = 20 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(usize, 1), count(&sink, 6, enter_op));

    // xdg_toplevel.destroy unmaps the surface, buffer or not
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 0, &.{})); // xdg_toplevel.destroy
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 0, &.{})); // xdg_surface.destroy
    try std.testing.expectEqual(@as(usize, 1), count(&sink, 6, leave_op));

    // the wl_surface is reused for a new toplevel: its initial (bufferless)
    // commit does not enter, the first buffer does
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 9 }, .{ .object = 6 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 1, &.{.{ .new_id = 10 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(usize, 0), count(&sink, 6, enter_op));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, attach_op, &.{ .{ .object = 20 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    try std.testing.expectEqual(@as(usize, 1), count(&sink, 6, enter_op));
    try std.testing.expectEqual(@as(usize, 0), count(&sink, 6, leave_op));
}

test "wl_output v4: name/description precede done; mode is desk size; live resize resends" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.desk_w = 1600;
    comp.desk_h = 900;

    var buf: [128]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 5 }, .{ .new_id_dynamic = .{ .interface = "wl_output", .version = 4, .id = 4 } } }));

    const out = comptime protocol.find("wl_output").?;
    const mode_op = comptime out.eventIndex("mode").?;
    const name_op = comptime out.eventIndex("name").?;
    const desc_op = comptime out.eventIndex("description").?;
    const done_op = comptime out.eventIndex("done").?;
    // geometry, mode, scale, name, description, done — name/desc before done
    try std.testing.expectEqual(@as(usize, 6), sink.events.items.len);
    try std.testing.expectEqual(mode_op, sink.events.items[1].opcode);
    var vals: [wire.max_args]wire.Value = undefined;
    const mode_ev = sink.events.items[1];
    const mode_args = try wire.decodeArgs(mode_ev.bytes[wire.header_size..mode_ev.len], &.{ .uint, .int, .int, .int }, &vals);
    try std.testing.expectEqual(@as(i32, 1600), mode_args[1].int); // real desk size (scale 1)
    try std.testing.expectEqual(@as(i32, 900), mode_args[2].int);
    try std.testing.expectEqual(name_op, sink.events.items[3].opcode);
    try std.testing.expectEqual(desc_op, sink.events.items[4].opcode);
    try std.testing.expectEqual(done_op, sink.events.items[5].opcode);

    // desktop resize → a fresh mode + done to the bound output
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1920, 1080);
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(mode_op, sink.events.items[0].opcode);
    const m2 = sink.events.items[0];
    const m2a = try wire.decodeArgs(m2.bytes[wire.header_size..m2.len], &.{ .uint, .int, .int, .int }, &vals);
    try std.testing.expectEqual(@as(i32, 1920), m2a[1].int);
    try std.testing.expectEqual(done_op, sink.events.items[1].opcode);

    // no-op resize (same size) sends nothing
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1920, 1080);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // release the output → a later resize no longer reaches it
    const release_op = comptime out.requestIndex("release").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 4, release_op, &.{}));
    sink.events.clearRetainingCapacity();
    comp.setDesktopSize(1024, 768);
    // only the delete_id from the release is gone by now; no mode/done resends
    for (sink.events.items) |ev| try std.testing.expect(ev.opcode != mode_op);
}

test "wl_compositor v5: wl_surface.offset decodes; pending until commit latches it" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    var buf: [128]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 5, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }})); // create_surface

    const offset_op = comptime protocol.find("wl_surface").?.requestIndex("offset").?;
    const commit_op = comptime protocol.find("wl_surface").?.requestIndex("commit").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 6, offset_op, &.{ .{ .int = 7 }, .{ .int = -3 } }));

    // decode is clean (surface still tracked); the offset is pending state
    var surface = comp.conns.get(1).?.surfaces.get(6).?;
    try std.testing.expectEqual(@as(i32, 0), surface.offset_x);
    try comp.onWire(1, wire.encodeMessage(&buf, 6, commit_op, &.{}));
    surface = comp.conns.get(1).?.surfaces.get(6).?;
    try std.testing.expectEqual(@as(i32, 7), surface.offset_x);
    try std.testing.expectEqual(@as(i32, -3), surface.offset_y);
    try std.testing.expectEqual(@as(?[2]i32, null), surface.offset_pending);
    try std.testing.expectEqual(Role.none, comp.surfaceRole(1, 6));
}

test "wl_pointer.set_cursor: serial + focus gated, hotspot moved by committed offsets, hidden without content; last of shape/surface wins" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    comp.cursor_shape_fn = TestSink.cursorShape;
    comp.cursor_surface_fn = TestSink.cursorSurface;
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    const surf = comptime protocol.find("wl_surface").?;
    const attach_op = comptime surf.requestIndex("attach").?;
    const commit_op = comptime surf.requestIndex("commit").?;
    const offset_op = comptime surf.requestIndex("offset").?;
    const frame_op = comptime surf.requestIndex("frame").?;
    const destroy_op = comptime surf.requestIndex("destroy").?;
    const set_cursor_op = comptime protocol.find("wl_pointer").?.requestIndex("set_cursor").?;
    const done_op = comptime protocol.find("wl_callback").?.eventIndex("done").?;

    var buf: [128]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    // wl_compositor v5 @3, wl_seat @4, cursor-shape manager @5
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 5, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 9 }, .{ .new_id_dynamic = .{ .interface = "wp_cursor_shape_manager_v1", .version = 1, .id = 5 } } }));
    // surface 6 (the pointer's target), surface 9 (the cursor), wl_pointer 7, shape device 8
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 7 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 8 }, .{ .object = 7 } }));
    const H = struct {
        fn setCursor(c: *Compositor, b: []u8, serial: u32, surface: u32, hx: i32, hy: i32) !void {
            try c.onWire(1, wire.encodeMessage(b, 7, set_cursor_op, &.{ .{ .uint = serial }, .{ .object = surface }, .{ .int = hx }, .{ .int = hy } }));
        }
        fn expectCursor(s: *TestSink, calls: u32, surface: u32, hx: i32, hy: i32) !void {
            try std.testing.expectEqual(calls, s.cursor_calls);
            try std.testing.expectEqual(surface, s.cursor_surface);
            try std.testing.expectEqual(hx, s.cursor_hx);
            try std.testing.expectEqual(hy, s.cursor_hy);
        }
    };

    // GTK order: the cursor buffer is committed before set_cursor
    try comp.onWire(1, wire.encodeMessage(&buf, 9, attach_op, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));

    // without pointer focus nothing applies (the role does)
    try H.setCursor(&comp, &buf, 0, 9, 4, 5);
    try std.testing.expectEqual(@as(u32, 0), sink.cursor_calls);
    try std.testing.expectEqual(Role.cursor, comp.surfaceRole(1, 9));

    comp.pointerEnter(1, 6, 0, 0);
    const serial = comp.conns.get(1).?.pointer_enter_serial;
    // a stale serial is ignored, not an error
    sink.events.clearRetainingCapacity();
    try H.setCursor(&comp, &buf, serial +% 7, 9, 4, 5);
    try std.testing.expectEqual(@as(u32, 0), sink.cursor_calls);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    // the latest enter's serial: surface 9 with hotspot 4,5
    try H.setCursor(&comp, &buf, serial, 9, 4, 5);
    try H.expectCursor(&sink, 1, 9, 4, 5);
    // the pointer never enters a cursor surface
    comp.pointerEnter(1, 9, 0, 0);
    try std.testing.expectEqual(@as(u32, 6), comp.conns.get(1).?.pointer_focus);

    // an offset moves the hotspot against it, but only once committed
    try comp.onWire(1, wire.encodeMessage(&buf, 9, offset_op, &.{ .{ .int = 2 }, .{ .int = -1 } }));
    try H.expectCursor(&sink, 1, 9, 4, 5);
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));
    try H.expectCursor(&sink, 2, 9, 2, 6);
    // pre-v5 style: attach's x,y does the same
    try comp.onWire(1, wire.encodeMessage(&buf, 9, attach_op, &.{ .{ .object = 31 }, .{ .int = 1 }, .{ .int = 1 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));
    try H.expectCursor(&sink, 3, 9, 1, 5);
    // a plain new buffer (an animation frame) needs no re-send: the commit
    // carries the pixels; its frame callback still fires at the next tick
    try comp.onWire(1, wire.encodeMessage(&buf, 9, frame_op, &.{.{ .new_id = 40 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, attach_op, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));
    try H.expectCursor(&sink, 3, 9, 1, 5);
    sink.events.clearRetainingCapacity();
    comp.tick(.{ .time_ms = 10 });
    var fired = false;
    for (sink.events.items) |e| fired = fired or (e.object_id == 40 and e.opcode == done_op);
    try std.testing.expect(fired);
    // set_cursor naming the same surface again: just the hotspot
    try H.setCursor(&comp, &buf, serial, 9, 3, 3);
    try H.expectCursor(&sink, 4, 9, 3, 3);

    // attach(NULL): no content, so no image (hidden); a buffer brings it back
    try comp.onWire(1, wire.encodeMessage(&buf, 9, attach_op, &.{ .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));
    try H.expectCursor(&sink, 5, 0, 0, 0);
    try comp.onWire(1, wire.encodeMessage(&buf, 9, attach_op, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));
    try H.expectCursor(&sink, 6, 9, 3, 3);

    // a shape replaces the surface: its commits no longer re-send anything
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 1, &.{ .{ .uint = serial }, .{ .uint = 9 } })); // set_shape(text)
    try std.testing.expectEqual(@as(u32, 9), sink.shape_value);
    try comp.onWire(1, wire.encodeMessage(&buf, 9, offset_op, &.{ .{ .int = 1 }, .{ .int = 1 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 6), sink.cursor_calls);
    // ...and a surface replaces the shape
    try H.setCursor(&comp, &buf, serial, 9, 0, 0);
    try H.expectCursor(&sink, 7, 9, 0, 0);
    // NULL hides the pointer
    try H.setCursor(&comp, &buf, serial, 0, 0, 0);
    try H.expectCursor(&sink, 8, 0, 0, 0);

    // leave: back to the default, and the old enter's serial is dead
    try H.setCursor(&comp, &buf, serial, 9, 4, 4);
    sink.shape_calls = 0;
    comp.pointerLeave(1);
    try std.testing.expectEqual(@as(u32, 1), sink.shape_calls);
    try std.testing.expectEqual(cursor_shape_reset, sink.shape_value);
    try H.setCursor(&comp, &buf, serial, 9, 4, 4);
    try comp.onWire(1, wire.encodeMessage(&buf, 9, commit_op, &.{}));
    try std.testing.expectEqual(@as(u32, 9), sink.cursor_calls);

    // destroyed while it is the image: hidden, and the reused id is no cursor
    comp.pointerEnter(1, 6, 0, 0);
    try H.setCursor(&comp, &buf, comp.conns.get(1).?.pointer_enter_serial, 9, 4, 4);
    try H.expectCursor(&sink, 10, 9, 4, 4);
    try comp.onWire(1, wire.encodeMessage(&buf, 9, destroy_op, &.{}));
    try H.expectCursor(&sink, 11, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), comp.conns.get(1).?.cursor_surface);
}

test "pointer motion/button/axis are dropped without pointer focus" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    var buf: [256]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 5 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{.{ .new_id = 7 }})); // get_pointer
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }})); // create_surface
    sink.events.clearRetainingCapacity();

    // no surface entered: motion/button/axis must be swallowed (foot
    // dereferences its null focus and SIGSEGVs on e.g. axis-after-leave)
    comp.pointerMotion(1, 1, 256, 256, null);
    comp.pointerButton(1, 2, 0x110, true);
    comp.pointerAxis(1, 3, 0, 2560, 0);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // entered: events flow. A pure-continuous scroll at seat v5 emits
    // axis_source + axis + frame (no discrete component)
    comp.pointerEnter(1, 9, 0, 0);
    sink.events.clearRetainingCapacity();
    comp.pointerAxis(1, 4, 0, 2560, 0);
    try std.testing.expectEqual(@as(usize, 3), sink.events.items.len);

    // left again: swallowed again
    comp.pointerLeave(1);
    sink.events.clearRetainingCapacity();
    comp.pointerMotion(1, 5, 256, 256, null);
    comp.pointerButton(1, 6, 0x110, false);
    comp.pointerAxis(1, 7, 0, 2560, 120);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

test "wl_seat v9 wheel: axis_source, axis_relative_direction, axis_value120 + axis" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    var buf: [256]u8 = undefined;
    // conn 1 binds wl_seat at v9 (get_pointer inherits the version)
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 5 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{.{ .new_id = 7 }})); // get_pointer
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }})); // create_surface
    comp.pointerEnter(1, 9, 0, 0);

    const p = comptime protocol.find("wl_pointer").?;
    const src_op = comptime p.eventIndex("axis_source").?;
    const dir_op = comptime p.eventIndex("axis_relative_direction").?;
    const v120_op = comptime p.eventIndex("axis_value120").?;
    const axis_op = comptime p.eventIndex("axis").?;
    const frame_op = comptime p.eventIndex("frame").?;

    // vertical wheel, half a detent (value120 = 60): a v9 client gets the
    // whole coupled sequence in one frame, and axis_discrete is NEVER sent
    sink.events.clearRetainingCapacity();
    comp.pointerAxis(1, 100, 0, 1280, 60);
    var vals: [wire.max_args]wire.Value = undefined;
    try std.testing.expectEqual(@as(usize, 5), sink.events.items.len);
    try std.testing.expectEqual(src_op, sink.events.items[0].opcode);
    try std.testing.expectEqual(dir_op, sink.events.items[1].opcode);
    const dir = sink.events.items[1];
    const dir_args = try wire.decodeArgs(dir.bytes[wire.header_size..dir.len], &.{ .uint, .uint }, &vals);
    try std.testing.expectEqual(@as(u32, 0), dir_args[0].uint); // axis vertical
    try std.testing.expectEqual(axis_direction_identical, dir_args[1].uint);
    // axis_value120 carries the exact 120-fraction; coupled before axis
    try std.testing.expectEqual(v120_op, sink.events.items[2].opcode);
    const v120 = sink.events.items[2];
    const v120_args = try wire.decodeArgs(v120.bytes[wire.header_size..v120.len], &.{ .uint, .int }, &vals);
    try std.testing.expectEqual(@as(u32, 0), v120_args[0].uint);
    try std.testing.expectEqual(@as(i32, 60), v120_args[1].int);
    try std.testing.expectEqual(axis_op, sink.events.items[3].opcode);
    const ax = sink.events.items[3];
    const ax_args = try wire.decodeArgs(ax.bytes[wire.header_size..ax.len], &.{ .uint, .uint, .fixed }, &vals);
    try std.testing.expectEqual(@as(i32, 1280), ax_args[2].fixed);
    try std.testing.expectEqual(frame_op, sink.events.items[4].opcode);

    // a v7 client gets axis_discrete (whole steps) instead of value120 and
    // never sees axis_relative_direction. Two full detents up = -2 steps.
    try comp.connOpen(2);
    try comp.onWire(2, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 7, .id = 5 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 5, 0, &.{.{ .new_id = 7 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }}));
    comp.pointerEnter(2, 9, 0, 0);
    const disc_op = comptime p.eventIndex("axis_discrete").?;
    sink.events.clearRetainingCapacity();
    comp.pointerAxis(2, 100, 0, -2560, -240);
    // axis_source + axis_discrete + axis + frame (no value120, no direction)
    try std.testing.expectEqual(@as(usize, 4), sink.events.items.len);
    try std.testing.expectEqual(src_op, sink.events.items[0].opcode);
    try std.testing.expectEqual(disc_op, sink.events.items[1].opcode);
    const disc = sink.events.items[1];
    const disc_args = try wire.decodeArgs(disc.bytes[wire.header_size..disc.len], &.{ .uint, .int }, &vals);
    try std.testing.expectEqual(@as(i32, -2), disc_args[1].int);
    try std.testing.expectEqual(axis_op, sink.events.items[2].opcode);
    try std.testing.expectEqual(frame_op, sink.events.items[3].opcode);
}

test "xdg_toplevel move/resize/maximize: interactive callbacks + configures" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.interactive_fn = TestSink.interactive;
    comp.desk_w = 1500;
    comp.desk_h = 1000;

    var buf: [256]u8 = undefined;
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }})); // create_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 10 }, .{ .object = 9 } })); // get_xdg_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 10, 1, &.{.{ .new_id = 11 }})); // get_toplevel
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 6, &.{})); // initial commit: configured

    const tl = comptime protocol.find("xdg_toplevel").?;
    const move_op = comptime tl.requestIndex("move").?;
    const resize_op = comptime tl.requestIndex("resize").?;
    const max_op = comptime tl.requestIndex("set_maximized").?;
    const unmax_op = comptime tl.requestIndex("unset_maximized").?;

    // a press held on the window: wl_seat 5, wl_pointer 12
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 5 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{.{ .new_id = 12 }})); // get_pointer
    comp.pointerEnter(1, 9, 0, 0);
    comp.pointerButton(1, 0, 0x110, true);
    const held = comp.conns.get(1).?.serial;

    // move → embedder drag callback (kind 0), no protocol events
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 11, move_op, &.{ .{ .object = 5 }, .{ .uint = held } }));
    try std.testing.expectEqual(@as(u32, 0), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 9), sink.inter_surface);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // resize → callback (kind 1) with the edges bitmask (bottom-right = 10)
    try comp.onWire(1, wire.encodeMessage(&buf, 11, resize_op, &.{ .{ .object = 5 }, .{ .uint = held }, .{ .uint = 10 } }));
    try std.testing.expectEqual(@as(u32, 1), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 10), sink.inter_value);

    // floating size seen from a presented buffer → unmaximize restore target
    comp.noteBufferSize(1, 9, 800, 600);

    // set_maximized → configure(desk size, [maximized]) + kind 2
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 11, max_op, &.{}));
    try std.testing.expectEqual(@as(u32, 2), sink.inter_kind);
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // xdg_toplevel + xdg_surface configure
    var vals: [wire.max_args]wire.Value = undefined;
    const max_cfg = sink.events.items[0];
    const max_args = try wire.decodeArgs(max_cfg.bytes[wire.header_size..max_cfg.len], &.{ .int, .int, .array }, &vals);
    try std.testing.expectEqual(@as(i32, 1500), max_args[0].int);
    try std.testing.expectEqual(@as(i32, 1000), max_args[1].int);
    try std.testing.expectEqual(@as(usize, 4), max_args[2].array.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, max_args[2].array[0..4], .little)); // maximized

    // maximized-size commits must NOT overwrite the restore size,
    // and the grip resize is ignored while maximized
    comp.noteBufferSize(1, 9, 1500, 1000);
    sink.events.clearRetainingCapacity();
    comp.requestResize(1, 9, 555, 444);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // unset_maximized → configure back to the floating size + kind 3
    try comp.onWire(1, wire.encodeMessage(&buf, 11, unmax_op, &.{}));
    try std.testing.expectEqual(@as(u32, 3), sink.inter_kind);
    const un_cfg = sink.events.items[0];
    const un_args = try wire.decodeArgs(un_cfg.bytes[wire.header_size..un_cfg.len], &.{ .int, .int, .array }, &vals);
    try std.testing.expectEqual(@as(i32, 800), un_args[0].int);
    try std.testing.expectEqual(@as(i32, 600), un_args[1].int);
    try std.testing.expectEqual(@as(usize, 0), un_args[2].array.len);
}

test "clipboard: selection follows focus, receive routes to source, replace cancels" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;

    var buf: [256]u8 = undefined;

    // conn 1: the SOURCE (wl-copy shaped). manager=3, source=4, device=5.
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 4 }})); // create_data_source
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .string = "text/plain" }})); // offer
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 1, &.{ .{ .new_id = 5 }, .{ .object = 6 } })); // get_data_device (seat id fake)
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 4 }, .{ .uint = testInputSerial(&comp, 1) } })); // set_selection

    // conn 2: the RECEIVER with a focused toplevel + keyboard + data device.
    try comp.connOpen(2);
    try comp.onWire(2, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 5 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 6 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 7 }})); // get_keyboard
    try comp.onWire(2, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 5 } })); // get_data_device
    try comp.onWire(2, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }})); // create_surface
    try comp.onWire(2, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 10 }, .{ .object = 9 } })); // get_xdg_surface
    try comp.onWire(2, wire.encodeMessage(&buf, 10, 1, &.{.{ .new_id = 11 }})); // get_toplevel
    sink.events.clearRetainingCapacity();

    // focus enters → keyboard enter + modifiers + data_offer/offer/selection
    comp.keyboardEnter(2, 9);
    try std.testing.expectEqual(@as(usize, 5), sink.events.items.len);
    const offer_intro = sink.events.items[2]; // after enter + modifiers
    try std.testing.expectEqual(@as(u32, 8), offer_intro.object_id); // on the data device
    var vals: [wire.max_args]wire.Value = undefined;
    const intro_args = try wire.decodeArgs(offer_intro.bytes[wire.header_size..offer_intro.len], &.{.new_id}, &vals);
    const offer_id = intro_args[0].new_id;
    try std.testing.expect(offer_id >= objects.server_id_base);
    const mime_ev = sink.events.items[3];
    try std.testing.expectEqual(offer_id, mime_ev.object_id); // offer("text/plain") on the offer
    const sel_ev = sink.events.items[4];
    try std.testing.expectEqual(@as(u32, 8), sel_ev.object_id); // selection on the data device

    // receiver asks for the content: receive(mime, fd) arrives via pipe FDMSG
    const receive_op = comptime protocol.find("wl_data_offer").?.requestIndex("receive").?;
    const rcv = wire.encodeMessage(&buf, offer_id, receive_op, &.{ .{ .string = "text/plain" }, .fd });
    comp.onPipeReceive(2, rcv, 42);
    try std.testing.expectEqual(@as(u32, 1), sink.fdmsg_conn); // routed to SOURCE conn
    try std.testing.expectEqual(@as(u32, 3), sink.fdmsg_kind); // pipe
    try std.testing.expectEqual(@as(u32, 42), sink.fdmsg_token);
    const send_header = try wire.Header.parse(sink.fdmsg_bytes[0..sink.fdmsg_len]);
    try std.testing.expectEqual(@as(u32, 4), send_header.object_id); // the data source
    const send_args = try wire.decodeArgs(sink.fdmsg_bytes[wire.header_size..sink.fdmsg_len], &.{ .string, .fd }, &vals);
    try std.testing.expectEqualStrings("text/plain", send_args[0].string.?);

    // a new selection replaces the old → old source gets cancelled
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 12 }})); // second source
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 12 }, .{ .uint = testInputSerial(&comp, 1) } }));
    const cancelled_op = comptime protocol.find("wl_data_source").?.eventIndex("cancelled").?;
    var saw_cancelled = false;
    for (sink.events.items) |ev| {
        if (ev.conn_id == 1 and ev.object_id == 4 and ev.opcode == cancelled_op) saw_cancelled = true;
    }
    try std.testing.expect(saw_cancelled);
}

/// setOwnSelection's packed entries (test helper): data null = alias of the
/// previous entry's data.
fn packOwnSelection(out: []u8, entries: []const struct { []const u8, ?[]const u8 }) []u8 {
    var n: usize = 0;
    for (entries) |e| {
        std.mem.writeInt(u32, out[n..][0..4], @intCast(e[0].len), .little);
        @memcpy(out[n + 4 ..][0..e[0].len], e[0]);
        n += 4 + e[0].len;
        if (e[1]) |d| {
            std.mem.writeInt(u32, out[n..][0..4], @intCast(d.len), .little);
            @memcpy(out[n + 4 ..][0..d.len], d);
            n += 4 + d.len;
        } else {
            std.mem.writeInt(u32, out[n..][0..4], 0xffffffff, .little);
            n += 4;
        }
    }
    return out[0..n];
}

test "clipboard: the embedder's own selection is offered to the focused client only, served from the core; reads of a client's go to its source" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;
    comp.selection_fn = TestSink.selection;
    comp.applyFeature(@intFromEnum(stream.FeatureKind.selection_cache), &.{});

    var buf: [256]u8 = undefined;
    var vals: [wire.max_args]wire.Value = undefined;
    const receive_op = comptime protocol.find("wl_data_offer").?.requestIndex("receive").?;
    const cancelled_op = comptime protocol.find("wl_data_source").?.eventIndex("cancelled").?;
    const send_op = comptime protocol.find("wl_data_source").?.eventIndex("send").?;
    const offer_op = comptime protocol.find("wl_data_offer").?.eventIndex("offer").?;
    const selection_op = comptime protocol.find("wl_data_device").?.eventIndex("selection").?;

    // conn 1: a wl-copy shaped source. manager=3, source=4, device=5.
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 4 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 1, &.{ .{ .new_id = 5 }, .{ .object = 6 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 4 }, .{ .uint = testInputSerial(&comp, 1) } }));
    try std.testing.expectEqual(@as(u32, 1), sink.sel_calls);
    try std.testing.expectEqual(@as(u32, 1), sink.sel_conn);
    try std.testing.expectEqualStrings("text/plain", sink.sel_mimes[0..sink.sel_mimes_len]);

    // the embedder reads it: send(mime, fd) to the source in a pipe_read
    try std.testing.expect(comp.readSelection("text/plain", 7, 1000));
    try std.testing.expectEqual(@as(u32, 1), sink.fdmsg_conn);
    try std.testing.expectEqual(@intFromEnum(stream.FdMsgKind.pipe_read), sink.fdmsg_kind);
    const send_hdr = try wire.Header.parse(sink.fdmsg_bytes[0..sink.fdmsg_len]);
    try std.testing.expectEqual(@as(u32, 4), send_hdr.object_id);
    try std.testing.expectEqual(send_op, send_hdr.opcode);
    try std.testing.expectEqualStrings("text/plain", (try wire.decodeArgs(sink.fdmsg_bytes[wire.header_size..sink.fdmsg_len], &.{ .string, .fd }, &vals))[0].string.?);
    try std.testing.expectEqual(@as(usize, 8), sink.fdmsg_aux_len);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, sink.fdmsg_aux[0..4], .little));
    try std.testing.expectEqual(@as(u32, 1000), std.mem.readInt(u32, sink.fdmsg_aux[4..8], .little));
    try std.testing.expect(!comp.readSelection("image/png", 8, 1000)); // not offered

    // conn 2: focused receiver; conn 3: a data device, never focused
    for ([_]u32{ 2, 3 }) |c| {
        try comp.connOpen(c);
        try comp.onWire(c, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
        try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 5 } } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 6 } } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 7 }}));
        try comp.onWire(c, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 5 } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }}));
        try comp.onWire(c, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 10 }, .{ .object = 9 } }));
        try comp.onWire(c, wire.encodeMessage(&buf, 10, 1, &.{.{ .new_id = 11 }}));
    }
    comp.keyboardEnter(2, 9);
    sink.events.clearRetainingCapacity();

    // bad entries change nothing: an alias with nothing before it, a NUL in a mime
    var pack: [256]u8 = undefined;
    try std.testing.expectError(error.BadSelection, comp.setOwnSelection(packOwnSelection(&pack, &.{.{ "text/plain", null }})));
    try std.testing.expectError(error.BadSelection, comp.setOwnSelection(packOwnSelection(&pack, &.{.{ "text\x00plain", "x" }})));
    try std.testing.expectError(error.BadSelection, comp.setOwnSelection("\x05\x00"));
    // clearing when a client owns it: not ours to clear
    try comp.setOwnSelection("");
    try std.testing.expectEqual(@as(u32, 1), sink.sel_calls);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // the embedder's own: the source is cancelled, the focused conn alone is offered it
    try comp.setOwnSelection(packOwnSelection(&pack, &.{ .{ "text/plain;charset=utf-8", "h\xc3\xa9llo" }, .{ "text/plain", null }, .{ "UTF8_STRING", null } }));
    try std.testing.expectEqual(@as(u32, 2), sink.sel_calls);
    try std.testing.expectEqual(@as(u32, 0), sink.sel_conn);
    try std.testing.expectEqualStrings("text/plain;charset=utf-8,text/plain,UTF8_STRING", sink.sel_mimes[0..sink.sel_mimes_len]);
    var own_offer: u32 = 0;
    var offers: usize = 0;
    var cancelled = false;
    for (sink.events.items) |ev| {
        try std.testing.expect(ev.conn_id != 3);
        if (ev.conn_id == 1 and ev.object_id == 4 and ev.opcode == cancelled_op) cancelled = true;
        if (ev.conn_id == 2 and ev.opcode == offer_op and ev.object_id >= objects.server_id_base) {
            own_offer = ev.object_id;
            offers += 1;
        }
    }
    try std.testing.expect(cancelled);
    try std.testing.expectEqual(@as(usize, 3), offers);
    try std.testing.expect(!comp.readSelection("text/plain", 9, 1000)); // the embedder has the bytes

    // a receive is answered from the core: no wire message, FDMSG own_pipe
    // with the token and (the first time) the bytes
    comp.onPipeReceive(2, wire.encodeMessage(&buf, own_offer, receive_op, &.{ .{ .string = "UTF8_STRING" }, .fd }), 42);
    try std.testing.expectEqual(@as(u32, 2), sink.fdmsg_conn);
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FdMsgKind.own_pipe)), sink.fdmsg_kind);
    try std.testing.expectEqual(@as(usize, 0), sink.fdmsg_len);
    const own_msg = try stream.OwnPipe.decode(sink.fdmsg_aux[0..sink.fdmsg_aux_len]);
    try std.testing.expectEqual(@as(u32, 42), own_msg.token);
    try std.testing.expectEqualStrings("h\xc3\xa9llo", own_msg.bytes);
    // a mime it does not have: EOF (the token alone)
    comp.onPipeReceive(2, wire.encodeMessage(&buf, own_offer, receive_op, &.{ .{ .string = "image/png" }, .fd }), 43);
    try std.testing.expectEqual(@as(usize, 4), sink.fdmsg_aux_len);
    try std.testing.expectEqual(@as(u32, 43), std.mem.readInt(u32, sink.fdmsg_aux[0..4], .little));

    // a newer own selection: the old offer reads EOF
    try comp.setOwnSelection(packOwnSelection(&pack, &.{.{ "text/plain", "second" }}));
    comp.onPipeReceive(2, wire.encodeMessage(&buf, own_offer, receive_op, &.{ .{ .string = "text/plain" }, .fd }), 44);
    try std.testing.expectEqual(@as(usize, 4), sink.fdmsg_aux_len);

    // a client takes it back: the own selection is gone (its offers read EOF)
    var own2: u32 = 0;
    for (sink.events.items) |ev| {
        if (ev.conn_id == 2 and ev.opcode == offer_op and ev.object_id >= objects.server_id_base) own2 = ev.object_id;
    }
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 12 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 12 }, .{ .uint = testInputSerial(&comp, 1) } }));
    try std.testing.expectEqual(@as(u32, 1), sink.sel_conn);
    try std.testing.expect(comp.own_selection == null);
    comp.onPipeReceive(2, wire.encodeMessage(&buf, own2, receive_op, &.{ .{ .string = "text/plain" }, .fd }), 45);
    try std.testing.expectEqual(@as(usize, 4), sink.fdmsg_aux_len);
    try std.testing.expectEqual(@as(u32, 45), std.mem.readInt(u32, sink.fdmsg_aux[0..4], .little));

    // own again, then cleared by the embedder: the focused client hears selection(null)
    try comp.setOwnSelection(packOwnSelection(&pack, &.{.{ "text/plain", "third" }}));
    sink.events.clearRetainingCapacity();
    try comp.setOwnSelection("");
    try std.testing.expectEqual(@as(u32, 0), sink.sel_conn);
    try std.testing.expectEqual(@as(usize, 0), sink.sel_mimes_len);
    try std.testing.expect(comp.selection == null);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(selection_op, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, sink.events.items[0].bytes[8..12], .little));
}

test "clipboard: a relay without FEATURE selection_cache (wlandr 0.1.0) is never sent pipe_read or own-selection frames, and no client is offered an embedder selection it could not paste" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;
    comp.selection_fn = TestSink.selection;
    // other features don't turn it on
    comp.applyFeature(@intFromEnum(stream.FeatureKind.dmabuf_kind), &[_]u8{ 1, 0, 0, 0 });
    try selConn(&comp, 1);
    comp.keyboardEnter(1, 11);
    const T = SelTest;
    // conn 1 copies: clients' selections work as ever
    try T.sources(&comp);
    try T.setSel(&comp, 1, 20, testInputSerial(&comp, 1));
    try std.testing.expectEqual(@as(u32, 1), sink.sel_conn);
    const calls = sink.fdmsg_calls;
    // the embedder can't read it: nothing sent (no FDMSG pipe_read)
    try std.testing.expect(!comp.readSelection("text/plain", 1, 1000));
    try std.testing.expectEqual(calls, sink.fdmsg_calls);
    // nor set its own: refused, nothing offered, the client's source stays
    sink.events.clearRetainingCapacity();
    var pack: [64]u8 = undefined;
    try std.testing.expectError(error.Unsupported, comp.setOwnSelection(packOwnSelection(&pack, &.{.{ "text/plain", "page" }})));
    try std.testing.expectError(error.Unsupported, comp.setOwnSelection(""));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expect(comp.own_selection == null);
    try std.testing.expectEqual([2]u32{ 1, 20 }, T.owner(comp.selection).?);
    try std.testing.expectEqual(calls, sink.fdmsg_calls);
}

test "primary selection: offer on keyboard enter, receive routes to source, replace cancels" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;

    var buf: [256]u8 = undefined;

    // conn 1: the SOURCE (foot-shaped primary owner). manager=3, source=4,
    // device=5. Primary manager requests: create_source(0), get_device(1).
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 4 }})); // create_source
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .string = "text/plain" }})); // source.offer
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 1, &.{ .{ .new_id = 5 }, .{ .object = 6 } })); // get_device (seat id fake)
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{ .{ .object = 4 }, .{ .uint = testInputSerial(&comp, 1) } })); // device.set_selection

    // conn 2: the RECEIVER with a focused toplevel + keyboard + primary device.
    try comp.connOpen(2);
    try comp.onWire(2, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 5 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 6 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 7 }})); // get_keyboard
    try comp.onWire(2, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 5 } })); // get_device
    try comp.onWire(2, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 9 }})); // create_surface
    try comp.onWire(2, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 10 }, .{ .object = 9 } })); // get_xdg_surface
    try comp.onWire(2, wire.encodeMessage(&buf, 10, 1, &.{.{ .new_id = 11 }})); // get_toplevel
    sink.events.clearRetainingCapacity();

    // focus enters → keyboard enter + modifiers + data_offer/offer/selection.
    // conn 2 has no wl_data_device or text_input, so those deliveries no-op.
    comp.keyboardEnter(2, 9);
    try std.testing.expectEqual(@as(usize, 5), sink.events.items.len);
    const offer_intro = sink.events.items[2]; // after enter + modifiers
    try std.testing.expectEqual(@as(u32, 8), offer_intro.object_id); // on the primary device
    var vals: [wire.max_args]wire.Value = undefined;
    const intro_args = try wire.decodeArgs(offer_intro.bytes[wire.header_size..offer_intro.len], &.{.new_id}, &vals);
    const offer_id = intro_args[0].new_id;
    // the offer id is a contiguous server id AND was announced to the transport
    // as a primary offer (SRVOBJ) so the server intercepts primary receive
    try std.testing.expect(offer_id >= objects.server_id_base);
    try std.testing.expectEqual(offer_id, sink.srvobj_id);
    try std.testing.expectEqual(srvobj_kind_primary_offer, sink.srvobj_kind);
    try std.testing.expect(sink.isPrimary(offer_id));
    const mime_ev = sink.events.items[3];
    try std.testing.expectEqual(offer_id, mime_ev.object_id); // offer("text/plain") on the offer
    const sel_ev = sink.events.items[4];
    try std.testing.expectEqual(@as(u32, 8), sel_ev.object_id); // selection on the primary device

    // receiver asks for the content: receive(mime, fd) arrives via pipe FDMSG.
    // primary offer.receive is opcode 0 (vs wl_data_offer's 1).
    const receive_op = comptime protocol.find("zwp_primary_selection_offer_v1").?.requestIndex("receive").?;
    const rcv = wire.encodeMessage(&buf, offer_id, receive_op, &.{ .{ .string = "text/plain" }, .fd });
    comp.onPipeReceive(2, rcv, 55);
    try std.testing.expectEqual(@as(u32, 1), sink.fdmsg_conn); // routed to SOURCE conn
    try std.testing.expectEqual(@as(u32, 3), sink.fdmsg_kind); // pipe
    try std.testing.expectEqual(@as(u32, 55), sink.fdmsg_token);
    const send_header = try wire.Header.parse(sink.fdmsg_bytes[0..sink.fdmsg_len]);
    try std.testing.expectEqual(@as(u32, 4), send_header.object_id); // the primary source
    // the routed event is the PRIMARY source's send (opcode differs from data)
    const primary_send_op = comptime protocol.find("zwp_primary_selection_source_v1").?.eventIndex("send").?;
    try std.testing.expectEqual(primary_send_op, send_header.opcode);
    const send_args = try wire.decodeArgs(sink.fdmsg_bytes[wire.header_size..sink.fdmsg_len], &.{ .string, .fd }, &vals);
    try std.testing.expectEqualStrings("text/plain", send_args[0].string.?);

    // a new selection replaces the old → old source gets cancelled
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 12 }})); // second source
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{ .{ .object = 12 }, .{ .uint = testInputSerial(&comp, 1) } }));
    const cancelled_op = comptime protocol.find("zwp_primary_selection_source_v1").?.eventIndex("cancelled").?;
    var saw_cancelled = false;
    for (sink.events.items) |ev| {
        if (ev.conn_id == 1 and ev.object_id == 4 and ev.opcode == cancelled_op) saw_cancelled = true;
    }
    try std.testing.expect(saw_cancelled);

    // the cancelled source is destroyed; the receiver still holds its offer.
    // A receive on it is answered with a bare token (the server closes the
    // fd → EOF), also once the client reuses the id for a new source
    // (xwayland-satellite hung in read() on exactly this).
    const destroy_op = comptime protocol.find("zwp_primary_selection_source_v1").?.requestIndex("destroy").?;
    try comp.onWire(1, wire.encodeMessage(&buf, 4, destroy_op, &.{}));
    const stale = wire.encodeMessage(&buf, offer_id, receive_op, &.{ .{ .string = "text/plain" }, .fd });
    comp.onPipeReceive(2, stale, 56);
    try std.testing.expectEqual(@as(u32, 3), sink.fdmsg_kind);
    try std.testing.expectEqual(@as(u32, 56), sink.fdmsg_token);
    try std.testing.expectEqual(@as(usize, 0), sink.fdmsg_len);
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 4 }})); // id 4 again
    comp.onPipeReceive(2, wire.encodeMessage(&buf, offer_id, receive_op, &.{ .{ .string = "text/plain" }, .fd }), 57);
    try std.testing.expectEqual(@as(u32, 57), sink.fdmsg_token);
    try std.testing.expectEqual(@as(usize, 0), sink.fdmsg_len);
    // an offer id nobody allocated: same answer
    comp.onPipeReceive(2, wire.encodeMessage(&buf, offer_id + 40, receive_op, &.{ .{ .string = "text/plain" }, .fd }), 58);
    try std.testing.expectEqual(@as(u32, 58), sink.fdmsg_token);
    try std.testing.expectEqual(@as(usize, 0), sink.fdmsg_len);
}

test "server-id typing: data + primary offers share the contiguous id space; only primary is SRVOBJ-flagged" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;

    var buf: [256]u8 = undefined;

    // conn 1 owns BOTH the clipboard and the primary selection.
    // manager(clip)=3 source=4 device=5 ; manager(primary)=6 source=7 device=8.
    try comp.connOpen(1);
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 4 }})); // clip create_data_source
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 1, &.{ .{ .new_id = 5 }, .{ .object = 99 } })); // clip get_data_device
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 4 }, .{ .uint = testInputSerial(&comp, 1) } })); // clip set_selection
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 6 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 7 }})); // primary create_source
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 99 } })); // primary get_device
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 0, &.{ .{ .object = 7 }, .{ .uint = testInputSerial(&comp, 1) } })); // primary set_selection

    // conn 2 receives both selections: bind clip manager(6) + primary manager(9),
    // a keyboard, both devices, and a mapped toplevel.
    try comp.connOpen(2);
    try comp.onWire(2, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 5 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 6 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 9 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 7 }})); // get_keyboard (obj 7)
    try comp.onWire(2, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 5 } })); // clip get_data_device (obj 8)
    try comp.onWire(2, wire.encodeMessage(&buf, 9, 1, &.{ .{ .new_id = 10 }, .{ .object = 5 } })); // primary get_device (obj 10)
    try comp.onWire(2, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 11 }})); // create_surface
    try comp.onWire(2, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 12 }, .{ .object = 11 } })); // get_xdg_surface
    try comp.onWire(2, wire.encodeMessage(&buf, 12, 1, &.{.{ .new_id = 13 }})); // get_toplevel
    sink.events.clearRetainingCapacity();

    comp.keyboardEnter(2, 11);

    // find each device's data_offer intro and extract the allocated offer id
    const dd_offer_op = comptime protocol.find("wl_data_device").?.eventIndex("data_offer").?;
    const pd_offer_op = comptime protocol.find("zwp_primary_selection_device_v1").?.eventIndex("data_offer").?;
    var data_offer_id: u32 = 0;
    var primary_offer_id: u32 = 0;
    var vals: [wire.max_args]wire.Value = undefined;
    for (sink.events.items) |ev| {
        const args = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.new_id}, &vals);
        if (ev.object_id == 8 and ev.opcode == dd_offer_op) data_offer_id = args[0].new_id;
        if (ev.object_id == 10 and ev.opcode == pd_offer_op) primary_offer_id = args[0].new_id;
    }
    // both draw from the SAME contiguous server-id counter (libwayland needs
    // dense ids); they never collide, and the type is conveyed out of band:
    // only the primary offer is SRVOBJ-flagged, the data offer is not.
    try std.testing.expect(data_offer_id >= objects.server_id_base);
    try std.testing.expect(primary_offer_id >= objects.server_id_base);
    try std.testing.expect(data_offer_id != primary_offer_id);
    try std.testing.expect(sink.isPrimary(primary_offer_id));
    try std.testing.expect(!sink.isPrimary(data_offer_id));
    // exactly one SRVOBJ registration fired (the primary offer)
    try std.testing.expectEqual(@as(u32, 1), sink.srvobj_calls);
}

test "batched messages in one onWire call" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(7);
    var buf: [128]u8 = undefined;
    const m1 = wire.encodeMessage(buf[0..32], 1, 1, &.{.{ .new_id = 2 }});
    const m2 = wire.encodeMessage(buf[32..64], 1, 0, &.{.{ .new_id = 3 }});
    var batch: [64]u8 = undefined;
    @memcpy(batch[0..m1.len], m1);
    @memcpy(batch[m1.len..][0..m2.len], m2);
    try comp.onWire(7, batch[0 .. m1.len + m2.len]);
    // globals + done + delete_id
    try std.testing.expectEqual(globals.len + 2, sink.events.items.len);
}

/// Full client stack for dnd tests: registry 2, wl_compositor 3, wl_seat 4
/// (pointer 10), xdg_wm_base 5, data_device_manager 6 (device 11), and a
/// mapped toplevel (surface 7, xdg_surface 8, toplevel 9).
fn dndConnSetup(comp: *Compositor, conn_id: u32) !void {
    var buf: [128]u8 = undefined;
    try comp.connOpen(conn_id);
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 4 } } }));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 5 } } }));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 6 } } }));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 10 }})); // get_pointer
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 11 }, .{ .object = 4 } })); // get_data_device
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 7 }})); // create_surface
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 5, 2, &.{ .{ .new_id = 8 }, .{ .object = 7 } })); // get_xdg_surface
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 8, 1, &.{.{ .new_id = 9 }})); // get_toplevel
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 7, 6, &.{})); // commit
}

test "dnd: full drag conn1→conn2 — offer, actions, drop, transfer, finish" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.interactive_fn = TestSink.interactive;
    comp.fdmsg_fn = TestSink.fdmsg;

    try dndConnSetup(&comp, 1);
    try dndConnSetup(&comp, 2);
    var buf: [128]u8 = undefined;
    // conn1: source 12 offers text/plain, actions copy|move
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 12 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 2, &.{.{ .uint = dnd_action_copy | dnd_action_move }}));
    // press on the origin, then start_drag(source 12, origin 7, no icon)
    comp.pointerEnter(1, 7, 0, 0);
    comp.pointerButton(1, 0, 0x110, true);
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = comp.conns.get(1).?.serial } })); // the press
    try std.testing.expectEqual(@as(u32, 4), sink.inter_kind); // dnd session started
    try std.testing.expectEqual(@as(u32, 7), sink.inter_surface);
    comp.pointerLeave(1); // the embedder's part: the drag grab steals the pointer

    const dd = comptime protocol.find("wl_data_device").?;
    const off = comptime protocol.find("wl_data_offer").?;
    const src = comptime protocol.find("wl_data_source").?;

    // over conn2's toplevel: data_offer intro → offer(mime) → source_actions → enter
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 1000, 2560, 5120);
    try std.testing.expectEqual(@as(usize, 4), sink.events.items.len);
    var vals: [wire.max_args]wire.Value = undefined;
    const ev0 = sink.events.items[0];
    try std.testing.expectEqual(dd.eventIndex("data_offer").?, ev0.opcode);
    try std.testing.expectEqual(@as(u32, 11), ev0.object_id);
    try std.testing.expectEqual(@as(u32, 2), ev0.conn_id);
    const offer_id = (try wire.decodeArgs(ev0.bytes[wire.header_size..ev0.len], &.{.new_id}, &vals))[0].new_id;
    try std.testing.expect(offer_id >= objects.server_id_base);
    const ev1 = sink.events.items[1];
    try std.testing.expectEqual(offer_id, ev1.object_id);
    try std.testing.expectEqualStrings("text/plain", (try wire.decodeArgs(ev1.bytes[wire.header_size..ev1.len], &.{.string}, &vals))[0].string.?);
    try std.testing.expectEqual(off.eventIndex("source_actions").?, sink.events.items[2].opcode);
    const ev3 = sink.events.items[3];
    try std.testing.expectEqual(dd.eventIndex("enter").?, ev3.opcode);
    const enter_args = try wire.decodeArgs(ev3.bytes[wire.header_size..ev3.len], &.{ .uint, .object, .fixed, .fixed, .object }, &vals);
    try std.testing.expectEqual(@as(u32, 7), enter_args[1].object);
    try std.testing.expectEqual(@as(i32, 2560), enter_args[2].fixed);
    try std.testing.expectEqual(offer_id, enter_args[4].object);

    // target accepts + negotiates: target(conn1) then action to both ends
    sink.events.clearRetainingCapacity();
    try comp.onWire(2, wire.encodeMessage(&buf, offer_id, 0, &.{ .{ .uint = 1 }, .{ .string = "text/plain" } }));
    try comp.onWire(2, wire.encodeMessage(&buf, offer_id, 4, &.{ .{ .uint = dnd_action_copy }, .{ .uint = dnd_action_copy } }));
    try std.testing.expectEqual(@as(usize, 3), sink.events.items.len);
    try std.testing.expectEqual(src.eventIndex("target").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[0].conn_id);
    try std.testing.expectEqual(@as(u32, 12), sink.events.items[0].object_id);
    const act1 = sink.events.items[1];
    try std.testing.expectEqual(off.eventIndex("action").?, act1.opcode);
    try std.testing.expectEqual(dnd_action_copy, (try wire.decodeArgs(act1.bytes[wire.header_size..act1.len], &.{.uint}, &vals))[0].uint);
    try std.testing.expectEqual(src.eventIndex("action").?, sink.events.items[2].opcode);

    // motion within the same target
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 1100, 2600, 5200);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(dd.eventIndex("motion").?, sink.events.items[0].opcode);

    // drop: conn2 drop, conn1 dnd_drop_performed, session ends (kind 5)
    sink.events.clearRetainingCapacity();
    comp.dragDrop();
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(dd.eventIndex("drop").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 2), sink.events.items[0].conn_id);
    try std.testing.expectEqual(src.eventIndex("dnd_drop_performed").?, sink.events.items[1].opcode);
    try std.testing.expectEqual(@as(u32, 5), sink.inter_kind);

    // transfer rides the existing pipe path: receive routes to the source
    // as wl_data_source.send with the fd token echoed
    const recv = wire.encodeMessage(&buf, offer_id, 1, &.{ .{ .string = "text/plain" }, .fd });
    comp.onPipeReceive(2, recv, 77);
    try std.testing.expectEqual(@as(u32, 1), sink.fdmsg_conn);
    try std.testing.expectEqual(@as(u32, 3), sink.fdmsg_kind);
    try std.testing.expectEqual(@as(u32, 77), sink.fdmsg_token);

    // finish → dnd_finished to the source, routed via the offers map
    sink.events.clearRetainingCapacity();
    try comp.onWire(2, wire.encodeMessage(&buf, offer_id, 3, &.{}));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(src.eventIndex("dnd_finished").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[0].conn_id);

    // normal pointer flow works again after the session
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(1, 7, 0, 0);
    try std.testing.expect(sink.events.items.len > 0);
}

test "dnd: leave on retarget, unaccepted drop cancels, icon role lifecycle" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.interactive_fn = TestSink.interactive;

    try dndConnSetup(&comp, 1);
    try dndConnSetup(&comp, 2);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 12 }})); // source
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 13 }})); // icon surface
    comp.pointerEnter(1, 7, 0, 0);
    comp.pointerButton(1, 0, 0x110, true);
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 13 }, .{ .uint = comp.conns.get(1).?.serial } }));
    try std.testing.expectEqual(Role.dnd_icon, comp.surfaceRole(1, 13));
    try std.testing.expectEqual(@as(u32, 13), sink.inter_value); // icon id rides kind 4

    const dd = comptime protocol.find("wl_data_device").?;
    const src = comptime protocol.find("wl_data_source").?;

    // normal pointer delivery is suppressed during the drag
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(2, 7, 0, 0);
    comp.pointerMotion(2, 0, 0, 0, null);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // enter conn2, then off into the void → leave; drag icon is not a target
    comp.dragMotion(2, 7, 100, 256, 256);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(0, 0, 200, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(dd.eventIndex("leave").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 2), sink.events.items[0].conn_id);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(1, 13, 300, 0, 0); // over the icon itself: no target
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // re-enter conn2 (fresh offer), then drop WITHOUT accept → cancel:
    // leave to conn2, cancelled to the source, session end, icon role reverts
    comp.dragMotion(2, 7, 400, 256, 256);
    sink.events.clearRetainingCapacity();
    comp.dragDrop();
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(dd.eventIndex("leave").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(src.eventIndex("cancelled").?, sink.events.items[1].opcode);
    try std.testing.expectEqual(@as(u32, 12), sink.events.items[1].object_id);
    try std.testing.expectEqual(@as(u32, 5), sink.inter_kind);
    try std.testing.expectEqual(Role.none, comp.surfaceRole(1, 13));
    try std.testing.expectEqual(@as(?Drag, null), comp.drag);
}

test "dnd: source destroy mid-drag cancels silently; conn close cancels" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.interactive_fn = TestSink.interactive;

    try dndConnSetup(&comp, 1);
    try dndConnSetup(&comp, 2);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 12 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{.{ .string = "text/plain" }}));
    comp.pointerEnter(1, 7, 0, 0);
    comp.pointerButton(1, 0, 0x110, true);
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = comp.conns.get(1).?.serial } }));
    comp.dragMotion(2, 7, 100, 256, 256);

    const dd = comptime protocol.find("wl_data_device").?;

    // destroying the dragged source ends the session: leave to the target,
    // NO cancelled to the (destroyed) source, delete_id to conn1
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 1, &.{})); // wl_data_source.destroy
    try std.testing.expectEqual(@as(?Drag, null), comp.drag);
    try std.testing.expectEqual(@as(u32, 5), sink.inter_kind);
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(dd.eventIndex("leave").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 2), sink.events.items[0].conn_id);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[1].object_id); // delete_id on conn1

    // fresh drag; the source conn closing cancels the session
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 14 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 14, 0, &.{.{ .string = "text/plain" }}));
    comp.pointerEnter(1, 7, 0, 0);
    comp.pointerButton(1, 0, 0x110, true);
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 14 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = comp.conns.get(1).?.serial } }));
    comp.dragMotion(2, 7, 100, 256, 256);
    sink.events.clearRetainingCapacity();
    comp.connClose(1);
    try std.testing.expectEqual(@as(?Drag, null), comp.drag);
    try std.testing.expectEqual(@as(u32, 5), sink.inter_kind);
    // conn2 (the target) got its leave; nothing went to the dead conn1
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(dd.eventIndex("leave").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 2), sink.events.items[0].conn_id);
}

// ---------------------------------------------------------------------------
// linux-dmabuf
// ---------------------------------------------------------------------------

const fourcc_argb8888: u32 = 0x34325241;
const fourcc_xrgb8888: u32 = 0x34325258;

fn dmabufTable() [32]u8 {
    var t: [32]u8 = undefined;
    for ([_]u32{ fourcc_argb8888, fourcc_xrgb8888 }, 0..) |f, i| {
        std.mem.writeInt(u32, t[i * 16 ..][0..4], f, .little);
        std.mem.writeInt(u32, t[i * 16 + 4 ..][0..4], 0, .little);
        std.mem.writeInt(u64, t[i * 16 + 8 ..][0..8], 0, .little); // LINEAR
    }
    return t;
}

/// Error code of the last wl_display.error, or null.
fn lastErrorCode(sink: *const TestSink) ?u32 {
    var i = sink.events.items.len;
    while (i > 0) {
        i -= 1;
        const ev = sink.events.items[i];
        if (ev.object_id != 1 or ev.opcode != comptime protocol.find("wl_display").?.eventIndex("error").?) continue;
        var vals: [wire.max_args]wire.Value = undefined;
        const args = wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals) catch return null;
        return args[1].uint;
    }
    return null;
}

/// get_registry as id 2, bind zwp_linux_dmabuf_v1 at `version` as id 3.
fn dmabufBind(comp: *Compositor, version: u32) !void {
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = dmabuf_global.name }, .{ .new_id_dynamic = .{ .interface = dmabuf_global.interface, .version = version, .id = 3 } } }));
}

fn dmabufAdd(comp: *Compositor, params: u32, plane: u32, modifier: u64) !void {
    var buf: [64]u8 = undefined;
    // as the relay forwards it (FDMSG kind dmabuf → onWire): the fd carries no bytes
    try comp.onWire(1, wire.encodeMessage(&buf, params, comptime protocol.find("zwp_linux_buffer_params_v1").?.requestIndex("add").?, &.{
        .fd, .{ .uint = plane }, .{ .uint = 0 }, .{ .uint = 64 }, .{ .uint = @truncate(modifier >> 32) }, .{ .uint = @truncate(modifier) },
    }));
}

test "linux-dmabuf: advertised only after setDmabuf; binding it unadvertised is a protocol error" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try std.testing.expectEqual(globals.len, sink.events.items.len);
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = dmabuf_global.name }, .{ .new_id_dynamic = .{ .interface = dmabuf_global.interface, .version = 4, .id = 3 } } }));
    try std.testing.expectEqual(@as(?u32, display_err_invalid_object), lastErrorCode(&sink));

    const table = dmabufTable();
    try std.testing.expectError(error.BadFormatTable, comp.setDmabuf(1, table[0..20]));
    try comp.setDmabuf(0xe280, &table);
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 4 }}));
    try std.testing.expectEqual(globals.len + 1, sink.events.items.len);
    const last = sink.events.items[globals.len];
    var vals: [wire.max_args]wire.Value = undefined;
    const args = try wire.decodeArgs(last.bytes[wire.header_size..last.len], &.{ .uint, .string, .uint }, &vals);
    try std.testing.expectEqualStrings("zwp_linux_dmabuf_v1", args[1].string.?);
    try std.testing.expectEqual(@as(u32, 4), args[2].uint);
}

test "linux-dmabuf from FEATURE frames: dmabuf_kind virtgpu without a GPU source keeps it off (either order, one log line); with one, shm, or no dmabuf_kind (readback) it is offered" {
    const table = dmabufTable();
    var feat: [8 + table.len]u8 = undefined;
    (stream.DmabufFeature{ .main_device = 0xe280, .table = &table }).encode(&feat);
    var vg: [4]u8 = undefined;
    (stream.DmabufKindFeature{ .buffer_kind = @intFromEnum(stream.BufferKind.virtgpu) }).encode(&vg);
    var shm_kind: [4]u8 = undefined;
    (stream.DmabufKindFeature{ .buffer_kind = @intFromEnum(stream.BufferKind.shm) }).encode(&shm_kind);
    const unknown_kind = [_]u8{ 9, 0, 0, 0 };
    const Case = struct { gpu: bool, kind: ?[]const u8, kind_first: bool = true, offered: bool };
    const cases = [_]Case{
        .{ .gpu = true, .kind = &vg, .offered = true },
        .{ .gpu = false, .kind = &vg, .offered = false },
        .{ .gpu = false, .kind = &vg, .kind_first = false, .offered = false }, // out of order: still off
        .{ .gpu = false, .kind = null, .offered = true }, // readback: pixels in the stream
        .{ .gpu = false, .kind = &shm_kind, .offered = true },
        .{ .gpu = true, .kind = &unknown_kind, .offered = false }, // a kind it can't show
        .{ .gpu = true, .kind = vg[0..3], .offered = false }, // bad bytes: unknown kind
    };
    for (cases) |c| {
        var sink: TestSink = undefined;
        var comp = testSetup(&sink);
        defer comp.deinit();
        defer sink.events.deinit(sink.gpa);
        comp.gpu_source = c.gpu;
        if (!c.kind_first) comp.applyFeature(@intFromEnum(stream.FeatureKind.linux_dmabuf), &feat);
        if (c.kind) |k| comp.applyFeature(@intFromEnum(stream.FeatureKind.dmabuf_kind), k);
        if (c.kind_first) comp.applyFeature(@intFromEnum(stream.FeatureKind.linux_dmabuf), &feat);
        comp.applyFeature(77, "skipped"); // unknown feature: logged, nothing else
        try std.testing.expectEqual(c.offered, comp.dmabuf != null);
        // offered: setDmabuf's line; refused: exactly one about why (plus the unknown feature's)
        try std.testing.expectEqual(@as(u32, 2), sink.logs - @as(u32, if (c.kind_first or c.offered) 0 else 1));
        try comp.connOpen(1);
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
        try std.testing.expectEqual(globals.len + @intFromBool(c.offered), sink.events.items.len);
        if (!c.offered) { // binding it anyway: a protocol error, as for any unadvertised global
            try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = dmabuf_global.name }, .{ .new_id_dynamic = .{ .interface = dmabuf_global.interface, .version = 4, .id = 3 } } }));
            try std.testing.expectEqual(@as(?u32, display_err_invalid_object), lastErrorCode(&sink));
        }
    }
}

test "linux-dmabuf: feedback is the format table (memfd FDMSG), main device, one tranche of every entry, done; v3 gets modifier events" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    comp.fdmsg_fn = TestSink.fdmsg;
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    const table = dmabufTable();
    try comp.setDmabuf(0xe280, &table);
    try comp.connOpen(1);
    try dmabufBind(&comp, 4);
    sink.events.clearRetainingCapacity();

    var buf: [64]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 3, comptime protocol.find("zwp_linux_dmabuf_v1").?.requestIndex("get_default_feedback").?, &.{.{ .new_id = 5 }}));
    try std.testing.expectEqual(@as(u32, 2), sink.fdmsg_kind); // memfd
    try std.testing.expectEqual(table.len, sink.fdmsg_aux_len);
    const ft = try wire.Header.parse(sink.fdmsg_bytes[0..sink.fdmsg_len]);
    try std.testing.expectEqual(@as(u32, 5), ft.object_id);
    var vals: [wire.max_args]wire.Value = undefined;
    const ft_args = try wire.decodeArgs(sink.fdmsg_bytes[wire.header_size..sink.fdmsg_len], &.{ .fd, .uint }, &vals);
    try std.testing.expectEqual(@as(u32, table.len), ft_args[1].uint);

    const fb = comptime protocol.find("zwp_linux_dmabuf_feedback_v1").?;
    const want = [_]u16{ fb.eventIndex("main_device").?, fb.eventIndex("tranche_target_device").?, fb.eventIndex("tranche_flags").?, fb.eventIndex("tranche_formats").?, fb.eventIndex("tranche_done").?, fb.eventIndex("done").? };
    try std.testing.expectEqual(want.len, sink.events.items.len);
    for (sink.events.items, want) |ev, opcode| {
        try std.testing.expectEqual(@as(u32, 5), ev.object_id);
        try std.testing.expectEqual(opcode, ev.opcode);
    }
    const dev = try wire.decodeArgs(sink.events.items[0].bytes[wire.header_size..sink.events.items[0].len], &.{.array}, &vals);
    try std.testing.expectEqual(@as(u64, 0xe280), std.mem.readInt(u64, dev[0].array[0..8], .little));
    const fmts = try wire.decodeArgs(sink.events.items[3].bytes[wire.header_size..sink.events.items[3].len], &.{.array}, &vals);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0 }, fmts[0].array);

    // a v3 client learns the pairs at bind; v1/v2 (implicit modifiers) nothing
    try comp.connOpen(2);
    try comp.onWire(2, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    sink.events.clearRetainingCapacity();
    var bbuf: [128]u8 = undefined;
    try comp.onWire(2, wire.encodeMessage(&bbuf, 2, 0, &.{ .{ .uint = dmabuf_global.name }, .{ .new_id_dynamic = .{ .interface = dmabuf_global.interface, .version = 3, .id = 3 } } }));
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    const m = try wire.decodeArgs(sink.events.items[1].bytes[wire.header_size..sink.events.items[1].len], &.{ .uint, .uint, .uint }, &vals);
    try std.testing.expectEqual(fourcc_xrgb8888, m[0].uint);
    sink.events.clearRetainingCapacity();
    try comp.onWire(2, wire.encodeMessage(&bbuf, 2, 0, &.{ .{ .uint = dmabuf_global.name }, .{ .new_id_dynamic = .{ .interface = dmabuf_global.interface, .version = 2, .id = 4 } } }));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

test "linux-dmabuf: a table with implicit-modifier entries (virtgpu's) gives v1/v2 binders one format event per such format; create with MOD_INVALID passes" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    comp.fdmsg_fn = TestSink.fdmsg;
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    // XR24/INVALID, AR24/INVALID, XR24/LINEAR, AR24/INVALID again (a dup)
    var table: [64]u8 = undefined;
    for ([_]struct { u32, u64 }{ .{ fourcc_xrgb8888, dmabuf_mod_invalid }, .{ fourcc_argb8888, dmabuf_mod_invalid }, .{ fourcc_xrgb8888, 0 }, .{ fourcc_argb8888, dmabuf_mod_invalid } }, 0..) |e, i| {
        std.mem.writeInt(u32, table[i * 16 ..][0..4], e[0], .little);
        std.mem.writeInt(u32, table[i * 16 + 4 ..][0..4], 0, .little);
        std.mem.writeInt(u64, table[i * 16 + 8 ..][0..8], e[1], .little);
    }
    try comp.setDmabuf(0xe280, &table);
    try comp.connOpen(1);
    try dmabufBind(&comp, 2);
    var vals: [wire.max_args]wire.Value = undefined;
    var got: [4]u32 = undefined;
    var n: usize = 0;
    const format_op = comptime protocol.find("zwp_linux_dmabuf_v1").?.eventIndex("format").?;
    for (sink.events.items) |ev| {
        if (ev.object_id != 3 or ev.opcode != format_op) continue;
        got[n] = (try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.uint}, &vals))[0].uint;
        n += 1;
    }
    try std.testing.expectEqualSlices(u32, &.{ fourcc_xrgb8888, fourcc_argb8888 }, got[0..n]);

    // params with the implicit modifier: accepted (no error)
    var buf: [64]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 3, comptime protocol.find("zwp_linux_dmabuf_v1").?.requestIndex("create_params").?, &.{.{ .new_id = 4 }}));
    try dmabufAdd(&comp, 4, 0, dmabuf_mod_invalid);
    try comp.onWire(1, wire.encodeMessage(&buf, 4, comptime protocol.find("zwp_linux_buffer_params_v1").?.requestIndex("create_immed").?, &.{ .{ .new_id = 5 }, .{ .int = 8 }, .{ .int = 8 }, .{ .uint = fourcc_xrgb8888 }, .{ .uint = 0 } }));
    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
}

test "linux-dmabuf params: create_immed makes the client's wl_buffer; create a dense server id, DMABUF_CREATED before created" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    comp.dmabuf_created_fn = TestSink.dmabufCreated;
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    const table = dmabufTable();
    try comp.setDmabuf(0xe280, &table);
    try comp.connOpen(1);
    try dmabufBind(&comp, 4);
    const dm = comptime protocol.find("zwp_linux_dmabuf_v1").?;
    const pm = comptime protocol.find("zwp_linux_buffer_params_v1").?;
    var buf: [64]u8 = undefined;

    try comp.onWire(1, wire.encodeMessage(&buf, 3, dm.requestIndex("create_params").?, &.{.{ .new_id = 10 }}));
    try dmabufAdd(&comp, 10, 0, 0);
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 10, pm.requestIndex("create_immed").?, &.{ .{ .new_id = 11 }, .{ .int = 16 }, .{ .int = 8 }, .{ .uint = fourcc_xrgb8888 }, .{ .uint = 0 } }));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // no event on success
    try std.testing.expectEqualStrings("wl_buffer", comp.conns.get(1).?.objects.get(11).?.iface.name);
    // params destroy: delete_id, state gone
    try comp.onWire(1, wire.encodeMessage(&buf, 10, pm.requestIndex("destroy").?, &.{}));
    try std.testing.expect(comp.conns.get(1).?.dmabuf_params.get(10) == null);

    try comp.onWire(1, wire.encodeMessage(&buf, 3, dm.requestIndex("create_params").?, &.{.{ .new_id = 12 }}));
    try dmabufAdd(&comp, 12, 0, 0);
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 12, pm.requestIndex("create").?, &.{ .{ .int = 16 }, .{ .int = 8 }, .{ .uint = fourcc_argb8888 }, .{ .uint = 0 } }));
    try std.testing.expectEqual(@as(u32, 1), sink.dmabuf_created_calls);
    try std.testing.expectEqual(@as(u32, 12), sink.dmabuf_params);
    try std.testing.expectEqual(objects.server_id_base, sink.dmabuf_buffer); // first server id of the conn
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    const ev = sink.events.items[0];
    try std.testing.expectEqual(@as(u32, 12), ev.object_id);
    try std.testing.expectEqual(pm.eventIndex("created").?, ev.opcode);
    try std.testing.expectEqual(objects.server_id_base, std.mem.readInt(u32, ev.bytes[8..12], .little));
    // the server-made buffer is a wl_buffer whose destroy needs no delete_id
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, objects.server_id_base, 0, &.{}));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expect(comp.conns.get(1).?.objects.get(objects.server_id_base) == null);
}

test "linux-dmabuf params: plane_idx, plane_set, already_used, incomplete, invalid_format, invalid_dimensions" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    const table = dmabufTable();
    try comp.setDmabuf(0xe280, &table);
    try comp.connOpen(1);
    try dmabufBind(&comp, 4);
    const dm = comptime protocol.find("zwp_linux_dmabuf_v1").?;
    const pm = comptime protocol.find("zwp_linux_buffer_params_v1").?;
    var buf: [64]u8 = undefined;
    var next: u32 = 20;
    const Case = struct {
        fn params(c: *Compositor, id: *u32) !u32 {
            var b: [32]u8 = undefined;
            id.* += 1;
            try c.onWire(1, wire.encodeMessage(&b, 3, comptime protocol.find("zwp_linux_dmabuf_v1").?.requestIndex("create_params").?, &.{.{ .new_id = id.* }}));
            return id.*;
        }
        fn immed(c: *Compositor, params_id: u32, w: i32, h: i32, format: u32) !void {
            var b: [64]u8 = undefined;
            try c.onWire(1, wire.encodeMessage(&b, params_id, comptime protocol.find("zwp_linux_buffer_params_v1").?.requestIndex("create_immed").?, &.{ .{ .new_id = params_id + 1000 }, .{ .int = w }, .{ .int = h }, .{ .uint = format }, .{ .uint = 0 } }));
        }
    };
    _ = dm;
    _ = &buf;

    var p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 4, 0);
    try std.testing.expectEqual(@as(?u32, dmabuf_err_plane_idx), lastErrorCode(&sink));

    p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 0, 0);
    sink.events.clearRetainingCapacity();
    try dmabufAdd(&comp, p, 0, 0);
    try std.testing.expectEqual(@as(?u32, dmabuf_err_plane_set), lastErrorCode(&sink));

    p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 0, 0);
    sink.events.clearRetainingCapacity();
    try Case.immed(&comp, p, 4, 4, fourcc_xrgb8888);
    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
    try dmabufAdd(&comp, p, 1, 0);
    try std.testing.expectEqual(@as(?u32, dmabuf_err_already_used), lastErrorCode(&sink));
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, p, pm.requestIndex("create").?, &.{ .{ .int = 4 }, .{ .int = 4 }, .{ .uint = fourcc_xrgb8888 }, .{ .uint = 0 } }));
    try std.testing.expectEqual(@as(?u32, dmabuf_err_already_used), lastErrorCode(&sink));

    // no plane 0; two planes for a one-plane format
    p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 1, 0);
    sink.events.clearRetainingCapacity();
    try Case.immed(&comp, p, 4, 4, fourcc_xrgb8888);
    try std.testing.expectEqual(@as(?u32, dmabuf_err_incomplete), lastErrorCode(&sink));
    p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 0, 0);
    try dmabufAdd(&comp, p, 1, 0);
    sink.events.clearRetainingCapacity();
    try Case.immed(&comp, p, 4, 4, fourcc_xrgb8888);
    try std.testing.expectEqual(@as(?u32, dmabuf_err_incomplete), lastErrorCode(&sink));

    // a modifier or a format the table doesn't hold
    p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 0, 0x0100000000000001); // I915_FORMAT_MOD_X_TILED
    sink.events.clearRetainingCapacity();
    try Case.immed(&comp, p, 4, 4, fourcc_xrgb8888);
    try std.testing.expectEqual(@as(?u32, dmabuf_err_invalid_format), lastErrorCode(&sink));
    p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 0, 0);
    sink.events.clearRetainingCapacity();
    try Case.immed(&comp, p, 4, 4, 0x34324241); // ABGR8888: not offered
    try std.testing.expectEqual(@as(?u32, dmabuf_err_invalid_format), lastErrorCode(&sink));

    p = try Case.params(&comp, &next);
    try dmabufAdd(&comp, p, 0, 0);
    sink.events.clearRetainingCapacity();
    try Case.immed(&comp, p, 0, 4, fourcc_xrgb8888);
    try std.testing.expectEqual(@as(?u32, dmabuf_err_invalid_dimensions), lastErrorCode(&sink));
}

// --- wland_external_buffer_manager_v1 ------------------------------------------

const ExtTest = struct {
    const mgr = protocol.find("wland_external_buffer_manager_v1").?;
    const create_op = mgr.requestIndex("create_buffer").?;
    const mgr_destroy_op = mgr.requestIndex("destroy").?;
    const buf_destroy_op = protocol.find("wl_buffer").?.requestIndex("destroy").?;
    const surf = protocol.find("wl_surface").?;
    const attach_op = surf.requestIndex("attach").?;
    const damage_op = surf.requestIndex("damage_buffer").?;
    const commit_op = surf.requestIndex("commit").?;
    const argb: u32 = 0x34325241;

    /// Whether conn 1's registry (id 2) lists the global.
    fn advertised(comp: *Compositor, sink: *TestSink) !bool {
        var buf: [128]u8 = undefined;
        sink.events.clearRetainingCapacity();
        try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
        var vals: [wire.max_args]wire.Value = undefined;
        var found = false;
        for (sink.events.items) |ev| {
            const args = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .uint, .string, .uint }, &vals);
            if (std.mem.eql(u8, args[1].string.?, external_global.interface)) {
                try std.testing.expectEqual(external_global.name, args[0].uint);
                try std.testing.expectEqual(@as(u32, 1), args[2].uint);
                found = true;
            }
        }
        try std.testing.expectEqual(globals.len + @intFromBool(found), sink.events.items.len);
        return found;
    }

    /// Bind the manager as id 3 (registry 2).
    fn bind(comp: *Compositor) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = external_global.name }, .{ .new_id_dynamic = .{ .interface = external_global.interface, .version = 1, .id = 3 } } }));
    }

    fn create(comp: *Compositor, buffer: u32, id: u64, w: i32, h: i32, format: u32, flags: u32) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, 3, create_op, &.{
            .{ .new_id = buffer }, .{ .uint = @truncate(id >> 32) }, .{ .uint = @truncate(id) },
            .{ .int = w },         .{ .int = h },                     .{ .uint = format },
            .{ .uint = flags },
        }));
    }

    /// A link with the global offered, conn 1 open, registry 2, manager 3.
    fn setup(comp: *Compositor, sink: *TestSink) !void {
        comp.external_source = true;
        comp.applyFeature(@intFromEnum(stream.FeatureKind.external_buffer), &.{});
        try comp.connOpen(1);
        try std.testing.expect(try advertised(comp, sink));
        try bind(comp);
        try std.testing.expectEqual(@as(?u32, null), lastErrorCode(sink));
    }
};

test "external buffers: the global needs FEATURE external_buffer AND an embedder that resolves them, in either order; off by default" {
    const Case = struct { feature: bool, source: bool, source_first: bool = true };
    const cases = [_]Case{
        .{ .feature = false, .source = false },
        .{ .feature = true, .source = false },
        .{ .feature = false, .source = true },
        .{ .feature = true, .source = true },
        .{ .feature = true, .source = true, .source_first = false }, // the embedder says after the frame
    };
    {
        var sink: TestSink = undefined;
        var comp = testSetup(&sink);
        defer comp.deinit();
        defer sink.events.deinit(sink.gpa);
        try std.testing.expect(!comp.external_source); // native users never offer it by accident
        try std.testing.expect(!comp.externalOffered());
    }
    for (cases) |c| {
        var sink: TestSink = undefined;
        var comp = testSetup(&sink);
        defer comp.deinit();
        defer sink.events.deinit(sink.gpa);
        if (c.source_first) comp.external_source = c.source;
        if (c.feature) comp.applyFeature(@intFromEnum(stream.FeatureKind.external_buffer), "ignored bytes");
        if (!c.source_first) comp.external_source = c.source;
        const on = c.feature and c.source;
        try std.testing.expectEqual(on, comp.externalOffered());
        // the FEATURE is one log line either way, not fatal
        try std.testing.expectEqual(@as(u32, @intFromBool(c.feature)), sink.logs);
        try comp.connOpen(1);
        try std.testing.expectEqual(on, try ExtTest.advertised(&comp, &sink));
        try ExtTest.bind(&comp);
        if (on) {
            try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
            try std.testing.expectEqualStrings(external_global.interface, comp.conns.get(1).?.objects.get(3).?.iface.name);
        } else {
            // never advertised: binding it anyway is refused, as linux-dmabuf's
            try std.testing.expectEqual(@as(?u32, display_err_invalid_object), lastErrorCode(&sink));
        }
    }
}

test "external buffers: create_buffer makes the client's wl_buffer; attach, commit and destroy need nothing more; the manager's destroy leaves its buffers" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try ExtTest.setup(&comp, &sink);
    var buf: [128]u8 = undefined;
    // the bounds and every known flag pass
    try ExtTest.create(&comp, 10, 0xdead_beef_0000_0007, 64, 32, ExtTest.argb, 0);
    try ExtTest.create(&comp, 11, 0, 16384, 1, 0x34324258, stream.ExternalRef.flag_y_invert); // XBGR8888, y_invert
    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
    const conn = comp.conns.get(1).?;
    try std.testing.expectEqualStrings("wl_buffer", conn.objects.get(10).?.iface.name);
    try std.testing.expectEqualStrings("wl_buffer", conn.objects.get(11).?.iface.name);

    // the manager goes; its buffers stay
    try comp.onWire(1, wire.encodeMessage(&buf, 3, ExtTest.mgr_destroy_op, &.{}));
    try std.testing.expect(conn.objects.get(3) == null);
    try std.testing.expect(conn.objects.get(10) != null);

    // a surface shows it like any buffer (it enters the output)
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = 6 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, ExtTest.attach_op, &.{ .{ .object = 10 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, ExtTest.damage_op, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 64 }, .{ .int = 32 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, ExtTest.commit_op, &.{}));
    comp.noteBufferSize(1, 6, 64, 32); // what the engine does with the COMMIT's size
    const s = conn.surfaces.get(6).?;
    try std.testing.expectEqual(@as(i32, 64), s.log_w);
    try std.testing.expectEqual(@as(i32, 32), s.log_h);

    // destroy while attached: delete_id, nothing else
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 10, ExtTest.buf_destroy_op, &.{}));
    try std.testing.expect(conn.objects.get(10) == null);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u16, comptime protocol.find("wl_display").?.eventIndex("delete_id").?), sink.events.items[0].opcode);
    try comp.onWire(1, wire.encodeMessage(&buf, 6, ExtTest.attach_op, &.{ .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, ExtTest.commit_op, &.{}));
    try std.testing.expectEqual(@as(?u32, null), lastErrorCode(&sink));
}

test "external buffers: create_buffer's protocol errors on the manager, in the XML's order" {
    const fourcc_nv12: u32 = 0x3231564e;
    const Case = struct { w: i32, h: i32, format: u32, flags: u32, err: u32 };
    const cases = [_]Case{
        .{ .w = 8, .h = 8, .format = fourcc_nv12, .flags = 0, .err = external_err_invalid_format },
        .{ .w = 8, .h = 8, .format = 0, .flags = 0, .err = external_err_invalid_format }, // a wl_shm code is not a fourcc
        .{ .w = 0, .h = 8, .format = ExtTest.argb, .flags = 0, .err = external_err_invalid_dimensions },
        .{ .w = 8, .h = -1, .format = ExtTest.argb, .flags = 0, .err = external_err_invalid_dimensions },
        .{ .w = 16385, .h = 8, .format = ExtTest.argb, .flags = 0, .err = external_err_invalid_dimensions },
        .{ .w = 8, .h = 16385, .format = ExtTest.argb, .flags = 0, .err = external_err_invalid_dimensions },
        .{ .w = 8, .h = 8, .format = ExtTest.argb, .flags = 2, .err = external_err_invalid_flags },
        .{ .w = 8, .h = 8, .format = ExtTest.argb, .flags = 0x8000_0001, .err = external_err_invalid_flags },
        // more than one wrong: format first, then dimensions
        .{ .w = 0, .h = 0, .format = fourcc_nv12, .flags = 4, .err = external_err_invalid_format },
        .{ .w = 0, .h = 0, .format = ExtTest.argb, .flags = 4, .err = external_err_invalid_dimensions },
    };
    for (cases) |c| {
        var sink: TestSink = undefined;
        var comp = testSetup(&sink);
        defer comp.deinit();
        defer sink.events.deinit(sink.gpa);
        try ExtTest.setup(&comp, &sink);
        sink.events.clearRetainingCapacity();
        try ExtTest.create(&comp, 10, 1, c.w, c.h, c.format, c.flags);
        try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
        const ev = sink.events.items[0];
        var vals: [wire.max_args]wire.Value = undefined;
        const args = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{ .object, .uint, .string }, &vals);
        try std.testing.expectEqual(@as(u32, 3), args[0].object); // on the manager
        try std.testing.expectEqual(c.err, args[1].uint);
    }
}

test "external buffers: a new link starts with the global off (the relay's FEATURE and the embedder's word are per link)" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer sink.events.deinit(sink.gpa);
    try ExtTest.setup(&comp, &sink);
    // a link that opens again is a fresh compositor (wasm wland_init); its
    // relay's FEATURE frames decide again, the embedder's flag is re-set
    comp.deinit();
    sink.events.deinit(sink.gpa);
    comp = testSetup(&sink);
    defer comp.deinit();
    try std.testing.expect(!comp.external_relay);
    comp.external_source = true;
    try comp.connOpen(1);
    try std.testing.expect(!try ExtTest.advertised(&comp, &sink));
}

// --- pointer constraints + relative pointer -----------------------------------

const PtrTest = struct {
    const surf = protocol.find("wl_surface").?;
    const attach_op = surf.requestIndex("attach").?;
    const commit_op = surf.requestIndex("commit").?;
    const destroy_op = surf.requestIndex("destroy").?;
    const input_op = surf.requestIndex("set_input_region").?;
    const create_region_op = protocol.find("wl_compositor").?.requestIndex("create_region").?;
    const add_op = protocol.find("wl_region").?.requestIndex("add").?;
    const lock_op = protocol.find("zwp_pointer_constraints_v1").?.requestIndex("lock_pointer").?;
    const confine_op = protocol.find("zwp_pointer_constraints_v1").?.requestIndex("confine_pointer").?;
    const locked_iface = protocol.find("zwp_locked_pointer_v1").?;
    const confined_iface = protocol.find("zwp_confined_pointer_v1").?;
    const locked_ev = locked_iface.eventIndex("locked").?;
    const unlocked_ev = locked_iface.eventIndex("unlocked").?;
    const confined_ev = confined_iface.eventIndex("confined").?;
    const unconfined_ev = confined_iface.eventIndex("unconfined").?;
    const lock_region_op = locked_iface.requestIndex("set_region").?;
    const confine_region_op = confined_iface.requestIndex("set_region").?;
    const ptr = protocol.find("wl_pointer").?;
    const enter_ev = ptr.eventIndex("enter").?;
    const leave_ev = ptr.eventIndex("leave").?;
    const motion_ev = ptr.eventIndex("motion").?;
    const button_ev = ptr.eventIndex("button").?;
    const frame_ev = ptr.eventIndex("frame").?;
    const rel_ev = protocol.find("zwp_relative_pointer_v1").?.eventIndex("relative_motion").?;
    const err_ev = protocol.find("wl_display").?.eventIndex("error").?;
    const delete_ev = protocol.find("wl_display").?.eventIndex("delete_id").?;

    // object ids: registry 2, wl_compositor 3, wl_seat 4, constraints 5,
    // relative manager 6, wl_pointer 7, surface 9 (100×80, mapped)
    const PTR = 7;
    const SURF = 9;
    fn setup(comp: *Compositor, sink: *TestSink) !void {
        comp.pointer_lock_fn = TestSink.pointerLock;
        var buf: [128]u8 = undefined;
        try comp.connOpen(1);
        try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
        try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 6, .id = 3 } } }));
        try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 4 } } }));
        try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 16 }, .{ .new_id_dynamic = .{ .interface = "zwp_pointer_constraints_v1", .version = 1, .id = 5 } } }));
        try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 15 }, .{ .new_id_dynamic = .{ .interface = "zwp_relative_pointer_manager_v1", .version = 1, .id = 6 } } }));
        try comp.onWire(1, wire.encodeMessage(&buf, 4, 0, &.{.{ .new_id = PTR }})); // get_pointer
        try surface(comp, SURF, 100, 80);
        sink.events.clearRetainingCapacity();
    }
    fn surface(comp: *Compositor, id: u32, w: u32, h: u32) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = id }}));
        try comp.onWire(1, wire.encodeMessage(&buf, id, attach_op, &.{ .{ .object = 50 }, .{ .int = 0 }, .{ .int = 0 } }));
        try comp.onWire(1, wire.encodeMessage(&buf, id, commit_op, &.{}));
        comp.noteBufferSize(1, id, w, h);
    }
    fn region(comp: *Compositor, id: u32, x: i32, y: i32, w: i32, h: i32) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, 3, create_region_op, &.{.{ .new_id = id }}));
        if (w > 0) try comp.onWire(1, wire.encodeMessage(&buf, id, add_op, &.{ .{ .int = x }, .{ .int = y }, .{ .int = w }, .{ .int = h } }));
    }
    fn constrain(comp: *Compositor, lock: bool, id: u32, surface_id: u32, region_id: u32, lifetime: u32) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, 5, if (lock) lock_op else confine_op, &.{
            .{ .new_id = id }, .{ .object = surface_id }, .{ .object = PTR }, .{ .object = region_id }, .{ .uint = lifetime },
        }));
    }
    fn send(comp: *Compositor, obj: u32, op: u16, args: []const wire.Value) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, obj, op, args));
    }
    fn px(v: i32) i32 {
        return v * 256;
    }
    fn rel(dx: i32, dy: i32) Relative {
        return .{ .dx = dx * 256, .dy = dy * 256, .dx_unaccel = dx * 128, .dy_unaccel = dy * 128, .utime = (5 << 32) | 7 };
    }
    /// the events since the last clear, as {object, opcode} — exactly
    fn expect(sink: *TestSink, want: []const [2]u32) !void {
        var got: [32][2]u32 = undefined;
        const n = @min(sink.events.items.len, got.len);
        for (sink.events.items[0..n], 0..) |e, i| got[i] = .{ e.object_id, e.opcode };
        try std.testing.expectEqualSlices([2]u32, want, got[0..n]);
        sink.events.clearRetainingCapacity();
    }
    /// argument word `i` (after the header) of event `n`
    fn word(sink: *TestSink, n: usize, i: usize) u32 {
        return std.mem.readInt(u32, sink.events.items[n].bytes[8 + i * 4 ..][0..4], .little);
    }
    fn state(comp: *Compositor, id: u32) @TypeOf(@as(Constraint, undefined).state) {
        return comp.conns.get(1).?.constraints.get(id).?.state;
    }
};

test "relative pointer: relative_motion to each relative pointer of the focused client, after the motion, before the frame" {
    const T = PtrTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.send(&comp, 6, 1, &.{ .{ .new_id = 10 }, .{ .object = T.PTR } }); // get_relative_pointer
    try T.send(&comp, 6, 1, &.{ .{ .new_id = 11 }, .{ .object = T.PTR } });

    // no pointer focus: nothing, relative or not
    comp.pointerMotion(1, 1, T.px(5), T.px(5), T.rel(3, -2));
    try T.expect(&sink, &.{});
    comp.pointerEnter(1, T.SURF, T.px(5), T.px(5));
    sink.events.clearRetainingCapacity();
    comp.pointerMotion(1, 2, T.px(8), T.px(3), T.rel(3, -2));
    try std.testing.expectEqual(@as(u32, 5), T.word(&sink, 1, 0)); // utime hi
    try std.testing.expectEqual(@as(u32, 7), T.word(&sink, 1, 1)); // utime lo
    try std.testing.expectEqual(@as(u32, @bitCast(T.px(3))), T.word(&sink, 1, 2)); // dx
    try std.testing.expectEqual(@as(u32, @bitCast(T.px(-2))), T.word(&sink, 1, 3)); // dy
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, 3 * 128))), T.word(&sink, 1, 4)); // dx_unaccel
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -2 * 128))), T.word(&sink, 1, 5)); // dy_unaccel
    try T.expect(&sink, &.{ .{ T.PTR, T.motion_ev }, .{ 10, T.rel_ev }, .{ 11, T.rel_ev }, .{ T.PTR, T.frame_ev } });
    // no movement in it (or none given): just the motion
    comp.pointerMotion(1, 3, T.px(9), T.px(3), T.rel(0, 0));
    comp.pointerMotion(1, 4, T.px(9), T.px(4), null);
    try T.expect(&sink, &.{ .{ T.PTR, T.motion_ev }, .{ T.PTR, T.frame_ev }, .{ T.PTR, T.motion_ev }, .{ T.PTR, T.frame_ev } });
    // a destroyed one gets no more
    try T.send(&comp, 11, 0, &.{});
    try T.expect(&sink, &.{.{ 1, T.delete_ev }});
    comp.pointerMotion(1, 5, T.px(9), T.px(4), T.rel(1, 0));
    try T.expect(&sink, &.{ .{ T.PTR, T.motion_ev }, .{ 10, T.rel_ev }, .{ T.PTR, T.frame_ev } });
}

test "pointer lock: wanted until the embedder's grant, then locked; frozen motion, relative still; oneshot vs persistent; focus loss, destroy" {
    const T = PtrTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.send(&comp, 6, 1, &.{ .{ .new_id = 10 }, .{ .object = T.PTR } });

    // requested before the pointer is there: nothing yet
    try T.constrain(&comp, true, 20, T.SURF, 0, 1); // oneshot, no region
    try T.expect(&sink, &.{});
    try std.testing.expectEqual(@as(u32, 0), sink.lock_calls);
    // the pointer enters: the embedder is asked for the lock, the client
    // hears nothing until it is granted, and still gets its motion
    comp.pointerEnter(1, T.SURF, T.px(10), T.px(10));
    try std.testing.expectEqual(@as(u32, 1), sink.lock_calls);
    try std.testing.expectEqual(@as(u32, T.SURF), sink.lock_surface);
    try T.expect(&sink, &.{ .{ T.PTR, T.enter_ev }, .{ T.PTR, T.frame_ev } });
    comp.pointerMotion(1, 1, T.px(12), T.px(11), T.rel(2, 1));
    try T.expect(&sink, &.{ .{ T.PTR, T.motion_ev }, .{ 10, T.rel_ev }, .{ T.PTR, T.frame_ev } });
    // a grant for a surface no lock waits on is ignored
    comp.pointerLockGranted(1, 33);
    try T.expect(&sink, &.{});
    comp.pointerLockGranted(1, T.SURF);
    try T.expect(&sink, &.{.{ 20, T.locked_ev }});
    try std.testing.expectEqual(.active, T.state(&comp, 20));
    // locked: no wl_pointer.motion, the relative motion goes on; buttons too
    comp.pointerMotion(1, 2, T.px(50), T.px(50), T.rel(40, 40));
    comp.pointerMotion(1, 3, T.px(50), T.px(50), null);
    comp.pointerButton(1, 4, 0x110, true);
    try T.expect(&sink, &.{ .{ 10, T.rel_ev }, .{ T.PTR, T.frame_ev }, .{ T.PTR, T.button_ev }, .{ T.PTR, T.frame_ev } });
    try std.testing.expectEqual(T.px(12), comp.conns.get(1).?.pointer_x); // frozen

    // the browser lost it (Esc): unlocked, and a oneshot lock is dead
    comp.pointerLockLost(1);
    try T.expect(&sink, &.{.{ 20, T.unlocked_ev }});
    try std.testing.expectEqual(.defunct, T.state(&comp, 20));
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
    comp.pointerLockGranted(1, T.SURF); // late: nothing
    try T.expect(&sink, &.{});

    // a defunct one no longer counts: a persistent lock may replace it,
    // and is wanted at once (the pointer is in)
    try T.constrain(&comp, true, 21, T.SURF, 0, 2);
    try std.testing.expectEqual(@as(u32, T.SURF), sink.lock_surface);
    comp.pointerLockGranted(1, T.SURF);
    try T.expect(&sink, &.{.{ 21, T.locked_ev }});
    // lost: unlocked, and wanted again straight away (the embedder keeps
    // its want and retries at the next user gesture: no new call)
    const calls = sink.lock_calls;
    comp.pointerLockLost(1);
    try T.expect(&sink, &.{.{ 21, T.unlocked_ev }});
    try std.testing.expectEqual(.wanted, T.state(&comp, 21));
    try std.testing.expectEqual(calls, sink.lock_calls);
    comp.pointerLockGranted(1, T.SURF);
    try T.expect(&sink, &.{.{ 21, T.locked_ev }});

    // the pointer leaves: unlocked first, then the leave; the embedder lets go
    comp.pointerLeave(1);
    try T.expect(&sink, &.{ .{ 21, T.unlocked_ev }, .{ T.PTR, T.leave_ev }, .{ T.PTR, T.frame_ev } });
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
    try std.testing.expectEqual(.inactive, T.state(&comp, 21));
    // back in: wanted again; destroying it lets go (no event: it is gone)
    comp.pointerEnter(1, T.SURF, T.px(10), T.px(10));
    try std.testing.expectEqual(@as(u32, T.SURF), sink.lock_surface);
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 21, 0, &.{});
    try T.expect(&sink, &.{.{ 1, T.delete_ev }});
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);

    // the surface destroyed while locked: unlocked, defunct, let go
    try T.constrain(&comp, true, 22, T.SURF, 0, 2);
    comp.pointerLockGranted(1, T.SURF);
    sink.events.clearRetainingCapacity();
    try T.send(&comp, T.SURF, T.destroy_op, &.{});
    try std.testing.expectEqual(@as(u32, 22), sink.events.items[0].object_id);
    try std.testing.expectEqual(@as(u16, T.unlocked_ev), sink.events.items[0].opcode);
    try std.testing.expectEqual(.defunct, T.state(&comp, 22));
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
}

test "pointer constraints: one per surface (already_constrained), a defunct one doesn't count; requests on a gone surface are inert" {
    const T = PtrTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.surface(&comp, 12, 50, 50);
    sink.events.clearRetainingCapacity();
    // a lock on one surface, a confinement on another: fine
    try T.constrain(&comp, true, 20, T.SURF, 0, 2);
    try T.constrain(&comp, false, 21, 12, 0, 2);
    try T.expect(&sink, &.{});
    // a second of either kind on the same surface: the error, on the manager
    try T.constrain(&comp, false, 22, T.SURF, 0, 2);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u16, T.err_ev), sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 5), T.word(&sink, 0, 0));
    try std.testing.expectEqual(constraints_err_already_constrained, T.word(&sink, 0, 1));
    sink.events.clearRetainingCapacity();
    // a constraint on a destroyed surface never applies
    try T.send(&comp, 12, T.destroy_op, &.{});
    try std.testing.expectEqual(.defunct, T.state(&comp, 21));
    try T.constrain(&comp, true, 23, 77, 0, 2);
    try std.testing.expectEqual(.defunct, T.state(&comp, 23));
}

test "lock region: wanted only inside region ∩ input region; withdrawn when the pointer leaves it; set_region latched by commit" {
    const T = PtrTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.region(&comp, 30, 0, 0, 20, 20);
    try T.region(&comp, 31, 0, 0, 50, 50);
    try T.send(&comp, T.SURF, T.input_op, &.{.{ .object = 31 }});
    try T.send(&comp, T.SURF, T.commit_op, &.{});
    try T.constrain(&comp, true, 20, T.SURF, 30, 2);

    comp.pointerEnter(1, T.SURF, T.px(30), T.px(30));
    try std.testing.expectEqual(@as(u32, 0), sink.lock_calls); // outside the region
    comp.pointerMotion(1, 1, T.px(5), T.px(5), null);
    try std.testing.expectEqual(@as(u32, T.SURF), sink.lock_surface);
    comp.pointerMotion(1, 2, T.px(20), T.px(5), null); // the box's right edge is exclusive
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
    try std.testing.expectEqual(.inactive, T.state(&comp, 20));
    // set_region(NULL) = the input region alone, from the next commit
    try T.send(&comp, 20, T.lock_region_op, &.{.{ .object = 0 }});
    comp.pointerMotion(1, 3, T.px(25), T.px(5), null);
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
    try T.send(&comp, T.SURF, T.commit_op, &.{});
    try std.testing.expectEqual(@as(u32, T.SURF), sink.lock_surface);
    // outside the input region (still on the surface: the implicit grab)
    comp.pointerMotion(1, 4, T.px(60), T.px(5), null);
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
    // and off the surface itself
    try T.send(&comp, T.SURF, T.input_op, &.{.{ .object = 0 }});
    try T.send(&comp, T.SURF, T.commit_op, &.{});
    try std.testing.expectEqual(@as(u32, T.SURF), sink.lock_surface);
    comp.pointerMotion(1, 5, T.px(-3), T.px(5), null);
    try std.testing.expectEqual(@as(u32, 0), sink.lock_surface);
}

test "confine: confined inside its area, motion clamped (relative unclipped), unconfined on leave; set_region warps; oneshot ends for good" {
    const T = PtrTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.send(&comp, 6, 1, &.{ .{ .new_id = 10 }, .{ .object = T.PTR } });
    try T.region(&comp, 30, 10, 10, 20, 20); // [10, 30) both ways
    try T.constrain(&comp, false, 20, T.SURF, 30, 2);

    comp.pointerEnter(1, T.SURF, T.px(5), T.px(5));
    try T.expect(&sink, &.{ .{ T.PTR, T.enter_ev }, .{ T.PTR, T.frame_ev } }); // outside: not yet
    comp.pointerMotion(1, 1, T.px(15), T.px(15), null);
    try T.expect(&sink, &.{ .{ T.PTR, T.motion_ev }, .{ T.PTR, T.frame_ev }, .{ 20, T.confined_ev } });
    try std.testing.expectEqual(@as(u32, 0), sink.lock_calls); // the embedder has nothing to do
    // past the edge: the client sees the pointer at it, the delta whole
    comp.pointerMotion(1, 2, T.px(40), T.px(12), T.rel(25, -3));
    try std.testing.expectEqual(@as(u32, @bitCast(T.px(30) - 1)), T.word(&sink, 0, 1));
    try std.testing.expectEqual(@as(u32, @bitCast(T.px(12))), T.word(&sink, 0, 2));
    try std.testing.expectEqual(@as(u32, @bitCast(T.px(25))), T.word(&sink, 1, 2));
    try T.expect(&sink, &.{ .{ T.PTR, T.motion_ev }, .{ 10, T.rel_ev }, .{ T.PTR, T.frame_ev } });
    // the pointer left the surface: unconfined, then the leave
    comp.pointerLeave(1);
    try T.expect(&sink, &.{ .{ 20, T.unconfined_ev }, .{ T.PTR, T.leave_ev }, .{ T.PTR, T.frame_ev } });
    // persistent: confined again once back inside
    comp.pointerEnter(1, T.SURF, T.px(20), T.px(20));
    try T.expect(&sink, &.{ .{ T.PTR, T.enter_ev }, .{ T.PTR, T.frame_ev }, .{ 20, T.confined_ev } });

    // a new region that moved off the pointer: warped into it at the commit
    try T.region(&comp, 31, 0, 0, 5, 5);
    try T.send(&comp, 20, T.confine_region_op, &.{.{ .object = 31 }});
    try T.expect(&sink, &.{});
    try T.send(&comp, T.SURF, T.commit_op, &.{});
    try std.testing.expectEqual(@as(u32, @bitCast(T.px(5) - 1)), T.word(&sink, 0, 1));
    try T.expect(&sink, &.{ .{ T.PTR, T.motion_ev }, .{ T.PTR, T.frame_ev } });
    // nothing left of the area: unconfined
    try T.region(&comp, 32, 0, 0, 0, 0);
    try T.send(&comp, 20, T.confine_region_op, &.{.{ .object = 32 }});
    try T.send(&comp, T.SURF, T.commit_op, &.{});
    try T.expect(&sink, &.{.{ 20, T.unconfined_ev }});
    try std.testing.expectEqual(.inactive, T.state(&comp, 20));
    try T.send(&comp, 20, 0, &.{}); // destroy
    sink.events.clearRetainingCapacity();

    // oneshot: once it ends it never comes back
    try T.constrain(&comp, false, 21, T.SURF, 0, 1);
    try T.expect(&sink, &.{.{ 21, T.confined_ev }}); // the pointer is in (no region: the surface)
    comp.pointerLeave(1);
    comp.pointerEnter(1, T.SURF, T.px(20), T.px(20));
    try T.expect(&sink, &.{ .{ 21, T.unconfined_ev }, .{ T.PTR, T.leave_ev }, .{ T.PTR, T.frame_ev }, .{ T.PTR, T.enter_ev }, .{ T.PTR, T.frame_ev } });
    try std.testing.expectEqual(.defunct, T.state(&comp, 21));
}

/// Tests (selection gating, long mime types): conn `c` with a toplevel
/// (surface 11), a keyboard (7), a pointer (14), a data device (8) and a
/// primary device (10); data manager 6, primary manager 9. Unfocused.
fn selConn(comp: *Compositor, c: u32) !void {
    var buf: [256]u8 = undefined;
    try comp.connOpen(c);
    try comp.onWire(c, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
    try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 5 } } }));
    try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 6 } } }));
    try comp.onWire(c, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 9 } } }));
    try comp.onWire(c, wire.encodeMessage(&buf, 5, 1, &.{.{ .new_id = 7 }})); // get_keyboard
    try comp.onWire(c, wire.encodeMessage(&buf, 5, 0, &.{.{ .new_id = 14 }})); // get_pointer
    try comp.onWire(c, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 5 } })); // get_data_device
    try comp.onWire(c, wire.encodeMessage(&buf, 9, 1, &.{ .{ .new_id = 10 }, .{ .object = 5 } })); // primary get_device
    try comp.onWire(c, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 11 }})); // create_surface
    try comp.onWire(c, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 12 }, .{ .object = 11 } })); // get_xdg_surface
    try comp.onWire(c, wire.encodeMessage(&buf, 12, 1, &.{.{ .new_id = 13 }})); // get_toplevel
    try comp.onWire(c, wire.encodeMessage(&buf, 11, 6, &.{})); // initial commit
}

const SelTest = struct {
    const ddev = protocol.find("wl_data_device").?;
    const pdev = protocol.find("zwp_primary_selection_device_v1").?;
    const doffer = protocol.find("wl_data_offer").?;
    const poffer = protocol.find("zwp_primary_selection_offer_v1").?;
    const set_sel_op = ddev.requestIndex("set_selection").?;
    const start_drag_op = ddev.requestIndex("start_drag").?;
    const pset_sel_op = pdev.requestIndex("set_selection").?;
    fn send(comp: *Compositor, c: u32, obj: u32, op: u16, args: []const wire.Value) !void {
        var buf: [2048]u8 = undefined;
        try comp.onWire(c, wire.encodeMessage(&buf, obj, op, args));
    }
    /// conn 1's clipboard source 20 and primary source 21, each offering text/plain
    fn sources(comp: *Compositor) !void {
        try send(comp, 1, 6, 0, &.{.{ .new_id = 20 }}); // create_data_source
        try send(comp, 1, 20, 0, &.{.{ .string = "text/plain" }});
        try send(comp, 1, 9, 0, &.{.{ .new_id = 21 }}); // primary create_source
        try send(comp, 1, 21, 0, &.{.{ .string = "text/plain" }});
    }
    fn setSel(comp: *Compositor, c: u32, source: u32, serial: u32) !void {
        try send(comp, c, 8, set_sel_op, &.{ .{ .object = source }, .{ .uint = serial } });
    }
    fn setPrimary(comp: *Compositor, c: u32, source: u32, serial: u32) !void {
        try send(comp, c, 10, pset_sel_op, &.{ .{ .object = source }, .{ .uint = serial } });
    }
    fn owner(sel: ?Selection) ?[2]u32 {
        const s = sel orelse return null;
        return .{ s.conn, s.source };
    }
    /// the newest offer id introduced to `c` on `device` (data_offer event)
    fn lastOffer(sink: *TestSink, c: u32, device: u32, op: u16) u32 {
        var id: u32 = 0;
        for (sink.events.items) |ev| {
            if (ev.conn_id == c and ev.object_id == device and ev.opcode == op) id = std.mem.readInt(u32, ev.bytes[8..12], .little);
        }
        return id;
    }
    fn count(sink: *TestSink, c: u32, obj: u32, op: u16) usize {
        var n: usize = 0;
        for (sink.events.items) |ev| {
            if (ev.conn_id == c and ev.object_id == obj and ev.opcode == op) n += 1;
        }
        return n;
    }
};

test "selection requests: honoured from the keyboard-focused client, or with a recent input serial while no other client had input since; start_drag needs a held press" {
    const T = SelTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.interactive_fn = TestSink.interactive;
    try selConn(&comp, 1);
    try selConn(&comp, 2);
    try T.sources(&comp);

    // a background client with no input of its own: ignored, any serial
    try T.setSel(&comp, 1, 20, 0);
    try T.setSel(&comp, 1, 20, 5);
    try T.setPrimary(&comp, 1, 21, 0);
    try std.testing.expectEqual(@as(?[2]u32, null), T.owner(comp.selection));
    try std.testing.expectEqual(@as(?[2]u32, null), T.owner(comp.primary_selection));

    // wl-copy's way: the selection set while it holds keyboard focus
    comp.keyboardEnter(1, 11);
    const enter1 = comp.conns.get(1).?.serial;
    try T.setSel(&comp, 1, 20, enter1);
    try T.setPrimary(&comp, 1, 21, enter1);
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 20 }), T.owner(comp.selection));
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 21 }), T.owner(comp.primary_selection));

    // focus moved on: its old serial no longer counts (conn 2 had focus since)
    comp.keyboardLeave(1);
    comp.keyboardEnter(2, 11);
    try T.send(&comp, 1, 6, 0, &.{.{ .new_id = 22 }});
    try T.send(&comp, 1, 22, 0, &.{.{ .string = "text/plain" }});
    try T.setSel(&comp, 1, 22, enter1);
    try T.setSel(&comp, 1, 0, enter1); // nor may it clear
    try T.setPrimary(&comp, 1, 0, enter1);
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 20 }), T.owner(comp.selection));
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 21 }), T.owner(comp.primary_selection));

    // a slow client: Ctrl+C in conn 1, the embedder moves focus away before
    // the request arrives — honoured with that key's serial, nothing else
    comp.keyboardLeave(2);
    comp.keyboardEnter(1, 11);
    comp.keyboardKey(1, 0, 46, true);
    const key = comp.conns.get(1).?.serial;
    comp.keyboardLeave(1);
    try T.setSel(&comp, 1, 22, key +% 100); // never sent to it
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 20 }), T.owner(comp.selection));
    try T.setSel(&comp, 1, 22, key);
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 22 }), T.owner(comp.selection));
    // ...until another client has input: a click in conn 2
    comp.pointerEnter(2, 11, 0, 0);
    comp.pointerButton(2, 0, 0x110, true);
    comp.pointerButton(2, 0, 0x110, false);
    try T.setSel(&comp, 1, 20, key);
    try T.setPrimary(&comp, 1, 0, key);
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 22 }), T.owner(comp.selection));
    try std.testing.expectEqual(@as(?[2]u32, .{ 1, 21 }), T.owner(comp.primary_selection));

    // start_drag: a press of conn 1's still held, nothing else
    const drag_args = struct {
        fn of(serial: u32) [4]wire.Value {
            return .{ .{ .object = 20 }, .{ .object = 11 }, .{ .object = 0 }, .{ .uint = serial } };
        }
    };
    sink.inter_kind = 0xffffffff;
    try T.send(&comp, 1, 8, T.start_drag_op, &drag_args.of(key)); // a key, no press
    try std.testing.expectEqual(@as(u32, 0xffffffff), sink.inter_kind);
    comp.pointerLeave(2);
    comp.pointerEnter(1, 11, 0, 0);
    comp.pointerButton(1, 0, 0x110, true);
    const press = comp.conns.get(1).?.serial;
    comp.pointerButton(1, 0, 0x110, false);
    try T.send(&comp, 1, 8, T.start_drag_op, &drag_args.of(press)); // released: too late
    try std.testing.expectEqual(@as(u32, 0xffffffff), sink.inter_kind);
    comp.pointerButton(1, 0, 0x110, true);
    const held = comp.conns.get(1).?.serial;
    try T.send(&comp, 1, 8, T.start_drag_op, &drag_args.of(press)); // an earlier press
    try std.testing.expectEqual(@as(u32, 0xffffffff), sink.inter_kind);
    try T.send(&comp, 1, 8, T.start_drag_op, &drag_args.of(held));
    try std.testing.expectEqual(@as(u32, 4), sink.inter_kind); // the dnd session started
    try std.testing.expect(comp.drag != null);

    // the target accepting with a mime no source can offer: a revoke
    comp.dragMotion(2, 11, 0, 256, 256);
    const offer = comp.drag.?.focus_offers[0];
    try std.testing.expect(offer != 0);
    const over = [_]u8{'x'} ** (max_mime_len + 1);
    try T.send(&comp, 2, offer, comptime T.doffer.requestIndex("accept").?, &.{ .{ .uint = 0 }, .{ .string = "text/plain" } });
    try std.testing.expect(comp.drag.?.accepted);
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 2, offer, comptime T.doffer.requestIndex("accept").?, &.{ .{ .uint = 0 }, .{ .string = &over } });
    try std.testing.expect(!comp.drag.?.accepted);
    const target_op = comptime protocol.find("wl_data_source").?.eventIndex("target").?;
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(target_op, sink.events.items[0].opcode);
    try std.testing.expectEqual(@as(usize, 12), sink.events.items[0].len); // target(null)
    comp.dragCancel();
}

test "clipboard: a client's over-long mime types are ignored at offer (both sources) and read EOF at receive; sendEvent refuses an event over its buffer" {
    const T = SelTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;
    try selConn(&comp, 1);
    try T.sources(&comp);
    const long = [_]u8{'a'} ** 1500; // the reviewers' repro: 1512 B into a 1024 B buffer
    const over = [_]u8{'b'} ** (max_mime_len + 1);
    const edge = [_]u8{'c'} ** max_mime_len;
    try T.send(&comp, 1, 20, 0, &.{.{ .string = &long }});
    try T.send(&comp, 1, 20, 0, &.{.{ .string = &over }});
    try T.send(&comp, 1, 20, 0, &.{.{ .string = &edge }});
    try T.send(&comp, 1, 21, 0, &.{.{ .string = &long }});
    try std.testing.expectEqual(@as(usize, 2), comp.conns.get(1).?.source_mimes.get(20).?.items.len);
    try std.testing.expectEqual(@as(usize, 1), comp.conns.get(1).?.primary_source_mimes.get(21).?.items.len);

    // set while focused: its own device is offered the selection (no
    // panic, no write past the event buffer)
    comp.keyboardEnter(1, 11);
    sink.events.clearRetainingCapacity();
    try T.setSel(&comp, 1, 20, comp.conns.get(1).?.serial);
    try T.setPrimary(&comp, 1, 21, comp.conns.get(1).?.serial);
    const offer = T.lastOffer(&sink, 1, 8, comptime T.ddev.eventIndex("data_offer").?);
    const poffer = T.lastOffer(&sink, 1, 10, comptime T.pdev.eventIndex("data_offer").?);
    try std.testing.expectEqual(@as(usize, 2), T.count(&sink, 1, offer, comptime T.doffer.eventIndex("offer").?));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 1, poffer, comptime T.poffer.eventIndex("offer").?));
    var edge_ev: usize = 0;
    for (sink.events.items) |ev| if (ev.object_id == offer and ev.len == 8 + 4 + 260) {
        edge_ev += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), edge_ev); // the 256 B one went out whole

    // a receive naming a mime over the cap reads EOF (no send to the source)
    var buf: [1024]u8 = undefined;
    const receive_op = comptime T.doffer.requestIndex("receive").?;
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer, receive_op, &.{ .{ .string = &over }, .fd }), 61);
    try std.testing.expectEqual(@as(u32, 3), sink.fdmsg_kind);
    try std.testing.expectEqual(@as(u32, 61), sink.fdmsg_token);
    try std.testing.expectEqual(@as(usize, 0), sink.fdmsg_len);
    comp.onPipeReceive(1, wire.encodeMessage(&buf, poffer, comptime T.poffer.requestIndex("receive").?, &.{ .{ .string = &over }, .fd }), 62);
    try std.testing.expectEqual(@as(u32, 62), sink.fdmsg_token);
    try std.testing.expectEqual(@as(usize, 0), sink.fdmsg_len);
    // the 256 B one is routed to the source
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer, receive_op, &.{ .{ .string = &edge }, .fd }), 63);
    try std.testing.expectEqual(@as(u32, 63), sink.fdmsg_token);
    try std.testing.expectEqual(@as(usize, 8 + 4 + 260), sink.fdmsg_len);

    // the backstop: an event that does not fit is not sent (and logged)
    sink.events.clearRetainingCapacity();
    const logs = sink.logs;
    const huge = [_]u8{'e'} ** 2000;
    comp.sendEvent(1, 1, "wl_display", "error", &.{ .{ .object = 1 }, .{ .uint = 0 }, .{ .string = &huge } });
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expectEqual(logs + 1, sink.logs);
}

test "conn 0 is reserved: connOpen refuses it, and a conn already open" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try std.testing.expectError(error.ReservedConnId, comp.connOpen(0));
    try std.testing.expectEqual(@as(usize, 0), comp.conns.count());
    try comp.connOpen(1);
    try std.testing.expectError(error.ConnAlreadyOpen, comp.connOpen(1));
    try std.testing.expectEqual(@as(usize, 1), comp.conns.count());
}

test "placement saturates at the i32 limits: client geometry, positions and positioners" {
    const T = WinTest;
    const P = PopupTest;
    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    // the reviewers' repro: parent geometry x = INT32_MAX, popup geometry x = −10
    try T.send(&comp, 7, P.geom_op, &.{ .{ .int = max }, .{ .int = 0 }, .{ .int = 10 }, .{ .int = 10 } });
    try T.send(&comp, 6, T.commit_op, &.{});
    try P.positioner(&comp, 20, 0, 0, .{ 8, 8 }, 20, 20);
    try P.popup(&comp, 21, 7, 20);
    try T.send(&comp, 22, P.geom_op, &.{ .{ .int = -10 }, .{ .int = 0 }, .{ .int = 10 }, .{ .int = 10 } });
    try T.send(&comp, 21, T.commit_op, &.{});
    try std.testing.expectEqual(max, P.at(&comp, 21)[0]);
    // the other way round, and the positioner's own sums
    try T.send(&comp, 7, P.geom_op, &.{ .{ .int = min }, .{ .int = min }, .{ .int = 10 }, .{ .int = 10 } });
    try T.send(&comp, 22, P.geom_op, &.{ .{ .int = max }, .{ .int = max }, .{ .int = 10 }, .{ .int = 10 } });
    try T.send(&comp, 6, T.commit_op, &.{});
    try T.send(&comp, 21, T.commit_op, &.{});
    try std.testing.expectEqual([2]i32{ min + 1, min + 1 }, P.at(&comp, 21)); // its configure x/y is 1, 1
    const pos = comptime protocol.find("xdg_positioner").?;
    try T.send(&comp, 4, comptime protocol.find("xdg_wm_base").?.requestIndex("create_positioner").?, &.{.{ .new_id = 30 }});
    try T.send(&comp, 30, comptime pos.requestIndex("set_size").?, &.{ .{ .int = max }, .{ .int = max } });
    try T.send(&comp, 30, comptime pos.requestIndex("set_anchor_rect").?, &.{ .{ .int = max }, .{ .int = min }, .{ .int = max }, .{ .int = max } });
    try T.send(&comp, 30, comptime pos.requestIndex("set_anchor").?, &.{.{ .uint = 8 }});
    try T.send(&comp, 30, comptime pos.requestIndex("set_gravity").?, &.{.{ .uint = 5 }}); // top_left: − size
    try T.send(&comp, 30, comptime pos.requestIndex("set_offset").?, &.{ .{ .int = max }, .{ .int = min } });
    try T.send(&comp, 23, comptime protocol.find("xdg_popup").?.requestIndex("reposition").?, &.{ .{ .object = 30 }, .{ .uint = 1 } });
    try std.testing.expectEqual([2]i32{ 0, min }, try P.configured(&sink, 23)); // (max + max + max) − max, (min + max + min) − max

    // windowGeometry over subsurfaces at the extremes (no geometry set)
    try T.send(&comp, 7, P.geom_op, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } });
    comp.conns.get(1).?.surfaces.getPtr(6).?.geom_set = false;
    try T.send(&comp, 3, 0, &.{.{ .new_id = 40 }});
    try T.send(&comp, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 41 } } });
    try T.send(&comp, 41, 1, &.{ .{ .new_id = 42 }, .{ .object = 40 }, .{ .object = 6 } }); // get_subsurface
    try T.send(&comp, 42, comptime protocol.find("wl_subsurface").?.requestIndex("set_position").?, &.{ .{ .int = min }, .{ .int = max } });
    comp.noteBufferSize(1, 40, 0xffff_ffff, 0xffff_ffff);
    const g = comp.windowGeometry(1, 6);
    try std.testing.expectEqual(min, g.x);
    try std.testing.expectEqual(@as(i32, 0), g.y);
    try std.testing.expectEqual(max, g.w);
    try std.testing.expectEqual(max, g.h);
}

test "own selection to a relay with FEATURE selection_cache: each payload's bytes go once (FDMSG own_pipe), later receives name it; a new selection drops the relay's copy first" {
    const T = SelTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;
    try selConn(&comp, 1);
    comp.keyboardEnter(1, 11);
    comp.applyFeature(@intFromEnum(stream.FeatureKind.selection_cache), &.{});
    var pack: [256]u8 = undefined;
    try comp.setOwnSelection(packOwnSelection(&pack, &.{ .{ "text/plain", "shared" }, .{ "UTF8_STRING", null }, .{ "text/html", "<b>x</b>" } }));
    const offer = T.lastOffer(&sink, 1, 8, comptime T.ddev.eventIndex("data_offer").?);
    const gen = comp.own_gen;
    var buf: [256]u8 = undefined;
    const receive_op = comptime T.doffer.requestIndex("receive").?;
    const Expect = struct {
        fn ownPipe(s: *TestSink, conn: u32, token: u32, g: u32, blob: u32, bytes: ?[]const u8) !void {
            try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FdMsgKind.own_pipe)), s.fdmsg_kind);
            try std.testing.expectEqual(conn, s.fdmsg_conn);
            try std.testing.expectEqual(@as(usize, 0), s.fdmsg_len); // no wire message
            const m = try stream.OwnPipe.decode(s.fdmsg_aux[0..s.fdmsg_aux_len]);
            try std.testing.expectEqual(token, m.token);
            try std.testing.expectEqual(g, m.gen);
            try std.testing.expectEqual(blob, m.blob);
            try std.testing.expectEqual(@as(u32, if (bytes != null) stream.OwnPipe.has_bytes else 0), m.flags);
            try std.testing.expectEqualStrings(bytes orelse "", m.bytes);
        }
    };
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer, receive_op, &.{ .{ .string = "UTF8_STRING" }, .fd }), 71);
    try Expect.ownPipe(&sink, 1, 71, gen, 0, "shared");
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer, receive_op, &.{ .{ .string = "text/plain" }, .fd }), 72);
    try Expect.ownPipe(&sink, 1, 72, gen, 0, null); // the alias: same payload, already there
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer, receive_op, &.{ .{ .string = "text/html" }, .fd }), 73);
    try Expect.ownPipe(&sink, 1, 73, gen, 1, "<b>x</b>");
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer, receive_op, &.{ .{ .string = "text/html" }, .fd }), 74);
    try Expect.ownPipe(&sink, 1, 74, gen, 1, null);
    // a mime it doesn't have: EOF as ever (pipe, token alone)
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer, receive_op, &.{ .{ .string = "image/png" }, .fd }), 75);
    try std.testing.expectEqual(@as(u32, 3), sink.fdmsg_kind);
    try std.testing.expectEqual(@as(usize, 4), sink.fdmsg_aux_len);

    // replaced: gen 0 first (the relay drops its copy), then fresh bytes
    const calls = sink.fdmsg_calls;
    try comp.setOwnSelection(packOwnSelection(&pack, &.{.{ "text/plain", "next" }}));
    try std.testing.expectEqual(calls + 1, sink.fdmsg_calls);
    try Expect.ownPipe(&sink, 0, 0, 0, 0, null);
    const offer2 = T.lastOffer(&sink, 1, 8, comptime T.ddev.eventIndex("data_offer").?);
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer2, receive_op, &.{ .{ .string = "text/plain" }, .fd }), 76);
    try Expect.ownPipe(&sink, 1, 76, comp.own_gen, 0, "next");
    // a new link's relay holds nothing: the bytes go again
    comp.applyFeature(@intFromEnum(stream.FeatureKind.selection_cache), &.{});
    comp.onPipeReceive(1, wire.encodeMessage(&buf, offer2, receive_op, &.{ .{ .string = "text/plain" }, .fd }), 77);
    try Expect.ownPipe(&sink, 1, 77, comp.own_gen, 0, "next");
    // cleared: the copy goes; nothing was sent of an unread selection
    const calls2 = sink.fdmsg_calls;
    try comp.setOwnSelection(&.{});
    try std.testing.expectEqual(calls2 + 1, sink.fdmsg_calls);
    try Expect.ownPipe(&sink, 0, 0, 0, 0, null);
    try comp.setOwnSelection(packOwnSelection(&pack, &.{.{ "text/plain", "unread" }}));
    const calls3 = sink.fdmsg_calls;
    try comp.setOwnSelection(&.{});
    try std.testing.expectEqual(calls3, sink.fdmsg_calls);
}

/// Seat tests (Firefox binds wl_seat twice): conn 1's v6 toplevel
/// (wmBaseToplevel: surface 6, xdg_surface 7, toplevel 8) past its initial
/// commit, keymaps through the FDMSG sink, cursor images recorded.
const SeatTest = struct {
    const ptr = protocol.find("wl_pointer").?;
    const kbd = protocol.find("wl_keyboard").?;
    const p_enter = ptr.eventIndex("enter").?;
    const p_leave = ptr.eventIndex("leave").?;
    const p_motion = ptr.eventIndex("motion").?;
    const p_button = ptr.eventIndex("button").?;
    const p_frame = ptr.eventIndex("frame").?;
    const p_axis = ptr.eventIndex("axis").?;
    const p_source = ptr.eventIndex("axis_source").?;
    const p_discrete = ptr.eventIndex("axis_discrete").?;
    const p_v120 = ptr.eventIndex("axis_value120").?;
    const p_dir = ptr.eventIndex("axis_relative_direction").?;
    const k_enter = kbd.eventIndex("enter").?;
    const k_leave = kbd.eventIndex("leave").?;
    const k_key = kbd.eventIndex("key").?;
    const k_mods = kbd.eventIndex("modifiers").?;
    const k_repeat = kbd.eventIndex("repeat_info").?;
    const set_cursor_op = ptr.requestIndex("set_cursor").?;
    const p_release = ptr.requestIndex("release").?;
    const k_release = kbd.requestIndex("release").?;

    fn setup(comp: *Compositor) !void {
        comp.fdmsg_fn = TestSink.fdmsg;
        comp.cursor_surface_fn = TestSink.cursorSurface;
        try wmBaseToplevel(comp, 1);
        try send(comp, 6, protocol.find("wl_surface").?.requestIndex("commit").?, &.{});
    }
    fn send(comp: *Compositor, obj: u32, op: u16, args: []const wire.Value) !void {
        var buf: [128]u8 = undefined;
        try comp.onWire(1, wire.encodeMessage(&buf, obj, op, args));
    }
    /// bind wl_seat (global 4) at `version` as `id`
    fn bindSeat(comp: *Compositor, id: u32, version: u32) !void {
        try send(comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = version, .id = id } } });
    }
    fn getPointer(comp: *Compositor, seat: u32, id: u32) !void {
        try send(comp, seat, 0, &.{.{ .new_id = id }});
    }
    fn getKeyboard(comp: *Compositor, seat: u32, id: u32) !void {
        try send(comp, seat, 1, &.{.{ .new_id = id }});
    }
    /// conn 1's events on `obj` with `opcode` since the last clear
    fn count(sink: *const TestSink, obj: u32, opcode: u16) usize {
        var n: usize = 0;
        for (sink.events.items) |e| {
            if (e.conn_id == 1 and e.object_id == obj and e.opcode == opcode) n += 1;
        }
        return n;
    }
    /// the first arg (a serial, uint) of the one `opcode` event each of
    /// `ids` got — the same for all of them, or the test fails
    fn sameSerial(sink: *const TestSink, ids: []const u32, opcode: u16) !u32 {
        var serial: ?u32 = null;
        for (ids) |id| {
            try std.testing.expectEqual(@as(usize, 1), count(sink, id, opcode));
            for (sink.events.items) |e| {
                if (e.conn_id != 1 or e.object_id != id or e.opcode != opcode) continue;
                const s = std.mem.readInt(u32, e.bytes[wire.header_size..][0..4], .little);
                if (serial) |want| try std.testing.expectEqual(want, s) else serial = s;
            }
        }
        return serial.?;
    }
    /// the args of the last `opcode` event on `obj`
    fn argsOf(sink: *const TestSink, obj: u32, opcode: u16, sig: []const wire.ArgType, vals: *[wire.max_args]wire.Value) ![]const wire.Value {
        var i = sink.events.items.len;
        while (i > 0) {
            i -= 1;
            const e = &sink.events.items[i];
            if (e.conn_id == 1 and e.object_id == obj and e.opcode == opcode) return wire.decodeArgs(e.bytes[wire.header_size..e.len], sig, vals);
        }
        return error.NoSuchEvent;
    }
};

test "seat: two wl_seat bindings (Firefox) — every wl_pointer and wl_keyboard gets enter, motion, button, axis, key, modifiers, leave with one serial, version-gated per object" {
    const T = SeatTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);

    // GTK's seat at v9, Firefox's at v7, a third at v3: pointer + keyboard each
    try T.bindSeat(&comp, 20, 9);
    try T.getPointer(&comp, 20, 21);
    try T.getKeyboard(&comp, 20, 22);
    try T.bindSeat(&comp, 23, 7);
    try T.getPointer(&comp, 23, 24);
    try T.getKeyboard(&comp, 23, 25);
    try T.bindSeat(&comp, 26, 3);
    try T.getPointer(&comp, 26, 27);
    try T.getKeyboard(&comp, 26, 28);
    // a keymap each (an FDMSG per keyboard); repeat_info only from v4
    try std.testing.expectEqual(@as(u32, 3), sink.fdmsg_calls);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 22, T.k_repeat));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 25, T.k_repeat));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 28, T.k_repeat));

    const kbds = [_]u32{ 22, 25, 28 };
    const ptrs = [_]u32{ 21, 24, 27 };
    sink.events.clearRetainingCapacity();
    comp.keyboardEnter(1, 6);
    const k_enter = try T.sameSerial(&sink, &kbds, T.k_enter);
    const k_mods = try T.sameSerial(&sink, &kbds, T.k_mods);
    try std.testing.expect(k_mods != k_enter);
    try std.testing.expectEqual(k_enter, comp.conns.get(1).?.keyboard_enter_serial);

    sink.events.clearRetainingCapacity();
    comp.keyboardKey(1, 5, 30, true); // 'a'
    const key = try T.sameSerial(&sink, &kbds, T.k_key);
    comp.keyboardKey(1, 6, 42, true); // Shift: modifiers to all, one serial
    _ = try T.sameSerial(&sink, &kbds, T.k_mods);
    try std.testing.expect(comp.maySetSelection(1, comp.conns.get(1).?, key));

    sink.events.clearRetainingCapacity();
    comp.pointerEnter(1, 6, 256, 512);
    const p_enter = try T.sameSerial(&sink, &ptrs, T.p_enter);
    try std.testing.expectEqual(p_enter, comp.conns.get(1).?.pointer_enter_serial);
    // frame: v5+ only, per object
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_frame));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 24, T.p_frame));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 27, T.p_frame));

    sink.events.clearRetainingCapacity();
    comp.pointerMotion(1, 7, 1024, 2048, null);
    for (ptrs) |p| try std.testing.expectEqual(@as(usize, 1), T.count(&sink, p, T.p_motion));
    var vals: [wire.max_args]wire.Value = undefined;
    for (ptrs) |p| try std.testing.expectEqual(@as(i32, 2048), (try T.argsOf(&sink, p, T.p_motion, &.{ .uint, .fixed, .fixed }, &vals))[2].fixed);
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 27, T.p_frame));

    sink.events.clearRetainingCapacity();
    comp.pointerButton(1, 8, 0x110, true);
    const press = try T.sameSerial(&sink, &ptrs, T.p_button);
    // the implicit grab is the conn's: a move naming the press is honoured
    // whichever pointer the client read it from
    comp.interactive_fn = TestSink.interactive;
    try T.send(&comp, 8, comptime protocol.find("xdg_toplevel").?.requestIndex("move").?, &.{ .{ .object = 23 }, .{ .uint = press } });
    try std.testing.expectEqual(@as(u32, 0), sink.inter_kind);
    comp.pointerButton(1, 9, 0x110, false);

    // a wheel detent: each pointer the frame its version knows
    sink.events.clearRetainingCapacity();
    comp.pointerAxis(1, 10, 0, 2560, 120);
    // v9: axis_source, axis_relative_direction, axis_value120, axis, frame
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_source));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_dir));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_v120));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 21, T.p_discrete));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_axis));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_frame));
    // v7: axis_source, axis_discrete, axis, frame
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 24, T.p_source));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 24, T.p_dir));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 24, T.p_v120));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 24, T.p_discrete));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 24, T.p_axis));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 24, T.p_frame));
    // v3: axis alone
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 27, T.p_axis));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len - 9);

    sink.events.clearRetainingCapacity();
    comp.pointerLeave(1);
    _ = try T.sameSerial(&sink, &ptrs, T.p_leave);
    comp.keyboardLeave(1);
    _ = try T.sameSerial(&sink, &kbds, T.k_leave);
}

test "seat: a released wl_pointer / wl_keyboard leaves the set, the others keep working; set_cursor from any pointer with the enter's serial applies" {
    const T = SeatTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    try T.bindSeat(&comp, 20, 9);
    try T.getPointer(&comp, 20, 21);
    try T.getKeyboard(&comp, 20, 22);
    try T.bindSeat(&comp, 23, 9);
    try T.getPointer(&comp, 23, 24);
    try T.getKeyboard(&comp, 23, 25);
    comp.keyboardEnter(1, 6);
    comp.pointerEnter(1, 6, 0, 0);
    const enter = comp.conns.get(1).?.pointer_enter_serial;

    // set_cursor on the SECOND pointer naming the shared enter serial: applied
    const calls0 = sink.cursor_calls;
    try T.send(&comp, 24, T.set_cursor_op, &.{ .{ .uint = enter }, .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } });
    try std.testing.expectEqual(calls0 + 1, sink.cursor_calls);
    try T.send(&comp, 21, T.set_cursor_op, &.{ .{ .uint = enter }, .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } });
    try std.testing.expectEqual(calls0 + 2, sink.cursor_calls);

    // GTK's pair released: only Firefox's still hears the seat
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 21, T.p_release, &.{});
    try T.send(&comp, 22, T.k_release, &.{});
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len); // two delete_ids
    try std.testing.expectEqual(@as(u8, 1), comp.conns.get(1).?.pointers.len);
    try std.testing.expectEqual(@as(u8, 1), comp.conns.get(1).?.keyboards.len);
    sink.events.clearRetainingCapacity();
    comp.pointerMotion(1, 1, 256, 256, null);
    comp.pointerButton(1, 2, 0x110, true);
    comp.keyboardKey(1, 3, 30, true);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 24, T.p_motion));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 24, T.p_button));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 25, T.k_key));
    for (sink.events.items) |e| try std.testing.expect(e.object_id != 21 and e.object_id != 22);

    // the freed id names a new wl_pointer: it is sent the enter it missed
    // (the focus's serial, where the pointer is now), then a frame
    sink.events.clearRetainingCapacity();
    try T.getPointer(&comp, 20, 21);
    var vals: [wire.max_args]wire.Value = undefined;
    const a = try T.argsOf(&sink, 21, T.p_enter, &.{ .uint, .object, .fixed, .fixed }, &vals);
    try std.testing.expectEqual(enter, a[0].uint);
    try std.testing.expectEqual(@as(u32, 6), a[1].object);
    try std.testing.expectEqual(@as(i32, 256), a[2].fixed);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_frame));
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);

    // every pointer released while focused: focus stays the conn's, the
    // leave goes to nobody and still ends the grab and the cursor image
    try T.send(&comp, 21, T.p_release, &.{});
    try T.send(&comp, 24, T.p_release, &.{});
    sink.events.clearRetainingCapacity();
    comp.pointerLeave(1);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 0), comp.conns.get(1).?.pointer_focus);
    try std.testing.expectEqual(@as(u32, 0), comp.conns.get(1).?.buttons_held);
}

test "seat: a wl_keyboard / wl_pointer made while its client has focus gets the enter (the focus's serial, current position) and modifiers; the first pointer made after the enter too" {
    const T = SeatTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    try T.bindSeat(&comp, 20, 9);
    try T.getKeyboard(&comp, 20, 22);
    comp.keyboardEnter(1, 6);
    const k_enter = comp.conns.get(1).?.keyboard_enter_serial;
    comp.keyboardKey(1, 1, 42, true); // Shift held

    // Firefox's own seat (v5), after GTK's keyboard got focus: keymap,
    // repeat_info, then enter (same serial, no keys) and the modifiers —
    // to it alone
    try T.bindSeat(&comp, 23, 5);
    sink.events.clearRetainingCapacity();
    const fd0 = sink.fdmsg_calls;
    try T.getKeyboard(&comp, 23, 25);
    try std.testing.expectEqual(fd0 + 1, sink.fdmsg_calls);
    try std.testing.expectEqual(@as(usize, 3), sink.events.items.len);
    try std.testing.expectEqual(T.k_repeat, sink.events.items[0].opcode);
    var vals: [wire.max_args]wire.Value = undefined;
    const e = try T.argsOf(&sink, 25, T.k_enter, &.{ .uint, .object, .array }, &vals);
    try std.testing.expectEqual(k_enter, e[0].uint);
    try std.testing.expectEqual(@as(u32, 6), e[1].object);
    try std.testing.expectEqual(@as(usize, 0), e[2].array.len);
    const m = try T.argsOf(&sink, 25, T.k_mods, &.{ .uint, .uint, .uint, .uint, .uint }, &vals);
    try std.testing.expectEqual(@as(u32, 1), m[1].uint); // Shift depressed
    try std.testing.expectEqual(@as(u32, 1 << 4), m[3].uint); // NumLock locked
    try std.testing.expectEqual(T.k_mods, sink.events.items[2].opcode); // after the enter

    // no wl_pointer yet: the enter is the conn's focus, sent to nobody
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(1, 6, 10 << 8, 20 << 8);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    const p_enter = comp.conns.get(1).?.pointer_enter_serial;
    // the first wl_pointer: the enter it missed + frame
    try T.getPointer(&comp, 20, 21);
    const pe = try T.argsOf(&sink, 21, T.p_enter, &.{ .uint, .object, .fixed, .fixed }, &vals);
    try std.testing.expectEqual(p_enter, pe[0].uint);
    try std.testing.expectEqual(@as(i32, 10 << 8), pe[2].fixed);
    try std.testing.expectEqual(@as(i32, 20 << 8), pe[3].fixed);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 21, T.p_frame));
    comp.pointerMotion(1, 2, 30 << 8, 40 << 8, null);
    // a second, late: where the pointer is now; the same serial
    sink.events.clearRetainingCapacity();
    try T.getPointer(&comp, 23, 24);
    const pe2 = try T.argsOf(&sink, 24, T.p_enter, &.{ .uint, .object, .fixed, .fixed }, &vals);
    try std.testing.expectEqual(p_enter, pe2[0].uint);
    try std.testing.expectEqual(@as(i32, 30 << 8), pe2[2].fixed);
    try std.testing.expectEqual(@as(i32, 40 << 8), pe2[3].fixed);
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    // set_cursor from the late one, with that serial: applied
    const calls0 = sink.cursor_calls;
    try T.send(&comp, 24, T.set_cursor_op, &.{ .{ .uint = p_enter }, .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } });
    try std.testing.expectEqual(calls0 + 1, sink.cursor_calls);

    // made with no focus: keymap only
    comp.pointerLeave(1);
    comp.keyboardLeave(1);
    sink.events.clearRetainingCapacity();
    try T.getKeyboard(&comp, 20, 30);
    try T.getPointer(&comp, 20, 31);
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len); // repeat_info
}

test "seat: objects over max_seat_objects get no events (the cap); a release makes room" {
    const T = SeatTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    try T.bindSeat(&comp, 20, 9);
    for (0..max_seat_objects + 1) |i| try T.getPointer(&comp, 20, 30 + @as(u32, @intCast(i)));
    for (0..max_seat_objects + 1) |i| try T.getKeyboard(&comp, 20, 50 + @as(u32, @intCast(i)));
    const extra_p: u32 = 30 + max_seat_objects;
    const extra_k: u32 = 50 + max_seat_objects;
    try std.testing.expectEqual(@as(u32, max_seat_objects), sink.fdmsg_calls); // no keymap for the extra one
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, extra_k, T.k_repeat));
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(1, 6, 0, 0);
    comp.keyboardEnter(1, 6);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 30, T.p_enter));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, extra_p, T.p_enter));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, extra_k, T.k_enter));
    try std.testing.expectEqual(@as(u8, max_seat_objects), comp.conns.get(1).?.pointers.len);
    // the ignored object is still the client's: it can release it
    try T.send(&comp, extra_p, T.p_release, &.{});
    try std.testing.expectEqual(@as(u8, max_seat_objects), comp.conns.get(1).?.pointers.len);
    // a release makes room: the next one is accepted (late enter)
    try T.send(&comp, 30, T.p_release, &.{});
    sink.events.clearRetainingCapacity();
    try T.getPointer(&comp, 20, 70);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 70, T.p_enter));
    // the other kinds share the cap: relative pointers, data devices
    try T.send(&comp, 2, 0, &.{ .{ .uint = 15 }, .{ .new_id_dynamic = .{ .interface = "zwp_relative_pointer_manager_v1", .version = 1, .id = 80 } } });
    for (0..max_seat_objects + 1) |i| try T.send(&comp, 80, 1, &.{ .{ .new_id = 81 + @as(u32, @intCast(i)) }, .{ .object = 31 } });
    try std.testing.expectEqual(@as(u8, max_seat_objects), comp.conns.get(1).?.relative_pointers.len);
    try T.send(&comp, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 100 } } });
    for (0..max_seat_objects + 1) |i| try T.send(&comp, 100, 1, &.{ .{ .new_id = 101 + @as(u32, @intCast(i)) }, .{ .object = 20 } });
    try std.testing.expectEqual(@as(u8, max_seat_objects), comp.conns.get(1).?.data_devices.len);
}

const TouchTest = struct {
    const touch = protocol.find("wl_touch").?;
    const down = touch.eventIndex("down").?;
    const up = touch.eventIndex("up").?;
    const motion = touch.eventIndex("motion").?;
    const frame = touch.eventIndex("frame").?;
    const cancel = touch.eventIndex("cancel").?;
    const release = touch.requestIndex("release").?;
    const get_touch = protocol.find("wl_seat").?.requestIndex("get_touch").?;

    /// SeatTest's toplevel (surface 6) plus wl_seat 20 (v9) and its
    /// wl_touch 21, the embedder told (touch_bound_fn)
    fn setup(comp: *Compositor) !void {
        comp.touch_bound_fn = TestSink.touchBound;
        try SeatTest.setup(comp);
        try SeatTest.bindSeat(comp, 20, 9);
        try SeatTest.send(comp, 20, get_touch, &.{.{ .new_id = 21 }});
    }
    /// conn 1's wl_touch events since the last clear, as {object, opcode}
    fn events(sink: *const TestSink, out: [][2]u32) []const [2]u32 {
        var n: usize = 0;
        for (sink.events.items) |e| {
            if (e.conn_id != 1 or e.object_id < 21 or e.object_id > 29) continue; // the tests' wl_touch ids
            out[n] = .{ e.object_id, e.opcode };
            n += 1;
        }
        return out[0..n];
    }
    fn expectEvents(sink: *TestSink, want: []const [2]u32) !void {
        var buf: [64][2]u32 = undefined;
        const got = events(sink, &buf);
        errdefer for (got) |g| std.debug.print("got: @{d} op {d}\n", .{ g[0], g[1] });
        try std.testing.expectEqualSlices([2]u32, want, got);
        sink.events.clearRetainingCapacity();
    }
};

test "touch: wl_seat advertises touch; touch_bound on the first get_touch and the last release; down, motion, up, frame in order with their args; a frame only after something" {
    const T = TouchTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.touch_bound_fn = TestSink.touchBound;
    try SeatTest.setup(&comp);

    // the capabilities event names all three
    sink.events.clearRetainingCapacity();
    try SeatTest.bindSeat(&comp, 20, 9);
    var vals: [wire.max_args]wire.Value = undefined;
    const caps = try SeatTest.argsOf(&sink, 20, comptime protocol.find("wl_seat").?.eventIndex("capabilities").?, &.{.uint}, &vals);
    try std.testing.expectEqual(seat_capability_pointer | seat_capability_keyboard | seat_capability_touch, caps[0].uint);

    // no wl_touch yet: touch calls are ignored, no serial spent
    const serial0 = comp.conns.get(1).?.serial;
    comp.touchDown(1, 5, 6, 0, 256, 256);
    comp.touchFrame(1);
    try std.testing.expectEqual(serial0, comp.conns.get(1).?.serial);
    try std.testing.expectEqual(@as(u8, 0), comp.conns.get(1).?.touch_n);
    try std.testing.expectEqual(@as(u32, 0), sink.touch_bound_calls);

    // the first wl_touch: bound; a second one: nothing new
    try SeatTest.send(&comp, 20, T.get_touch, &.{.{ .new_id = 21 }});
    try std.testing.expectEqual(@as(u32, 1), sink.touch_bound_calls);
    try std.testing.expectEqual(true, sink.touch_bound.?);
    try std.testing.expectEqual(@as(u32, 1), sink.touch_conn);
    try SeatTest.send(&comp, 20, T.get_touch, &.{.{ .new_id = 22 }});
    try std.testing.expectEqual(@as(u32, 1), sink.touch_bound_calls);
    try SeatTest.send(&comp, 22, T.release, &.{});
    try std.testing.expectEqual(@as(u32, 1), sink.touch_bound_calls);
    sink.events.clearRetainingCapacity();

    // nothing sent yet: no frame
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{});

    comp.touchDown(1, 10, 6, 3, 10 * 256, 20 * 256);
    const s_down = comp.conns.get(1).?.serial;
    const d = try SeatTest.argsOf(&sink, 21, T.down, &.{ .uint, .uint, .object, .int, .fixed, .fixed }, &vals);
    try std.testing.expectEqual(s_down, d[0].uint);
    try std.testing.expectEqual(@as(u32, 10), d[1].uint);
    try std.testing.expectEqual(@as(u32, 6), d[2].object);
    try std.testing.expectEqual(@as(i32, 3), d[3].int);
    try std.testing.expectEqual(@as(i32, 10 * 256), d[4].fixed);
    try std.testing.expectEqual(@as(i32, 20 * 256), d[5].fixed);
    // an input serial, like a press: a set_selection naming it counts
    try std.testing.expectEqual(@as(u32, 1), comp.last_input_conn);
    try std.testing.expect(comp.maySetSelection(1, comp.conns.get(1).?, s_down));
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{ .{ 21, T.down }, .{ 21, T.frame } });

    // outside the surface, still its coordinates
    comp.touchMotion(1, 11, 3, -5 * 256, 900 * 256);
    const m = try SeatTest.argsOf(&sink, 21, T.motion, &.{ .uint, .int, .fixed, .fixed }, &vals);
    try std.testing.expectEqual(@as(u32, 11), m[0].uint);
    try std.testing.expectEqual(@as(i32, 3), m[1].int);
    try std.testing.expectEqual(@as(i32, -5 * 256), m[2].fixed);
    try std.testing.expectEqual(@as(i32, 900 * 256), m[3].fixed);
    comp.touchFrame(1);
    comp.touchFrame(1); // nothing since: no second frame
    try T.expectEvents(&sink, &.{ .{ 21, T.motion }, .{ 21, T.frame } });

    comp.touchUp(1, 12, 3);
    const u = try SeatTest.argsOf(&sink, 21, T.up, &.{ .uint, .uint, .int }, &vals);
    try std.testing.expectEqual(comp.conns.get(1).?.serial, u[0].uint);
    try std.testing.expect(u[0].uint != s_down);
    try std.testing.expectEqual(@as(u32, 12), u[1].uint);
    try std.testing.expectEqual(@as(i32, 3), u[2].int);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{ .{ 21, T.up }, .{ 21, T.frame } });
    try std.testing.expectEqual(@as(u8, 0), comp.conns.get(1).?.touch_n);

    // the last wl_touch released: unbound, its points forgotten
    comp.touchDown(1, 13, 6, 4, 0, 0);
    try SeatTest.send(&comp, 21, T.release, &.{});
    try std.testing.expectEqual(@as(u32, 2), sink.touch_bound_calls);
    try std.testing.expectEqual(false, sink.touch_bound.?);
    try std.testing.expectEqual(@as(u8, 0), comp.conns.get(1).?.touch_n);
    sink.events.clearRetainingCapacity();
    comp.touchUp(1, 14, 4);
    comp.touchFrame(1);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
}

test "touch: several points, every wl_touch of the client (two wl_seat bindings) gets every event with one serial; an id already down, an unknown id and one beyond the cap are ignored" {
    const T = TouchTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    // a second binding at v3 (release's version) and its wl_touch 22
    try SeatTest.bindSeat(&comp, 23, 3);
    try SeatTest.send(&comp, 23, T.get_touch, &.{.{ .new_id = 22 }});
    try std.testing.expectEqual(@as(u32, 1), sink.touch_bound_calls);
    sink.events.clearRetainingCapacity();

    // two fingers down together, one frame
    comp.touchDown(1, 1, 6, 0, 0, 0);
    comp.touchDown(1, 1, 6, 1, 256, 256);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{ .{ 21, T.down }, .{ 22, T.down }, .{ 21, T.down }, .{ 22, T.down }, .{ 21, T.frame }, .{ 22, T.frame } });
    comp.touchDown(1, 2, 6, 0, 0, 0); // already down
    comp.touchMotion(1, 2, 7, 0, 0); // never down
    comp.touchUp(1, 2, 7);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{});

    comp.touchDown(1, 2, 6, 2, 0, 0);
    _ = try SeatTest.sameSerial(&sink, &.{ 21, 22 }, T.down);
    comp.touchMotion(1, 3, 1, 512, 512);
    comp.touchUp(1, 3, 0);
    _ = try SeatTest.sameSerial(&sink, &.{ 21, 22 }, T.up);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{ .{ 21, T.down }, .{ 22, T.down }, .{ 21, T.motion }, .{ 22, T.motion }, .{ 21, T.up }, .{ 22, T.up }, .{ 21, T.frame }, .{ 22, T.frame } });
    const c = comp.conns.get(1).?;
    try std.testing.expectEqual(@as(u8, 2), c.touch_n);
    // the freed id may go down again
    comp.touchDown(1, 4, 6, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 3), c.touch_n);

    // the cap
    for (0..max_touch_points) |i| comp.touchDown(1, 5, 6, 100 + @as(i32, @intCast(i)), 0, 0);
    try std.testing.expectEqual(@as(u8, max_touch_points), c.touch_n);
    sink.events.clearRetainingCapacity();
    comp.touchMotion(1, 6, 100 + max_touch_points - 1, 0, 0); // the one that didn't go down
    try T.expectEvents(&sink, &.{});

    // GTK's released: the other one still hears
    try SeatTest.send(&comp, 21, T.release, &.{});
    try std.testing.expectEqual(@as(u32, 1), sink.touch_bound_calls);
    sink.events.clearRetainingCapacity();
    comp.touchUp(1, 7, 1);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{ .{ 22, T.up }, .{ 22, T.frame } });
}

test "touch: cancel ends every point (later calls naming them ignored), nothing when none is down; embedderGone cancels; downs ignored on a cursor surface or a surface that is gone" {
    const T = TouchTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    sink.events.clearRetainingCapacity();

    comp.touchCancel(1);
    try T.expectEvents(&sink, &.{});

    comp.touchDown(1, 1, 6, 0, 0, 0);
    comp.touchDown(1, 1, 6, 1, 0, 0);
    comp.touchCancel(1); // (unframed: the cancel ends the group, no frame follows)
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{ .{ 21, T.down }, .{ 21, T.down }, .{ 21, T.cancel } });
    comp.touchMotion(1, 2, 0, 0, 0);
    comp.touchUp(1, 2, 1);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{});

    // the embedder goes: the points it was holding up are cancelled
    comp.touchDown(1, 3, 6, 0, 0, 0);
    comp.touchFrame(1);
    sink.events.clearRetainingCapacity();
    comp.embedderGone();
    try T.expectEvents(&sink, &.{.{ 21, T.cancel }});
    try std.testing.expectEqual(@as(u8, 0), comp.conns.get(1).?.touch_n);

    // a cursor surface (40) is not a touch target; nor is a surface that
    // does not exist (the down would name it)
    try SeatTest.getPointer(&comp, 20, 30);
    comp.pointerEnter(1, 6, 0, 0);
    try SeatTest.send(&comp, 3, 0, &.{.{ .new_id = 40 }});
    try SeatTest.send(&comp, 30, SeatTest.set_cursor_op, &.{ .{ .uint = comp.conns.get(1).?.pointer_enter_serial }, .{ .object = 40 }, .{ .int = 0 }, .{ .int = 0 } });
    sink.events.clearRetainingCapacity();
    comp.touchDown(1, 4, 40, 0, 0, 0);
    comp.touchDown(1, 4, 99, 1, 0, 0);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{});
}

test "touch: move/resize honoured with the serial of a point down on the window, then the client's touch is cancelled; a stale (up) touch serial refused; start_drag never takes a touch serial" {
    const T = TouchTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    comp.interactive_fn = TestSink.interactive;
    const move_op = comptime protocol.find("xdg_toplevel").?.requestIndex("move").?;
    const resize_op = comptime protocol.find("xdg_toplevel").?.requestIndex("resize").?;
    var calls = sink.inter_calls;

    // a finger up again: its serial is stale
    comp.touchDown(1, 1, 6, 0, 0, 0);
    const s_up = comp.conns.get(1).?.serial;
    comp.touchUp(1, 2, 0);
    comp.touchFrame(1);
    try SeatTest.send(&comp, 8, move_op, &.{ .{ .object = 20 }, .{ .uint = s_up } });
    try std.testing.expectEqual(calls, sink.inter_calls);

    // two fingers down; the titlebar's move names the first: honoured, and
    // every point of the client is cancelled (the embedder's drag has it)
    comp.touchDown(1, 3, 6, 0, 0, 0);
    const s1 = comp.conns.get(1).?.serial;
    comp.touchDown(1, 3, 6, 1, 0, 0);
    comp.touchFrame(1);
    sink.events.clearRetainingCapacity();
    try SeatTest.send(&comp, 8, move_op, &.{ .{ .object = 20 }, .{ .uint = s1 } });
    try std.testing.expectEqual(calls + 1, sink.inter_calls);
    try std.testing.expectEqual(@as(u32, 0), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 6), sink.inter_surface);
    try T.expectEvents(&sink, &.{.{ 21, T.cancel }});
    calls = sink.inter_calls;
    // the fingers are the embedder's now: their calls and serial are dead
    comp.touchMotion(1, 4, 0, 256, 256);
    comp.touchUp(1, 4, 0);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{});
    try SeatTest.send(&comp, 8, resize_op, &.{ .{ .object = 20 }, .{ .uint = s1 }, .{ .uint = 4 } });
    try std.testing.expectEqual(calls, sink.inter_calls);

    // a resize from a finger on a subsurface of the window counts too
    try SeatTest.send(&comp, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 50 } } });
    try SeatTest.send(&comp, 3, 0, &.{.{ .new_id = 51 }});
    try SeatTest.send(&comp, 50, 1, &.{ .{ .new_id = 52 }, .{ .object = 51 }, .{ .object = 6 } });
    comp.touchDown(1, 5, 51, 2, 0, 0);
    try SeatTest.send(&comp, 8, resize_op, &.{ .{ .object = 20 }, .{ .uint = comp.conns.get(1).?.serial }, .{ .uint = 8 } });
    try std.testing.expectEqual(calls + 1, sink.inter_calls);
    try std.testing.expectEqual(@as(u32, 1), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 8), sink.inter_value);
    try std.testing.expectEqual(@as(u8, 0), comp.conns.get(1).?.touch_n);
    calls = sink.inter_calls;

    // start_drag: a touch serial is refused, even one inside a held
    // press's range (press, finger, press); the press's own is honoured
    try SeatTest.getPointer(&comp, 20, 30);
    try SeatTest.send(&comp, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 60 } } });
    try SeatTest.send(&comp, 60, 1, &.{ .{ .new_id = 61 }, .{ .object = 20 } }); // get_data_device
    try SeatTest.send(&comp, 60, 0, &.{.{ .new_id = 62 }}); // create_data_source
    comp.pointerEnter(1, 6, 0, 0);
    comp.pointerButton(1, 6, 0x110, true);
    comp.touchDown(1, 6, 6, 3, 0, 0);
    const s_touch = comp.conns.get(1).?.serial;
    comp.pointerButton(1, 6, 0x111, true);
    const s_press = comp.conns.get(1).?.serial;
    const start_drag_op = comptime protocol.find("wl_data_device").?.requestIndex("start_drag").?;
    try SeatTest.send(&comp, 61, start_drag_op, &.{ .{ .object = 62 }, .{ .object = 6 }, .{ .object = 0 }, .{ .uint = s_touch } });
    try std.testing.expect(comp.drag == null);
    try std.testing.expectEqual(calls, sink.inter_calls);
    try SeatTest.send(&comp, 61, start_drag_op, &.{ .{ .object = 62 }, .{ .object = 6 }, .{ .object = 0 }, .{ .uint = s_press } });
    try std.testing.expect(comp.drag != null);
    // the dnd grab owns input: no new finger goes down
    sink.events.clearRetainingCapacity();
    comp.touchDown(1, 7, 6, 4, 0, 0);
    try T.expectEvents(&sink, &.{});
}

test "touch: a move naming a touch-down serial that falls between two held presses is the finger's: the client's touch is cancelled; the press's own serial cancels nothing" {
    const T = TouchTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    comp.interactive_fn = TestSink.interactive;
    const move_op = comptime protocol.find("xdg_toplevel").?.requestIndex("move").?;
    try SeatTest.getPointer(&comp, 20, 30);
    comp.pointerEnter(1, 6, 0, 0);

    // a button held, a finger down, another button: the down's serial is
    // inside the held presses' range (inImplicitGrab passes it too)
    comp.pointerButton(1, 1, 0x110, true);
    comp.touchDown(1, 2, 6, 0, 0, 0);
    const s_touch = comp.conns.get(1).?.serial;
    comp.touchFrame(1);
    comp.pointerButton(1, 3, 0x111, true);
    const s_press = comp.conns.get(1).?.serial;
    sink.events.clearRetainingCapacity();
    const calls = sink.inter_calls;
    try SeatTest.send(&comp, 8, move_op, &.{ .{ .object = 20 }, .{ .uint = s_touch } });
    try std.testing.expectEqual(calls + 1, sink.inter_calls);
    try T.expectEvents(&sink, &.{.{ 21, T.cancel }});
    try std.testing.expectEqual(@as(u8, 0), comp.conns.get(1).?.touch_n);

    // the press's serial with a finger down: the pointer's move, the
    // finger stays the client's
    comp.touchDown(1, 4, 6, 1, 0, 0);
    comp.touchFrame(1);
    sink.events.clearRetainingCapacity();
    try SeatTest.send(&comp, 8, move_op, &.{ .{ .object = 20 }, .{ .uint = s_press } });
    try std.testing.expectEqual(calls + 2, sink.inter_calls);
    try T.expectEvents(&sink, &.{});
    try std.testing.expectEqual(@as(u8, 1), comp.conns.get(1).?.touch_n);
}

test "touch: a destroyed or unmapped surface drops its points (and its subsurfaces') silently" {
    const T = TouchTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp);
    // subsurfaces 51 and 53 of the toplevel, 55 of 53
    try SeatTest.send(&comp, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 50 } } });
    for ([_][2]u32{ .{ 51, 6 }, .{ 53, 6 }, .{ 55, 53 } }) |sp| {
        try SeatTest.send(&comp, 3, 0, &.{.{ .new_id = sp[0] }});
        try SeatTest.send(&comp, 50, 1, &.{ .{ .new_id = sp[0] + 1 }, .{ .object = sp[0] }, .{ .object = sp[1] } });
    }
    const surf_destroy = comptime protocol.find("wl_surface").?.requestIndex("destroy").?;
    const c = comp.conns.get(1).?;

    // a finger on 51, 53, 55 and the toplevel
    comp.touchDown(1, 1, 51, 1, 0, 0);
    comp.touchDown(1, 1, 53, 2, 0, 0);
    comp.touchDown(1, 1, 55, 3, 0, 0);
    comp.touchDown(1, 1, 6, 4, 0, 0);
    comp.touchFrame(1);
    sink.events.clearRetainingCapacity();
    // 51 destroyed: its point goes, no event names it
    try SeatTest.send(&comp, 51, surf_destroy, &.{});
    try std.testing.expectEqual(@as(u8, 3), c.touch_n);
    // 53 destroyed: its point and 55's (hanging from it)
    try SeatTest.send(&comp, 53, surf_destroy, &.{});
    try std.testing.expectEqual(@as(u8, 1), c.touch_n);
    comp.touchUp(1, 2, 1);
    comp.touchUp(1, 2, 3);
    comp.touchFrame(1);
    try T.expectEvents(&sink, &.{});
    // the xdg_toplevel destroyed (unmapped, the wl_surface lives on): 6's
    try SeatTest.send(&comp, 8, comptime protocol.find("xdg_toplevel").?.requestIndex("destroy").?, &.{});
    try std.testing.expectEqual(@as(u8, 0), c.touch_n);
    try T.expectEvents(&sink, &.{});
}

test "touch: a popup grabbing with the serial of a tap's down (GTK's menu on a tap) is mapped and kept, not dismissed" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, TouchTest.get_touch, &.{.{ .new_id = 21 }});
    comp.touchDown(1, 1, 6, 0, 0, 0);
    const s_down = comp.conns.get(1).?.serial;
    comp.touchFrame(1);
    // the menu: surface 15, xdg_surface 16, xdg_popup 17, grabbing with it
    try PopupTest.positioner(&comp, 14, 10, 10, .{ 8, 8 }, 50, 40);
    try PopupTest.popup(&comp, 15, 7, 14);
    try T.send(&comp, 17, comptime protocol.find("xdg_popup").?.requestIndex("grab").?, &.{ .{ .object = 9 }, .{ .uint = s_down } });
    try T.send(&comp, 15, T.commit_op, &.{});
    try T.send(&comp, 15, T.attach_op, &.{ .{ .object = 31 }, .{ .int = 0 }, .{ .int = 0 } });
    try T.send(&comp, 15, T.commit_op, &.{});
    // (the finger may lift before or after: the menu stays either way)
    comp.touchUp(1, 2, 0);
    comp.touchFrame(1);
    const done_op = comptime protocol.find("xdg_popup").?.eventIndex("popup_done").?;
    for (sink.events.items) |e| try std.testing.expect(!(e.object_id == 17 and e.opcode == done_op));
    try std.testing.expectEqual(Role.popup, comp.surfaceRole(1, 15));
    try std.testing.expect(comp.surfaceHasContent(1, 15));
}

test "touch: minimizing a window with a finger on it cancels the client's touch, a minimized one takes no down; hiding cancels too, a hidden one still takes downs" {
    const T = WinTest;
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    try T.setup(&comp, &sink);
    try T.send(&comp, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 9 } } });
    try T.send(&comp, 9, TouchTest.get_touch, &.{.{ .new_id = 21 }});
    sink.events.clearRetainingCapacity();
    const c = comp.conns.get(1).?;

    comp.touchDown(1, 1, 6, 0, 0, 0);
    comp.touchFrame(1);
    sink.events.clearRetainingCapacity();
    comp.setMinimized(1, 6, true);
    try TouchTest.expectEvents(&sink, &.{.{ 21, TouchTest.cancel }});
    comp.touchDown(1, 2, 6, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 0), c.touch_n);
    comp.setMinimized(1, 6, false);
    sink.events.clearRetainingCapacity();

    // hidden with no finger on it: nothing for wl_touch
    comp.setVisible(1, 6, false);
    comp.setVisible(1, 6, true);
    try TouchTest.expectEvents(&sink, &.{});
    comp.touchDown(1, 3, 6, 0, 0, 0);
    comp.touchFrame(1);
    sink.events.clearRetainingCapacity();
    comp.setVisible(1, 6, false);
    try TouchTest.expectEvents(&sink, &.{.{ 21, TouchTest.cancel }});
    try std.testing.expectEqual(@as(u8, 0), c.touch_n);
    // the embedder routes input to hidden windows as it likes
    comp.touchDown(1, 4, 6, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 1), c.touch_n);
}

test "data devices: each of a client's wl_data_devices and primary devices gets an offer of its own (dense server ids, SRVOBJ per primary offer); a late one while focused gets the selection; release" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.fdmsg_fn = TestSink.fdmsg;
    var buf: [256]u8 = undefined;

    // conn 2: the source of both selections (clip manager 3 → source 4,
    // device 5; primary manager 6 → source 7, device 8)
    try comp.connOpen(2);
    try comp.onWire(2, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 3 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 4 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 4, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 3, 1, &.{ .{ .new_id = 5 }, .{ .object = 9 } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 4 }, .{ .uint = testInputSerial(&comp, 2) } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 6 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 7 }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 7, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(2, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 9 } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 8, 0, &.{ .{ .object = 7 }, .{ .uint = testInputSerial(&comp, 2) } }));

    // conn 1 (Firefox-shaped): two seats (20 GTK's, 23 its own), a keyboard,
    // a data device and a primary device on each
    const T = SeatTest;
    try T.setup(&comp);
    try T.bindSeat(&comp, 20, 9);
    try T.bindSeat(&comp, 23, 9);
    try T.getKeyboard(&comp, 20, 22);
    try T.send(&comp, 2, 0, &.{ .{ .uint = 7 }, .{ .new_id_dynamic = .{ .interface = "wl_data_device_manager", .version = 3, .id = 30 } } });
    try T.send(&comp, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 31 } } });
    try T.send(&comp, 30, 1, &.{ .{ .new_id = 32 }, .{ .object = 20 } });
    try T.send(&comp, 30, 1, &.{ .{ .new_id = 33 }, .{ .object = 23 } });
    try T.send(&comp, 31, 1, &.{ .{ .new_id = 34 }, .{ .object = 20 } });
    try T.send(&comp, 31, 1, &.{ .{ .new_id = 35 }, .{ .object = 23 } });
    sink.events.clearRetainingCapacity();
    const srvobj0 = sink.srvobj_calls;

    const dd = comptime protocol.find("wl_data_device").?;
    const pd = comptime protocol.find("zwp_primary_selection_device_v1").?;
    const dd_offer = comptime dd.eventIndex("data_offer").?;
    const dd_sel = comptime dd.eventIndex("selection").?;
    const pd_offer = comptime pd.eventIndex("data_offer").?;
    const pd_sel = comptime pd.eventIndex("selection").?;
    const H = struct {
        /// the offer `device` was introduced to and its selection names
        /// (they must agree; the last of each since the clear)
        fn offerOf(sk: *const TestSink, device: u32, intro: u16, sel: u16) !u32 {
            var vals: [wire.max_args]wire.Value = undefined;
            const id = (try SeatTest.argsOf(sk, device, intro, &.{.new_id}, &vals))[0].new_id;
            try std.testing.expectEqual(id, (try SeatTest.argsOf(sk, device, sel, &.{.object}, &vals))[0].object);
            return id;
        }
    };

    comp.keyboardEnter(1, 6);
    const a = try H.offerOf(&sink, 32, dd_offer, dd_sel);
    const b = try H.offerOf(&sink, 33, dd_offer, dd_sel);
    const pa = try H.offerOf(&sink, 34, pd_offer, pd_sel);
    const pb = try H.offerOf(&sink, 35, pd_offer, pd_sel);
    // one dense server-id space, in order: the data offers, then the primary
    try std.testing.expectEqual(objects.server_id_base, a);
    try std.testing.expectEqual(a + 1, b);
    try std.testing.expectEqual(a + 2, pa);
    try std.testing.expectEqual(a + 3, pb);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, a, comptime protocol.find("wl_data_offer").?.eventIndex("offer").?));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, b, comptime protocol.find("wl_data_offer").?.eventIndex("offer").?));
    // each primary offer flagged on its own; the data offers are not
    try std.testing.expectEqual(srvobj0 + 2, sink.srvobj_calls);
    try std.testing.expect(sink.isPrimary(pa) and sink.isPrimary(pb));
    try std.testing.expect(!sink.isPrimary(a) and !sink.isPrimary(b));

    // a receive on the SECOND device's offers routes to the source too
    comp.onPipeReceive(1, wire.encodeMessage(&buf, b, 1, &.{ .{ .string = "text/plain" }, .fd }), 41);
    try std.testing.expectEqual(@as(u32, 2), sink.fdmsg_conn);
    try std.testing.expectEqual(@as(u32, 41), sink.fdmsg_token);
    comp.onPipeReceive(1, wire.encodeMessage(&buf, pb, 0, &.{ .{ .string = "text/plain" }, .fd }), 42);
    try std.testing.expectEqual(@as(u32, 2), sink.fdmsg_conn);
    try std.testing.expectEqual(@as(u32, 42), sink.fdmsg_token);

    // a data device made while the client has keyboard focus: the selection now
    sink.events.clearRetainingCapacity();
    try T.send(&comp, 30, 1, &.{ .{ .new_id = 36 }, .{ .object = 23 } });
    const c = try H.offerOf(&sink, 36, dd_offer, dd_sel);
    try std.testing.expectEqual(pb + 1, c);
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 32, dd_sel));

    // GTK's data device released (v2+): a new selection reaches the others only
    try T.send(&comp, 32, comptime dd.requestIndex("release").?, &.{});
    sink.events.clearRetainingCapacity();
    try comp.onWire(2, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 0 }, .{ .uint = testInputSerial(&comp, 2) } })); // cleared
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 32, dd_sel));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 33, dd_sel));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 36, dd_sel));
}

test "dnd: a target with two wl_data_devices — each gets its own offer and the enter (one serial), motion, drop; accept on either counts" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.interactive_fn = TestSink.interactive;
    comp.fdmsg_fn = TestSink.fdmsg;

    try dndConnSetup(&comp, 1);
    try dndConnSetup(&comp, 2);
    var buf: [128]u8 = undefined;
    // conn 2's second seat (30) and data device (31) on it, Firefox-style
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 30 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 31 }, .{ .object = 30 } }));
    // conn 1 drags source 12 (text/plain; copy)
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 12 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 12, 2, &.{.{ .uint = dnd_action_copy }}));
    comp.pointerEnter(1, 7, 0, 0);
    comp.pointerButton(1, 0, 0x110, true);
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = comp.conns.get(1).?.serial } }));

    const dd = comptime protocol.find("wl_data_device").?;
    const off = comptime protocol.find("wl_data_offer").?;
    const src = comptime protocol.find("wl_data_source").?;
    const Of = struct {
        fn count(sk: *const TestSink, conn: u32, obj: u32, opcode: u16) usize {
            var n: usize = 0;
            for (sk.events.items) |e| {
                if (e.conn_id == conn and e.object_id == obj and e.opcode == opcode) n += 1;
            }
            return n;
        }
        fn enter(sk: *const TestSink, obj: u32) ![2]u32 { // serial, offer
            var vals: [wire.max_args]wire.Value = undefined;
            for (sk.events.items) |e| {
                if (e.conn_id != 2 or e.object_id != obj or e.opcode != dd.eventIndex("enter").?) continue;
                const a = try wire.decodeArgs(e.bytes[wire.header_size..e.len], &.{ .uint, .object, .fixed, .fixed, .object }, &vals);
                return .{ a[0].uint, a[4].object };
            }
            return error.NoEnter;
        }
    };

    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 1000, 2560, 5120);
    const e1 = try Of.enter(&sink, 11);
    const e2 = try Of.enter(&sink, 31);
    try std.testing.expectEqual(e1[0], e2[0]); // one serial
    try std.testing.expect(e1[1] != e2[1] and e1[1] >= objects.server_id_base and e2[1] >= objects.server_id_base);
    for ([_]u32{ e1[1], e2[1] }) |o| {
        try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 2, o, off.eventIndex("offer").?));
        try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 2, o, off.eventIndex("source_actions").?));
    }

    // accept + set_actions on the second device's offer: honoured
    sink.events.clearRetainingCapacity();
    try comp.onWire(2, wire.encodeMessage(&buf, e2[1], 0, &.{ .{ .uint = 1 }, .{ .string = "text/plain" } }));
    try comp.onWire(2, wire.encodeMessage(&buf, e2[1], 4, &.{ .{ .uint = dnd_action_copy }, .{ .uint = dnd_action_copy } }));
    try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 1, 12, src.eventIndex("target").?));
    try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 2, e2[1], off.eventIndex("action").?));
    try std.testing.expect(comp.drag.?.accepted);

    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 1100, 2600, 5200);
    try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 2, 11, dd.eventIndex("motion").?));
    try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 2, 31, dd.eventIndex("motion").?));

    sink.events.clearRetainingCapacity();
    comp.dragDrop();
    try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 2, 11, dd.eventIndex("drop").?));
    try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 2, 31, dd.eventIndex("drop").?));
    try std.testing.expectEqual(@as(usize, 1), Of.count(&sink, 1, 12, src.eventIndex("dnd_drop_performed").?));

    // either device's offer carries the transfer to the source
    comp.onPipeReceive(2, wire.encodeMessage(&buf, e1[1], 1, &.{ .{ .string = "text/plain" }, .fd }), 5);
    try std.testing.expectEqual(@as(u32, 1), sink.fdmsg_conn);
    try std.testing.expectEqual(@as(u32, 5), sink.fdmsg_token);
}

/// An own-drag test rig: conns 1 and 2 (dndConnSetup), the relay's
/// selection_cache, the callbacks the own drag uses.
fn ownDragSetup(sink: *TestSink) !Compositor {
    var comp = testSetup(sink);
    errdefer comp.deinit();
    comp.interactive_fn = TestSink.interactive;
    comp.fdmsg_fn = TestSink.fdmsg;
    comp.drag_action_fn = TestSink.dragAction;
    try dndConnSetup(&comp, 1);
    try dndConnSetup(&comp, 2);
    return comp;
}

const OwnDragT = struct {
    const dd = protocol.find("wl_data_device").?;
    const off = protocol.find("wl_data_offer").?;

    /// the offer of conn 2's enter on data device `dev` (0: none seen)
    fn enterOffer(sk: *const TestSink, dev: u32) !u32 {
        return enterOffer2(sk, 2, dev);
    }
    fn enterOffer2(sk: *const TestSink, conn: u32, dev: u32) !u32 {
        var vals: [wire.max_args]wire.Value = undefined;
        for (sk.events.items) |e| {
            if (e.conn_id != conn or e.object_id != dev or e.opcode != dd.eventIndex("enter").?) continue;
            return (try wire.decodeArgs(e.bytes[wire.header_size..e.len], &.{ .uint, .object, .fixed, .fixed, .object }, &vals))[4].object;
        }
        return 0;
    }
    fn count(sk: *const TestSink, conn: u32, obj: u32, opcode: u16) usize {
        var n: usize = 0;
        for (sk.events.items) |e| {
            if (e.conn_id == conn and e.object_id == obj and e.opcode == opcode) n += 1;
        }
        return n;
    }
    fn receive(comp: *Compositor, offer: u32, mime: []const u8, token: u32) void {
        var buf: [128]u8 = undefined;
        comp.onPipeReceive(2, wire.encodeMessage(&buf, offer, 1, &.{ .{ .string = mime }, .fd }), token);
    }
    /// the last fdmsg was EOF for `token` (pipe, no wire message, the token alone)
    fn expectEof(sk: *const TestSink, token: u32) !void {
        try std.testing.expectEqual(@as(u32, 3), sk.fdmsg_kind);
        try std.testing.expectEqual(@as(usize, 0), sk.fdmsg_len);
        try std.testing.expectEqual(@as(usize, 4), sk.fdmsg_aux_len);
        try std.testing.expectEqual(token, sk.fdmsg_token);
    }
    /// the last fdmsg wrote `bytes` into `token`'s pipe (pipe, no wire
    /// message, aux = token ++ bytes)
    fn expectWrite(sk: *const TestSink, conn: u32, token: u32, bytes: []const u8) !void {
        try std.testing.expectEqual(@as(u32, 3), sk.fdmsg_kind);
        try std.testing.expectEqual(conn, sk.fdmsg_conn);
        try std.testing.expectEqual(@as(usize, 0), sk.fdmsg_len);
        try std.testing.expectEqual(4 + bytes.len, sk.fdmsg_aux_len);
        try std.testing.expectEqual(token, std.mem.readInt(u32, sk.fdmsg_aux[0..4], .little));
        try std.testing.expectEqualStrings(bytes, sk.fdmsg_aux[4..][0..bytes.len]);
    }
};

test "own drag: begun by the embedder (no press, no client source) — offers its types to the target, receives held until the payloads come, actions negotiated without a source, the drop, receives after it, finish frees it" {
    var sink: TestSink = undefined;
    var comp = try ownDragSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    const T = OwnDragT;
    var buf: [128]u8 = undefined;

    // no FEATURE selection_cache: refused, nothing offered (a receive could not be served)
    try std.testing.expectError(error.Unsupported, comp.beginOwnDrag("text/plain", dnd_action_copy));
    try std.testing.expect(comp.drag == null);
    comp.applyFeature(@intFromEnum(stream.FeatureKind.selection_cache), &.{});
    try std.testing.expectError(error.BadDrag, comp.beginOwnDrag("", dnd_action_copy));
    try std.testing.expectError(error.BadDrag, comp.beginOwnDrag("text/plain", 4)); // ask only
    try std.testing.expectError(error.BadDrag, comp.beginOwnDrag("text/plain\x00\x00x", dnd_action_copy));
    try std.testing.expect(comp.drag == null and comp.own_drag == null);

    try comp.beginOwnDrag("text/plain;charset=utf-8\x00text/plain\x00text/html\x00text/plain", dnd_action_copy | dnd_action_move);
    try std.testing.expect(comp.drag != null and comp.drag.?.own);
    try std.testing.expectEqual(@as(usize, 3), comp.own_drag.?.mimes.items.len); // the repeat once
    try std.testing.expectEqual(@as(u32, 0), sink.inter_calls); // no drag-start: the embedder began it
    try std.testing.expectError(error.Busy, comp.beginOwnDrag("text/plain", dnd_action_copy));

    // the pointer is the drag's meanwhile
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(2, 7, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // over conn 2: data_offer, offer ×3, source_actions, enter
    comp.dragMotion(2, 7, 1000, 2560, 5120);
    try std.testing.expectEqual(@as(usize, 6), sink.events.items.len);
    const offer = try T.enterOffer(&sink, 11);
    try std.testing.expect(offer >= objects.server_id_base);
    try std.testing.expectEqual(@as(usize, 3), T.count(&sink, 2, offer, T.off.eventIndex("offer").?));
    var vals: [wire.max_args]wire.Value = undefined;
    const sa = sink.events.items[4];
    try std.testing.expectEqual(T.off.eventIndex("source_actions").?, sa.opcode);
    try std.testing.expectEqual(dnd_action_copy | dnd_action_move, (try wire.decodeArgs(sa.bytes[wire.header_size..sa.len], &.{.uint}, &vals))[0].uint);
    try std.testing.expectEqual(@as(u32, 0), sink.drag_action_calls); // nothing accepted yet

    // a receive before the payloads: held (nothing goes to the relay)
    const calls = sink.fdmsg_calls;
    T.receive(&comp, offer, "text/plain", 41);
    try std.testing.expectEqual(calls, sink.fdmsg_calls);
    try std.testing.expectEqual(@as(usize, 1), comp.own_drag.?.held.items.len);
    // a type it does not offer: EOF at once
    T.receive(&comp, offer, "image/png", 42);
    try T.expectEof(&sink, 42);

    // accept: the drag's own preference (copy) until the target negotiates;
    // set_actions picks its preferred (move) — action to the offer, no source to tell
    sink.events.clearRetainingCapacity();
    try comp.onWire(2, wire.encodeMessage(&buf, offer, 0, &.{ .{ .uint = 1 }, .{ .string = "text/plain" } }));
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);
    try std.testing.expectEqual(dnd_action_copy, sink.drag_action);
    try comp.onWire(2, wire.encodeMessage(&buf, offer, 4, &.{ .{ .uint = dnd_action_copy | dnd_action_move }, .{ .uint = dnd_action_move } }));
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(T.off.eventIndex("action").?, sink.events.items[0].opcode);
    try std.testing.expectEqual(dnd_action_move, sink.drag_action);
    try std.testing.expectEqual(@as(u32, 2), sink.drag_action_calls);
    comp.dragMotion(2, 7, 1100, 2600, 5200); // a motion changes nothing told
    try std.testing.expectEqual(@as(u32, 2), sink.drag_action_calls);

    // the payloads: the held receive is answered (its bytes into its pipe)
    var pack: [256]u8 = undefined;
    try comp.setOwnDragData(packOwnSelection(&pack, &.{ .{ "text/plain", "hello" }, .{ "text/plain;charset=utf-8", null }, .{ "text/html", "<b>hi</b>" } }));
    try T.expectWrite(&sink, 2, 41, "hello");
    try std.testing.expectEqual(@as(usize, 0), comp.own_drag.?.held.items.len);
    try std.testing.expectError(error.AlreadySet, comp.setOwnDragData(""));

    // the drop: to the target, the session ends (no drag-end), the action told 0
    sink.events.clearRetainingCapacity();
    comp.dragDrop();
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 11, T.dd.eventIndex("drop").?));
    try std.testing.expect(comp.drag == null);
    try std.testing.expectEqual(@as(u32, 0), sink.inter_calls);
    try std.testing.expectEqual(@as(u32, 0), sink.drag_action);
    // receives after it: from the payloads (aliases share one)
    T.receive(&comp, offer, "text/html", 43);
    try T.expectWrite(&sink, 2, 43, "<b>hi</b>");
    T.receive(&comp, offer, "text/plain;charset=utf-8", 44);
    try T.expectWrite(&sink, 2, 44, "hello");
    try std.testing.expectError(error.NoDrag, comp.setOwnDragData(""));

    // finish: read, the payloads go; a later receive reads EOF
    try comp.onWire(2, wire.encodeMessage(&buf, offer, 3, &.{}));
    try std.testing.expect(comp.own_drag == null);
    T.receive(&comp, offer, "text/plain", 45);
    try T.expectEof(&sink, 45);

    // the pointer is the apps' again
    sink.events.clearRetainingCapacity();
    comp.pointerEnter(2, 7, 0, 0);
    try std.testing.expect(sink.events.items.len > 0);
}

test "own drag: held receives read EOF when the target is left, at a cancel and at a drop without payloads; two data devices each get an offer; an unaccepted drop, or one with no common action, cancels" {
    var sink: TestSink = undefined;
    var comp = try ownDragSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.applyFeature(@intFromEnum(stream.FeatureKind.selection_cache), &.{});
    const T = OwnDragT;
    var buf: [128]u8 = undefined;
    // conn 2's second seat (30) and data device (31) on it, Firefox-style
    try comp.onWire(2, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 5, .id = 30 } } }));
    try comp.onWire(2, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 31 }, .{ .object = 30 } }));

    try comp.beginOwnDrag("text/uri-list", dnd_action_copy);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 0, 256, 256);
    const o1 = try T.enterOffer(&sink, 11);
    const o2 = try T.enterOffer(&sink, 31);
    try std.testing.expect(o1 != 0 and o2 != 0 and o1 != o2);
    T.receive(&comp, o1, "text/uri-list", 1);
    T.receive(&comp, o2, "text/uri-list", 2);
    try std.testing.expectEqual(@as(usize, 2), comp.own_drag.?.held.items.len);

    // off the target: leave on both devices, both held receives read EOF
    const calls = sink.fdmsg_calls;
    sink.events.clearRetainingCapacity();
    comp.dragMotion(0, 0, 10, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 11, T.dd.eventIndex("leave").?));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 31, T.dd.eventIndex("leave").?));
    try std.testing.expectEqual(calls + 2, sink.fdmsg_calls);
    try T.expectEof(&sink, 2);
    try std.testing.expectEqual(@as(usize, 0), comp.own_drag.?.held.items.len);
    // a receive on a left offer now: EOF at once
    T.receive(&comp, o1, "text/uri-list", 3);
    try T.expectEof(&sink, 3);

    // back over it: fresh offers; a held receive reads EOF at the cancel
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 20, 256, 256);
    const o3 = try T.enterOffer(&sink, 11);
    T.receive(&comp, o3, "text/uri-list", 4);
    try comp.onWire(2, wire.encodeMessage(&buf, o3, 0, &.{ .{ .uint = 1 }, .{ .string = "text/uri-list" } }));
    try std.testing.expectEqual(dnd_action_copy, sink.drag_action);
    sink.events.clearRetainingCapacity();
    comp.dragCancel();
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 11, T.dd.eventIndex("leave").?));
    try T.expectEof(&sink, 4);
    try std.testing.expect(comp.drag == null and comp.own_drag == null);
    try std.testing.expectEqual(@as(u32, 0), sink.drag_action);
    try std.testing.expectEqual(@as(u32, 0), sink.inter_calls);

    // dropped with no payloads given: the held receive and later ones read EOF
    try comp.beginOwnDrag("text/uri-list", dnd_action_copy);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 30, 256, 256);
    const o4 = try T.enterOffer(&sink, 31);
    T.receive(&comp, o4, "text/uri-list", 5);
    try comp.onWire(2, wire.encodeMessage(&buf, o4, 0, &.{ .{ .uint = 1 }, .{ .string = "text/uri-list" } }));
    try comp.onWire(2, wire.encodeMessage(&buf, o4, 4, &.{ .{ .uint = dnd_action_copy }, .{ .uint = dnd_action_copy } }));
    sink.events.clearRetainingCapacity();
    comp.dragDrop();
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 11, T.dd.eventIndex("drop").?));
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 31, T.dd.eventIndex("drop").?));
    try T.expectEof(&sink, 5);
    T.receive(&comp, o4, "text/uri-list", 6);
    try T.expectEof(&sink, 6);

    // not accepted: the drop is a cancel (a leave, no drop)
    try comp.beginOwnDrag("text/plain", dnd_action_copy);
    comp.dragMotion(2, 7, 40, 256, 256);
    sink.events.clearRetainingCapacity();
    comp.dragDrop();
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 11, T.dd.eventIndex("leave").?));
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 2, 11, T.dd.eventIndex("drop").?));
    try std.testing.expect(comp.drag == null and comp.own_drag == null);

    // accepted, but the target takes only copy of a move-only drag: action 0, the drop cancels
    try comp.beginOwnDrag("text/plain", dnd_action_move);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 50, 256, 256);
    const o5 = try T.enterOffer(&sink, 11);
    try comp.onWire(2, wire.encodeMessage(&buf, o5, 0, &.{ .{ .uint = 1 }, .{ .string = "text/plain" } }));
    try std.testing.expectEqual(dnd_action_move, sink.drag_action);
    try comp.onWire(2, wire.encodeMessage(&buf, o5, 4, &.{ .{ .uint = dnd_action_copy }, .{ .uint = dnd_action_copy } }));
    try std.testing.expectEqual(@as(u32, 0), sink.drag_action);
    sink.events.clearRetainingCapacity();
    comp.dragDrop();
    try std.testing.expectEqual(@as(usize, 0), T.count(&sink, 2, 11, T.dd.eventIndex("drop").?));
    try std.testing.expect(comp.drag == null);
}

test "own drag: a drop whose bytes come after it (a page's files) — the drop target's receives on the drop's offers wait, before and after the drop, and are answered when the bytes come; a next own drag or the target's conn closing reads them EOF" {
    var sink: TestSink = undefined;
    var comp = try ownDragSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.applyFeature(@intFromEnum(stream.FeatureKind.selection_cache), &.{});
    const T = OwnDragT;
    var buf: [128]u8 = undefined;
    var pack: [128]u8 = undefined;

    try comp.beginOwnDrag("text/uri-list", dnd_action_copy);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 0, 256, 256);
    const o = try T.enterOffer(&sink, 11);
    T.receive(&comp, o, "text/uri-list", 20); // before the drop: held
    try comp.onWire(2, wire.encodeMessage(&buf, o, 0, &.{ .{ .uint = 1 }, .{ .string = "text/uri-list" } }));
    const calls = sink.fdmsg_calls;
    sink.events.clearRetainingCapacity();
    comp.dragDropBytes(true);
    try std.testing.expectEqual(@as(usize, 1), T.count(&sink, 2, 11, T.dd.eventIndex("drop").?));
    try std.testing.expect(comp.drag == null);
    try std.testing.expectEqual(calls, sink.fdmsg_calls); // still waiting
    T.receive(&comp, o, "text/uri-list", 21); // after the drop, on the drop's offer: waits too
    try std.testing.expectEqual(calls, sink.fdmsg_calls);
    try std.testing.expectEqual(@as(usize, 2), comp.own_drag.?.held.items.len);
    T.receive(&comp, o + 1, "text/uri-list", 22); // not an offer of the drop: EOF
    try T.expectEof(&sink, 22);
    // the bytes: both answered
    try comp.setOwnDragData(packOwnSelection(&pack, &.{.{ "text/uri-list", "file:///tmp/a.png\r\n" }}));
    try std.testing.expectEqual(calls + 3, sink.fdmsg_calls);
    try T.expectWrite(&sink, 2, 21, "file:///tmp/a.png\r\n");
    try std.testing.expectError(error.AlreadySet, comp.setOwnDragData(""));

    // awaiting bytes that never come: the next own drag reads its receive EOF
    try comp.beginOwnDrag("image/png", dnd_action_copy);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 10, 256, 256);
    const o2 = try T.enterOffer(&sink, 11);
    try comp.onWire(2, wire.encodeMessage(&buf, o2, 0, &.{ .{ .uint = 1 }, .{ .string = "image/png" } }));
    comp.dragDropBytes(true);
    T.receive(&comp, o2, "image/png", 30);
    try std.testing.expectEqual(@as(usize, 1), comp.own_drag.?.held.items.len);
    try comp.beginOwnDrag("text/plain", dnd_action_copy);
    try T.expectEof(&sink, 30);
    comp.dragCancel();

    // ... or the target's conn closing
    try comp.beginOwnDrag("image/png", dnd_action_copy);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 20, 256, 256);
    const o3 = try T.enterOffer(&sink, 11);
    try comp.onWire(2, wire.encodeMessage(&buf, o3, 0, &.{ .{ .uint = 1 }, .{ .string = "image/png" } }));
    comp.dragDropBytes(true);
    T.receive(&comp, o3, "image/png", 31);
    comp.connClose(2);
    try T.expectEof(&sink, 31);
    try std.testing.expect(comp.own_drag == null);

    // a plain drop (bytes in, or none): nothing more taken after it
    try comp.beginOwnDrag("text/plain", dnd_action_copy);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(1, 7, 30, 256, 256);
    const o4 = try T.enterOffer2(&sink, 1, 11);
    try comp.onWire(1, wire.encodeMessage(&buf, o4, 0, &.{ .{ .uint = 1 }, .{ .string = "text/plain" } }));
    comp.dragDrop();
    try std.testing.expectError(error.NoDrag, comp.setOwnDragData(""));
}

test "own drag: the target's conn closing reads its held receives EOF (the relay parks fds by token); the drop target's closing frees the payloads; an app's start_drag meanwhile is ignored" {
    var sink: TestSink = undefined;
    var comp = try ownDragSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);
    comp.applyFeature(@intFromEnum(stream.FeatureKind.selection_cache), &.{});
    const T = OwnDragT;
    var buf: [128]u8 = undefined;

    try comp.beginOwnDrag("text/plain", dnd_action_copy);
    // an app's start_drag while it lasts: ignored (one drag at a time)
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 12 }}));
    comp.dragMotion(1, 7, 0, 0, 0);
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = comp.conns.get(1).?.serial } }));
    try std.testing.expect(comp.drag.?.own);
    try std.testing.expectEqual(@as(u32, 0), sink.inter_calls);

    sink.events.clearRetainingCapacity();
    comp.dragMotion(2, 7, 10, 256, 256);
    const o = try T.enterOffer(&sink, 11);
    T.receive(&comp, o, "text/plain", 7);
    try comp.onWire(2, wire.encodeMessage(&buf, o, 0, &.{ .{ .uint = 1 }, .{ .string = "text/plain" } }));
    try std.testing.expectEqual(dnd_action_copy, sink.drag_action);
    comp.connClose(2);
    try T.expectEof(&sink, 7);
    try std.testing.expectEqual(@as(u32, 0), sink.drag_action); // no target now
    try std.testing.expect(comp.drag != null); // the drag goes on (another target may come)
    comp.dragCancel();

    // a drop on conn 1, then conn 1 goes: the payloads with it
    try comp.beginOwnDrag("text/plain", dnd_action_copy);
    sink.events.clearRetainingCapacity();
    comp.dragMotion(1, 7, 20, 256, 256);
    const o1 = try T.enterOffer2(&sink, 1, 11);
    try comp.onWire(1, wire.encodeMessage(&buf, o1, 0, &.{ .{ .uint = 1 }, .{ .string = "text/plain" } }));
    var pack: [64]u8 = undefined;
    try comp.setOwnDragData(packOwnSelection(&pack, &.{.{ "text/plain", "x" }}));
    comp.dragDrop();
    try std.testing.expect(comp.own_drag != null);
    comp.connClose(1);
    try std.testing.expect(comp.own_drag == null);
}

/// Records the embedder callbacks a replay makes, one line each, in order.
const ReplayRecorder = struct {
    lines: std.ArrayList([]u8) = .empty,

    fn add(self: *ReplayRecorder, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(std.testing.allocator, fmt, args) catch unreachable;
        self.lines.append(std.testing.allocator, line) catch unreachable;
    }
    fn clear(self: *ReplayRecorder) void {
        for (self.lines.items) |l| std.testing.allocator.free(l);
        self.lines.clearRetainingCapacity();
    }
    fn deinit(self: *ReplayRecorder) void {
        self.clear();
        self.lines.deinit(std.testing.allocator);
    }
    fn of(ctx: ?*anyopaque) *ReplayRecorder {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn send(_: ?*anyopaque, _: u32, _: []const u8) void {}
    fn log(_: ?*anyopaque, _: []const u8) void {}
    fn surface(ctx: ?*anyopaque, c: u32, s: u32, v: u32) void {
        of(ctx).add("surface {d} {d} {d}", .{ c, s, v });
    }
    fn title(ctx: ?*anyopaque, c: u32, s: u32, t: []const u8) void {
        of(ctx).add("title {d} {d} {s}", .{ c, s, t });
    }
    fn appId(ctx: ?*anyopaque, c: u32, s: u32, a: []const u8) void {
        of(ctx).add("app_id {d} {d} {s}", .{ c, s, a });
    }
    fn limits(ctx: ?*anyopaque, c: u32, s: u32, min_w: i32, min_h: i32, max_w: i32, max_h: i32) void {
        of(ctx).add("limits {d} {d} {d} {d} {d} {d}", .{ c, s, min_w, min_h, max_w, max_h });
    }
    fn interactive(ctx: ?*anyopaque, c: u32, s: u32, k: u32, v: u32) void {
        of(ctx).add("interactive {d} {d} {d} {d}", .{ c, s, k, v });
    }
    fn region(ctx: ?*anyopaque, c: u32, s: u32, r: ?*const Region) void {
        of(ctx).add("region {d} {d} {d}", .{ c, s, if (r) |x| x.slice().len else 99 });
    }
    fn selection(ctx: ?*anyopaque, c: u32, mimes: []const []const u8) void {
        of(ctx).add("selection {d} {d}", .{ c, mimes.len });
    }
    fn shape(ctx: ?*anyopaque, c: u32, v: u32) void {
        of(ctx).add("shape {d} {d}", .{ c, v });
    }
    fn lock(ctx: ?*anyopaque, c: u32, s: u32) void {
        of(ctx).add("lock {d} {d}", .{ c, s });
    }
    fn decoration(ctx: ?*anyopaque, c: u32, s: u32, on: bool) void {
        of(ctx).add("decoration {d} {d} {}", .{ c, s, on });
    }
    fn touch(ctx: ?*anyopaque, c: u32, on: bool) void {
        of(ctx).add("touch {d} {}", .{ c, on });
    }
    fn expect(self: *const ReplayRecorder, want: []const []const u8) !void {
        errdefer for (self.lines.items) |l| std.debug.print("got: {s}\n", .{l});
        try std.testing.expectEqual(want.len, self.lines.items.len);
        for (want, self.lines.items) |w, l| try std.testing.expectEqualStrings(w, l);
    }
};

test "replay: an embedder attaching later is told each surface (parents first: role, title, app id, input region, size hints, decoration, window states) and the seat (pointer image, lock, touch, selection); embedderGone lets go of the seat and suspends" {
    var rec: ReplayRecorder = .{};
    defer rec.deinit();
    var comp = Compositor.init(std.testing.allocator, &rec, ReplayRecorder.send, ReplayRecorder.log);
    defer comp.deinit();
    comp.surface_fn = ReplayRecorder.surface;
    comp.title_fn = ReplayRecorder.title;
    comp.app_id_fn = ReplayRecorder.appId;
    comp.size_limits_fn = ReplayRecorder.limits;
    comp.decoration_fn = ReplayRecorder.decoration;
    comp.interactive_fn = ReplayRecorder.interactive;
    comp.input_region_fn = ReplayRecorder.region;
    comp.selection_fn = ReplayRecorder.selection;
    comp.cursor_shape_fn = ReplayRecorder.shape;
    comp.pointer_lock_fn = ReplayRecorder.lock;
    comp.touch_bound_fn = ReplayRecorder.touch;

    const surf = comptime protocol.find("wl_surface").?;
    const tl = comptime protocol.find("xdg_toplevel").?;
    var buf: [128]u8 = undefined;
    const S = struct {
        fn send(c: *Compositor, b: []u8, obj: u32, op: u16, args: []const wire.Value) !void {
            try c.onWire(1, wire.encodeMessage(b, obj, op, args));
        }
    };
    // conn 1: toplevel surface 6 (xdg 7, toplevel 8), mapped with content,
    // decorated by the embedder (a decoration object 41 before its first
    // commit)
    comp.setDecorations(true);
    try wmBaseToplevel(&comp, 1);
    try S.send(&comp, &buf, 2, 0, &.{ .{ .uint = 8 }, .{ .new_id_dynamic = .{ .interface = "zxdg_decoration_manager_v1", .version = 1, .id = 40 } } });
    try S.send(&comp, &buf, 40, 1, &.{ .{ .new_id = 41 }, .{ .object = 8 } });
    try S.send(&comp, &buf, 6, comptime surf.requestIndex("commit").?, &.{});
    try S.send(&comp, &buf, 6, comptime surf.requestIndex("attach").?, &.{ .{ .object = 30 }, .{ .int = 0 }, .{ .int = 0 } });
    try S.send(&comp, &buf, 6, comptime surf.requestIndex("commit").?, &.{});
    try S.send(&comp, &buf, 8, comptime tl.requestIndex("set_title").?, &.{.{ .string = "Old" }});
    try S.send(&comp, &buf, 8, comptime tl.requestIndex("set_title").?, &.{.{ .string = "Hello" }});
    try S.send(&comp, &buf, 8, comptime tl.requestIndex("set_app_id").?, &.{.{ .string = "hello.app" }});
    try S.send(&comp, &buf, 8, comptime tl.requestIndex("set_min_size").?, &.{ .{ .int = 100 }, .{ .int = 50 } });
    try S.send(&comp, &buf, 6, comptime surf.requestIndex("commit").?, &.{});
    try S.send(&comp, &buf, 8, comptime tl.requestIndex("set_maximized").?, &.{});
    // a subsurface 9 of it (made after a later surface 12, so ids alone
    // would not order it), with an input region of one box
    try S.send(&comp, &buf, 2, 0, &.{ .{ .uint = 2 }, .{ .new_id_dynamic = .{ .interface = "wl_subcompositor", .version = 1, .id = 5 } } });
    try S.send(&comp, &buf, 3, 0, &.{.{ .new_id = 12 }}); // create_surface 12: never given a role
    try S.send(&comp, &buf, 3, 0, &.{.{ .new_id = 9 }});
    try S.send(&comp, &buf, 5, 1, &.{ .{ .new_id = 10 }, .{ .object = 9 }, .{ .object = 6 } });
    try S.send(&comp, &buf, 3, comptime protocol.find("wl_compositor").?.requestIndex("create_region").?, &.{.{ .new_id = 11 }});
    try S.send(&comp, &buf, 11, comptime protocol.find("wl_region").?.requestIndex("add").?, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 5 }, .{ .int = 5 } });
    try S.send(&comp, &buf, 9, comptime surf.requestIndex("set_input_region").?, &.{.{ .object = 11 }});
    try S.send(&comp, &buf, 9, comptime surf.requestIndex("commit").?, &.{});
    try comp.connOpen(2); // a conn with nothing yet
    try std.testing.expect(comp.surfaceHasContent(1, 6));
    try std.testing.expect(!comp.surfaceHasContent(1, 9));
    const conns = try comp.connIds(std.testing.allocator);
    defer std.testing.allocator.free(conns);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, conns);

    rec.clear();
    comp.replaySurfaces();
    try rec.expect(&.{ "surface 1 6 1", "title 1 6 Hello", "app_id 1 6 hello.app", "limits 1 6 100 50 0 0", "decoration 1 6 true", "interactive 1 6 2 0", "surface 1 9 2", "region 1 9 1" });
    rec.clear();
    comp.replaySeat();
    try rec.expect(&.{"selection 0 0"}); // nobody holds the pointer: no image

    // a pointer over the window with a shape: the image is replayed while it holds it
    try S.send(&comp, &buf, 2, 0, &.{ .{ .uint = 4 }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 9, .id = 20 } } });
    try S.send(&comp, &buf, 20, 0, &.{.{ .new_id = 21 }}); // get_pointer
    try S.send(&comp, &buf, 20, 1, &.{.{ .new_id = 22 }}); // get_keyboard
    try S.send(&comp, &buf, 20, 2, &.{.{ .new_id = 25 }}); // get_touch
    comp.pointerEnter(1, 6, 0, 0);
    comp.keyboardEnter(1, 6);
    comp.keyboardKey(1, 0, 42, true); // shift held
    comp.pointerButton(1, 0, 0x110, true);
    try S.send(&comp, &buf, 2, 0, &.{ .{ .uint = 9 }, .{ .new_id_dynamic = .{ .interface = "wp_cursor_shape_manager_v1", .version = 1, .id = 23 } } });
    const enter_serial = comp.conns.get(1).?.pointer_enter_serial;
    try S.send(&comp, &buf, 23, 1, &.{ .{ .new_id = 24 }, .{ .object = 21 } }); // get_pointer
    try S.send(&comp, &buf, 24, 1, &.{ .{ .uint = enter_serial }, .{ .uint = 3 } }); // set_shape
    rec.clear();
    comp.replaySeat();
    try rec.expect(&.{ "shape 1 3", "touch 1 true", "selection 0 0" });

    // the embedder goes: pointer and keyboard leave, nothing held, suspended
    rec.clear();
    comp.embedderGone();
    const c1 = comp.conns.get(1).?;
    try std.testing.expectEqual(@as(u32, 0), c1.pointer_focus);
    try std.testing.expectEqual(@as(u32, 0), c1.keyboard_focus);
    try std.testing.expectEqual(@as(u32, 0), c1.buttons_held);
    try std.testing.expectEqual(@as(u32, 0), c1.mods_depressed);
    try std.testing.expectEqual(@as(u32, 0), c1.cursor_shape);
    try std.testing.expect(comp.suspended);
    try rec.expect(&.{"shape 1 0"}); // the pointer image reset with the leave
    rec.clear();
    comp.replaySeat();
    try rec.expect(&.{ "touch 1 true", "selection 0 0" }); // (the wl_touch outlives the embedder)

    // destroying the xdg_toplevel (its decoration first) drops its title,
    // app id, hints and decoration; the role-none surface is not replayed
    rec.clear();
    try S.send(&comp, &buf, 41, 0, &.{});
    try S.send(&comp, &buf, 8, comptime tl.requestIndex("destroy").?, &.{});
    try rec.expect(&.{ "limits 1 6 0 0 0 0", "decoration 1 6 false", "surface 1 6 0" });
    rec.clear();
    comp.replaySurfaces();
    try rec.expect(&.{ "surface 1 9 2", "region 1 9 1" });
}
