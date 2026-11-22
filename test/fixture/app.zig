// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! What every windowed fixture shares: the globals, the seat (pointer,
//! keyboard with a US layout), xdg_wm_base pings, toplevel windows.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl.zig");

pub const App = struct {
    c: *wl.Client,
    compositor: u32 = 0,
    subcompositor: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    output: u32 = 0,
    cursor_shape: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    shape_device: u32 = 0,
    /// modifiers: Shift (xkb mod index 0) held
    shift: bool = false,
    ctrl: bool = false,
    /// NumLock (Mod2, xkb mod index 4) locked: keypad keys type digits
    numlock: bool = false,
    keymap_ok: bool = false,

    /// Connect, read the globals and bind the usual ones.
    pub fn init(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, ctx: anytype) App {
        return initSeat(gpa, environ, ctx, 8);
    }

    /// init, with wl_seat bound at (at most) `seat_version`.
    pub fn initSeat(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, ctx: anytype, seat_version: u32) App {
        var app: App = .{ .c = wl.Client.connect(gpa, environ) catch wl.fail("connect failed", .{}) };
        const c = app.c;
        c.start(ctx);
        app.compositor = c.mustBind("wl_compositor", 6);
        app.subcompositor = c.bind("wl_subcompositor", 1);
        app.shm = c.mustBind("wl_shm", 1);
        app.wm_base = c.bind("xdg_wm_base", 6);
        app.seat = c.bind("wl_seat", seat_version);
        app.output = c.bind("wl_output", 4);
        app.cursor_shape = c.bind("wp_cursor_shape_manager_v1", 1);
        return app;
    }

    /// Events every fixture answers the same way. True: consumed.
    pub fn handle(app: *App, ev: wl.Event) bool {
        const c = app.c;
        if (ev.is("xdg_wm_base", "ping")) {
            c.send(ev.id, "xdg_wm_base", "pong", &.{.{ .uint = ev.uint(0) }});
            return true;
        }
        if (ev.is("wl_seat", "capabilities")) {
            const caps = ev.uint(0);
            if (caps & 1 != 0 and app.pointer == 0) {
                app.pointer = c.new("wl_pointer");
                c.send(app.seat, "wl_seat", "get_pointer", &.{.{ .new_id = app.pointer }});
                if (app.cursor_shape != 0) {
                    app.shape_device = c.new("wp_cursor_shape_device_v1");
                    c.send(app.cursor_shape, "wp_cursor_shape_manager_v1", "get_pointer", &.{ .{ .new_id = app.shape_device }, .{ .object = app.pointer } });
                }
            }
            if (caps & 2 != 0 and app.keyboard == 0) {
                app.keyboard = c.new("wl_keyboard");
                c.send(app.seat, "wl_seat", "get_keyboard", &.{.{ .new_id = app.keyboard }});
            }
            return true;
        }
        if (ev.is("wl_keyboard", "keymap")) {
            // what xkbcommon would choke on, we do too: a readable xkb text
            const size = ev.uint(2);
            const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, ev.fd, 0);
            if (linux.errno(addr) != .SUCCESS) wl.fail("cannot map the keymap ({d} bytes)", .{size});
            const text: [*]const u8 = @ptrFromInt(addr);
            if (ev.uint(0) != 1 or size < 16 or !std.mem.startsWith(u8, text[0..size], "xkb_keymap")) wl.fail("the keymap is not xkb text", .{});
            app.keymap_ok = true;
            _ = linux.munmap(text, size);
            _ = linux.close(ev.fd);
            return true;
        }
        if (ev.is("wl_keyboard", "modifiers")) {
            const mods = ev.uint(1) | ev.uint(2);
            app.shift = mods & 1 != 0;
            app.ctrl = mods & 4 != 0;
            app.numlock = ev.uint(3) & 16 != 0;
            return true;
        }
        if (ev.is("wl_keyboard", "repeat_info") or ev.is("wl_seat", "name") or ev.iface == (comptime wl.iface("wl_output")) or
            ev.is("wl_shm", "format") or ev.is("wl_surface", "enter") or ev.is("wl_surface", "leave") or
            ev.is("wl_surface", "preferred_buffer_transform") or ev.is("xdg_toplevel", "configure_bounds") or
            ev.is("xdg_toplevel", "wm_capabilities") or ev.is("wl_pointer", "frame") or ev.is("wl_pointer", "axis_source") or
            ev.is("wl_pointer", "axis_stop") or ev.is("wl_pointer", "axis_discrete") or ev.is("wl_pointer", "axis_value120") or
            ev.is("wl_pointer", "axis_relative_direction"))
        {
            return true;
        }
        return false;
    }

    /// wp_cursor_shape_device_v1.set_shape (1 default, 9 text, 18+ resizes).
    pub fn setShape(app: *App, serial: u32, shape: u32) void {
        if (app.shape_device != 0) app.c.send(app.shape_device, "wp_cursor_shape_device_v1", "set_shape", &.{ .{ .uint = serial }, .{ .uint = shape } });
    }

    pub fn region(app: *App, rects: []const [4]i32) u32 {
        const r = app.c.new("wl_region");
        app.c.send(app.compositor, "wl_compositor", "create_region", &.{.{ .new_id = r }});
        for (rects) |q| app.c.send(r, "wl_region", "add", &.{ .{ .int = q[0] }, .{ .int = q[1] }, .{ .int = q[2] }, .{ .int = q[3] } });
        return r;
    }

    pub fn surface(app: *App) u32 {
        const s = app.c.new("wl_surface");
        app.c.send(app.compositor, "wl_compositor", "create_surface", &.{.{ .new_id = s }});
        return s;
    }

    pub fn subsurface(app: *App, s: u32, parent: u32) u32 {
        if (app.subcompositor == 0) wl.fail("wl_subcompositor is not advertised", .{});
        const sub = app.c.new("wl_subsurface");
        app.c.send(app.subcompositor, "wl_subcompositor", "get_subsurface", &.{ .{ .new_id = sub }, .{ .object = s }, .{ .object = parent } });
        return sub;
    }
};

/// evdev keycode → character, US layout (plain, shifted). 0: none. The
/// keypad as the keymap's KEYPAD type has it: digits and '.' with NumLock
/// and no Shift, navigation (none here) otherwise; its operators always.
pub fn keyChar(code: u32, shift: bool, numlock: bool) u8 {
    const plain = "\x00\x001234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./";
    const shifted = "\x00\x00!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?";
    if (code == 57) return ' ';
    if (code == 96) return '\n'; // KP Enter
    switch (code) {
        55 => return '*',
        74 => return '-',
        78 => return '+',
        98 => return '/',
        71...73, 75...77, 79...83 => {
            if (!numlock or shift) return 0; // KP_Home, KP_Up, … KP_Delete
            const keypad = "789-456+1230.";
            return keypad[code - 71];
        },
        else => {},
    }
    if (code >= plain.len) return 0;
    return if (shift) shifted[code] else plain[code];
}

pub const Change = enum { none, configure, frame, scale, close };

/// An xdg_toplevel on one wl_surface. Sizes are logical.
pub const Window = struct {
    surface: u32,
    xdg_surface: u32,
    toplevel: u32,
    configured: bool = false,
    width: u32,
    height: u32,
    /// the last configure's suggestion (0 = the client's choice)
    want_w: u32 = 0,
    want_h: u32 = 0,
    maximized: bool = false,
    fullscreen: bool = false,
    activated: bool = false,
    scale: u32 = 1,
    frame_cb: u32 = 0,

    pub fn create(app: *App, title: []const u8, app_id: []const u8, width: u32, height: u32) Window {
        return createWith(app, title, app_id, width, height, false);
    }

    /// `fullscreen`: set_fullscreen before the initial commit (it maps so).
    pub fn createWith(app: *App, title: []const u8, app_id: []const u8, width: u32, height: u32, fullscreen: bool) Window {
        const c = app.c;
        if (app.wm_base == 0) wl.fail("xdg_wm_base is not advertised", .{});
        const s = app.surface();
        const xs = c.new("xdg_surface");
        c.send(app.wm_base, "xdg_wm_base", "get_xdg_surface", &.{ .{ .new_id = xs }, .{ .object = s } });
        const tl = c.new("xdg_toplevel");
        c.send(xs, "xdg_surface", "get_toplevel", &.{.{ .new_id = tl }});
        c.send(tl, "xdg_toplevel", "set_title", &.{.{ .string = title }});
        c.send(tl, "xdg_toplevel", "set_app_id", &.{.{ .string = app_id }});
        if (fullscreen) c.send(tl, "xdg_toplevel", "set_fullscreen", &.{.{ .object = 0 }});
        c.send(s, "wl_surface", "commit", &.{});
        return .{ .surface = s, .xdg_surface = xs, .toplevel = tl, .width = width, .height = height };
    }

    pub fn setTitle(win: *Window, app: *App, title: []const u8) void {
        app.c.send(win.toplevel, "xdg_toplevel", "set_title", &.{.{ .string = title }});
    }

    /// Ask for a frame callback with the next commit.
    pub fn requestFrame(win: *Window, app: *App) void {
        if (win.frame_cb != 0) return;
        win.frame_cb = app.c.new("wl_callback");
        app.c.send(win.surface, "wl_surface", "frame", &.{.{ .new_id = win.frame_cb }});
    }

    pub fn handle(win: *Window, app: *App, ev: wl.Event) Change {
        const c = app.c;
        if (ev.id == win.toplevel and ev.is("xdg_toplevel", "configure")) {
            win.want_w = @intCast(@max(ev.int(0), 0));
            win.want_h = @intCast(@max(ev.int(1), 0));
            const states = std.mem.bytesAsSlice(u32, ev.array(2));
            win.maximized = false;
            win.fullscreen = false;
            win.activated = false;
            for (states) |st| {
                if (st == 1) win.maximized = true;
                if (st == 2) win.fullscreen = true;
                if (st == 4) win.activated = true;
            }
            return .none;
        }
        if (ev.id == win.toplevel and ev.is("xdg_toplevel", "close")) return .close;
        if (ev.id == win.xdg_surface and ev.is("xdg_surface", "configure")) {
            c.send(win.xdg_surface, "xdg_surface", "ack_configure", &.{.{ .uint = ev.uint(0) }});
            win.configured = true;
            return .configure;
        }
        if (ev.id == win.frame_cb and ev.is("wl_callback", "done")) {
            win.frame_cb = 0;
            return .frame;
        }
        if (ev.id == win.surface and ev.is("wl_surface", "preferred_buffer_scale")) {
            const s: u32 = @intCast(@max(ev.int(0), 1));
            if (s != win.scale) {
                win.scale = s;
                return .scale;
            }
            return .none;
        }
        return .none;
    }
};
