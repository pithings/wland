// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! fd + shm primitives: recvmsg with SCM_RIGHTS fd capture, sendmsg with an
//! fd, memfds, pool storage, damage accumulation.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const FdQueue = struct {
    fds: [16]posix.fd_t = undefined,
    len: usize = 0,

    pub fn pop(self: *FdQueue) ?posix.fd_t {
        if (self.len == 0) return null;
        const fd = self.fds[0];
        std.mem.copyForwards(posix.fd_t, self.fds[0 .. self.len - 1], self.fds[1..self.len]);
        self.len -= 1;
        return fd;
    }

    fn push(self: *FdQueue, fd: posix.fd_t) void {
        if (self.len == self.fds.len) {
            std.log.err("fd queue overflow, dropping fd", .{});
            _ = linux.close(fd);
            return;
        }
        self.fds[self.len] = fd;
        self.len += 1;
    }

    pub fn drain(self: *FdQueue) void {
        for (self.fds[0..self.len]) |fd| _ = linux.close(fd);
        self.len = 0;
    }
};

const cmsg_align = @sizeOf(usize);

fn cmsgAlign(len: usize) usize {
    return (len + cmsg_align - 1) & ~@as(usize, cmsg_align - 1);
}

const cmsg_hdr_space = cmsgAlign(@sizeOf(linux.cmsghdr));

/// Blocking read that also captures any SCM_RIGHTS fds riding with the bytes.
/// Returns 0 on orderly shutdown.
pub fn recvWithFds(fd: posix.fd_t, buf: []u8, fds: *FdQueue) !usize {
    var iov = [1]posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cmsg_buf: [256]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    while (true) {
        var msg: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_buf.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(fd, &msg, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                collectFds(&msg, &cmsg_buf, fds);
                return rc;
            },
            .INTR => continue,
            .CONNRESET => return 0,
            else => |e| {
                std.log.err("recvmsg failed: {t}", .{e});
                return error.ReadFailed;
            },
        }
    }
}

fn collectFds(msg: *const linux.msghdr, cmsg_buf: []align(@alignOf(linux.cmsghdr)) u8, fds: *FdQueue) void {
    var off: usize = 0;
    while (off + @sizeOf(linux.cmsghdr) <= msg.controllen) {
        const cmsg: *const linux.cmsghdr = @ptrCast(@alignCast(cmsg_buf.ptr + off));
        if (cmsg.len < @sizeOf(linux.cmsghdr)) break;
        if (cmsg.level == linux.SOL.SOCKET and cmsg.type == linux.SCM.RIGHTS) {
            const data = cmsg_buf[off + cmsg_hdr_space .. off + cmsg.len];
            var i: usize = 0;
            while (i + @sizeOf(posix.fd_t) <= data.len) : (i += @sizeOf(posix.fd_t)) {
                fds.push(std.mem.bytesToValue(posix.fd_t, data[i..][0..@sizeOf(posix.fd_t)]));
            }
        }
        off += cmsgAlign(cmsg.len);
    }
}

/// Create a sealed memfd holding `bytes` + a terminating NUL (xkb keymap
/// convention: advertised size includes the NUL).
pub fn createMemfd(name: [*:0]const u8, bytes: []const u8) !posix.fd_t {
    const rc = linux.memfd_create(name, linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.MemfdFailed;
    const fd: posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const w = linux.write(fd, bytes.ptr + written, bytes.len - written);
        if (linux.errno(w) != .SUCCESS) return error.WriteFailed;
        written += w;
    }
    const nul = [1]u8{0};
    if (linux.errno(linux.write(fd, &nul, 1)) != .SUCCESS) return error.WriteFailed;
    return fd;
}

/// Blocking sendmsg shipping `bytes` with one SCM_RIGHTS fd attached.
pub fn sendWithFd(sock: posix.fd_t, bytes: []const u8, fd: posix.fd_t) !void {
    var sent: usize = 0;
    var cmsg_buf: [cmsg_hdr_space + 8]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const cmsg: *linux.cmsghdr = @ptrCast(&cmsg_buf);
    cmsg.* = .{ .len = cmsg_hdr_space + @sizeOf(posix.fd_t), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
    @memcpy(cmsg_buf[cmsg_hdr_space..][0..@sizeOf(posix.fd_t)], std.mem.asBytes(&fd));

    while (sent < bytes.len) {
        var iov = [1]posix.iovec_const{.{ .base = bytes.ptr + sent, .len = bytes.len - sent }};
        var msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            // attach the fd only to the first byte batch
            .control = if (sent == 0) &cmsg_buf else null,
            .controllen = if (sent == 0) cmsg_buf.len else 0,
            .flags = 0,
        };
        const rc = linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => sent += rc,
            .INTR, .AGAIN => continue,
            else => |e| {
                std.log.err("sendmsg failed: {t}", .{e});
                return error.WriteFailed;
            },
        }
    }
}

/// A wl_shm_pool's storage: the client's fd (owned) and its size. Whether
/// the relay maps it is the buffer backend's business (the copy backend
/// does, read-only; a handle backend would export the fd instead).
///
/// `size` is what the client CLAIMS (create_pool, resize). Nothing makes the
/// file that big, or keeps it so: a read of a mapped page past the file's
/// end raises SIGBUS. So every read of `data` runs between `beginAccess` and
/// `endAccess`, which turn such a fault into "this read failed" (zero pages
/// in place of the missing ones) instead of the death of the relay and every
/// app it serves — libwayland-server's wl_shm_buffer_begin_access does the
/// same. No fstat: a client can truncate between any check and the read.
pub const Pool = struct {
    fd: posix.fd_t,
    size: usize,
    /// 1 for the wl_shm_pool object + 1 per live wl_buffer. The storage must
    /// outlive wl_shm_pool.destroy while buffers still reference it
    /// (weston-simple-shm destroys the pool right after create_buffer).
    refs: u32 = 1,
    /// Read-only MAP_SHARED view of the whole pool; empty while unmapped.
    data: []align(std.heap.page_size_min) u8 = &.{},
    /// Set by the SIGBUS handler: `data` now maps zero pages, not the file.
    faulted: bool = false,

    pub fn map(self: *Pool) !void {
        std.debug.assert(self.data.len == 0);
        installSigbusGuard();
        self.data = try posix.mmap(null, self.size, .{ .READ = true }, .{ .TYPE = .SHARED }, self.fd, 0);
    }

    /// Replace the mapping with one of the current `size` (after
    /// wl_shm_pool.resize). Unmapped on failure.
    pub fn remap(self: *Pool) !void {
        if (self.data.len != 0) posix.munmap(self.data);
        self.data = &.{};
        try self.map();
    }

    pub fn deinit(self: *Pool) void {
        if (self.data.len != 0) posix.munmap(self.data);
        _ = linux.close(self.fd);
    }
};

/// The pool whose `data` this thread is reading (beginAccess … endAccess).
threadlocal var accessing: ?*Pool = null;
/// 0 = no guard, 1 = being installed, 2 = installed.
var guard_state: std.atomic.Value(u8) = .init(0);
var prev_sigbus: posix.Sigaction = undefined;

/// Reads of `pool.data` follow, on this thread, until `endAccess`.
pub fn beginAccess(pool: *Pool) void {
    accessing = pool;
    // a compiler barrier: no read of the pool may move above the store
    asm volatile ("" ::: .{ .memory = true });
}

/// The reads since `beginAccess` are over. False if one of them hit a page
/// past the end of the client's file: what they returned is garbage (the
/// missing pages read as zeros), and the pool is mapped afresh from the
/// file for the next access. Fails only if that remap fails.
pub fn endAccess(pool: *Pool) error{ReadFailed}!bool {
    asm volatile ("" ::: .{ .memory = true });
    accessing = null;
    if (!pool.faulted) return true;
    pool.faulted = false;
    pool.remap() catch return error.ReadFailed;
    return false;
}

/// Process-wide SIGBUS handler, installed once (the first pool mapping).
fn installSigbusGuard() void {
    if (guard_state.load(.acquire) == 2) return;
    if (guard_state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        while (guard_state.load(.acquire) != 2) std.Thread.yield() catch {};
        return;
    }
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = onSigbus },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.RESTART | posix.SA.ONSTACK,
    };
    posix.sigaction(.BUS, &act, &prev_sigbus);
    guard_state.store(2, .release);
}

/// A fault inside the pool this thread is accessing: map anonymous zero
/// pages over the whole pool, in place, and return — the faulting read
/// retries and succeeds. Any other SIGBUS goes to the previous disposition.
fn onSigbus(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    if (accessing) |pool| {
        const addr = @intFromPtr(info.fields.sigfault.addr);
        const start = @intFromPtr(pool.data.ptr);
        if (addr >= start and addr - start < pool.data.len) {
            const rc = linux.mmap(pool.data.ptr, pool.data.len, .{ .READ = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
            if (linux.errno(rc) == .SUCCESS) {
                pool.faulted = true;
                return;
            }
        }
    }
    if (prev_sigbus.flags & posix.SA.SIGINFO != 0) {
        if (prev_sigbus.handler.sigaction) |f| return f(sig, info, ctx);
    } else if (prev_sigbus.handler.handler != posix.SIG.DFL and prev_sigbus.handler.handler != posix.SIG.IGN) {
        return prev_sigbus.handler.handler.?(sig);
    }
    // default: restore it; the read faults again and the process dies as it
    // would have without us
    posix.sigaction(.BUS, &prev_sigbus, null);
}

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Per-surface accumulated damage. Capped; a rect added past the cap merges
/// into the stored rect whose bounding-box union grows the least — never a
/// full-surface degrade (that cliff shipped whole buffers exactly when
/// damage got busiest, e.g. nautilus resize storms).
pub const DamageList = struct {
    pub const cap = 64;
    rects: [cap]Rect = undefined,
    len: usize = 0,

    pub fn add(self: *DamageList, rect: Rect) void {
        if (self.len < cap) {
            self.rects[self.len] = rect;
            self.len += 1;
            return;
        }
        var best: usize = 0;
        var best_area: i64 = std.math.maxInt(i64);
        for (self.rects[0..self.len], 0..) |r, i| {
            const area = unionArea(r, rect);
            if (area < best_area) {
                best_area = area;
                best = i;
            }
        }
        self.rects[best] = unionRect(self.rects[best], rect);
    }

    fn unionRect(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x +| a.w, b.x +| b.w);
        const y1 = @max(a.y +| a.h, b.y +| b.h);
        return .{ .x = x0, .y = y0, .w = x1 -| x0, .h = y1 -| y0 };
    }

    fn unionArea(a: Rect, b: Rect) i64 {
        const u = unionRect(a, b);
        return @as(i64, u.w) * @as(i64, u.h);
    }

    pub fn reset(self: *DamageList) void {
        self.len = 0;
    }

    /// Rects clamped to buffer bounds, empties dropped. `force_full` yields
    /// one full-buffer rect. Returns the slice into `out`.
    pub fn clamped(self: *const DamageList, out: *[cap]Rect, buf_w: u32, buf_h: u32, force_full: bool) []Rect {
        const w: i32 = @intCast(buf_w);
        const h: i32 = @intCast(buf_h);
        if (force_full) {
            out[0] = .{ .x = 0, .y = 0, .w = w, .h = h };
            return out[0..1];
        }
        var n: usize = 0;
        for (self.rects[0..self.len]) |rect| {
            const x0 = @max(rect.x, 0);
            const y0 = @max(rect.y, 0);
            const x1 = @min(rect.x +| rect.w, w);
            const y1 = @min(rect.y +| rect.h, h);
            if (x1 <= x0 or y1 <= y0) continue;
            out[n] = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
            n += 1;
        }
        return out[0..n];
    }
};

pub const Buffer = struct {
    pool: *Pool,
    offset: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,

    /// Geometry is readable from the pool as it is NOW (pools only grow, but
    /// a buffer may be created past the end before a resize): non-empty,
    /// 4-byte pixels (the only formats wl_shm advertises), every row inside.
    pub fn fits(self: Buffer) bool {
        if (self.width == 0 or self.height == 0) return false;
        if (self.stride < @as(u64, self.width) * 4) return false;
        return @as(u64, self.offset) + @as(u64, self.height) * self.stride <= self.pool.size;
    }
};

test "damage list clamps and merges past the cap" {
    var d: DamageList = .{};
    d.add(.{ .x = -10, .y = 5, .w = 20, .h = 10 }); // clips left
    d.add(.{ .x = 90, .y = 90, .w = 50, .h = 50 }); // clips right/bottom
    d.add(.{ .x = 200, .y = 0, .w = 5, .h = 5 }); // fully outside
    var out: [DamageList.cap]Rect = undefined;
    const rects = d.clamped(&out, 100, 100, false);
    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 5, .w = 10, .h = 10 }, rects[0]);
    try std.testing.expectEqual(Rect{ .x = 90, .y = 90, .w = 10, .h = 10 }, rects[1]);

    // force_full wins
    const full = d.clamped(&out, 100, 100, true);
    try std.testing.expectEqual(@as(usize, 1), full.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, full[0]);

    // past the cap: merges into the nearest rect, never a full-buffer degrade
    var o: DamageList = .{};
    for (0..DamageList.cap) |i| o.add(.{ .x = @intCast(i * 10), .y = 0, .w = 1, .h = 1 });
    o.add(.{ .x = 1, .y = 0, .w = 2, .h = 1 }); // overlaps rect 0's row, nearest to it
    try std.testing.expectEqual(@as(usize, DamageList.cap), o.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 3, .h = 1 }, o.rects[0]);

    o.reset();
    try std.testing.expectEqual(@as(usize, 0), o.clamped(&out, 100, 100, false).len);
}

test "buffer fits its pool" {
    var pool: Pool = .{ .fd = -1, .size = 64 };
    const ok: Buffer = .{ .pool = &pool, .offset = 0, .width = 4, .height = 4, .stride = 16, .format = 1 };
    try std.testing.expect(ok.fits());
    var b = ok;
    b.offset = 4; // last row ends past the pool
    try std.testing.expect(!b.fits());
    b = ok;
    b.stride = 8; // rows narrower than their pixels
    try std.testing.expect(!b.fits());
    b = ok;
    b.height = 0;
    try std.testing.expect(!b.fits());
    pool.size = 68; // a resize makes the offset buffer readable
    b = ok;
    b.offset = 4;
    try std.testing.expect(b.fits());
}

test "fd queue fifo" {
    var q: FdQueue = .{};
    q.push(10);
    q.push(11);
    try std.testing.expectEqual(@as(?posix.fd_t, 10), q.pop());
    try std.testing.expectEqual(@as(?posix.fd_t, 11), q.pop());
    try std.testing.expectEqual(@as(?posix.fd_t, null), q.pop());
    // don't drain — these fake fds were never opened
    q.len = 0;
}

test "cmsg alignment" {
    try std.testing.expectEqual(@as(usize, 16), cmsg_hdr_space);
    try std.testing.expectEqual(@as(usize, 24), cmsgAlign(20));
}
