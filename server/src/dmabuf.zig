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
//! Two backends:
//!   - `readback`: LINEAR only, plane 0 mapped read-only and read at commit
//!     time into the copy path (BUFFER frames), exactly as a wl_shm pool —
//!     so the engine and the page see no difference;
//!   - `virtgpu`: nothing is read. At create/create_immed plane 0 is named
//!     as the virtio-gpu resource behind it (virtgpu.zig: PRIME import +
//!     RESOURCE_INFO) and every commit is a COMMIT of buffer kind virtgpu
//!     (STREAM.md) the engine ACKs, on the relay's shared COMMIT/ACK
//!     ledger (relay.zig); any buffer mode, no copy path.
//! Everything here runs on the conn's app thread (virtgpu's Importer is
//! the one relay-wide, locked part).

const std = @import("std");
const linux = std.os.linux;
const stream = @import("core").stream;
const shm = @import("shm.zig");
const virtgpu = @import("virtgpu.zig");

/// DRM fourcc codes (drm_fourcc.h) and modifiers this file names.
pub const fourcc_argb8888: u32 = 0x34325241; // 'AR24': LE B, G, R, A — wl_shm ARGB8888
pub const fourcc_xrgb8888: u32 = 0x34325258; // 'XR24': LE B, G, R, X — wl_shm XRGB8888
pub const fourcc_abgr8888: u32 = 0x34324241; // 'AB24': LE R, G, B, A
pub const fourcc_xbgr8888: u32 = 0x34324258; // 'XB24': LE R, G, B, X
pub const mod_linear: u64 = 0;
/// DRM_FORMAT_MOD_INVALID: no explicit modifier, the driver's implicit
/// layout (what virgl allocates with: it has no modifiers)
pub const mod_invalid: u64 = 0x00ff_ffff_ffff_ffff;
pub const max_planes = 4;

pub const Format = struct { fourcc: u32, modifier: u64 };

/// The relay's dmabuf backend, chosen at startup.
pub const Backend = union(enum) {
    /// Map the dmabuf and copy damaged pixels into the stream at commit
    /// time (the copy backend's path; needs `--buffers copy`). LINEAR
    /// ARGB8888/XRGB8888 only: a CPU mapping of a tiled or compressed
    /// buffer is not pixels.
    readback,
    /// Name each dmabuf by its virtio-gpu resource (COMMIT kind virtgpu):
    /// the relay-wide importer on the render node. 8888 RGB formats,
    /// implicit (MOD_INVALID) or LINEAR, one plane: the embedder's
    /// renderer reads the resource, so the layout only has to be one it
    /// knows — virgl allocates with the implicit modifier.
    virtgpu: *virtgpu.Importer,

    pub fn formats(self: Backend) []const Format {
        return switch (self) {
            .readback => &readback_formats,
            .virtgpu => &virtgpu_formats,
        };
    }

    pub fn needsCopyPath(self: Backend) bool {
        return switch (self) {
            .readback => true,
            .virtgpu => false,
        };
    }

    /// Its commits are COMMIT frames the engine ACKs (the conn needs the
    /// ACK path whatever the buffer mode).
    pub fn sendsCommits(self: Backend) bool {
        return switch (self) {
            .readback => false,
            .virtgpu => true,
        };
    }
};

const readback_formats = [_]Format{
    .{ .fourcc = fourcc_argb8888, .modifier = mod_linear },
    .{ .fourcc = fourcc_xrgb8888, .modifier = mod_linear },
};

/// Preference order (the one tranche lists them so): implicit first, the
/// layout Mesa's virgl picks anyway.
const virtgpu_formats = [_]Format{
    .{ .fourcc = fourcc_argb8888, .modifier = mod_invalid },
    .{ .fourcc = fourcc_xrgb8888, .modifier = mod_invalid },
    .{ .fourcc = fourcc_abgr8888, .modifier = mod_invalid },
    .{ .fourcc = fourcc_xbgr8888, .modifier = mod_invalid },
    .{ .fourcc = fourcc_argb8888, .modifier = mod_linear },
    .{ .fourcc = fourcc_xrgb8888, .modifier = mod_linear },
    .{ .fourcc = fourcc_abgr8888, .modifier = mod_linear },
    .{ .fourcc = fourcc_xbgr8888, .modifier = mod_linear },
};

/// What the relay offers: its backend and the device clients allocate on.
pub const Config = struct {
    backend: Backend,
    /// dev_t of that device (feedback main_device / tranche_target_device;
    /// Mesa opens its render node from it): the render node the backend
    /// reads (readback) or names resources on (virtgpu).
    main_device: u64,

    const kind_frame_len = stream.feature_header_len + stream.DmabufKindFeature.len;
    pub const max_features_len = kind_frame_len + stream.feature_header_len + 8 + 16 * 16;

    /// The FEATURE frames announcing this to the engine, as one link
    /// message: for a backend whose commits are COMMITs (virtgpu) first
    /// dmabuf_kind naming their buffer kind — an engine that can't show it
    /// then leaves linux-dmabuf off — then linux_dmabuf (device + formats).
    pub fn featureFrames(self: Config, out: *[max_features_len]u8) []u8 {
        var n: usize = 0;
        if (self.backend.sendsCommits()) {
            var kb: [stream.DmabufKindFeature.len]u8 = undefined;
            (stream.DmabufKindFeature{ .buffer_kind = @intFromEnum(stream.BufferKind.virtgpu) }).encode(&kb);
            n += stream.encodeFeature(out[n..], .dmabuf_kind, &kb).len;
        }
        const fmts = self.backend.formats();
        var bytes: [8 + 16 * 16]u8 = undefined;
        std.debug.assert(fmts.len <= 16);
        // stream.DmabufFeature layout, built in place
        std.mem.writeInt(u64, bytes[0..8], self.main_device, .little);
        for (fmts, 0..) |f, i| stream.writeFormatEntry(bytes[8 + i * 16 ..][0..16], f.fourcc, f.modifier);
        n += stream.encodeFeature(out[n..], .linux_dmabuf, bytes[0 .. 8 + fmts.len * 16]).len;
        return out[0..n];
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
    /// virtgpu: at create (`prepare`); readback: at the first commit. Kept
    /// for the buffer's life.
    import: Import = .pending,
    /// readback: plane 0 answers DMA_BUF_IOCTL_SYNC (null = not asked yet;
    /// false = not a dmabuf — a memfd stand-in in tests)
    syncs: ?bool = null,

    pub const Import = union(enum) {
        pending,
        /// The backend can't use this buffer (logged once per kind): never
        /// shown; its commits still release it, like an unfit wl_shm buffer.
        failed,
        /// readback: plane 0 mapped read-only, whole (a shm Pool: the
        /// SIGBUS guard covers a memfd truncated under us).
        mapped: *shm.Pool,
        /// virtgpu: the resource, and the GEM handle this buffer holds a
        /// reference on (dropped by deinit; each un-ACKed COMMIT holds its
        /// own, so the resource outlives wl_buffer.destroy until its ACKs).
        resource: Resource,
    };

    pub const Resource = struct {
        importer: *virtgpu.Importer,
        gem: u32,
        id: u32,
    };

    pub fn deinit(self: *Buffer, gpa: std.mem.Allocator) void {
        switch (self.import) {
            .mapped => |pool| {
                pool.deinit();
                gpa.destroy(pool);
            },
            .resource => |r| r.importer.unref(r.gem),
            .pending, .failed => {},
        }
        for (self.planes) |p| if (p) |plane| {
            _ = linux.close(plane.fd);
        };
    }

    /// At create/create_immed: a backend that names buffers names this one
    /// now (virtgpu), so the resource is known — or the refusal logged —
    /// before the first commit. `label` says which object for the log
    /// (create's wl_buffer id is not known yet: the params id then).
    pub fn prepare(self: *Buffer, backend: Backend, conn_id: u32, label: []const u8, id: u32) void {
        switch (backend) {
            .readback => {},
            .virtgpu => |imp| self.import = self.importVirtgpu(imp, conn_id, label, id),
        }
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
                .virtgpu => |imp| self.importVirtgpu(imp, conn_id, "buffer", buffer_id),
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
            .resource => |r| .{ .resource = .{
                .gem = r.gem,
                .importer = r.importer,
                .ref = .{
                    .resource = r.id,
                    .width = self.width,
                    .height = self.height,
                    .format = self.format,
                    .flags = self.flags,
                    .offset = self.planes[0].?.offset,
                    .stride = self.planes[0].?.stride,
                    .modifier = self.planes[0].?.modifier,
                },
            } },
        };
    }

    /// virtgpu: one plane of an 8888 RGB format, implicit or LINEAR, no
    /// interlacing, named through the render node, and the plane inside the
    /// resource (`bounds`). What is refused, and the first buffer of each
    /// (format, modifier, flags) accepted, is logged once per relay run:
    /// the first run on a new guest says what its Mesa allocates.
    fn importVirtgpu(self: *Buffer, imp: *virtgpu.Importer, conn_id: u32, label: []const u8, id: u32) Import {
        const plane = self.planes[0] orelse return .failed; // the compositor raises `incomplete`
        const fcc: [4]u8 = @bitCast(self.format);
        const kind = struct {
            fn key(tag: u64, a: u64, b: u64, c: u64) u64 {
                return std.hash.Wyhash.hash(tag, std.mem.asBytes(&[3]u64{ a, b, c }));
            }
        };
        const refusal: ?[]const u8 = blk: {
            for (virtgpu_formats) |f| {
                if (f.fourcc == self.format and f.modifier == plane.modifier) break;
            } else break :blk "format/modifier not offered";
            for (self.planes[1..]) |p| if (p != null) break :blk "more than one plane";
            if (self.flags & ~@as(u32, 1) != 0) break :blk "interlaced flags";
            if (self.width == 0 or self.height == 0) break :blk "empty size";
            break :blk null;
        };
        if (refusal) |why| {
            if (imp.once(.refused, kind.key(1, self.format, plane.modifier, self.flags)))
                std.log.warn("virtgpu: conn {d} {s} {d}: refused ({s}): '{s}' 0x{x:0>8} modifier 0x{x:0>16} flags {d}, {d}x{d}; buffers like it are never shown", .{ conn_id, label, id, why, &fcc, self.format, plane.modifier, self.flags, self.width, self.height });
            return .failed;
        }
        switch (imp.import(plane.fd)) {
            .failed => |f| {
                // a device that won't open is logged by the importer, rate-
                // limited (it is no property of this buffer, and repeats)
                if (f.step != .open_device and imp.once(.refused, kind.key(2, @intFromEnum(f.step), @intFromEnum(f.errno), 0)))
                    std.log.warn("virtgpu: conn {d} {s} {d}: cannot name its dmabuf: {t} failed ({t}); buffers like it are never shown", .{ conn_id, label, id, f.step, f.errno });
                return .failed;
            },
            .ok => |r| {
                if (virtgpuBounds(self.width, self.height, plane.offset, plane.stride, r.size)) |why| {
                    imp.unref(r.gem);
                    const text = refusalText(why, r.size);
                    if (imp.once(.refused, kind.key(4, @intFromEnum(why), @intFromBool(text.ptr != why.text().ptr), 0)))
                        std.log.warn("virtgpu: conn {d} {s} {d}: refused ({s}): {d}x{d} offset {d} stride {d} on a {d} B resource {d}; buffers like it are never shown", .{ conn_id, label, id, text, self.width, self.height, plane.offset, plane.stride, r.size, r.resource });
                    return .failed;
                }
                if (imp.once(.accepted, kind.key(3, self.format, plane.modifier, self.flags)))
                    std.log.info("virtgpu: conn {d} {s} {d}: first '{s}' 0x{x:0>8} modifier 0x{x:0>16} flags {d} buffer, {d}x{d} stride {d} → resource {d} ({d} B)", .{ conn_id, label, id, &fcc, self.format, plane.modifier, self.flags, self.width, self.height, plane.stride, r.resource, r.size });
                return .{ .resource = .{ .importer = imp, .gem = r.gem, .id = r.resource } };
            },
        }
    }

    /// virtgpu, before a COMMIT goes out: wait (at most `timeout_ms`) for
    /// the writes still pending on the buffer — poll(POLLIN) on a dmabuf
    /// returns once its implicit write fences (dma_resv) have signalled; a
    /// regular file (a memfd stand-in) is always ready. False = timed out
    /// (the caller sends anyway).
    pub fn awaitWrites(self: *Buffer, timeout_ms: i32) bool {
        var pfd = [1]linux.pollfd{.{ .fd = self.planes[0].?.fd, .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const rc = linux.poll(&pfd, 1, timeout_ms);
            switch (linux.errno(rc)) {
                .INTR => continue,
                .SUCCESS => return rc != 0,
                else => return true, // not pollable: nothing to wait for
            }
        }
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

/// A side of a virtgpu buffer may not exceed this: the page's renderer
/// holds it as one texture, and GL caps those (MAX_TEXTURE_SIZE, 16384 on
/// desktop GPUs; WebGL inherits it). The size check below already bounds
/// the area by memory; this keeps a one-page resource from claiming a
/// 1×1048576 shape the page would size a canvas from.
pub const virtgpu_max_side = 16384;

pub const BoundsRefusal = enum {
    stride_below_width,
    too_large,
    past_resource,

    pub fn text(self: BoundsRefusal) []const u8 {
        return switch (self) {
            .stride_below_width => "stride below width × 4",
            .too_large => "a side over 16384 px",
            .past_resource => "plane past the resource's end",
        };
    }
};

/// A client's claimed size and layout against the resource's real size
/// (RESOURCE_INFO: the GEM object's size — the guest backing the guest's
/// Mesa asked for, rounded up to a page by the kernel; virtgpu_ioctl.c
/// resource_create, virtgpu_object.c). Null = fits. That size is the
/// layout's total (256-aligned) only for resources created
/// PIPE_BIND_SHARED, which GBM and EGL-Wayland buffers always are, so a GPU
/// client's buffers pass. Mesa's virgl_resource_create_front asks for 1
/// byte for a texture that can use staging transfers and 0 for MSAA, i.e.
/// one page: such a non-shared texture exported as a dmabuf is refused
/// here though valid on the host — the safe side, since the relay can't
/// tell the host's real size (`refusalText` names the case). Every format
/// offered is 4 bytes a pixel. The last row needs only width × 4 bytes (a
/// tightly allocated plane is legal).
pub fn virtgpuBounds(width: u32, height: u32, offset: u32, stride: u32, size: u32) ?BoundsRefusal {
    if (@as(u64, stride) < @as(u64, width) * 4) return .stride_below_width;
    if (width > virtgpu_max_side or height > virtgpu_max_side) return .too_large;
    const end = @as(u64, offset) + @as(u64, stride) * (height - 1) + @as(u64, width) * 4;
    if (end > size) return .past_resource;
    return null;
}

/// The refusal's reason as logged: a plane past a ONE-page resource is
/// most likely a texture Mesa created without PIPE_BIND_SHARED (guest
/// backing of 1 or 0 bytes, see virtgpuBounds), not a lying client.
pub fn refusalText(why: BoundsRefusal, size: u32) []const u8 {
    if (why == .past_resource and size <= std.heap.pageSize())
        return "resource has no guest backing of the claimed size (non-shared virgl texture?)";
    return why.text();
}

/// A commit's buffer, as the commit path delivers it.
pub const View = union(enum) {
    /// Not presentable (import failed): nothing shown, release at commit.
    unreadable,
    /// Pixels in a wl_shm-shaped view: the copy backend reads them at
    /// commit time (BUFFER frames) and the buffer is released at once.
    pixels: shm.Buffer,
    /// A named GPU resource: a COMMIT of kind virtgpu, released on its ACK
    /// (each COMMIT takes a reference on `gem` until then).
    resource: struct {
        ref: stream.VirtgpuRef,
        gem: u32,
        importer: *virtgpu.Importer,
    },
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

test "config feature frames: readback, linux_dmabuf alone with the device and the backend's formats" {
    const cfg: Config = .{ .backend = .readback, .main_device = 0xe280 };
    var out: [Config.max_features_len]u8 = undefined;
    const msg = cfg.featureFrames(&out);
    const p = try stream.parseNext(msg);
    try std.testing.expectEqual(msg.len, p.consumed); // nothing else: no dmabuf_kind (pixels in the stream)
    const f = p.frame.feature;
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

test "virtgpu import: named at prepare through the fake device; refusals (multi-plane, modifier, format, flags) fail without a handle; view is the kind-virtgpu ref; deinit drops the GEM reference" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var fake: virtgpu.Fake = .{};
    defer fake.deinit();
    var imp: virtgpu.Importer = .init(threaded.io(), gpa, .{ .fd = -1, .fake = &fake });
    defer imp.deinit();
    const backend: Backend = .{ .virtgpu = &imp };
    try std.testing.expect(backend.sendsCommits() and !backend.needsCopyPath());

    const cfg: Config = .{ .backend = backend, .main_device = 0xe280 };
    var out: [Config.max_features_len]u8 = undefined;
    // dmabuf_kind virtgpu first (an engine without a GPU source then offers
    // no linux-dmabuf), then linux_dmabuf; one message, nothing else
    const msg = cfg.featureFrames(&out);
    const k = try stream.parseNext(msg);
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.dmabuf_kind)), k.frame.feature.feature);
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.BufferKind.virtgpu)), (try stream.DmabufKindFeature.decode(k.frame.feature.bytes)).buffer_kind);
    const l = try stream.parseNext(msg[k.consumed..]);
    try std.testing.expectEqual(msg.len, k.consumed + l.consumed);
    try std.testing.expectEqual(@as(u32, @intFromEnum(stream.FeatureKind.linux_dmabuf)), l.frame.feature.feature);
    const d = try stream.DmabufFeature.decode(l.frame.feature.bytes);
    try std.testing.expectEqual(@as(usize, 8), d.count());

    var bytes: [64]u8 = @splat(0);
    const fd = try shm.createMemfd("virtgpu-import", &bytes);
    defer _ = linux.close(fd);
    const make = struct {
        fn f(src: i32, planes: u32, modifier: u64, format: u32, flags: u32) !Buffer {
            var p: Params = .{};
            for (0..planes) |i| {
                const dup = linux.fcntl(src, linux.F.DUPFD_CLOEXEC, 0);
                try std.testing.expect(p.add(@intCast(i), .{ .fd = @intCast(dup), .offset = 0, .stride = 16, .modifier = modifier }));
            }
            return p.take(4, 4, format, flags);
        }
    }.f;
    const bad = [_]Buffer{
        try make(fd, 2, mod_invalid, fourcc_xrgb8888, 0), // two planes
        try make(fd, 1, 0x0100000000000001, fourcc_xrgb8888, 0), // X-tiled
        try make(fd, 1, mod_invalid, 0x3231564e, 0), // NV12
        try make(fd, 1, mod_linear, fourcc_argb8888, 4), // bottom_first
    };
    std.testing.log_level = .err; // the refusals are warnings
    defer std.testing.log_level = .warn;
    for (bad) |b| {
        var buf = b;
        defer buf.deinit(gpa);
        buf.prepare(backend, 1, "buffer", 2);
        try std.testing.expectEqual(Buffer.Import.failed, buf.import);
        try std.testing.expectEqual(View.unreadable, buf.view(backend, gpa, 1, 2));
    }
    try std.testing.expectEqual(@as(usize, 0), fake.live());

    var good = try make(fd, 1, mod_invalid, fourcc_abgr8888, 1);
    good.prepare(backend, 1, "params", 3);
    const v = good.view(backend, gpa, 1, 2).resource;
    try std.testing.expectEqual(stream.VirtgpuRef{ .resource = 1, .width = 4, .height = 4, .format = fourcc_abgr8888, .flags = 1, .offset = 0, .stride = 16, .modifier = mod_invalid }, v.ref);
    try std.testing.expectEqual(@as(u32, 1), imp.refsOf(v.gem));
    try std.testing.expect(good.awaitWrites(10)); // a memfd: always ready
    good.deinit(gpa);

    // a plane still being written (poll not readable: a pipe with nothing
    // in it stands in for a dmabuf with an unsignalled write fence) times
    // out, bounded, and says so
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(pipe_fds[1]);
    var busy: Buffer = .{ .planes = .{ .{ .fd = pipe_fds[0], .offset = 0, .stride = 16, .modifier = mod_invalid }, null, null, null }, .width = 4, .height = 4, .format = fourcc_xrgb8888, .flags = 0 };
    defer busy.deinit(gpa);
    try std.testing.expect(!busy.awaitWrites(5));
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try std.testing.expectEqual(@as(usize, 0), fake.bad_closes);
}

test "virtgpu bounds: a client's size and stride must fit the resource's real size" {
    // 64×64 XRGB, stride 256, on a page-rounded 16 KiB resource: fits exactly
    try std.testing.expectEqual(@as(?BoundsRefusal, null), virtgpuBounds(64, 64, 0, 256, 16384));
    // the last row needs only width × 4 (no trailing stride padding)
    try std.testing.expectEqual(@as(?BoundsRefusal, null), virtgpuBounds(60, 64, 0, 256, 63 * 256 + 240));
    try std.testing.expectEqual(@as(?BoundsRefusal, .past_resource), virtgpuBounds(60, 64, 0, 256, 63 * 256 + 239));
    try std.testing.expectEqual(@as(?BoundsRefusal, .past_resource), virtgpuBounds(64, 64, 4, 256, 16384));
    // one page claiming a huge buffer
    try std.testing.expectEqual(@as(?BoundsRefusal, .past_resource), virtgpuBounds(16384, 16384, 0, 65536, 4096));
    try std.testing.expectEqual(@as(?BoundsRefusal, .too_large), virtgpuBounds(0x3fff_ffff, 1, 0, 0xffff_fffc, 4096));
    try std.testing.expectEqual(@as(?BoundsRefusal, .too_large), virtgpuBounds(1, 16385, 0, 4, 0xffff_ffff));
    try std.testing.expectEqual(@as(?BoundsRefusal, .stride_below_width), virtgpuBounds(64, 64, 0, 255, 16384));
    // no u32 overflow on the way: offset + stride × (h - 1) + w × 4 in u64
    try std.testing.expectEqual(@as(?BoundsRefusal, .past_resource), virtgpuBounds(16384, 16384, 0xffff_ffff, 0xffff_ffff, 0xffff_ffff));
}

test "virtgpu refusal text: a plane past a one-page resource names the non-shared texture case" {
    const page: u32 = @intCast(std.heap.pageSize());
    try std.testing.expectEqualStrings("resource has no guest backing of the claimed size (non-shared virgl texture?)", refusalText(.past_resource, page));
    try std.testing.expectEqualStrings("plane past the resource's end", refusalText(.past_resource, page * 2));
    try std.testing.expectEqualStrings("a side over 16384 px", refusalText(.too_large, page));
}

test "virtgpu import: a layout past the resource's real size is refused, its handle closed, the reason logged" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var fake: virtgpu.Fake = .{};
    defer fake.deinit();
    var imp: virtgpu.Importer = .init(threaded.io(), gpa, .{ .fake = &fake });
    defer imp.deinit();
    const backend: Backend = .{ .virtgpu = &imp };
    var bytes: [64]u8 = @splat(0);
    const fd = try shm.createMemfd("virtgpu-bounds", &bytes); // one page as the kernel rounds it
    defer _ = linux.close(fd);
    const make = struct {
        fn f(src: i32, w: i32, h: i32, stride: u32) !Buffer {
            var p: Params = .{};
            const dup = linux.fcntl(src, linux.F.DUPFD_CLOEXEC, 0);
            try std.testing.expect(p.add(0, .{ .fd = @intCast(dup), .offset = 0, .stride = stride, .modifier = mod_invalid }));
            return p.take(w, h, fourcc_xrgb8888, 0);
        }
    }.f;
    std.testing.log_level = .err; // the refusal is a warning
    defer std.testing.log_level = .warn;
    var huge = try make(fd, 16384, 16384, 65536);
    defer huge.deinit(gpa);
    huge.prepare(backend, 1, "buffer", 2);
    try std.testing.expectEqual(Buffer.Import.failed, huge.import);
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try std.testing.expect(!imp.deviceOpen());
    try std.testing.expectEqual(@as(usize, 1), imp.n_logged[@intFromEnum(virtgpu.Importer.LogClass.refused)]);
    // a whole page of 32×32 fits
    var ok = try make(fd, 32, 32, 128);
    ok.prepare(backend, 1, "buffer", 3);
    try std.testing.expect(ok.import == .resource);
    ok.deinit(gpa);
    // RESOURCE_INFO is what bounds it, not the fd: a resource smaller than
    // the claim is refused even where the file is larger
    fake.info_size = 256;
    var short = try make(fd, 32, 32, 128);
    defer short.deinit(gpa);
    short.prepare(backend, 1, "buffer", 4);
    try std.testing.expectEqual(Buffer.Import.failed, short.import);
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try std.testing.expectEqual(@as(usize, 0), fake.bad_closes);
}
