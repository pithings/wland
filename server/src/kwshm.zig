// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! unkernel's /dev/kwshm guest UAPI (include/uapi/linux/kwshm.h in the
//! unkernel kernel tree): export a page-aligned range of a shmem file (a
//! memfd, a /dev/shm file) so the JavaScript host can read its pages in
//! place. The relay's `kwshm` buffer handles are these exports
//! (protocol/STREAM.md, Handle kinds).
//!
//! An export pins and allocates every page of its range, lives until
//! KWSHM_IOC_RELEASE or until the /dev/kwshm file that made it is closed,
//! and holds its own reference to the file (the exported fd may be closed).
//! Limits: 4096 live exports (ENOSPC), half of guest RAM pinned (ENOMEM).
//! `F_SEAL_WRITE` on an exported file fails with EBUSY.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const dev_path = "/dev/kwshm";

/// struct kwshm_export flags: the host may only read.
pub const export_rdonly: u32 = 1 << 0;

/// struct kwshm_export (40 bytes, no padding on any 64-bit-aligned ABI).
pub const Export = extern struct {
    /// in: a shmem file, open for reading
    fd: i32,
    /// in: export_rdonly
    flags: u32,
    /// in: start in the file, page aligned
    offset: u64,
    /// in: bytes from `offset`, within the file's current size (0 = to the
    /// end, following the file's size on host refreshes — never used here)
    length: u64,
    /// out: bytes exported
    size: u64 = 0,
    /// out: the export's id, > 0
    id: u32 = 0,
    /// out: pages held
    pages: u32 = 0,
};

/// asm-generic `_IOC(dir, type, nr, size)`, the encoding x86_64 and aarch64
/// use (mips, powerpc, sparc and alpha differ; the relay targets neither).
fn ioc(dir: u32, io_type: u8, nr: u8, size: u14) u32 {
    return dir << 30 | @as(u32, size) << 16 | @as(u32, io_type) << 8 | nr;
}
const ioc_write: u32 = 1;
const ioc_read: u32 = 2;
const magic: u8 = 0xBB;

/// _IOWR(0xBB, 0x00, struct kwshm_export)
pub const ioc_export: u32 = ioc(ioc_read | ioc_write, magic, 0x00, @sizeOf(Export));
/// _IOW(0xBB, 0x01, __u32)
pub const ioc_release: u32 = ioc(ioc_write, magic, 0x01, @sizeOf(u32));

/// Test builds talk to `fake` instead (no /dev/kwshm on a dev box); only
/// the syscall is swapped, so everything above it is what ships.
const ioctl = if (builtin.is_test) fake.ioctl else linux.ioctl;

pub const OpenError = error{ NoKwshmDevice, OpenFailed };

/// Open /dev/kwshm read-write (close-on-exec). Keep it open: closing it
/// releases every export it made.
pub fn open() OpenError!i32 {
    const rc = linux.open(dev_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT, .NODEV, .NXIO => error.NoKwshmDevice,
        else => |e| {
            std.log.err("open {s}: {t}", .{ dev_path, e });
            return error.OpenFailed;
        },
    };
}

pub const ExportError = error{
    /// ENOSPC: 4096 live exports
    TooManyExports,
    /// ENOMEM: the half-of-RAM pin limit (or the kernel is out of memory)
    PinLimit,
    /// EINVAL: range outside the file, unaligned offset, or not a shmem file
    InvalidRange,
    /// anything else (logged)
    ExportFailed,
};

/// KWSHM_IOC_EXPORT a read-only range `[offset, offset + length)` of `fd`.
pub fn exportRange(dev: i32, fd: i32, offset: u64, length: u64) ExportError!Export {
    var e: Export = .{ .fd = fd, .flags = export_rdonly, .offset = offset, .length = length };
    while (true) {
        const rc = ioctl(dev, ioc_export, @intFromPtr(&e));
        switch (linux.errno(rc)) {
            .SUCCESS => return e,
            .INTR => continue,
            .NOSPC => return error.TooManyExports,
            .NOMEM => return error.PinLimit,
            .INVAL => return error.InvalidRange,
            else => |err| {
                std.log.err("kwshm export: {t}", .{err});
                return error.ExportFailed;
            },
        }
    }
}

/// KWSHM_IOC_RELEASE: the host's view of the export ends now.
pub fn release(dev: i32, id: u32) void {
    var arg: u32 = id;
    const rc = ioctl(dev, ioc_release, @intFromPtr(&arg));
    if (linux.errno(rc) != .SUCCESS) std.log.err("kwshm release {d}: {t}", .{ id, linux.errno(rc) });
}

/// An in-process /dev/kwshm for tests: implements KWSHM_IOC_EXPORT/RELEASE
/// the way the driver does as far as the relay can tell (the struct as the
/// kernel reads it, page-aligned offset, range within the file's size, its
/// own reference to the file) and lets the harness engine resolve ids as
/// the host page would. Only reachable from test builds (`ioctl` above);
/// the device fd passed in is ignored. A spinlock, since relay app threads
/// export while the test thread resolves.
pub const fake = struct {
    const max = 64;
    const Slot = struct { id: u32 = 0, fd: i32 = -1, offset: u64 = 0, size: u64 = 0 };

    var lock: std.atomic.Value(bool) = .init(false);
    var slots: [max]Slot = @splat(.{});
    var next_id: u32 = 1;
    /// the errno the next EXPORT fails with (then cleared)
    var fail_next: linux.E = .SUCCESS;

    fn acquire() void {
        while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock() void {
        lock.store(false, .release);
    }

    fn err(e: linux.E) usize {
        return @bitCast(-@as(isize, @intFromEnum(e)));
    }

    fn ioctl(dev: i32, req: u32, arg: usize) usize {
        _ = dev;
        acquire();
        defer unlock();
        switch (req) {
            ioc_export => {
                const e: *Export = @ptrFromInt(arg);
                if (fail_next != .SUCCESS) {
                    defer fail_next = .SUCCESS;
                    return err(fail_next);
                }
                const page = std.heap.pageSize();
                if (e.flags != export_rdonly or e.offset % page != 0 or e.length == 0) return err(.INVAL);
                var stx: linux.Statx = undefined;
                if (linux.errno(linux.statx(e.fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx)) != .SUCCESS) return err(.BADF);
                if (e.offset + e.length > stx.size) return err(.INVAL);
                const slot = for (&slots) |*sl| {
                    if (sl.id == 0) break sl;
                } else return err(.NOSPC);
                const rc = linux.fcntl(e.fd, linux.F.DUPFD_CLOEXEC, 0);
                if (linux.errno(rc) != .SUCCESS) return err(.NOMEM);
                slot.* = .{ .id = next_id, .fd = @intCast(rc), .offset = e.offset, .size = e.length };
                next_id += 1;
                e.size = e.length;
                e.id = slot.id;
                e.pages = @intCast((e.length + page - 1) / page);
                return 0;
            },
            ioc_release => {
                const id: *const u32 = @ptrFromInt(arg);
                for (&slots) |*sl| if (sl.id == id.* and id.* != 0) {
                    _ = linux.close(sl.fd);
                    sl.* = .{};
                    return 0;
                };
                return err(.INVAL);
            },
            else => return err(.NOTTY),
        }
    }

    /// Make the next EXPORT fail with `e`.
    pub fn failNext(e: linux.E) void {
        acquire();
        defer unlock();
        fail_next = e;
    }

    /// Exports alive now.
    pub fn live() usize {
        acquire();
        defer unlock();
        var n: usize = 0;
        for (slots) |sl| n += @intFromBool(sl.id != 0);
        return n;
    }

    /// The host's view of export `id`: a new fd of the exported file (the
    /// caller closes it) and the export's range in it; null once released.
    pub fn resolve(id: u32) ?struct { fd: i32, offset: u64, size: u64 } {
        acquire();
        defer unlock();
        for (slots) |sl| if (sl.id == id and id != 0) {
            const rc = linux.fcntl(sl.fd, linux.F.DUPFD_CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return null;
            return .{ .fd = @intCast(rc), .offset = sl.offset, .size = sl.size };
        };
        return null;
    }
};

test "kwshm UAPI: ioctl numbers and struct layout match include/uapi/linux/kwshm.h" {
    // values STREAM.md documents, computed by hand from _IOC
    try std.testing.expectEqual(@as(u32, 0xC028BB00), ioc_export);
    try std.testing.expectEqual(@as(u32, 0x4004BB01), ioc_release);
    // ...and std's own asm-generic encoding agrees (on this host's arch)
    try std.testing.expectEqual(linux.IOCTL.IOWR(magic, 0x00, Export), ioc_export);
    try std.testing.expectEqual(linux.IOCTL.IOW(magic, 0x01, u32), ioc_release);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Export));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Export, "fd"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Export, "flags"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Export, "offset"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Export, "length"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Export, "size"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Export, "id"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Export, "pages"));
}

test "kwshm: export/release through the fake device, errno mapping" {
    const page = std.heap.pageSize();
    const mfd: i32 = @intCast(linux.memfd_create("kwshm-test", linux.MFD.CLOEXEC));
    defer _ = linux.close(mfd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(mfd, @intCast(3 * page))));
    const base = fake.live();

    const e = try exportRange(-1, mfd, page, 2 * page);
    try std.testing.expect(e.id > 0);
    try std.testing.expectEqual(@as(u64, 2 * page), e.size);
    try std.testing.expectEqual(@as(u32, 2), e.pages);
    try std.testing.expectEqual(base + 1, fake.live());
    const r = fake.resolve(e.id).?;
    _ = linux.close(r.fd);
    try std.testing.expectEqual(@as(u64, page), r.offset);

    try std.testing.expectError(error.InvalidRange, exportRange(-1, mfd, page, 3 * page)); // past EOF
    try std.testing.expectError(error.InvalidRange, exportRange(-1, mfd, 1, page)); // unaligned
    fake.failNext(.NOSPC);
    try std.testing.expectError(error.TooManyExports, exportRange(-1, mfd, 0, page));
    fake.failNext(.NOMEM);
    try std.testing.expectError(error.PinLimit, exportRange(-1, mfd, 0, page));

    release(-1, e.id);
    try std.testing.expectEqual(base, fake.live());
    try std.testing.expect(fake.resolve(e.id) == null);
}

comptime {
    // the guest target: pin the layout at compile time too
    std.debug.assert(@sizeOf(Export) == 40);
    std.debug.assert(ioc_export == 0xC028BB00 and ioc_release == 0x4004BB01);
}
