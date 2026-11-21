// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! End-to-end relay tests over socketpairs (harness.zig): scripted client ⇄
//! relay ⇄ StreamLink ⇄ native core compositor. No browser, no listener.

const std = @import("std");
const linux = std.os.linux;
const core = @import("core");
const stream = core.stream;
const shm = @import("shm.zig");
const harness = @import("harness.zig");
const relay_mod = @import("relay.zig");
const kwshm = @import("kwshm.zig");
const StreamLink = @import("stream_link.zig").StreamLink;
const Loop = harness.Loop;
const Client = harness.Client;
const op = harness.op;

const xrgb8888: u32 = 1;

/// A mapped xdg_toplevel plus the globals it took to make it.
const Window = struct {
    registry: u32,
    compositor: u32,
    shm: u32,
    surface: u32,
};

fn bind(c: *Client, registry: u32, comptime iface: []const u8, version: u32) !u32 {
    const name = c.globalName(registry, iface) orelse return error.MissingGlobal;
    const id = c.newId();
    try c.send(registry, comptime op("wl_registry", .request, "bind"), &.{
        .{ .uint = name },
        .{ .new_id_dynamic = .{ .interface = iface, .version = version, .id = id } },
    });
    return id;
}

/// Registry round trip, globals, and the xdg-shell configure handshake.
fn openWindow(loop: *Loop, c: *Client) !Window {
    const registry = c.newId();
    try c.send(1, comptime op("wl_display", .request, "get_registry"), &.{.{ .new_id = registry }});
    try loop.roundtrip(c);
    try std.testing.expect(c.count(registry, comptime op("wl_registry", .event, "global")) >= 3);

    const w: Window = .{
        .registry = registry,
        .compositor = try bind(c, registry, "wl_compositor", 6),
        .shm = try bind(c, registry, "wl_shm", 1),
        .surface = undefined,
    };
    const wm = try bind(c, registry, "xdg_wm_base", 1);
    var win = w;
    win.surface = c.newId();
    try c.send(w.compositor, comptime op("wl_compositor", .request, "create_surface"), &.{.{ .new_id = win.surface }});
    const xdg_surface = c.newId();
    try c.send(wm, comptime op("xdg_wm_base", .request, "get_xdg_surface"), &.{ .{ .new_id = xdg_surface }, .{ .object = win.surface } });
    try c.send(xdg_surface, comptime op("xdg_surface", .request, "get_toplevel"), &.{.{ .new_id = c.newId() }});
    try c.send(win.surface, comptime op("wl_surface", .request, "commit"), &.{});
    try loop.roundtrip(c);
    const configure = c.last(xdg_surface, comptime op("xdg_surface", .event, "configure")) orelse return error.NoConfigure;
    const serial = std.mem.readInt(u32, configure.body[0..4], .little);
    try c.send(xdg_surface, comptime op("xdg_surface", .request, "ack_configure"), &.{.{ .uint = serial }});
    return win;
}

/// wl_shm.create_pool over a real memfd (SCM_RIGHTS) + one buffer filling it.
/// Returns the buffer id; the memfd stays open for pixel edits (caller closes).
fn shmBuffer(c: *Client, w: Window, pixels: []const u8, width: i32, height: i32, fd_out: *i32) !u32 {
    const fd = try shm.createMemfd("relay-test", pixels);
    fd_out.* = fd;
    const pool = c.newId();
    try c.sendFd(w.shm, comptime op("wl_shm", .request, "create_pool"), &.{ .{ .new_id = pool }, .fd, .{ .int = @intCast(pixels.len) } }, fd);
    const buffer = c.newId();
    try c.send(pool, comptime op("wl_shm_pool", .request, "create_buffer"), &.{
        .{ .new_id = buffer }, .{ .int = 0 }, .{ .int = width }, .{ .int = height }, .{ .int = width * 4 }, .{ .uint = xrgb8888 },
    });
    // clients destroy the pool right away; buffers keep its storage alive
    try c.send(pool, comptime op("wl_shm_pool", .request, "destroy"), &.{});
    return buffer;
}

fn damageAll(c: *Client, surface: u32, w: i32, h: i32) !void {
    try c.send(surface, comptime op("wl_surface", .request, "damage_buffer"), &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = w }, .{ .int = h } });
}

fn attach(c: *Client, surface: u32, buffer: u32) !void {
    try c.send(surface, comptime op("wl_surface", .request, "attach"), &.{ .{ .object = buffer }, .{ .int = 0 }, .{ .int = 0 } });
}

fn commit(c: *Client, surface: u32) !void {
    try c.send(surface, comptime op("wl_surface", .request, "commit"), &.{});
}

const release_ev = op("wl_buffer", .event, "release");
const done_ev = op("wl_callback", .event, "done");
const delete_id_ev = op("wl_display", .event, "delete_id");
const presented_ev = op("wp_presentation_feedback", .event, "presented");

/// Every frame received by the engine since `from`, BUFFER frames only.
fn bufferFramesSince(loop: *Loop, from: usize) usize {
    var n: usize = 0;
    for (loop.engine.frames.items[from..]) |f| {
        if (f.type == .buffer or f.type == .buffer_lz) n += 1;
    }
    return n;
}

test "loop: registry, memfd pool, commit ships BUFFER after its WIRE, release exactly once, engine-paced frame done" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .frame_callbacks = .engine });
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    // 4×2 XRGB, LE words 0x00_10_20_(30+i) → canvas-ready RGBA 10 20 30+i ff
    var pixels: [4 * 2 * 4]u8 = undefined;
    for (0..8) |i| std.mem.writeInt(u32, pixels[i * 4 ..][0..4], 0x0010_2030 + @as(u32, @intCast(i)), .little);
    var memfd: i32 = -1;
    defer _ = linux.close(memfd);
    const buffer = try shmBuffer(c, w, &pixels, 4, 2, &memfd);

    const cb = c.newId();
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 2);
    try c.send(w.surface, comptime op("wl_surface", .request, "frame"), &.{.{ .new_id = cb }});
    const frames_before = loop.engine.frames.items.len;
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.count(.fdmsg)); // the pool, as FDMSG

    // exactly one BUFFER, full rect, swizzled pixels, right after a WIRE frame
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, frames_before));
    const frames = loop.engine.frames.items;
    var bi: usize = frames_before;
    while (frames[bi].type != .buffer) bi += 1;
    try std.testing.expectEqual(stream.FrameType.wire, frames[bi - 1].type);
    const bf = frames[bi].parse().buffer;
    try std.testing.expectEqual(w.surface, bf.surface_id);
    try std.testing.expectEqual(@as(u32, 4), bf.width);
    try std.testing.expectEqual(@as(u32, 2), bf.height);
    try std.testing.expectEqual(@as(u32, 1), bf.n_rects);
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 4, .h = 2 }, bf.rectAt(0));
    for (0..8) |i|
        try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30 + @as(u8, @intCast(i)), 0xff }, bf.pixels[i * 4 ..][0..4]);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));

    // engine-paced: the request reached the compositor; done waits for its tick
    try std.testing.expectEqual(@as(usize, 0), c.count(cb, done_ev));
    try loop.engine.tick(1234);
    const Ctx = struct { c: *Client, cb: u32 };
    try loop.until(Ctx{ .c = c, .cb = cb }, struct {
        fn pred(x: Ctx) bool {
            return x.c.count(x.cb, done_ev) == 1 and x.c.count(1, delete_id_ev) > 0;
        }
    }.pred);
    try std.testing.expectEqual(@as(u32, 1234), std.mem.readInt(u32, c.last(cb, done_ev).?.body[0..4], .little));

    // a commit WITHOUT attach (GTK's empty frame) owes no release, and
    // re-damaging unchanged pixels ships nothing (shadow trim)
    const before_noattach = loop.engine.frames.items.len;
    try damageAll(c, w.surface, 4, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
    try std.testing.expectEqual(@as(usize, 0), bufferFramesSince(&loop, before_noattach));

    // change one pixel (col 2, row 1), re-attach with full damage: one more
    // release, and the BUFFER is trimmed to that pixel
    const px = [_]u8{ 0xaa, 0xbb, 0xcc, 0x00 };
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pwrite(memfd, &px, px.len, 1 * 16 + 2 * 4)));
    const before_trim = loop.engine.frames.items.len;
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 2), c.count(buffer, release_ev));
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, before_trim));
    const t = loop.engine.last(.buffer).?.parse().buffer;
    try std.testing.expectEqual(stream.Rect{ .x = 2, .y = 1, .w = 1, .h = 1 }, t.rectAt(0));
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xbb, 0xaa, 0xff }, t.pixels);
}

test "loop: relay-paced frame callbacks fire without the engine, never twice, and survive surface destroy" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .frame_callbacks = .relay });
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    const frame_op = comptime op("wl_surface", .request, "frame");
    const cb = c.newId();
    try c.send(w.surface, frame_op, &.{.{ .new_id = cb }});
    try commit(c, w.surface); // no buffer attached: still owes the callback
    const Ctx = struct { c: *Client, cb: u32 };
    const fired = struct {
        fn pred(x: Ctx) bool {
            return x.c.count(x.cb, done_ev) > 0;
        }
    }.pred;
    try loop.until(Ctx{ .c = c, .cb = cb }, fired);
    // the engine never saw the request: its tick fires nothing
    try loop.engine.tick(1);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(cb, done_ev));

    // a surface destroyed before its next commit still gets done+delete_id
    const cb2 = c.newId();
    try c.send(w.surface, frame_op, &.{.{ .new_id = cb2 }});
    try c.send(w.surface, comptime op("wl_surface", .request, "destroy"), &.{});
    try loop.until(Ctx{ .c = c, .cb = cb2 }, fired);
}

test "loop: a buffer past its pool is released unshown; after wl_shm_pool.resize it ships" {
    std.testing.log_level = .err; // the relay warns about the bad buffer
    defer std.testing.log_level = .warn;
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    // memfd holds 64 B, but the pool starts at 32: a 2×2 buffer at offset 32
    // lies entirely past the pool's end until it grows
    var pixels: [64]u8 = undefined;
    for (0..16) |i| std.mem.writeInt(u32, pixels[i * 4 ..][0..4], 0x0001_0203 * @as(u32, @intCast(i)), .little);
    const fd = try shm.createMemfd("relay-resize", &pixels);
    defer _ = linux.close(fd);
    const pool = c.newId();
    try c.sendFd(w.shm, comptime op("wl_shm", .request, "create_pool"), &.{ .{ .new_id = pool }, .fd, .{ .int = 32 } }, fd);
    const buffer = c.newId();
    try c.send(pool, comptime op("wl_shm_pool", .request, "create_buffer"), &.{
        .{ .new_id = buffer }, .{ .int = 32 }, .{ .int = 2 }, .{ .int = 2 }, .{ .int = 8 }, .{ .uint = xrgb8888 },
    });
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev)); // not withheld
    try std.testing.expectEqual(@as(usize, 0), bufferFramesSince(&loop, 0));

    try c.send(pool, comptime op("wl_shm_pool", .request, "resize"), &.{.{ .int = 64 }});
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 2), c.count(buffer, release_ev));
    const bf = (loop.engine.last(.buffer) orelse return error.NoBuffer).parse().buffer;
    try std.testing.expectEqual(@as(u32, 2), bf.width);
    // first pixel of the buffer = word 8 of the memfd = 0x00081018 → RGBA 08 10 18 ff
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x10, 0x18, 0xff }, bf.pixels[0..4]);
}

test "loop: a pool larger than its file, or a file truncated under a buffer, is released unshown (no SIGBUS); grown back it ships" {
    std.testing.log_level = .err; // the relay warns about the unreadable buffer
    defer std.testing.log_level = .warn;
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const page = std.heap.pageSize();

    // the pool claims 4 pages, the memfd holds 65 bytes: a buffer on page 2
    // lies wholly past the end of the file
    var head: [65]u8 = @splat(0x11);
    const fd = try shm.createMemfd("relay-lying-pool", head[0..64]);
    defer _ = linux.close(fd);
    const pool = try createPool(c, w, fd, @intCast(4 * page));
    const b1 = try createBuffer(c, pool, @intCast(2 * page), 2, 2, 8);
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c); // the relay survived the commit
    try std.testing.expectEqual(@as(usize, 1), c.count(b1, release_ev));
    try std.testing.expectEqual(@as(usize, 0), bufferFramesSince(&loop, 0));

    // the file grows to cover the pool: the same buffer now ships, read
    // through a fresh mapping (word 0 = 0x00303030 → RGBA 30 30 30 ff)
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, @intCast(4 * page))));
    const px = [_]u8{0x30} ** 16;
    try std.testing.expectEqual(px.len, linux.pwrite(fd, &px, px.len, @intCast(2 * page)));
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 2), c.count(b1, release_ev));
    const bf = (loop.engine.last(.buffer) orelse return error.NoBuffer).parse().buffer;
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 2, .h = 2 }, bf.rectAt(0));
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x30, 0x30, 0xff }, bf.pixels[0..4]);

    // an honest pool whose file the client truncates afterwards
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, 1)));
    const shown = bufferFramesSince(&loop, 0);
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 3), c.count(b1, release_ev));
    try std.testing.expectEqual(shown, bufferFramesSince(&loop, 0));

    // ...and grows it back, zero-filled: the zero pages the faulted read
    // saw must not count as shown (the engine still shows 0x30s), so the
    // next commit ships in full rather than being trimmed away
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, @intCast(4 * page))));
    try attach(c, w.surface, b1);
    try damage(c, w.surface, 0, 0, 1, 1);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 4), c.count(b1, release_ev));
    try std.testing.expectEqual(shown + 1, bufferFramesSince(&loop, 0));
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 2, .h = 2 }, loop.engine.last(.buffer).?.parse().buffer.rectAt(0));
}

test "loop: a destroyed buffer's id, reused, is never presented or released through the surface it was attached to" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    var mem: [3 * 2 * 2 * 4]u8 = undefined;
    for (&mem, 0..) |*b, i| b.* = @intCast(i / 16 + 1); // buffer k's bytes are k+1
    const fd = try shm.createMemfd("relay-reuse", &mem);
    defer _ = linux.close(fd);
    const pool = try createPool(c, w, fd, mem.len);
    const destroy_op = comptime op("wl_buffer", .request, "destroy");

    // after the commit: attach B (id X), commit, destroy B, X reused by an
    // unrelated buffer; a commit WITHOUT attach presents nothing new
    const x = try createBuffer(c, pool, 0, 2, 2, 8);
    try attach(c, w.surface, x);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try c.send(x, destroy_op, &.{});
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, 0));
    try c.send(pool, comptime op("wl_shm_pool", .request, "create_buffer"), &.{
        .{ .new_id = x }, .{ .int = 16 }, .{ .int = 2 }, .{ .int = 2 }, .{ .int = 8 }, .{ .uint = xrgb8888 },
    });
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, 0));
    try std.testing.expectEqual(@as(usize, 1), c.count(x, release_ev)); // the first B's, nothing for the new X

    // before the commit: attach Y, destroy it, reuse its id, commit — the
    // pending attach is of no buffer (libwayland: attach(NULL)); the new
    // buffer is neither shown nor owed a release
    const y = try createBuffer(c, pool, 32, 2, 2, 8);
    try attach(c, w.surface, y);
    try c.send(y, destroy_op, &.{});
    try loop.roundtrip(c);
    try c.send(pool, comptime op("wl_shm_pool", .request, "create_buffer"), &.{
        .{ .new_id = y }, .{ .int = 16 }, .{ .int = 2 }, .{ .int = 2 }, .{ .int = 8 }, .{ .uint = xrgb8888 },
    });
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, 0));
    try std.testing.expectEqual(@as(usize, 0), c.count(y, release_ev));

    // attaching the reused id for real works as ever
    try attach(c, w.surface, y);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 2), bufferFramesSince(&loop, 0));
    try std.testing.expectEqual(@as(usize, 1), c.count(y, release_ev));
}

test "loop: wl_surface.damage on a surface with a viewport or a buffer transform damages the whole buffer" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    var pixels: [4 * 4 * 4]u8 = @splat(0x10);
    var memfd: i32 = -1;
    defer _ = linux.close(memfd);
    const buffer = try shmBuffer(c, w, &pixels, 4, 4, &memfd);
    const surface_damage = comptime op("wl_surface", .request, "damage");

    // a 4x4 buffer shown at 2x2 surface px: surface damage (0,0,1,1) covers
    // buffer (0,0,2,2) — scaling by the buffer scale alone gets (0,0,1,1)
    const viewporter = try bind(c, w.registry, "wp_viewporter", 1);
    const viewport = c.newId();
    try c.send(viewporter, comptime op("wp_viewporter", .request, "get_viewport"), &.{ .{ .new_id = viewport }, .{ .object = w.surface } });
    try c.send(viewport, comptime op("wp_viewport", .request, "set_destination"), &.{ .{ .int = 2 }, .{ .int = 2 } });
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 4);
    try commit(c, w.surface);
    try loop.roundtrip(c);

    const px = [_]u8{ 0xaa, 0xbb, 0xcc, 0x00 };
    for ([_]u32{ 1, 3 }) |at| { // (1,1), then (3,3) with a buffer transform instead
        if (at == 3) {
            try c.send(viewport, comptime op("wp_viewport", .request, "destroy"), &.{});
            try c.send(w.surface, comptime op("wl_surface", .request, "set_buffer_transform"), &.{.{ .int = 1 }}); // 90°
        }
        try std.testing.expectEqual(@as(usize, 4), linux.pwrite(memfd, &px, 4, @intCast(at * 16 + at * 4)));
        try attach(c, w.surface, buffer);
        try c.send(w.surface, surface_damage, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } });
        const before = bufferFramesSince(&loop, 0);
        try commit(c, w.surface);
        try loop.roundtrip(c);
        try std.testing.expectEqual(before + 1, bufferFramesSince(&loop, 0));
        const bf = loop.engine.last(.buffer).?.parse().buffer;
        try std.testing.expectEqual(stream.Rect{ .x = @intCast(at), .y = @intCast(at), .w = 1, .h = 1 }, bf.rectAt(0));
    }
}

test "loop: large compressible commit ships a decodable BUFFER_LZ" {
    const gpa = std.testing.allocator;
    var loop: Loop = undefined;
    try loop.start(gpa, .{});
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    // 64×64 flat XRGB 0x40404040 → 0xff404040; 16 KiB, compresses hard
    const flat = [_]u8{0x40} ** (64 * 64 * 4);
    var memfd: i32 = -1;
    defer _ = linux.close(memfd);
    const buffer = try shmBuffer(c, w, &flat, 64, 64, &memfd);
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 64, 64);
    try commit(c, w.surface);
    try loop.roundtrip(c);

    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
    const f = (loop.engine.last(.buffer_lz) orelse return error.NoBufferLz).parse().buffer_lz;
    try std.testing.expectEqual(@as(u32, 64 * 64 * 4), f.raw_len);
    try std.testing.expect(f.comp.len < f.raw_len);
    const raw = try gpa.alloc(u8, f.raw_len);
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(?usize, f.raw_len), core.lz4.decompress(f.comp, raw));
    for (0..f.raw_len / 4) |i|
        try std.testing.expectEqual(@as(u32, 0xff40_4040), std.mem.readInt(u32, raw[i * 4 ..][0..4], .little));
}

test "loop: keymap FDMSG from the engine reaches the app as a real fd" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    const registry = c.newId();
    try c.send(1, comptime op("wl_display", .request, "get_registry"), &.{.{ .new_id = registry }});
    try loop.roundtrip(c);
    const seat = try bind(c, registry, "wl_seat", 5);
    const keyboard = c.newId();
    try c.send(seat, comptime op("wl_seat", .request, "get_keyboard"), &.{.{ .new_id = keyboard }});
    try loop.roundtrip(c);

    const ev = c.last(keyboard, comptime op("wl_keyboard", .event, "keymap")) orelse return error.NoKeymap;
    const fd = c.fds.pop() orelse return error.NoKeymapFd;
    defer _ = linux.close(fd);
    const size = std.mem.readInt(u32, ev.body[4..8], .little); // format, (fd), size
    const text = core.compositor.keymap_text;
    try std.testing.expectEqual(@as(u32, text.len + 1), size);
    var buf: [64]u8 = undefined;
    const n = linux.pread(fd, &buf, buf.len, 0);
    try std.testing.expectEqualStrings(text[0..buf.len], buf[0..n]);
}

test "an app waits for an engine; a new link takes over and drops the old link's conns" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var relay: relay_mod.Relay = .{ .io = io, .gpa = gpa };
    defer relay.deinit();
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);

    // the app connects first and waits (no engine yet)
    const app1 = try harness.socketpair();
    defer _ = linux.close(app1[1]);
    const app1_thread = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &relay, appStream(app1[0]) });

    const a = try harness.socketpair();
    defer _ = linux.close(a[0]);
    defer _ = linux.close(a[1]);
    var link_a: StreamLink = undefined;
    link_a.init(io, a[0], .engine);
    const a_thread = try std.Thread.spawn(.{}, relay_mod.serveLink, .{ &relay, &link_a.link });
    try harness.readRecord(gpa, a[1], &rec);
    try std.testing.expectEqual(@as(u32, 1), (try stream.parse(rec.items)).conn_open);

    // link B attaches: A is kicked (its engine sees EOF), A's app is hung up
    const b = try harness.socketpair();
    defer _ = linux.close(b[0]);
    defer _ = linux.close(b[1]);
    var link_b: StreamLink = undefined;
    link_b.init(io, b[0], .engine);
    const b_thread = try std.Thread.spawn(.{}, relay_mod.serveLink, .{ &relay, &link_b.link });
    a_thread.join(); // returns only after app1's thread let go of link A
    app1_thread.join();
    try std.testing.expectError(error.EndOfStream, harness.readRecord(gpa, a[1], &rec));
    var byte: [1]u8 = undefined;
    try harness.waitReadable(app1[1]);
    try std.testing.expectEqual(@as(usize, 0), linux.read(app1[1], &byte, 1)); // hung up

    // new apps land on B, with a fresh conn id
    const app2 = try harness.socketpair();
    defer _ = linux.close(app2[1]);
    const app2_thread = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &relay, appStream(app2[0]) });
    try harness.readRecord(gpa, b[1], &rec);
    try std.testing.expectEqual(@as(u32, 2), (try stream.parse(rec.items)).conn_open);

    link_b.link.kick();
    b_thread.join();
    app2_thread.join();
}

fn appStream(fd: i32) std.Io.net.Stream {
    return .{ .socket = .{ .handle = fd, .address = undefined } };
}

// ---------------------------------------------------------------------------
// Handle backends (procfd; kwshm via kwshm.fake): HANDLE_OPEN / COMMIT /
// ACK / HANDLE_CLOSE and the
// deferred-release ledger (STREAM.md "Buffer handles", "Buffer release").
// ---------------------------------------------------------------------------

/// conn_id of a Loop's first client
const conn1: u32 = 1;

fn createPool(c: *Client, w: Window, fd: i32, size: i32) !u32 {
    const pool = c.newId();
    try c.sendFd(w.shm, comptime op("wl_shm", .request, "create_pool"), &.{ .{ .new_id = pool }, .fd, .{ .int = size } }, fd);
    return pool;
}

fn createBuffer(c: *Client, pool: u32, offset: i32, width: i32, height: i32, stride: i32) !u32 {
    const buffer = c.newId();
    try c.send(pool, comptime op("wl_shm_pool", .request, "create_buffer"), &.{
        .{ .new_id = buffer }, .{ .int = offset }, .{ .int = width }, .{ .int = height }, .{ .int = stride }, .{ .uint = xrgb8888 },
    });
    return buffer;
}

/// A memfd named `name` holding `buf`, filled first with byte i = 7i + 3.
fn patternMemfd(name: [*:0]const u8, buf: []u8) !i32 {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    const rc = linux.memfd_create(name, linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.MemfdFailed;
    const fd: i32 = @intCast(rc);
    if (linux.pwrite(fd, buf.ptr, buf.len, 0) != buf.len) return error.WriteFailed;
    return fd;
}

fn damage(c: *Client, surface: u32, x: i32, y: i32, w: i32, h: i32) !void {
    try c.send(surface, comptime op("wl_surface", .request, "damage_buffer"), &.{ .{ .int = x }, .{ .int = y }, .{ .int = w }, .{ .int = h } });
}

fn framesSince(loop: *Loop, from: usize, t: stream.FrameType) usize {
    var n: usize = 0;
    for (loop.engine.frames.items[from..]) |f| {
        if (f.type == t) n += 1;
    }
    return n;
}

/// Every HANDLE_OPEN is matched by exactly one HANDLE_CLOSE or conn drop (or
/// is still open), and the relay never named a handle the engine lacked.
fn expectHandlesBalanced(loop: *Loop) !void {
    const e = &loop.engine;
    try std.testing.expectEqual(@as(usize, 0), e.errors);
    try std.testing.expectEqual(e.handles_opened, e.handles_closed + e.handles_dropped + e.handles.count());
}

/// The engine's copy of a surface equals the client's buffer rows.
fn expectPixels(loop: *Loop, conn_id: u32, surface: u32, mem: []const u8, offset: usize, width: u32, height: u32, stride: usize) !void {
    const px = loop.engine.pixels(conn_id, surface) orelse return error.NoPixels;
    try std.testing.expectEqual(width, px.width);
    try std.testing.expectEqual(height, px.height);
    for (0..height) |y|
        try std.testing.expectEqualSlices(u8, mem[offset + y * stride ..][0 .. width * 4], px.bytes[y * width * 4 ..][0 .. width * 4]);
}

fn waitReleases(loop: *Loop, c: *Client, buffer: u32, n: usize) !void {
    const Ctx = struct { c: *Client, buffer: u32, n: usize };
    try loop.until(Ctx{ .c = c, .buffer = buffer, .n = n }, struct {
        fn pred(x: Ctx) bool {
            return x.c.count(x.buffer, release_ev) >= x.n;
        }
    }.pred);
    try std.testing.expectEqual(n, c.count(buffer, release_ev));
}

test "handles: pixels read through a procfd handle match the client's; release waits for the ACK, once per attach" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .backend = .procfd });
    defer loop.stop();
    loop.engine.auto_ack = false;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    // a 4×3 buffer with a padded stride, NOT page aligned: the handle starts
    // at the page floor, the COMMIT offset is the remainder
    const page = std.heap.pageSize();
    const offset = page + 64;
    const stride = 20;
    const len = offset + 3 * stride;
    const mem = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(mem);
    const fd = try patternMemfd("wland-h-pixels", mem);
    defer _ = linux.close(fd);
    const pool = try createPool(c, w, fd, @intCast(len));
    const buffer = try createBuffer(c, pool, @intCast(offset), 4, 3, stride);
    try c.send(pool, comptime op("wl_shm_pool", .request, "destroy"), &.{});

    const from = loop.engine.frames.items.len;
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 3);
    try commit(c, w.surface);
    try loop.settle(c);

    // HANDLE_OPEN then COMMIT, both after the commit's WIRE, in one message
    try std.testing.expectEqual(@as(usize, 1), framesSince(&loop, from, .handle_open));
    try std.testing.expectEqual(@as(usize, 1), framesSince(&loop, from, .commit));
    try std.testing.expectEqual(@as(usize, 0), framesSince(&loop, from, .buffer));
    const frames = loop.engine.frames.items;
    var ci: usize = from;
    while (frames[ci].type != .commit) ci += 1;
    try std.testing.expectEqual(stream.FrameType.handle_open, frames[ci - 1].type);
    try std.testing.expectEqual(stream.FrameType.wire, frames[ci - 2].type);
    const ho = frames[ci - 1].parse().handle_open;
    const ph = try stream.ProcfdHandle.decode(ho.bytes);
    try std.testing.expectEqual(conn1, ho.conn_id);
    try std.testing.expectEqual(@as(u64, page), ph.offset);
    try std.testing.expectEqual(@as(u64, 64 + 3 * stride), ph.size);

    const seen = loop.engine.commits.items[0];
    try std.testing.expectEqual(@as(u32, 1), seen.serial);
    try std.testing.expectEqual(ho.handle_id, seen.ref.handle_id);
    try std.testing.expectEqual(@as(u32, 64), seen.ref.offset);
    try std.testing.expectEqual(@as(u32, stride), seen.ref.stride);
    try std.testing.expectEqual(xrgb8888, seen.ref.format);
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 4, .h = 3 }, seen.first_rect);
    try expectPixels(&loop, conn1, w.surface, mem, offset, 4, 3, stride);

    // withheld until the ACK; then exactly one
    try std.testing.expectEqual(@as(usize, 0), c.count(buffer, release_ev));
    try loop.engine.ack(conn1, 1);
    try waitReleases(&loop, c, buffer, 1);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));

    // commit WITHOUT attach but with damage: a COMMIT (busy) that owes nothing
    try damage(c, w.surface, 1, 1, 1, 1);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.commits.items.len);
    try loop.engine.ack(conn1, 2);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
    // ...and with neither attach nor damage: nothing at all
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.commits.items.len);

    // the client redraws one pixel (col 2, row 1) and re-attaches: the
    // engine reads the new bytes through the same handle
    const px = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    @memcpy(mem[offset + stride + 8 ..][0..4], &px);
    try std.testing.expectEqual(@as(usize, 4), linux.pwrite(fd, &px, 4, @intCast(offset + stride + 8)));
    try attach(c, w.surface, buffer);
    try damage(c, w.surface, 2, 1, 1, 1);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.handles_opened); // one handle per wl_buffer
    try std.testing.expectEqual(stream.Rect{ .x = 2, .y = 1, .w = 1, .h = 1 }, loop.engine.commits.items[2].first_rect);
    try expectPixels(&loop, conn1, w.surface, mem, offset, 4, 3, stride);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
    try loop.engine.ack(conn1, 3);
    try waitReleases(&loop, c, buffer, 2);

    // fds on the memfd: the test's, the relay's pool fd (the buffer holds
    // the pool), the handle's dup, the engine's handle fd
    try std.testing.expectEqual(@as(usize, 4), harness.countMemfds("wland-h-pixels"));
    // destroy with nothing un-ACKed: HANDLE_CLOSE now, every relay fd gone
    try c.send(buffer, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.handles_closed);
    try std.testing.expectEqual(@as(usize, 1), harness.countMemfds("wland-h-pixels"));
    try std.testing.expectEqual(@as(usize, 2), c.count(buffer, release_ev));
    try expectHandlesBalanced(&loop);
}

test "handles: re-attach + commit before the earlier ACK gets one release per busy period; stray ACKs are ignored" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .backend = .procfd });
    defer loop.stop();
    loop.engine.auto_ack = false;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    var pixels: [4 * 4 * 4]u8 = undefined;
    @memset(&pixels, 0x5a);
    var memfd: i32 = -1;
    defer _ = linux.close(memfd);
    const buffer = try shmBuffer(c, w, &pixels, 4, 4, &memfd);

    // two attach-latching commits of B, neither ACKed yet
    for (0..2) |_| {
        try attach(c, w.surface, buffer);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface);
    }
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.commits.items.len);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.handles_opened);

    try loop.engine.ack(conn1, 1); // B still busy with serial 2
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 0), c.count(buffer, release_ev));
    try loop.engine.ack(conn1, 2); // idle: ONE release for both
    try waitReleases(&loop, c, buffer, 1);

    // duplicate, never-sent and unknown-conn ACKs change nothing
    try loop.engine.ack(conn1, 2);
    try loop.engine.ack(conn1, 999);
    try loop.engine.ack(conn1 + 7, 1);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));

    // ACKs in reverse order: the release waits for the last one
    for (0..2) |_| {
        try attach(c, w.surface, buffer);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface);
    }
    try loop.settle(c);
    try loop.engine.ack(conn1, 4);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
    try loop.engine.ack(conn1, 3);
    try waitReleases(&loop, c, buffer, 2);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), c.count(buffer, release_ev));
    try std.testing.expectEqual(@as(usize, 0), loop.engine.handles_closed); // B lives
    try expectHandlesBalanced(&loop);
}

test "handles: wl_buffer.destroy before the ACK: no release ever, HANDLE_CLOSE after the ACK, a reused id starts clean" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .backend = .procfd });
    defer loop.stop();
    loop.engine.auto_ack = false;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    var mem: [2 * 8 * 8 * 4]u8 = undefined;
    const fd = try patternMemfd("wland-h-destroy", &mem);
    defer _ = linux.close(fd);
    const pool = try createPool(c, w, fd, mem.len);
    const buffer = try createBuffer(c, pool, 0, 8, 8, 32);

    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 8, 8);
    try commit(c, w.surface); // serial 1
    try c.send(buffer, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.settle(c); // the engine has sent delete_id: the id is free
    try std.testing.expectEqual(@as(usize, 0), loop.engine.handles_closed); // the COMMIT holds it

    // the client reuses the id for a new buffer (second half of the pool)
    // and commits it (serial 2) before the old COMMIT is ACKed
    try c.send(pool, comptime op("wl_shm_pool", .request, "create_buffer"), &.{
        .{ .new_id = buffer }, .{ .int = 8 * 8 * 4 }, .{ .int = 8 }, .{ .int = 8 }, .{ .int = 32 }, .{ .uint = xrgb8888 },
    });
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 8, 8);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.handles_opened);
    try expectPixels(&loop, conn1, w.surface, &mem, 8 * 8 * 4, 8, 8, 32);

    // the OLD COMMIT's ACK: closes the old handle, releases nothing (the
    // new buffer is busy with serial 2, the old one is forgotten)
    try loop.engine.ack(conn1, 1);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.handles_closed);
    try std.testing.expectEqual(@as(usize, 0), c.count(buffer, release_ev));
    try loop.engine.ack(conn1, 2);
    try waitReleases(&loop, c, buffer, 1);
    try expectHandlesBalanced(&loop);
    // the test's fd + the relay's pool fd + the live handle's dup + the engine's
    try std.testing.expectEqual(@as(usize, 4), harness.countMemfds("wland-h-destroy"));
}

test "handles: conn close with un-ACKed COMMITs drops everything — no HANDLE_CLOSE, no fds left, late ACKs ignored" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .backend = .procfd });
    defer loop.stop();
    loop.engine.auto_ack = false;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    var mem: [2 * 4 * 4 * 4]u8 = undefined;
    const fd = try patternMemfd("wland-h-close", &mem);
    defer _ = linux.close(fd);
    const pool = try createPool(c, w, fd, mem.len);
    const b1 = try createBuffer(c, pool, 0, 4, 4, 16);
    const b2 = try createBuffer(c, pool, 64, 4, 4, 16);
    for ([_]u32{ b1, b2 }) |b| {
        try attach(c, w.surface, b);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface);
    }
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.handles_opened);
    // the test's fd, the relay's pool fd, two dups, two engine fds
    try std.testing.expectEqual(@as(usize, 6), harness.countMemfds("wland-h-close"));

    const closes = loop.engine.count(.conn_close);
    c.close();
    const Ctx = struct { e: *harness.Engine, n: usize };
    try loop.until(Ctx{ .e = &loop.engine, .n = closes }, struct {
        fn pred(x: Ctx) bool {
            return x.e.count(.conn_close) > x.n;
        }
    }.pred);
    try std.testing.expectEqual(@as(usize, 0), loop.engine.count(.handle_close));
    try std.testing.expectEqual(@as(usize, 2), loop.engine.handles_dropped);
    // the relay tore the conn down before CONN_CLOSE: only the test's fd is left
    try std.testing.expectEqual(@as(usize, 1), harness.countMemfds("wland-h-close"));

    // the engine still ACKs what it received; the relay ignores them and
    // keeps serving new apps
    try loop.engine.ack(conn1, 1);
    try loop.engine.ack(conn1, 2);
    loop.engine.auto_ack = true;
    const c2 = try loop.connect();
    const w2 = try openWindow(&loop, c2);
    var px2: [4]u8 = .{ 1, 2, 3, 4 };
    var memfd2: i32 = -1;
    defer _ = linux.close(memfd2);
    const b3 = try shmBuffer(c2, w2, &px2, 1, 1, &memfd2);
    try attach(c2, w2.surface, b3);
    try damageAll(c2, w2.surface, 1, 1);
    try commit(c2, w2.surface);
    try waitReleases(&loop, c2, b3, 1);
    try expectPixels(&loop, conn1 + 1, w2.surface, &px2, 0, 1, 1, 4);
    try std.testing.expectEqual(@as(usize, 0), loop.engine.count(.handle_close));
    try expectHandlesBalanced(&loop);
}

test "handles: a buffer past its pool is released unshown; after wl_shm_pool.resize it and a buffer beyond the old size ship" {
    std.testing.log_level = .err; // the relay warns about the bad buffer
    defer std.testing.log_level = .warn;
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .backend = .procfd });
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    // memfd holds 96 B, the pool starts at 32: a 2×2 buffer at offset 32 lies
    // past the pool's end until it grows
    var mem: [96]u8 = undefined;
    const fd = try patternMemfd("wland-h-resize", &mem);
    defer _ = linux.close(fd);
    const pool = try createPool(c, w, fd, 32);
    const b1 = try createBuffer(c, pool, 32, 2, 2, 8);
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface);
    try waitReleases(&loop, c, b1, 1); // at commit time, no ACK involved
    try std.testing.expectEqual(@as(usize, 0), loop.engine.count(.handle_open));
    try std.testing.expectEqual(@as(usize, 0), loop.engine.count(.commit));

    try c.send(pool, comptime op("wl_shm_pool", .request, "resize"), &.{.{ .int = 96 }});
    try attach(c, w.surface, b1);
    try damage(c, w.surface, 0, 0, 1, 1);
    try commit(c, w.surface);
    try waitReleases(&loop, c, b1, 2);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.count(.handle_open));
    // the unshown commit zeroed the latched dims: this one is full again
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 2, .h = 2 }, loop.engine.commits.items[0].first_rect);
    try std.testing.expectEqual(@as(u32, 32), loop.engine.commits.items[0].ref.offset);
    try expectPixels(&loop, conn1, w.surface, &mem, 32, 2, 2, 8);

    // a buffer created after the resize, beyond the old size
    const b2 = try createBuffer(c, pool, 64, 2, 4, 8);
    try attach(c, w.surface, b2);
    try damageAll(c, w.surface, 2, 4);
    try commit(c, w.surface);
    try waitReleases(&loop, c, b2, 1);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.count(.handle_open));
    try expectPixels(&loop, conn1, w.surface, &mem, 64, 2, 4, 8);
    try loop.settle(c);
    try expectHandlesBalanced(&loop);
}

test "handles (kwshm): ids via kwshm.fake; export released after HANDLE_CLOSE went out, refused export unshown, conn close releases all" {
    std.testing.log_level = .err; // the relay warns about the refused export
    defer std.testing.log_level = .warn;
    const fake = kwshm.fake;
    // any open fd stands in for /dev/kwshm: the ioctls go to the fake
    const dev: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    defer _ = linux.close(dev);
    const base = fake.live();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .backend = .{ .kwshm = dev } });
    defer loop.stop();
    loop.engine.auto_ack = false;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    // as the procfd test: not page aligned, the export starts at the floor
    const page = std.heap.pageSize();
    const offset = page + 64;
    const stride = 20;
    const len = offset + 3 * stride;
    const mem = try std.testing.allocator.alloc(u8, len + 2 * 4 * 4);
    defer std.testing.allocator.free(mem);
    const fd = try patternMemfd("wland-h-kwshm", mem);
    defer _ = linux.close(fd);
    const pool = try createPool(c, w, fd, @intCast(mem.len));
    const b1 = try createBuffer(c, pool, @intCast(offset), 4, 3, stride);

    const from = loop.engine.frames.items.len;
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 4, 3);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), framesSince(&loop, from, .handle_open));
    var hi: usize = from;
    while (loop.engine.frames.items[hi].type != .handle_open) hi += 1;
    const ho = loop.engine.frames.items[hi].parse().handle_open;
    try std.testing.expectEqual(@as(u32, 1), ho.kind); // the wire value unkernel's page decodes
    const kh = try stream.KwshmHandle.decode(ho.bytes);
    try std.testing.expectEqual(@as(u64, 64 + 3 * stride), kh.size);
    try std.testing.expectEqual(base + 1, fake.live());
    try std.testing.expectEqual(@as(u32, 64), loop.engine.commits.items[0].ref.offset);
    try expectPixels(&loop, conn1, w.surface, mem, offset, 4, 3, stride);

    // release waits for the ACK; destroy then closes the handle, and the
    // export goes once the HANDLE_CLOSE has been written
    try std.testing.expectEqual(@as(usize, 0), c.count(b1, release_ev));
    try loop.engine.ack(conn1, 1);
    try waitReleases(&loop, c, b1, 1);
    try c.send(b1, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.handles_closed);
    try std.testing.expectEqual(base, fake.live());
    try std.testing.expect(fake.resolve(kh.id) == null);

    // the device refuses (EINVAL, e.g. a pool on a disk file): no handle,
    // released at commit time, never retried for that buffer
    const b2 = try createBuffer(c, pool, @intCast(len), 2, 4, 8);
    fake.failNext(.INVAL);
    try attach(c, w.surface, b2);
    try damageAll(c, w.surface, 2, 4);
    try commit(c, w.surface);
    try waitReleases(&loop, c, b2, 1);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.handles_opened);
    try std.testing.expectEqual(@as(usize, 1), loop.engine.commits.items.len);
    try std.testing.expectEqual(base, fake.live());

    // an un-ACKed COMMIT, then the app hangs up: its export goes with it
    const b3 = try createBuffer(c, pool, 0, 4, 4, 16);
    try attach(c, w.surface, b3);
    try damageAll(c, w.surface, 4, 4);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(base + 1, fake.live());
    const closes = loop.engine.count(.conn_close);
    c.close();
    const Ctx = struct { e: *harness.Engine, n: usize };
    try loop.until(Ctx{ .e = &loop.engine, .n = closes }, struct {
        fn pred(x: Ctx) bool {
            return x.e.count(.conn_close) > x.n;
        }
    }.pred);
    try std.testing.expectEqual(base, fake.live());
    try expectHandlesBalanced(&loop);
}

test "copy backend: stray ACKs from the engine are ignored" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    var px: [4]u8 = .{ 1, 2, 3, 4 };
    var memfd: i32 = -1;
    defer _ = linux.close(memfd);
    const buffer = try shmBuffer(c, w, &px, 1, 1, &memfd);
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 1, 1);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
    try loop.engine.ack(conn1, 1);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
}

test "SRVOBJ flags: dropped with their offer's destroy, never recorded for a closed conn" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    try loop.roundtrip(c);
    const primary: u32 = @intFromEnum(stream.SrvObjKind.primary_offer);
    const offer = core.objects.server_id_base + 3;

    // flagged, then destroyed by the client: the flag goes with it
    try loop.engine.srvObj(conn1, offer, primary);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), loop.relay.primary_offers.count());
    try c.send(offer, comptime op("zwp_primary_selection_offer_v1", .request, "destroy"), &.{});
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 0), loop.relay.primary_offers.count());

    // a SRVOBJ that crosses the conn's CONN_CLOSE: not recorded (nothing
    // would ever remove it)
    const closes = loop.engine.count(.conn_close);
    c.close();
    const Ctx = struct { e: *harness.Engine, n: usize };
    try loop.until(Ctx{ .e = &loop.engine, .n = closes }, struct {
        fn pred(x: Ctx) bool {
            return x.e.count(.conn_close) > x.n;
        }
    }.pred);
    try loop.engine.srvObj(conn1, offer + 1, primary);
    const c2 = try loop.connect();
    try loop.roundtrip(c2); // the link thread handled the SRVOBJ before this reply
    try std.testing.expectEqual(@as(usize, 0), loop.relay.primary_offers.count());
}

// ---------------------------------------------------------------------------
// linux-dmabuf (memfds stand in for dmabufs: no /dev/dri here; the readback
// backend treats a memfd like a LINEAR dmabuf, DMA_BUF_IOCTL_SYNC → ENOTTY)
// ---------------------------------------------------------------------------

const dmabuf = @import("dmabuf.zig");
const readback: dmabuf.Config = .{ .backend = .readback, .main_device = 0xe280 };

/// create_params + add(memfd as plane 0, LINEAR); returns the params id.
fn dmabufParams(c: *Client, dm: u32, fd: i32, stride: u32) !u32 {
    const params = c.newId();
    try c.send(dm, comptime op("zwp_linux_dmabuf_v1", .request, "create_params"), &.{.{ .new_id = params }});
    try c.sendFd(params, comptime op("zwp_linux_buffer_params_v1", .request, "add"), &.{
        .fd, .{ .uint = 0 }, .{ .uint = 0 }, .{ .uint = stride }, .{ .uint = 0 }, .{ .uint = 0 },
    }, fd);
    return params;
}

fn dmabufImmed(c: *Client, params: u32, w: i32, h: i32, format: u32) !u32 {
    const buffer = c.newId();
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "create_immed"), &.{
        .{ .new_id = buffer }, .{ .int = w }, .{ .int = h }, .{ .uint = format }, .{ .uint = 0 },
    });
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "destroy"), &.{});
    return buffer;
}

test "dmabuf: FEATURE first, global + feedback with a real format-table fd; create_immed from a memfd ships swizzled BUFFERs, one release per attach, fds closed on destroy" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = readback });
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    try std.testing.expectEqual(stream.FrameType.feature, loop.engine.frames.items[0].type);

    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    const fb = c.newId();
    try c.send(dm, comptime op("zwp_linux_dmabuf_v1", .request, "get_default_feedback"), &.{.{ .new_id = fb }});
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(fb, comptime op("zwp_linux_dmabuf_feedback_v1", .event, "done")));
    const ft = c.last(fb, comptime op("zwp_linux_dmabuf_feedback_v1", .event, "format_table")).?;
    try std.testing.expectEqual(@as(u32, 32), std.mem.readInt(u32, ft.body[0..4], .little));
    const table_fd = c.fds.pop().?; // the only fd sent to this client
    defer _ = linux.close(table_fd);
    var table: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 32), linux.pread(table_fd, &table, table.len, 0));
    try std.testing.expectEqual(dmabuf.fourcc_argb8888, std.mem.readInt(u32, table[0..4], .little));
    try std.testing.expectEqual(dmabuf.fourcc_xrgb8888, std.mem.readInt(u32, table[16..20], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, table[24..32], .little)); // LINEAR
    const dev = c.last(fb, comptime op("zwp_linux_dmabuf_feedback_v1", .event, "main_device")).?;
    try std.testing.expectEqual(@as(u64, 0xe280), std.mem.readInt(u64, dev.body[4..12], .little));

    // 4×2 XRGB, stride 16: LE words 0x00_10_20_(30+i)
    var pixels: [32]u8 = undefined;
    for (0..8) |i| std.mem.writeInt(u32, pixels[i * 4 ..][0..4], 0x0010_2030 + @as(u32, @intCast(i)), .little);
    const memfd = try shm.createMemfd("relay-dmabuf", &pixels);
    defer _ = linux.close(memfd);
    const params = try dmabufParams(c, dm, memfd, 16);
    const buffer = try dmabufImmed(c, params, 4, 2, dmabuf.fourcc_xrgb8888);
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 2);
    const before = loop.engine.frames.items.len;
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FdMsgKind.dmabuf)), loop.engine.last(.fdmsg).?.parse().fdmsg.kind);
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, before));
    const bf = loop.engine.last(.buffer).?.parse().buffer;
    try std.testing.expectEqual(w.surface, bf.surface_id);
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 4, .h = 2 }, bf.rectAt(0));
    for (0..8) |i|
        try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30 + @as(u8, @intCast(i)), 0xff }, bf.pixels[i * 4 ..][0..4]);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));

    // the GPU draws again (one pixel), the client re-attaches: trimmed BUFFER, one more release
    const px = [_]u8{ 0xaa, 0xbb, 0xcc, 0x00 };
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pwrite(memfd, &px, px.len, 1 * 16 + 2 * 4)));
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 2), c.count(buffer, release_ev));
    const t = loop.engine.last(.buffer).?.parse().buffer;
    try std.testing.expectEqual(stream.Rect{ .x = 2, .y = 1, .w = 1, .h = 1 }, t.rectAt(0));
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xbb, 0xaa, 0xff }, t.pixels);

    // the relay holds the plane fd and the readback mapping's dup; destroy closes both
    try std.testing.expectEqual(@as(usize, 3), harness.countMemfds("relay-dmabuf"));
    try c.send(buffer, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), harness.countMemfds("relay-dmabuf"));
    try std.testing.expectEqual(@as(usize, 2), c.count(buffer, release_ev));
}

test "dmabuf: params.create gets a server-id wl_buffer the relay tracks (DMABUF_CREATED); ARGB alpha passes; params destroyed unused closes its fds" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = readback });
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);

    var pixels: [16]u8 = undefined; // 2×2 ARGB, premultiplied, alpha 0x80
    for (0..4) |i| std.mem.writeInt(u32, pixels[i * 4 ..][0..4], 0x8010_2030 + @as(u32, @intCast(i)), .little);
    const memfd = try shm.createMemfd("relay-dmabuf-create", &pixels);
    defer _ = linux.close(memfd);
    const params = try dmabufParams(c, dm, memfd, 8);
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "create"), &.{
        .{ .int = 2 }, .{ .int = 2 }, .{ .uint = dmabuf.fourcc_argb8888 }, .{ .uint = 0 },
    });
    try loop.roundtrip(c);
    const created = c.last(params, comptime op("zwp_linux_buffer_params_v1", .event, "created")) orelse return error.NotCreated;
    const buffer = std.mem.readInt(u32, created.body[0..4], .little);
    try std.testing.expect(buffer >= core.objects.server_id_base);
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "destroy"), &.{});

    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 2, 2);
    const before = loop.engine.frames.items.len;
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, before));
    const bf = loop.engine.last(.buffer).?.parse().buffer;
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 0x80 }, bf.pixels[0..4]);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));
    try c.send(buffer, comptime op("wl_buffer", .request, "destroy"), &.{});

    // planes added, then the params destroyed without a create: fds go too
    const unused = try dmabufParams(c, dm, memfd, 8);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 2), harness.countMemfds("relay-dmabuf-create"));
    try c.send(unused, comptime op("zwp_linux_buffer_params_v1", .request, "destroy"), &.{});
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), harness.countMemfds("relay-dmabuf-create"));
}

test "dmabuf: a buffer past its fd's end, or truncated under the relay, is released unshown (no SIGBUS)" {
    std.testing.log_level = .err; // the relay warns about both
    defer std.testing.log_level = .warn;
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = readback });
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);

    // 4×2 at stride 16 needs 32 bytes; this fd has 17
    var short: [16]u8 = @splat(0x40);
    const short_fd = try shm.createMemfd("relay-dmabuf-short", &short);
    defer _ = linux.close(short_fd);
    const b1 = try dmabufImmed(c, try dmabufParams(c, dm, short_fd, 16), 4, 2, dmabuf.fourcc_xrgb8888);
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 4, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(b1, release_ev));
    try std.testing.expectEqual(@as(usize, 0), bufferFramesSince(&loop, 0));

    // a readable one, shown once; then its file shrinks to nothing
    var pixels: [32]u8 = @splat(0x50);
    const fd = try shm.createMemfd("relay-dmabuf-trunc", &pixels);
    defer _ = linux.close(fd);
    const b2 = try dmabufImmed(c, try dmabufParams(c, dm, fd, 16), 4, 2, dmabuf.fourcc_xrgb8888);
    try attach(c, w.surface, b2);
    try damageAll(c, w.surface, 4, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, 0));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, 0)));
    try attach(c, w.surface, b2);
    try damageAll(c, w.surface, 4, 2);
    try commit(c, w.surface);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 2), c.count(b2, release_ev));
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, 0));
}

test "dmabuf: without a backend the global is absent, and a client adding a plane anyway is dropped with its fd closed" {
    std.testing.log_level = .err; // the relay warns as it drops the conn
    defer std.testing.log_level = .warn;
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    try std.testing.expectEqual(@as(?u32, null), c.globalName(w.registry, "zwp_linux_dmabuf_v1"));
    try std.testing.expectEqual(@as(usize, 0), loop.engine.count(.feature));

    // bound by name regardless: the compositor answers with a protocol error
    // (which may lose the race), the relay drops the conn at the first fd it
    // was never meant to take
    const dm = c.newId();
    try c.send(w.registry, comptime op("wl_registry", .request, "bind"), &.{
        .{ .uint = core.compositor.dmabuf_global.name },
        .{ .new_id_dynamic = .{ .interface = "zwp_linux_dmabuf_v1", .version = 4, .id = dm } },
    });
    var pixels: [16]u8 = @splat(0);
    const memfd = try shm.createMemfd("relay-dmabuf-off", &pixels);
    defer _ = linux.close(memfd);
    _ = try dmabufParams(c, dm, memfd, 8);
    try std.testing.expectError(error.EndOfStream, loop.until(c, struct {
        fn pred(_: *Client) bool {
            return false;
        }
    }.pred));
    // the plane fd was closed before the conn went (only the test's own is left)
    try std.testing.expectEqual(@as(usize, 1), harness.countMemfds("relay-dmabuf-off"));
}

test "loop: presentation feedback passes the relay stamped on CLOCK_MONOTONIC less the frame's age, on both link kinds" {
    const discarded_ev = op("wp_presentation_feedback", .event, "discarded");
    const sync_ev = op("wp_presentation_feedback", .event, "sync_output");
    for ([_]@import("link.zig").Link.FrameCallbacks{ .engine, .relay }) |fc| {
        var loop: Loop = undefined;
        try loop.start(std.testing.allocator, .{ .frame_callbacks = fc });
        defer loop.stop();
        const c = try loop.connect();
        const w = try openWindow(&loop, c);
        const output = try bind(c, w.registry, "wl_output", 4);
        const pres = try bind(c, w.registry, "wp_presentation", 3);
        try loop.roundtrip(c);
        const clock = c.last(pres, comptime op("wp_presentation", .event, "clock_id")) orelse return error.NoClockId;
        try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, clock.body[0..4], .little)); // CLOCK_MONOTONIC

        var pixels: [2 * 2 * 4]u8 = @splat(0x40);
        var memfd: i32 = -1;
        defer _ = linux.close(memfd);
        const buffer = try shmBuffer(c, w, &pixels, 2, 2, &memfd);
        const fb = c.newId();
        try c.send(pres, comptime op("wp_presentation", .request, "feedback"), &.{ .{ .object = w.surface }, .{ .new_id = fb } });
        try attach(c, w.surface, buffer);
        try damageAll(c, w.surface, 2, 2);
        try commit(c, w.surface);
        try loop.roundtrip(c);
        try std.testing.expectEqual(@as(usize, 0), c.count(fb, presented_ev)); // waits for the frame

        // the frame began 200 ms before the tick: the relay dates it so
        const age_ns: i96 = 200 * std.time.ns_per_ms;
        const io = loop.threaded.io();
        const before = std.Io.Clock.now(.awake, io).nanoseconds;
        try loop.engine.tickFrame(.{ .time_ms = 7, .age_us = 200_000, .refresh_ns = 16_666_667, .vsync = true });
        const Ctx = struct { c: *Client, fb: u32 };
        try loop.until(Ctx{ .c = c, .fb = fb }, struct {
            fn pred(x: Ctx) bool {
                return x.c.count(x.fb, presented_ev) == 1 and x.c.count(1, delete_id_ev) > 0;
            }
        }.pred);
        const after = std.Io.Clock.now(.awake, io).nanoseconds;
        const p = c.last(fb, presented_ev).?.body;
        const word = struct {
            fn at(b: []const u8, i: usize) u32 {
                return std.mem.readInt(u32, b[i * 4 ..][0..4], .little);
            }
        }.at;
        const stamped: i96 = (@as(i96, word(p, 0)) << 32 | word(p, 1)) * std.time.ns_per_s + word(p, 2);
        try std.testing.expect(word(p, 2) < std.time.ns_per_s);
        try std.testing.expect(stamped >= before - age_ns and stamped <= after - age_ns);
        try std.testing.expectEqual(@as(u32, 16_666_667), word(p, 3));
        try std.testing.expectEqual(@as(u32, 0), word(p, 4)); // no vblank counter
        try std.testing.expectEqual(@as(u32, 0), word(p, 5));
        try std.testing.expectEqual(@as(u32, 1), word(p, 6)); // vsync
        // sync_output for the bound wl_output came first
        try std.testing.expectEqual(@as(usize, 1), c.count(fb, sync_ev));
        try std.testing.expectEqual(output, std.mem.readInt(u32, c.last(fb, sync_ev).?.body[0..4], .little));
        var order: [2]u16 = undefined;
        var n: usize = 0;
        for (c.events.items) |e| {
            if (e.object_id != fb) continue;
            order[n] = e.opcode;
            n += 1;
        }
        try std.testing.expectEqualSlices(u16, &.{ sync_ev, presented_ev }, order[0..n]);

        // superseded before a frame: discarded, which the relay passes as is
        const fb2 = c.newId();
        try c.send(pres, comptime op("wp_presentation", .request, "feedback"), &.{ .{ .object = w.surface }, .{ .new_id = fb2 } });
        try commit(c, w.surface);
        try commit(c, w.surface);
        try loop.roundtrip(c);
        try std.testing.expectEqual(@as(usize, 1), c.count(fb2, discarded_ev));
        try std.testing.expectEqual(@as(usize, 0), c.count(fb2, presented_ev));
    }
}
