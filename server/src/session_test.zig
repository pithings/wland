// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Session profile end to end over socketpairs: scripted clients ⇄ the real
//! relay ⇄ the session host (session.zig, the core hosted natively) ⇄
//! scripted viewers on StreamLinks. The test thread plays the clients and
//! the viewers; the relay and the host run their usual threads.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const core = @import("core");
const stream = core.stream;
const shm = @import("shm.zig");
const harness = @import("harness.zig");
const relay_mod = @import("relay.zig");
const Session = @import("session.zig").Session;
const StreamLink = @import("stream_link.zig").StreamLink;
const Client = harness.Client;
const Received = harness.Engine.Received;
const op = harness.op;

const timeout_ms = 5000;

const Viewer = struct {
    gpa: std.mem.Allocator,
    /// [0] the host's end (its StreamLink), [1] the test's
    fds: [2]i32,
    link: StreamLink,
    thread: std.Thread,
    /// every frame received, in order
    frames: std.ArrayList(Received) = .empty,
    /// the host closed the link (a takeover kicked it)
    eof: bool = false,
    joined: bool = false,
    rx: std.ArrayList(u8) = .empty,

    fn call(self: *Viewer, o: stream.CallOp, args: []const u8) !void {
        var buf: [512]u8 = undefined;
        const frame = stream.encodeOpFrame(buf[stream.record_header_len..], .call, @intFromEnum(o), args);
        stream.writeRecordHeader(buf[0..stream.record_header_len], @intCast(frame.len));
        try writeAll(self.fds[1], buf[0 .. stream.record_header_len + frame.len]);
    }

    fn init(self: *Viewer) !void {
        try self.call(.init, &(le(1) ++ le(120)));
    }

    /// One record off the link (it is readable), or eof.
    fn readOne(self: *Viewer) !void {
        harness.readRecord(self.gpa, self.fds[1], &self.rx) catch |err| switch (err) {
            error.EndOfStream => {
                self.eof = true;
                return;
            },
            else => return err,
        };
        var rest = self.rx.items;
        while (rest.len > 0) {
            const p = try stream.parseNext(rest);
            try self.frames.append(self.gpa, .{ .type = std.meta.activeTag(p.frame), .bytes = try self.gpa.dupe(u8, rest[0..p.consumed]) });
            rest = rest[p.consumed..];
        }
    }

    /// Hang up (a page reload) and wait for the host to let go of it.
    fn close(self: *Viewer) void {
        if (self.joined) return;
        _ = linux.shutdown(self.fds[1], linux.SHUT.RDWR);
        self.thread.join();
        self.joined = true;
        _ = linux.close(self.fds[0]);
        _ = linux.close(self.fds[1]);
    }

    fn deinit(self: *Viewer) void {
        self.close();
        for (self.frames.items) |f| self.gpa.free(f.bytes);
        self.frames.deinit(self.gpa);
        self.rx.deinit(self.gpa);
    }

    fn count(self: *const Viewer, t: stream.FrameType) usize {
        var n: usize = 0;
        for (self.frames.items) |f| n += @intFromBool(f.type == t);
        return n;
    }

    /// Index of the first EVENT `o` at or after `from`.
    fn findEvent(self: *const Viewer, from: usize, o: stream.EventOp) ?usize {
        for (self.frames.items[from..], from..) |f, i| {
            if (f.type == .event and f.parse().event.op == @intFromEnum(o)) return i;
        }
        return null;
    }

    fn hasSynced(self: *const Viewer) bool {
        return self.findEvent(0, .synced) != null;
    }
};

fn le(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

const Rig = struct {
    gpa: std.mem.Allocator,
    threaded: Io.Threaded,
    relay: relay_mod.Relay,
    session: *Session,
    clients: [2]Client = undefined,
    app_threads: [2]std.Thread = undefined,
    n_clients: usize = 0,
    viewers: [3]Viewer = undefined,
    n_viewers: usize = 0,

    fn start(self: *Rig, gpa: std.mem.Allocator) !void {
        self.* = .{ .gpa = gpa, .threaded = .init(gpa, .{}), .relay = undefined, .session = undefined };
        const io = self.threaded.io();
        self.relay = .{ .io = io, .gpa = gpa };
        self.session = try Session.create(gpa, io);
        try self.session.start(&self.relay);
    }

    fn connect(self: *Rig) !*Client {
        const fds = try harness.socketpair();
        const c = &self.clients[self.n_clients];
        c.* = .{ .gpa = self.gpa, .fd = fds[1] };
        const app: Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
        self.app_threads[self.n_clients] = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &self.relay, app });
        self.n_clients += 1;
        return c;
    }

    /// A viewer link (WS or stream in real life) handed to the host.
    fn viewer(self: *Rig) !*Viewer {
        const v = &self.viewers[self.n_viewers];
        self.n_viewers += 1;
        v.* = .{ .gpa = self.gpa, .fds = try harness.socketpair(), .link = undefined, .thread = undefined };
        v.link.init(self.threaded.io(), v.fds[0], .engine);
        v.thread = try std.Thread.spawn(.{}, Session.serveViewer, .{ self.session, &v.link.link });
        return v;
    }

    fn stop(self: *Rig) void {
        for (self.viewers[0..self.n_viewers]) |*v| v.deinit();
        self.session.destroy(); // the relay's link goes: every conn is dropped
        for (self.app_threads[0..self.n_clients]) |t| t.join();
        for (self.clients[0..self.n_clients]) |*c| c.deinit();
        self.relay.deinit();
        self.threaded.deinit();
    }

    /// Pump every client and open viewer until `pred` holds (5 s).
    fn until(self: *Rig, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
        const io = self.threaded.io();
        const deadline = Io.Clock.now(.awake, io).toMilliseconds() + timeout_ms;
        while (!pred(ctx)) {
            var pfds: [5]linux.pollfd = undefined;
            var who: [5]?*Viewer = undefined;
            var n: usize = 0;
            for (self.clients[0..self.n_clients]) |c| {
                pfds[n] = .{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 };
                who[n] = null;
                n += 1;
            }
            for (self.viewers[0..self.n_viewers]) |*v| {
                pfds[n] = .{ .fd = if (v.eof or v.joined) -1 else v.fds[1], .events = linux.POLL.IN, .revents = 0 };
                who[n] = v;
                n += 1;
            }
            const left = deadline - Io.Clock.now(.awake, io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            const rc = linux.poll(&pfds, n, @intCast(@min(left, 50)));
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS) return error.PollFailed;
            for (pfds[0..n], who[0..n], 0..) |p, w, i| {
                if (p.revents == 0) continue;
                if (w) |v| try v.readOne() else try self.clients[i].read();
            }
        }
    }

    fn roundtrip(self: *Rig, c: *Client) !void {
        const cb = c.newId();
        try c.send(1, comptime op("wl_display", .request, "sync"), &.{.{ .new_id = cb }});
        const Ctx = struct { c: *Client, cb: u32 };
        try self.until(Ctx{ .c = c, .cb = cb }, struct {
            fn pred(x: Ctx) bool {
                return x.c.count(x.cb, comptime op("wl_callback", .event, "done")) > 0;
            }
        }.pred);
    }

    fn synced(self: *Rig, v: *Viewer) !void {
        try self.until(v, struct {
            fn pred(x: *Viewer) bool {
                return x.hasSynced();
            }
        }.pred);
    }

    /// Pump for `ms` (whatever arrives is recorded).
    fn idle(self: *Rig, ms: i64) !void {
        const io = self.threaded.io();
        const Ctx = struct { io: Io, until: i64 };
        try self.until(Ctx{ .io = io, .until = Io.Clock.now(.awake, io).toMilliseconds() + ms }, struct {
            fn pred(x: Ctx) bool {
                return Io.Clock.now(.awake, x.io).toMilliseconds() >= x.until;
            }
        }.pred);
    }
};

const Window = struct { registry: u32, compositor: u32, shm: u32, surface: u32, toplevel: u32, seat: u32, pointer: u32 };

fn bind(c: *Client, registry: u32, comptime iface: []const u8, version: u32) !u32 {
    const name = c.globalName(registry, iface) orelse return error.MissingGlobal;
    const id = c.newId();
    try c.send(registry, comptime op("wl_registry", .request, "bind"), &.{
        .{ .uint = name },
        .{ .new_id_dynamic = .{ .interface = iface, .version = version, .id = id } },
    });
    return id;
}

fn openWindow(rig: *Rig, c: *Client) !Window {
    const registry = c.newId();
    try c.send(1, comptime op("wl_display", .request, "get_registry"), &.{.{ .new_id = registry }});
    try rig.roundtrip(c);
    var w: Window = .{
        .registry = registry,
        .compositor = try bind(c, registry, "wl_compositor", 6),
        .shm = try bind(c, registry, "wl_shm", 1),
        .surface = undefined,
        .toplevel = undefined,
        .seat = try bind(c, registry, "wl_seat", 5),
        .pointer = undefined,
    };
    w.pointer = c.newId();
    try c.send(w.seat, comptime op("wl_seat", .request, "get_pointer"), &.{.{ .new_id = w.pointer }});
    const wm = try bind(c, registry, "xdg_wm_base", 1);
    w.surface = c.newId();
    try c.send(w.compositor, comptime op("wl_compositor", .request, "create_surface"), &.{.{ .new_id = w.surface }});
    const xdg_surface = c.newId();
    try c.send(wm, comptime op("xdg_wm_base", .request, "get_xdg_surface"), &.{ .{ .new_id = xdg_surface }, .{ .object = w.surface } });
    w.toplevel = c.newId();
    try c.send(xdg_surface, comptime op("xdg_surface", .request, "get_toplevel"), &.{.{ .new_id = w.toplevel }});
    try c.send(w.toplevel, comptime op("xdg_toplevel", .request, "set_title"), &.{.{ .string = "kept" }});
    try c.send(w.surface, comptime op("wl_surface", .request, "commit"), &.{});
    try rig.roundtrip(c);
    const configure = c.last(xdg_surface, comptime op("xdg_surface", .event, "configure")) orelse return error.NoConfigure;
    try c.send(xdg_surface, comptime op("xdg_surface", .request, "ack_configure"), &.{.{ .uint = std.mem.readInt(u32, configure.body[0..4], .little) }});
    return w;
}

/// A 4×2 XRGB buffer (LE words 0x0010_20xx + i → RGBA 10 20 xx+i ff),
/// attached, damaged and committed.
fn present(c: *Client, w: Window, base: u32) !void {
    var pixels: [4 * 2 * 4]u8 = undefined;
    for (0..8) |i| std.mem.writeInt(u32, pixels[i * 4 ..][0..4], 0x0010_2000 + base + @as(u32, @intCast(i)), .little);
    const fd = try shm.createMemfd("session-test", &pixels);
    defer _ = linux.close(fd);
    const pool = c.newId();
    try c.sendFd(w.shm, comptime op("wl_shm", .request, "create_pool"), &.{ .{ .new_id = pool }, .fd, .{ .int = pixels.len } }, fd);
    const buffer = c.newId();
    try c.send(pool, comptime op("wl_shm_pool", .request, "create_buffer"), &.{
        .{ .new_id = buffer }, .{ .int = 0 }, .{ .int = 4 }, .{ .int = 2 }, .{ .int = 16 }, .{ .uint = 1 },
    });
    try c.send(pool, comptime op("wl_shm_pool", .request, "destroy"), &.{});
    try c.send(w.surface, comptime op("wl_surface", .request, "attach"), &.{ .{ .object = buffer }, .{ .int = 0 }, .{ .int = 0 } });
    try c.send(w.surface, comptime op("wl_surface", .request, "damage_buffer"), &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 4 }, .{ .int = 2 } });
    try c.send(w.surface, comptime op("wl_surface", .request, "commit"), &.{});
}

/// The RGBA of a pixel frame (BUFFER, or BUFFER_LZ decoded), with its rects.
fn framePixels(gpa: std.mem.Allocator, f: Received) !struct { b: stream.BufferFrame, px: []u8 } {
    switch (f.parse()) {
        .buffer => |b| return .{ .b = b, .px = try gpa.dupe(u8, b.pixels) },
        .buffer_lz => |b| {
            const px = try gpa.alloc(u8, b.raw_len);
            if ((core.lz4.decompress(b.comp, px) orelse 0) != px.len) return error.BadLz4;
            return .{ .b = .{ .conn_id = b.conn_id, .surface_id = b.surface_id, .width = b.width, .height = b.height, .n_rects = b.n_rects, .rect_bytes = b.rect_bytes, .pixels = px }, .px = px };
        },
        else => return error.NotPixels,
    }
}

fn expectWindowPixels(gpa: std.mem.Allocator, f: Received, surface: u32, base: u8) !void {
    const got = try framePixels(gpa, f);
    defer gpa.free(got.px);
    try std.testing.expectEqual(surface, got.b.surface_id);
    try std.testing.expectEqual(@as(u32, 4), got.b.width);
    try std.testing.expectEqual(@as(u32, 1), got.b.n_rects);
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 4, .h = 2 }, got.b.rectAt(0));
    for (0..8) |i| try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, base + @as(u8, @intCast(i)), 0xff }, got.px[i * 4 ..][0..4]);
}

/// The scene replay after `from`: CONN_OPEN for `conn`, the window's
/// SURFACE (a toplevel) before its surface_event and title, one whole-window
/// pixel frame with `base`'s pixels, synced last.
fn expectReplay(gpa: std.mem.Allocator, v: *const Viewer, from: usize, conn: u32, w: Window, base: u8) !void {
    const frames = v.frames.items;
    const synced = v.findEvent(from, .synced).?;
    try std.testing.expectEqual(frames.len - 1, synced); // nothing after it yet
    var open_at: ?usize = null;
    var surface_at: ?usize = null;
    var pixels_at: ?usize = null;
    var n_pixels: usize = 0;
    for (frames[from..synced], from..) |f, i| switch (f.parse()) {
        .conn_open => |id| if (id == conn) {
            open_at = i;
        },
        .surface => |s| if (s.surface_id == w.surface and surface_at == null) {
            try std.testing.expectEqual(conn, s.conn_id);
            try std.testing.expectEqual(@as(u32, 1), s.role);
            try std.testing.expectEqual(w.surface, s.root);
            try std.testing.expectEqual(@as(i32, 4), s.geom_w);
            surface_at = i;
        },
        .buffer, .buffer_lz => {
            n_pixels += 1;
            pixels_at = i;
            try expectWindowPixels(gpa, f, w.surface, base);
        },
        else => {},
    };
    try std.testing.expect(open_at.? < surface_at.?);
    try std.testing.expectEqual(@as(usize, 1), n_pixels);
    const role_at = v.findEvent(from, .surface_event).?;
    const role = v.frames.items[role_at].parse().event;
    try std.testing.expectEqualSlices(u8, &(le(conn) ++ le(w.surface) ++ le(1)), role.args);
    const title_at = v.findEvent(from, .set_title).?;
    try std.testing.expectEqualSlices(u8, &(le(conn) ++ le(w.surface) ++ le(4) ++ "kept".*), v.frames.items[title_at].parse().event.args);
    try std.testing.expect(surface_at.? < role_at and role_at < title_at and title_at < pixels_at.? and pixels_at.? < synced);
    // the selection (nobody's) and the lock state precede synced
    try std.testing.expect(v.findEvent(from, .selection).? < synced);
    try std.testing.expect(v.findEvent(from, .keyboard_locks_state).? < synced);
}

test "session: FEATURE session first, nothing before init, init replays the scene; a viewer that goes leaves the app connected, the next one gets the scene with the whole current image" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa);
    defer rig.stop();

    // an app runs with no viewer at all: the compositor is the relay's
    const c = try rig.connect();
    const w = try openWindow(&rig, c);
    try present(c, w, 0x30);
    try rig.roundtrip(c);
    const conn: u32 = 1;

    // a viewer: FEATURE session, then nothing (the app keeps committing)
    const a = try rig.viewer();
    try rig.until(a, struct {
        fn pred(v: *Viewer) bool {
            return v.frames.items.len > 0;
        }
    }.pred);
    const feature = a.frames.items[0].parse().feature;
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.session)), feature.feature);
    try std.testing.expectEqual(@as(usize, 8), feature.bytes.len);
    try std.testing.expectEqual(rig.session.session_id, std.mem.readInt(u64, feature.bytes[0..8], .little));
    try present(c, w, 0x40);
    try rig.roundtrip(c);
    try a.call(.pointer_enter, &(le(conn) ++ le(w.surface) ++ le(0) ++ le(0))); // before init: ignored
    try rig.idle(100);
    try std.testing.expectEqual(@as(usize, 1), a.frames.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.count(w.pointer, comptime op("wl_pointer", .event, "enter")));

    // init: the replay, ending in synced, with the latest image
    try a.init();
    try rig.synced(a);
    try expectReplay(gpa, a, 1, conn, w, 0x40);

    // live: a commit's pixels follow, after its surface's SURFACE if changed
    var mark = a.frames.items.len;
    try present(c, w, 0x50);
    try rig.roundtrip(c);
    try rig.until(a, struct {
        fn pred(v: *Viewer) bool {
            return v.count(.buffer) + v.count(.buffer_lz) >= 2;
        }
    }.pred);
    for (a.frames.items[mark..]) |f| {
        if (f.type == .wire or f.type == .fdmsg or f.type == .presented or f.type == .srvobj) return error.RelayFrameLeaked;
    }
    // input reaches the app
    try a.call(.pointer_enter, &(le(conn) ++ le(w.surface) ++ le(256) ++ le(256)));
    const Pc = struct { c: *Client, p: u32, ev: u16 };
    try rig.until(Pc{ .c = c, .p = w.pointer, .ev = comptime op("wl_pointer", .event, "enter") }, struct {
        fn pred(x: Pc) bool {
            return x.c.count(x.p, x.ev) == 1;
        }
    }.pred);
    // read_selection with nothing to read: selection_data status 3
    mark = a.frames.items.len;
    try a.call(.read_selection, &(le(10) ++ "text/plain".* ++ le(7) ++ le(1000)));
    try rig.until(a, struct {
        fn pred(v: *Viewer) bool {
            return v.findEvent(0, .selection_data) != null;
        }
    }.pred);
    try std.testing.expectEqualSlices(u8, &(le(7) ++ le(3) ++ le(0)), a.frames.items[a.findEvent(mark, .selection_data).?].parse().event.args);

    // the viewer goes: the pointer leaves the app, which stays connected
    a.close();
    try rig.until(Pc{ .c = c, .p = w.pointer, .ev = comptime op("wl_pointer", .event, "leave") }, struct {
        fn pred(x: Pc) bool {
            return x.c.count(x.p, x.ev) == 1;
        }
    }.pred);
    try present(c, w, 0x60);
    // frame callbacks still fire (the idle clock)
    const cb = c.newId();
    try c.send(w.surface, comptime op("wl_surface", .request, "frame"), &.{.{ .new_id = cb }});
    try c.send(w.surface, comptime op("wl_surface", .request, "commit"), &.{});
    const Cb = struct { c: *Client, cb: u32 };
    try rig.until(Cb{ .c = c, .cb = cb }, struct {
        fn pred(x: Cb) bool {
            return x.c.count(x.cb, comptime op("wl_callback", .event, "done")) == 1;
        }
    }.pred);
    try rig.roundtrip(c);

    // the next viewer is sent the scene as it is now
    const b = try rig.viewer();
    try rig.until(b, struct {
        fn pred(v: *Viewer) bool {
            return v.frames.items.len > 0;
        }
    }.pred);
    try std.testing.expectEqual(stream.FrameType.feature, b.frames.items[0].type);
    try b.init();
    try rig.synced(b);
    try expectReplay(gpa, b, 1, conn, w, 0x60);
    try rig.roundtrip(c); // still connected
}

test "session: a new viewer takes over — the old one's link is closed, the new one gets the scene; the app never notices" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa);
    defer rig.stop();
    const c = try rig.connect();
    const w = try openWindow(&rig, c);
    try present(c, w, 0x30);
    try rig.roundtrip(c);

    const a = try rig.viewer();
    try a.init();
    try rig.synced(a);
    const b = try rig.viewer();
    try rig.until(a, struct {
        fn pred(v: *Viewer) bool {
            return v.eof;
        }
    }.pred);
    try b.init();
    try rig.synced(b);
    try expectReplay(gpa, b, 1, 1, w, 0x30);
    try rig.roundtrip(c);
    // the app's commits reach the new viewer
    try present(c, w, 0x70);
    try rig.roundtrip(c);
    try rig.until(b, struct {
        fn pred(v: *Viewer) bool {
            return v.count(.buffer) + v.count(.buffer_lz) >= 2;
        }
    }.pred);
}

test "session: an app that leaves goes from the viewer as CONN_CLOSE; one that comes is CONN_OPEN" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa);
    defer rig.stop();
    const a = try rig.viewer();
    try a.init();
    try rig.synced(a);
    try std.testing.expectEqual(@as(usize, 0), a.count(.conn_open));
    const c = try rig.connect();
    _ = try openWindow(&rig, c);
    try rig.until(a, struct {
        fn pred(v: *Viewer) bool {
            return v.count(.surface) >= 1 and v.findEvent(0, .surface_event) != null;
        }
    }.pred);
    try std.testing.expectEqual(@as(usize, 1), a.count(.conn_open));
    c.close();
    try rig.until(a, struct {
        fn pred(v: *Viewer) bool {
            return v.count(.conn_close) == 1;
        }
    }.pred);
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
