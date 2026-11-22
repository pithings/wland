// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! The session profile (`wlandr --profile session`, STREAM.md "Profiles"):
//! the compositor (core) runs here, natively, for the relay's whole life,
//! and the engine on the other end of a link is a *viewer* — it is sent the
//! scene (EVENT, SURFACE, the pixel frames) and sends input (CALL). Apps
//! survive the viewer going away (a page reload); the next viewer is sent
//! the scene as it is now.
//!
//! The host is core/src/wasm.zig's native twin: the same compositor
//! callbacks, the same frame routing. Toward the relay it is an in-process
//! `Link` (`link`): relay.serveLink runs on it once, for the process's life,
//! so the relay is unchanged — app conns never see a link drop. The relay's
//! messages (`send`, any relay thread) are fed to the core the way
//! wland_on_frame feeds them; the core's output to the relay (WIRE, FDMSG,
//! SRVOBJ, DMABUF_CREATED, PRESENTED) is queued for `recv` (the serveLink
//! thread), which hands it to the relay exactly as a remote engine's would.
//! Frame callbacks are the core's (`.engine`): the host's clock (a timer
//! thread) ticks the compositor.
//!
//! Toward the viewer, per step (one relay message, one viewer message, one
//! tick) the frames go out as one message, in the order the compositor made
//! them: core callbacks become EVENTs, pixel frames are forwarded as they
//! came (after the host noted their dims, `noteBufferSize`, and kept them in
//! a per-surface shadow image), CONN_OPEN / CONN_CLOSE pass through, and a
//! SURFACE goes out for every surface whose getters answer differently from
//! what the viewer was last sent — inside a callback for the surface it
//! names (and its root), before every pixel frame and at the end of every
//! step for all of them.
//!
//! One viewer at a time; a new one takes over (the old one is kicked: a WS
//! viewer gets close code 4000). Nothing goes to a viewer before its CALL
//! init but FEATURE session; init answers with the scene replay ending in
//! EVENT synced. A viewer that goes: the core lets go of the seat
//! (`Compositor.embedderGone`) and the apps are suspended; they stay
//! connected.
//!
//! Defaults before any viewer: the core's own (scale 1, desktop
//! core.compositor.output_width × output_height = 1280×720, not suspended).
//! Clock: a tick every 16 ms while a viewer is attached (init'ed), every
//! 256 ms while none is (apps keep running, slowly — idle_tick_every).
//!
//! Locking. `mutex` (the host mutex) guards the compositor and everything
//! the steps touch; every entry point (relay send, viewer message, tick,
//! attach/detach) takes it for the whole step. Lock order:
//!   host `mutex` → `vmutex` (the viewer slot) and host `mutex` → `out_mutex`
//!   (the relay-bound queue); never the reverse.
//!   The relay never holds relay.mutex while calling into a link, and the
//!   host never takes relay.mutex, so the two are unordered and can't
//!   deadlock. A viewer link's write lock is taken inside its send, under
//!   the host mutex; a viewer link never calls into the host.
//!   A takeover waits for the old viewer holding only `vmutex`, and kicks it
//!   with `vmutex` alone (kick never blocks), so a viewer blocked in a send
//!   under the host mutex is woken, never waited for with the mutex held.
//! Known v1 trade-off: a slow viewer socket stalls the host (and so every
//! app's relay thread) while a step's send blocks.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const stream = core.stream;
const Compositor = core.compositor.Compositor;
const Region = core.compositor.Region;
const Link = @import("link.zig").Link;
const relay_mod = @import("relay.zig");

/// Tick period while a viewer is attached (≈ a 60 Hz display).
pub const tick_ms = 16;
/// With no viewer the clock ticks every this many periods (≈ 4 Hz): frame
/// callbacks and presentation feedback keep apps alive without a display.
pub const idle_tick_every = 16;

const key = struct {
    fn of(conn_id: u32, surface_id: u32) u64 {
        return @as(u64, conn_id) << 32 | surface_id;
    }
    fn conn(k: u64) u32 {
        return @intCast(k >> 32);
    }
};

/// What a surface's last pixel frames left: tight RGBA rows, w*4 each.
const Shadow = struct { w: u32, h: u32, px: []u8 };

pub const Session = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// FEATURE session's bytes: random per relay run.
    session_id: u64,

    // ---- under `mutex` ----------------------------------------------------
    mutex: Io.Mutex = .init,
    comp: Compositor,
    /// the current step's frames for the relay / the viewer
    to_relay: stream.Batch = .{},
    to_viewer: stream.Batch = .{},
    /// The viewer link (written under `mutex` AND `vmutex`, read under
    /// either). Alive while set: its thread clears it (under `mutex`)
    /// before it returns.
    viewer: ?*Link = null,
    /// The viewer sent init (its replay went out): it is sent everything.
    synced: bool = false,
    /// A send to the viewer failed: nothing more goes to it (it was kicked;
    /// its thread detaches it).
    viewer_broken: bool = false,
    /// What the viewer was last sent per surface (SURFACE bytes).
    records: std.AutoHashMapUnmanaged(u64, [stream.SurfaceFrame.len]u8) = .empty,
    shadows: std.AutoHashMapUnmanaged(u64, Shadow) = .empty,
    /// keyboard_locks_state last sent (null: not since init)
    locks_sent: ?u32 = null,
    /// read_selection ids of this viewer awaiting their answer
    pending_reads: std.ArrayList(u32) = .empty,
    /// selection EVENTs sent so far (set_selection's outcome check)
    selection_events: u32 = 0,
    args: std.ArrayList(u8) = .empty,
    raw: std.ArrayList(u8) = .empty,
    lz: std.ArrayList(u8) = .empty,

    // ---- the relay-bound queue (`out_mutex`) -------------------------------
    out_mutex: Io.Mutex = .init,
    out_cond: Io.Condition = .init,
    out: std.ArrayList(u8) = .empty,
    closed: bool = false,

    // ---- the viewer slot (`vmutex`) ----------------------------------------
    vmutex: Io.Mutex = .init,
    /// Broadcast when the viewer detached (a takeover waits).
    viewer_detached: Io.Condition = .init,

    /// The link relay.serveLink runs on (see the file comment).
    link: Link,
    stopping: std.atomic.Value(bool) = .init(false),
    clock: ?std.Thread = null,
    relay_thread: ?std.Thread = null,

    /// Heap-allocated: the compositor and threads keep its address.
    pub fn create(gpa: std.mem.Allocator, io: Io) !*Session {
        const self = try gpa.create(Session);
        var id: u64 = 0;
        io.random(std.mem.asBytes(&id));
        self.* = .{
            .io = io,
            .gpa = gpa,
            .session_id = id,
            .comp = .init(gpa, self, coreSend, coreLog),
            .link = .{ .ctx = self, .vtable = &link_vtable, .frame_callbacks = .engine },
        };
        const c = &self.comp;
        c.fdmsg_fn = coreFdMsg;
        c.srvobj_fn = coreSrvObj;
        c.dmabuf_created_fn = coreDmabufCreated;
        c.presented_fn = corePresented;
        c.title_fn = evTitle;
        c.app_id_fn = evAppId;
        c.size_limits_fn = evSizeLimits;
        c.decoration_fn = evDecoration;
        c.configure_fn = evConfigure;
        c.acked_fn = evAcked;
        c.surface_fn = evSurface;
        c.interactive_fn = evInteractive;
        c.cursor_shape_fn = evCursorShape;
        c.cursor_surface_fn = evCursorSurface;
        c.text_input_fn = evTextInput;
        c.input_region_fn = evInputRegion;
        c.pointer_lock_fn = evPointerLock;
        c.selection_fn = evSelection;
        return self;
    }

    /// Serve the relay on `link` (its own thread, relay.serveLink) and start
    /// the clock. Call before apps can connect.
    pub fn start(self: *Session, relay: *relay_mod.Relay) !void {
        std.debug.assert(relay.gpa.ptr == self.gpa.ptr); // `recv` hands our bytes to its list
        self.relay_thread = try std.Thread.spawn(.{}, relay_mod.serveLink, .{ relay, &self.link });
        self.clock = try std.Thread.spawn(.{}, clockLoop, .{self});
    }

    /// Tests: stop the clock, take the relay link down (every app conn is
    /// dropped) and free everything. No viewer may be attached.
    pub fn destroy(self: *Session) void {
        self.stopping.store(true, .release);
        if (self.clock) |t| t.join();
        self.link.kick();
        if (self.relay_thread) |t| t.join();
        std.debug.assert(self.viewer == null);
        const gpa = self.gpa;
        self.comp.deinit();
        self.to_relay.deinit(gpa);
        self.to_viewer.deinit(gpa);
        self.records.deinit(gpa);
        var it = self.shadows.valueIterator();
        while (it.next()) |s| gpa.free(s.px);
        self.shadows.deinit(gpa);
        self.pending_reads.deinit(gpa);
        self.args.deinit(gpa);
        self.raw.deinit(gpa);
        self.lz.deinit(gpa);
        self.out.deinit(gpa);
        gpa.destroy(self);
    }

    // ------------------------------------------------------------------
    // the relay side: an in-process Link
    // ------------------------------------------------------------------

    const link_vtable: Link.VTable = .{ .send = linkSend, .recv = linkRecv, .kick = linkKick };

    /// A relay message (any relay thread): fed to the core in order, one step.
    fn linkSend(ctx: *anyopaque, msg: []const u8) Link.SendError!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.isClosed()) return error.LinkGone;
        var rest = msg;
        while (rest.len > 0) {
            const p = stream.parseNext(rest) catch |err| {
                std.log.err("session: bad relay frame: {t}", .{err});
                break;
            };
            self.relayFrame(p.frame, rest[0..p.consumed]);
            rest = rest[p.consumed..];
        }
        self.endStep();
    }

    /// The serveLink thread: the core's next output for the relay.
    fn linkRecv(ctx: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Link.RecvError!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        while (self.out.items.len == 0 and !self.closed) self.out_cond.waitUncancelable(self.io, &self.out_mutex);
        if (self.out.items.len == 0) return error.EndOfStream;
        out.clearRetainingCapacity();
        try out.appendSlice(gpa, self.out.items);
        self.out.clearRetainingCapacity();
    }

    /// Only ever at shutdown (tests): the relay's link goes down.
    fn linkKick(ctx: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        self.out_mutex.lockUncancelable(self.io);
        self.closed = true;
        self.out_mutex.unlock(self.io);
        self.out_cond.broadcast(self.io);
    }

    fn isClosed(self: *Session) bool {
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        return self.closed;
    }

    /// One frame from the relay, `bytes` the whole frame. Host mutex held.
    fn relayFrame(self: *Session, frame: stream.Frame, bytes: []const u8) void {
        const c = &self.comp;
        switch (frame) {
            .conn_open => |conn_id| {
                c.connOpen(conn_id) catch |err| std.log.err("session: conn_open {d}: {t}", .{ conn_id, err });
                self.forward(bytes);
            },
            .conn_close => |conn_id| {
                c.connClose(conn_id);
                self.forward(bytes);
                self.dropConn(conn_id);
            },
            .wire => |w| c.onWire(w.conn_id, w.bytes) catch |err| std.log.err("session: onWire: {t}", .{err}),
            .fdmsg => |f| switch (f.kind) {
                @intFromEnum(stream.FdMsgKind.pipe_read) => self.pipeReadAnswer(f.aux),
                @intFromEnum(stream.FdMsgKind.pipe) => if (f.aux.len == 4) {
                    c.onPipeReceive(f.conn_id, f.wire_bytes, std.mem.readInt(u32, f.aux[0..4], .little));
                } else std.log.err("session: pipe fdmsg with bad aux len {d}", .{f.aux.len}),
                else => c.onWire(f.conn_id, f.wire_bytes) catch |err| std.log.err("session: fdmsg: {t}", .{err}),
            },
            .feature => |f| c.applyFeature(f.feature, f.bytes),
            .buffer => |b| self.pixelFrame(b.conn_id, b.surface_id, b.width, b.height, b.n_rects, b.rect_bytes, b.pixels, bytes),
            .buffer_lz => |b| {
                self.raw.resize(self.gpa, b.raw_len) catch {
                    std.log.err("session: out of memory decoding a {d} B BUFFER_LZ", .{b.raw_len});
                    return;
                };
                const n = core.lz4.decompress(b.comp, self.raw.items) orelse 0;
                if (n != b.raw_len) {
                    std.log.err("session: bad BUFFER_LZ (c{d} s{d})", .{ b.conn_id, b.surface_id });
                    return;
                }
                self.pixelFrame(b.conn_id, b.surface_id, b.width, b.height, b.n_rects, b.rect_bytes, self.raw.items, bytes);
            },
            // the copy backend only (main.zig refuses the rest with
            // --profile session): handle frames never come
            else => std.log.err("session: unexpected {t} frame from the relay", .{std.meta.activeTag(frame)}),
        }
    }

    /// BUFFER / BUFFER_LZ (`bytes`, forwarded as they came; `pixels` the raw
    /// RGBA): note the dims as the page did (wland_note_buffer_size), keep
    /// the pixels, then — after the SURFACEs the viewer reads it with — pass
    /// the frame on.
    fn pixelFrame(self: *Session, conn_id: u32, surface_id: u32, w: u32, h: u32, n_rects: u32, rect_bytes: []const u8, pixels: []const u8, bytes: []const u8) void {
        self.comp.noteBufferSize(conn_id, surface_id, w, h);
        self.keepPixels(conn_id, surface_id, w, h, n_rects, rect_bytes, pixels);
        self.diffAll();
        self.forward(bytes);
    }

    fn keepPixels(self: *Session, conn_id: u32, surface_id: u32, w: u32, h: u32, n_rects: u32, rect_bytes: []const u8, pixels: []const u8) void {
        const gpa = self.gpa;
        const len = @as(usize, w) * h * 4;
        const gop = self.shadows.getOrPut(gpa, key.of(conn_id, surface_id)) catch return;
        if (!gop.found_existing or gop.value_ptr.w != w or gop.value_ptr.h != h) {
            // a new size: what the viewer shows is only what this frame names
            if (gop.found_existing) gpa.free(gop.value_ptr.px);
            const px = gpa.alloc(u8, len) catch {
                _ = self.shadows.remove(key.of(conn_id, surface_id));
                return;
            };
            @memset(px, 0);
            gop.value_ptr.* = .{ .w = w, .h = h, .px = px };
        }
        const px = gop.value_ptr.px;
        var off: usize = 0;
        var i: u32 = 0;
        while (i < n_rects) : (i += 1) {
            const r = rect_bytes[@as(usize, i) * 16 ..][0..16];
            const x = std.mem.readInt(i32, r[0..4], .little);
            const y = std.mem.readInt(i32, r[4..8], .little);
            const rw = std.mem.readInt(i32, r[8..12], .little);
            const rh = std.mem.readInt(i32, r[12..16], .little);
            const row_len = @as(usize, @intCast(rw)) * 4; // parseNext: rw, rh > 0
            defer off += row_len * @as(usize, @intCast(rh));
            if (x < 0 or y < 0 or @as(u64, @intCast(x)) + @as(u64, @intCast(rw)) > w or @as(u64, @intCast(y)) + @as(u64, @intCast(rh)) > h) continue;
            for (0..@intCast(rh)) |row| {
                const dst = ((@as(usize, @intCast(y)) + row) * w + @as(usize, @intCast(x))) * 4;
                @memcpy(px[dst..][0..row_len], pixels[off + row * row_len ..][0..row_len]);
            }
        }
    }

    fn dropShadow(self: *Session, k: u64) void {
        if (self.shadows.fetchRemove(k)) |kv| self.gpa.free(kv.value.px);
        _ = self.records.remove(k);
    }

    /// A conn closed: its records and shadows end (CONN_CLOSE ends them on
    /// the viewer too).
    fn dropConn(self: *Session, conn_id: u32) void {
        scan: while (true) {
            var it = self.shadows.keyIterator();
            while (it.next()) |k| if (key.conn(k.*) == conn_id) {
                self.dropShadow(k.*);
                continue :scan;
            };
            break;
        }
        scan: while (true) {
            var it = self.records.keyIterator();
            while (it.next()) |k| if (key.conn(k.*) == conn_id) {
                _ = self.records.remove(k.*);
                continue :scan;
            };
            break;
        }
    }

    /// FDMSG pipe_read: a read_selection's answer (aux = read id ++ status ++
    /// bytes), for the viewer that asked — a gone viewer's are dropped.
    fn pipeReadAnswer(self: *Session, aux: []const u8) void {
        if (aux.len < 8) return std.log.err("session: pipe_read fdmsg with bad aux len {d}", .{aux.len});
        const read_id = std.mem.readInt(u32, aux[0..4], .little);
        const i = std.mem.indexOfScalar(u32, self.pending_reads.items, read_id) orelse return;
        _ = self.pending_reads.swapRemove(i);
        self.selectionData(read_id, std.mem.readInt(u32, aux[4..8], .little), aux[8..]);
    }

    // ------------------------------------------------------------------
    // steps
    // ------------------------------------------------------------------

    /// The viewer is sent everything (attached, init'ed, not broken).
    fn live(self: *const Session) bool {
        return self.viewer != null and self.synced and !self.viewer_broken;
    }

    /// The end of every step: SURFACEs that changed, the lock state, then
    /// the step's frames go out — to the viewer as one message, to the
    /// relay's queue.
    fn endStep(self: *Session) void {
        self.diffAll();
        if (self.live()) {
            const l = self.comp.lockState();
            const locks = @as(u32, @intFromBool(l.caps_lock)) | @as(u32, @intFromBool(l.num_lock)) << 1;
            if (self.locks_sent != locks) self.sendLocks(locks);
        }
        const v = self.to_viewer.finish();
        if (v.len > 0) {
            if (self.live()) {
                relay_mod.sendBatch(self.viewer.?, v, stream.max_record_len) catch {
                    // gone: kicked so its recv returns, its thread detaches it
                    self.viewer_broken = true;
                    self.viewer.?.kick();
                };
            }
            self.to_viewer.clear();
        }
        const r = self.to_relay.finish();
        if (r.len > 0) {
            self.out_mutex.lockUncancelable(self.io);
            const queued = self.out.appendSlice(self.gpa, r);
            self.out_mutex.unlock(self.io);
            queued catch std.log.err("session: out of memory, {d} B for the relay lost", .{r.len});
            self.out_cond.signal(self.io);
            self.to_relay.clear();
        }
    }

    /// A whole frame for the viewer, as is.
    fn forward(self: *Session, bytes: []const u8) void {
        if (!self.live()) return;
        const out = self.to_viewer.frame(self.gpa, bytes.len) catch return;
        @memcpy(out[0..bytes.len], bytes);
    }

    fn record(self: *Session, conn_id: u32, surface_id: u32) stream.SurfaceFrame {
        const c = &self.comp;
        const view = c.surfaceViewSize(conn_id, surface_id);
        const abs = c.surfaceAbs(conn_id, surface_id);
        const g = c.windowGeometry(conn_id, surface_id);
        return .{
            .conn_id = conn_id,
            .surface_id = surface_id,
            .role = @intFromEnum(c.surfaceRole(conn_id, surface_id)),
            .scale = c.surfaceScale(conn_id, surface_id),
            .view_w = view.w,
            .view_h = view.h,
            .toplevel_state = c.toplevelState(conn_id, surface_id),
            .root = c.surfaceRoot(conn_id, surface_id),
            .parent = c.surfaceParent(conn_id, surface_id),
            .abs_x = abs.x,
            .abs_y = abs.y,
            .z = c.surfaceZ(conn_id, surface_id),
            .geom_x = g.x,
            .geom_y = g.y,
            .geom_w = g.w,
            .geom_h = g.h,
        };
    }

    fn surfaceExists(self: *Session, conn_id: u32, surface_id: u32) bool {
        const conn = self.comp.conns.get(conn_id) orelse return false;
        return conn.surfaces.contains(surface_id);
    }

    /// A SURFACE for the surface if the viewer's copy differs.
    fn noteSurface(self: *Session, conn_id: u32, surface_id: u32) void {
        var bytes: [stream.SurfaceFrame.len]u8 = undefined;
        self.record(conn_id, surface_id).encode(&bytes);
        const gop = self.records.getOrPut(self.gpa, key.of(conn_id, surface_id)) catch return;
        if (gop.found_existing and std.mem.eql(u8, &gop.value_ptr.*, &bytes)) return;
        const out = self.to_viewer.frame(self.gpa, bytes.len) catch {
            _ = self.records.remove(key.of(conn_id, surface_id)); // unsent: compared again next time
            return;
        };
        @memcpy(out[0..bytes.len], &bytes);
        gop.value_ptr.* = bytes;
    }

    /// Before an EVENT naming a surface: its SURFACE and its root's.
    fn noteNamed(self: *Session, conn_id: u32, surface_id: u32) void {
        if (!self.live() or surface_id == 0 or !self.surfaceExists(conn_id, surface_id)) return;
        self.noteSurface(conn_id, surface_id);
        const root = self.comp.surfaceRoot(conn_id, surface_id);
        if (root != surface_id and self.surfaceExists(conn_id, root)) self.noteSurface(conn_id, root);
    }

    /// Every live surface whose SURFACE changed.
    fn diffAll(self: *Session) void {
        if (!self.live()) return;
        var it = self.comp.conns.iterator();
        while (it.next()) |kv| {
            var sit = kv.value_ptr.*.surfaces.keyIterator();
            while (sit.next()) |sid| self.noteSurface(kv.key_ptr.*, sid.*);
        }
    }

    // ------------------------------------------------------------------
    // EVENTs (core callbacks)
    // ------------------------------------------------------------------

    /// The argument writer for an EVENT, or null when the viewer is not sent
    /// events. Finish with `endEvent`.
    fn beginEvent(self: *Session) ?stream.ArgWriter {
        if (!self.live()) return null;
        self.args.clearRetainingCapacity();
        return .{ .list = &self.args, .gpa = self.gpa };
    }

    fn endEvent(self: *Session, op: stream.EventOp) void {
        self.to_viewer.opFrame(self.gpa, .event, @intFromEnum(op), self.args.items) catch {};
    }

    fn of(ctx: ?*anyopaque) *Session {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn evTitle(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, title: []const u8) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(surface_id) catch return;
        w.bytes(title) catch return;
        self.endEvent(.set_title);
    }

    fn evAppId(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, app_id: []const u8) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(surface_id) catch return;
        w.bytes(app_id) catch return;
        self.endEvent(.set_app_id);
    }

    fn evSizeLimits(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, min_w: i32, min_h: i32, max_w: i32, max_h: i32) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(surface_id) catch return;
        inline for (.{ min_w, min_h, max_w, max_h }) |v| w.i32_(v) catch return;
        self.endEvent(.size_limits);
    }

    fn evDecoration(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, decorated: bool) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        inline for (.{ conn_id, surface_id, @as(u32, @intFromBool(decorated)) }) |v| w.u32_(v) catch return;
        self.endEvent(.decoration);
    }

    fn evConfigure(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, cfg: core.compositor.Configure, cause: u32) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        inline for (.{ conn_id, surface_id, cfg.serial }) |v| w.u32_(v) catch return;
        inline for (.{ cfg.w, cfg.h }) |v| w.i32_(v) catch return;
        inline for (.{ cfg.states, cause }) |v| w.u32_(v) catch return;
        self.endEvent(.configure);
    }

    fn evAcked(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, serial: u32, cw: i32, ch: i32) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        inline for (.{ conn_id, surface_id, serial }) |v| w.u32_(v) catch return;
        inline for (.{ cw, ch }) |v| w.i32_(v) catch return;
        self.endEvent(.acked);
    }

    fn evSurface(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, value: u32) void {
        const self = of(ctx);
        if (value != core.compositor.surface_destroyed_code) self.noteNamed(conn_id, surface_id);
        if (self.beginEvent()) |w| {
            w.u32_(conn_id) catch return;
            w.u32_(surface_id) catch return;
            w.u32_(value) catch return;
            self.endEvent(.surface_event);
        }
        // its record and pixels end with it (the viewer's too)
        if (value == core.compositor.surface_destroyed_code) self.dropShadow(key.of(conn_id, surface_id));
    }

    fn evInteractive(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, kind: u32, value: u32) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        inline for (.{ conn_id, surface_id, kind, value }) |v| w.u32_(v) catch return;
        self.endEvent(.interactive);
    }

    fn evCursorShape(ctx: ?*anyopaque, conn_id: u32, shape: u32) void {
        const self = of(ctx);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(shape) catch return;
        self.endEvent(.cursor_shape);
    }

    fn evCursorSurface(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, hx: i32, hy: i32) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(surface_id) catch return;
        w.i32_(hx) catch return;
        w.i32_(hy) catch return;
        self.endEvent(.cursor_surface);
    }

    fn evTextInput(ctx: ?*anyopaque, conn_id: u32, active: u32, x: i32, y: i32, rw: i32, rh: i32) void {
        const self = of(ctx);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(active) catch return;
        inline for (.{ x, y, rw, rh }) |v| w.i32_(v) catch return;
        self.endEvent(.text_input);
    }

    fn evInputRegion(ctx: ?*anyopaque, conn_id: u32, surface_id: u32, region: ?*const Region) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(surface_id) catch return;
        const r = region orelse {
            w.u32_(1) catch return; // infinite
            w.u32_(0) catch return;
            return self.endEvent(.input_region);
        };
        const boxes = r.slice();
        w.u32_(0) catch return;
        w.u32_(@intCast(boxes.len)) catch return;
        for (boxes) |b| {
            inline for (.{ b.x0, b.y0, b.x1 -| b.x0, b.y1 -| b.y0 }) |v| w.i32_(v) catch return;
        }
        self.endEvent(.input_region);
    }

    fn evPointerLock(ctx: ?*anyopaque, conn_id: u32, surface_id: u32) void {
        const self = of(ctx);
        self.noteNamed(conn_id, surface_id);
        const w = self.beginEvent() orelse return;
        w.u32_(conn_id) catch return;
        w.u32_(surface_id) catch return;
        self.endEvent(.pointer_lock);
    }

    fn evSelection(ctx: ?*anyopaque, conn_id: u32, mimes: []const []const u8) void {
        const self = of(ctx);
        const w = self.beginEvent() orelse return;
        self.selection_events +%= 1;
        w.u32_(conn_id) catch return;
        var len: usize = 0;
        for (mimes, 0..) |m, i| len += m.len + @intFromBool(i > 0);
        w.u32_(@intCast(len)) catch return;
        for (mimes, 0..) |m, i| {
            if (i > 0) self.args.append(self.gpa, 0) catch return;
            self.args.appendSlice(self.gpa, m) catch return;
        }
        self.endEvent(.selection);
    }

    fn selectionData(self: *Session, read_id: u32, status: u32, data: []const u8) void {
        const w = self.beginEvent() orelse return;
        w.u32_(read_id) catch return;
        w.u32_(status) catch return;
        w.bytes(data) catch return;
        self.endEvent(.selection_data);
    }

    fn sendLocks(self: *Session, locks: u32) void {
        const w = self.beginEvent() orelse return;
        w.u32_(locks) catch return;
        self.endEvent(.keyboard_locks_state);
        self.locks_sent = locks;
    }

    // the core's frames for the relay (wasm.zig's js_send path)

    fn coreSend(ctx: ?*anyopaque, conn_id: u32, bytes: []const u8) void {
        const self = of(ctx);
        self.to_relay.wire(self.gpa, conn_id, bytes) catch std.log.err("session: out of memory, wire for c{d} lost", .{conn_id});
    }

    fn coreFdMsg(ctx: ?*anyopaque, conn_id: u32, kind: u32, wire_bytes: []const u8, aux: []const u8) void {
        const self = of(ctx);
        self.to_relay.fdMsg(self.gpa, conn_id, @enumFromInt(kind), wire_bytes, aux) catch std.log.err("session: out of memory, fdmsg for c{d} lost", .{conn_id});
    }

    fn coreSrvObj(ctx: ?*anyopaque, conn_id: u32, object_id: u32, kind: u32) void {
        const self = of(ctx);
        const out = self.to_relay.frame(self.gpa, stream.srvobj_len) catch return;
        stream.writeSrvObj(out[0..stream.srvobj_len], conn_id, object_id, kind);
    }

    fn coreDmabufCreated(ctx: ?*anyopaque, conn_id: u32, params_id: u32, buffer_id: u32) void {
        const self = of(ctx);
        const out = self.to_relay.frame(self.gpa, stream.dmabuf_created_len) catch return;
        stream.writeDmabufCreated(out[0..stream.dmabuf_created_len], conn_id, params_id, buffer_id);
    }

    fn corePresented(ctx: ?*anyopaque, conn_id: u32, age_us: u32, msg: []const u8) void {
        const self = of(ctx);
        self.to_relay.presented(self.gpa, conn_id, age_us, msg) catch {};
    }

    /// The core's log lines go to the viewer (EVENT log), as wasm's went to
    /// the page (js_log); none are sent while no viewer is.
    fn coreLog(ctx: ?*anyopaque, text: []const u8) void {
        const self = of(ctx);
        const w = self.beginEvent() orelse return;
        w.bytes(text) catch return;
        self.endEvent(.log);
    }

    fn logf(self: *Session, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        coreLog(self, std.fmt.bufPrint(&buf, fmt, args) catch &buf);
    }

    // ------------------------------------------------------------------
    // the clock
    // ------------------------------------------------------------------

    fn clockLoop(self: *Session) void {
        var n: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(tick_ms), .awake) catch {};
            n +%= 1;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const attached = self.viewer != null and self.synced;
            if (!attached and n % idle_tick_every != 0) continue;
            const now_ms = Io.Clock.now(.awake, self.io).toMilliseconds();
            self.comp.tick(.{
                .time_ms = @truncate(@as(u64, @intCast(@max(0, now_ms)))),
                .refresh_ns = if (attached) 16_666_667 else 0,
            });
            self.endStep();
        }
    }

    // ------------------------------------------------------------------
    // viewers
    // ------------------------------------------------------------------

    /// Serve one viewer link until it closes or is taken over (blocks). On
    /// return the host no longer references `link`. A viewer attaching
    /// while another is kicks the old one and waits for it to detach.
    pub fn serveViewer(self: *Session, link: *Link) void {
        const io = self.io;
        // first on the link, before anything else: what this relay is
        {
            var id: [8]u8 = undefined;
            std.mem.writeInt(u64, &id, self.session_id, .little);
            var out: [stream.feature_header_len + 8]u8 = undefined;
            link.send(stream.encodeFeature(&out, .session, &id)) catch {}; // a dead link fails its recv below
        }
        while (true) {
            self.vmutex.lockUncancelable(io);
            while (self.viewer) |old| {
                std.log.info("session: viewer takeover: kicking the previous one", .{});
                old.kick(); // never blocks (link.zig)
                self.viewer_detached.waitUncancelable(io, &self.vmutex);
            }
            self.vmutex.unlock(io);
            self.mutex.lockUncancelable(io);
            self.vmutex.lockUncancelable(io);
            const free = self.viewer == null;
            if (free) {
                self.viewer = link;
                self.synced = false;
                self.viewer_broken = false;
            }
            self.vmutex.unlock(io);
            self.mutex.unlock(io);
            if (free) break; // else another viewer got in between: take over again
        }
        std.log.info("session: viewer attached (waiting for its init)", .{});

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.gpa);
        while (true) {
            link.recv(self.gpa, &msg) catch |err| {
                switch (err) {
                    error.EndOfStream, error.LinkGone => {},
                    error.OutOfMemory => std.log.err("session: viewer link: {t}", .{err}),
                }
                break;
            };
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.viewer_broken) break;
            self.viewerMessage(msg.items);
            self.endStep();
        }

        self.mutex.lockUncancelable(io);
        self.vmutex.lockUncancelable(io);
        self.viewer = null;
        self.vmutex.unlock(io);
        self.synced = false;
        self.viewer_broken = false;
        self.records.clearRetainingCapacity();
        self.pending_reads.clearRetainingCapacity();
        self.to_viewer.clear();
        self.locks_sent = null;
        // what only the viewer held up ends; the apps are suspended
        self.comp.embedderGone();
        self.endStep();
        self.mutex.unlock(io);
        self.viewer_detached.broadcast(io);
        std.log.info("session: viewer detached (apps kept)", .{});
    }

    /// One viewer message: its CALLs, in order. Host mutex held.
    fn viewerMessage(self: *Session, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const p = stream.parseNext(rest) catch |err| {
                std.log.err("session: bad viewer frame: {t}", .{err});
                return;
            };
            rest = rest[p.consumed..];
            switch (p.frame) {
                .call => |f| self.call(f) catch |err| std.log.warn("session: CALL {d}: {t}", .{ f.op, err }),
                else => std.log.warn("session: unexpected {t} frame from a viewer", .{std.meta.activeTag(p.frame)}),
            }
        }
    }

    /// One CALL: the Compositor method its wasm export calls, with the
    /// same conversions (core/src/wasm.zig).
    fn call(self: *Session, f: stream.OpFrame) !void {
        const c = &self.comp;
        var a: stream.ArgReader = .{ .rest = f.args };
        const op: stream.CallOp = @enumFromInt(f.op);
        if (op == .init) {
            const scale = try a.i32_();
            const scale_120 = try a.i32_();
            // (a viewer before decorations sends no more: client-side)
            const decorations = a.u32_() catch 0;
            return self.attach(scale, scale_120, decorations == 1);
        }
        if (!self.synced) return; // nothing before init
        switch (op) {
            .init => unreachable,
            .set_gpu_source => c.gpu_source = try a.u32_() != 0,
            .set_dpr => c.setScale(try a.i32_(), try a.i32_()),
            .desktop_size => c.setDesktopSize(try a.i32_(), try a.i32_()),
            .set_suspended => c.setSuspended(try a.u32_() != 0),
            .pointer_enter => c.pointerEnter(try a.u32_(), try a.u32_(), try a.i32_(), try a.i32_()),
            .pointer_leave => c.pointerLeave(try a.u32_()),
            .pointer_motion => {
                const conn_id = try a.u32_();
                const time_ms = try a.u32_();
                const x = try a.i32_();
                const y = try a.i32_();
                const dx = try a.i32_();
                const dy = try a.i32_();
                const dxu = try a.i32_();
                const dyu = try a.i32_();
                const utime = try a.f64_();
                const us: u64 = if (utime > 0 and utime < 9007199254740992.0) @intFromFloat(utime) else 0;
                c.pointerMotion(conn_id, time_ms, x, y, .{ .dx = dx, .dy = dy, .dx_unaccel = dxu, .dy_unaccel = dyu, .utime = us });
            },
            .pointer_lock_granted => c.pointerLockGranted(try a.u32_(), try a.u32_()),
            .pointer_lock_lost => c.pointerLockLost(try a.u32_()),
            .pointer_button => c.pointerButton(try a.u32_(), try a.u32_(), try a.u32_(), try a.u32_() != 0),
            .pointer_axis => c.pointerAxis(try a.u32_(), try a.u32_(), try a.u32_(), try a.i32_(), try a.i32_()),
            .keyboard_enter => c.keyboardEnter(try a.u32_(), try a.u32_()),
            .keyboard_leave => c.keyboardLeave(try a.u32_()),
            .key => c.keyboardKey(try a.u32_(), try a.u32_(), try a.u32_(), try a.u32_() != 0),
            .keyboard_locks => {
                const locks = try a.u32_();
                c.keyboardLocks(locks & 1 != 0, locks & 2 != 0);
            },
            .text_input_preedit => c.textInputPreedit(try a.u32_(), try a.bytes(), try a.i32_(), try a.i32_()),
            .text_input_commit_string => c.textInputCommitString(try a.u32_(), try a.bytes()),
            .set_maximized, .set_fullscreen => {
                const conn_id = try a.u32_();
                const surface_id = try a.u32_();
                const on = try a.u32_() != 0;
                // (a viewer before tokens sends no cause)
                c.cause = a.u32_() catch 0;
                defer c.cause = 0;
                if (op == .set_maximized) c.setMaximized(conn_id, surface_id, on) else c.setFullscreen(conn_id, surface_id, on);
            },
            .set_minimized => c.setMinimized(try a.u32_(), try a.u32_(), try a.u32_() != 0),
            .popup_dismiss => c.popupDismiss(try a.u32_(), try a.u32_()),
            .close => c.closeToplevel(try a.u32_(), try a.u32_()),
            .set_bounds => c.setBounds(try a.i32_(), try a.i32_(), try a.i32_(), try a.i32_()),
            .set_visible => c.setVisible(try a.u32_(), try a.u32_(), try a.u32_() != 0),
            .request_resize => {
                const conn_id = try a.u32_();
                const surface_id = try a.u32_();
                const w = try a.i32_();
                const h = try a.i32_();
                c.cause = a.u32_() catch 0;
                defer c.cause = 0;
                c.requestResize(conn_id, surface_id, w, h);
            },
            .set_tiled => {
                const conn_id = try a.u32_();
                const surface_id = try a.u32_();
                const edges = try a.u32_();
                const w = try a.i32_();
                const h = try a.i32_();
                c.cause = a.u32_() catch 0;
                defer c.cause = 0;
                c.setTiled(conn_id, surface_id, edges, w, h);
            },
            .drag_motion => c.dragMotion(try a.u32_(), try a.u32_(), try a.u32_(), try a.i32_(), try a.i32_()),
            .drag_drop => c.dragDrop(),
            .drag_cancel => c.dragCancel(),
            .set_selection => {
                const packed_entries = try a.bytes();
                const before = self.selection_events;
                c.setOwnSelection(packed_entries) catch |err| self.logf("set_selection: {t}", .{err});
                // the outcome is a selection EVENT: the selection as it is
                // now when the call changed nothing (refused, or a clear of
                // a client's selection)
                if (self.selection_events == before) c.tellSelection();
            },
            .read_selection => {
                const mime = try a.bytes();
                const read_id = try a.u32_();
                const max_bytes = try a.u32_();
                if (c.readSelection(mime, read_id, max_bytes)) {
                    try self.pending_reads.append(self.gpa, read_id);
                } else {
                    self.selectionData(read_id, @intFromEnum(stream.PipeReadStatus.failed), &.{});
                }
            },
            _ => {}, // an op this relay does not know: skipped
        }
    }

    /// CALL init: the viewer attaches — the scale as set_dpr, un-suspended,
    /// its decorations mode (toplevels it changes answered again: apps
    /// outlive viewers), no bounds of the last viewer's and none of its
    /// per-window state (hidden windows shown: it sends its own), then the
    /// scene replay (STREAM.md), ending in EVENT synced. The
    /// mode is set before `synced`, so the replay carries what it made.
    fn attach(self: *Session, scale: i32, scale_120: i32, decorations_server: bool) void {
        const c = &self.comp;
        c.setScale(scale, scale_120);
        c.setSuspended(false);
        c.setDecorations(decorations_server);
        c.setBounds(0, 0, 0, 0);
        c.resetEmbedderWindows();
        self.synced = true;
        self.records.clearRetainingCapacity();
        self.locks_sent = null;
        self.replay();
        std.log.info("session: viewer init'ed (scene replayed)", .{});
    }

    fn replay(self: *Session) void {
        const gpa = self.gpa;
        const c = &self.comp;
        const conns = c.connIds(gpa) catch return;
        defer gpa.free(conns);
        for (conns) |conn_id| {
            const open = stream.encodeConnFrame(.conn_open, conn_id);
            self.forward(&open);
        }
        // every surface's record first, parents first, then what describes
        // them (their SURFACE is current by then)
        for (conns) |conn_id| {
            const ids = c.surfaceIds(gpa, conn_id) catch continue;
            defer gpa.free(ids);
            for (ids) |sid| self.noteSurface(conn_id, sid);
        }
        c.replaySurfaces();
        // pixels: one whole-surface frame each
        for (conns) |conn_id| {
            const ids = c.surfaceIds(gpa, conn_id) catch continue;
            defer gpa.free(ids);
            for (ids) |sid| {
                if (!c.surfaceHasContent(conn_id, sid)) continue;
                const s = self.shadows.get(key.of(conn_id, sid)) orelse continue;
                self.wholeBuffer(conn_id, sid, s);
            }
        }
        c.replaySeat();
        const l = c.lockState();
        self.sendLocks(@as(u32, @intFromBool(l.caps_lock)) | @as(u32, @intFromBool(l.num_lock)) << 1);
        if (self.beginEvent() != null) self.endEvent(.synced);
    }

    /// A surface's whole shadow as one BUFFER (BUFFER_LZ when that is
    /// smaller, as the copy backend decides).
    fn wholeBuffer(self: *Session, conn_id: u32, surface_id: u32, s: Shadow) void {
        if (!self.live() or s.w == 0 or s.h == 0) return;
        const gpa = self.gpa;
        const prefix = stream.buffer_header_len + 16;
        compressed: {
            if (s.px.len < 4096) break :compressed;
            self.lz.resize(gpa, core.lz4.compressBound(s.px.len)) catch break :compressed;
            const n = core.lz4.compress(s.px, self.lz.items) orelse break :compressed;
            if (n >= s.px.len) break :compressed;
            const out = self.to_viewer.frame(gpa, prefix + stream.buffer_lz_meta_len + n) catch return;
            writeHead(out, .buffer_lz, conn_id, surface_id, s);
            std.mem.writeInt(u32, out[prefix..][0..4], @intCast(s.px.len), .little);
            std.mem.writeInt(u32, out[prefix + 4 ..][0..4], @intCast(n), .little);
            @memcpy(out[prefix + stream.buffer_lz_meta_len ..][0..n], self.lz.items[0..n]);
            return;
        }
        const out = self.to_viewer.frame(gpa, prefix + s.px.len) catch return;
        writeHead(out, .buffer, conn_id, surface_id, s);
        @memcpy(out[prefix..][0..s.px.len], s.px);
    }

    fn writeHead(out: []u8, frame_type: stream.FrameType, conn_id: u32, surface_id: u32, s: Shadow) void {
        stream.writeBufferHeader(out[0..stream.buffer_header_len], .{ .conn_id = conn_id, .surface_id = surface_id, .width = s.w, .height = s.h, .n_rects = 1 });
        out[0] = @intFromEnum(frame_type);
        stream.writeRect(out[stream.buffer_header_len..][0..16], 0, 0, @intCast(s.w), @intCast(s.h));
    }
};
