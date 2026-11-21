// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `copy` / `paste`: wl-copy and wl-paste's command lines, over
//! wl_data_device (or zwp_primary_selection with --primary). copy forks
//! into the background unless --foreground, and serves the selection until
//! it is replaced (cancelled); --clear unsets it. paste prints the
//! selection (a newline added unless --no-newline) or exits 1 without one.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl.zig");
const app_mod = @import("app.zig");

const mimes = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING" };

const Opts = struct {
    primary: bool = false,
    foreground: bool = false,
    clear: bool = false,
    no_newline: bool = false,
    text: []const u8 = "",
};

fn parse(gpa: std.mem.Allocator, args: []const []const u8) Opts {
    var o: Opts = .{};
    var words: std.ArrayList(u8) = .empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--primary") or std.mem.eql(u8, a, "-p")) o.primary = true
        else if (std.mem.eql(u8, a, "--foreground")) o.foreground = true
        else if (std.mem.eql(u8, a, "--clear") or std.mem.eql(u8, a, "-c")) o.clear = true
        else if (std.mem.eql(u8, a, "--no-newline") or std.mem.eql(u8, a, "-n")) o.no_newline = true
        else {
            if (words.items.len > 0) words.append(gpa, ' ') catch {};
            words.appendSlice(gpa, a) catch {};
        }
    }
    o.text = words.items;
    return o;
}

const Ctx = struct {
    c: *wl.Client = undefined,
    opts: Opts,
    source: u32 = 0,
    cancelled: bool = false,
    /// offers by id: their mime types (the last one per device is the selection)
    offer_mimes: std.AutoHashMapUnmanaged(u32, std.ArrayList([]const u8)) = .empty,
    selection: ?u32 = null,
    got_selection: bool = false,
    focused: bool = false,
    /// paste: the 1×1 window that takes keyboard focus (selections go to
    /// the focused client only; wl-paste does the same)
    app: ?*app_mod.App = null,
    win: app_mod.Window = undefined,
    gpa: std.mem.Allocator,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ctx.app) |app| {
            if (ev.is("wl_keyboard", "enter")) ctx.focused = true;
            if (ev.is("wl_keyboard", "enter") or ev.is("wl_keyboard", "leave") or ev.iface == (comptime wl.iface("wl_pointer"))) return;
            if (app.handle(ev)) return;
            if (ev.is("wl_buffer", "release")) return;
            _ = ctx.win.handle(app, ev);
        }
        if (ev.is("wl_data_source", "send") or ev.is("zwp_primary_selection_source_v1", "send")) {
            wl.writeFd(ev.fd, ctx.opts.text);
            _ = linux.close(ev.fd);
        } else if (ev.is("wl_data_source", "cancelled") or ev.is("zwp_primary_selection_source_v1", "cancelled")) {
            ctx.cancelled = true;
        } else if (ev.is("wl_data_device", "data_offer") or ev.is("zwp_primary_selection_device_v1", "data_offer")) {
            ctx.offer_mimes.put(ctx.gpa, ev.uint(0), .empty) catch {};
        } else if (ev.is("wl_data_offer", "offer") or ev.is("zwp_primary_selection_offer_v1", "offer")) {
            if (ctx.offer_mimes.getPtr(ev.id)) |l| l.append(ctx.gpa, ctx.gpa.dupe(u8, ev.str(0)) catch return) catch {};
        } else if (ev.is("wl_data_device", "selection") or ev.is("zwp_primary_selection_device_v1", "selection")) {
            const id = ev.uint(0);
            ctx.selection = if (id == 0) null else id;
            ctx.got_selection = true;
        }
    }
};

/// The device for the seat: wl_data_device or the primary selection's.
fn device(c: *wl.Client, primary: bool) u32 {
    return deviceOn(c, c.mustBind("wl_seat", 1), primary);
}

fn deviceOn(c: *wl.Client, seat: u32, primary: bool) u32 {
    if (primary) {
        const mgr = c.mustBind("zwp_primary_selection_device_manager_v1", 1);
        const dev = c.new("zwp_primary_selection_device_v1");
        c.send(mgr, "zwp_primary_selection_device_manager_v1", "get_device", &.{ .{ .new_id = dev }, .{ .object = seat } });
        return dev;
    }
    const mgr = c.mustBind("wl_data_device_manager", 3);
    const dev = c.new("wl_data_device");
    c.send(mgr, "wl_data_device_manager", "get_data_device", &.{ .{ .new_id = dev }, .{ .object = seat } });
    return dev;
}

pub fn runCopy(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    const opts = parse(gpa, args);
    if (!opts.foreground and !opts.clear) {
        // wl-copy's default: the parent returns at once, a child serves
        const pid = linux.fork();
        if (pid != 0) return;
        // detach from the caller's pipes (a test waiting for EOF must not wait on us)
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(devnull) == .SUCCESS) {
            _ = linux.dup2(@intCast(devnull), 0);
            _ = linux.dup2(@intCast(devnull), 1);
            _ = linux.dup2(@intCast(devnull), 2);
        }
    }
    var ctx: Ctx = .{ .opts = opts, .gpa = gpa };
    ctx.c = try wl.Client.connect(gpa, env);
    const c = ctx.c;
    c.start(&ctx);
    const dev = device(c, opts.primary);
    var src: u32 = 0;
    if (!opts.clear) {
        if (opts.primary) {
            const mgr = c.mustBind("zwp_primary_selection_device_manager_v1", 1);
            src = c.new("zwp_primary_selection_source_v1");
            c.send(mgr, "zwp_primary_selection_device_manager_v1", "create_source", &.{.{ .new_id = src }});
            for (mimes) |m| c.send(src, "zwp_primary_selection_source_v1", "offer", &.{.{ .string = m }});
        } else {
            const mgr = c.mustBind("wl_data_device_manager", 3);
            src = c.new("wl_data_source");
            c.send(mgr, "wl_data_device_manager", "create_data_source", &.{.{ .new_id = src }});
            for (mimes) |m| c.send(src, "wl_data_source", "offer", &.{.{ .string = m }});
        }
    }
    if (opts.primary) {
        c.send(dev, "zwp_primary_selection_device_v1", "set_selection", &.{ .{ .object = src }, .{ .uint = 0 } });
    } else {
        c.send(dev, "wl_data_device", "set_selection", &.{ .{ .object = src }, .{ .uint = 0 } });
    }
    c.roundtrip(&ctx);
    if (opts.clear) return;
    while (!ctx.cancelled) {
        if (!c.dispatch(&ctx, -1)) break;
    }
}

pub fn runPaste(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    const opts = parse(gpa, args);
    var ctx: Ctx = .{ .opts = opts, .gpa = gpa };
    var app = app_mod.App.init(gpa, env, &ctx);
    ctx.app = &app;
    ctx.c = app.c;
    const c = ctx.c;
    _ = deviceOn(c, app.seat, opts.primary);
    c.roundtrip(&ctx);
    var pool = wl.Pool.create(c, app.shm, 1, 1, 1, wl.ARGB8888, 0);
    pool.buffers[0].pixels[0] = 0;
    ctx.win = app_mod.Window.create(&app, "wland-fixture paste", "wland-fixture", 1, 1);
    const deadline = wl.nowMs() + 5000;
    var attached = false;
    while (!(ctx.focused and ctx.got_selection)) {
        if (wl.nowMs() > deadline) break;
        if (ctx.win.configured and !attached) {
            c.send(ctx.win.surface, "wl_surface", "attach", &.{ .{ .object = pool.buffers[0].id }, .{ .int = 0 }, .{ .int = 0 } });
            c.send(ctx.win.surface, "wl_surface", "commit", &.{});
            attached = true;
        }
        if (!c.dispatch(&ctx, 100)) std.process.exit(1);
    }
    const offer = ctx.selection orelse {
        wl.writeFd(2, "No selection\n");
        std.process.exit(1);
    };
    const offered = ctx.offer_mimes.get(offer).?.items;
    var mime: []const u8 = if (offered.len > 0) offered[0] else wl.fail("the selection offers no type", .{});
    outer: for (mimes) |want| for (offered) |m| if (std.mem.eql(u8, m, want)) {
        mime = m;
        break :outer;
    };
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) wl.fail("pipe2 failed", .{});
    if (opts.primary) {
        c.sendFds(offer, "zwp_primary_selection_offer_v1", "receive", &.{ .{ .string = mime }, .fd }, &.{fds[1]});
    } else {
        c.sendFds(offer, "wl_data_offer", "receive", &.{ .{ .string = mime }, .fd }, &.{fds[1]});
    }
    c.flush();
    _ = linux.close(fds[1]);
    var data: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try data.appendSlice(gpa, buf[0..n]);
    }
    wl.writeFd(1, data.items);
    if (!opts.no_newline and (data.items.len == 0 or data.items[data.items.len - 1] != '\n')) wl.writeFd(1, "\n");
}
