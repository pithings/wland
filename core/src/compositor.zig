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
    // the shell draws no window decorations (see 8bd3949) — every toplevel is answered
    // client_side, which is what makes SSD-preferring apps (foot) draw their
    // own CSD instead of mapping a bare window
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
};

/// linux-dmabuf, advertised only when the relay takes dmabufs: it says so
/// with a FEATURE frame first on the link (setDmabuf). Not in `globals`,
/// which every link offers. FD RULE: the fds are params.add (client →
/// relay, FDMSG kind dmabuf here) and feedback.format_table (sent as FDMSG
/// kind memfd, the relay makes the fd) — both intercepted. v4 = feedback
/// (Mesa finds its render node through main_device); v5 adds only the
/// same-modifier rule, v6 set_sampling_device (fd-free, not offered).
pub const dmabuf_global: Global = .{ .name = 14, .interface = "zwp_linux_dmabuf_v1", .version = 4 };

// zwp_linux_buffer_params_v1.error
const dmabuf_err_already_used: u32 = 0;
const dmabuf_err_plane_idx: u32 = 1;
const dmabuf_err_plane_set: u32 = 2;
const dmabuf_err_incomplete: u32 = 3;
const dmabuf_err_invalid_format: u32 = 4;
const dmabuf_err_invalid_dimensions: u32 = 5;
const dmabuf_max_planes = 4;
// wl_display.error
const display_err_invalid_object: u32 = 0;

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

// wl_pointer.axis_source: our browser wheel input is always a physical wheel
const axis_source_wheel: u32 = 0;
// wl_pointer.axis_relative_direction: physical motion matches axis direction
const axis_direction_identical: u32 = 0;
// one logical wheel detent in value120 units
const value120_per_notch: i32 = 120;

// zxdg_toplevel_decoration_v1.mode — the only mode we ever configure
const decoration_mode_client_side: u32 = 1;

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

// mod masks matching the canned us keymap
const mod_shift: u32 = 1 << 0;
const mod_lock: u32 = 1 << 1;
const mod_ctrl: u32 = 1 << 2;
const mod_alt: u32 = 1 << 3;
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
    /// xdg_toplevel size hints (0 = unset); resize requests are clamped
    min_w: i32 = 0,
    min_h: i32 = 0,
    max_w: i32 = 0,
    max_h: i32 = 0,
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
    /// zxdg_toplevel_decoration_v1 object id (0 = none); the mode is always
    /// client_side, so only the id needs tracking
    decoration_id: u32 = 0,
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
};

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

/// Minimal xdg_positioner state — enough for GTK menus.
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

    /// Popup position relative to the parent SURFACE's origin. xdg-shell
    /// says the parent's window geometry; that offset is left out on purpose
    /// for now (xwayland-satellite places menus from the surface origin while
    /// its default geometry starts at its titlebar — plan.md).
    fn place(p: *const Positioner) struct { x: i32, y: i32 } {
        const ax = p.anchor_x + if (isRight(p.anchor)) p.anchor_w else if (isLeft(p.anchor)) 0 else @divTrunc(p.anchor_w, 2);
        const ay = p.anchor_y + if (isBottom(p.anchor)) p.anchor_h else if (isTop(p.anchor)) 0 else @divTrunc(p.anchor_h, 2);
        const x = ax + p.dx - (if (isLeft(p.gravity)) p.w else if (isRight(p.gravity)) 0 else @divTrunc(p.w, 2));
        const y = ay + p.dy - (if (isTop(p.gravity)) p.h else if (isBottom(p.gravity)) 0 else @divTrunc(p.h, 2));
        return .{ .x = x, .y = y };
    }
};

/// The selection: which conn's wl_data_source currently owns the clipboard.
const Selection = struct { conn: u32, source: u32 };

/// An in-flight dnd session (wl_data_device.start_drag). The embedder owns
/// pointer tracking — it drives dragMotion/dragDrop/dragCancel like a
/// move/resize grab — and the compositor owns all protocol sequencing.
/// Offers allocated at each target register in `Conn.offers` exactly like
/// selection offers, so the server's receive/pipe interception carries dnd
/// transfers with no server change.
const Drag = struct {
    /// conn that requested start_drag (the origin surface's owner)
    source_conn: u32,
    /// wl_data_source id; 0 = client-internal drag (null source): only the
    /// source client's own surfaces are entered, and nothing transfers
    source_id: u32,
    origin_surface: u32,
    /// dnd_icon-role surface on source_conn (0 = none)
    icon_surface: u32,
    focus_conn: u32 = 0,
    focus_surface: u32 = 0,
    /// server-allocated wl_data_offer at the current target (0 over nothing
    /// or during a null-source drag)
    focus_offer: u32 = 0,
    /// last wl_data_offer.accept named a mime (a drop without this cancels)
    accepted: bool = false,
};

const Conn = struct {
    objects: objects.ObjectMap = .{},
    serial: u32 = 0,
    surfaces: std.AutoHashMapUnmanaged(u32, Surface) = .empty,
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
    pointer_id: u32 = 0,
    pointer_version: u32 = 0,
    keyboard_id: u32 = 0,
    keyboard_version: u32 = 0,
    pointer_focus: u32 = 0,
    /// serial of the latest wl_pointer.enter sent to this conn —
    /// wp_cursor_shape_device_v1.set_shape and wl_pointer.set_cursor must
    /// echo it or be ignored
    pointer_enter_serial: u32 = 0,
    /// The cursor surface set_cursor named for the current enter (0 = none:
    /// a shape, hidden, or nothing set yet) and its hotspot, surface-local
    /// logical px (offsets committed to the surface move it, per spec).
    /// Cleared on leave: the next enter needs a fresh set_cursor.
    cursor_surface: u32 = 0,
    cursor_hx: i32 = 0,
    cursor_hy: i32 = 0,
    /// where the pointer is in pointer_focus's local px (wl_fixed): the
    /// last enter or motion as the client saw it (clamped while confined,
    /// frozen while locked), and that motion's time
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    pointer_time: u32 = 0,
    /// zwp_relative_pointer_v1 ids (they share the seat's pointer focus)
    relative_pointers: std.ArrayList(u32) = .empty,
    /// pointer constraint object id → its state (see Constraint)
    constraints: std.AutoHashMapUnmanaged(u32, Constraint) = .empty,
    /// the surface whose lock the embedder was last told this conn wants (0 none)
    lock_surface: u32 = 0,
    keyboard_focus: u32 = 0,
    mods_depressed: u32 = 0,
    mods_locked: u32 = 0,
    data_device_id: u32 = 0,
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
    /// zwp_primary_selection_device_v1 object id (0 = none)
    primary_device_id: u32 = 0,
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
    /// A wp_presentation_feedback.presented event (`msg`, one whole wire
    /// message) whose timestamp the transport must replace: the core's is
    /// the page's frame time, which no client can read. The transport
    /// sends it as a PRESENTED frame and the relay writes its own
    /// CLOCK_MONOTONIC less `age_us` (how long before the tick the frame
    /// began, on the page's clock). Null: sent as is (unit tests).
    presented_fn: ?*const fn (ctx: ?*anyopaque, conn_id: u32, age_us: u32, msg: []const u8) void = null,
    conns: std.AutoHashMapUnmanaged(u32, *Conn) = .empty,
    /// clipboard: the current selection source, if any
    selection: ?Selection = null,
    /// primary selection (M13): the current source, if any. Independent of the
    /// clipboard selection but structurally identical.
    primary_selection: ?Selection = null,
    /// in-flight dnd session, if any (normal pointer delivery is suppressed)
    drag: ?Drag = null,
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
    /// true while the browser tab is hidden — mapped v6 toplevels are told
    /// via the xdg_toplevel suspended state so they can stop rendering.
    suspended: bool = false,
    /// linux-dmabuf as the relay offers it (its FEATURE frame); null = the
    /// relay takes no dmabufs and zwp_linux_dmabuf_v1 is not advertised.
    dmabuf: ?Dmabuf = null,
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

    fn destroyConn(self: *Compositor, conn: *Conn) void {
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
        conn.relative_pointers.deinit(self.gpa);
        conn.constraints.deinit(self.gpa);
        self.gpa.destroy(conn);
    }

    fn freeMimes(self: *Compositor, list: *std.ArrayList([]u8)) void {
        for (list.items) |mime| self.gpa.free(mime);
        list.deinit(self.gpa);
    }

    pub fn connOpen(self: *Compositor, conn_id: u32) !void {
        const conn = try self.gpa.create(Conn);
        conn.* = .{};
        try conn.objects.put(self.gpa, 1, protocol.find("wl_display").?, 1);
        try self.conns.put(self.gpa, conn_id, conn);
        self.logf("conn {d} open", .{conn_id});
    }

    pub fn connClose(self: *Compositor, conn_id: u32) void {
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
            }
        }
        if (self.primary_selection) |sel| {
            if (sel.conn == conn_id) {
                self.primary_selection = null;
                self.broadcastPrimarySelection();
            }
        }
        if (self.drag) |*drag| {
            if (drag.source_conn == conn_id) {
                drag.source_id = 0; // conn (and its source) already gone
                self.dragCancel();
            } else if (drag.focus_conn == conn_id) {
                drag.focus_conn = 0;
                drag.focus_surface = 0;
                drag.focus_offer = 0;
                drag.accepted = false;
            }
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
    /// A minimized window's callbacks are held until it is restored — on
    /// stream links only: the relay's own (WS) keep their 16 ms pace.
    pub fn tick(self: *Compositor, t: Tick) void {
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn_id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            if (conn.feedbacks.items.len > 0) self.presentFeedbacks(conn_id, conn, t);
            var keep: usize = 0;
            for (conn.frame_callbacks.items) |cb| {
                // a minimized window's surfaces are not repainted: their
                // callbacks wait for the window to come back (the client's
                // render loop stops, as on any compositor)
                if (!cb.committed or underMinimized(conn, cb.surface)) {
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
        if (underMinimized(conn, surface_id)) return false;
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

    /// The surface belongs to a minimized window: the root of its parent
    /// chain (subsurfaces and popups alike) is a minimized toplevel.
    fn underMinimized(conn: *const Conn, surface_id: u32) bool {
        var id = surface_id;
        for (0..32) |_| {
            const surface = conn.surfaces.get(id) orelse return false;
            if (surface.parent_id == 0) return surface.role == .toplevel and surface.minimized;
            id = surface.parent_id;
        }
        return false;
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
            self.onBind(conn_id, conn, bound.interface, bound.version, bound.id);
            return;
        }
        if (std.mem.eql(u8, iface.name, "wl_seat")) {
            if (std.mem.eql(u8, msg.name, "get_pointer")) {
                conn.pointer_id = args[0].new_id;
                conn.pointer_version = entry.version;
            } else if (std.mem.eql(u8, msg.name, "get_keyboard")) {
                conn.keyboard_id = args[0].new_id;
                conn.keyboard_version = entry.version;
                self.sendKeymap(conn_id, conn);
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
            if (self.title_fn) |title_fn| {
                if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                    title_fn(self.ctx, conn_id, surfaceIdOf(conn, surface), args[0].string orelse "");
                }
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and std.mem.eql(u8, msg.name, "set_min_size")) {
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                surface.min_w = args[0].int;
                surface.min_h = args[1].int;
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and std.mem.eql(u8, msg.name, "set_max_size")) {
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                surface.max_w = args[0].int;
                surface.max_h = args[1].int;
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and std.mem.eql(u8, msg.name, "move")) {
            // CSD titlebar drag; the embedder owns the drag (serial unchecked,
            // POC). A fullscreen window doesn't move.
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                if (!surface.fullscreen) {
                    if (self.interactive_fn) |f| f(self.ctx, conn_id, surfaceIdOf(conn, surface), 0, 0);
                }
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_toplevel") and std.mem.eql(u8, msg.name, "resize")) {
            // CSD border/corner drag; args = seat, serial, edges. Not while
            // fullscreen (its size is the desktop's).
            if (surfaceByToplevelId(conn, header.object_id)) |surface| {
                if (!surface.fullscreen) {
                    if (self.interactive_fn) |f| f(self.ctx, conn_id, surfaceIdOf(conn, surface), 1, args[2].uint);
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
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_surface") and std.mem.eql(u8, msg.name, "get_toplevel")) {
            if (surfaceByXdgId(conn, header.object_id)) |surface| {
                surface.toplevel_id = args[0].new_id;
                surface.role = .toplevel;
                self.notifySurface(conn_id, surfaceIdOf(conn, surface), @intFromEnum(Role.toplevel));
            }
        } else if (std.mem.eql(u8, iface.name, "wl_subcompositor") and std.mem.eql(u8, msg.name, "get_subsurface")) {
            if (conn.surfaces.getPtr(args[1].object)) |surface| {
                surface.role = .subsurface;
                surface.sub_obj_id = args[0].new_id;
                surface.parent_id = args[2].object;
                self.notifySurface(conn_id, args[1].object, @intFromEnum(Role.subsurface));
            }
        } else if (std.mem.eql(u8, iface.name, "wl_subsurface") and std.mem.eql(u8, msg.name, "set_position")) {
            if (surfaceBySubObjId(conn, header.object_id)) |surface| {
                surface.x = args[0].int;
                surface.y = args[1].int;
            }
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
                } else if (std.mem.eql(u8, msg.name, "destroy")) {
                    _ = conn.positioners.remove(header.object_id);
                }
            }
        } else if (std.mem.eql(u8, iface.name, "xdg_surface") and std.mem.eql(u8, msg.name, "get_popup")) {
            if (surfaceByXdgId(conn, header.object_id)) |surface| {
                surface.role = .popup;
                surface.popup_id = args[0].new_id;
                self.notifySurface(conn_id, surfaceIdOf(conn, surface), @intFromEnum(Role.popup));
                if (args[1].object != 0) { // parent xdg_surface is nullable
                    if (surfaceByXdgId(conn, args[1].object)) |parent| {
                        surface.parent_id = surfaceIdOf(conn, parent);
                    }
                }
                if (conn.positioners.get(args[2].object)) |pos| {
                    const placed = pos.place();
                    surface.x = placed.x;
                    surface.y = placed.y;
                    surface.popup_w = pos.w;
                    surface.popup_h = pos.h;
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
                conn.data_device_id = args[0].new_id;
            }
        } else if (std.mem.eql(u8, iface.name, "wl_data_source")) {
            if (std.mem.eql(u8, msg.name, "offer")) {
                if (conn.source_mimes.getPtr(header.object_id)) |list| {
                    const mime = try self.gpa.dupe(u8, args[0].string orelse "");
                    try list.append(self.gpa, mime);
                }
            } else if (std.mem.eql(u8, msg.name, "set_actions")) {
                try conn.source_actions.put(self.gpa, header.object_id, args[0].uint);
            }
        } else if (std.mem.eql(u8, iface.name, "wl_data_device")) {
            if (std.mem.eql(u8, msg.name, "set_selection")) {
                // serial unchecked (POC); args[0] is the source, 0 = clear
                self.setSelection(conn_id, args[0].object);
            } else if (std.mem.eql(u8, msg.name, "start_drag")) {
                // args: source (nullable), origin, icon (nullable), serial —
                // serial unchecked (POC, like set_selection/move/resize)
                self.startDrag(conn_id, conn, args[0].object, args[1].object, args[2].object);
            }
        } else if (std.mem.eql(u8, iface.name, "wl_data_offer")) {
            // requests on drag offers (selection offers only ever get
            // receive, which the server intercepts and never forwards)
            if (std.mem.eql(u8, msg.name, "accept")) {
                self.dragAccept(conn_id, header.object_id, args[1].string);
            } else if (std.mem.eql(u8, msg.name, "set_actions")) {
                self.dragOfferActions(conn_id, header.object_id, args[0].uint, args[1].uint);
            } else if (std.mem.eql(u8, msg.name, "finish")) {
                self.dragFinish(conn, header.object_id);
            }
        } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_device_manager_v1")) {
            // M13, mirror of wl_data_device_manager. destroy is a generic
            // destructor (removes the object); no dnd counterpart exists.
            if (std.mem.eql(u8, msg.name, "create_source")) {
                try conn.primary_source_mimes.put(self.gpa, args[0].new_id, .empty);
            } else if (std.mem.eql(u8, msg.name, "get_device")) {
                conn.primary_device_id = args[0].new_id;
            }
        } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_source_v1")) {
            // only `offer` (no set_actions — primary selection has no dnd)
            if (std.mem.eql(u8, msg.name, "offer")) {
                if (conn.primary_source_mimes.getPtr(header.object_id)) |list| {
                    const mime = try self.gpa.dupe(u8, args[0].string orelse "");
                    try list.append(self.gpa, mime);
                }
            }
        } else if (std.mem.eql(u8, iface.name, "zwp_primary_selection_device_v1")) {
            if (std.mem.eql(u8, msg.name, "set_selection")) {
                // args: source (nullable), serial — serial unchecked (POC,
                // exactly like wl_data_device.set_selection above)
                self.setPrimarySelection(conn_id, args[0].object);
            }
        }
        // zwp_primary_selection_offer_v1 requests never reach here: `receive`
        // is intercepted server-side (FDMSG pipe → onPipeReceive), and `destroy`
        // is handled by the generic destructor block below.
        else if (std.mem.eql(u8, iface.name, "zxdg_decoration_manager_v1") and std.mem.eql(u8, msg.name, "get_toplevel_decoration")) {
            if (surfaceByToplevelId(conn, args[1].object)) |surface| {
                surface.decoration_id = args[0].new_id;
                // mapped toplevels learn the mode now; unmapped ones get it
                // with their first configure (configureIfNeeded)
                if (surface.configured) self.sendDecorationConfigure(conn_id, conn, surface);
            }
        } else if (std.mem.eql(u8, iface.name, "zxdg_toplevel_decoration_v1") and
            (std.mem.eql(u8, msg.name, "set_mode") or std.mem.eql(u8, msg.name, "unset_mode")))
        {
            // the compositor picks the mode regardless of the request, and we
            // never draw decorations — re-answer client_side
            if (surfaceByDecorationId(conn, header.object_id)) |surface| {
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
        } else if (std.mem.eql(u8, iface.name, "zwp_linux_buffer_params_v1")) {
            // `add` arrives as FDMSG kind dmabuf: the relay kept the fd
            try self.dmabufParamsRequest(conn_id, conn, header.object_id, msg.name, args);
        } else if (std.mem.eql(u8, iface.name, "zwp_relative_pointer_manager_v1") and std.mem.eql(u8, msg.name, "get_relative_pointer")) {
            // one seat: every relative pointer shares its pointer focus
            try conn.relative_pointers.append(self.gpa, args[0].new_id);
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
                self.configureIfNeeded(conn_id, conn, header.object_id);
                if (conn.surfaces.getPtr(header.object_id)) |surface| {
                    if (surface.geom_pending) |geom| {
                        surface.geom = geom;
                        surface.geom_set = true;
                        surface.geom_pending = null;
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
                        drag.focus_conn = 0;
                        drag.focus_surface = 0;
                        drag.focus_offer = 0;
                        drag.accepted = false;
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
                        surface.role = .none;
                        surface.popup_id = 0;
                        surface.toplevel_id = 0;
                        surface.configured = false;
                        // window states are the xdg_toplevel's: a new one
                        // on this wl_surface starts floating and shown
                        surface.maximized = false;
                        surface.fullscreen = false;
                        surface.minimized = false;
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
                    surface.role = .none;
                    surface.sub_obj_id = 0;
                    surface.parent_id = 0;
                    self.setOnOutput(conn_id, conn, kv.key_ptr.*, surface, false);
                    self.notifySurface(conn_id, kv.key_ptr.*, @intFromEnum(Role.none));
                    break;
                }
            } else if (std.mem.eql(u8, iface.name, "xdg_surface")) {
                var it = conn.surfaces.valueIterator();
                while (it.next()) |surface| {
                    if (surface.xdg_surface_id == header.object_id) {
                        surface.xdg_surface_id = 0;
                        // window geometry is xdg_surface state
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
                if (surfaceByDecorationId(conn, header.object_id)) |surface| surface.decoration_id = 0;
            } else if (std.mem.eql(u8, iface.name, "zwp_relative_pointer_v1")) {
                for (conn.relative_pointers.items, 0..) |rid, i| {
                    if (rid == header.object_id) {
                        _ = conn.relative_pointers.swapRemove(i);
                        break;
                    }
                }
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
        self.notifySurface(conn_id, surface_id, @intFromEnum(Role.none));
    }

    fn notifySurface(self: *Compositor, conn_id: u32, surface_id: u32, value: u32) void {
        if (self.surface_fn) |surface_fn| surface_fn(self.ctx, conn_id, surface_id, value);
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

    fn surfaceIdOf(conn: *Conn, target: *Surface) u32 {
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr == target) return kv.key_ptr.*;
        }
        return 0;
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

    /// Offset of a surface relative to its root toplevel (sums the parent chain).
    pub fn surfaceAbs(self: *Compositor, conn_id: u32, surface_id: u32) struct { x: i32, y: i32 } {
        const conn = self.conns.get(conn_id) orelse return .{ .x = 0, .y = 0 };
        var x: i32 = 0;
        var y: i32 = 0;
        var id = surface_id;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            const surface = conn.surfaces.get(id) orelse break;
            x += surface.x;
            y += surface.y;
            if (surface.parent_id == 0) break;
            id = surface.parent_id;
        }
        return .{ .x = x, .y = y };
    }

    const state_maximized: u32 = 1;
    const state_fullscreen: u32 = 2;
    const state_activated: u32 = 4;
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
        for (states, 0..) |s, i| std.mem.writeInt(u32, state_bytes[i * 4 ..][0..4], s, .little);
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
    }

    /// The states every configure of this toplevel carries now: maximized,
    /// fullscreen; activated while it holds the keyboard (Chromium takes
    /// "is this window active" from it, not from wl_keyboard); suspended
    /// (v6) while the tab is hidden or the window minimized.
    fn toplevelStates(self: *Compositor, conn: *Conn, surface: *Surface, states: *[4]u32) []const u32 {
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
        if ((self.suspended or surface.minimized) and objVersion(conn, surface.toplevel_id) >= 6) {
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

    /// Answer a decoration-mode request on a mapped toplevel: the decoration
    /// configure rides an xdg_surface configure cycle of its own. During the
    /// INITIAL configure the mode is emitted inline instead (configureIfNeeded)
    /// so it shares the toplevel's first cycle.
    fn sendDecorationConfigure(self: *Compositor, conn_id: u32, conn: *Conn, surface: *Surface) void {
        if (surface.decoration_id == 0 or surface.xdg_surface_id == 0) return;
        self.sendEvent(conn_id, surface.decoration_id, "zxdg_toplevel_decoration_v1", "configure", &.{
            .{ .uint = decoration_mode_client_side },
        });
        self.sendEvent(conn_id, surface.xdg_surface_id, "xdg_surface", "configure", &.{
            .{ .uint = nextSerial(conn) },
        });
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
        var states: [4]u32 = undefined;
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
                // a minimized window is suspended either way
                if (surface.minimized) continue;
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
        const big = surface.maximized or surface.fullscreen;
        const w = if (big) self.desk_w else surface.last_w;
        const h = if (big) self.desk_h else surface.last_h;
        var states: [4]u32 = undefined;
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
    /// unlocked/unconfined before the leave) and dismisses its popups; a
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
            // (the leave's configure, no longer activated, carries `suspended`)
            told = conn.keyboard_focus == id and conn.keyboard_id != 0;
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
            surface.log_w = @divTrunc(@as(i32, @intCast(buf_w)), surface.buffer_scale);
            surface.log_h = @divTrunc(@as(i32, @intCast(buf_h)), surface.buffer_scale);
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
        var it = conn.surfaces.iterator();
        while (it.next()) |kv| {
            const sub = kv.value_ptr;
            if (sub.role != .subsurface or sub.log_w <= 0 or sub.log_h <= 0) continue;
            if (subsurfaceRoot(conn, kv.key_ptr.*) != surface_id) continue;
            const at = self.surfaceAbs(conn_id, kv.key_ptr.*); // sums the chain up to the root
            if (!any) {
                x0 = at.x;
                y0 = at.y;
                x1 = at.x + sub.log_w;
                y1 = at.y + sub.log_h;
                any = true;
                continue;
            }
            x0 = @min(x0, at.x);
            y0 = @min(y0, at.y);
            x1 = @max(x1, at.x + sub.log_w);
            y1 = @max(y1, at.y + sub.log_h);
        }
        if (!any) return .{};
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// xdg_popup.reposition (v3): recompute the popup's placement from a new
    /// positioner and emit the reposition sequence — repositioned(token) then
    /// xdg_popup.configure then xdg_surface.configure (spec order).
    fn repositionPopup(self: *Compositor, conn_id: u32, conn: *Conn, popup_id: u32, positioner_id: u32, token: u32) void {
        const surface = surfaceByPopupId(conn, popup_id) orelse return;
        const pos = conn.positioners.get(positioner_id) orelse return;
        const placed = pos.place();
        surface.x = placed.x;
        surface.y = placed.y;
        surface.popup_w = pos.w;
        surface.popup_h = pos.h;
        self.sendEvent(conn_id, popup_id, "xdg_popup", "repositioned", &.{.{ .uint = token }});
        self.sendEvent(conn_id, popup_id, "xdg_popup", "configure", &.{
            .{ .int = surface.x },       .{ .int = surface.y },
            .{ .int = surface.popup_w }, .{ .int = surface.popup_h },
        });
        self.sendEvent(conn_id, surface.xdg_surface_id, "xdg_surface", "configure", &.{
            .{ .uint = nextSerial(conn) },
        });
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
            if (tlv >= 4) {
                // recommend the usable desktop so apps don't open oversized
                self.sendEvent(conn_id, surface.toplevel_id, "xdg_toplevel", "configure_bounds", &.{
                    .{ .int = self.desk_w }, .{ .int = self.desk_h },
                });
            }
            // decoration mode next, so it rides the initial configure cycle
            // (sendToplevelConfigure carries the xdg_surface.configure)
            if (surface.decoration_id != 0) {
                self.sendEvent(conn_id, surface.decoration_id, "zxdg_toplevel_decoration_v1", "configure", &.{
                    .{ .uint = decoration_mode_client_side },
                });
            }
            if (surface.maximized or surface.fullscreen) {
                // the app maximized / fullscreened itself before its first
                // commit: it maps that way
                self.sendCurrentConfigure(conn_id, conn, surface);
            } else {
                var states: [4]u32 = undefined;
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
            // table entry. v1/v2 get nothing: their `format` event promises
            // implicit modifiers, which no relay backend can read.
            if (version == 3) {
                if (self.dmabuf) |d| for (0..d.count()) |i| {
                    const e = d.entry(i);
                    self.sendEvent(conn_id, id, "zwp_linux_dmabuf_v1", "modifier", &.{
                        .{ .uint = e.format }, .{ .uint = @truncate(e.modifier >> 32) }, .{ .uint = @truncate(e.modifier) },
                    });
                };
            }
        } else if (std.mem.eql(u8, interface, "wp_presentation")) {
            self.sendEvent(conn_id, id, "wp_presentation", "clock_id", &.{.{ .uint = presentation_clock_monotonic }});
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            self.sendEvent(conn_id, id, "wl_seat", "capabilities", &.{
                .{ .uint = seat_capability_pointer | seat_capability_keyboard },
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
                self.sendEvent(conn_id, id, "wl_output", "scale", &.{.{ .int = self.output_scale }});
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
        self.sendEvent(conn_id, output_id, "wl_output", "mode", &.{
            .{ .uint = 0x1 | 0x2 }, // current | preferred
            .{ .int = self.desk_w * self.output_scale }, .{ .int = self.desk_h * self.output_scale },
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
                if (objVersion(conn, surface.toplevel_id) >= 4) {
                    self.sendEvent(conn_id, surface.toplevel_id, "xdg_toplevel", "configure_bounds", &.{
                        .{ .int = nw }, .{ .int = nh },
                    });
                }
                self.sendCurrentConfigure(conn_id, conn, surface);
            }
        }
    }

    /// wl_keyboard.keymap needs an fd; emit via the FDMSG path. Followed by
    /// repeat_info for v4+ keyboards.
    fn sendKeymap(self: *Compositor, conn_id: u32, conn: *Conn) void {
        const fdmsg_fn = self.fdmsg_fn orelse {
            self.logf("no fdmsg transport; keyboard will not get a keymap", .{});
            return;
        };
        // format 1 = xkb_v1; size includes the terminating NUL the server appends
        var buf: [64]u8 = undefined;
        const iface = comptime protocol.find("wl_keyboard").?;
        const opcode = comptime iface.eventIndex("keymap").?;
        const msg = wire.encodeMessage(&buf, conn.keyboard_id, opcode, &.{
            .{ .uint = 1 },
            .fd,
            .{ .uint = keymap_text.len + 1 },
        });
        fdmsg_fn(self.ctx, conn_id, 2, msg, keymap_text); // kind 2 = keymap
        if (conn.keyboard_version >= 4) {
            self.sendEvent(conn_id, conn.keyboard_id, "wl_keyboard", "repeat_info", &.{
                .{ .int = 25 }, .{ .int = 400 },
            });
        }
    }

    fn nextSerial(conn: *Conn) u32 {
        conn.serial += 1;
        return conn.serial;
    }

    // ------------------------------------------------------------------
    // clipboard (wl_data_device selection)
    // ------------------------------------------------------------------

    fn setSelection(self: *Compositor, conn_id: u32, source_id: u32) void {
        if (self.selection) |old| {
            // replaced (or cleared) → previous source is done; wl-copy exits on this
            if (!(old.conn == conn_id and old.source == source_id)) {
                self.sendEvent(old.conn, old.source, "wl_data_source", "cancelled", &.{});
            }
        }
        self.selection = if (source_id != 0) .{ .conn = conn_id, .source = source_id } else null;
        self.broadcastSelection();
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

    /// Introduce a fresh wl_data_offer proxying the selection, then the
    /// selection event (null when the clipboard is empty). Spec order:
    /// data_offer intro → offer(mime)* → selection.
    fn deliverSelection(self: *Compositor, conn_id: u32, conn: *Conn) void {
        if (conn.data_device_id == 0) return;
        const sel = self.selection orelse {
            self.sendEvent(conn_id, conn.data_device_id, "wl_data_device", "selection", &.{.{ .object = 0 }});
            return;
        };
        const src_conn = self.conns.get(sel.conn) orelse return;
        const mimes = src_conn.source_mimes.get(sel.source) orelse return;

        const offer_id = conn.next_server_id;
        conn.next_server_id += 1;
        conn.objects.put(self.gpa, offer_id, protocol.find("wl_data_offer").?, 3) catch return;
        conn.offers.put(self.gpa, offer_id, sel) catch return;
        self.sendEvent(conn_id, conn.data_device_id, "wl_data_device", "data_offer", &.{.{ .new_id = offer_id }});
        for (mimes.items) |mime| {
            self.sendEvent(conn_id, offer_id, "wl_data_offer", "offer", &.{.{ .string = mime }});
        }
        self.sendEvent(conn_id, conn.data_device_id, "wl_data_device", "selection", &.{.{ .object = offer_id }});
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
        const msg = wire.encodeMessage(&buf, offer.source, opcode, &.{ .{ .string = mime }, .fd });
        var aux: [4]u8 = undefined;
        std.mem.writeInt(u32, &aux, token, .little);
        fdmsg_fn(self.ctx, offer.conn, 3, msg, &aux); // kind 3 = pipe
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
        if (conn.primary_device_id == 0) return;
        const sel = self.primary_selection orelse {
            self.sendEvent(conn_id, conn.primary_device_id, "zwp_primary_selection_device_v1", "selection", &.{.{ .object = 0 }});
            return;
        };
        const src_conn = self.conns.get(sel.conn) orelse return;
        const mimes = src_conn.primary_source_mimes.get(sel.source) orelse return;

        const offer_id = conn.next_server_id;
        conn.next_server_id += 1;
        conn.objects.put(self.gpa, offer_id, protocol.find("zwp_primary_selection_offer_v1").?, 1) catch return;
        conn.primary_offers.put(self.gpa, offer_id, sel) catch return;
        // tell the server this server id is a PRIMARY offer (SRVOBJ frame) so
        // its fd interception watches primary_offer.receive (opcode 0), not
        // data_offer.receive (opcode 1). Must precede the data_offer event so
        // the server records the type before the app can send receive.
        if (self.srvobj_fn) |f| f(self.ctx, conn_id, offer_id, srvobj_kind_primary_offer);
        self.sendEvent(conn_id, conn.primary_device_id, "zwp_primary_selection_device_v1", "data_offer", &.{.{ .new_id = offer_id }});
        for (mimes.items) |mime| {
            self.sendEvent(conn_id, offer_id, "zwp_primary_selection_offer_v1", "offer", &.{.{ .string = mime }});
        }
        self.sendEvent(conn_id, conn.primary_device_id, "zwp_primary_selection_device_v1", "selection", &.{.{ .object = offer_id }});
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

    /// Embedder: the pointer is over (target_conn, target_surface) at x,y —
    /// 0,0 for "over nothing". Sends enter/leave/motion + fresh offers.
    pub fn dragMotion(self: *Compositor, target_conn_id: u32, target_surface_id: u32, time_ms: u32, x_fixed: i32, y_fixed: i32) void {
        const drag = if (self.drag) |*d| d else return;
        var conn_id = target_conn_id;
        var surface_id = target_surface_id;
        // null-source drags are client-internal: other clients never see them
        if (drag.source_id == 0 and conn_id != drag.source_conn) {
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
            if (conn.data_device_id == 0) return;
            self.sendEvent(conn_id, conn.data_device_id, "wl_data_device", "motion", &.{
                .{ .uint = time_ms }, .{ .fixed = x_fixed }, .{ .fixed = y_fixed },
            });
            return;
        }
        self.dragLeaveFocus(drag);
        if (surface_id == 0) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.data_device_id == 0 or conn.surfaces.get(surface_id) == null) return;
        var offer_id: u32 = 0;
        if (drag.source_id != 0) {
            // fresh offer per enter, same recipe as deliverSelection: intro →
            // offer(mime)* → source_actions; registered in conn.offers so the
            // server's receive interception routes transfers to the source
            const src_conn = self.conns.get(drag.source_conn) orelse return;
            const mimes = src_conn.source_mimes.get(drag.source_id) orelse return;
            offer_id = conn.next_server_id;
            conn.next_server_id += 1;
            conn.objects.put(self.gpa, offer_id, protocol.find("wl_data_offer").?, 3) catch return;
            conn.offers.put(self.gpa, offer_id, .{ .conn = drag.source_conn, .source = drag.source_id }) catch return;
            self.sendEvent(conn_id, conn.data_device_id, "wl_data_device", "data_offer", &.{.{ .new_id = offer_id }});
            for (mimes.items) |mime| {
                self.sendEvent(conn_id, offer_id, "wl_data_offer", "offer", &.{.{ .string = mime }});
            }
            const actions = src_conn.source_actions.get(drag.source_id) orelse 0;
            self.sendEvent(conn_id, offer_id, "wl_data_offer", "source_actions", &.{.{ .uint = actions }});
        }
        drag.focus_conn = conn_id;
        drag.focus_surface = surface_id;
        drag.focus_offer = offer_id;
        drag.accepted = false;
        self.sendEvent(conn_id, conn.data_device_id, "wl_data_device", "enter", &.{
            .{ .uint = nextSerial(conn) }, .{ .object = surface_id },
            .{ .fixed = x_fixed },         .{ .fixed = y_fixed },
            .{ .object = offer_id },
        });
    }

    /// Embedder: button released. A drop lands only on an accepting target;
    /// anything else is a cancel. Transfer + finish route through Conn.offers
    /// afterwards — the session itself ends here either way.
    pub fn dragDrop(self: *Compositor) void {
        const drag = self.drag orelse return;
        if (drag.focus_surface == 0 or (drag.source_id != 0 and !drag.accepted)) {
            self.dragCancel();
            return;
        }
        if (self.conns.get(drag.focus_conn)) |conn| {
            if (conn.data_device_id != 0) {
                self.sendEvent(drag.focus_conn, conn.data_device_id, "wl_data_device", "drop", &.{});
            }
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
        defer {
            drag.focus_conn = 0;
            drag.focus_surface = 0;
            drag.focus_offer = 0;
            drag.accepted = false;
        }
        if (drag.focus_surface == 0) return;
        const conn = self.conns.get(drag.focus_conn) orelse return;
        if (conn.data_device_id == 0) return;
        self.sendEvent(drag.focus_conn, conn.data_device_id, "wl_data_device", "leave", &.{});
    }

    /// Tear down the session: icon role reverts (the embedder re-hides it)
    /// and the embedder learns the session ended (kind 5) — it may have been
    /// compositor-initiated.
    fn endDrag(self: *Compositor) void {
        const drag = self.drag orelse return;
        self.drag = null;
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
        if (conn_id != drag.focus_conn or offer_id != drag.focus_offer or drag.source_id == 0) return;
        drag.accepted = mime != null;
        if (self.conns.get(drag.source_conn)) |_| {
            self.sendEvent(drag.source_conn, drag.source_id, "wl_data_source", "target", &.{.{ .string = mime }});
        }
    }

    /// Target's wl_data_offer.set_actions: negotiate and announce the action
    /// to both ends (v3 flow; GTK will not complete a drop without it).
    fn dragOfferActions(self: *Compositor, conn_id: u32, offer_id: u32, actions: u32, preferred: u32) void {
        const drag = if (self.drag) |*d| d else return;
        if (conn_id != drag.focus_conn or offer_id != drag.focus_offer or drag.source_id == 0) return;
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
    fn dragFinish(self: *Compositor, conn: *Conn, offer_id: u32) void {
        const offer = conn.offers.get(offer_id) orelse return;
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
        if (conn.pointer_id == 0) return;
        // pointer may enter toplevels and subsurfaces (CSD hover), never
        // cursors or dnd icons
        switch (self.surfaceRole(conn_id, surface_id)) {
            .cursor, .dnd_icon => return,
            else => {},
        }
        // a minimized window is not on screen (an embedder lagging behind)
        if (underMinimized(conn, surface_id)) return;
        conn.pointer_focus = surface_id;
        const serial = nextSerial(conn);
        conn.pointer_enter_serial = serial; // set_shape/set_cursor must echo this serial
        conn.cursor_surface = 0; // a new enter takes a fresh set_cursor
        self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "enter", &.{
            .{ .uint = serial }, .{ .object = surface_id },
            .{ .fixed = x_fixed }, .{ .fixed = y_fixed },
        });
        self.pointerFrame(conn_id, conn);
        conn.pointer_x = x_fixed;
        conn.pointer_y = y_fixed;
        // a constraint of the surface may apply now (after the enter, as
        // the spec has it); one of a surface it moved off ends
        self.updateConstraints(conn_id, conn);
    }

    pub fn pointerLeave(self: *Compositor, conn_id: u32) void {
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.pointer_id == 0 or conn.pointer_focus == 0) return;
        const focus = conn.pointer_focus;
        conn.pointer_focus = 0;
        // its constraint ends first (unlocked/unconfined while the client
        // still sees its surface under the pointer), then the leave
        self.updateConstraints(conn_id, conn);
        self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "leave", &.{
            .{ .uint = nextSerial(conn) }, .{ .object = focus },
        });
        self.pointerFrame(conn_id, conn);
        // the shape or cursor surface the client set applied only while its
        // surface held the pointer — reset to the default pointer now
        conn.cursor_surface = 0;
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
        if (conn.pointer_id == 0 or conn.pointer_focus == 0) return;
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
            self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "motion", &.{
                .{ .uint = time_ms }, .{ .fixed = x }, .{ .fixed = y },
            });
        }
        if (moved) {
            const r = rel.?;
            for (conn.relative_pointers.items) |id| {
                self.sendEvent(conn_id, id, "zwp_relative_pointer_v1", "relative_motion", &.{
                    .{ .uint = @truncate(r.utime >> 32) }, .{ .uint = @truncate(r.utime) },
                    .{ .fixed = r.dx },                    .{ .fixed = r.dy },
                    .{ .fixed = r.dx_unaccel },            .{ .fixed = r.dy_unaccel },
                });
            }
        }
        self.pointerFrame(conn_id, conn);
        // into a constraint's region (it may start), out of a wanted lock's
        if (!locked) self.updateConstraints(conn_id, conn);
    }

    pub fn pointerButton(self: *Compositor, conn_id: u32, time_ms: u32, button: u32, pressed: bool) void {
        if (self.drag != null) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.pointer_id == 0 or conn.pointer_focus == 0) return;
        self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "button", &.{
            .{ .uint = nextSerial(conn) }, .{ .uint = time_ms },
            .{ .uint = button },           .{ .uint = if (pressed) 1 else 0 },
        });
        self.pointerFrame(conn_id, conn);
    }

    /// A wheel event. `value_fixed` is the continuous scroll vector (surface
    /// coords); `value120` is the high-resolution discrete component (120 per
    /// detent, browser fractional deltas → smooth scroll). One frame per axis:
    /// axis_source(wheel) [v5+] · axis_relative_direction(identical) [v9+] ·
    /// axis_value120 [v8+] or axis_discrete [v5-7] · axis · frame [v5+]. The
    /// high-res / discrete events are each coupled BEFORE their axis event.
    pub fn pointerAxis(self: *Compositor, conn_id: u32, time_ms: u32, axis: u32, value_fixed: i32, value120: i32) void {
        if (self.drag != null) return;
        const conn = self.conns.get(conn_id) orelse return;
        if (conn.pointer_id == 0 or conn.pointer_focus == 0) return;
        const v = conn.pointer_version;
        if (v >= 5) {
            self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "axis_source", &.{.{ .uint = axis_source_wheel }});
        }
        if (v >= 9) {
            self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "axis_relative_direction", &.{
                .{ .uint = axis }, .{ .uint = axis_direction_identical },
            });
        }
        if (v >= 8) {
            // spec: value120 must not be zero — skip the high-res event on a
            // pure-continuous scroll rather than emit a zero
            if (value120 != 0) {
                self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "axis_value120", &.{
                    .{ .uint = axis }, .{ .int = value120 },
                });
            }
        } else if (v >= 5) {
            // deprecated axis_discrete carries whole detents only; fractional
            // (trackpad-style) deltas stay purely continuous for old clients
            const steps = @divTrunc(value120, value120_per_notch);
            if (steps != 0) {
                self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "axis_discrete", &.{
                    .{ .uint = axis }, .{ .int = steps },
                });
            }
        }
        self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "axis", &.{
            .{ .uint = time_ms }, .{ .uint = axis }, .{ .fixed = value_fixed },
        });
        self.pointerFrame(conn_id, conn);
    }

    fn pointerFrame(self: *Compositor, conn_id: u32, conn: *Conn) void {
        if (conn.pointer_version >= 5) {
            self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "frame", &.{});
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
            self.sendEvent(conn_id, conn.pointer_id, "wl_pointer", "motion", &.{
                .{ .uint = conn.pointer_time }, .{ .fixed = p[0] }, .{ .fixed = p[1] },
            });
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
            .{ .uint = @intCast(@max(1, self.scale_120)) },
        });
    }

    /// Embedder: the browser devicePixelRatio changed (matchMedia resolution
    /// listener). `output_scale` is the integer scale (round(dpr), clamped),
    /// `scale_120` the fractional preferred scale (round(dpr × 120)). Resend
    /// wp_fractional_scale preferred_scale to every fractional object,
    /// wl_compositor v6 preferred_buffer_scale/transform to every v6 surface,
    /// and (when the integer scale changed) the wl_output scale + mode. This
    /// is what removes the reload-on-dpr-change limit.
    pub fn setScale(self: *Compositor, output_scale: i32, scale_120: i32) void {
        const os = std.math.clamp(output_scale, 1, 4);
        const s120 = @max(1, scale_120);
        if (os == self.output_scale and s120 == self.scale_120) return;
        const scale_changed = os != self.output_scale;
        self.output_scale = os;
        self.scale_120 = s120;
        var it = self.conns.iterator();
        while (it.next()) |kv| {
            const conn_id = kv.key_ptr.*;
            const conn = kv.value_ptr.*;
            var fit = conn.frac_scales.keyIterator();
            while (fit.next()) |frac_id| self.sendPreferredScale(conn_id, frac_id.*);
            self.sendPreferredBufferScaleAll(conn_id, conn);
            if (scale_changed) {
                for (conn.output_ids.items) |oid| {
                    self.sendEvent(conn_id, oid, "wl_output", "scale", &.{.{ .int = self.output_scale }});
                    self.sendOutputMode(conn_id, oid);
                    self.sendEvent(conn_id, oid, "wl_output", "done", &.{});
                }
            }
        }
    }

    /// wl_compositor v6: preferred_buffer_scale (integer fallback for
    /// non-fractional clients) + preferred_buffer_transform (normal) for one
    /// surface. Sent at creation and on dpr change.
    fn sendPreferredBuffer(self: *Compositor, conn_id: u32, surface_id: u32) void {
        self.sendEvent(conn_id, surface_id, "wl_surface", "preferred_buffer_scale", &.{.{ .int = self.output_scale }});
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
        if (conn.keyboard_id == 0 or conn.keyboard_focus == surface_id) return;
        // keyboard focus only ever lands on toplevels — apps crash on focus
        // events for surfaces without window state (foot + cursor surface)
        if (self.surfaceRole(conn_id, surface_id) != .toplevel) return;
        if (underMinimized(conn, surface_id)) return; // hidden: restore it first
        const before = conn.keyboard_focus;
        conn.keyboard_focus = surface_id;
        if (before != 0) self.sendActivation(conn_id, conn, before);
        self.sendActivation(conn_id, conn, surface_id);
        self.sendEvent(conn_id, conn.keyboard_id, "wl_keyboard", "enter", &.{
            .{ .uint = nextSerial(conn) }, .{ .object = surface_id }, .{ .array = &.{} },
        });
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
        if (conn.keyboard_id == 0 or conn.keyboard_focus == 0) return;
        self.sendEvent(conn_id, conn.keyboard_id, "wl_keyboard", "leave", &.{
            .{ .uint = nextSerial(conn) }, .{ .object = conn.keyboard_focus },
        });
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
        if (conn.keyboard_id == 0) return;
        self.sendEvent(conn_id, conn.keyboard_id, "wl_keyboard", "key", &.{
            .{ .uint = nextSerial(conn) }, .{ .uint = time_ms },
            .{ .uint = evdev_key },        .{ .uint = if (pressed) 1 else 0 },
        });
        // modifier bookkeeping
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
        } else if (evdev_key == key_capslock and pressed) {
            conn.mods_locked ^= mod_lock;
            changed = true;
        }
        if (changed) self.sendModifiers(conn_id, conn);
    }

    fn sendModifiers(self: *Compositor, conn_id: u32, conn: *Conn) void {
        self.sendEvent(conn_id, conn.keyboard_id, "wl_keyboard", "modifiers", &.{
            .{ .uint = nextSerial(conn) },
            .{ .uint = conn.mods_depressed },
            .{ .uint = 0 },
            .{ .uint = conn.mods_locked },
            .{ .uint = 0 },
        });
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
        const msg = wire.encodeMessage(&buf, object_id, opcode, args);
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
        @memcpy(self.fdmsg_bytes[0..wire_bytes.len], wire_bytes);
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
        @memcpy(entry.bytes[0..bytes.len], bytes);
        self.events.append(self.gpa, entry) catch unreachable;
    }

    fn log(ctx: ?*anyopaque, text: []const u8) void {
        _ = ctx;
        _ = text;
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

test "decoration: client_side rides the initial configure; set_mode re-answered; destroy unhooks" {
    var sink: TestSink = undefined;
    var comp = testSetup(&sink);
    defer comp.deinit();
    defer sink.events.deinit(sink.gpa);

    try comp.connOpen(1);
    var buf: [128]u8 = undefined;
    try comp.onWire(1, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }})); // get_registry
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 1, .id = 4 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 8 }, .{ .new_id_dynamic = .{ .interface = "zxdg_decoration_manager_v1", .version = 1, .id = 5 } } }));
    // surface 6 + xdg_surface 7 + toplevel 8 + decoration 9, decoration BEFORE first commit
    try comp.onWire(1, wire.encodeMessage(&buf, 3, 0, &.{.{ .new_id = 6 }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 4, 2, &.{ .{ .new_id = 7 }, .{ .object = 6 } })); // get_xdg_surface
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 1, &.{.{ .new_id = 8 }})); // get_toplevel
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 9 }, .{ .object = 8 } })); // get_toplevel_decoration
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 1, &.{.{ .uint = 2 }})); // set_mode(server_side), pre-map
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len); // nothing before map

    try comp.onWire(1, wire.encodeMessage(&buf, 6, 6, &.{})); // first commit
    // decoration.configure(client_side) → xdg_toplevel.configure → xdg_surface.configure
    try std.testing.expectEqual(@as(usize, 3), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 9), sink.events.items[0].object_id);
    var vals: [wire.max_args]wire.Value = undefined;
    const ev = sink.events.items[0];
    const args = try wire.decodeArgs(ev.bytes[wire.header_size..ev.len], &.{.uint}, &vals);
    try std.testing.expectEqual(decoration_mode_client_side, args[0].uint);
    try std.testing.expectEqual(@as(u32, 8), sink.events.items[1].object_id);
    try std.testing.expectEqual(@as(u32, 7), sink.events.items[2].object_id);

    // post-map set_mode(server_side) → re-answered client_side + its own configure cycle
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 1, &.{.{ .uint = 2 }}));
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 9), sink.events.items[0].object_id);
    const ev2 = sink.events.items[0];
    const args2 = try wire.decodeArgs(ev2.bytes[wire.header_size..ev2.len], &.{.uint}, &vals);
    try std.testing.expectEqual(decoration_mode_client_side, args2[0].uint);
    try std.testing.expectEqual(@as(u32, 7), sink.events.items[1].object_id);

    // destroy the decoration object → just delete_id; a later set_mode on a
    // fresh decoration for the same toplevel still works
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 9, 0, &.{})); // destroy
    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqual(@as(u32, 1), sink.events.items[0].object_id);
    try std.testing.expectEqual(@as(u16, 1), sink.events.items[0].opcode); // delete_id
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .new_id = 10 }, .{ .object = 8 } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 10, 2, &.{})); // unset_mode
    try std.testing.expectEqual(@as(usize, 4), sink.events.items.len); // configure cycle × 2 (get + unset)
    try std.testing.expectEqual(@as(u32, 10), sink.events.items[0].object_id);
}

/// Map a v6 toplevel: registry 2, wl_compositor 3, xdg_wm_base(v6) 4,
/// surface 6, xdg_surface 7, toplevel 8. Leaves the toplevel UNcommitted.
fn wmBaseToplevel(comp: *Compositor, conn_id: u32) !void {
    var buf: [128]u8 = undefined;
    try comp.connOpen(conn_id);
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }}));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 1 }, .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 3 } } }));
    try comp.onWire(conn_id, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 6 }, .{ .new_id_dynamic = .{ .interface = "xdg_wm_base", .version = 6, .id = 4 } } }));
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
    const calls = sink.inter_calls;
    try T.send(&comp, 8, comptime T.tl.requestIndex("move").?, &.{ .{ .object = 0 }, .{ .uint = 1 } });
    try T.send(&comp, 8, comptime T.tl.requestIndex("resize").?, &.{ .{ .object = 0 }, .{ .uint = 1 }, .{ .uint = 10 } });
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
    try T.send(&comp, 8, comptime T.tl.requestIndex("move").?, &.{ .{ .object = 0 }, .{ .uint = 1 } });
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

    // move → embedder drag callback (kind 0), no protocol events
    sink.events.clearRetainingCapacity();
    try comp.onWire(1, wire.encodeMessage(&buf, 11, move_op, &.{ .{ .object = 5 }, .{ .uint = 1 } }));
    try std.testing.expectEqual(@as(u32, 0), sink.inter_kind);
    try std.testing.expectEqual(@as(u32, 9), sink.inter_surface);
    try std.testing.expectEqual(@as(usize, 0), sink.events.items.len);

    // resize → callback (kind 1) with the edges bitmask (bottom-right = 10)
    try comp.onWire(1, wire.encodeMessage(&buf, 11, resize_op, &.{ .{ .object = 5 }, .{ .uint = 2 }, .{ .uint = 10 } }));
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
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 4 }, .{ .uint = 0 } })); // set_selection

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
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 12 }, .{ .uint = 0 } }));
    const cancelled_op = comptime protocol.find("wl_data_source").?.eventIndex("cancelled").?;
    var saw_cancelled = false;
    for (sink.events.items) |ev| {
        if (ev.conn_id == 1 and ev.object_id == 4 and ev.opcode == cancelled_op) saw_cancelled = true;
    }
    try std.testing.expect(saw_cancelled);
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
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{ .{ .object = 4 }, .{ .uint = 0 } })); // device.set_selection

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
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 0, &.{ .{ .object = 12 }, .{ .uint = 0 } }));
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
    try comp.onWire(1, wire.encodeMessage(&buf, 5, 1, &.{ .{ .object = 4 }, .{ .uint = 0 } })); // clip set_selection
    try comp.onWire(1, wire.encodeMessage(&buf, 2, 0, &.{ .{ .uint = 13 }, .{ .new_id_dynamic = .{ .interface = "zwp_primary_selection_device_manager_v1", .version = 1, .id = 6 } } }));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 0, &.{.{ .new_id = 7 }})); // primary create_source
    try comp.onWire(1, wire.encodeMessage(&buf, 7, 0, &.{.{ .string = "text/plain" }}));
    try comp.onWire(1, wire.encodeMessage(&buf, 6, 1, &.{ .{ .new_id = 8 }, .{ .object = 99 } })); // primary get_device
    try comp.onWire(1, wire.encodeMessage(&buf, 8, 0, &.{ .{ .object = 7 }, .{ .uint = 0 } })); // primary set_selection

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
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = 99 } }));
    try std.testing.expectEqual(@as(u32, 4), sink.inter_kind); // dnd session started
    try std.testing.expectEqual(@as(u32, 7), sink.inter_surface);

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
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 13 }, .{ .uint = 1 } }));
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
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 12 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = 1 } }));
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
    try comp.onWire(1, wire.encodeMessage(&buf, 11, 0, &.{ .{ .object = 14 }, .{ .object = 7 }, .{ .object = 0 }, .{ .uint = 1 } }));
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
