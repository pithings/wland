// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `game`: an SDL2 game's window (neverball through SDL 2.32's Wayland
//! backend). It binds zxdg_decoration_manager_v1, makes the toplevel and
//! its decoration object before the initial commit, waits for the first
//! configure, then attaches an 800×600 buffer with no frame of its own.
//! Prints `decoration: server_side` / `decoration: client_side` per
//! decoration configure and `Created a window` after its first buffer
//! (neverball's line). `b` toggles the border as SDL_SetWindowBordered
//! does: set_mode(client_side), then set_mode(server_side).
//!
//! Real SDL 2.32.4 answered client_side moves the window to libdecor in the
//! middle of that first wait and never attaches a buffer (WINDOW.md of the
//! unkernel page); the fixture does not mimic the hang: it just draws.

const std = @import("std");
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const Plane = @import("pointer.zig").Plane;

const W = 800;
const H = 600;
const mode_client_side: u32 = 1;
const mode_server_side: u32 = 2;

const Ctx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    decoration: u32 = 0,
    main: Plane = undefined,
    bordered: bool = true,
    shown: bool = false,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.main.pool.released(ev.id);
            return;
        }
        if (!ctx.ready) return;
        if (ev.id == ctx.decoration and ev.is("zxdg_toplevel_decoration_v1", "configure")) {
            wl.print("decoration: {s}\n", .{if (ev.uint(0) == mode_server_side) "server_side" else "client_side"});
            return;
        }
        if (ev.is("wl_keyboard", "key")) {
            if (ev.uint(3) == 1 and ev.uint(2) == 48) { // b
                ctx.bordered = !ctx.bordered;
                ctx.app.c.send(ctx.decoration, "zxdg_toplevel_decoration_v1", "set_mode", &.{.{ .uint = if (ctx.bordered) mode_server_side else mode_client_side }});
            }
            return;
        }
        if (ev.iface == (comptime wl.iface("wl_keyboard")) or ev.iface == (comptime wl.iface("wl_pointer"))) return;
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure => ctx.redraw(),
            .scale => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    /// A fixed 800×600 picture (SDL games keep their video mode), drawn
    /// edge to edge: no title bar, no border.
    fn redraw(ctx: *Ctx) void {
        ctx.main.scale = ctx.win.scale;
        const b = ctx.main.buffer(&ctx.app, W, H) orelse return;
        var cv = Plane.canvas(b);
        const s: i32 = @intCast(ctx.win.scale);
        cv.gradient(0, 0, @intCast(b.width), @intCast(b.height), 0xff206030, 0xff103018);
        cv.text(20 * s, 20 * s, 3 * s, 0xffffffff, "GAME");
        ctx.main.commit(&ctx.app, b);
        if (!ctx.shown) {
            ctx.shown = true;
            wl.print("Created a window\n", .{});
        }
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: Ctx = .{};
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    c.roundtrip(&ctx);
    const manager = c.mustBind("zxdg_decoration_manager_v1", 1);
    if (ctx.app.wm_base == 0) wl.fail("xdg_wm_base is not advertised", .{});
    // SDL's order: surface, xdg_surface, toplevel, title and app id, the
    // decoration object, then the initial commit and a wait for configure
    const s = ctx.app.surface();
    const xs = c.new("xdg_surface");
    c.send(ctx.app.wm_base, "xdg_wm_base", "get_xdg_surface", &.{ .{ .new_id = xs }, .{ .object = s } });
    const tl = c.new("xdg_toplevel");
    c.send(xs, "xdg_surface", "get_toplevel", &.{.{ .new_id = tl }});
    c.send(tl, "xdg_toplevel", "set_title", &.{.{ .string = "game" }});
    c.send(tl, "xdg_toplevel", "set_app_id", &.{.{ .string = "wland-fixture.game" }});
    ctx.decoration = c.new("zxdg_toplevel_decoration_v1");
    c.send(manager, "zxdg_decoration_manager_v1", "get_toplevel_decoration", &.{ .{ .new_id = ctx.decoration }, .{ .object = tl } });
    c.send(s, "wl_surface", "commit", &.{});
    ctx.win = .{ .surface = s, .xdg_surface = xs, .toplevel = tl, .width = W, .height = H };
    ctx.main = .{ .surface = s };
    ctx.ready = true;
    while (!ctx.done) if (!c.dispatch(&ctx, -1)) break;
    // the decoration object goes before its toplevel (xdg-decoration)
    c.send(ctx.decoration, "zxdg_toplevel_decoration_v1", "destroy", &.{});
    c.send(tl, "xdg_toplevel", "destroy", &.{});
    c.flush();
}
