// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `fullscreen [-f]`: weston-fullscreen's part — a 400×300 toplevel drawn
//! at whatever size it is configured to; the `f` key toggles
//! set_fullscreen / unset_fullscreen; with -f it asks for fullscreen before
//! its first commit (it maps fullscreen).

const std = @import("std");
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const Plane = @import("pointer.zig").Plane;

const W = 400;
const H = 300;

const Ctx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    main: Plane = undefined,
    w: u32 = W,
    h: u32 = H,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.main.pool.released(ev.id);
            return;
        }
        if (!ctx.ready) return;
        if (ev.is("wl_keyboard", "key")) {
            if (ev.uint(3) == 1 and ev.uint(2) == 33) { // f
                if (ctx.win.fullscreen) {
                    ctx.app.c.send(ctx.win.toplevel, "xdg_toplevel", "unset_fullscreen", &.{});
                } else {
                    ctx.app.c.send(ctx.win.toplevel, "xdg_toplevel", "set_fullscreen", &.{.{ .object = 0 }});
                }
            }
            return;
        }
        if (ev.iface == (comptime wl.iface("wl_keyboard")) or ev.iface == (comptime wl.iface("wl_pointer"))) return;
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure => {
                if (ctx.win.want_w > 0 and ctx.win.want_h > 0) {
                    ctx.w = ctx.win.want_w;
                    ctx.h = ctx.win.want_h;
                } else if (!ctx.win.fullscreen and !ctx.win.maximized) {
                    ctx.w = W;
                    ctx.h = H;
                }
                ctx.redraw();
            },
            .scale => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn redraw(ctx: *Ctx) void {
        ctx.main.scale = ctx.win.scale;
        const b = ctx.main.buffer(&ctx.app, ctx.w, ctx.h) orelse return;
        var cv = Plane.canvas(b);
        const s: i32 = @intCast(ctx.win.scale);
        cv.gradient(0, 0, @intCast(b.width), @intCast(b.height), 0xff304060, 0xff603040);
        cv.text(20 * s, 20 * s, 3 * s, 0xffffffff, if (ctx.win.fullscreen) "FULLSCREEN - F TO LEAVE" else "F FOR FULLSCREEN");
        ctx.main.commit(&ctx.app, b);
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    var ctx: Ctx = .{};
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    c.roundtrip(&ctx);
    const start_fs = args.len > 0 and std.mem.eql(u8, args[0], "-f");
    ctx.win = app_mod.Window.createWith(&ctx.app, "fullscreen", "wland-fixture", W, H, start_fs);
    ctx.main = .{ .surface = ctx.win.surface };
    ctx.ready = true;
    while (!ctx.done) if (!c.dispatch(&ctx, -1)) break;
}
