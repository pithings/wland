// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `info`: what the tests read off wayland-info — every global as
//! `interface: 'NAME', version: N, name: N`, the wl_shm formats as
//! `N = 'FOURCC'` and the seat's `capabilities: pointer keyboard`.

const std = @import("std");
const wl = @import("wl.zig");

const Ctx = struct {
    formats: std.ArrayList(u32) = .empty,
    caps: u32 = 0,
    seat_name: []const u8 = "",
    gpa: std.mem.Allocator,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ev.is("wl_shm", "format")) ctx.formats.append(ctx.gpa, ev.uint(0)) catch {};
        if (ev.is("wl_seat", "capabilities")) ctx.caps = ev.uint(0);
        if (ev.is("wl_seat", "name")) ctx.seat_name = ctx.gpa.dupe(u8, ev.str(0)) catch "";
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: Ctx = .{ .gpa = gpa };
    const c = try wl.Client.connect(gpa, env);
    c.start(&ctx);
    _ = c.bind("wl_shm", 1);
    _ = c.bind("wl_seat", 8);
    c.roundtrip(&ctx);
    for (c.globals.items) |g| {
        wl.print("interface: '{s}', version: {d}, name: {d}", .{ g.interface, g.version, g.name });
        if (std.mem.eql(u8, g.interface, "wl_shm")) {
            wl.print("\tformats (fourcc):", .{});
            for (ctx.formats.items) |f| {
                const name: [4]u8 = switch (f) {
                    0 => "AR24".*,
                    1 => "XR24".*,
                    else => @bitCast(f),
                };
                wl.print("\t{x:0>8} = '{s}'", .{ f, &name });
            }
        }
        if (std.mem.eql(u8, g.interface, "wl_seat")) {
            wl.print("\tname: {s}", .{ctx.seat_name});
            wl.print("\tcapabilities:{s}{s}{s}", .{
                if (ctx.caps & 1 != 0) " pointer" else "",
                if (ctx.caps & 2 != 0) " keyboard" else "",
                if (ctx.caps & 4 != 0) " touch" else "",
            });
        }
    }
}
