// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `touch`: weston-simple-touch's part — a 600×500 toplevel titled
//! "simple-touch" that binds wl_touch when the seat has the capability (and
//! releases it if the capability goes) and paints a 5×5 dot, a colour per
//! id, where each point goes down and moves. Read it through WAYLAND_DEBUG
//! like the real one: `wl_touch#N.down(serial, time, wl_surface#S, id, x, y)`,
//! `motion(time, id, x, y)`, `up(serial, time, id)`, `frame()`, `cancel()`
//! (test/support/touch-log.ts parses libwayland's lines and these alike).
//!
//! Beyond the real one, which only paints: a 40 px title strip at its top
//! where a touch-down starts xdg_toplevel.move with the down's serial (what
//! GTK's header bar does with a finger: the move-by-finger path), and the
//! pointer and keyboard App binds for every fixture (the real one takes
//! wl_touch alone), so a finger reaching it as both a touch point and the
//! pointer shows in its log.

const std = @import("std");
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const Plane = @import("pointer.zig").Plane;

const W = 600;
const H = 500;
/// the title strip: a touch-down above this y moves the window
pub const STRIP = 40;

const colours = [_]u32{ 0xffff5050, 0xff50ff50, 0xff5090ff, 0xffffff50, 0xffff50ff, 0xff50ffff };

const Ctx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    main: Plane = undefined,
    touch: u32 = 0,
    /// a dot painted while no buffer was free: commit at the next release
    dirty: bool = false,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        const c = ctx.app.c;
        if (ev.is("wl_seat", "capabilities")) {
            const has = ev.uint(0) & 4 != 0;
            if (has and ctx.touch == 0) {
                ctx.touch = c.new("wl_touch");
                c.send(ctx.app.seat, "wl_seat", "get_touch", &.{.{ .new_id = ctx.touch }});
            } else if (!has and ctx.touch != 0) {
                c.send(ctx.touch, "wl_touch", "release", &.{});
                ctx.touch = 0;
            }
            // (App binds the pointer and keyboard)
        }
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.main.pool.released(ev.id);
            if (ctx.dirty) ctx.show();
            return;
        }
        if (!ctx.ready) return;
        if (ev.is("wl_touch", "down")) {
            if (ev.uint(2) == ctx.win.surface and ev.num(5) < STRIP) {
                c.send(ctx.win.toplevel, "xdg_toplevel", "move", &.{ .{ .object = ctx.app.seat }, .{ .uint = ev.uint(0) } });
            } else ctx.dot(ev.int(3), ev.num(4), ev.num(5));
            return;
        }
        if (ev.is("wl_touch", "motion")) {
            ctx.dot(ev.int(1), ev.num(2), ev.num(3));
            return;
        }
        // up, frame, cancel (shape, orientation): logged under WAYLAND_DEBUG
        if (ev.iface == (comptime wl.iface("wl_touch")) or ev.iface == (comptime wl.iface("wl_keyboard")) or
            ev.iface == (comptime wl.iface("wl_pointer"))) return;
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure, .scale => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn redraw(ctx: *Ctx) void {
        ctx.main.scale = ctx.win.scale;
        const b = ctx.main.buffer(&ctx.app, W, H) orelse return;
        // every buffer of the pool starts from the same picture: the dots
        // go into all of them
        for (ctx.main.pool.buffers[0..ctx.main.pool.n]) |*each| {
            var cv = Plane.canvas(each);
            const s: i32 = @intCast(ctx.win.scale);
            cv.gradient(0, 0, @intCast(each.width), @intCast(each.height), 0xff203040, 0xff102030);
            cv.rect(0, 0, @intCast(each.width), STRIP * s, 0xff404858);
            cv.text(12 * s, 12 * s, 3 * s, 0xffffffff, "SIMPLE-TOUCH");
        }
        ctx.main.commit(&ctx.app, b);
    }

    fn dot(ctx: *Ctx, id: i32, x: f64, y: f64) void {
        if (ctx.main.pool.n == 0) return;
        const s: f64 = @floatFromInt(ctx.win.scale);
        // (a point keeps its surface's coordinates outside it: far off is fine)
        const px: i32 = @intFromFloat(std.math.clamp(x * s, -1e4, 1e4));
        const py: i32 = @intFromFloat(std.math.clamp(y * s, -1e4, 1e4));
        const r: i32 = @intFromFloat(2 * s);
        const colour = colours[@intCast(@mod(id, @as(i32, colours.len)))];
        for (ctx.main.pool.buffers[0..ctx.main.pool.n]) |*each| {
            var cv = Plane.canvas(each);
            cv.rect(px - r, py - r, 2 * r + 1, 2 * r + 1, colour);
        }
        ctx.show();
    }

    fn show(ctx: *Ctx) void {
        const b = ctx.main.pool.free() orelse {
            ctx.dirty = true;
            return;
        };
        ctx.dirty = false;
        ctx.main.commit(&ctx.app, b);
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: Ctx = .{};
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    c.roundtrip(&ctx);
    ctx.win = app_mod.Window.create(&ctx.app, "simple-touch", "wland-fixture", W, H);
    ctx.main = .{ .surface = ctx.win.surface };
    ctx.ready = true;
    while (!ctx.done) if (!c.dispatch(&ctx, -1)) break;
}
