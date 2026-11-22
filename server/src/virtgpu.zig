// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! virtio-gpu DRM, relay side (`--dmabuf virtgpu`): a client's dmabuf is
//! named by the virtio-gpu resource behind it instead of being read. Per
//! dmabuf wl_buffer, on the render node:
//!
//!   DRM_IOCTL_PRIME_FD_TO_HANDLE(plane 0 fd) → a GEM handle on our fd
//!   DRM_IOCTL_VIRTGPU_RESOURCE_INFO(handle)  → res_handle: the resource id
//!                                              COMMIT kind virtgpu carries
//!   DRM_IOCTL_GEM_CLOSE(handle)              once nothing names it any more
//!
//! The GEM handle keeps the object (and so the host resource) alive. A
//! handle is per DRM file and per object, NOT per import: importing the
//! same dmabuf again (two wl_buffers over one dmabuf, from any app) returns
//! the SAME handle, and the kernel does not count imports (drm.h, GEM_CLOSE:
//! "user-space needs to ensure DRM_IOCTL_GEM_CLOSE is performed once only").
//! So `Importer` counts references per handle — each buffer made from it,
//! plus each COMMIT naming it that the engine has not ACKed — relay-wide,
//! under one mutex that also covers the ioctls (an import racing the last
//! unref must not get a handle that is being closed).
//!
//! The node is open only while a handle is held: opened at the first
//! import, closed when the last handle goes (both under that mutex), opened
//! again at the next import. On a device without VIRTIO_GPU_F_CONTEXT_INIT
//! (unkernel's offers only VIRGL) the guest kernel creates a host virgl
//! context for a DRM file at its first PRIME import
//! (virtio_gpu_gem_object_open → CTX_CREATE, then CTX_ATTACH_RESOURCE per
//! import, CTX_DETACH at GEM_CLOSE) and destroys it only when the file
//! closes (driver_postclose). A node held open for the relay's life would
//! keep one renderer context alive in the page forever after the first GPU
//! app — and unkernel refuses snapshots while any context exists. Handles
//! are per file, so "no handle held" is exactly when closing loses nothing.
//! Every open checks DRM_IOCTL_VERSION's driver name ("virtio_gpu"): DRM
//! dispatches driver ioctls by number, so on another driver's node
//! RESOURCE_INFO (driver ioctl 5) would run that driver's ioctl 5.
//!
//! The ioctls go through `Device`, whose `fake` replaces the kernel for
//! tests: unit tests, the native harness, and the E2E tests' test-only
//! `--dmabuf virtgpu:@fake` (no /dev/dri in CI). Nothing here has run on a
//! real virtio-gpu node.
//!
//! Struct layouts and ioctl numbers: linux/include/uapi/drm/drm.h and
//! virtgpu_drm.h (identical in the unkernel kernel tree and in
//! /usr/include/drm); the encoding is asm-generic `_IOC` (x86_64, aarch64).

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;

/// struct drm_prime_handle (12 bytes)
pub const PrimeHandle = extern struct {
    /// out: the GEM handle
    handle: u32 = 0,
    /// handle → fd only
    flags: u32 = 0,
    /// in: the dmabuf fd
    fd: i32,
};

/// struct drm_gem_close (8 bytes)
pub const GemClose = extern struct {
    handle: u32,
    pad: u32 = 0,
};

/// struct drm_virtgpu_resource_info (16 bytes)
pub const ResourceInfo = extern struct {
    /// in: a GEM handle
    bo_handle: u32,
    /// out: the host resource id (virgl's)
    res_handle: u32 = 0,
    /// out: the object's size in bytes
    size: u32 = 0,
    /// out: VIRTGPU_BLOB_MEM_* for blob resources, else untouched (0)
    blob_mem: u32 = 0,
};

/// struct drm_version (64 bytes on 64-bit targets)
pub const Version = extern struct {
    version_major: i32 = 0,
    version_minor: i32 = 0,
    version_patchlevel: i32 = 0,
    /// in: the `name` buffer's size; out: the name's length
    name_len: usize,
    name: ?[*]u8,
    date_len: usize = 0,
    date: ?[*]u8 = null,
    desc_len: usize = 0,
    desc: ?[*]u8 = null,
};

fn ioc(dir: u32, nr: u8, size: u14) u32 {
    return dir << 30 | @as(u32, size) << 16 | @as(u32, 'd') << 8 | nr;
}
const ioc_write: u32 = 1;
const ioc_read: u32 = 2;
/// DRM_COMMAND_BASE: driver ioctls start here
const command_base: u8 = 0x40;

/// DRM_IOWR(0x00, struct drm_version)
pub const ioc_version: u32 = ioc(ioc_read | ioc_write, 0x00, @sizeOf(Version));
/// DRM_IOWR(0x2e, struct drm_prime_handle)
pub const ioc_prime_fd_to_handle: u32 = ioc(ioc_read | ioc_write, 0x2e, @sizeOf(PrimeHandle));
/// DRM_IOW(0x09, struct drm_gem_close)
pub const ioc_gem_close: u32 = ioc(ioc_write, 0x09, @sizeOf(GemClose));
/// DRM_IOWR(DRM_COMMAND_BASE + DRM_VIRTGPU_RESOURCE_INFO (0x05), struct drm_virtgpu_resource_info)
pub const ioc_resource_info: u32 = ioc(ioc_read | ioc_write, command_base + 0x05, @sizeOf(ResourceInfo));

/// The DRM driver a render node must be driven by.
pub const driver_name = "virtio_gpu";

/// The render node the relay names resources through: a path, opened only
/// while the importer holds handles (`fd` ≥ 0 then).
pub const Device = struct {
    /// the node (lives for the relay's life); unused with `fake`
    path: [*:0]const u8 = "",
    fd: i32 = -1,
    /// Test-only stand-in for the kernel (null: the real node).
    fake: ?*Fake = null,

    pub const OpenError = error{ NoDevice, OpenFailed, NotVirtioGpu };

    /// Why the last `open` failed, beyond its error: the errno of open(2)
    /// or of DRM_IOCTL_VERSION (SUCCESS: none — e.g. another driver's
    /// node, whose name is `driver`).
    pub const OpenDetail = struct {
        errno: linux.E = .SUCCESS,
        driver: [32]u8 = undefined,
        driver_len: usize = 0,
    };

    /// Startup validation: the node opens read-write and is a virtio_gpu
    /// one. Closed again (nothing is held until the first import). The
    /// details are logged here (warn, not err: the caller decides — startup
    /// fails on it); the importer's later opens log through its own limiter.
    pub fn check(self: Device) OpenError!void {
        var d = self;
        var detail: OpenDetail = .{};
        d.open(&detail) catch |err| {
            switch (err) {
                error.NotVirtioGpu => if (detail.errno != .SUCCESS)
                    std.log.warn("virtgpu: {s}: DRM_IOCTL_VERSION failed ({t}); not a DRM node?", .{ self.path, detail.errno })
                else
                    std.log.warn("virtgpu: {s}: DRM driver '{s}', not '{s}'", .{ self.path, detail.driver[0..detail.driver_len], driver_name }),
                else => std.log.warn("virtgpu: open {s}: {t} ({t})", .{ self.path, err, detail.errno }),
            }
            return err;
        };
        d.close();
    }

    /// Open the node (close-on-exec) and check its driver. Logs nothing:
    /// `detail` says why it failed.
    fn open(self: *Device, detail: *OpenDetail) OpenError!void {
        std.debug.assert(self.fd < 0);
        detail.* = .{};
        if (self.fake) |f| {
            self.fd = try f.open();
        } else {
            const rc = linux.open(self.path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => self.fd = @intCast(rc),
                .NOENT, .NODEV, .NXIO => |e| {
                    detail.errno = e;
                    return error.NoDevice;
                },
                else => |e| {
                    detail.errno = e;
                    return error.OpenFailed;
                },
            }
        }
        var name: [32]u8 = undefined;
        var v: Version = .{ .name_len = name.len, .name = &name };
        const e = self.ioctl(ioc_version, @intFromPtr(&v));
        const got = name[0..@min(v.name_len, name.len)];
        if (e != .SUCCESS or !std.mem.eql(u8, got, driver_name)) {
            detail.errno = e;
            @memcpy(detail.driver[0..got.len], got);
            detail.driver_len = got.len;
            self.close();
            return error.NotVirtioGpu;
        }
    }

    fn close(self: *Device) void {
        if (self.fd < 0) return;
        if (self.fake) |f| f.close() else _ = linux.close(self.fd);
        self.fd = -1;
    }

    fn ioctl(self: Device, req: u32, arg: usize) linux.E {
        while (true) {
            const rc = if (self.fake) |f| f.ioctl(req, arg) else linux.ioctl(self.fd, req, arg);
            switch (linux.errno(rc)) {
                .INTR, .AGAIN => continue,
                else => |e| return e,
            }
        }
    }
};

/// Relay-global: the device, every GEM handle the relay holds and who
/// holds it, and what was logged already. Thread-safe (app threads import,
/// commit and unref concurrently). The device is open exactly while `refs`
/// is not empty.
pub const Importer = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dev: Device,
    mutex: Io.Mutex = .init,
    /// GEM handle → references (buffers made from it + un-ACKed COMMITs)
    refs: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// `once` keys seen, per class: a client can mint refusal kinds at will
    /// (distinct unoffered formats), so refusals have their own table and
    /// can never crowd out the accepted-buffer lines (at most
    /// `accepted_kinds` of them exist: offered format × modifier pairs ×
    /// y_invert). Past its cap a class stops logging new kinds (saying so
    /// once) rather than repeating old ones; the volume stays bounded.
    logged: [std.meta.fields(LogClass).len][64]u64 = undefined,
    n_logged: [std.meta.fields(LogClass).len]usize = @splat(0),
    full_said: [std.meta.fields(LogClass).len]bool = @splat(false),
    /// open-failure limiter (see open_log_interval_ms): when the next line
    /// may go out (awake ms), failures since the last line, lines so far
    open_log_next_ms: i64 = std.math.minInt(i64),
    open_fails_unlogged: u32 = 0,
    open_log_lines: u32 = 0,

    pub const LogClass = enum { refused, accepted };

    pub const Imported = struct {
        gem: u32,
        resource: u32,
        /// the object's size (RESOURCE_INFO: the GEM object's, page-rounded)
        size: u32,
    };

    pub const Failure = struct {
        step: enum { open_device, prime_fd_to_handle, resource_info, no_resource, out_of_memory },
        errno: linux.E = .SUCCESS,
        /// .open_device: how (its errno is `errno`)
        open_error: ?Device.OpenError = null,
    };

    /// Device-open failures are the environment's (the node went away, its
    /// permissions) and can repeat at every import — a resize storm makes
    /// one per frame. So they are logged by the importer at most once per
    /// `open_log_interval_ms`, saying how many came since; never once-only
    /// (a node that comes back and goes again is news).
    pub const open_log_interval_ms = 60_000;

    pub const Result = union(enum) { ok: Imported, failed: Failure };

    pub fn init(io: Io, gpa: std.mem.Allocator, dev: Device) Importer {
        return .{ .io = io, .gpa = gpa, .dev = dev };
    }

    /// Only once no buffer or COMMIT holds a handle (tests: after the relay
    /// stopped). Closes what is left.
    pub fn deinit(self: *Importer) void {
        var it = self.refs.keyIterator();
        while (it.next()) |h| self.gemClose(h.*);
        self.refs.deinit(self.gpa);
        self.dev.close();
    }

    /// The device is open (a handle is held). For tests.
    pub fn deviceOpen(self: *Importer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.dev.fd >= 0;
    }

    /// Name a dmabuf: its GEM handle (one more reference on it) and its
    /// resource id. Opens the device if no handle is held.
    pub fn import(self: *Importer, dmabuf_fd: i32) Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.dev.fd < 0) {
            var detail: Device.OpenDetail = .{};
            self.dev.open(&detail) catch |err| {
                self.noteOpenFailure(err, detail);
                return .{ .failed = .{ .step = .open_device, .errno = detail.errno, .open_error = err } };
            };
        }
        // whatever fails below, a device holding no handle closes again
        defer if (self.refs.count() == 0) self.dev.close();
        var p: PrimeHandle = .{ .fd = dmabuf_fd };
        const e = self.dev.ioctl(ioc_prime_fd_to_handle, @intFromPtr(&p));
        if (e != .SUCCESS) return .{ .failed = .{ .step = .prime_fd_to_handle, .errno = e } };
        const gop = self.refs.getOrPut(self.gpa, p.handle) catch {
            if (!self.refs.contains(p.handle)) self.gemClose(p.handle);
            return .{ .failed = .{ .step = .out_of_memory } };
        };
        // a handle we did not hold yet is closed again on any failure below;
        // one we hold stays (another buffer's)
        const fresh = !gop.found_existing;
        if (fresh) gop.value_ptr.* = 0;
        var info: ResourceInfo = .{ .bo_handle = p.handle };
        const ie = self.dev.ioctl(ioc_resource_info, @intFromPtr(&info));
        if (ie != .SUCCESS or info.res_handle == 0) {
            if (fresh) {
                _ = self.refs.remove(p.handle);
                self.gemClose(p.handle);
            }
            return .{ .failed = if (ie != .SUCCESS) .{ .step = .resource_info, .errno = ie } else .{ .step = .no_resource } };
        }
        gop.value_ptr.* += 1;
        return .{ .ok = .{ .gem = p.handle, .resource = info.res_handle, .size = info.size } };
    }

    /// One more holder of `gem` (a COMMIT naming it went out).
    pub fn ref(self: *Importer, gem: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.refs.getPtr(gem) orelse unreachable; // only held handles are named
        r.* += 1;
    }

    /// One holder fewer; the last one closes the handle.
    pub fn unref(self: *Importer, gem: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.refs.getPtr(gem) orelse unreachable;
        r.* -= 1;
        if (r.* > 0) return;
        _ = self.refs.remove(gem);
        self.gemClose(gem);
        // no handle left: closing the file loses nothing and ends the
        // guest's host context for it (see the top of this file)
        if (self.refs.count() == 0) self.dev.close();
    }

    /// GEM handles held now.
    pub fn live(self: *Importer) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.refs.count();
    }

    /// References on `gem` now (0: not held).
    pub fn refsOf(self: *Importer, gem: u32) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.refs.get(gem) orelse 0;
    }

    /// True the first time `key` is seen in `class`: log a kind of event
    /// once per relay run, not once per frame.
    pub fn once(self: *Importer, class: LogClass, key: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const c = @intFromEnum(class);
        const seen = self.logged[c][0..self.n_logged[c]];
        for (seen) |k| if (k == key) return false;
        if (seen.len == self.logged[c].len) {
            if (!self.full_said[c])
                std.log.warn("virtgpu: {d} kinds of {t} buffers logged; further new kinds are not", .{ seen.len, class });
            self.full_said[c] = true;
            return false;
        }
        self.logged[c][seen.len] = key;
        self.n_logged[c] += 1;
        return true;
    }

    /// A device open failed (mutex held): logged now if the limiter allows.
    fn noteOpenFailure(self: *Importer, err: Device.OpenError, detail: Device.OpenDetail) void {
        self.open_fails_unlogged += 1;
        const now = Io.Clock.now(.awake, self.io).toMilliseconds();
        if (now < self.open_log_next_ms) return;
        const since = self.open_fails_unlogged - 1;
        self.open_fails_unlogged = 0;
        self.open_log_next_ms = now + open_log_interval_ms;
        self.open_log_lines += 1;
        const path = if (self.dev.fake != null) "(fake)" else std.mem.span(self.dev.path);
        if (err == error.NotVirtioGpu and detail.errno == .SUCCESS) {
            std.log.warn("virtgpu: {s}: DRM driver '{s}', not '{s}'; GPU buffers are not shown ({d} more failures since the last line)", .{ path, detail.driver[0..detail.driver_len], driver_name, since });
        } else {
            std.log.warn("virtgpu: cannot open {s}: {t} ({t}); GPU buffers are not shown ({d} more failures since the last line)", .{ path, err, detail.errno, since });
        }
    }

    fn gemClose(self: *Importer, gem: u32) void {
        var c: GemClose = .{ .handle = gem };
        const e = self.dev.ioctl(ioc_gem_close, @intFromPtr(&c));
        if (e != .SUCCESS) std.log.warn("virtgpu: GEM_CLOSE {d}: {t}", .{ gem, e });
    }
};

/// A stand-in for a virtio-gpu render node, as far as the relay can tell:
/// any regular file (a memfd) counts as a dmabuf; PRIME_FD_TO_HANDLE gives
/// one handle per underlying file (same st_dev/st_ino → the same handle
/// while it is open, like the kernel's per-object lookup), holding its own
/// reference to the file the way a GEM handle holds the object; each object
/// gets a fresh resource id; GEM_CLOSE of a handle not open is an error
/// (counted: a double close). The node itself is opened and closed like a
/// file: ioctls while it is closed fail (EBADF, counted), and closing it
/// with handles open drops them (as the kernel does) and is counted too.
/// `resolve` is the host's view: the file behind a resource id, for test
/// engines that read what a COMMIT names.
///
/// TEST-ONLY. Selected by unit tests and the harness directly, and by the
/// undocumented `--dmabuf virtgpu:@fake` that the E2E tests pass (never in
/// the usage text: nothing real can allocate on it).
pub const Fake = struct {
    lock: std.atomic.Value(bool) = .init(false),
    objects: [max]Object = @splat(.{}),
    next_handle: u32 = 1,
    next_resource: u32 = 1,
    /// the errno the next PRIME_FD_TO_HANDLE / RESOURCE_INFO fails with
    fail_import: linux.E = .SUCCESS,
    fail_info: linux.E = .SUCCESS,
    /// what DRM_IOCTL_VERSION names (another driver's node: anything else)
    driver: []const u8 = driver_name,
    /// RESOURCE_INFO size override (null: the file's size, page-rounded)
    info_size: ?u32 = null,
    /// GEM_CLOSE calls that closed a handle, and ones naming no open handle
    closes: usize = 0,
    bad_closes: usize = 0,
    /// the node: open now; opens and closes so far; ioctls on a closed
    /// node; closes with handles still open (each a relay bug)
    is_open: bool = false,
    opens: usize = 0,
    dev_closes: usize = 0,
    closed_ioctls: usize = 0,
    closed_with_handles: usize = 0,
    /// the next open fails (the node vanished)
    fail_open: bool = false,

    const max = 64;
    const Object = struct { handle: u32 = 0, resource: u32 = 0, dev: u64 = 0, ino: u64 = 0, fd: i32 = -1, size: u64 = 0 };

    fn acquire(self: *Fake) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn release(self: *Fake) void {
        self.lock.store(false, .release);
    }

    fn err(e: linux.E) usize {
        return @bitCast(-@as(isize, @intFromEnum(e)));
    }

    fn find(self: *Fake, handle: u32) ?*Object {
        if (handle == 0) return null;
        for (&self.objects) |*o| if (o.handle == handle) return o;
        return null;
    }

    /// open(2) of the node: a dummy fd number (never used as one).
    pub fn open(self: *Fake) Device.OpenError!i32 {
        self.acquire();
        defer self.release();
        if (self.fail_open) {
            self.fail_open = false;
            return error.NoDevice;
        }
        std.debug.assert(!self.is_open); // one file at a time, like the importer
        self.is_open = true;
        self.opens += 1;
        return 1000;
    }

    /// close(2) of the node: its handles go with it.
    pub fn close(self: *Fake) void {
        self.acquire();
        defer self.release();
        self.is_open = false;
        self.dev_closes += 1;
        var held = false;
        for (&self.objects) |*o| if (o.handle != 0) {
            held = true;
            _ = linux.close(o.fd);
            o.* = .{};
        };
        if (held) self.closed_with_handles += 1;
    }

    pub fn ioctl(self: *Fake, req: u32, arg: usize) usize {
        self.acquire();
        defer self.release();
        if (!self.is_open) {
            self.closed_ioctls += 1;
            return err(.BADF);
        }
        switch (req) {
            ioc_version => {
                const v: *Version = @ptrFromInt(arg);
                const n = @min(v.name_len, self.driver.len);
                if (v.name) |name| @memcpy(name[0..n], self.driver[0..n]);
                v.name_len = self.driver.len;
                return 0;
            },
            ioc_prime_fd_to_handle => {
                const p: *PrimeHandle = @ptrFromInt(arg);
                if (self.fail_import != .SUCCESS) {
                    defer self.fail_import = .SUCCESS;
                    return err(self.fail_import);
                }
                var stx: linux.Statx = undefined;
                if (linux.errno(linux.statx(p.fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true, .SIZE = true }, &stx)) != .SUCCESS) return err(.BADF);
                if (!linux.S.ISREG(stx.mode)) return err(.INVAL); // dma_buf_get: not a dmabuf
                const dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
                for (self.objects) |o| if (o.handle != 0 and o.dev == dev and o.ino == stx.ino) {
                    p.handle = o.handle;
                    return 0;
                };
                const slot = for (&self.objects) |*o| {
                    if (o.handle == 0) break o;
                } else return err(.NOMEM);
                const rc = linux.fcntl(p.fd, linux.F.DUPFD_CLOEXEC, 0);
                if (linux.errno(rc) != .SUCCESS) return err(.NOMEM);
                slot.* = .{ .handle = self.next_handle, .resource = self.next_resource, .dev = dev, .ino = stx.ino, .fd = @intCast(rc), .size = stx.size };
                self.next_handle += 1;
                self.next_resource += 1;
                p.handle = slot.handle;
                return 0;
            },
            ioc_resource_info => {
                const info: *ResourceInfo = @ptrFromInt(arg);
                if (self.fail_info != .SUCCESS) {
                    defer self.fail_info = .SUCCESS;
                    return err(self.fail_info);
                }
                const o = self.find(info.bo_handle) orelse return err(.NOENT);
                info.res_handle = o.resource;
                // the kernel's GEM size: what Mesa asked for, page-rounded
                info.size = self.info_size orelse @truncate(std.mem.alignForward(u64, o.size, 4096));
                return 0;
            },
            ioc_gem_close => {
                const c: *const GemClose = @ptrFromInt(arg);
                const o = self.find(c.handle) orelse {
                    self.bad_closes += 1;
                    return err(.INVAL);
                };
                _ = linux.close(o.fd);
                o.* = .{};
                self.closes += 1;
                return 0;
            },
            else => return err(.NOTTY),
        }
    }

    /// Handles open now.
    pub fn live(self: *Fake) usize {
        self.acquire();
        defer self.release();
        var n: usize = 0;
        for (self.objects) |o| n += @intFromBool(o.handle != 0);
        return n;
    }

    /// The file behind resource `id` while its handle is open (a new fd the
    /// caller closes), as a host renderer would find the resource's pixels.
    pub fn resolve(self: *Fake, id: u32) ?i32 {
        self.acquire();
        defer self.release();
        for (self.objects) |o| if (o.handle != 0 and o.resource == id) {
            const rc = linux.fcntl(o.fd, linux.F.DUPFD_CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return null;
            return @intCast(rc);
        };
        return null;
    }

    /// Close every handle still open (a test's teardown).
    pub fn deinit(self: *Fake) void {
        self.is_open = false;
        for (&self.objects) |*o| if (o.handle != 0) {
            _ = linux.close(o.fd);
            o.* = .{};
        };
    }
};

test "virtgpu UAPI: ioctl numbers and struct layouts match drm.h / virtgpu_drm.h" {
    // by hand from _IOC: dir << 30 | size << 16 | 'd' << 8 | nr
    try std.testing.expectEqual(@as(u32, 0xC00C642E), ioc_prime_fd_to_handle);
    try std.testing.expectEqual(@as(u32, 0x40086409), ioc_gem_close);
    try std.testing.expectEqual(@as(u32, 0xC0106445), ioc_resource_info);
    // ...and std's asm-generic encoding agrees (on this host's arch)
    try std.testing.expectEqual(linux.IOCTL.IOWR('d', 0x2e, PrimeHandle), ioc_prime_fd_to_handle);
    try std.testing.expectEqual(linux.IOCTL.IOW('d', 0x09, GemClose), ioc_gem_close);
    try std.testing.expectEqual(linux.IOCTL.IOWR('d', 0x45, ResourceInfo), ioc_resource_info);
    try std.testing.expectEqual(linux.IOCTL.IOWR('d', 0x00, Version), ioc_version);
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(u32, 0xC0406400), ioc_version);
        try std.testing.expectEqual(@as(usize, 64), @sizeOf(Version));
        try std.testing.expectEqual(@as(usize, 16), @offsetOf(Version, "name_len"));
        try std.testing.expectEqual(@as(usize, 24), @offsetOf(Version, "name"));
    }
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(PrimeHandle));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(PrimeHandle, "fd"));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(GemClose));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ResourceInfo));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(ResourceInfo, "res_handle"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ResourceInfo, "size"));
}

test "importer: one GEM handle per object, counted; closed once at the last unref; failures close only fresh handles" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    defer fake.deinit();
    var imp: Importer = .init(threaded.io(), gpa, .{ .fd = -1, .fake = &fake });
    defer imp.deinit();

    const a: i32 = @intCast(linux.memfd_create("virtgpu-a", linux.MFD.CLOEXEC));
    defer _ = linux.close(a);
    const b: i32 = @intCast(linux.memfd_create("virtgpu-b", linux.MFD.CLOEXEC));
    defer _ = linux.close(b);
    const a2: i32 = @intCast(linux.fcntl(a, linux.F.DUPFD_CLOEXEC, 0)); // another fd, same object
    defer _ = linux.close(a2);

    const ia = imp.import(a).ok;
    const ia2 = imp.import(a2).ok;
    const ib = imp.import(b).ok;
    try std.testing.expectEqual(ia.gem, ia2.gem);
    try std.testing.expectEqual(ia.resource, ia2.resource);
    try std.testing.expect(ia.gem != ib.gem and ia.resource != ib.resource);
    try std.testing.expectEqual(@as(u32, 2), imp.refsOf(ia.gem));
    imp.ref(ia.gem); // a COMMIT in flight
    imp.unref(ia.gem);
    imp.unref(ia.gem);
    try std.testing.expectEqual(@as(usize, 2), fake.live()); // the COMMIT still holds it
    imp.unref(ia.gem);
    try std.testing.expectEqual(@as(usize, 1), fake.live());
    try std.testing.expectEqual(@as(usize, 0), fake.bad_closes);

    // a pipe is no dmabuf; RESOURCE_INFO failing on a fresh handle closes it,
    // on a held one leaves it
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }));
    defer for (pipe_fds) |fd| {
        _ = linux.close(fd);
    };
    try std.testing.expectEqual(linux.E.INVAL, imp.import(pipe_fds[0]).failed.errno);
    fake.fail_info = .NOENT;
    try std.testing.expect(imp.import(a).failed.step == .resource_info);
    try std.testing.expectEqual(@as(usize, 1), fake.live());
    fake.fail_info = .NOENT;
    try std.testing.expect(imp.import(b).failed.step == .resource_info);
    try std.testing.expectEqual(@as(u32, 1), imp.refsOf(ib.gem));
    imp.unref(ib.gem);
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try std.testing.expectEqual(@as(usize, 0), imp.live());
    try std.testing.expectEqual(@as(usize, 0), fake.bad_closes);

    try std.testing.expect(imp.once(.accepted, 7));
    try std.testing.expect(!imp.once(.accepted, 7));
}

test "importer: the node is open only while a handle is held — opened at the first import, closed with the last handle, reopened after" {
    std.testing.log_level = .err; // open failures warn
    defer std.testing.log_level = .warn;
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    defer fake.deinit();
    var imp: Importer = .init(threaded.io(), gpa, .{ .fake = &fake });
    defer imp.deinit();
    try std.testing.expect(!imp.deviceOpen() and fake.opens == 0); // nothing held at start

    const a: i32 = @intCast(linux.memfd_create("virtgpu-lazy-a", linux.MFD.CLOEXEC));
    defer _ = linux.close(a);
    const b: i32 = @intCast(linux.memfd_create("virtgpu-lazy-b", linux.MFD.CLOEXEC));
    defer _ = linux.close(b);
    const ia = imp.import(a).ok;
    const ib = imp.import(b).ok;
    try std.testing.expect(imp.deviceOpen());
    try std.testing.expectEqual(@as(usize, 1), fake.opens);
    imp.ref(ia.gem); // a COMMIT in flight
    imp.unref(ia.gem);
    imp.unref(ib.gem);
    try std.testing.expect(imp.deviceOpen()); // the COMMIT still holds a
    imp.unref(ia.gem);
    try std.testing.expect(!imp.deviceOpen());
    try std.testing.expectEqual(@as(usize, 1), fake.dev_closes);

    // a failed import with nothing held leaves the node closed again
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }));
    defer for (pipe_fds) |fd| {
        _ = linux.close(fd);
    };
    try std.testing.expect(imp.import(pipe_fds[0]) == .failed);
    try std.testing.expect(!imp.deviceOpen());
    try std.testing.expectEqual(@as(usize, 2), fake.opens);
    // the node vanished: the import fails at its open
    fake.fail_open = true;
    try std.testing.expect(imp.import(a).failed.step == .open_device);
    try std.testing.expect(!imp.deviceOpen());

    // reopened for the next buffer
    const ia2 = imp.import(a).ok;
    try std.testing.expectEqual(@as(usize, 3), fake.opens);
    imp.unref(ia2.gem);
    try std.testing.expect(!imp.deviceOpen());
    try std.testing.expectEqual(fake.opens, fake.dev_closes);
    try std.testing.expectEqual(@as(usize, 0), fake.closed_with_handles); // every handle went first
    try std.testing.expectEqual(@as(usize, 0), fake.closed_ioctls);
    try std.testing.expectEqual(@as(usize, 0), fake.bad_closes);
}

test "importer: a device-open failure carries its reason and errno, and is logged at most once per interval with a count" {
    std.testing.log_level = .err; // open failures warn
    defer std.testing.log_level = .warn;
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    defer fake.deinit();
    var imp: Importer = .init(threaded.io(), gpa, .{ .fake = &fake });
    defer imp.deinit();
    const a: i32 = @intCast(linux.memfd_create("virtgpu-openfail", linux.MFD.CLOEXEC));
    defer _ = linux.close(a);
    // a storm of imports on a vanished node: every one fails, one line
    for (0..5) |_| {
        fake.fail_open = true;
        const f = imp.import(a).failed;
        try std.testing.expect(f.step == .open_device);
        try std.testing.expectEqual(@as(?Device.OpenError, error.NoDevice), f.open_error);
    }
    try std.testing.expectEqual(@as(u32, 1), imp.open_log_lines);
    try std.testing.expectEqual(@as(u32, 4), imp.open_fails_unlogged);
    // another driver's node: its own reason (no errno); the next line once
    // the interval is over, counting what came between
    fake.driver = "i915";
    const f = imp.import(a).failed;
    try std.testing.expectEqual(@as(?Device.OpenError, error.NotVirtioGpu), f.open_error);
    try std.testing.expectEqual(linux.E.SUCCESS, f.errno);
    try std.testing.expectEqual(@as(u32, 1), imp.open_log_lines);
    imp.open_log_next_ms = std.math.minInt(i64);
    _ = imp.import(a).failed;
    try std.testing.expectEqual(@as(u32, 2), imp.open_log_lines);
    try std.testing.expectEqual(@as(u32, 0), imp.open_fails_unlogged);
    fake.driver = driver_name;
    const ok = imp.import(a).ok;
    imp.unref(ok.gem);
}

test "device check: only a virtio_gpu node passes (DRM_IOCTL_VERSION), and it is closed again" {
    std.testing.log_level = .err; // the mismatch is a warning
    defer std.testing.log_level = .warn;
    var fake: Fake = .{ .driver = "i915" };
    defer fake.deinit();
    const dev: Device = .{ .fake = &fake };
    try std.testing.expectError(error.NotVirtioGpu, dev.check());
    fake.driver = "virtio_gpu_but_longer";
    try std.testing.expectError(error.NotVirtioGpu, dev.check());
    fake.driver = driver_name;
    try dev.check();
    try std.testing.expectEqual(@as(usize, 3), fake.opens);
    try std.testing.expectEqual(@as(usize, 3), fake.dev_closes);
    try std.testing.expect(!fake.is_open);

    // ...and at each lazy open: another driver's node never gets RESOURCE_INFO
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var imp: Importer = .init(threaded.io(), gpa, dev);
    defer imp.deinit();
    const a: i32 = @intCast(linux.memfd_create("virtgpu-drv", linux.MFD.CLOEXEC));
    defer _ = linux.close(a);
    fake.driver = "amdgpu";
    try std.testing.expect(imp.import(a).failed.step == .open_device);
    try std.testing.expectEqual(@as(usize, 0), fake.live());
    try std.testing.expect(!fake.is_open);
}

test "once: refusal kinds a client mints at will never use up the accepted-buffer lines; volume stays bounded" {
    std.testing.log_level = .err; // the "no more kinds" line is a warning
    defer std.testing.log_level = .warn;
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    var imp: Importer = .init(threaded.io(), std.testing.allocator, .{ .fake = &fake });
    defer imp.deinit();
    var logged: usize = 0;
    for (0..1000) |k| logged += @intFromBool(imp.once(.refused, k));
    try std.testing.expectEqual(@as(usize, 64), logged);
    try std.testing.expect(imp.full_said[@intFromEnum(Importer.LogClass.refused)]);
    try std.testing.expect(!imp.once(.refused, 3)); // seen
    try std.testing.expect(imp.once(.accepted, 3)); // its own table
    try std.testing.expect(!imp.once(.accepted, 3));
}
