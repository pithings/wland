// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `browser`: Firefox's seat shape, as its WAYLAND_DEBUG shows it (Firefox
//! 160 and firefox-esr 153, GTK3). GTK binds wl_seat at v5 and makes its
//! primary selection device, wl_data_device, wl_pointer (+ a cursor-shape
//! device) and wl_keyboard on it; then Firefox binds wl_seat AGAIN, at v8
//! on a registry of its own, for a wl_pointer and wl_keyboard of its own.
//! GTK's objects are the ones its input handling listens on, so this mode
//! acts on them alone: a compositor that sends the seat's events only to
//! the objects made last leaves it deaf (what Firefox did on wland before).
//!
//! Every event on either pair is printed (what the test reads), with its
//! serial where it has one:
//!   gtk|own <iface>.<event> [serial=N] [button=B state=S | key=K state=S]
//! An event newer than the object's version (its seat binding's: GTK's is
//! v5, Firefox's v8 — axis_value120 is v8, frame v5) fails the run: the
//! version gate is per object. GTK's data device prints what the
//! selection offers (`gtk wl_data_device.selection mimes=…`), Ctrl+V on
//! GTK's keyboard pastes it (`gtk paste: TEXT`).

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const Plane = @import("pointer.zig").Plane;

const W = 480;
const H = 320;
const gtk_seat_version = 5;
const own_seat_version = 8;
const text_mimes = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" };

const Pair = enum { gtk, own };

const Ctx = struct {
    gpa: std.mem.Allocator,
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    main: Plane = undefined,
    gtk_version: u32 = 0,
    own_seat: u32 = 0,
    own_version: u32 = 0,
    own_pointer: u32 = 0,
    own_keyboard: u32 = 0,
    data_device: u32 = 0,
    primary_device: u32 = 0,
    /// offers announced to GTK's devices: id → their types
    offers: std.AutoHashMapUnmanaged(u32, std.ArrayList([]const u8)) = .empty,
    selection: u32 = 0,
    primary: u32 = 0,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        const c = ctx.app.c;
        if (ev.id == ctx.own_seat) {
            // Firefox's own seat: a pointer and a keyboard of its own
            if (ev.is("wl_seat", "capabilities")) {
                if (ev.uint(0) & 1 != 0 and ctx.own_pointer == 0) {
                    ctx.own_pointer = c.new("wl_pointer");
                    c.send(ctx.own_seat, "wl_seat", "get_pointer", &.{.{ .new_id = ctx.own_pointer }});
                }
                if (ev.uint(0) & 2 != 0 and ctx.own_keyboard == 0) {
                    ctx.own_keyboard = c.new("wl_keyboard");
                    c.send(ctx.own_seat, "wl_seat", "get_keyboard", &.{.{ .new_id = ctx.own_keyboard }});
                }
            }
            return;
        }
        if (ctx.pairOf(ev.id)) |p| ctx.logSeat(p, ev);
        if (ev.id == ctx.app.keyboard and ev.is("wl_keyboard", "key")) {
            if (ctx.ready and ev.uint(3) == 1 and ev.uint(2) == 47 and ctx.app.ctrl) ctx.paste(); // Ctrl+V
            return;
        }
        if (ctx.app.handle(ev)) return; // keymaps (both checked), modifiers, frames
        if (ev.iface == (comptime wl.iface("wl_pointer")) or ev.iface == (comptime wl.iface("wl_keyboard"))) return;
        if (ev.is("wl_buffer", "release")) {
            _ = ctx.main.pool.released(ev.id);
            return;
        }
        if (ev.is("wl_data_device", "data_offer") or ev.is("zwp_primary_selection_device_v1", "data_offer")) {
            ctx.offers.put(ctx.gpa, ev.uint(0), .empty) catch {};
            return;
        }
        if (ev.is("wl_data_offer", "offer") or ev.is("zwp_primary_selection_offer_v1", "offer")) {
            if (ctx.offers.getPtr(ev.id)) |l| l.append(ctx.gpa, ctx.gpa.dupe(u8, ev.str(0)) catch return) catch {};
            return;
        }
        if (ev.iface == (comptime wl.iface("wl_data_offer")) or ev.iface == (comptime wl.iface("zwp_primary_selection_offer_v1"))) return;
        if (ev.is("wl_data_device", "selection")) {
            ctx.selection = ctx.replaceOffer(ctx.selection, ev.uint(0), false);
            ctx.printSelection("wl_data_device", ctx.selection);
            return;
        }
        if (ev.is("zwp_primary_selection_device_v1", "selection")) {
            ctx.primary = ctx.replaceOffer(ctx.primary, ev.uint(0), true);
            ctx.printSelection("zwp_primary_selection_device_v1", ctx.primary);
            return;
        }
        if (ev.iface == (comptime wl.iface("wl_data_device")) or ev.iface == (comptime wl.iface("zwp_primary_selection_device_v1"))) return;
        if (!ctx.ready) return;
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure, .scale => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    fn pairOf(ctx: *Ctx, id: u32) ?Pair {
        if (id == 0) return null;
        if (id == ctx.app.pointer or id == ctx.app.keyboard) return .gtk;
        if (id == ctx.own_pointer or id == ctx.own_keyboard) return .own;
        return null;
    }

    /// The version an event of wl_pointer / wl_keyboard came in.
    fn since(ev: wl.Event) u32 {
        const name = ev.iface.events[ev.opcode].name;
        const v: u32 = if (ev.iface == (comptime wl.iface("wl_pointer")))
            if (std.mem.eql(u8, name, "axis_value120")) 8 else if (std.mem.eql(u8, name, "axis_relative_direction")) 9 else if (std.mem.eql(u8, name, "frame") or std.mem.startsWith(u8, name, "axis_")) 5 else 1
        else if (std.mem.eql(u8, name, "repeat_info")) 4 else 1;
        return v;
    }

    fn logSeat(ctx: *Ctx, p: Pair, ev: wl.Event) void {
        const name = ev.iface.events[ev.opcode].name;
        const version = if (p == .gtk) ctx.gtk_version else ctx.own_version;
        if (since(ev) > version) wl.fail("{t} {s}#{d}.{s}: an event of v{d}, sent to a v{d} object", .{ p, ev.iface.name, ev.id, name, since(ev), version });
        var buf: [160]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{t} {s}.{s}", .{ p, ev.iface.name, name }) catch {};
        const serial = std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "leave") or
            std.mem.eql(u8, name, "button") or std.mem.eql(u8, name, "key") or std.mem.eql(u8, name, "modifiers");
        if (serial) w.print(" serial={d}", .{ev.uint(0)}) catch {};
        if (std.mem.eql(u8, name, "button")) w.print(" button={d} state={d}", .{ ev.uint(2), ev.uint(3) }) catch {};
        if (std.mem.eql(u8, name, "key")) w.print(" key={d} state={d}", .{ ev.uint(2), ev.uint(3) }) catch {};
        wl.print("{s}", .{w.buffered()});
    }

    /// The device's offer `old` is replaced by `new`: destroy it (unless
    /// it is the same).
    fn replaceOffer(ctx: *Ctx, old: u32, new: u32, primary: bool) u32 {
        if (old != 0 and old != new) {
            if (primary) ctx.app.c.destroy(old, "zwp_primary_selection_offer_v1") else ctx.app.c.destroy(old, "wl_data_offer");
            _ = ctx.offers.remove(old);
        }
        return new;
    }

    fn printSelection(ctx: *Ctx, comptime iface_name: []const u8, offer: u32) void {
        const mimes = if (ctx.offers.get(offer)) |l| l.items else &.{};
        const joined = std.mem.join(ctx.gpa, ",", mimes) catch "";
        wl.print("gtk " ++ iface_name ++ ".selection mimes={s}", .{if (offer == 0) "none" else joined});
    }

    /// The clipboard's text through GTK's data device: receive into a
    /// pipe, read it to EOF (2 s at most).
    fn paste(ctx: *Ctx) void {
        const offered = (ctx.offers.get(ctx.selection) orelse return wl.print("gtk paste: (no selection)", .{})).items;
        var mime: ?[]const u8 = null;
        outer: for (text_mimes) |want| for (offered) |m| if (std.mem.eql(u8, m, want)) {
            mime = want;
            break :outer;
        };
        const m = mime orelse return wl.print("gtk paste: (no text)", .{});
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return;
        defer _ = linux.close(fds[0]);
        const c = ctx.app.c;
        c.sendFds(ctx.selection, "wl_data_offer", "receive", &.{ .{ .string = m }, .fd }, &.{fds[1]});
        c.flush();
        _ = linux.close(fds[1]);
        var text: std.ArrayList(u8) = .empty;
        const deadline = wl.nowMs() + 2000;
        var buf: [4096]u8 = undefined;
        while (wl.nowMs() < deadline) {
            var pfd = [1]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
            if (linux.poll(&pfd, 1, 100) == 0) continue;
            const n = linux.read(fds[0], &buf, buf.len);
            if (linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            text.appendSlice(ctx.gpa, buf[0..n]) catch {};
        }
        wl.print("gtk paste: {s}", .{text.items});
    }

    fn redraw(ctx: *Ctx) void {
        ctx.main.scale = ctx.win.scale;
        const w = if (ctx.win.want_w > 0) ctx.win.want_w else W;
        const h = if (ctx.win.want_h > 0) ctx.win.want_h else H;
        const b = ctx.main.buffer(&ctx.app, w, h) orelse return;
        var cv = Plane.canvas(b);
        const s: i32 = @intCast(ctx.win.scale);
        cv.gradient(0, 0, @intCast(b.width), @intCast(b.height), 0xff20304a, 0xff4a2030);
        cv.text(20 * s, 20 * s, 3 * s, 0xffffffff, "TWO SEATS");
        ctx.main.commit(&ctx.app, b);
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: Ctx = .{ .gpa = gpa };
    // GTK's seat (its devices before its pointer and keyboard, as GTK does)
    ctx.app = app_mod.App.initSeat(gpa, env, &ctx, gtk_seat_version);
    const c = ctx.app.c;
    if (ctx.app.seat == 0) wl.fail("wl_seat is not advertised", .{});
    ctx.gtk_version = c.bindVersion("wl_seat", gtk_seat_version);
    if (c.global("zwp_primary_selection_device_manager_v1") != null) {
        const mgr = c.mustBind("zwp_primary_selection_device_manager_v1", 1);
        ctx.primary_device = c.new("zwp_primary_selection_device_v1");
        c.send(mgr, "zwp_primary_selection_device_manager_v1", "get_device", &.{ .{ .new_id = ctx.primary_device }, .{ .object = ctx.app.seat } });
    }
    const ddm = c.mustBind("wl_data_device_manager", 3);
    ctx.data_device = c.new("wl_data_device");
    c.send(ddm, "wl_data_device_manager", "get_data_device", &.{ .{ .new_id = ctx.data_device }, .{ .object = ctx.app.seat } });
    c.roundtrip(&ctx); // capabilities: GTK's wl_pointer and wl_keyboard

    // Firefox's own: a registry of its own, wl_seat bound again
    const registry = c.new("wl_registry");
    c.send(1, "wl_display", "get_registry", &.{.{ .new_id = registry }});
    c.roundtrip(&ctx);
    const g = c.global("wl_seat").?;
    ctx.own_version = @min(own_seat_version, g.version);
    ctx.own_seat = c.new("wl_seat");
    c.send(registry, "wl_registry", "bind", &.{ .{ .uint = g.name }, .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = ctx.own_version, .id = ctx.own_seat } } });
    c.roundtrip(&ctx); // its capabilities: Firefox's wl_pointer and wl_keyboard
    c.roundtrip(&ctx);
    wl.print("seats gtk=v{d} own=v{d}", .{ ctx.gtk_version, ctx.own_version });

    ctx.win = app_mod.Window.create(&ctx.app, "browser", "wland-fixture.browser", W, H);
    ctx.main = .{ .surface = ctx.win.surface };
    ctx.ready = true;
    while (!ctx.done) if (!c.dispatch(&ctx, -1)) break;
}
