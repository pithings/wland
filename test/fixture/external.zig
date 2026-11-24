// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `external [--frames N]`: a client of wland_external_buffer_manager_v1 —
//! content it keeps at the embedder (the page), named by an opaque id; no
//! fd, no pixels. It makes two external buffers (ids 0x1122334400000001
//! and …02, 200×120 ARGB8888) and commits them in turn, one per frame
//! callback, with full damage, never reusing a buffer before its
//! wl_buffer.release (as an EGL WSI would). Only a relay started with
//! `--external-buffers` in front of a page that resolves the ids offers
//! the global.
//!
//! stdout, one line each (what the E2E reads):
//!   external: offered
//!   external: buffer id=0x1122334400000001 200x120     (one per buffer)
//!   external: commit id=0x… frame=N                    (every commit)
//!   external: release id=0x…                           (every release)
//!   external: done frames=N        (with --frames N: N commits made, both
//!                                   buffers back; it then idles)
//! Without the global it does what a real client must (the global's
//! absence means "use wl_shm"): `external: not offered`, then
//! `external: wl_shm fallback 200x120`, and the same loop over two wl_shm
//! buffers with `external: commit wl_shm frame=N` / `external: release
//! wl_shm` lines. A duplicate release (one while not busy) exits 1.

const std = @import("std");
const wl = @import("wl.zig");
const app_mod = @import("app.zig");

const W = 200;
const H = 120;
const fourcc_argb8888: u32 = 0x34325241;
const ids = [2]u64{ 0x1122_3344_0000_0001, 0x1122_3344_0000_0002 };

const Buf = struct {
    /// the wl_buffer
    id: u32,
    /// the external id (0 on the wl_shm fallback)
    ext: u64 = 0,
    /// wl_shm fallback: its pixels
    px: []u32 = &.{},
    busy: bool = false,
};

const Ctx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    bufs: [2]Buf = undefined,
    have_bufs: bool = false,
    /// false: the wl_shm fallback
    external: bool = false,
    frame: u32 = 0,
    /// commits to make (0: no end)
    frames: u32 = 0,
    done_said: bool = false,
    /// a frame is due but no buffer was free: draw at the next release
    starved: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            for (&ctx.bufs) |*b| if (b.id == ev.id) {
                if (!b.busy) wl.fail("wl_buffer {d} released while not busy (a duplicate release)", .{ev.id});
                b.busy = false;
                if (ctx.external) wl.print("external: release id=0x{x:0>16}", .{b.ext}) else wl.print("external: release wl_shm", .{});
            };
            if (ctx.starved) ctx.redraw();
            ctx.maybeDone();
            return;
        }
        if (!ctx.have_bufs) return;
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure => if (ctx.frame == 0) ctx.redraw(),
            .frame => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn finished(ctx: *const Ctx) bool {
        return ctx.frames != 0 and ctx.frame >= ctx.frames;
    }

    fn maybeDone(ctx: *Ctx) void {
        if (!ctx.finished() or ctx.done_said) return;
        for (ctx.bufs) |b| if (b.busy) return;
        ctx.done_said = true;
        wl.print("external: done frames={d}", .{ctx.frame});
    }

    fn redraw(ctx: *Ctx) void {
        if (ctx.finished()) return;
        const c = ctx.app.c;
        const b = for (&ctx.bufs) |*b| {
            if (!b.busy) break b;
        } else {
            ctx.starved = true; // a release will come
            return;
        };
        ctx.starved = false;
        ctx.frame += 1;
        if (!ctx.external) {
            // what the page would have drawn: a band that moves
            const t = ctx.frame * 3;
            for (0..H) |y| for (0..W) |x| {
                b.px[y * W + x] = if ((x + t) % W < 40) 0xff33ccff else 0xff304050;
            };
        }
        c.send(ctx.win.surface, "wl_surface", "attach", &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
        c.send(ctx.win.surface, "wl_surface", "damage_buffer", &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = W }, .{ .int = H } });
        if (!ctx.finished()) ctx.win.requestFrame(&ctx.app);
        c.send(ctx.win.surface, "wl_surface", "commit", &.{});
        b.busy = true;
        if (ctx.external) wl.print("external: commit id=0x{x:0>16} frame={d}", .{ b.ext, ctx.frame }) else wl.print("external: commit wl_shm frame={d}", .{ctx.frame});
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    var ctx: Ctx = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) {
            i += 1;
            ctx.frames = std.fmt.parseInt(u32, args[i], 10) catch wl.fail("--frames takes a count, not {s}", .{args[i]});
        } else wl.fail("external: unknown argument {s} (usage: external [--frames N])", .{args[i]});
    }
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    const mgr = c.bind("wland_external_buffer_manager_v1", 1);
    if (mgr != 0) {
        ctx.external = true;
        wl.print("external: offered", .{});
        for (&ctx.bufs, ids) |*b, ext| {
            const id = c.new("wl_buffer");
            c.send(mgr, "wland_external_buffer_manager_v1", "create_buffer", &.{
                .{ .new_id = id }, .{ .uint = @truncate(ext >> 32) }, .{ .uint = @truncate(ext) },
                .{ .int = W },     .{ .int = H },                     .{ .uint = fourcc_argb8888 },
                .{ .uint = 0 },
            });
            b.* = .{ .id = id, .ext = ext };
            wl.print("external: buffer id=0x{x:0>16} {d}x{d}", .{ ext, W, H });
        }
        // buffers stay; the manager is no longer needed
        c.destroy(mgr, "wland_external_buffer_manager_v1");
    } else {
        wl.print("external: not offered", .{});
        var pool = wl.Pool.create(c, ctx.app.shm, 2, W, H, wl.ARGB8888, 0);
        for (&ctx.bufs, pool.buffers[0..2]) |*b, pb| b.* = .{ .id = pb.id, .px = pb.pixels };
        wl.print("external: wl_shm fallback {d}x{d}", .{ W, H });
    }
    ctx.win = app_mod.Window.create(&ctx.app, "external-buffers", "wland-fixture", W, H);
    ctx.have_bufs = true;
    while (!ctx.done) {
        if (!c.dispatch(&ctx, -1)) break;
    }
}
