// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `shm`: weston-simple-shm's shape — one XRGB toplevel, two buffers,
//! redrawn whole on every frame callback with a moving pattern.
//! `presentation`: weston-presentation-shm -f's — the same window, a
//! wp_presentation_feedback per commit, one stdout line per answer:
//!   `N: c2p MS ms, p2p US us` (presented; c2p = commit → presentation on
//!   this process's CLOCK_MONOTONIC, printed unsigned), `discarded N`, and
//!   at SIGINT/SIGTERM `clean up feedback N` for every feedback still held
//!   (the outstanding ones and the last presented one).

const std = @import("std");
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");

const W = 250;
const H = 250;

const Feedback = struct { id: u32, frame: u32, commit_ns: u64 };

const Ctx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    pool: wl.Pool = undefined,
    have_pool: bool = false,
    frame: u32 = 0,
    presentation: u32 = 0,
    clock_id: u32 = 1,
    feedbacks: std.ArrayList(Feedback) = .empty,
    last_presented: ?u32 = null,
    last_present_ns: u64 = 0,
    gpa: std.mem.Allocator,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.pool.released(ev.id);
            return;
        }
        if (ev.is("wp_presentation", "clock_id")) {
            ctx.clock_id = ev.uint(0);
            return;
        }
        if (ev.is("wp_presentation_feedback", "sync_output")) return;
        if (ev.is("wp_presentation_feedback", "presented")) {
            const fb = ctx.take(ev.id) orelse return;
            const sec = (@as(u64, ev.uint(0)) << 32) | ev.uint(1);
            const t = sec * std.time.ns_per_s + ev.uint(2);
            const c2p: u32 = @truncate((t -% fb.commit_ns) / std.time.ns_per_ms);
            const p2p: i64 = if (ctx.last_present_ns == 0) 0 else @divTrunc(@as(i64, @intCast(t)) - @as(i64, @intCast(ctx.last_present_ns)), 1000);
            var nb: [24]u8 = undefined;
            const p2p_s = std.fmt.bufPrint(&nb, "{s}{d}", .{ if (p2p < 0) "-" else "", @abs(p2p) }) catch "0";
            wl.print("{d:>4}: c2p {d:>4} ms, p2p {s:>5} us", .{ fb.frame, c2p, p2p_s });
            ctx.last_present_ns = t;
            ctx.last_presented = fb.frame;
            return;
        }
        if (ev.is("wp_presentation_feedback", "discarded")) {
            const fb = ctx.take(ev.id) orelse return;
            wl.print("discarded {d}", .{fb.frame});
            return;
        }
        if (!ctx.have_pool) return; // before the window exists
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure => if (ctx.frame == 0) ctx.redraw(),
            .frame => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn take(ctx: *Ctx, id: u32) ?Feedback {
        for (ctx.feedbacks.items, 0..) |f, i| {
            if (f.id == id) return ctx.feedbacks.orderedRemove(i);
        }
        return null;
    }

    fn redraw(ctx: *Ctx) void {
        const c = ctx.app.c;
        const b = ctx.pool.free() orelse return; // a release will come
        ctx.frame += 1;
        var cv: draw.Canvas = .{ .px = b.pixels, .w = W, .h = H };
        // weston-simple-shm's moving rings, more or less
        const t = ctx.frame * 3;
        for (0..H) |y| {
            for (0..W) |x| {
                const dx: i32 = @as(i32, @intCast(x)) - W / 2;
                const dy: i32 = @as(i32, @intCast(y)) - H / 2;
                const r: u32 = @intCast(@divTrunc(dx * dx + dy * dy, 64));
                const v = (r + t) & 0xff;
                cv.px[y * W + x] = 0x00000000 | (v << 16) | (((v * 3) & 0xff) << 8) | ((255 - v) & 0xff);
            }
        }
        c.send(ctx.win.surface, "wl_surface", "attach", &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
        c.send(ctx.win.surface, "wl_surface", "damage_buffer", &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = W }, .{ .int = H } });
        ctx.win.requestFrame(&ctx.app);
        if (ctx.presentation != 0) {
            const fb = c.new("wp_presentation_feedback");
            c.send(ctx.presentation, "wp_presentation", "feedback", &.{ .{ .object = ctx.win.surface }, .{ .new_id = fb } });
            ctx.feedbacks.append(ctx.gpa, .{ .id = fb, .frame = ctx.frame, .commit_ns = clockNs(ctx.clock_id) }) catch {};
        }
        c.send(ctx.win.surface, "wl_surface", "commit", &.{});
        b.busy = true;
    }
};

fn clockNs(clock_id: u32) u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(@enumFromInt(clock_id), &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, presentation: bool) void {
    var ctx: Ctx = .{ .gpa = gpa };
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    if (presentation) {
        ctx.presentation = ctx.app.c.mustBind("wp_presentation", 1);
    }
    ctx.app.c.roundtrip(&ctx);
    ctx.pool = wl.Pool.create(ctx.app.c, ctx.app.shm, 2, W, H, wl.XRGB8888, 0);
    ctx.win = app_mod.Window.create(&ctx.app, if (presentation) "presentation-shm" else "simple-shm", "wland-fixture", W, H);
    ctx.have_pool = true;
    while (!ctx.done) {
        if (!ctx.app.c.dispatch(&ctx, -1)) break;
    }
    if (presentation) {
        for (ctx.feedbacks.items) |f| wl.print("clean up feedback {d}", .{f.frame});
        if (ctx.last_presented) |f| wl.print("clean up feedback {d}", .{f});
    }
}

pub fn runShm(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    run(gpa, env, false);
}

pub fn runPresentation(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    run(gpa, env, true);
}
