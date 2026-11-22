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
    try harness.readRecord(gpa, a[1], &rec); // first on every link: what the relay can do
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.selection_cache)), (try stream.parse(rec.items)).feature.feature);
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
    try std.testing.expectEqual(stream.FrameType.feature, std.meta.activeTag(try stream.parse(rec.items)));
    try harness.readRecord(gpa, b[1], &rec);
    try std.testing.expectEqual(@as(u32, 2), (try stream.parse(rec.items)).conn_open);

    link_b.link.kick();
    b_thread.join();
    app2_thread.join();
}

test "on demand: an app asks for the dial; a failed dial refuses every app waiting for it, the next app asks again; a link takes the apps waiting" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var relay: relay_mod.Relay = .{ .io = io, .gpa = gpa, .on_demand = .{ .link_text = "unix:/test" } };
    defer relay.deinit();
    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    var byte: [1]u8 = undefined;

    // the first app wakes the dial thread
    const app1 = try harness.socketpair();
    defer _ = linux.close(app1[1]);
    const app1_thread = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &relay, appStream(app1[0]) });
    relay_mod.awaitDemand(&relay);
    // a second app arrives while that dial is under way: it waits on it
    const app2 = try harness.socketpair();
    defer _ = linux.close(app2[1]);
    const app2_thread = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &relay, appStream(app2[0]) });
    while (true) { // (counted under the mutex)
        relay.mutex.lockUncancelable(io);
        const n = relay.on_demand.?.waiting;
        relay.mutex.unlock(io);
        if (n == 2) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // the dial fails: both are closed at once, and nobody waits any more
    relay_mod.dialFailed(&relay, error.ConnectionRefused);
    app1_thread.join();
    app2_thread.join();
    for ([_]i32{ app1[1], app2[1] }) |fd| {
        try harness.waitReadable(fd);
        try std.testing.expectEqual(@as(usize, 0), linux.read(fd, &byte, 1)); // hung up
    }
    try std.testing.expectEqual(@as(u32, 0), relay.on_demand.?.waiting);
    try std.testing.expectEqual(@as(u32, 1), relay.on_demand.?.failures);

    // the next app asks again; this dial connects: the link takes it on
    const app3 = try harness.socketpair();
    defer _ = linux.close(app3[1]);
    const app3_thread = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &relay, appStream(app3[0]) });
    relay_mod.awaitDemand(&relay);
    const l = try harness.socketpair();
    defer _ = linux.close(l[0]);
    defer _ = linux.close(l[1]);
    var link: StreamLink = undefined;
    link.init(io, l[0], .engine);
    const link_thread = try std.Thread.spawn(.{}, relay_mod.serveLink, .{ &relay, &link.link });
    try harness.readRecord(gpa, l[1], &rec);
    try std.testing.expectEqual(stream.FrameType.feature, std.meta.activeTag(try stream.parse(rec.items)));
    try harness.readRecord(gpa, l[1], &rec);
    try std.testing.expectEqual(@as(u32, 1), (try stream.parse(rec.items)).conn_open); // conn ids start at 1: refused apps took none
    // an app connecting while the link is up needs no dial
    const app4 = try harness.socketpair();
    defer _ = linux.close(app4[1]);
    const app4_thread = try std.Thread.spawn(.{}, relay_mod.serveApp, .{ &relay, appStream(app4[0]) });
    try harness.readRecord(gpa, l[1], &rec);
    try std.testing.expectEqual(@as(u32, 2), (try stream.parse(rec.items)).conn_open);
    relay.mutex.lockUncancelable(io);
    try std.testing.expectEqual(@as(u32, 0), relay.on_demand.?.waiting); // app3 counted itself out
    relay.mutex.unlock(io);

    // the link drops: its apps are dropped, nobody waits (the dial thread idles)
    link.link.kick();
    link_thread.join();
    app3_thread.join();
    app4_thread.join();
    try std.testing.expectEqual(@as(u32, 0), relay.on_demand.?.waiting);
    try std.testing.expectEqual(@as(u32, 1), relay.on_demand.?.failures);
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

/// The last FDMSG pipe_read answer the engine received: read id, status,
/// bytes (a slice of the frame).
fn lastPipeRead(loop: *Loop) ?struct { id: u32, status: u32, bytes: []const u8 } {
    var i = loop.engine.frames.items.len;
    while (i > 0) {
        i -= 1;
        const f = loop.engine.frames.items[i];
        if (f.type != .fdmsg) continue;
        const m = f.parse().fdmsg;
        if (m.kind != @intFromEnum(stream.FdMsgKind.pipe_read) or m.aux.len < 8) continue;
        return .{ .id = std.mem.readInt(u32, m.aux[0..4], .little), .status = std.mem.readInt(u32, m.aux[4..8], .little), .bytes = m.aux[8..] };
    }
    return null;
}

fn waitPipeRead(loop: *Loop, id: u32) !void {
    const Ctx = struct { loop: *Loop, id: u32 };
    try loop.until(Ctx{ .loop = loop, .id = id }, struct {
        fn pred(x: Ctx) bool {
            const r = lastPipeRead(x.loop) orelse return false;
            return r.id == x.id;
        }
    }.pred);
}

/// Serve the next wl_data_source.send the client got: write `text` into its
/// fd and close it (wl-copy's part).
fn serveSend(loop: *Loop, c: *Client, source: u32, text: []const u8) !void {
    const send_ev = comptime op("wl_data_source", .event, "send");
    const before = c.count(source, send_ev);
    const Ctx = struct { c: *Client, source: u32, n: usize };
    try loop.until(Ctx{ .c = c, .source = source, .n = before }, struct {
        fn pred(x: Ctx) bool {
            return x.c.count(x.source, comptime op("wl_data_source", .event, "send")) > x.n;
        }
    }.pred);
    const fd = c.fds.pop() orelse return error.NoSendFd;
    defer _ = linux.close(fd);
    _ = linux.write(fd, text.ptr, text.len);
}

/// A wl-copy shaped source on conn `conn_id` offering text/plain: like
/// wl-copy, a window that takes keyboard focus and sets the selection with
/// its enter's serial (a client without focus is ignored); focus goes again.
fn copyClient(loop: *Loop, conn_id: u32) !struct { c: *Client, source: u32 } {
    const c1 = try loop.connect();
    const w1 = try openWindow(loop, c1);
    const seat1 = try bind(c1, w1.registry, "wl_seat", 5);
    const ddm1 = try bind(c1, w1.registry, "wl_data_device_manager", 3);
    const kbd1 = c1.newId();
    try c1.send(seat1, comptime op("wl_seat", .request, "get_keyboard"), &.{.{ .new_id = kbd1 }});
    const source = c1.newId();
    try c1.send(ddm1, comptime op("wl_data_device_manager", .request, "create_data_source"), &.{.{ .new_id = source }});
    try c1.send(source, comptime op("wl_data_source", .request, "offer"), &.{.{ .string = "text/plain" }});
    const dev1 = c1.newId();
    try c1.send(ddm1, comptime op("wl_data_device_manager", .request, "get_data_device"), &.{ .{ .new_id = dev1 }, .{ .object = seat1 } });
    try loop.roundtrip(c1);
    loop.engine.comp.keyboardEnter(conn_id, w1.surface);
    try loop.engine.flush();
    try loop.roundtrip(c1);
    while (c1.fds.pop()) |fd| _ = linux.close(fd); // the keymap
    const enter = c1.last(kbd1, comptime op("wl_keyboard", .event, "enter")) orelse return error.NoEnter;
    try c1.send(dev1, comptime op("wl_data_device", .request, "set_selection"), &.{ .{ .object = source }, .{ .uint = std.mem.readInt(u32, enter.body[0..4], .little) } });
    try loop.roundtrip(c1);
    loop.engine.comp.keyboardLeave(conn_id);
    try loop.engine.flush();
    return .{ .c = c1, .source = source };
}

test "clipboard bridge: the engine reads a client's selection through a relay pipe (bounded); its own selection is written into a focused client's pipe" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();

    // conn 1: a wl-copy shaped source offering text/plain
    const src1 = try copyClient(&loop, 1);
    const c1 = src1.c;
    const source = src1.source;

    // the engine reads it: the source gets send(mime, fd), the bytes come back
    try std.testing.expect(loop.engine.comp.readSelection("text/plain", 7, 1024));
    try loop.engine.flush();
    try serveSend(&loop, c1, source, "from the app");
    try waitPipeRead(&loop, 7);
    var r = lastPipeRead(&loop).?;
    try std.testing.expectEqual(@intFromEnum(stream.PipeReadStatus.ok), r.status);
    try std.testing.expectEqualStrings("from the app", r.bytes);
    // over the engine's bound: too_large, no bytes
    try std.testing.expect(loop.engine.comp.readSelection("text/plain", 8, 4));
    try loop.engine.flush();
    try serveSend(&loop, c1, source, "from the app");
    try waitPipeRead(&loop, 8);
    r = lastPipeRead(&loop).?;
    try std.testing.expectEqual(@intFromEnum(stream.PipeReadStatus.too_large), r.status);
    try std.testing.expectEqual(@as(usize, 0), r.bytes.len);

    // conn 2: a focused window with a data device
    const c2 = try loop.connect();
    const w = try openWindow(&loop, c2);
    const seat2 = try bind(c2, w.registry, "wl_seat", 5);
    const ddm2 = try bind(c2, w.registry, "wl_data_device_manager", 3);
    try c2.send(seat2, comptime op("wl_seat", .request, "get_keyboard"), &.{.{ .new_id = c2.newId() }});
    const dev2 = c2.newId();
    try c2.send(ddm2, comptime op("wl_data_device_manager", .request, "get_data_device"), &.{ .{ .new_id = dev2 }, .{ .object = seat2 } });
    try loop.roundtrip(c2);
    loop.engine.comp.keyboardEnter(2, w.surface);
    try loop.engine.flush();
    try loop.roundtrip(c2);
    // its fds so far (the keymap) are not the test's
    while (c2.fds.pop()) |fd| _ = linux.close(fd);

    // the engine's own selection: offered to conn 2, cancelling conn 1's source
    var pack: [64]u8 = undefined;
    const mime = "text/plain;charset=utf-8";
    const text = "from the page";
    std.mem.writeInt(u32, pack[0..4], mime.len, .little);
    @memcpy(pack[4..][0..mime.len], mime);
    std.mem.writeInt(u32, pack[4 + mime.len ..][0..4], text.len, .little);
    @memcpy(pack[8 + mime.len ..][0..text.len], text);
    try loop.engine.comp.setOwnSelection(pack[0 .. 8 + mime.len + text.len]);
    try loop.engine.flush();
    try loop.roundtrip(c2);
    try loop.roundtrip(c1);
    try std.testing.expectEqual(@as(usize, 1), c1.count(source, comptime op("wl_data_source", .event, "cancelled")));
    const sel = c2.last(dev2, comptime op("wl_data_device", .event, "selection")) orelse return error.NoSelection;
    const offer = std.mem.readInt(u32, sel.body[0..4], .little);
    try std.testing.expect(offer >= core.objects.server_id_base);

    // receive: the relay writes the core's bytes into the pipe, then closes it
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds[0]);
    try c2.sendFd(offer, comptime op("wl_data_offer", .request, "receive"), &.{ .{ .string = mime }, .fd }, fds[1]);
    _ = linux.close(fds[1]);
    try loop.roundtrip(c2);
    var got: [64]u8 = undefined;
    var n: usize = 0;
    while (true) {
        try harness.waitReadable(fds[0]);
        const rc = linux.read(fds[0], got[n..].ptr, got.len - n);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        if (rc == 0) break;
        n += rc;
    }
    try std.testing.expectEqualStrings(text, got[0..n]);
    // a mime it does not have reads EOF at once
    var fds2: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds2, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds2[0]);
    try c2.sendFd(offer, comptime op("wl_data_offer", .request, "receive"), &.{ .{ .string = "image/png" }, .fd }, fds2[1]);
    _ = linux.close(fds2[1]);
    try loop.roundtrip(c2);
    try harness.waitReadable(fds2[0]);
    try std.testing.expectEqual(@as(usize, 0), linux.read(fds2[0], &got, got.len));
}

test "clipboard bridge: EOF completes a read even after its source hung up (wl-copy --paste-once: a child writes, the parent has left)" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const src = try copyClient(&loop, 1);
    try std.testing.expect(loop.engine.comp.readSelection("text/plain", 9, 1024));
    try loop.engine.flush();
    const send_ev = comptime op("wl_data_source", .event, "send");
    const Ctx = struct { c: *Client, source: u32 };
    try loop.until(Ctx{ .c = src.c, .source = src.source }, struct {
        fn pred(x: Ctx) bool {
            return x.c.count(x.source, send_ev) > 0;
        }
    }.pred);
    const fd = src.c.fds.pop() orelse return error.NoSendFd;
    _ = linux.write(fd, "part", 4);
    src.c.close(); // the source's connection goes first...
    try loop.until(&loop, struct {
        fn pred(l: *Loop) bool {
            l.relay.mutex.lockUncancelable(l.relay.io);
            defer l.relay.mutex.unlock(l.relay.io);
            return !l.relay.conns.contains(1);
        }
    }.pred);
    _ = linux.write(fd, "-rest", 5); // ...the pipe's holder finishes later
    _ = linux.close(fd);
    try waitPipeRead(&loop, 9);
    const r = lastPipeRead(&loop).?;
    try std.testing.expectEqual(@intFromEnum(stream.PipeReadStatus.ok), r.status);
    try std.testing.expectEqualStrings("part-rest", r.bytes);
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
    // the one FEATURE is selection_cache, nothing dmabuf
    try std.testing.expectEqual(@as(usize, 1), loop.engine.count(.feature));
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.selection_cache)), loop.engine.frames.items[0].parse().feature.feature);

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

// ---------------------------------------------------------------------------
// dmabuf virtgpu: dmabufs named as resources (COMMIT kind virtgpu) through
// virtgpu.Fake, the ioctl seam's stand-in for a virtio-gpu render node.
// ---------------------------------------------------------------------------

const virtgpu = @import("virtgpu.zig");

/// A virtgpu backend on the fake device, outliving the Loop that uses it.
const Gpu = struct {
    threaded: std.Io.Threaded,
    fake: virtgpu.Fake = .{},
    imp: virtgpu.Importer = undefined,

    fn init(self: *Gpu) void {
        self.* = .{ .threaded = .init(std.testing.allocator, .{}) };
        self.imp = .init(self.threaded.io(), std.testing.allocator, .{ .fd = -1, .fake = &self.fake });
    }

    fn deinit(self: *Gpu) void {
        self.imp.deinit();
        self.fake.deinit();
        self.threaded.deinit();
    }

    fn config(self: *Gpu) dmabuf.Config {
        return .{ .backend = .{ .virtgpu = &self.imp }, .main_device = 0xe280 };
    }
};

test "virtgpu: FEATURE dmabuf_kind (virtgpu) then linux_dmabuf, before any CONN_OPEN; an engine without a GPU source offers no linux-dmabuf, wl_shm still shows" {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    for ([_]bool{ true, false }) |has_gpu| {
        var loop: Loop = undefined;
        try loop.start(std.testing.allocator, .{ .dmabuf = gpu.config(), .gpu_source = has_gpu });
        defer loop.stop();
        loop.engine.gpu = &gpu.fake;
        const c = try loop.connect();
        const w = try openWindow(&loop, c);

        const frames = loop.engine.frames.items;
        try std.testing.expectEqual(stream.FrameType.feature, frames[0].type);
        const k = frames[0].parse().feature;
        try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.dmabuf_kind)), k.feature);
        try std.testing.expectEqual(@as(u32, @intFromEnum(stream.BufferKind.virtgpu)), (try stream.DmabufKindFeature.decode(k.bytes)).buffer_kind);
        try std.testing.expectEqual(stream.FrameType.feature, frames[1].type);
        try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.linux_dmabuf)), frames[1].parse().feature.feature);
        try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.selection_cache)), frames[2].parse().feature.feature);
        try std.testing.expectEqual(stream.FrameType.conn_open, frames[3].type);
        try std.testing.expectEqual(@as(usize, 3), loop.engine.count(.feature));

        try std.testing.expectEqual(has_gpu, c.globalName(w.registry, "zwp_linux_dmabuf_v1") != null);
        // the software path is there either way
        var pixels: [4 * 3 * 4]u8 = undefined;
        for (0..12) |i| std.mem.writeInt(u32, pixels[i * 4 ..][0..4], 0xff40_5060 + @as(u32, @intCast(i)), .little); // X = ff: the copy path forces it
        var memfd: i32 = -1;
        defer _ = linux.close(memfd);
        const buffer = try shmBuffer(c, w, &pixels, 4, 3, &memfd);
        try attach(c, w.surface, buffer);
        try damageAll(c, w.surface, 4, 3);
        try commit(c, w.surface);
        try loop.roundtrip(c);
        try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, 0));
        try expectPixels(&loop, conn1, w.surface, &pixels, 0, 4, 3, 16);
    }
}

/// create_params + add(fd as plane 0 at `offset`/`stride`, `modifier`).
fn dmabufParamsMod(c: *Client, dm: u32, fd: i32, offset: u32, stride: u32, modifier: u64) !u32 {
    const params = c.newId();
    try c.send(dm, comptime op("zwp_linux_dmabuf_v1", .request, "create_params"), &.{.{ .new_id = params }});
    try c.sendFd(params, comptime op("zwp_linux_buffer_params_v1", .request, "add"), &.{
        .fd, .{ .uint = 0 }, .{ .uint = offset }, .{ .uint = stride }, .{ .uint = @truncate(modifier >> 32) }, .{ .uint = @truncate(modifier) },
    }, fd);
    return params;
}

fn dmabufImmedFlags(c: *Client, params: u32, w: i32, h: i32, format: u32, flags: u32) !u32 {
    const buffer = c.newId();
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "create_immed"), &.{
        .{ .new_id = buffer }, .{ .int = w }, .{ .int = h }, .{ .uint = format }, .{ .uint = flags },
    });
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "destroy"), &.{});
    return buffer;
}

/// The engine's copy of a surface equals `width`×`height` rows of `mem`
/// from `offset` at `stride` (read through the resource, `Engine.gpu`).
fn expectGpuPixels(loop: *Loop, conn_id: u32, surface: u32, mem: []const u8, offset: usize, width: u32, height: u32, stride: usize) !void {
    try expectPixels(loop, conn_id, surface, mem, offset, width, height, stride);
}

test "virtgpu: FEATURE offers implicit + LINEAR 8888s; create_immed names the resource, COMMIT kind virtgpu after its WIRE, no pixels in the stream; release after the ACK, once per attach; GEM closed at destroy" {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = gpu.config() }); // --buffers copy
    defer loop.stop();
    loop.engine.auto_ack = false;
    loop.engine.gpu = &gpu.fake;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);

    // frames[0] is dmabuf_kind (the next test), then linux_dmabuf
    const feat = try stream.DmabufFeature.decode(loop.engine.frames.items[1].parse().feature.bytes);
    try std.testing.expectEqual(@as(usize, 8), feat.count());
    try std.testing.expectEqual(dmabuf.fourcc_argb8888, feat.entry(0).format);
    try std.testing.expectEqual(dmabuf.mod_invalid, feat.entry(0).modifier);
    try std.testing.expectEqual(dmabuf.fourcc_xbgr8888, feat.entry(7).format);
    try std.testing.expectEqual(dmabuf.mod_linear, feat.entry(7).modifier);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);

    // 4×3 XRGB at offset 32, stride 20 (padded, as a GPU allocator would)
    var mem: [32 + 3 * 20]u8 = undefined;
    const fd = try patternMemfd("wland-vg-basic", &mem);
    defer _ = linux.close(fd);
    const buffer = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 32, 20, dmabuf.mod_invalid), 4, 3, dmabuf.fourcc_xrgb8888, 1);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.live()); // named at create, not at commit

    const from = loop.engine.frames.items.len;
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 3);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), framesSince(&loop, from, .commit));
    try std.testing.expectEqual(@as(usize, 0), framesSince(&loop, from, .buffer) + framesSince(&loop, from, .buffer_lz) + framesSince(&loop, from, .handle_open));
    const frames = loop.engine.frames.items;
    var ci: usize = from;
    while (frames[ci].type != .commit) ci += 1;
    try std.testing.expectEqual(stream.FrameType.wire, frames[ci - 1].type); // the commit request's
    const seen = loop.engine.gpu_commits.items[0];
    try std.testing.expectEqual(@as(u32, 1), seen.serial);
    try std.testing.expectEqual(w.surface, seen.surface_id);
    try std.testing.expectEqual(stream.VirtgpuRef{ .resource = 1, .width = 4, .height = 3, .format = dmabuf.fourcc_xrgb8888, .flags = 1, .offset = 32, .stride = 20, .modifier = dmabuf.mod_invalid }, seen.ref);
    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 4, .h = 3 }, seen.first_rect);
    try expectGpuPixels(&loop, conn1, w.surface, &mem, 32, 4, 3, 20);

    // withheld until the ACK; then exactly one
    try std.testing.expectEqual(@as(usize, 0), c.count(buffer, release_ev));
    try loop.engine.ack(conn1, 1);
    try waitReleases(&loop, c, buffer, 1);

    // a commit without attach (damage only): a COMMIT that owes nothing;
    // one with neither: nothing
    try damage(c, w.surface, 1, 1, 2, 1);
    try commit(c, w.surface);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.gpu_commits.items.len);
    try std.testing.expectEqual(stream.Rect{ .x = 1, .y = 1, .w = 2, .h = 1 }, loop.engine.gpu_commits.items[1].first_rect);
    try loop.engine.ack(conn1, 2);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), c.count(buffer, release_ev));

    // re-attach: the same resource, one more release after its ACK
    try attach(c, w.surface, buffer);
    try damageAll(c, w.surface, 4, 3);
    try commit(c, w.surface);
    try loop.settle(c);
    try std.testing.expectEqual(@as(u32, 1), loop.engine.gpu_commits.items[2].ref.resource);
    try loop.engine.ack(conn1, 3);
    try waitReleases(&loop, c, buffer, 2);

    // fds on the memfd: the test's, the relay's plane fd, the fake GEM's
    try std.testing.expectEqual(@as(usize, 3), harness.countMemfds("wland-vg-basic"));
    try c.send(buffer, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.live());
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.closes);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.bad_closes);
    try std.testing.expectEqual(@as(usize, 1), harness.countMemfds("wland-vg-basic"));
    try std.testing.expectEqual(@as(usize, 2), c.count(buffer, release_ev));
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
}

test "virtgpu: wl_buffer.destroy before the ACK keeps the resource alive until it; two buffers over one dmabuf share one GEM handle, closed once; params.create works too" {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = gpu.config() });
    defer loop.stop();
    loop.engine.auto_ack = false;
    loop.engine.gpu = &gpu.fake;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    var mem: [2 * 2 * 4]u8 = undefined;
    const fd = try patternMemfd("wland-vg-share", &mem);
    defer _ = linux.close(fd);

    // destroyed with its COMMIT in flight: no release, the engine still
    // resolves the resource (Engine.gpu counts an error otherwise)
    const b1 = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 0, 8, dmabuf.mod_linear), 2, 2, dmabuf.fourcc_argb8888, 0);
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface); // serial 1
    try c.send(b1, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.live()); // the COMMIT holds it
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);

    // a second buffer over the SAME dmabuf (create, server id): same GEM
    // handle, same resource; the first's ACK must not close it
    const params = try dmabufParamsMod(c, dm, fd, 0, 8, dmabuf.mod_linear);
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "create"), &.{
        .{ .int = 2 }, .{ .int = 2 }, .{ .uint = dmabuf.fourcc_argb8888 }, .{ .uint = 0 },
    });
    try loop.roundtrip(c);
    const created = c.last(params, comptime op("zwp_linux_buffer_params_v1", .event, "created")) orelse return error.NotCreated;
    const b2 = std.mem.readInt(u32, created.body[0..4], .little);
    try std.testing.expect(b2 >= core.objects.server_id_base);
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "destroy"), &.{});
    try attach(c, w.surface, b2);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface); // serial 2
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), loop.engine.gpu_commits.items.len);
    try std.testing.expectEqual(loop.engine.gpu_commits.items[0].ref.resource, loop.engine.gpu_commits.items[1].ref.resource);
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.live());
    try std.testing.expectEqual(@as(u32, 3), gpu.imp.refsOf(1)); // COMMIT 1, b2, COMMIT 2

    try loop.engine.ack(conn1, 1);
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 0), c.count(b1, release_ev)); // forgotten: never
    try std.testing.expectEqual(@as(usize, 0), c.count(b2, release_ev)); // busy with serial 2
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.live());
    try loop.engine.ack(conn1, 2);
    try waitReleases(&loop, c, b2, 1);
    try std.testing.expectEqual(@as(u32, 1), gpu.imp.refsOf(1)); // b2 alone

    // the server-id buffer destroyed: the handle goes, closed exactly once
    try c.send(b2, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.live());
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.closes);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.bad_closes);
    try std.testing.expectEqual(@as(usize, 1), harness.countMemfds("wland-vg-share"));
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
}

test "virtgpu: what it can't name (interlaced, a failed import) is released unshown, logged once; offered-but-odd layouts the compositor refuses never reach it" {
    std.testing.log_level = .err; // the refusals are warnings
    defer std.testing.log_level = .warn;
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = gpu.config() });
    defer loop.stop();
    loop.engine.gpu = &gpu.fake;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    var mem: [4 * 4 * 4]u8 = undefined;
    const fd = try patternMemfd("wland-vg-refuse", &mem);
    defer _ = linux.close(fd);

    // interlaced: the compositor takes it (flags are the backend's), the
    // relay does not name it
    const b1 = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 0, 16, dmabuf.mod_invalid), 4, 4, dmabuf.fourcc_xbgr8888, 2);
    // the device refuses the import
    gpu.fake.fail_import = .INVAL;
    const b2 = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 0, 16, dmabuf.mod_invalid), 4, 4, dmabuf.fourcc_abgr8888, 0);
    for ([_]u32{ b1, b2, b1, b2 }, 1..) |b, i| {
        try attach(c, w.surface, b);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface);
        try waitReleases(&loop, c, b, (i + 1) / 2);
    }
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 0), loop.engine.gpu_commits.items.len);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.live());
    try std.testing.expectEqual(@as(usize, 2), gpu.imp.n_logged[@intFromEnum(virtgpu.Importer.LogClass.refused)]); // one per kind, not per commit

    // a modifier the table lacks (X-tiled): the compositor answers with
    // invalid_format (a protocol error); the relay names nothing for it
    const closes_before = gpu.fake.closes;
    _ = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 0, 16, 0x0100000000000001), 4, 4, dmabuf.fourcc_xrgb8888, 0);
    const error_ev = comptime op("wl_display", .event, "error");
    try loop.until(c, struct {
        fn pred(x: *Client) bool {
            return x.count(1, error_ev) == 1;
        }
    }.pred);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, c.last(1, error_ev).?.body[4..8], .little)); // invalid_format
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.live());
    try std.testing.expectEqual(closes_before, gpu.fake.closes);
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
}

/// `n` commits of one virtgpu buffer whose write fence never signals (a
/// pipe stands in for its dmabuf: poll never readable), each settled
/// before the next; the ns they took.
fn commitsOnBusyDmabuf(fence_wait: bool, n: usize) !u64 {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    gpu.fake.accept_pipes = true;
    gpu.fake.info_size = 4096;
    var cfg = gpu.config();
    cfg.fence_wait = fence_wait;
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }));
    defer for (pipe_fds) |fd| {
        _ = linux.close(fd);
    };
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = cfg });
    defer loop.stop();
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    const buffer = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, pipe_fds[0], 0, 16, dmabuf.mod_invalid), 4, 4, dmabuf.fourcc_xrgb8888, 0);
    try loop.roundtrip(c);
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.live());
    try attach(c, w.surface, buffer);

    const start = monoNs();
    for (0..n) |_| {
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface);
        try loop.settle(c);
    }
    const took = monoNs() - start;
    try std.testing.expectEqual(n, loop.engine.gpu_commits.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
    return took;
}

fn monoNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "virtgpu: each COMMIT waits (bounded, 100 ms) for the dmabuf's write fence; --no-fence-wait sends it at once" {
    // the default: the fence never signals, so each COMMIT goes out after
    // the full bound (the timeout's once-per-conn line is info, not shown)
    try std.testing.expect(try commitsOnBusyDmabuf(true, 1) >= 100 * std.time.ns_per_ms);
    // fence_wait off: 20 COMMITs in well under the 2 s their waits would take
    try std.testing.expect(try commitsOnBusyDmabuf(false, 20) < 1000 * std.time.ns_per_ms);
}

test "virtgpu: conn close with COMMITs in flight drops every GEM reference; late ACKs ignored; the next app is served" {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = gpu.config() });
    defer loop.stop();
    loop.engine.auto_ack = false;
    loop.engine.gpu = &gpu.fake;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    var mem: [4 * 4 * 4]u8 = undefined;
    const fd1 = try patternMemfd("wland-vg-close", &mem);
    defer _ = linux.close(fd1);
    const fd2 = try patternMemfd("wland-vg-close", &mem);
    defer _ = linux.close(fd2);
    const b1 = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd1, 0, 16, dmabuf.mod_invalid), 4, 4, dmabuf.fourcc_xrgb8888, 0);
    const b2 = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd2, 0, 16, dmabuf.mod_invalid), 4, 4, dmabuf.fourcc_xrgb8888, 0);
    for ([_]u32{ b1, b2 }) |b| {
        try attach(c, w.surface, b);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface);
    }
    try c.send(b1, comptime op("wl_buffer", .request, "destroy"), &.{}); // held by its COMMIT only
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 2), gpu.fake.live());

    const closes = loop.engine.count(.conn_close);
    c.close();
    const Ctx = struct { e: *harness.Engine, n: usize };
    try loop.until(Ctx{ .e = &loop.engine, .n = closes }, struct {
        fn pred(x: Ctx) bool {
            return x.e.count(.conn_close) > x.n;
        }
    }.pred);
    // the relay tore the conn down before CONN_CLOSE: nothing held
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.live());
    try std.testing.expectEqual(@as(usize, 0), gpu.imp.live());
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.bad_closes);
    try std.testing.expectEqual(@as(usize, 2), harness.countMemfds("wland-vg-close")); // the test's two

    try loop.engine.ack(conn1, 1);
    try loop.engine.ack(conn1, 2);
    loop.engine.auto_ack = true;
    const c2 = try loop.connect();
    const w2 = try openWindow(&loop, c2);
    const dm2 = try bind(c2, w2.registry, "zwp_linux_dmabuf_v1", 4);
    const b3 = try dmabufImmedFlags(c2, try dmabufParamsMod(c2, dm2, fd1, 0, 16, dmabuf.mod_invalid), 4, 4, dmabuf.fourcc_xrgb8888, 0);
    try attach(c2, w2.surface, b3);
    try damageAll(c2, w2.surface, 4, 4);
    try commit(c2, w2.surface);
    try waitReleases(&loop, c2, b3, 1);
    try std.testing.expectEqual(@as(u32, 1), loop.engine.gpu_commits.items[2].serial); // a new conn: its own serials
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
}

test "virtgpu beside handle buffers (procfd, kwshm): shm by handle, dmabuf by resource on one conn, one serial space, ACKs in any order" {
    const dev: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    defer _ = linux.close(dev);
    for ([_]@import("buffers.zig").Backend{ .procfd, .{ .kwshm = dev } }) |backend| {
        var gpu: Gpu = undefined;
        gpu.init();
        defer gpu.deinit();
        var loop: Loop = undefined;
        try loop.start(std.testing.allocator, .{ .backend = backend, .dmabuf = gpu.config() });
        defer loop.stop();
        loop.engine.auto_ack = false;
        loop.engine.gpu = &gpu.fake;
        const c = try loop.connect();
        const w = try openWindow(&loop, c);
        const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);

        // a second surface for the GPU client half (a subsurface would do too)
        const gs = c.newId();
        try c.send(w.compositor, comptime op("wl_compositor", .request, "create_surface"), &.{.{ .new_id = gs }});
        var shm_px: [4 * 4 * 4]u8 = undefined;
        @memset(&shm_px, 0x33);
        var shm_fd: i32 = -1;
        defer _ = linux.close(shm_fd);
        const sb = try shmBuffer(c, w, &shm_px, 4, 4, &shm_fd);
        var gmem: [2 * 2 * 4]u8 = undefined;
        const gfd = try patternMemfd("wland-vg-mixed", &gmem);
        defer _ = linux.close(gfd);
        const gb = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, gfd, 0, 8, dmabuf.mod_invalid), 2, 2, dmabuf.fourcc_argb8888, 0);

        try attach(c, w.surface, sb);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface); // serial 1: shm
        try attach(c, gs, gb);
        try damageAll(c, gs, 2, 2);
        try commit(c, gs); // serial 2: virtgpu
        try attach(c, w.surface, sb);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface); // serial 3: shm again
        try loop.settle(c);
        try std.testing.expectEqual(@as(usize, 2), loop.engine.commits.items.len);
        try std.testing.expectEqual(@as(usize, 1), loop.engine.gpu_commits.items.len);
        try std.testing.expectEqual(@as(u32, 1), loop.engine.commits.items[0].serial);
        try std.testing.expectEqual(@as(u32, 2), loop.engine.gpu_commits.items[0].serial);
        try std.testing.expectEqual(@as(u32, 3), loop.engine.commits.items[1].serial);
        try expectGpuPixels(&loop, conn1, gs, &gmem, 0, 2, 2, 8);

        // the GPU commit's ACK first: its buffer alone is released
        try loop.engine.ack(conn1, 2);
        try waitReleases(&loop, c, gb, 1);
        try std.testing.expectEqual(@as(usize, 0), c.count(sb, release_ev));
        try loop.engine.ack(conn1, 3);
        try loop.engine.ack(conn1, 1);
        try waitReleases(&loop, c, sb, 1); // one release for both busy shm COMMITs
        try loop.settle(c);
        try std.testing.expectEqual(@as(usize, 1), c.count(gb, release_ev));
        try expectHandlesBalanced(&loop);
        try std.testing.expectEqual(@as(usize, 1), gpu.fake.live()); // gb lives
        try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
    }
}

test "virtgpu with --buffers copy on a relay-paced (WebSocket) link: COMMIT/ACK both ways, frame callbacks fired once by the relay" {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .frame_callbacks = .relay, .dmabuf = gpu.config() });
    defer loop.stop();
    loop.engine.gpu = &gpu.fake; // auto-ACK, as the reference engine does
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    var mem: [2 * 2 * 4]u8 = undefined;
    const fd = try patternMemfd("wland-vg-ws", &mem);
    defer _ = linux.close(fd);
    const b = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 0, 8, dmabuf.mod_invalid), 2, 2, dmabuf.fourcc_xrgb8888, 0);
    var pixels: [4]u8 = .{ 9, 9, 9, 9 };
    var shm_fd: i32 = -1;
    defer _ = linux.close(shm_fd);
    const sb = try shmBuffer(c, w, &pixels, 1, 1, &shm_fd);

    for (0..3) |i| {
        const cb = c.newId();
        try c.send(w.surface, comptime op("wl_surface", .request, "frame"), &.{.{ .new_id = cb }});
        try attach(c, w.surface, b);
        try damageAll(c, w.surface, 2, 2);
        try commit(c, w.surface);
        try waitReleases(&loop, c, b, i + 1); // the ACK came back and was settled
        const Ctx = struct { c: *Client, cb: u32 };
        try loop.until(Ctx{ .c = c, .cb = cb }, struct {
            fn pred(x: Ctx) bool {
                return x.c.count(x.cb, done_ev) == 1;
            }
        }.pred);
    }
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 3), loop.engine.gpu_commits.items.len);
    try std.testing.expectEqual(@as(usize, 3), c.count(b, release_ev));
    // the engine never saw a frame request (it would fire a second done)
    try std.testing.expectEqual(@as(usize, 0), loop.engine.comp.conns.get(conn1).?.frame_callbacks.items.len);

    // a wl_shm buffer on the same conn still travels as pixels
    try attach(c, w.surface, sb);
    try damageAll(c, w.surface, 1, 1);
    try commit(c, w.surface);
    try waitReleases(&loop, c, sb, 1);
    // copy mode releases before the burst goes out: the engine may not
    // have read the BUFFER yet
    try loop.settle(c);
    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, 0));
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
}

/// The engine shows `mem`'s rows (as `expectPixels`), alpha/X bytes not
/// compared: copy mode ships XRGB with X forced to 0xff.
fn expectRgb(loop: *Loop, conn_id: u32, surface: u32, mem: []const u8, offset: usize, width: u32, height: u32, stride: usize) !void {
    const px = loop.engine.pixels(conn_id, surface) orelse return error.NoPixels;
    try std.testing.expectEqual(width, px.width);
    try std.testing.expectEqual(height, px.height);
    for (0..height) |y| for (0..width) |x| {
        const want = mem[offset + y * stride + x * 4 ..][0..3];
        const got = px.bytes[(y * width + x) * 4 ..][0..3];
        try std.testing.expectEqualSlices(u8, want, got);
    };
}

test "virtgpu ⇄ pixels on one surface at the same size: each switch of kind ships the whole buffer, the engine shows the new content (copy, procfd, kwshm)" {
    const dev: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    defer _ = linux.close(dev);
    for ([_]@import("buffers.zig").Backend{ .copy, .procfd, .{ .kwshm = dev } }) |backend| {
        var gpu: Gpu = undefined;
        gpu.init();
        defer gpu.deinit();
        var loop: Loop = undefined;
        try loop.start(std.testing.allocator, .{ .backend = backend, .dmabuf = gpu.config() });
        defer loop.stop();
        loop.engine.gpu = &gpu.fake; // auto-ACK
        const c = try loop.connect();
        const w = try openWindow(&loop, c);
        const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
        // 4×4 each, different content everywhere
        var px: [4 * 4 * 4]u8 = undefined;
        for (&px, 0..) |*b, i| b.* = @truncate(0x80 + i);
        var shm_fd: i32 = -1;
        defer _ = linux.close(shm_fd);
        const sb = try shmBuffer(c, w, &px, 4, 4, &shm_fd);
        var gmem: [4 * 4 * 4]u8 = undefined;
        const gfd = try patternMemfd("wland-vg-switch", &gmem);
        defer _ = linux.close(gfd);
        const gb = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, gfd, 0, 16, dmabuf.mod_invalid), 4, 4, dmabuf.fourcc_xrgb8888, 0);

        const Step = struct { buffer: u32, rect: [4]i32, gpu: bool };
        const steps = [_]Step{
            .{ .buffer = sb, .rect = .{ 0, 0, 4, 4 }, .gpu = false },
            // shm → gpu: the client damages one pixel (the rest of its
            // buffer holds the same picture as the shm one did, for all
            // the client knows): the engine must still get all of it
            .{ .buffer = gb, .rect = .{ 1, 1, 1, 1 }, .gpu = true },
            // gpu → shm, partial damage: a GL presenter blanked the
            // texture for the GPU image; the copy backend's shadow is stale
            .{ .buffer = sb, .rect = .{ 2, 2, 1, 1 }, .gpu = false },
            .{ .buffer = gb, .rect = .{ 0, 0, 1, 1 }, .gpu = true },
            // the reviewer's case: full damage after a GPU image
            .{ .buffer = sb, .rect = .{ 0, 0, 4, 4 }, .gpu = false },
        };
        for (steps) |st| {
            const commits_before = loop.engine.commits.items.len;
            const gpu_before = loop.engine.gpu_commits.items.len;
            const from = loop.engine.frames.items.len;
            try attach(c, w.surface, st.buffer);
            try damage(c, w.surface, st.rect[0], st.rect[1], st.rect[2], st.rect[3]);
            try commit(c, w.surface);
            try loop.settle(c);
            if (st.gpu) {
                try std.testing.expectEqual(gpu_before + 1, loop.engine.gpu_commits.items.len);
                try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 4, .h = 4 }, loop.engine.gpu_commits.items[gpu_before].first_rect);
                try expectRgb(&loop, conn1, w.surface, &gmem, 0, 4, 4, 16);
            } else {
                if (backend == .copy) {
                    try std.testing.expectEqual(@as(usize, 1), bufferFramesSince(&loop, from));
                } else {
                    try std.testing.expectEqual(commits_before + 1, loop.engine.commits.items.len);
                    try std.testing.expectEqual(stream.Rect{ .x = 0, .y = 0, .w = 4, .h = 4 }, loop.engine.commits.items[commits_before].first_rect);
                }
                try expectRgb(&loop, conn1, w.surface, &px, 0, 4, 4, 16);
            }
        }
        // same kind again: the client's damage alone (no forced full rect)
        const gpu_before = loop.engine.gpu_commits.items.len;
        try attach(c, w.surface, gb);
        try damageAll(c, w.surface, 4, 4);
        try commit(c, w.surface);
        try damage(c, w.surface, 3, 0, 1, 2);
        try commit(c, w.surface);
        try loop.settle(c);
        try std.testing.expectEqual(gpu_before + 2, loop.engine.gpu_commits.items.len);
        try std.testing.expectEqual(stream.Rect{ .x = 3, .y = 0, .w = 1, .h = 2 }, loop.engine.gpu_commits.items[gpu_before + 1].first_rect);
        try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
    }
}

test "virtgpu swapchain: three resources in turn with partial damage carry the client's rects; the engine's copy stays the whole picture" {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .backend = .procfd, .dmabuf = gpu.config() });
    defer loop.stop();
    loop.engine.gpu = &gpu.fake; // auto-ACK
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);

    // A client's frames: frame k changes one rect of the picture; the
    // buffer it renders frame k into holds the whole picture as of frame k
    // (buffer age: it repaired what changed since that buffer's last use),
    // as wl_surface.attach requires.
    const W = 6;
    const H = 4;
    var picture: [W * H * 4]u8 = @splat(0x10);
    const rects = [_][4]i32{ .{ 0, 0, W, H }, .{ 1, 1, 2, 2 }, .{ 0, 0, 1, 1 }, .{ 5, 3, 1, 1 }, .{ 2, 0, 3, 1 }, .{ 4, 2, 2, 2 }, .{ 0, 3, 6, 1 } };
    var fds: [3]i32 = undefined;
    var bufs: [3]u32 = undefined;
    for (&fds, &bufs, 0..) |*fd, *b, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&name_buf, "wland-vg-swap{d}", .{i});
        var junk: [W * H * 4]u8 = undefined;
        fd.* = try patternMemfd(name, &junk);
        b.* = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd.*, 0, W * 4, dmabuf.mod_invalid), W, H, dmabuf.fourcc_xrgb8888, 0);
    }
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    for (rects, 0..) |r, k| {
        // frame k: change rect r of the picture, render it all into buffer k % 3
        for (0..@intCast(r[3])) |dy| for (0..@intCast(r[2])) |dx| {
            const at = ((@as(usize, @intCast(r[1])) + dy) * W + @as(usize, @intCast(r[0])) + dx) * 4;
            @memset(picture[at..][0..4], @as(u8, @intCast(0x20 + k * 0x11)));
        };
        const slot = k % 3;
        try std.testing.expectEqual(picture.len, linux.pwrite(fds[slot], &picture, picture.len, 0));
        try attach(c, w.surface, bufs[slot]);
        try damage(c, w.surface, r[0], r[1], r[2], r[3]);
        try commit(c, w.surface);
        try loop.settle(c);
        const seen = loop.engine.gpu_commits.items[k];
        try std.testing.expectEqual(@as(u32, 1), seen.n_rects);
        try std.testing.expectEqual(stream.Rect{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] }, seen.first_rect);
        try std.testing.expectEqual(loop.engine.gpu_commits.items[slot].ref.resource, seen.ref.resource);
        try expectPixels(&loop, conn1, w.surface, &picture, 0, W, H, W * 4);
    }
    try std.testing.expectEqual(@as(usize, 3), gpu.fake.live());
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
}

test "virtgpu: the render node is held only while a GPU buffer or its COMMIT is — closed after the last destroy + ACK and at conn close, reopened at the next import" {
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = gpu.config() });
    defer loop.stop();
    loop.engine.auto_ack = false;
    loop.engine.gpu = &gpu.fake;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.opens); // no GPU buffer yet: no host context
    var mem: [2 * 2 * 4]u8 = undefined;
    const fd = try patternMemfd("wland-vg-node", &mem);
    defer _ = linux.close(fd);

    const b1 = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 0, 8, dmabuf.mod_invalid), 2, 2, dmabuf.fourcc_xrgb8888, 0);
    try attach(c, w.surface, b1);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface); // serial 1
    try c.send(b1, comptime op("wl_buffer", .request, "destroy"), &.{});
    try loop.settle(c);
    try std.testing.expect(gpu.fake.is_open); // the COMMIT holds the resource
    try loop.engine.ack(conn1, 1);
    try loop.settle(c);
    try std.testing.expect(!gpu.fake.is_open);
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.opens);
    try std.testing.expectEqual(@as(usize, 1), gpu.fake.dev_closes);

    // the next GPU buffer opens it again; a conn ending with it held closes it
    const b2 = try dmabufImmedFlags(c, try dmabufParamsMod(c, dm, fd, 0, 8, dmabuf.mod_invalid), 2, 2, dmabuf.fourcc_xrgb8888, 0);
    try attach(c, w.surface, b2);
    try damageAll(c, w.surface, 2, 2);
    try commit(c, w.surface); // serial 2, never ACKed
    try loop.settle(c);
    try std.testing.expect(gpu.fake.is_open);
    try std.testing.expectEqual(@as(usize, 2), gpu.fake.opens);
    const closes = loop.engine.count(.conn_close);
    c.close();
    const Ctx = struct { e: *harness.Engine, n: usize };
    try loop.until(Ctx{ .e = &loop.engine, .n = closes }, struct {
        fn pred(x: Ctx) bool {
            return x.e.count(.conn_close) > x.n;
        }
    }.pred);
    try std.testing.expect(!gpu.fake.is_open);
    try std.testing.expectEqual(@as(usize, 2), gpu.fake.dev_closes);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.closed_with_handles); // handles went first
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.closed_ioctls);
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.bad_closes);
    try std.testing.expectEqual(@as(usize, 0), loop.engine.errors);
}

test "a stream link dropping mid-record (page suspend, vsock reset) is a drop, logged at info — no error line" {
    // the test runner fails a test that logs at .err from any thread
    for ([_]usize{ 2, 4 + 10 }) |partial| {
        var loop: Loop = undefined;
        try loop.start(std.testing.allocator, .{});
        defer loop.stop();
        const Attached = struct {
            fn wait(l: *Loop, want: bool) !void {
                for (0..500) |_| {
                    l.relay.mutex.lockUncancelable(l.threaded.io());
                    const attached = l.relay.link != null;
                    l.relay.mutex.unlock(l.threaded.io());
                    if (attached == want) return;
                    l.threaded.io().sleep(.fromMilliseconds(10), .awake) catch {};
                }
                return error.Timeout;
            }
        };
        try Attached.wait(&loop, true);
        // a record of 100 bytes announced, `partial` bytes of it sent
        var rec: [4 + 10]u8 = @splat(0);
        stream.writeRecordHeader(rec[0..4], 100);
        try std.testing.expectEqual(partial, linux.write(loop.link_fds[1], &rec, partial));
        _ = linux.shutdown(loop.link_fds[1], linux.SHUT.WR);
        try Attached.wait(&loop, false);
    }
}

test "virtgpu: a params.create the compositor refuses (a protocol error, never `failed`) leaves no GEM handle behind" {
    std.testing.log_level = .err; // the relay's own refusal is a warning
    defer std.testing.log_level = .warn;
    var gpu: Gpu = undefined;
    gpu.init();
    defer gpu.deinit();
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{ .dmabuf = gpu.config() });
    defer loop.stop();
    loop.engine.gpu = &gpu.fake;
    const c = try loop.connect();
    const w = try openWindow(&loop, c);
    const dm = try bind(c, w.registry, "zwp_linux_dmabuf_v1", 4);
    var mem: [2 * 2 * 4]u8 = undefined;
    const fd = try patternMemfd("wland-vg-refused-create", &mem);
    defer _ = linux.close(fd);
    const params = try dmabufParamsMod(c, dm, fd, 0, 8, dmabuf.mod_invalid);
    try c.send(params, comptime op("zwp_linux_buffer_params_v1", .request, "create"), &.{
        .{ .int = 0 }, .{ .int = 2 }, .{ .uint = dmabuf.fourcc_xrgb8888 }, .{ .uint = 0 },
    });
    const error_ev = comptime op("wl_display", .event, "error");
    try loop.until(c, struct {
        fn pred(x: *Client) bool {
            return x.count(1, error_ev) == 1;
        }
    }.pred);
    try std.testing.expectEqual(@as(usize, 0), c.count(params, comptime op("zwp_linux_buffer_params_v1", .event, "failed")));
    try std.testing.expectEqual(@as(usize, 0), gpu.fake.opens); // never imported
    try std.testing.expectEqual(@as(usize, 0), gpu.imp.live());
}

// ---------------------------------------------------------------------------
// The engine's own selection (FEATURE selection_cache, FDMSG own_pipe): each
// payload crosses the link once; receives are written by one capped writer
// thread (pipe_writer.zig).
// ---------------------------------------------------------------------------

const pipe_writer = @import("pipe_writer.zig");

fn countThreads() usize {
    const fd: i32 = @intCast(linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    const txt = buf[0..n];
    const i = std.mem.indexOf(u8, txt, "Threads:") orelse return 0;
    var j = i + 8;
    while (txt[j] == ' ' or txt[j] == '\t') j += 1;
    var k = j;
    while (txt[k] >= '0' and txt[k] <= '9') k += 1;
    return std.fmt.parseInt(usize, txt[j..k], 10) catch 0;
}

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

/// Spin (≤ 5 s) until the writer has `n` transfers in flight.
fn awaitInFlight(loop: *Loop, n: usize) !void {
    var spins: usize = 0;
    while (loop.relay.writer.inFlight(loop.relay.io) != n) : (spins += 1) {
        if (spins == 500) return error.Timeout;
        sleepMs(10);
    }
}

/// A focused window with a data device on a new conn (`conn_id`); focus
/// leaves whichever conn had it. Its data device id.
fn focusedReceiver(loop: *Loop, conn_id: u32, prev: u32) !struct { c: *Client, dev: u32 } {
    const c = try loop.connect();
    const w = try openWindow(loop, c);
    const seat = try bind(c, w.registry, "wl_seat", 5);
    const ddm = try bind(c, w.registry, "wl_data_device_manager", 3);
    try c.send(seat, comptime op("wl_seat", .request, "get_keyboard"), &.{.{ .new_id = c.newId() }});
    const dev = c.newId();
    try c.send(ddm, comptime op("wl_data_device_manager", .request, "get_data_device"), &.{ .{ .new_id = dev }, .{ .object = seat } });
    try loop.roundtrip(c);
    if (prev != 0) loop.engine.comp.keyboardLeave(prev);
    loop.engine.comp.keyboardEnter(conn_id, w.surface);
    try loop.engine.flush();
    try loop.roundtrip(c);
    while (c.fds.pop()) |fd| _ = linux.close(fd); // the keymap
    return .{ .c = c, .dev = dev };
}

/// The engine's own selection: `mime` → `len` bytes of `fill`.
fn setOwn(loop: *Loop, mime: []const u8, fill: u8, len: usize) !void {
    const gpa = std.testing.allocator;
    const pack = try gpa.alloc(u8, 8 + mime.len + len);
    defer gpa.free(pack);
    std.mem.writeInt(u32, pack[0..4], @intCast(mime.len), .little);
    @memcpy(pack[4..][0..mime.len], mime);
    std.mem.writeInt(u32, pack[4 + mime.len ..][0..4], @intCast(len), .little);
    @memset(pack[8 + mime.len ..], fill);
    try loop.engine.comp.setOwnSelection(pack);
    try loop.engine.flush();
}

fn lastOffer(c: *Client, dev: u32) !u32 {
    const sel = c.last(dev, comptime op("wl_data_device", .event, "selection")) orelse return error.NoSelection;
    return std.mem.readInt(u32, sel.body[0..4], .little);
}

/// receive(mime) on `offer`; the read end of its pipe.
fn receive(c: *Client, offer: u32, mime: []const u8) !i32 {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
    try c.sendFd(offer, comptime op("wl_data_offer", .request, "receive"), &.{ .{ .string = mime }, .fd }, fds[1]);
    _ = linux.close(fds[1]);
    return fds[0];
}

/// Read `fd` to EOF: how many bytes, and whether all were `fill`.
fn drain(fd: i32, fill: u8) !struct { n: usize, uniform: bool } {
    var buf: [64 * 1024]u8 = undefined;
    var n: usize = 0;
    var uniform = true;
    while (true) {
        try harness.waitReadable(fd);
        const rc = linux.read(fd, &buf, buf.len);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        if (rc == 0) break;
        for (buf[0..rc]) |b| uniform = uniform and b == fill;
        n += rc;
    }
    return .{ .n = n, .uniform = uniform };
}

test "own selection: a payload crosses the link once; receives never read hold capped slots on one writer thread, the rest read EOF; another conn is still served" {
    std.testing.log_level = .err; // the writer warns at its cap
    defer std.testing.log_level = .warn;
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const io = loop.relay.io;
    const r2 = try focusedReceiver(&loop, 1, 0);
    const mime = "text/plain";
    const size: usize = 1 << 20; // more than a pipe holds
    try setOwn(&loop, mime, 'x', size);
    try loop.roundtrip(r2.c);
    const offer = try lastOffer(r2.c, r2.dev);

    const threads = countThreads();
    const N = 64;
    var readers: [N]i32 = undefined;
    for (&readers) |*r| r.* = try receive(r2.c, offer, mime);
    defer for (readers) |r| {
        _ = linux.close(r);
    };
    try loop.roundtrip(r2.c);
    try awaitInFlight(&loop, pipe_writer.per_conn_max);
    try std.testing.expectEqual(@as(usize, 1), loop.relay.own_payloads_received);
    try std.testing.expect(countThreads() <= threads + 1); // the writer, once
    try std.testing.expectEqual(@as(usize, N - pipe_writer.per_conn_max), loop.relay.writer.refused);
    // past the cap: EOF at once
    try std.testing.expectEqual(@as(usize, 0), (try drain(readers[N - 1], 'x')).n);

    // another conn: same generation, no bytes cross again, all of it arrives
    const r3 = try focusedReceiver(&loop, 2, 1);
    const offer3 = try lastOffer(r3.c, r3.dev);
    const fd3 = try receive(r3.c, offer3, mime);
    defer _ = linux.close(fd3);
    try loop.roundtrip(r3.c);
    const got = try drain(fd3, 'x');
    try std.testing.expectEqual(size, got.n);
    try std.testing.expect(got.uniform);
    try std.testing.expectEqual(@as(usize, 1), loop.relay.own_payloads_received);

    // readers closing early end their transfers (EPIPE)
    for (readers[0..pipe_writer.per_conn_max]) |*r| {
        _ = linux.close(r.*);
        r.* = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    }
    try awaitInFlight(&loop, 0);
    _ = io;
}

test "own selection replaced mid-transfer: the transfer ends with the bytes it began with, the next receive gets the new ones, a stale offer reads EOF" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const r = try focusedReceiver(&loop, 1, 0);
    const mime = "text/plain";
    try setOwn(&loop, mime, 'a', 1 << 20);
    try loop.roundtrip(r.c);
    const old = try lastOffer(r.c, r.dev);
    const fd_old = try receive(r.c, old, mime);
    defer _ = linux.close(fd_old);
    try loop.roundtrip(r.c);
    try awaitInFlight(&loop, 1);

    try setOwn(&loop, mime, 'b', 1000); // the old copy is dropped (gen 0), then the new one
    try loop.roundtrip(r.c);
    const new = try lastOffer(r.c, r.dev);
    try std.testing.expect(new != old);
    const a = try drain(fd_old, 'a');
    try std.testing.expectEqual(@as(usize, 1 << 20), a.n);
    try std.testing.expect(a.uniform);
    const fd_new = try receive(r.c, new, mime);
    defer _ = linux.close(fd_new);
    const fd_stale = try receive(r.c, old, mime);
    defer _ = linux.close(fd_stale);
    try loop.roundtrip(r.c);
    const b = try drain(fd_new, 'b');
    try std.testing.expectEqual(@as(usize, 1000), b.n);
    try std.testing.expect(b.uniform);
    try std.testing.expectEqual(@as(usize, 0), (try drain(fd_stale, 'a')).n);
    try std.testing.expectEqual(@as(usize, 2), loop.relay.own_payloads_received);
    try awaitInFlight(&loop, 0);
}

test "own selection: a conn closing ends its transfers; the link dropping ends every transfer and drops the relay's copy" {
    var loop: Loop = undefined;
    try loop.start(std.testing.allocator, .{});
    defer loop.stop();
    const mime = "text/plain";
    const r2 = try focusedReceiver(&loop, 1, 0);
    try setOwn(&loop, mime, 'x', 1 << 20);
    try loop.roundtrip(r2.c);
    const fd2 = try receive(r2.c, try lastOffer(r2.c, r2.dev), mime);
    defer _ = linux.close(fd2);
    try loop.roundtrip(r2.c);
    try awaitInFlight(&loop, 1);
    r2.c.close(); // the receiving app hangs up mid-transfer
    try awaitInFlight(&loop, 0);
    try std.testing.expect((try drain(fd2, 'x')).n < 1 << 20); // cut short, EOF

    const r3 = try focusedReceiver(&loop, 2, 0);
    const fd3 = try receive(r3.c, try lastOffer(r3.c, r3.dev), mime);
    defer _ = linux.close(fd3);
    try loop.roundtrip(r3.c);
    try awaitInFlight(&loop, 1);
    loop.link.link.kick(); // the engine goes
    var spins: usize = 0;
    while (true) : (spins += 1) {
        loop.relay.mutex.lockUncancelable(loop.relay.io);
        const gone = loop.relay.link == null;
        const gen = loop.relay.own_cache.gen;
        loop.relay.mutex.unlock(loop.relay.io);
        if (gone) {
            try std.testing.expectEqual(@as(u32, 0), gen);
            break;
        }
        if (spins == 500) return error.Timeout;
        sleepMs(10);
    }
    try awaitInFlight(&loop, 0);
    try std.testing.expect((try drain(fd3, 'x')).n < 1 << 20);
}
