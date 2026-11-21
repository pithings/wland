// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! linux-dmabuf, relay side. The compositor (core) owns the protocol objects
//! and errors; the relay owns the fds: zwp_linux_buffer_params_v1.add hands
//! one per plane (relay.zig keeps it in `Params`), create/create_immed turn
//! the params into a `Buffer` in the conn's buffer table, and the commit
//! path asks the dmabuf backend what to do with it (`Buffer.view`).
//!
//! The backend (`--dmabuf`) is relay-global and decides two things:
//!   - what to offer: the (format, modifier) pairs and the device clients
//!     allocate on — the FEATURE frame the relay sends first on every link,
//!     which is what makes the compositor advertise zwp_linux_dmabuf_v1;
//!   - how a buffer's commits reach the engine (`View`).
//!
//! One backend today, `readback`: LINEAR only, plane 0 mapped read-only and
//! read at commit time into the copy path (BUFFER frames), exactly as a
//! wl_shm pool — so the engine and the page see no difference. A backend
//! that names a GPU resource instead of shipping pixels (STREAM.md COMMIT
//! kind 2) would add a `Backend` tag, its formats and a `View` variant.
//! Everything here runs on the conn's app thread.

const std = @import("std");
const linux = std.os.linux;
const stream = @import("core").stream;
const shm = @import("shm.zig");

/// DRM fourcc codes (drm_fourcc.h) and modifiers this file names.
pub const fourcc_argb8888: u32 = 0x34325241; // 'AR24': LE B, G, R, A — wl_shm ARGB8888
pub const fourcc_xrgb8888: u32 = 0x34325258; // 'XR24': LE B, G, R, X — wl_shm XRGB8888
pub const mod_linear: u64 = 0;
pub const max_planes = 4;

pub const Format = struct { fourcc: u32, modifier: u64 };

/// The relay's dmabuf backend, chosen at startup.
pub const Backend = union(enum) {
    /// Map the dmabuf and copy damaged pixels into the stream at commit
    /// time (the copy backend's path; needs `--buffers copy`). LINEAR
    /// ARGB8888/XRGB8888 only: a CPU mapping of a tiled or compressed
    /// buffer is not pixels.
    readback,

    pub fn formats(self: Backend) []const Format {
        return switch (self) {
            .readback => &readback_formats,
        };
    }

    pub fn needsCopyPath(self: Backend) bool {
        return switch (self) {
            .readback => true,
        };
    }
};

const readback_formats = [_]Format{
    .{ .fourcc = fourcc_argb8888, .modifier = mod_linear },
    .{ .fourcc = fourcc_xrgb8888, .modifier = mod_linear },
};

/// What the relay offers: its backend and the device clients allocate on.
pub const Config = struct {
    backend: Backend,
    /// dev_t of that device (feedback main_device / tranche_target_device;
    /// Mesa opens its render node from it). readback: the host's render
    /// node.
    main_device: u64,

    pub const max_feature_len = stream.feature_header_len + 8 + 16 * 16;

    /// The FEATURE frame announcing this to the engine.
    pub fn featureFrame(self: Config, out: *[max_feature_len]u8) []u8 {
        const fmts = self.backend.formats();
        var bytes: [8 + 16 * 16]u8 = undefined;
        std.debug.assert(fmts.len <= 16);
        // stream.DmabufFeature layout, built in place
        std.mem.writeInt(u64, bytes[0..8], self.main_device, .little);
        for (fmts, 0..) |f, i| stream.writeFormatEntry(bytes[8 + i * 16 ..][0..16], f.fourcc, f.modifier);
        return stream.encodeFeature(out, .linux_dmabuf, bytes[0 .. 8 + fmts.len * 16]);
    }
};

/// glibc's makedev(): the dev_t clients compare against their render node.
pub fn makedev(major: u32, minor: u32) u64 {
    return (@as(u64, major & 0xfffff000) << 32) | (@as(u64, major & 0xfff) << 8) |
        (@as(u64, minor & 0xffffff00) << 12) | (minor & 0xff);
}

/// dev_t of a character device node (a /dev/dri render node).
pub fn deviceOf(path: [*:0]const u8) !u64 {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return error.NoDevice;
    if (!linux.S.ISCHR(stx.mode)) return error.NotADevice;
    return makedev(stx.rdev_major, stx.rdev_minor);
}

/// The first DRM render node (/dev/dri/renderD128…), its path in `buf`.
pub fn firstRenderNode(buf: *[32]u8) ?[:0]const u8 {
    for (128..192) |minor| {
        const path = std.fmt.bufPrintZ(buf, "/dev/dri/renderD{d}", .{minor}) catch unreachable;
        if (deviceOf(path)) |_| return path else |_| {}
    }
    return null;
}

/// One plane as zwp_linux_buffer_params_v1.add gave it; `fd` owned.
pub const Plane = struct { fd: i32, offset: u32, stride: u32, modifier: u64 };

/// A zwp_linux_buffer_params_v1's planes so far. The protocol errors
/// (bad index, plane set twice, …) are the compositor's: a plane it would
/// refuse is not kept here either, its fd closed.
pub const Params = struct {
    planes: [max_planes]?Plane = @splat(null),

    /// Keep `plane` (false: index out of range or already set — the fd was
    /// closed and the compositor raises the error).
    pub fn add(self: *Params, idx: u32, plane: Plane) bool {
        if (idx >= max_planes or self.planes[idx] != null) {
            _ = linux.close(plane.fd);
            return false;
        }
        self.planes[idx] = plane;
        return true;
    }

    /// create/create_immed: the planes move into a Buffer; these params
    /// are empty after (only destroy may follow).
    pub fn take(self: *Params, width: i32, height: i32, format: u32, flags: u32) Buffer {
        const b: Buffer = .{
            .planes = self.planes,
            .width = std.math.cast(u32, width) orelse 0,
            .height = std.math.cast(u32, height) orelse 0,
            .format = format,
            .flags = flags,
        };
        self.planes = @splat(null);
        return b;
    }

    pub fn deinit(self: *Params) void {
        for (self.planes) |p| if (p) |plane| {
            _ = linux.close(plane.fd);
        };
        self.planes = @splat(null);
    }
};

/// A wl_buffer made from dmabufs: the planes (fds owned, valid for the
/// buffer's life per the protocol) and what the backend made of them.
/// Heap-allocated (the buffer table rehashes; a readback view points in).
pub const Buffer = struct {
    planes: [max_planes]?Plane,
    width: u32,
    height: u32,
    format: u32,
    flags: u32,
    /// Resolved at the first commit, kept for the buffer's life.
    import: Import = .pending,
    /// readback: plane 0 answers DMA_BUF_IOCTL_SYNC (null = not asked yet;
    /// false = not a dmabuf — a memfd stand-in in tests)
    syncs: ?bool = null,

    pub const Import = union(enum) {
        pending,
        /// The backend can't use this buffer (logged once): never shown;
        /// its commits still release it, like an unfit wl_shm buffer.
        failed,
        /// readback: plane 0 mapped read-only, whole (a shm Pool: the
        /// SIGBUS guard covers a memfd truncated under us).
        mapped: *shm.Pool,
    };

    pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
        switch (self.import) {
            .mapped => |pool| {
                pool.deinit();
                gpa.destroy(pool);
            },
            .pending, .failed => {},
        }
        for (self.planes) |p| if (p) |plane| {
            _ = linux.close(plane.fd);
        };
    }

    /// How this buffer's commits reach the engine (importing it on first
    /// use). `.pixels` is read by the copy backend between beginRead and
    /// endRead.
    pub fn view(self: *Buffer, backend: Backend, gpa: std.mem.Allocator, conn_id: u32, buffer_id: u32) View {
        if (self.import == .pending) {
            self.import = switch (backend) {
                .readback => self.importReadback(gpa) catch |err| blk: {
                    std.log.warn("conn {d}: dmabuf buffer {d} ({d}x{d} fourcc 0x{x}): readback import failed: {t}; it will not be shown", .{ conn_id, buffer_id, self.width, self.height, self.format, err });
                    break :blk .failed;
                },
            };
        }
        return switch (self.import) {
            .pending, .failed => .unreadable,
            .mapped => |pool| .{ .pixels = .{
                .pool = pool,
                .offset = self.planes[0].?.offset,
                .width = self.width,
                .height = self.height,
                .stride = self.planes[0].?.stride,
                .format = if (self.format == fourcc_xrgb8888) stream.shm_format_xrgb8888 else stream.shm_format_argb8888,
            } },
        };
    }

    /// Readback: one LINEAR plane of a 4-byte format, rows inside the
    /// dmabuf's real size (lseek SEEK_END: a dmabuf's size is fixed, a
    /// memfd's is whatever it is now — the SIGBUS guard covers later
    /// truncation), mapped whole.
    fn importReadback(self: *Buffer, gpa: std.mem.Allocator) !Import {
        if (self.format != fourcc_argb8888 and self.format != fourcc_xrgb8888) return error.UnsupportedFormat;
        if (self.flags != 0) return error.UnsupportedFlags; // y_invert / interlaced
        const plane = self.planes[0] orelse return error.Incomplete;
        for (self.planes[1..]) |p| if (p != null) return error.TooManyPlanes;
        if (plane.modifier != mod_linear) return error.NotLinear;
        if (self.width == 0 or self.height == 0) return error.BadGeometry;
        if (plane.stride < @as(u64, self.width) * 4) return error.BadGeometry;
        const end = linux.lseek(plane.fd, 0, linux.SEEK.END);
        if (linux.errno(end) != .SUCCESS) return error.NoSize;
        const size: u64 = end;
        if (@as(u64, plane.offset) + @as(u64, plane.stride) * self.height > size) return error.OutOfBounds;
        const dup = linux.fcntl(plane.fd, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(dup) != .SUCCESS) return error.DupFailed;
        const pool = gpa.create(shm.Pool) catch |err| {
            _ = linux.close(@intCast(dup));
            return err;
        };
        pool.* = .{ .fd = @intCast(dup), .size = @intCast(size) };
        pool.map() catch |err| {
            pool.deinit();
            gpa.destroy(pool);
            return err;
        };
        return .{ .mapped = pool };
    }

    /// Before the copy path reads the mapping: wait (bounded) for the
    /// writers' implicit fences — poll(POLLIN) on a dmabuf blocks until
    /// its pending writes are done; a regular file is always ready — then
    /// DMA_BUF_IOCTL_SYNC(START | READ) so a non-coherent CPU view is
    /// valid. ENOTTY = not a dmabuf (a memfd): no sync needed, never asked
    /// again.
    pub fn beginRead(self: *Buffer, conn_id: u32) void {
        const fd = self.planes[0].?.fd;
        var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const rc = linux.poll(&pfd, 1, fence_wait_ms);
            switch (linux.errno(rc)) {
                .INTR => continue,
                .SUCCESS => if (rc == 0) std.log.warn("conn {d}: dmabuf still being written after {d} ms; reading it anyway", .{ conn_id, fence_wait_ms }),
                else => {},
            }
            break;
        }
        self.sync(sync_start | sync_read);
    }

    pub fn endRead(self: *Buffer) void {
        self.sync(sync_end | sync_read);
    }

    fn sync(self: *Buffer, flags: u64) void {
        if (self.syncs == false) return;
        var arg: u64 = flags;
        while (true) {
            const rc = linux.ioctl(self.planes[0].?.fd, dma_buf_ioctl_sync, @intFromPtr(&arg));
            switch (linux.errno(rc)) {
                .SUCCESS => self.syncs = true,
                .INTR, .AGAIN => continue,
                .NOTTY => self.syncs = false,
                else => |e| if (self.syncs == null) {
                    std.log.warn("dmabuf: DMA_BUF_IOCTL_SYNC failed ({t}); reading without it", .{e});
                    self.syncs = false;
                },
            }
            return;
        }
    }
};

/// A commit's buffer, as the commit path delivers it.
pub const View = union(enum) {
    /// Not presentable (import failed): nothing shown, release at commit.
    unreadable,
    /// Pixels in a wl_shm-shaped view: the copy backend reads them at
    /// commit time (BUFFER frames) and the buffer is released at once.
    pixels: shm.Buffer,
};

/// How long a commit waits for a dmabuf's pending GPU writes before
/// reading it anyway (a hung GPU must not wedge the app's relay thread).
const fence_wait_ms = 500;

// linux/dma-buf.h: struct dma_buf_sync { __u64 flags; }
const sync_read: u64 = 1 << 0;
const sync_start: u64 = 0 << 2;
const sync_end: u64 = 1 << 2;
/// _IOW('b', 0, struct dma_buf_sync), asm-generic _IOC (x86_64 and aarch64)
const dma_buf_ioctl_sync: u32 = (1 << 30) | (8 << 16) | (@as(u32, 'b') << 8) | 0;

test "makedev matches glibc: renderD128 = 226:128" {
    try std.testing.expectEqual(@as(u64, 0xe280), makedev(226, 128));
    try std.testing.expectEqual(@as(u64, 0x0000_1000_0340_1256), makedev(0x1012, 0x3456));
    try std.testing.expectEqual(@as(u32, 0x40086200), dma_buf_ioctl_sync);
}

test "config feature frame carries the device and the backend's formats" {
    const cfg: Config = .{ .backend = .readback, .main_device = 0xe280 };
    var out: [Config.max_feature_len]u8 = undefined;
    const f = (try stream.parse(cfg.featureFrame(&out))).feature;
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.linux_dmabuf)), f.feature);
    const d = try stream.DmabufFeature.decode(f.bytes);
    try std.testing.expectEqual(@as(u64, 0xe280), d.main_device);
    try std.testing.expectEqual(@as(usize, 2), d.count());
    try std.testing.expectEqual(fourcc_argb8888, d.entry(0).format);
    try std.testing.expectEqual(mod_linear, d.entry(1).modifier);
}

test "readback import refuses what it can't read: modifiers, formats, flags, short fds; maps a memfd and views it as wl_shm" {
    const gpa = std.testing.allocator;
    var bytes: [64]u8 = @splat(0x11);
    const fd = try shm.createMemfd("dmabuf-test", &bytes); // 65 bytes with the NUL
    defer _ = linux.close(fd);
    const Case = struct {
        fn make(src: i32, offset: u32, stride: u32, modifier: u64, w: i32, h: i32, format: u32, flags: u32) !Buffer {
            var p: Params = .{};
            const d = linux.fcntl(src, linux.F.DUPFD_CLOEXEC, 0);
            if (linux.errno(d) != .SUCCESS) return error.DupFailed;
            try std.testing.expect(p.add(0, .{ .fd = @intCast(d), .offset = offset, .stride = stride, .modifier = modifier }));
            return p.take(w, h, format, flags);
        }
    };
    const bad = [_]Buffer{
        try Case.make(fd, 0, 16, 0x0100000000000001, 4, 4, fourcc_xrgb8888, 0), // X-tiled
        try Case.make(fd, 0, 16, mod_linear, 4, 4, 0x34324241, 0), // ABGR8888
        try Case.make(fd, 0, 16, mod_linear, 4, 4, fourcc_xrgb8888, 1), // y_invert
        try Case.make(fd, 4, 16, mod_linear, 4, 4, fourcc_xrgb8888, 0), // past the fd's end
        try Case.make(fd, 0, 8, mod_linear, 4, 4, fourcc_xrgb8888, 0), // stride < width * 4
    };
    for (bad) |b| {
        var buf = b;
        defer buf.deinit(gpa);
        std.testing.log_level = .err; // the warnings are the point
        defer std.testing.log_level = .warn;
        try std.testing.expectEqual(View.unreadable, buf.view(.readback, gpa, 1, 2));
        try std.testing.expectEqual(Buffer.Import.failed, buf.import);
    }

    var good = try Case.make(fd, 0, 16, mod_linear, 4, 4, fourcc_xrgb8888, 0);
    defer good.deinit(gpa);
    const v = good.view(.readback, gpa, 1, 2).pixels;
    try std.testing.expectEqual(stream.shm_format_xrgb8888, v.format);
    try std.testing.expect(v.fits());
    good.beginRead(1);
    try std.testing.expectEqual(@as(u8, 0x11), v.pool.data[63]);
    good.endRead();
    try std.testing.expectEqual(@as(?bool, false), good.syncs); // a memfd: ENOTTY, not asked again

    // params refuse a second plane 0 and an index past 3 (closing the fd)
    var p: Params = .{};
    defer p.deinit();
    try std.testing.expect(p.add(0, .{ .fd = @intCast(linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0)), .offset = 0, .stride = 16, .modifier = 0 }));
    try std.testing.expect(!p.add(0, .{ .fd = @intCast(linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0)), .offset = 0, .stride = 16, .modifier = 0 }));
    try std.testing.expect(!p.add(4, .{ .fd = @intCast(linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0)), .offset = 0, .stride = 16, .modifier = 0 }));
}
