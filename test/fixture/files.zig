// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `files`: nautilus's shape, as the tests see it (a GTK4 window).
//!
//! The surface is the frame plus a shadow margin (24 px; none when
//! maximized); the window geometry is the frame; the input region is the
//! frame plus a 10 px resize margin, so the outer shadow falls through.
//! Positions, from the surface's top-left (floating), match nautilus's
//! default layout so tests click the same spots on either:
//!   (184, 48)      the hamburger button: an xdg_popup menu with a grab
//!   right button   on the content: a context menu at the pointer (GTK3's
//!                  l3afpad has the same: anchor rect = the pointer)
//! Menus are GTK's shape too: a shadow of their own around the window
//! geometry (PM px), input region = the geometry; positioners count from
//! the parent's geometry. Each prints `POPUP at X,Y` (its configure: the
//! menu's geometry from the window's), and a click on an item prints
//! `MENU <item>` and closes it. Items are ROW px tall from 8 px down.
//!   (w-121, 47)    minimize (set_minimized; nautilus with the button layout
//!                  appmenu:minimize,maximize,close — box-relative (w-97, 23))
//!   (w-86, 48)     maximize (maximized: restore at (w-60, 22))
//!   (w-46, 47)     close
//!   (307, 145)     the first icon, a folder: a double click opens it (the
//!                  title becomes "folder")
//!   (427, 145)     the second icon, file.txt: drag it onto the folder and
//!                  it moves (wl_data_device dnd; prints `DROPPED <uri> ON folder`)
//!   elsewhere on the headerbar a press moves the window; in the resize
//!   margin it resizes. Pointer motion commits without attaching (GTK's
//!   frame clock does), which is what the double-release regression needs.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const Plane = @import("pointer.zig").Plane;

const MARGIN = 24;
const RESIZE = 10;
const HEADER = 48;
const BTN_LEFT = 0x110;
const ICON = 64;
const BTN_RIGHT = 0x111;
const PM = 6; // a menu's shadow margin
const MENU_W = 200;
const MENU_H = 160;
const ROW = 36;
const Menu = enum { hamburger, context };
const menu_items = [2][4][]const u8{
    .{ "New Window", "Show Hidden", "Preferences", "About" },
    .{ "New Folder", "Paste", "Select All", "Properties" },
};

const Hit = enum { none, shadow, resize, header, hamburger, minimize, maximize, close, folder, file, content };

const Ctx = struct {
    gpa: std.mem.Allocator,
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    main: Plane = undefined,
    dir: []const u8 = "",
    title: []const u8 = "Home",
    w: u32 = 1000,
    h: u32 = 640,
    floating_w: u32 = 1000,
    floating_h: u32 = 640,
    margin: u32 = MARGIN,
    dirty: bool = false,
    // pointer
    over: u32 = 0,
    enter_serial: u32 = 0,
    shape: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    pressed: Hit = .none,
    press_serial: u32 = 0,
    press_x: f64 = 0,
    press_y: f64 = 0,
    last_click_ms: u64 = 0,
    last_click: Hit = .none,
    selected: Hit = .none,
    navigated: bool = false,
    file_moved: bool = false,
    // popup menu
    popup_surface: u32 = 0,
    popup_xdg: u32 = 0,
    popup: u32 = 0,
    popup_plane: Plane = undefined,
    menu: Menu = .hamburger,
    // drag and drop
    ddm: u32 = 0,
    data_device: u32 = 0,
    drag_source: u32 = 0,
    dnd_offer: u32 = 0,
    dnd_serial: u32 = 0,
    dnd_x: f64 = 0,
    dnd_y: f64 = 0,
    drop_fd: i32 = -1,
    drop_data: std.ArrayList(u8) = .empty,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        const c = ctx.app.c;
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            if (ctx.main.pool.released(ev.id) and ctx.dirty) ctx.redraw();
            _ = ctx.popup_plane.pool.released(ev.id);
            return;
        }
        if (!ctx.ready) return;
        if (ev.is("wl_keyboard", "key") or ev.is("wl_keyboard", "enter") or ev.is("wl_keyboard", "leave")) return;
        if (ev.is("wl_pointer", "enter")) {
            ctx.over = ev.uint(1);
            ctx.enter_serial = ev.uint(0);
            ctx.shape = 0;
            ctx.pressed = .none; // a press of ours would have kept the pointer
            ctx.motion(ev.num(2), ev.num(3));
        } else if (ev.is("wl_pointer", "leave")) {
            ctx.over = 0;
        } else if (ev.is("wl_pointer", "motion")) {
            ctx.motion(ev.num(1), ev.num(2));
        } else if (ev.is("wl_pointer", "button")) {
            if (ev.uint(2) == BTN_RIGHT and ev.uint(3) == 1) return ctx.contextMenu(ev.uint(0));
            if (ev.uint(2) != BTN_LEFT) return;
            if (ev.uint(3) == 1) ctx.press(ev.uint(0)) else ctx.pressed = .none;
        } else if (ev.is("wl_pointer", "axis")) {
            // nothing scrolls
        } else if (ev.id == ctx.popup and ev.is("xdg_popup", "configure")) {
            wl.print("POPUP at {d},{d}", .{ ev.int(0), ev.int(1) }); // size as asked
        } else if (ev.id == ctx.popup and ev.is("xdg_popup", "popup_done")) {
            ctx.closePopup();
        } else if (ev.id == ctx.popup_xdg and ev.is("xdg_surface", "configure")) {
            c.send(ctx.popup_xdg, "xdg_surface", "ack_configure", &.{.{ .uint = ev.uint(0) }});
            ctx.drawPopup();
        } else if (ev.is("wl_data_source", "send")) {
            var buf: [512]u8 = undefined;
            const uri = std.fmt.bufPrint(&buf, "file://{s}/file.txt\r\n", .{ctx.dir}) catch "";
            wl.writeFd(ev.fd, uri);
            _ = linux.close(ev.fd);
        } else if (ev.is("wl_data_source", "dnd_finished") or ev.is("wl_data_source", "cancelled")) {
            if (ev.id == ctx.drag_source) {
                c.destroy(ctx.drag_source, "wl_data_source");
                ctx.drag_source = 0;
            }
        } else if (ev.is("wl_data_source", "target") or ev.is("wl_data_source", "action") or ev.is("wl_data_source", "dnd_drop_performed") or
            ev.is("wl_data_offer", "offer") or ev.is("wl_data_offer", "source_actions") or ev.is("wl_data_offer", "action") or
            ev.is("wl_data_device", "data_offer") or ev.is("wl_data_device", "selection"))
        {
            // offers announce themselves before enter/selection: nothing to keep
        } else if (ev.is("wl_data_device", "enter")) {
            ctx.dnd_serial = ev.uint(0);
            ctx.dnd_x = ev.num(2);
            ctx.dnd_y = ev.num(3);
            ctx.dnd_offer = ev.uint(4);
            if (ctx.dnd_offer != 0) {
                c.send(ctx.dnd_offer, "wl_data_offer", "accept", &.{ .{ .uint = ctx.dnd_serial }, .{ .string = "text/uri-list" } });
                c.send(ctx.dnd_offer, "wl_data_offer", "set_actions", &.{ .{ .uint = 3 }, .{ .uint = 2 } });
            }
        } else if (ev.is("wl_data_device", "motion")) {
            ctx.dnd_x = ev.num(1);
            ctx.dnd_y = ev.num(2);
        } else if (ev.is("wl_data_device", "leave")) {
            if (ctx.dnd_offer != 0 and ctx.drop_fd < 0) c.destroy(ctx.dnd_offer, "wl_data_offer");
            ctx.dnd_offer = 0;
        } else if (ev.is("wl_data_device", "drop")) {
            ctx.drop();
        } else switch (ctx.win.handle(&ctx.app, ev)) {
            .configure => ctx.configure(),
            .scale => ctx.redraw(),
            .frame => if (ctx.dirty) ctx.redraw(),
            .close => ctx.done = true,
            .none => {},
        }
    }

    // --- geometry -------------------------------------------------------------

    /// What is at surface-local (x, y).
    fn hit(ctx: *Ctx, x: f64, y: f64) Hit {
        const m: f64 = @floatFromInt(ctx.margin);
        const w: f64 = @floatFromInt(ctx.w);
        const h: f64 = @floatFromInt(ctx.h);
        const fx = x - m;
        const fy = y - m;
        if (fx < 0 or fy < 0 or fx >= w or fy >= h) {
            const r: f64 = RESIZE;
            return if (fx >= -r and fy >= -r and fx < w + r and fy < h + r) .resize else .shadow;
        }
        if (fy < HEADER) {
            if (@abs(fx - 160) <= 16 and @abs(fy - 24) <= 16) return .hamburger;
            if (@abs(fx - (w - 61)) <= 18 and @abs(fy - 23) <= 16) return .maximize;
            if (@abs(fx - (w - 97)) <= 16 and @abs(fy - 23) <= 16) return .minimize;
            if (@abs(fx - (w - 22)) <= 14 and @abs(fy - 23) <= 14) return .close;
            return .header;
        }
        if (!ctx.navigated and @abs(fx - 283) <= ICON / 2 and @abs(fy - 121) <= ICON / 2) return .folder;
        if (!ctx.navigated and !ctx.file_moved and @abs(fx - 403) <= ICON / 2 and @abs(fy - 121) <= ICON / 2) return .file;
        return .content;
    }

    fn edges(ctx: *Ctx, x: f64, y: f64) u32 {
        const m: f64 = @floatFromInt(ctx.margin);
        const w: f64 = @floatFromInt(ctx.w);
        const h: f64 = @floatFromInt(ctx.h);
        const fx = x - m;
        const fy = y - m;
        var e: u32 = 0;
        if (fy < 16) e |= 1;
        if (fy > h - 16) e |= 2;
        if (fx < 16) e |= 4;
        if (fx > w - 16) e |= 8;
        return e;
    }

    fn motion(ctx: *Ctx, x: f64, y: f64) void {
        ctx.x = x;
        ctx.y = y;
        if (ctx.over != ctx.win.surface) return;
        const h = ctx.hit(x, y);
        const shape: u32 = if (h == .resize) switch (ctx.edges(x, y)) {
            1 => 19,
            2 => 22,
            4 => 25,
            8 => 18,
            5 => 21,
            9 => 20,
            6 => 24,
            10 => 23,
            else => 1,
        } else if (h == .folder or h == .file or h == .hamburger or h == .minimize or h == .maximize or h == .close) 4 else 1;
        if (shape != ctx.shape) {
            ctx.shape = shape;
            ctx.app.setShape(ctx.enter_serial, shape);
        }
        // a drag of file.txt starts past a small threshold
        if (ctx.pressed == .file and ctx.drag_source == 0 and @abs(x - ctx.press_x) + @abs(y - ctx.press_y) > 8) ctx.startDrag();
        // GTK's frame clock: a frame request committed without a buffer
        if (ctx.win.frame_cb == 0) {
            ctx.win.requestFrame(&ctx.app);
            ctx.app.c.send(ctx.win.surface, "wl_surface", "commit", &.{});
        }
    }

    fn press(ctx: *Ctx, serial: u32) void {
        const c = ctx.app.c;
        if (ctx.popup != 0 and ctx.over == ctx.popup_surface) return ctx.menuClick();
        if (ctx.over != ctx.win.surface) return;
        const h = ctx.hit(ctx.x, ctx.y);
        ctx.pressed = h;
        ctx.press_serial = serial;
        ctx.press_x = ctx.x;
        ctx.press_y = ctx.y;
        const now = wl.nowMs();
        const double = h == ctx.last_click and now - ctx.last_click_ms < 500;
        ctx.last_click = h;
        ctx.last_click_ms = now;
        switch (h) {
            .resize => c.send(ctx.win.toplevel, "xdg_toplevel", "resize", &.{ .{ .object = ctx.app.seat }, .{ .uint = serial }, .{ .uint = ctx.edges(ctx.x, ctx.y) } }),
            .header => c.send(ctx.win.toplevel, "xdg_toplevel", "move", &.{ .{ .object = ctx.app.seat }, .{ .uint = serial } }),
            .hamburger => if (ctx.popup != 0) ctx.closePopup() else ctx.openPopup(serial, .hamburger, .{ 144, 8, 32, 32 }, 2),
            .minimize => c.send(ctx.win.toplevel, "xdg_toplevel", "set_minimized", &.{}),
            .maximize => if (ctx.win.maximized) c.send(ctx.win.toplevel, "xdg_toplevel", "unset_maximized", &.{}) else c.send(ctx.win.toplevel, "xdg_toplevel", "set_maximized", &.{}),
            .close => ctx.done = true,
            .folder => {
                if (double) {
                    ctx.navigated = true;
                    ctx.title = "folder";
                    ctx.win.setTitle(&ctx.app, ctx.title);
                    wl.print("OPENED folder", .{});
                }
                ctx.select(h);
            },
            .file => ctx.select(h),
            .content => ctx.select(.none),
            .shadow, .none => {},
        }
    }

    fn select(ctx: *Ctx, h: Hit) void {
        ctx.selected = h;
        ctx.redraw();
    }

    // --- popup menu ---------------------------------------------------------------

    /// A menu off `anchor` (x, y, w, h of the window geometry, as GTK
    /// gives it), anchor = gravity = `edge` (2 bottom, 8 bottom_right).
    fn openPopup(ctx: *Ctx, serial: u32, menu: Menu, anchor: [4]i32, edge: u32) void {
        const c = ctx.app.c;
        ctx.menu = menu;
        const pos = c.new("xdg_positioner");
        c.send(ctx.app.wm_base, "xdg_wm_base", "create_positioner", &.{.{ .new_id = pos }});
        c.send(pos, "xdg_positioner", "set_size", &.{ .{ .int = MENU_W }, .{ .int = MENU_H } });
        c.send(pos, "xdg_positioner", "set_anchor_rect", &.{ .{ .int = anchor[0] }, .{ .int = anchor[1] }, .{ .int = anchor[2] }, .{ .int = anchor[3] } });
        c.send(pos, "xdg_positioner", "set_anchor", &.{.{ .uint = edge }});
        c.send(pos, "xdg_positioner", "set_gravity", &.{.{ .uint = edge }});
        c.send(pos, "xdg_positioner", "set_constraint_adjustment", &.{.{ .uint = 3 }});
        ctx.popup_surface = ctx.app.surface();
        ctx.popup_xdg = c.new("xdg_surface");
        c.send(ctx.app.wm_base, "xdg_wm_base", "get_xdg_surface", &.{ .{ .new_id = ctx.popup_xdg }, .{ .object = ctx.popup_surface } });
        ctx.popup = c.new("xdg_popup");
        c.send(ctx.popup_xdg, "xdg_surface", "get_popup", &.{ .{ .new_id = ctx.popup }, .{ .object = ctx.win.xdg_surface }, .{ .object = pos } });
        c.send(ctx.popup, "xdg_popup", "grab", &.{ .{ .object = ctx.app.seat }, .{ .uint = serial } });
        c.destroy(pos, "xdg_positioner");
        c.send(ctx.popup_surface, "wl_surface", "commit", &.{});
        ctx.popup_plane = .{ .surface = ctx.popup_surface, .format = wl.ARGB8888 };
        wl.print("POPUP open", .{});
    }

    /// The right button on the content: a menu at the pointer (geometry px).
    fn contextMenu(ctx: *Ctx, serial: u32) void {
        if (ctx.over != ctx.win.surface or ctx.hit(ctx.x, ctx.y) != .content) return;
        if (ctx.popup != 0) ctx.closePopup();
        const m: f64 = @floatFromInt(ctx.margin);
        ctx.openPopup(serial, .context, .{ @intFromFloat(@floor(ctx.x - m)), @intFromFloat(@floor(ctx.y - m)), 1, 1 }, 8);
    }

    /// A press on the menu: its item (menu-local px, the shadow outside).
    fn menuClick(ctx: *Ctx) void {
        const x = ctx.x - PM;
        const y = ctx.y - PM - 8;
        if (x < 0 or x >= MENU_W or y < 0) return;
        const row: usize = @intFromFloat(@floor(y / ROW));
        if (row >= 4) return;
        wl.print("MENU {s}", .{menu_items[@intFromEnum(ctx.menu)][row]});
        ctx.closePopup();
    }

    fn drawPopup(ctx: *Ctx) void {
        const c = ctx.app.c;
        ctx.popup_plane.scale = ctx.win.scale;
        const b = ctx.popup_plane.buffer(&ctx.app, MENU_W + 2 * PM, MENU_H + 2 * PM) orelse return;
        var cv = Plane.canvas(b);
        const s: i32 = @intCast(ctx.win.scale);
        @memset(cv.px, 0);
        var k: i32 = 0;
        while (k < PM) : (k += 1) cv.rect((PM - k) * s, (PM - k) * s, (MENU_W + 2 * k) * s, (MENU_H + 2 * k) * s, @as(u32, @intCast(10 * k)) << 24);
        cv.rect(PM * s, PM * s, MENU_W * s, MENU_H * s, 0xfff4f4f4);
        cv.rect(PM * s, PM * s, MENU_W * s, s, 0xffc0c0c0);
        for (menu_items[@intFromEnum(ctx.menu)], 0..) |item, i| {
            cv.text((PM + 16) * s, (PM + @as(i32, @intCast(16 + i * ROW))) * s, 2 * s, 0xff303030, item);
        }
        c.send(ctx.popup_xdg, "xdg_surface", "set_window_geometry", &.{ .{ .int = PM }, .{ .int = PM }, .{ .int = MENU_W }, .{ .int = MENU_H } });
        const r = ctx.app.region(&.{.{ PM, PM, MENU_W, MENU_H }});
        c.send(ctx.popup_surface, "wl_surface", "set_input_region", &.{.{ .object = r }});
        c.destroy(r, "wl_region");
        ctx.popup_plane.commit(&ctx.app, b);
    }

    fn closePopup(ctx: *Ctx) void {
        const c = ctx.app.c;
        if (ctx.popup == 0) return;
        c.destroy(ctx.popup, "xdg_popup");
        c.destroy(ctx.popup_xdg, "xdg_surface");
        if (ctx.popup_plane.pool.n != 0) ctx.popup_plane.pool.destroy(c);
        c.destroy(ctx.popup_surface, "wl_surface");
        ctx.popup = 0;
        ctx.popup_xdg = 0;
        ctx.popup_surface = 0;
        wl.print("POPUP closed", .{});
    }

    // --- drag and drop ---------------------------------------------------------------

    fn startDrag(ctx: *Ctx) void {
        const c = ctx.app.c;
        ctx.drag_source = c.new("wl_data_source");
        c.send(ctx.ddm, "wl_data_device_manager", "create_data_source", &.{.{ .new_id = ctx.drag_source }});
        c.send(ctx.drag_source, "wl_data_source", "offer", &.{.{ .string = "text/uri-list" }});
        c.send(ctx.drag_source, "wl_data_source", "set_actions", &.{.{ .uint = 3 }});
        c.send(ctx.data_device, "wl_data_device", "start_drag", &.{ .{ .object = ctx.drag_source }, .{ .object = ctx.win.surface }, .{ .object = 0 }, .{ .uint = ctx.press_serial } });
        ctx.pressed = .none; // the drag owns the pointer now: its release is not ours
        wl.print("DRAG file.txt", .{});
    }

    fn drop(ctx: *Ctx) void {
        const c = ctx.app.c;
        const offer = ctx.dnd_offer;
        if (offer == 0) return;
        if (ctx.hit(ctx.dnd_x, ctx.dnd_y) != .folder) {
            wl.print("DROPPED nothing (not on the folder)", .{});
            c.destroy(offer, "wl_data_offer");
            ctx.dnd_offer = 0;
            return;
        }
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) wl.fail("pipe2 failed", .{});
        c.sendFds(offer, "wl_data_offer", "receive", &.{ .{ .string = "text/uri-list" }, .fd }, &.{fds[1]});
        c.flush();
        _ = linux.close(fds[1]);
        // the source may be this very client: read the pipe from the main
        // loop, between dispatches, never blocking it
        ctx.drop_fd = fds[0];
    }

    /// Read what the drop sent; at EOF finish the offer and move the file.
    fn readDrop(ctx: *Ctx) void {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = linux.read(ctx.drop_fd, &buf, buf.len);
            switch (linux.errno(n)) {
                .SUCCESS => {},
                .AGAIN, .INTR => return,
                else => break,
            }
            if (n == 0) break;
            ctx.drop_data.appendSlice(ctx.gpa, buf[0..n]) catch {};
        }
        _ = linux.close(ctx.drop_fd);
        ctx.drop_fd = -1;
        const c = ctx.app.c;
        c.send(ctx.dnd_offer, "wl_data_offer", "finish", &.{});
        c.destroy(ctx.dnd_offer, "wl_data_offer");
        ctx.dnd_offer = 0;
        const uri = std.mem.trim(u8, ctx.drop_data.items, "\r\n ");
        wl.print("DROPPED {s} ON folder", .{uri});
        ctx.drop_data.clearRetainingCapacity(); // (the next drop reads afresh)
        ctx.file_moved = true;
        ctx.win.setTitle(&ctx.app, "moved file.txt");
        ctx.redraw();
    }

    // --- drawing ----------------------------------------------------------------------

    fn configure(ctx: *Ctx) void {
        const was_max = ctx.margin == 0;
        if (ctx.win.maximized and !was_max) {
            ctx.floating_w = ctx.w;
            ctx.floating_h = ctx.h;
        }
        ctx.margin = if (ctx.win.maximized) 0 else MARGIN;
        if (ctx.win.want_w > 0 and ctx.win.want_h > 0) {
            ctx.w = @max(ctx.win.want_w, 360);
            ctx.h = @max(ctx.win.want_h, 240);
        } else if (was_max and !ctx.win.maximized) {
            ctx.w = ctx.floating_w;
            ctx.h = ctx.floating_h;
        }
        const c = ctx.app.c;
        const m: i32 = @intCast(ctx.margin);
        c.send(ctx.win.xdg_surface, "xdg_surface", "set_window_geometry", &.{ .{ .int = m }, .{ .int = m }, .{ .int = @intCast(ctx.w) }, .{ .int = @intCast(ctx.h) } });
        const r = if (ctx.margin == 0)
            ctx.app.region(&.{.{ 0, 0, @intCast(ctx.w), @intCast(ctx.h) }})
        else
            ctx.app.region(&.{.{ m - RESIZE, m - RESIZE, @as(i32, @intCast(ctx.w)) + 2 * RESIZE, @as(i32, @intCast(ctx.h)) + 2 * RESIZE }});
        c.send(ctx.win.surface, "wl_surface", "set_input_region", &.{.{ .object = r }});
        c.destroy(r, "wl_region");
        ctx.redraw();
        if (ctx.dirty) c.send(ctx.win.surface, "wl_surface", "commit", &.{}); // the ack, without a buffer yet
    }

    fn redraw(ctx: *Ctx) void {
        const sw = ctx.w + 2 * ctx.margin;
        const sh = ctx.h + 2 * ctx.margin;
        ctx.main.scale = ctx.win.scale;
        const b = ctx.main.buffer(&ctx.app, sw, sh) orelse {
            ctx.dirty = true;
            return;
        };
        ctx.dirty = false;
        var cv = Plane.canvas(b);
        const s: i32 = @intCast(ctx.win.scale);
        const m: i32 = @as(i32, @intCast(ctx.margin)) * s;
        const w: i32 = @as(i32, @intCast(ctx.w)) * s;
        const h: i32 = @as(i32, @intCast(ctx.h)) * s;
        // shadow: translucent black, darker near the frame
        @memset(cv.px, 0);
        var k: i32 = 0;
        while (k < m) : (k += s) {
            const alpha: u32 = @intCast(@divTrunc(@as(i32, 60) * k, @max(m, 1)));
            const ring = m - k;
            cv.rect(ring, ring, w + 2 * k, h + 2 * k, alpha << 24);
        }
        // headerbar
        cv.gradient(m, m, w, HEADER * s, 0xffebebeb, 0xffd6d6d6);
        cv.rect(m, m + HEADER * s - s, w, s, 0xffb8b8b8);
        const title_w = draw.textWidth(ctx.title, 2 * s);
        cv.text(m + @divTrunc(w - title_w, 2), m + 17 * s, 2 * s, 0xff2e2e2e, ctx.title);
        button(&cv, m + 160 * s, m + 24 * s, s, 0xff5a5a5a, "=");
        button(&cv, m + w - 97 * s, m + 23 * s, s, 0xff5a5a5a, "_");
        button(&cv, m + w - 61 * s, m + 23 * s, s, 0xff5a5a5a, if (ctx.win.maximized) "o" else "+");
        button(&cv, m + w - 22 * s, m + 23 * s, s, 0xffc04040, "x");
        // content: a soft gradient, the icons
        cv.gradient(m, m + HEADER * s, w, h - HEADER * s, 0xfffafafa, 0xffe4e8ee);
        if (ctx.navigated) {
            cv.text(m + 40 * s, m + 100 * s, 2 * s, 0xff808080, "folder is empty");
        } else {
            icon(&cv, m + 283 * s, m + 121 * s, s, 0xff3584e4, 0xff1c5fb0, "folder", ctx.selected == .folder);
            if (!ctx.file_moved) icon(&cv, m + 403 * s, m + 121 * s, s, 0xfff6f5f4, 0xff9a9996, "file.txt", ctx.selected == .file);
        }
        ctx.main.attach(&ctx.app, b);
        ctx.win.requestFrame(&ctx.app);
        ctx.app.c.send(ctx.win.surface, "wl_surface", "commit", &.{});
    }
};

fn button(cv: *draw.Canvas, cx: i32, cy: i32, s: i32, color: u32, label: []const u8) void {
    cv.rect(cx - 14 * s, cy - 14 * s, 28 * s, 28 * s, 0xffe0e0e0);
    cv.text(cx - 3 * s, cy - 5 * s, 2 * s, color, label);
}

fn icon(cv: *draw.Canvas, cx: i32, cy: i32, s: i32, fill: u32, edge: u32, label: []const u8, selected: bool) void {
    const half = ICON / 2 * s;
    if (selected) cv.rect(cx - half - 4 * s, cy - half - 4 * s, (ICON + 8) * s, (ICON + 30) * s, 0xffc8daf4);
    cv.gradient(cx - half + 6 * s, cy - half + 10 * s, (ICON - 12) * s, (ICON - 16) * s, fill, edge);
    cv.rect(cx - half + 6 * s, cy - half + 6 * s, 20 * s, 6 * s, edge);
    const tw = draw.textWidth(label, 2 * s);
    cv.text(cx - @divTrunc(tw, 2), cy + half + 6 * s, 2 * s, 0xff2e2e2e, label);
}

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    var ctx: Ctx = .{ .gpa = gpa, .dir = if (args.len > 0) args[0] else env.get("HOME") orelse "/" };
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    ctx.ddm = c.bind("wl_data_device_manager", 3);
    c.roundtrip(&ctx);
    if (ctx.ddm != 0 and ctx.app.seat != 0) {
        ctx.data_device = c.new("wl_data_device");
        c.send(ctx.ddm, "wl_data_device_manager", "get_data_device", &.{ .{ .new_id = ctx.data_device }, .{ .object = ctx.app.seat } });
    }
    ctx.title = std.fs.path.basename(ctx.dir);
    if (ctx.title.len == 0) ctx.title = "Home";
    ctx.win = app_mod.Window.create(&ctx.app, ctx.title, "org.gnome.Nautilus", ctx.w, ctx.h);
    ctx.main = .{ .surface = ctx.win.surface, .format = wl.ARGB8888 };
    ctx.popup_plane = .{ .surface = 0 };
    ctx.ready = true;
    while (!ctx.done) {
        if (!c.dispatch(&ctx, if (ctx.drop_fd >= 0) 20 else -1)) break;
        if (ctx.drop_fd >= 0) ctx.readDrop();
    }
}
