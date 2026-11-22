// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Native end-to-end harness, no browser: scripted wayland clients on unix
//! socketpairs ⇄ the real relay ⇄ a StreamLink socketpair ⇄ the real core
//! compositor running natively (a twin of core/src/wasm.zig's glue).
//!
//! The test thread plays both the clients and the engine; the relay runs
//! its usual threads (serveLink + one serveApp per client). Typical use:
//!
//!     var loop: Loop = undefined;
//!     try loop.start(std.testing.allocator, .{});
//!     defer loop.stop();
//!     const c = try loop.connect();
//!     try c.send(1, get_registry, ...);
//!     try loop.roundtrip(c);   // every effect of earlier requests has landed
//!
//! Handle backends: pass `.backend = .procfd`; the engine then opens every
//! HANDLE_OPEN through /proc/<pid>/fd/<fd> (this very process), reads the
//! damaged pixels each COMMIT names into `Engine.surfaces`, and ACKs —
//! at once, or (auto_ack = false) when the test calls `Engine.ack`.
//! `.backend = .{ .kwshm = dev }` (dev: any open fd) runs the kwshm backend
//! against kwshm.fake (test builds); the engine resolves export ids through it.
//! dmabuf virtgpu: pass a `dmabuf` Config whose importer runs on a
//! `virtgpu.Fake` and set `engine.gpu` to it; kind-virtgpu COMMITs land in
//! `Engine.gpu_commits` and their resources' pixels in `Engine.surfaces`.
//! Copy mode: BUFFER / BUFFER_LZ pixels land in `Engine.surfaces` too (byte
//! order put back to the client's BGRA; X alpha comes out 0xff). Like the
//! reference GL presenter, a surface whose content changes kind (handle
//! pixels, stream pixels, a GPU resource) or size starts from a blank
//! (zeroed) copy: only what the new frame's rects name is shown.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const core = @import("core");
const wire = core.wire;
const stream = core.stream;
const protocol = core.protocol;
const shm = @import("shm.zig");
const relay_mod = @import("relay.zig");
const buffers = @import("buffers.zig");
const dmabuf = @import("dmabuf.zig");
const kwshm = @import("kwshm.zig");
const virtgpu = @import("virtgpu.zig");
const Link = @import("link.zig").Link;
const StreamLink = @import("stream_link.zig").StreamLink;

const timeout_ms = 5000;

pub const Options = struct {
    frame_callbacks: Link.FrameCallbacks = .engine,
    backend: buffers.Backend = .copy,
    /// the relay takes dmabufs (its FEATURE frames reach the engine first)
    dmabuf: ?dmabuf.Config = null,
    /// the engine can draw GPU buffers (Compositor.gpu_source)
    gpu_source: bool = true,
};

pub const Loop = struct {
    gpa: std.mem.Allocator,
    threaded: Io.Threaded,
    relay: relay_mod.Relay,
    /// fds[0] = relay end (StreamLink), fds[1] = engine end
    link_fds: [2]i32,
    link: StreamLink,
    link_thread: std.Thread,
    engine: Engine,
    clients: [max_clients]Client = undefined,
    app_threads: [max_clients]std.Thread = undefined,
    n_clients: usize = 0,

    const max_clients = 4;

    /// In place (threads keep pointers into the Loop).
    pub fn start(self: *Loop, gpa: std.mem.Allocator, opts: Options) !void {
        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{}),
            .relay = undefined,
            .link_fds = try socketpair(),
            .link = undefined,
            .link_thread = undefined,
            .engine = undefined,
        };
        const io = self.threaded.io();
        self.relay = .{ .io = io, .gpa = gpa, .backend = opts.backend, .dmabuf = opts.dmabuf };
        self.link.init(io, self.link_fds[0], opts.frame_callbacks);
        self.engine.init(gpa, self.link_fds[1]);
        self.engine.comp.gpu_source = opts.gpu_source;
        self.link_thread = try std.Thread.spawn(.{}, relay_mod.serveLink, .{ &self.relay, &self.link.link });
    }

    /// A new app connection (the relay sends CONN_OPEN once it registers).
    pub fn connect(self: *Loop) !*Client {
        std.debug.assert(self.n_clients < max_clients);
        const fds = try socketpair();
        const c = &self.clients[self.n_clients];
        c.* = .{ .gpa = self.gpa, .fd = fds[1] };
        const app: Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
        self.app_threads[self.n_clients] = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &self.relay, app });
        self.n_clients += 1;
        return c;
    }

    /// Kick the link; the relay drops every conn and its threads exit.
    pub fn stop(self: *Loop) void {
        self.link.link.kick();
        self.link_thread.join(); // returns once no app thread uses the link
        for (self.app_threads[0..self.n_clients]) |t| t.join();
        for (self.clients[0..self.n_clients]) |*c| c.deinit();
        self.relay.deinit();
        self.engine.deinit();
        _ = linux.close(self.link_fds[0]);
        _ = linux.close(self.link_fds[1]);
        self.threaded.deinit();
    }

    /// Pump the engine and every client until `pred` holds (error.Timeout
    /// after 5 s of real time).
    pub fn until(self: *Loop, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
        const io = self.threaded.io();
        const deadline = Io.Clock.now(.awake, io).toMilliseconds() + timeout_ms;
        while (!pred(ctx)) {
            var pfds: [1 + max_clients]linux.pollfd = undefined;
            pfds[0] = .{ .fd = self.engine.fd, .events = linux.POLL.IN, .revents = 0 };
            for (self.clients[0..self.n_clients], 1..) |c, i|
                pfds[i] = .{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 };
            const n = 1 + self.n_clients;
            const left = deadline - Io.Clock.now(.awake, io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            const rc = linux.poll(&pfds, n, @intCast(left));
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS) return error.PollFailed;
            if (pfds[0].revents != 0) try self.engine.readRecord();
            for (self.clients[0..self.n_clients], 1..) |*c, i|
                if (pfds[i].revents != 0) try c.read();
        }
    }

    /// Two round trips: when it returns, every ACK the engine sent before
    /// the call has been settled by the relay too (releases written,
    /// HANDLE_CLOSEs received). One is not enough: an ACK and the sync's
    /// done can share a link message, and the relay writes done to the app
    /// from the link thread while the ACK is settled on the app thread. The
    /// app thread takes queued ACKs before the next requests, so the second
    /// sync orders after them.
    pub fn settle(self: *Loop, c: *Client) !void {
        try self.roundtrip(c);
        try self.roundtrip(c);
    }

    /// wl_display.sync round trip: when it returns, every effect of the
    /// client's earlier requests has reached the engine and the client
    /// (relay-fired frame callbacks excepted — they may wait for the pacing
    /// floor; use `until` for those).
    pub fn roundtrip(self: *Loop, c: *Client) !void {
        const cb = c.newId();
        try c.send(1, comptime op("wl_display", .request, "sync"), &.{.{ .new_id = cb }});
        const Ctx = struct { c: *Client, cb: u32 };
        try self.until(Ctx{ .c = c, .cb = cb }, struct {
            fn pred(x: Ctx) bool {
                return x.c.count(x.cb, comptime op("wl_callback", .event, "done")) > 0;
            }
        }.pred);
    }
};

/// Opcode of a request or event, by name (comptime).
pub fn op(comptime iface: []const u8, comptime dir: enum { request, event }, comptime name: []const u8) u16 {
    const i = protocol.find(iface).?;
    return switch (dir) {
        .request => i.requestIndex(name).?,
        .event => i.eventIndex(name).?,
    };
}

pub const Event = struct {
    object_id: u32,
    opcode: u16,
    /// args (owned)
    body: []u8,
};

/// A scripted wayland client: hand-encoded requests, every event recorded.
pub const Client = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    next_id: u32 = 2,
    rx: [64 * 1024]u8 = undefined,
    fill: usize = 0,
    /// fds received with events, in arrival order (the client can't tell
    /// which event an fd belongs to without interface knowledge; tests pop)
    fds: shm.FdQueue = .{},
    events: std.ArrayList(Event) = .empty,

    fn deinit(self: *Client) void {
        for (self.events.items) |e| self.gpa.free(e.body);
        self.events.deinit(self.gpa);
        self.fds.drain();
        self.close();
    }

    /// Hang up (the app exits). `Loop.until` stops polling it.
    pub fn close(self: *Client) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1; // poll ignores negative fds
    }

    pub fn newId(self: *Client) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }

    pub fn send(self: *Client, object_id: u32, opcode: u16, args: []const wire.Value) !void {
        var buf: [512]u8 = undefined;
        try writeAll(self.fd, wire.encodeMessage(&buf, object_id, opcode, args));
    }

    /// A request whose signature carries one fd (`.fd` in `args`).
    pub fn sendFd(self: *Client, object_id: u32, opcode: u16, args: []const wire.Value, fd: i32) !void {
        var buf: [512]u8 = undefined;
        try shm.sendWithFd(self.fd, wire.encodeMessage(&buf, object_id, opcode, args), fd);
    }

    /// Events received so far on `object_id` with `opcode`.
    pub fn count(self: *const Client, object_id: u32, opcode: u16) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e.object_id == object_id and e.opcode == opcode) n += 1;
        }
        return n;
    }

    pub fn last(self: *const Client, object_id: u32, opcode: u16) ?Event {
        var i = self.events.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.events.items[i];
            if (e.object_id == object_id and e.opcode == opcode) return e;
        }
        return null;
    }

    /// wl_registry.global events so far: the name of `interface`.
    pub fn globalName(self: *const Client, registry: u32, interface: []const u8) ?u32 {
        for (self.events.items) |e| {
            if (e.object_id != registry or e.opcode != comptime op("wl_registry", .event, "global")) continue;
            var vals: [wire.max_args]wire.Value = undefined;
            const args = wire.decodeArgs(e.body, &.{ .uint, .string, .uint }, &vals) catch continue;
            if (std.mem.eql(u8, args[1].string.?, interface)) return args[0].uint;
        }
        return null;
    }

    fn read(self: *Client) !void {
        const n = try shm.recvWithFds(self.fd, self.rx[self.fill..], &self.fds);
        if (n == 0) return error.EndOfStream;
        self.fill += n;
        var off: usize = 0;
        while (self.fill - off >= wire.header_size) {
            const h = try wire.Header.parse(self.rx[off..]);
            if (self.fill - off < h.size) break;
            try self.events.append(self.gpa, .{
                .object_id = h.object_id,
                .opcode = h.opcode,
                .body = try self.gpa.dupe(u8, self.rx[off + wire.header_size .. off + h.size]),
            });
            off += h.size;
        }
        std.mem.copyForwards(u8, self.rx[0 .. self.fill - off], self.rx[off..self.fill]);
        self.fill -= off;
    }
};

/// The engine end: core's Compositor driven natively from STREAM records,
/// exactly as core/src/wasm.zig drives it from WS messages.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    comp: core.compositor.Compositor,
    batch: stream.Batch = .{},
    rx: std.ArrayList(u8) = .empty,
    /// Every frame received from the relay, in order.
    frames: std.ArrayList(Received) = .empty,

    /// Handle backends: open handles by key(conn_id, handle_id).
    handles: std.AutoHashMapUnmanaged(u64, OpenHandle) = .empty,
    handles_opened: usize = 0,
    /// closed by HANDLE_CLOSE / dropped with their conn (CONN_CLOSE)
    handles_closed: usize = 0,
    handles_dropped: usize = 0,
    /// Relay misbehaviour a real engine would only log: a HANDLE_CLOSE or
    /// COMMIT naming an unknown handle, a duplicate handle id, an invalid
    /// COMMIT, a failed open or read. Tests expect 0.
    errors: usize = 0,
    /// What each surface shows, as the client wrote it (BGRA/BGRX), tightly
    /// packed w*4 rows, by key(conn_id, surface_id): pixels read through
    /// handles or resources, or shipped in BUFFER frames.
    surfaces: std.AutoHashMapUnmanaged(u64, Pixels) = .empty,
    /// Every COMMIT received, in order.
    commits: std.ArrayList(SeenCommit) = .empty,
    /// false: COMMITs are not ACKed until the test calls `ack`.
    auto_ack: bool = true,
    /// Every COMMIT of buffer kind virtgpu received, in order.
    gpu_commits: std.ArrayList(SeenGpuCommit) = .empty,
    /// The virtio-gpu stand-in the relay names resources on (a test's
    /// `virtgpu.Fake`): set, the engine resolves each kind-virtgpu COMMIT's
    /// resource through it as the host renderer would and reads the damaged
    /// pixels into `surfaces` — an unresolvable resource counts as an error.
    gpu: ?*virtgpu.Fake = null,

    pub const OpenHandle = struct { fd: i32, offset: u64, size: u64 };
    pub const Pixels = struct { width: u32, height: u32, bytes: []u8, kind: ContentKind };
    /// Where a surface's pixels came from: a change starts a blank copy,
    /// as the GL presenter's texture does (present.ts).
    pub const ContentKind = enum { handle, buffer, gpu };
    pub const SeenCommit = struct { conn_id: u32, surface_id: u32, serial: u32, ref: stream.ShmRef, n_rects: u32, first_rect: stream.Rect };
    pub const SeenGpuCommit = struct { conn_id: u32, surface_id: u32, serial: u32, ref: stream.VirtgpuRef, n_rects: u32, first_rect: stream.Rect };

    pub fn key(conn_id: u32, id: u32) u64 {
        return @as(u64, conn_id) << 32 | id;
    }

    pub const Received = struct {
        type: stream.FrameType,
        /// the whole frame (owned)
        bytes: []u8,

        pub fn parse(self: Received) stream.Frame {
            return stream.parse(self.bytes) catch unreachable;
        }
    };

    fn init(self: *Engine, gpa: std.mem.Allocator, fd: i32) void {
        self.* = .{ .gpa = gpa, .fd = fd, .comp = .init(gpa, self, sendWire, log) };
        self.comp.fdmsg_fn = sendFdMsg;
        self.comp.srvobj_fn = sendSrvObj;
        self.comp.dmabuf_created_fn = sendDmabufCreated;
        self.comp.presented_fn = sendPresented;
    }

    fn deinit(self: *Engine) void {
        self.comp.deinit();
        self.batch.deinit(self.gpa);
        self.rx.deinit(self.gpa);
        for (self.frames.items) |f| self.gpa.free(f.bytes);
        self.frames.deinit(self.gpa);
        var h_it = self.handles.valueIterator();
        while (h_it.next()) |h| _ = linux.close(h.fd);
        self.handles.deinit(self.gpa);
        var s_it = self.surfaces.valueIterator();
        while (s_it.next()) |s| self.gpa.free(s.bytes);
        self.surfaces.deinit(self.gpa);
        self.commits.deinit(self.gpa);
        self.gpu_commits.deinit(self.gpa);
    }

    /// ACK a COMMIT now (auto_ack = false tests). Any serial goes — the
    /// relay must ignore unknown ones.
    pub fn ack(self: *Engine, conn_id: u32, serial: u32) !void {
        try self.batch.ack(self.gpa, conn_id, serial);
        try self.flush();
    }

    /// Send a SRVOBJ frame now (as the compositor does for primary offers).
    pub fn srvObj(self: *Engine, conn_id: u32, object_id: u32, kind: u32) !void {
        sendSrvObj(self, conn_id, object_id, kind);
        try self.flush();
    }

    /// The pixels a surface shows (read through handles).
    pub fn pixels(self: *const Engine, conn_id: u32, surface_id: u32) ?Pixels {
        return self.surfaces.get(key(conn_id, surface_id));
    }

    fn handleOpen(self: *Engine, h: stream.HandleOpenFrame) !void {
        self.handles_opened += 1;
        const opened: OpenHandle = switch (h.kind) {
            @intFromEnum(stream.HandleKind.procfd) => blk: {
                const p = stream.ProcfdHandle.decode(h.bytes) catch {
                    self.errors += 1;
                    return;
                };
                var path_buf: [64]u8 = undefined;
                const path = try std.fmt.bufPrintZ(&path_buf, "/proc/{d}/fd/{d}", .{ p.pid, p.fd });
                const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
                if (linux.errno(rc) != .SUCCESS) {
                    self.errors += 1;
                    return;
                }
                break :blk .{ .fd = @intCast(rc), .offset = p.offset, .size = p.size };
            },
            // the host side of kwshm.fake: resolve the export id, as
            // unkernel's page does; the export's size must match the handle's
            @intFromEnum(stream.HandleKind.kwshm) => blk: {
                const k = stream.KwshmHandle.decode(h.bytes) catch {
                    self.errors += 1;
                    return;
                };
                const r = kwshm.fake.resolve(k.id) orelse {
                    self.errors += 1;
                    return;
                };
                if (r.size != k.size) {
                    _ = linux.close(r.fd);
                    self.errors += 1;
                    return;
                }
                break :blk .{ .fd = r.fd, .offset = r.offset, .size = r.size };
            },
            else => {
                self.errors += 1;
                return;
            },
        };
        const gop = try self.handles.getOrPut(self.gpa, key(h.conn_id, h.handle_id));
        if (gop.found_existing) { // handle ids are never reused
            self.errors += 1;
            _ = linux.close(gop.value_ptr.fd);
        }
        gop.value_ptr.* = opened;
    }

    fn handleClose(self: *Engine, conn_id: u32, handle_id: u32) void {
        const kv = self.handles.fetchRemove(key(conn_id, handle_id)) orelse {
            self.errors += 1; // a double close, or a close of a handle never opened
            return;
        };
        _ = linux.close(kv.value.fd);
        self.handles_closed += 1;
    }

    /// CONN_CLOSE: the conn's handles close with it (no HANDLE_CLOSE comes).
    fn dropConn(self: *Engine, conn_id: u32) void {
        scan: while (true) {
            var it = self.handles.iterator();
            while (it.next()) |e| {
                if (@as(u32, @intCast(e.key_ptr.* >> 32)) != conn_id) continue;
                _ = linux.close(e.value_ptr.fd);
                _ = self.handles.remove(e.key_ptr.*);
                self.handles_dropped += 1;
                continue :scan;
            }
            break;
        }
    }

    /// Read the COMMIT's damaged pixels through its handle, as the reference
    /// engine does, then ACK it (also when it is invalid).
    fn commitNotice(self: *Engine, f: stream.CommitFrame) !void {
        defer if (self.auto_ack) self.batch.ack(self.gpa, f.conn_id, f.serial) catch @panic("OOM");
        if (f.kind == @intFromEnum(stream.BufferKind.virtgpu)) return self.gpuCommit(f);
        const ref = f.shm() catch {
            self.errors += 1;
            return;
        };
        try self.commits.append(self.gpa, .{ .conn_id = f.conn_id, .surface_id = f.surface_id, .serial = f.serial, .ref = ref, .n_rects = f.n_rects, .first_rect = f.rectAt(0) });
        const h = self.handles.get(key(f.conn_id, ref.handle_id)) orelse {
            self.errors += 1;
            return;
        };
        if (@as(u64, ref.offset) + ref.span() > h.size) {
            self.errors += 1;
            return;
        }
        const dst = try self.surfaceFor(f.conn_id, f.surface_id, ref.width, ref.height, .handle);
        var i: u32 = 0;
        while (i < f.n_rects) : (i += 1) {
            const r = f.rectAt(i);
            const row_len: usize = @as(usize, @intCast(r.w)) * 4;
            for (0..@intCast(r.h)) |row| {
                const y = @as(usize, @intCast(r.y)) + row;
                const x: usize = @intCast(r.x);
                const at = h.offset + ref.offset + y * ref.stride + x * 4;
                const out = dst[(y * ref.width + x) * 4 ..][0..row_len];
                const n = linux.pread(h.fd, out.ptr, out.len, @intCast(at));
                if (linux.errno(n) != .SUCCESS or n != out.len) self.errors += 1;
            }
        }
    }

    /// A kind-virtgpu COMMIT: record it; with `gpu` set, read the damaged
    /// pixels of the resource it names (its file, at the plane's offset and
    /// stride) — the host renderer's view.
    fn gpuCommit(self: *Engine, f: stream.CommitFrame) !void {
        const ref = f.virtgpu() catch {
            self.errors += 1;
            return;
        };
        try self.gpu_commits.append(self.gpa, .{ .conn_id = f.conn_id, .surface_id = f.surface_id, .serial = f.serial, .ref = ref, .n_rects = f.n_rects, .first_rect = f.rectAt(0) });
        const fake = self.gpu orelse return;
        const fd = fake.resolve(ref.resource) orelse {
            self.errors += 1; // the relay let the resource go under a COMMIT
            return;
        };
        defer _ = linux.close(fd);
        const dst = try self.surfaceFor(f.conn_id, f.surface_id, ref.width, ref.height, .gpu);
        var i: u32 = 0;
        while (i < f.n_rects) : (i += 1) {
            const r = f.rectAt(i);
            const row_len: usize = @as(usize, @intCast(r.w)) * 4;
            for (0..@intCast(r.h)) |row| {
                const y = @as(usize, @intCast(r.y)) + row;
                const x: usize = @intCast(r.x);
                const out = dst[(y * ref.width + x) * 4 ..][0..row_len];
                const n = linux.pread(fd, out.ptr, out.len, @intCast(@as(usize, ref.offset) + y * ref.stride + x * 4));
                if (linux.errno(n) != .SUCCESS or n != out.len) self.errors += 1;
            }
        }
    }

    /// A surface's pixels for a frame of `kind` at `width`×`height`: kept
    /// while both match, otherwise a fresh zeroed copy (what a presenter
    /// shows of a surface whose content changed kind or size is only what
    /// the new frame names).
    fn surfaceFor(self: *Engine, conn_id: u32, surface_id: u32, width: u32, height: u32, kind: ContentKind) ![]u8 {
        const gop = try self.surfaces.getOrPut(self.gpa, key(conn_id, surface_id));
        if (gop.found_existing and gop.value_ptr.width == width and gop.value_ptr.height == height and gop.value_ptr.kind == kind)
            return gop.value_ptr.bytes;
        if (gop.found_existing) self.gpa.free(gop.value_ptr.bytes);
        gop.value_ptr.* = .{ .width = width, .height = height, .bytes = &.{}, .kind = kind };
        gop.value_ptr.bytes = try self.gpa.alloc(u8, @as(usize, width) * height * 4);
        @memset(gop.value_ptr.bytes, 0);
        return gop.value_ptr.bytes;
    }

    /// BUFFER / BUFFER_LZ: the rects' RGBA pixels into the surface, back in
    /// the client's byte order (BGRA).
    fn bufferPixels(self: *Engine, conn_id: u32, surface_id: u32, width: u32, height: u32, n_rects: u32, rect_bytes: []const u8, rgba: []const u8) !void {
        const dst = try self.surfaceFor(conn_id, surface_id, width, height, .buffer);
        var off: usize = 0;
        var i: u32 = 0;
        while (i < n_rects) : (i += 1) {
            const rb = rect_bytes[@as(usize, i) * 16 ..][0..16];
            const x: usize = @intCast(std.mem.readInt(i32, rb[0..4], .little));
            const y0: usize = @intCast(std.mem.readInt(i32, rb[4..8], .little));
            const rw: usize = @intCast(std.mem.readInt(i32, rb[8..12], .little));
            const rh: usize = @intCast(std.mem.readInt(i32, rb[12..16], .little));
            for (0..rh) |row| {
                const y = y0 + row;
                for (0..rw) |col| {
                    const s = rgba[off..][0..4];
                    const d = dst[(y * width + x + col) * 4 ..][0..4];
                    d.* = .{ s[2], s[1], s[0], s[3] };
                    off += 4;
                }
            }
        }
    }

    /// Frames of one type received so far.
    pub fn count(self: *const Engine, frame_type: stream.FrameType) usize {
        var n: usize = 0;
        for (self.frames.items) |f| {
            if (f.type == frame_type) n += 1;
        }
        return n;
    }

    pub fn last(self: *const Engine, frame_type: stream.FrameType) ?Received {
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.frames.items[i].type == frame_type) return self.frames.items[i];
        }
        return null;
    }

    /// Presentation tick: fire the compositor's pending frame callbacks,
    /// end latched presentation feedback.
    pub fn tick(self: *Engine, time_ms: u32) !void {
        try self.tickFrame(.{ .time_ms = time_ms });
    }

    pub fn tickFrame(self: *Engine, t: core.compositor.Compositor.Tick) !void {
        self.comp.tick(t);
        try self.flush();
    }

    fn readRecord(self: *Engine) !void {
        var hdr: [stream.record_header_len]u8 = undefined;
        try readExact(self.fd, &hdr);
        const len = try stream.readRecordHeader(&hdr);
        try self.rx.resize(self.gpa, len);
        try readExact(self.fd, self.rx.items);
        var rest = self.rx.items;
        while (rest.len > 0) {
            const p = try stream.parseNext(rest);
            try self.frames.append(self.gpa, .{ .type = std.meta.activeTag(p.frame), .bytes = try self.gpa.dupe(u8, rest[0..p.consumed]) });
            rest = rest[p.consumed..];
            switch (p.frame) {
                .conn_open => |id| try self.comp.connOpen(id),
                .conn_close => |id| {
                    self.comp.connClose(id);
                    self.dropConn(id);
                },
                .wire => |w| try self.comp.onWire(w.conn_id, w.bytes),
                .fdmsg => |f| if (f.kind == @intFromEnum(stream.FdMsgKind.pipe))
                    self.comp.onPipeReceive(f.conn_id, f.wire_bytes, std.mem.readInt(u32, f.aux[0..4], .little))
                else if (f.kind == @intFromEnum(stream.FdMsgKind.pipe_read))
                    {} // a readSelection's answer: tests read it from `frames`
                else
                    try self.comp.onWire(f.conn_id, f.wire_bytes),
                .buffer => |b| try self.bufferPixels(b.conn_id, b.surface_id, b.width, b.height, b.n_rects, b.rect_bytes, b.pixels),
                .buffer_lz => |b| {
                    const raw = try self.gpa.alloc(u8, b.raw_len);
                    defer self.gpa.free(raw);
                    if ((core.lz4.decompress(b.comp, raw) orelse 0) != raw.len) return error.BadLz4;
                    try self.bufferPixels(b.conn_id, b.surface_id, b.width, b.height, b.n_rects, b.rect_bytes, raw);
                },
                .handle_open => |h| try self.handleOpen(h),
                .handle_close => |h| self.handleClose(h.conn_id, h.handle_id),
                .commit => |cf| try self.commitNotice(cf),
                .feature => |f| {
                    // a malformed one is a relay bug here, not a log line
                    if (f.feature == @intFromEnum(stream.FeatureKind.linux_dmabuf)) _ = try stream.DmabufFeature.decode(f.bytes);
                    if (f.feature == @intFromEnum(stream.FeatureKind.dmabuf_kind)) _ = try stream.DmabufKindFeature.decode(f.bytes);
                    self.comp.applyFeature(f.feature, f.bytes);
                },
                .srvobj, .ack, .dmabuf_created, .presented => return error.UnexpectedFrame, // engine → relay only
            }
        }
        try self.flush();
    }

    /// Send what the compositor queued (after a direct `comp` call).
    pub fn flush(self: *Engine) !void {
        const msg = self.batch.finish();
        if (msg.len == 0) return;
        var hdr: [stream.record_header_len]u8 = undefined;
        stream.writeRecordHeader(&hdr, @intCast(msg.len));
        try writeAll(self.fd, &hdr);
        try writeAll(self.fd, msg);
        self.batch.clear();
    }

    fn sendWire(ctx: ?*anyopaque, conn_id: u32, bytes: []const u8) void {
        const self: *Engine = @ptrCast(@alignCast(ctx.?));
        self.batch.wire(self.gpa, conn_id, bytes) catch @panic("OOM");
    }

    fn sendFdMsg(ctx: ?*anyopaque, conn_id: u32, kind: u32, wire_bytes: []const u8, aux: []const u8) void {
        const self: *Engine = @ptrCast(@alignCast(ctx.?));
        self.batch.fdMsg(self.gpa, conn_id, @enumFromInt(kind), wire_bytes, aux) catch @panic("OOM");
    }

    fn sendSrvObj(ctx: ?*anyopaque, conn_id: u32, object_id: u32, kind: u32) void {
        const self: *Engine = @ptrCast(@alignCast(ctx.?));
        const out = self.batch.frame(self.gpa, stream.srvobj_len) catch @panic("OOM");
        stream.writeSrvObj(out[0..stream.srvobj_len], conn_id, object_id, kind);
    }

    fn sendDmabufCreated(ctx: ?*anyopaque, conn_id: u32, params_id: u32, buffer_id: u32) void {
        const self: *Engine = @ptrCast(@alignCast(ctx.?));
        const out = self.batch.frame(self.gpa, stream.dmabuf_created_len) catch @panic("OOM");
        stream.writeDmabufCreated(out[0..stream.dmabuf_created_len], conn_id, params_id, buffer_id);
    }

    fn sendPresented(ctx: ?*anyopaque, conn_id: u32, age_us: u32, msg: []const u8) void {
        const self: *Engine = @ptrCast(@alignCast(ctx.?));
        self.batch.presented(self.gpa, conn_id, age_us, msg) catch @panic("OOM");
    }

    fn log(ctx: ?*anyopaque, text: []const u8) void {
        _ = ctx;
        _ = text; // the compositor logs every decoded message; too chatty here
    }
};

/// Wait (≤ 5 s) for `fd` to become readable or hung up.
pub fn waitReadable(fd: i32) !void {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const rc = linux.poll(&pfd, 1, timeout_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == 0) error.Timeout else {},
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

/// One record off a raw engine-end fd, for tests that drive links by hand.
pub fn readRecord(gpa: std.mem.Allocator, fd: i32, out: *std.ArrayList(u8)) !void {
    try waitReadable(fd);
    var hdr: [stream.record_header_len]u8 = undefined;
    try readExact(fd, &hdr);
    try out.resize(gpa, try stream.readRecordHeader(&hdr));
    try readExact(fd, out.items);
}

/// Open fds of this process that point at memfd `name` (relay pool fds and
/// handle dups, the engine's handle fds, the test's own memfd).
pub fn countMemfds(name: []const u8) usize {
    var want_buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "/memfd:{s} ", .{name}) catch unreachable;
    var n: usize = 0;
    for (0..1024) |fd| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/self/fd/{d}", .{fd}) catch unreachable;
        var target: [256]u8 = undefined;
        const rc = linux.readlink(path, &target, target.len);
        if (linux.errno(rc) != .SUCCESS) continue;
        if (std.mem.startsWith(u8, target[0..rc], want)) n += 1; // "/memfd:NAME (deleted)"
    }
    return n;
}

pub fn socketpair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    return fds;
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

fn readExact(fd: i32, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                off += rc;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
}
