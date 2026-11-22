// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Writes the engine's own clipboard selection into receivers' pipes (a
//! `wl_data_offer.receive` on it: STREAM.md FDMSG own_pipe / pipe). One
//! thread for the relay's life polls every transfer, with non-blocking
//! writes, so a receiver that reads slowly or never costs a slot, not a
//! thread; slots are capped per conn and relay-wide, and past a cap the fd
//! is closed at once (the receiver reads EOF). A transfer ends when all is
//! written, at EPIPE (SIGPIPE is ignored by Io.Threaded), at its deadline,
//! or when its conn closes or the link detaches (`dropConn`, `dropAll`).
//!
//! Payloads are refcounted `Blob`s: the relay's copy of a selection payload
//! (Relay.own_cache) holds one reference and each transfer one, so a
//! selection replaced mid-transfer finishes from the bytes it started with.
//!
//! Only the writer thread closes a transfer's fd (another thread closing it
//! could hand the number to a new file under the thread's poll). It drops
//! the transfer's blob reference first and closes the fd last, so a reader
//! that saw EOF sees no transfer state left.
//!
//! The fds are the RECEIVER's: only pipes are taken (`isPipe`; anything
//! else is closed at once). O_NONBLOCK is a request some files ignore — a
//! FUSE file whose server never answers, a regular file on a hung NFS
//! mount, a tty draining under flow control block in write() and close()
//! whatever the flag — and a pipe is the one type whose write and close
//! never wait. The flag also sits on a file description the receiver
//! shares (it can clear it again), so each write asks RWF_NOWAIT itself
//! (`writeNoWait`). Belt and braces, no syscall on a transfer's fd runs
//! under `mutex`: the thread copies what it needs out, writes and closes
//! unlocked, so start()/dropConn()/dropAll() (the link and app threads)
//! never wait on a receiver.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;

/// A payload shared by the relay's cache and the transfers writing it.
pub const Blob = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: std.mem.Allocator,
    bytes: []u8,

    /// A copy of `bytes`, one reference held (the caller's).
    pub fn create(gpa: std.mem.Allocator, bytes: []const u8) !*Blob {
        const b = try gpa.create(Blob);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .bytes = try gpa.dupe(u8, bytes) };
        return b;
    }

    pub fn ref(self: *Blob) *Blob {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn unref(self: *Blob) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = self.gpa;
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
};

/// Most transfers in flight for one receiving conn, and in all.
pub const per_conn_max = 4;
pub const total_max = 32;
/// How long one transfer may take in all.
pub const deadline_ms = 5000;
/// Most bytes written to one fd per wakeup (fairness between transfers).
const burst_max = 256 * 1024;
/// Conns whose close the writer remembers (`Writer.closed`).
const closed_ring_len = 256;

/// Is `fd` a pipe (anonymous or a FIFO)? F_GETPIPE_SZ answers from the
/// file's ops alone — it never calls into a filesystem (fstat could: FUSE
/// getattr), so a hung FUSE or NFS file can't block the asking.
pub fn isPipe(fd: i32) bool {
    return linux.errno(linux.fcntl(fd, linux.F.GETPIPE_SZ, 0)) == .SUCCESS;
}

/// Default-constructible (it lives in the Relay struct literal): `io` and
/// `gpa` come with each call and are kept for the thread at its spawn.
pub const Writer = struct {
    io: Io = undefined,
    gpa: std.mem.Allocator = undefined,
    mutex: Io.Mutex = .init,
    transfers: std.ArrayList(Transfer) = .empty,
    /// eventfd that wakes the thread (a new transfer, a cancel, stop)
    wake_fd: i32 = -1,
    thread: ?std.Thread = null,
    stopping: bool = false,
    /// transfers refused at a cap (their fd closed at once), for tests/logs
    refused: usize = 0,
    cap_logged: bool = false,
    /// fds refused for not being pipes (closed at once), for tests/logs
    refused_type: usize = 0,
    type_logged: bool = false,
    /// receives refused because their conn had closed (closed at once)
    refused_closed: usize = 0,
    /// The conns dropConn ended most recently: a start() for one of them
    /// is refused. The relay checks a conn is live before start(), but
    /// unlocked: the conn can close (and dropConn find nothing to end)
    /// between that check and this start(). Conn ids are never reused, so
    /// a tombstone is never wrong; the ring only has to outlast that short
    /// window (a conn closed long before fails the relay's own check).
    closed: [closed_ring_len]u32 = @splat(0),
    closed_next: usize = 0,

    const Transfer = struct {
        fd: i32,
        conn_id: u32,
        blob: *Blob,
        off: usize = 0,
        deadline: i64,
        cancelled: bool = false,
    };

    /// Stop the thread; transfers still going are ended (fds closed).
    pub fn deinit(self: *Writer, io: Io) void {
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        const thread = self.thread;
        self.mutex.unlock(io);
        if (thread) |t| {
            self.wake();
            t.join();
            for (self.transfers.items) |t2| finish(t2);
            self.transfers.deinit(self.gpa);
        }
        if (self.wake_fd >= 0) _ = linux.close(self.wake_fd);
    }

    /// Write `blob` into `fd` (a receiver's pipe) for conn `conn_id`, then
    /// close it. Takes the fd and the caller's blob reference whatever
    /// happens: not a pipe, past a cap, for a conn dropConn ended (or with
    /// no thread) the fd is closed now — the receiver reads EOF.
    pub fn start(self: *Writer, io: Io, gpa: std.mem.Allocator, conn_id: u32, fd: i32, blob: *Blob) void {
        // The relay refuses non-pipes at the receive already (on the
        // receiver's own thread: closing such an fd may block); this is
        // the backstop for any other caller.
        const pipe = isPipe(fd);
        // for a write that falls back from RWF_NOWAIT (writeNoWait)
        if (pipe) {
            const fl = linux.fcntl(fd, linux.F.GETFL, 0);
            if (linux.errno(fl) == .SUCCESS) _ = linux.fcntl(fd, linux.F.SETFL, fl | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
        }
        self.mutex.lockUncancelable(io);
        const ok = blk: {
            if (self.stopping) break :blk false;
            if (!pipe) {
                self.refused_type += 1;
                if (!self.type_logged) std.log.warn("clipboard: conn {d}: a receive of the page's selection with an fd that is not a pipe — refused (the receiver reads EOF); only pipes are written", .{conn_id});
                self.type_logged = true;
                break :blk false;
            }
            if (std.mem.indexOfScalar(u32, &self.closed, conn_id) != null) {
                self.refused_closed += 1;
                break :blk false;
            }
            var mine: usize = 0;
            for (self.transfers.items) |t| {
                if (t.conn_id == conn_id and !t.cancelled) mine += 1;
            }
            if (mine >= per_conn_max or self.transfers.items.len >= total_max) {
                self.refused += 1;
                if (!self.cap_logged) std.log.warn("clipboard: conn {d}: over {d} transfers of the page's selection in flight ({d} in all) — further receives read EOF until some finish", .{ conn_id, per_conn_max, total_max });
                self.cap_logged = true;
                break :blk false;
            }
            self.ensureThread(io, gpa) catch break :blk false;
            const now = Io.Clock.now(.awake, self.io).toMilliseconds();
            self.transfers.append(self.gpa, .{ .fd = fd, .conn_id = conn_id, .blob = blob, .deadline = now + deadline_ms }) catch break :blk false;
            break :blk true;
        };
        self.mutex.unlock(io);
        if (!ok) return finish(.{ .fd = fd, .conn_id = conn_id, .blob = blob, .deadline = 0 });
        self.wake();
    }

    /// End `conn_id`'s transfers (its app hung up), and refuse any it
    /// starts from now on. Never waits on a receiver.
    pub fn dropConn(self: *Writer, io: Io, conn_id: u32) void {
        if (conn_id == 0) return; // no conn has id 0 (0 is the ring's empty slot)
        self.mutex.lockUncancelable(io);
        self.closed[self.closed_next] = conn_id;
        self.closed_next = (self.closed_next + 1) % closed_ring_len;
        self.mutex.unlock(io);
        self.cancel(io, conn_id);
    }

    /// End every transfer (the link detached).
    pub fn dropAll(self: *Writer, io: Io) void {
        self.cancel(io, null);
    }

    /// Transfers in flight (cancelled ones not yet closed included).
    pub fn inFlight(self: *Writer, io: Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.transfers.items.len;
    }

    fn cancel(self: *Writer, io: Io, conn_id: ?u32) void {
        self.mutex.lockUncancelable(io);
        var any = false;
        for (self.transfers.items) |*t| {
            if (conn_id == null or t.conn_id == conn_id.?) {
                t.cancelled = true;
                any = true;
            }
        }
        self.mutex.unlock(io);
        if (any) self.wake();
    }

    /// mutex held
    fn ensureThread(self: *Writer, io: Io, gpa: std.mem.Allocator) !void {
        if (self.thread != null) return;
        self.io = io;
        self.gpa = gpa;
        if (self.wake_fd < 0) {
            const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(rc) != .SUCCESS) return error.EventFd;
            self.wake_fd = @intCast(rc);
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn wake(self: *Writer) void {
        if (self.wake_fd < 0) return;
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// Drop the blob reference, then close the fd (the receiver reads EOF).
    fn finish(t: Transfer) void {
        t.blob.unref();
        _ = linux.close(t.fd);
    }

    /// A polled transfer that is ready, copied out to write unlocked.
    const Ready = struct { k: usize, fd: i32, bytes: []const u8, off: usize, over: bool = false };

    fn run(self: *Writer) void {
        var pfds: std.ArrayList(linux.pollfd) = .empty;
        defer pfds.deinit(self.gpa);
        var ready: std.ArrayList(Ready) = .empty;
        defer ready.deinit(self.gpa);
        // transfers taken out of the list, finished (closed) once unlocked
        var over: std.ArrayList(Transfer) = .empty;
        defer over.deinit(self.gpa);
        while (true) {
            // under the lock: take out what is over, then poll the rest
            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const now = Io.Clock.now(.awake, self.io).toMilliseconds();
            var timeout: i64 = -1;
            var i: usize = 0;
            while (i < self.transfers.items.len) {
                const t = self.transfers.items[i];
                if (t.cancelled or now >= t.deadline) {
                    self.retire(&over, i);
                    continue;
                }
                const left = t.deadline - now;
                if (timeout < 0 or left < timeout) timeout = left;
                i += 1;
            }
            pfds.clearRetainingCapacity();
            const n = self.transfers.items.len;
            const room = pfds.ensureTotalCapacity(self.gpa, n + 1);
            if (room) |_| {
                pfds.appendAssumeCapacity(.{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 });
                for (self.transfers.items) |t| pfds.appendAssumeCapacity(.{ .fd = t.fd, .events = linux.POLL.OUT, .revents = 0 });
            } else |_| {}
            self.mutex.unlock(self.io);
            finishAll(&over);
            room catch {
                sleepMs(10);
                continue; // out of memory: retry (the deadlines still apply)
            };

            const rc = linux.poll(pfds.items.ptr, @intCast(pfds.items.len), @intCast(timeout));
            if (linux.errno(rc) != .SUCCESS) continue; // EINTR
            if (pfds.items[0].revents != 0) {
                var buf: u64 = 0;
                _ = linux.read(self.wake_fd, std.mem.asBytes(&buf), @sizeOf(u64));
            }
            // only this thread removes transfers (or closes their fds, or
            // drops their blobs); others only append and mark cancelled: so
            // indices 0..n stay the ones polled, and a copied-out fd and
            // blob stay valid while unlocked
            ready.ensureTotalCapacity(self.gpa, n) catch continue;
            ready.clearRetainingCapacity();
            self.mutex.lockUncancelable(self.io);
            for (pfds.items[1..], 0..) |p, k| {
                if (p.revents == 0) continue;
                const t = self.transfers.items[k];
                ready.appendAssumeCapacity(.{ .k = k, .fd = t.fd, .bytes = t.blob.bytes, .off = t.off });
            }
            self.mutex.unlock(self.io);
            for (ready.items) |*r| r.over = writeSome(r.fd, r.bytes, &r.off);
            self.mutex.lockUncancelable(self.io);
            var j: usize = ready.items.len;
            while (j > 0) { // descending k: a swapRemove leaves lower ones in place
                j -= 1;
                const r = ready.items[j];
                const t = &self.transfers.items[r.k];
                t.off = r.off;
                if (r.over or t.cancelled) self.retire(&over, r.k);
            }
            self.mutex.unlock(self.io);
            finishAll(&over);
        }
    }

    /// mutex held: take transfer `k` out of the list onto `over` (finished
    /// once unlocked; with no memory for that, now — a pipe's close never
    /// waits, so the lock is held for no time).
    fn retire(self: *Writer, over: *std.ArrayList(Transfer), k: usize) void {
        const t = self.transfers.swapRemove(k);
        over.append(self.gpa, t) catch finish(t);
    }

    fn finishAll(over: *std.ArrayList(Transfer)) void {
        for (over.items) |t| finish(t);
        over.clearRetainingCapacity();
    }

    /// Non-blocking writes of `bytes[off.*..]` into `fd` until the pipe is
    /// full or `burst_max` went out; advances `off`. True: the transfer is
    /// over (all written, or the reader is gone).
    fn writeSome(fd: i32, bytes: []const u8, off: *usize) bool {
        var budget: usize = burst_max;
        while (off.* < bytes.len and budget > 0) {
            const chunk = @min(bytes.len - off.*, budget);
            const rc = writeNoWait(fd, bytes[off.*..].ptr, chunk);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    off.* += rc;
                    budget -= rc;
                },
                .INTR => {},
                .AGAIN => return false,
                else => return true, // EPIPE (the receiver closed its end), a bad fd
            }
        }
        return off.* >= bytes.len;
    }

    /// One write that never waits, whatever the fd's flags. O_NONBLOCK
    /// lives on the file description, which the receiver shares (it may
    /// keep a dup of the end it handed over and clear the flag again);
    /// RWF_NOWAIT is this call's own. Pipes take it (Linux 5.8+); where
    /// it is not supported (a named FIFO, an older kernel) a plain write
    /// relies on O_NONBLOCK — and at worst stalls this thread, unlocked.
    fn writeNoWait(fd: i32, ptr: [*]const u8, len: usize) usize {
        const iov = [1]std.posix.iovec_const{.{ .base = ptr, .len = len }};
        const rc = linux.pwritev2(fd, &iov, 1, -1, linux.RWF.NOWAIT);
        return switch (linux.errno(rc)) {
            .OPNOTSUPP, .NOSYS => linux.write(fd, ptr, len),
            else => rc,
        };
    }
};

test "writer: one thread, capped slots; a full pipe holds a slot not a thread; EOF past the caps; EPIPE and cancels end transfers" {
    std.testing.log_level = .err; // the cap warns
    defer std.testing.log_level = .warn;
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var w: Writer = .{};
    defer w.deinit(io);
    const blob = try Blob.create(gpa, &([_]u8{'x'} ** (1 << 20)));
    defer blob.unref();

    // conn 1: per_conn_max transfers into pipes nobody reads, then one more
    var readers: [per_conn_max + 1]i32 = undefined;
    for (&readers) |*r| {
        var fds: [2]i32 = undefined;
        try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
        r.* = fds[0];
        w.start(io, gpa, 1, fds[1], blob.ref());
    }
    defer for (readers) |r| {
        _ = linux.close(r);
    };
    try std.testing.expectEqual(@as(usize, per_conn_max), w.inFlight(io));
    try std.testing.expectEqual(@as(usize, 1), w.refused);
    // the one past the cap reads EOF at once
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(readers[per_conn_max], &byte, 1));

    // another conn is still served, all of it
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds[0]);
    w.start(io, gpa, 2, fds[1], blob.ref());
    var got: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = linux.read(fds[0], &buf, buf.len);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        if (rc == 0) break;
        got += rc;
    }
    try std.testing.expectEqual(blob.bytes.len, got);

    // a reader that closes early ends its transfer (EPIPE)
    _ = linux.close(readers[0]);
    readers[0] = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    var spins: usize = 0;
    while (w.inFlight(io) != per_conn_max - 1 and spins < 500) : (spins += 1) sleepMs(10);
    try std.testing.expectEqual(@as(usize, per_conn_max - 1), w.inFlight(io));

    // the conn goes: its transfers end, their readers see EOF after what was written
    w.dropConn(io, 1);
    spins = 0;
    while (w.inFlight(io) != 0 and spins < 500) : (spins += 1) sleepMs(10);
    try std.testing.expectEqual(@as(usize, 0), w.inFlight(io));
    for (readers[1..per_conn_max]) |r| {
        var total: usize = 0;
        while (true) {
            const rc = linux.read(r, &buf, buf.len);
            if (rc == 0) break;
            total += rc;
        }
        try std.testing.expect(total < blob.bytes.len); // cut short
    }
    try std.testing.expectEqual(@as(u32, 1), blob.refs.load(.monotonic)); // ours alone
}

test "writer: only pipes are written; a regular file, /dev/null, a socket, a pty are closed at once" {
    std.testing.log_level = .err; // the refusal warns
    defer std.testing.log_level = .warn;
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var w: Writer = .{};
    defer w.deinit(io);
    const blob = try Blob.create(gpa, "data");
    defer blob.unref();

    // a regular file (a FUSE or NFS one would block write() and close()
    // whatever O_NONBLOCK says; a plain one stands in for its type)
    const file: i32 = @intCast(linux.memfd_create("wland-test", linux.MFD.CLOEXEC));
    const file_dup: i32 = @intCast(linux.dup(file));
    defer _ = linux.close(file_dup);
    w.start(io, gpa, 1, file, blob.ref());
    // /dev/null
    const null_fd: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0));
    w.start(io, gpa, 1, null_fd, blob.ref());
    // one end of a socketpair: its peer reads EOF at once, nothing written
    var sp: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sp));
    defer _ = linux.close(sp[1]);
    w.start(io, gpa, 1, sp[0], blob.ref());
    var byte: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(sp[1], &byte, byte.len));
    // a pty (a tty's close can wait for output to drain)
    const ptm = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    const have_pty = linux.errno(ptm) == .SUCCESS;
    if (have_pty) w.start(io, gpa, 1, @intCast(ptm), blob.ref());

    const refused: usize = if (have_pty) 4 else 3;
    try std.testing.expectEqual(refused, w.refused_type);
    try std.testing.expectEqual(@as(usize, 0), w.inFlight(io));
    // nothing went into the file
    var st: linux.Statx = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.statx(file_dup, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st));
    try std.testing.expectEqual(@as(u64, 0), st.size);
    try std.testing.expectEqual(@as(u32, 1), blob.refs.load(.monotonic));

    // a pipe is written, as ever
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds[0]);
    try std.testing.expect(isPipe(fds[1]));
    w.start(io, gpa, 1, fds[1], blob.ref());
    var got: usize = 0;
    while (true) {
        const rc = linux.read(fds[0], byte[got..].ptr, byte.len - got);
        if (rc == 0) break;
        got += rc;
    }
    try std.testing.expectEqualStrings("data", byte[0..got]);
}

test "writer: a receiver that clears O_NONBLOCK on its end and never reads stalls nothing: start/dropConn/dropAll return at once, others are served" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var w: Writer = .{};
    defer w.deinit(io);
    const blob = try Blob.create(gpa, &([_]u8{'x'} ** (1 << 20)));
    defer blob.unref();

    // conn 1 keeps a dup of the write end it hands over (the same file
    // description), and once the writer set O_NONBLOCK, clears it again:
    // a plain write() on the full pipe would now block
    var slow: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&slow, .{ .CLOEXEC = true }));
    var slow_reader: ?i32 = slow[0];
    defer if (slow_reader) |r| {
        _ = linux.close(r);
    };
    const kept: i32 = @intCast(linux.dup(slow[1]));
    defer _ = linux.close(kept);
    // pipes take RWF_NOWAIT from Linux 5.8; before that this receiver can
    // still stall the writer thread (never the relay's locks)
    const none = [1]std.posix.iovec_const{.{ .base = "", .len = 0 }};
    if (linux.errno(linux.pwritev2(kept, &none, 1, -1, linux.RWF.NOWAIT)) != .SUCCESS) return error.SkipZigTest;
    w.start(io, gpa, 1, slow[1], blob.ref());
    const fl = linux.fcntl(kept, linux.F.GETFL, 0);
    _ = linux.fcntl(kept, linux.F.SETFL, fl & ~@as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
    // let the writer fill the pipe and come round to it again
    var spins: usize = 0;
    var avail: i32 = 0;
    while (spins < 200) : (spins += 1) {
        _ = linux.ioctl(slow[0], linux.T.FIONREAD, @intFromPtr(&avail));
        if (avail >= 64 * 1024) break;
        sleepMs(5);
    }
    sleepMs(50);

    // another conn's receive starts and completes, and the conn and
    // link drops return — on a thread (the link's, the app's), so a
    // writer that waits on conn 1 fails this test rather than hanging it
    const Other = struct {
        done: std.atomic.Value(bool) = .init(false),
        got: usize = 0,
        fn run(o: *@This(), wr: *Writer, io2: Io, g: std.mem.Allocator, b: *Blob) void {
            defer o.done.store(true, .release);
            var fds: [2]i32 = undefined;
            if (linux.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return;
            defer _ = linux.close(fds[0]);
            wr.start(io2, g, 2, fds[1], b.ref());
            var buf: [64 * 1024]u8 = undefined;
            var pfd = [1]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
            while (linux.poll(&pfd, 1, 3000) == 1) {
                const rc = linux.read(fds[0], &buf, buf.len);
                if (linux.errno(rc) != .SUCCESS or rc == 0) break;
                o.got += rc;
            }
            wr.dropConn(io2, 3);
            wr.dropAll(io2);
        }
    };
    var other: Other = .{};
    const th = try std.Thread.spawn(.{}, Other.run, .{ &other, &w, io, gpa, blob });
    spins = 0;
    while (!other.done.load(.acquire) and spins < 300) : (spins += 1) sleepMs(10);
    const stalled = !other.done.load(.acquire);
    if (stalled) { // unwedge: conn 1's reader goes, its blocked write fails (EPIPE)
        _ = linux.close(slow[0]);
        slow_reader = null;
    }
    th.join();
    try std.testing.expect(!stalled);
    try std.testing.expectEqual(blob.bytes.len, other.got);
    spins = 0;
    while (w.inFlight(io) != 0 and spins < 500) : (spins += 1) sleepMs(10);
    try std.testing.expectEqual(@as(usize, 0), w.inFlight(io));
}

test "writer: a receive that starts after its conn's dropConn (the relay saw it live, then it closed) is closed at once" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var w: Writer = .{};
    defer w.deinit(io);
    const blob = try Blob.create(gpa, "late");
    defer blob.unref();

    w.dropConn(io, 5); // its app thread: nothing in flight to end
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds[0]);
    w.start(io, gpa, 5, fds[1], blob.ref()); // the link thread, a moment late
    try std.testing.expectEqual(@as(usize, 0), w.inFlight(io));
    try std.testing.expectEqual(@as(usize, 1), w.refused_closed);
    var byte: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(fds[0], &byte, byte.len)); // EOF, nothing written
    // other conns go on (and conn 5's tombstone outlives many later closes)
    var c: u32 = 100;
    while (c < 100 + closed_ring_len - 1) : (c += 1) w.dropConn(io, c);
    var fds2: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds2, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds2[0]);
    w.start(io, gpa, 5, fds2[1], blob.ref());
    try std.testing.expectEqual(@as(usize, 2), w.refused_closed);
    var fds3: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds3, .{ .CLOEXEC = true }));
    defer _ = linux.close(fds3[0]);
    w.start(io, gpa, 6, fds3[1], blob.ref());
    var n: usize = 0;
    while (true) {
        const rc = linux.read(fds3[0], byte[n..].ptr, byte.len - n);
        if (rc == 0) break;
        n += rc;
    }
    try std.testing.expectEqualStrings("late", byte[0..n]);
}

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}
