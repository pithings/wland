// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `dmabuf`: weston-simple-dmabuf-egl's shape — a GPU client that hands the
//! compositor linux-dmabuf buffers. It reads the default feedback (format
//! table fd, main device, tranche), picks XRGB8888 as a virgl client would
//! (the implicit modifier when offered, else LINEAR), makes two buffers
//! with create_immed, each over a memfd of its own standing in for a dmabuf
//! (only a relay whose device takes memfds can name them: `wlandr --dmabuf
//! virtgpu:@fake`, test-only), and redraws on every frame callback into a
//! released buffer, as the EGL WSI does. One stdout line once it has
//! chosen: `dmabuf: format XR24 modifier 0x… (N table entries) on device
//! 0x…`; `frame N` every 30 frames. Without zwp_linux_dmabuf_v1 (a relay
//! with no dmabuf backend, or an engine with no GPU source in front of a
//! virtgpu one) it exits 1 with `zwp_linux_dmabuf_v1 is not advertised` on
//! stderr, as weston-simple-dmabuf-egl gives up without the global (a
//! general EGL client would fall back to wl_shm instead).

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl.zig");
const app_mod = @import("app.zig");

const W = 256;
const H = 192;
const fourcc_xrgb8888: u32 = 0x34325258;
const mod_invalid: u64 = 0x00ff_ffff_ffff_ffff;

const Buf = struct { id: u32, px: []u32, busy: bool = false };

const Ctx = struct {
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    table: []const u8 = &.{},
    device: u64 = 0,
    tranche: []const u8 = &.{},
    feedback_done: bool = false,
    bufs: [2]Buf = undefined,
    have_bufs: bool = false,
    frame: u32 = 0,
    /// a frame is due but no buffer was free: draw at the next release
    /// (as an EGL WSI blocks in eglSwapBuffers for one)
    starved: bool = false,
    done: bool = false,
    gpa: std.mem.Allocator,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ctx.app.handle(ev)) return;
        if (ev.is("zwp_linux_dmabuf_feedback_v1", "format_table")) {
            const size = ev.uint(1);
            const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, ev.fd, 0);
            if (linux.errno(addr) != .SUCCESS) wl.fail("cannot map the format table ({d} bytes)", .{size});
            ctx.table = ctx.gpa.dupe(u8, @as([*]const u8, @ptrFromInt(addr))[0..size]) catch wl.fail("oom", .{});
            _ = linux.munmap(@ptrFromInt(addr), size);
            _ = linux.close(ev.fd);
            return;
        }
        if (ev.is("zwp_linux_dmabuf_feedback_v1", "main_device")) {
            const a = ev.array(0);
            if (a.len == 8) ctx.device = std.mem.readInt(u64, a[0..8], .little);
            return;
        }
        if (ev.is("zwp_linux_dmabuf_feedback_v1", "tranche_formats")) {
            ctx.tranche = ctx.gpa.dupe(u8, ev.array(0)) catch wl.fail("oom", .{});
            return;
        }
        if (ev.is("zwp_linux_dmabuf_feedback_v1", "done")) {
            ctx.feedback_done = true;
            return;
        }
        if (ev.is("zwp_linux_buffer_params_v1", "failed")) wl.fail("the compositor refused a dmabuf buffer", .{});
        if (ev.is("wl_buffer", "release")) {
            for (&ctx.bufs) |*b| if (b.id == ev.id) {
                if (!b.busy) wl.fail("wl_buffer {d} released while not busy (a duplicate release)", .{ev.id});
                b.busy = false;
            };
            if (ctx.starved) ctx.redraw();
            return;
        }
        if (!ctx.have_bufs) return;
        switch (ctx.win.handle(&ctx.app, ev)) {
            .configure => if (ctx.frame == 0) ctx.redraw(),
            .frame => ctx.redraw(),
            .close => ctx.done = true,
            else => {},
        }
    }

    /// The (format, modifier) the client renders with: XRGB8888 from the
    /// tranche, implicit preferred.
    fn choose(ctx: *Ctx) u64 {
        var linear = false;
        var i: usize = 0;
        while (i + 2 <= ctx.tranche.len) : (i += 2) {
            const idx = std.mem.readInt(u16, ctx.tranche[i..][0..2], .little);
            if (@as(usize, idx) * 16 + 16 > ctx.table.len) wl.fail("tranche index {d} past the format table", .{idx});
            const e = ctx.table[@as(usize, idx) * 16 ..][0..16];
            if (std.mem.readInt(u32, e[0..4], .little) != fourcc_xrgb8888) continue;
            const m = std.mem.readInt(u64, e[8..16], .little);
            if (m == mod_invalid) return m;
            if (m == 0) linear = true;
        }
        if (linear) return 0;
        wl.fail("no XRGB8888 (implicit or LINEAR) in the dmabuf feedback", .{});
    }

    fn makeBuffer(ctx: *Ctx, dm: u32, modifier: u64) Buf {
        const c = ctx.app.c;
        const stride = W * 4;
        const size = stride * H;
        const mrc = linux.memfd_create("wland-fixture-dmabuf", linux.MFD.CLOEXEC);
        if (linux.errno(mrc) != .SUCCESS) wl.fail("memfd_create failed", .{});
        const fd: i32 = @intCast(mrc);
        if (linux.errno(linux.ftruncate(fd, size)) != .SUCCESS) wl.fail("ftruncate failed", .{});
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(addr) != .SUCCESS) wl.fail("mmap failed", .{});
        const params = c.new("zwp_linux_buffer_params_v1");
        c.send(dm, "zwp_linux_dmabuf_v1", "create_params", &.{.{ .new_id = params }});
        c.sendFds(params, "zwp_linux_buffer_params_v1", "add", &.{
            .fd, .{ .uint = 0 }, .{ .uint = 0 }, .{ .uint = stride }, .{ .uint = @truncate(modifier >> 32) }, .{ .uint = @truncate(modifier) },
        }, &.{fd});
        const id = c.new("wl_buffer");
        c.send(params, "zwp_linux_buffer_params_v1", "create_immed", &.{ .{ .new_id = id }, .{ .int = W }, .{ .int = H }, .{ .uint = fourcc_xrgb8888 }, .{ .uint = 0 } });
        c.send(params, "zwp_linux_buffer_params_v1", "destroy", &.{});
        c.flush(); // the fd travels now; then it can go
        _ = linux.close(fd);
        const px: [*]u32 = @ptrFromInt(addr);
        return .{ .id = id, .px = px[0 .. W * H] };
    }

    fn redraw(ctx: *Ctx) void {
        const c = ctx.app.c;
        const b = for (&ctx.bufs) |*b| {
            if (!b.busy) break b;
        } else {
            ctx.starved = true; // a release will come
            return;
        };
        ctx.starved = false;
        ctx.frame += 1;
        // simple-dmabuf-egl's moving square, more or less
        const t = ctx.frame * 4;
        for (0..H) |y| for (0..W) |x| {
            const inside = (x + t) % W < 64 and (y + t / 2) % H < 64;
            b.px[y * W + x] = if (inside) 0x00ffcc33 else 0x00203040 | @as(u32, @intCast(x & 0xff));
        };
        c.send(ctx.win.surface, "wl_surface", "attach", &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
        c.send(ctx.win.surface, "wl_surface", "damage_buffer", &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = W }, .{ .int = H } });
        ctx.win.requestFrame(&ctx.app);
        c.send(ctx.win.surface, "wl_surface", "commit", &.{});
        b.busy = true;
        if (ctx.frame % 30 == 0) wl.print("frame {d}", .{ctx.frame});
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: Ctx = .{ .gpa = gpa };
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    const dm = c.mustBind("zwp_linux_dmabuf_v1", 4);
    const fb = c.new("zwp_linux_dmabuf_feedback_v1");
    c.send(dm, "zwp_linux_dmabuf_v1", "get_default_feedback", &.{.{ .new_id = fb }});
    c.roundtrip(&ctx);
    if (!ctx.feedback_done) wl.fail("no dmabuf feedback after a roundtrip", .{});
    const modifier = ctx.choose();
    wl.print("dmabuf: format XR24 modifier 0x{x:0>16} ({d} table entries) on device 0x{x}", .{ modifier, ctx.table.len / 16, ctx.device });
    for (&ctx.bufs) |*b| b.* = ctx.makeBuffer(dm, modifier);
    ctx.win = app_mod.Window.create(&ctx.app, "simple-dmabuf-egl", "wland-fixture", W, H);
    ctx.have_bufs = true;
    while (!ctx.done) {
        if (!c.dispatch(&ctx, -1)) break;
    }
}
