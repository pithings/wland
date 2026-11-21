// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! The pointer fixtures.
//!
//! `cursor` (weston-flower's part): a window that sets a cursor SURFACE on
//! every pointer enter (wl_pointer.set_cursor, no cursor-shape): a 24×24
//! ARGB arrow, hotspot (4, 2).
//!
//! `constraints` (weston-constraints'): a 400×300 window with a 125×100
//! gray subsurface. Presses on the subsurface cycle: confine (oneshot) →
//! lock (oneshot) → none. The relative pointer is taken on locked() and
//! dropped on unlocked(), as weston-constraints does. Read it through
//! WAYLAND_DEBUG, like the real one.
//!
//! `relative` (an SDL app in relative mouse mode): the first press locks the
//! pointer (persistent) and takes a relative pointer, printing `RELATIVE 1`;
//! every motion prints `MOTION x y xrel yrel rel=0|1` like SDL's event loop.

const std = @import("std");
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");

const BTN_LEFT = 0x110;

/// A surface with its own buffers, redrawn whole on demand.
pub const Plane = struct {
    surface: u32,
    pool: wl.Pool = .{ .mem = &.{}, .n = 0 },
    w: u32 = 0,
    h: u32 = 0,
    scale: u32 = 1,
    format: u32 = wl.XRGB8888,
    pool_scale: u32 = 0,

    /// A free buffer of `w`×`h` logical px at `scale` (null: none free yet).
    pub fn buffer(p: *Plane, app: *app_mod.App, w: u32, h: u32) ?*wl.Buffer {
        if (p.pool.n == 0 or p.w != w or p.h != h or p.pool_scale != p.scale) {
            if (p.pool.n != 0) p.pool.destroy(app.c);
            p.pool = wl.Pool.create(app.c, app.shm, 2, w * p.scale, h * p.scale, p.format, 0);
            p.w = w;
            p.h = h;
            p.pool_scale = p.scale;
        }
        return p.pool.free();
    }

    pub fn commit(p: *Plane, app: *app_mod.App, b: *wl.Buffer) void {
        p.attach(app, b);
        app.c.send(p.surface, "wl_surface", "commit", &.{});
    }

    /// Attach + full damage, no commit.
    pub fn attach(p: *Plane, app: *app_mod.App, b: *wl.Buffer) void {
        const c = app.c;
        c.send(p.surface, "wl_surface", "set_buffer_scale", &.{.{ .int = @intCast(p.scale) }});
        c.send(p.surface, "wl_surface", "attach", &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
        c.send(p.surface, "wl_surface", "damage_buffer", &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = @intCast(b.width) }, .{ .int = @intCast(b.height) } });
        b.busy = true;
    }

    /// A canvas in logical px: the buffer, drawn at `scale`.
    pub fn canvas(b: *wl.Buffer) draw.Canvas {
        return .{ .px = b.pixels, .w = b.width, .h = b.height };
    }
};

// --- cursor ---------------------------------------------------------------------

const CursorCtx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    main: Plane = undefined,
    cursor: Plane = undefined,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *CursorCtx, ev: wl.Event) void {
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.main.pool.released(ev.id) or ctx.cursor.pool.released(ev.id);
            return;
        }
        if (!ctx.ready) return;
        if (ev.is("wl_pointer", "enter")) {
            ctx.app.c.send(ctx.app.pointer, "wl_pointer", "set_cursor", &.{ .{ .uint = ev.uint(0) }, .{ .object = ctx.cursor.surface }, .{ .int = 4 }, .{ .int = 2 } });
            return;
        }
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure, .scale => ctx.drawMain(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn drawMain(ctx: *CursorCtx) void {
        ctx.main.scale = ctx.win.scale;
        const b = ctx.main.buffer(&ctx.app, 240, 240) orelse return;
        var cv = Plane.canvas(b);
        // petals: rings of hues
        const n = b.width;
        for (0..b.height) |y| for (0..n) |x| {
            const dx = @as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(n)) / 2;
            const dy = @as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(b.height)) / 2;
            const a = std.math.atan2(dy, dx);
            const r = @sqrt(dx * dx + dy * dy) / @as(f32, @floatFromInt(n));
            const petal = @abs(@cos(a * 5)) * 0.4 + 0.05;
            cv.px[y * n + x] = if (r < 0.08) 0xffe0c020 else if (r < petal) draw.mix(0xffd02060, 0xff6020d0, @intFromFloat(@min(r / petal, 1) * 255)) else 0xff204020;
        };
        ctx.main.commit(&ctx.app, b);
    }

    fn drawCursor(ctx: *CursorCtx) void {
        ctx.cursor.format = wl.ARGB8888;
        const b = ctx.cursor.buffer(&ctx.app, 24, 24) orelse return;
        var cv = Plane.canvas(b);
        @memset(cv.px, 0);
        // an arrow: a filled triangle with an outline
        for (0..18) |y| for (0..18) |x| {
            if (x <= y and x + y / 2 < 20) cv.px[(y + 2) * 24 + x + 4] = if (x == 0 or x == y or y == 17) 0xff000000 else 0xffffffff;
        };
        ctx.cursor.commit(&ctx.app, b);
    }
};

pub fn runCursor(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: CursorCtx = .{};
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    ctx.app.c.roundtrip(&ctx);
    ctx.cursor = .{ .surface = ctx.app.surface() };
    ctx.drawCursor();
    ctx.win = app_mod.Window.create(&ctx.app, "flower", "wland-fixture", 240, 240);
    ctx.main = .{ .surface = ctx.win.surface };
    ctx.ready = true;
    while (!ctx.done) if (!ctx.app.c.dispatch(&ctx, -1)) break;
}

// --- constraints ------------------------------------------------------------------

const ConstraintsCtx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    main: Plane = undefined,
    sub: Plane = undefined,
    subsurface: u32 = 0,
    constraints: u32 = 0,
    relative_mgr: u32 = 0,
    confined: u32 = 0,
    locked: u32 = 0,
    relative: u32 = 0,
    /// the surface under the pointer
    over: u32 = 0,
    state: enum { none, confined, locked } = .none,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *ConstraintsCtx, ev: wl.Event) void {
        const c = ctx.app.c;
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.main.pool.released(ev.id) or ctx.sub.pool.released(ev.id);
            return;
        }
        if (!ctx.ready) return;
        if (ev.is("wl_pointer", "enter")) {
            ctx.over = ev.uint(1);
        } else if (ev.is("wl_pointer", "leave")) {
            ctx.over = 0;
        } else if (ev.is("wl_pointer", "button")) {
            if (ev.uint(2) != BTN_LEFT or ev.uint(3) != 1 or ctx.over != ctx.sub.surface) return;
            switch (ctx.state) {
                .none => {
                    ctx.confined = c.new("zwp_confined_pointer_v1");
                    c.send(ctx.constraints, "zwp_pointer_constraints_v1", "confine_pointer", &.{ .{ .new_id = ctx.confined }, .{ .object = ctx.sub.surface }, .{ .object = ctx.app.pointer }, .{ .object = 0 }, .{ .uint = 1 } });
                    ctx.state = .confined;
                },
                .confined => {
                    c.destroy(ctx.confined, "zwp_confined_pointer_v1");
                    ctx.confined = 0;
                    ctx.locked = c.new("zwp_locked_pointer_v1");
                    c.send(ctx.constraints, "zwp_pointer_constraints_v1", "lock_pointer", &.{ .{ .new_id = ctx.locked }, .{ .object = ctx.sub.surface }, .{ .object = ctx.app.pointer }, .{ .object = 0 }, .{ .uint = 1 } });
                    ctx.state = .locked;
                },
                .locked => {},
            }
        } else if (ev.is("zwp_confined_pointer_v1", "confined")) {
            // (logged under WAYLAND_DEBUG; nothing to do)
        } else if (ev.is("zwp_confined_pointer_v1", "unconfined")) {
            c.destroy(ctx.confined, "zwp_confined_pointer_v1");
            ctx.confined = 0;
            ctx.state = .none;
        } else if (ev.is("zwp_locked_pointer_v1", "locked")) {
            ctx.relative = c.new("zwp_relative_pointer_v1");
            c.send(ctx.relative_mgr, "zwp_relative_pointer_manager_v1", "get_relative_pointer", &.{ .{ .new_id = ctx.relative }, .{ .object = ctx.app.pointer } });
        } else if (ev.is("zwp_locked_pointer_v1", "unlocked")) {
            if (ctx.relative != 0) c.destroy(ctx.relative, "zwp_relative_pointer_v1");
            ctx.relative = 0;
            c.destroy(ctx.locked, "zwp_locked_pointer_v1");
            ctx.locked = 0;
            ctx.state = .none;
        } else switch (ctx.win.handle(&ctx.app, ev)) {
            .configure, .scale => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn redraw(ctx: *ConstraintsCtx) void {
        ctx.sub.scale = ctx.win.scale;
        if (ctx.sub.buffer(&ctx.app, 125, 100)) |b| {
            var cv = Plane.canvas(b);
            cv.rect(0, 0, @intCast(b.width), @intCast(b.height), 0xff808080);
            ctx.sub.commit(&ctx.app, b);
        }
        ctx.main.scale = ctx.win.scale;
        if (ctx.main.buffer(&ctx.app, 400, 300)) |b| {
            var cv = Plane.canvas(b);
            cv.gradient(0, 0, @intCast(b.width), @intCast(b.height), 0xff203050, 0xff102030);
            ctx.main.commit(&ctx.app, b);
        }
    }
};

pub fn runConstraints(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: ConstraintsCtx = .{};
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    ctx.constraints = c.mustBind("zwp_pointer_constraints_v1", 1);
    ctx.relative_mgr = c.mustBind("zwp_relative_pointer_manager_v1", 1);
    c.roundtrip(&ctx);
    ctx.win = app_mod.Window.create(&ctx.app, "constraints", "wland-fixture", 400, 300);
    ctx.main = .{ .surface = ctx.win.surface };
    ctx.sub = .{ .surface = ctx.app.surface() };
    ctx.subsurface = ctx.app.subsurface(ctx.sub.surface, ctx.win.surface);
    c.send(ctx.subsurface, "wl_subsurface", "set_position", &.{ .{ .int = 137 }, .{ .int = 100 } });
    c.send(ctx.subsurface, "wl_subsurface", "set_desync", &.{});
    ctx.ready = true;
    while (!ctx.done) if (!c.dispatch(&ctx, -1)) break;
}

// --- relative (SDL's relative mouse mode) ------------------------------------------

const RelativeCtx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    main: Plane = undefined,
    constraints: u32 = 0,
    relative_mgr: u32 = 0,
    locked: u32 = 0,
    relative: u32 = 0,
    rel: bool = false,
    x: f64 = 0,
    y: f64 = 0,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *RelativeCtx, ev: wl.Event) void {
        const c = ctx.app.c;
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.main.pool.released(ev.id);
            return;
        }
        if (!ctx.ready) return;
        if (ev.is("wl_pointer", "enter")) {
            ctx.x = ev.num(2);
            ctx.y = ev.num(3);
        } else if (ev.is("wl_pointer", "motion")) {
            const dx = ev.num(1) - ctx.x;
            const dy = ev.num(2) - ctx.y;
            ctx.x = ev.num(1);
            ctx.y = ev.num(2);
            if (!ctx.rel) wl.print("MOTION {d:.2} {d:.2} {d:.2} {d:.2} rel=0", .{ ctx.x, ctx.y, dx, dy });
        } else if (ev.is("zwp_relative_pointer_v1", "relative_motion")) {
            wl.print("MOTION {d:.2} {d:.2} {d:.2} {d:.2} rel=1", .{ ctx.x, ctx.y, ev.num(2), ev.num(3) });
        } else if (ev.is("wl_pointer", "button")) {
            if (ev.uint(2) != BTN_LEFT or ev.uint(3) != 1 or ctx.rel) return;
            ctx.locked = c.new("zwp_locked_pointer_v1");
            c.send(ctx.constraints, "zwp_pointer_constraints_v1", "lock_pointer", &.{ .{ .new_id = ctx.locked }, .{ .object = ctx.win.surface }, .{ .object = ctx.app.pointer }, .{ .object = 0 }, .{ .uint = 2 } });
            ctx.relative = c.new("zwp_relative_pointer_v1");
            c.send(ctx.relative_mgr, "zwp_relative_pointer_manager_v1", "get_relative_pointer", &.{ .{ .new_id = ctx.relative }, .{ .object = ctx.app.pointer } });
            ctx.rel = true;
            wl.print("RELATIVE 1", .{});
            ctx.redraw();
        } else if (ev.is("zwp_locked_pointer_v1", "locked") or ev.is("zwp_locked_pointer_v1", "unlocked")) {
            // persistent: the compositor re-locks it on a later press
        } else switch (ctx.win.handle(&ctx.app, ev)) {
            .configure, .scale => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn redraw(ctx: *RelativeCtx) void {
        ctx.main.scale = ctx.win.scale;
        const b = ctx.main.buffer(&ctx.app, 320, 240) orelse return;
        var cv = Plane.canvas(b);
        cv.rect(0, 0, @intCast(b.width), @intCast(b.height), if (ctx.rel) 0xff2878c8 else 0xff2828c8);
        ctx.main.commit(&ctx.app, b);
    }
};

pub fn runRelative(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: RelativeCtx = .{};
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    ctx.constraints = c.mustBind("zwp_pointer_constraints_v1", 1);
    ctx.relative_mgr = c.mustBind("zwp_relative_pointer_manager_v1", 1);
    c.roundtrip(&ctx);
    ctx.win = app_mod.Window.create(&ctx.app, "sdl-relative", "wland-fixture", 320, 240);
    ctx.main = .{ .surface = ctx.win.surface };
    ctx.ready = true;
    while (!ctx.done) if (!c.dispatch(&ctx, -1)) break;
}
