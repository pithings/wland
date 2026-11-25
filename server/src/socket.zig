// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Claiming a wayland socket name the way libwayland-server does
//! (wl_display_add_socket_auto): hold an flock on `<dir>/<name>.lock` for the
//! whole process, and only then replace a stale socket file. Real compositors
//! hold that lock, so a held one means "in use". A socket that still answers
//! is in use too, lock or not (a compositor that doesn't lock, or an older
//! wlandr): listenWayland deletes the file it binds over, and must never
//! delete a live one.
//!
//! At exit both files go, socket first, while the lock is still held (as
//! wl_display_destroy does): `remove` on a normal return, and handlers for
//! SIGINT/SIGTERM/SIGHUP (`removeOnSignal`). SIGKILL or a crash leaves them
//! behind — harmless: the next claim takes the lock and replaces the socket.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const LOCK = posix.LOCK;

/// How far claimAuto looks (libwayland stops at 32 too).
pub const max_auto = 32;

/// A claimed name. The lock is held until the process exits (never released
/// on purpose: the socket lives as long as wlandr does).
pub const Claim = struct {
    lock_fd: i32,
    path_buf: [108]u8 = undefined,
    path_len: usize,
    name_start: usize,
    /// `<path>.lock`, NUL-terminated.
    lock_buf: [128]u8 = undefined,

    /// `<dir>/<name>`, the socket to bind.
    pub fn path(self: *const Claim) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// The name alone (what WAYLAND_DISPLAY should say).
    pub fn name(self: *const Claim) []const u8 {
        return self.path_buf[self.name_start..self.path_len];
    }

    /// `<path>.lock`.
    pub fn lockPath(self: *const Claim) [*:0]const u8 {
        return @ptrCast(&self.lock_buf);
    }

    /// Unlink the socket, then the lock file, then let go of the lock — the
    /// order libwayland uses, so nobody can lock a name whose socket is
    /// still ours. Idempotent; disarms removeOnSignal.
    pub fn remove(self: *Claim) void {
        if (self.lock_fd < 0) return;
        armed.store(false, .seq_cst);
        var z: [109]u8 = undefined;
        @memcpy(z[0..self.path_len], self.path());
        z[self.path_len] = 0;
        _ = linux.unlink(@ptrCast(&z));
        unlinkExtras();
        _ = linux.unlink(self.lockPath());
        self.release();
    }

    /// Tests: let go of the name, leaving the files.
    pub fn release(self: *Claim) void {
        if (self.lock_fd >= 0) _ = linux.close(self.lock_fd);
        self.lock_fd = -1;
    }
};

// --- removal on a terminating signal ------------------------------------------
// A signal handler can only use what's already in memory: the two paths are
// copied here, NUL-terminated, when the handlers are installed.

var armed: std.atomic.Value(bool) = .init(false);
var exit_sock: [109]u8 = @splat(0);
var exit_lock: [128]u8 = @splat(0);
const exit_signals = [_]posix.SIG{ .INT, .TERM, .HUP };

/// Remove `c`'s socket and lock file if the process is ended by SIGINT,
/// SIGTERM or SIGHUP; the signal then takes its default course (the exit
/// status still says which). One claim per process.
pub fn removeOnSignal(c: *const Claim) void {
    @memcpy(exit_sock[0..c.path_len], c.path());
    exit_sock[c.path_len] = 0;
    exit_lock = c.lock_buf;
    armed.store(true, .seq_cst);
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onExitSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (exit_signals) |sig| posix.sigaction(sig, &act, null);
}

/// Other files of this process that go at exit, with the socket (the X11
/// display's lock and socket, the `.x11` note, the --lodpi socket and its
/// lock): NUL-terminated, in static memory for the signal handler.
var extras: [8][128]u8 = @splat(@splat(0));
var extras_len: std.atomic.Value(usize) = .init(0);

/// Remove `path` too when the claim is removed (a normal return or a
/// terminating signal). At most 8, each under 128 bytes; more are ignored.
pub fn removeAtExit(path: []const u8) void {
    const i = extras_len.load(.seq_cst);
    if (i >= extras.len or path.len >= extras[i].len) return;
    @memcpy(extras[i][0..path.len], path);
    extras[i][path.len] = 0;
    extras_len.store(i + 1, .seq_cst);
}

fn unlinkExtras() void {
    for (extras[0..extras_len.load(.seq_cst)]) |*p| _ = linux.unlink(@ptrCast(p));
}

/// Unlink the armed paths (async-signal-safe: unlinks only). True if armed.
fn unlinkArmed() bool {
    if (!armed.swap(false, .seq_cst)) return false;
    _ = linux.unlink(@ptrCast(&exit_sock));
    unlinkExtras();
    _ = linux.unlink(@ptrCast(&exit_lock));
    return true;
}

fn onExitSignal(sig: posix.SIG) callconv(.c) void {
    _ = unlinkArmed();
    // default disposition, then re-raise: the signal is blocked while this
    // handler runs, and kills the process as it returns
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(sig, &dfl, null);
    _ = linux.kill(linux.getpid(), sig);
}

pub const Error = error{
    /// Another compositor holds the lock or answers on the socket.
    InUse,
    /// `<dir>/<name>` doesn't fit sun_path (108 bytes with the NUL).
    NameTooLong,
    /// The lock file can't be opened or locked (missing dir, permissions).
    LockFailed,
    /// claimAuto: wayland-0 … wayland-31 are all taken.
    NoFreeName,
};

/// Claim exactly `name` in `dir`.
pub fn claim(dir: []const u8, name: []const u8) Error!Claim {
    var c: Claim = .{ .lock_fd = -1, .path_len = 0, .name_start = dir.len + 1 };
    // the lock path is `<path>.lock`, so leave room for that and its NUL
    const sock_path = std.fmt.bufPrint(&c.path_buf, "{s}/{s}", .{ dir, name }) catch return error.NameTooLong;
    if (sock_path.len > c.path_buf.len - 1) return error.NameTooLong;
    c.path_len = sock_path.len;

    const lock_path = std.fmt.bufPrintZ(&c.lock_buf, "{s}.lock", .{sock_path}) catch return error.NameTooLong;
    // created: whether this call made the file (then it may remove it again
    // when it backs off — a file someone else made is theirs)
    var created = true;
    var rc = linux.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o660);
    if (linux.errno(rc) == .EXIST) {
        created = false;
        rc = linux.open(lock_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    }
    if (linux.errno(rc) != .SUCCESS) return error.LockFailed;
    const fd: i32 = @intCast(rc);
    while (true) {
        switch (linux.errno(linux.flock(fd, LOCK.EX | LOCK.NB))) {
            .SUCCESS => break,
            .INTR => continue,
            .AGAIN => {
                _ = linux.close(fd);
                return error.InUse;
            },
            else => {
                _ = linux.close(fd);
                return error.LockFailed;
            },
        }
    }
    if (answers(sock_path)) {
        // a live socket nobody locks: back off, leaving no lock file of ours
        if (created) _ = linux.unlink(lock_path);
        _ = linux.close(fd);
        return error.InUse;
    }
    c.lock_fd = fd;
    return c;
}

/// Claim the first free `wayland-N` in `dir`.
pub fn claimAuto(dir: []const u8) Error!Claim {
    var buf: [16]u8 = undefined;
    for (0..max_auto) |n| {
        const name = std.fmt.bufPrint(&buf, "wayland-{d}", .{n}) catch unreachable;
        return claim(dir, name) catch |err| switch (err) {
            error.InUse => continue,
            else => return err,
        };
    }
    return error.NoFreeName;
}

/// Something accepts connections at this unix socket path. Non-blocking: a
/// full backlog (EAGAIN) is a busy compositor, not a dead one.
pub fn answers(path: []const u8) bool {
    var sa: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= sa.path.len) return false;
    @memcpy(sa.path[0..path.len], path);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    while (true) {
        return switch (linux.errno(linux.connect(fd, &sa, @sizeOf(linux.sockaddr.un)))) {
            .SUCCESS, .AGAIN, .INPROGRESS => true,
            .INTR => continue,
            else => false, // ENOENT: no file · ECONNREFUSED: a stale one
        };
    }
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// A fresh directory under /tmp (sun_path is short: no deep test dirs).
fn tmpDir(buf: []u8) ![:0]const u8 {
    const dir = try std.fmt.bufPrintZ(buf, "/tmp/wland-sock-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o700);
    return dir;
}

fn rmTree(dir: []const u8) void {
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ "wayland-0", "wayland-1", "wayland-2", "wayland-3", "dev" }) |n| {
        for ([_][]const u8{ "", ".lock" }) |ext| {
            const p = std.fmt.bufPrintZ(&buf, "{s}/{s}{s}", .{ dir, n, ext }) catch continue;
            _ = linux.unlink(p);
        }
    }
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{dir}) catch return;
    _ = linux.rmdir(z);
}

/// Bind and listen at `<dir>/<name>` with no lock: a compositor that doesn't
/// lock. Returns the listening fd.
fn listenAt(dir: []const u8, name: []const u8) !i32 {
    var sa: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = try std.fmt.bufPrint(&sa.path, "{s}/{s}", .{ dir, name });
    const fd: i32 = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(fd, 4)));
    return fd;
}

test "claimAuto takes the first wayland-N whose lock is free" {
    var buf: [64]u8 = undefined;
    const dir = try tmpDir(&buf);
    defer rmTree(dir);

    var a = try claimAuto(dir);
    defer a.release();
    try testing.expectEqualStrings("wayland-0", a.name());
    // flock is per open file description: a second claim in this process
    // conflicts exactly like another process would
    var b = try claimAuto(dir);
    defer b.release();
    try testing.expectEqualStrings("wayland-1", b.name());
    try testing.expectError(error.InUse, claim(dir, "wayland-0"));
}

test "a live socket is in use even without a lock; a stale one is free" {
    var buf: [64]u8 = undefined;
    const dir = try tmpDir(&buf);
    defer rmTree(dir);

    const live = try listenAt(dir, "wayland-0");
    try testing.expectError(error.InUse, claim(dir, "wayland-0"));
    try testing.expect(!exists(dir, "wayland-0.lock")); // backed off without a trace
    var c = try claimAuto(dir);
    try testing.expectEqualStrings("wayland-1", c.name());
    c.release();

    // closing the listener leaves the file behind: stale, so it's claimable
    _ = linux.close(live);
    var d = try claim(dir, "wayland-0");
    defer d.release();
    try testing.expectEqualStrings("wayland-0", d.name());
}

test "explicit names and errors" {
    var buf: [64]u8 = undefined;
    const dir = try tmpDir(&buf);
    defer rmTree(dir);

    var c = try claim(dir, "dev");
    defer c.release();
    try testing.expectEqualStrings("dev", c.name());
    try testing.expect(std.mem.endsWith(u8, c.path(), "/dev"));
    try testing.expectError(error.LockFailed, claim("/nonexistent-wland-dir", "wayland-0"));
    try testing.expectError(error.NameTooLong, claim(dir, "x" ** 120));
}

fn exists(dir: []const u8, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    return linux.errno(linux.access(p, linux.F_OK)) == .SUCCESS;
}

test "remove: socket and lock file go, and the name is free again" {
    var buf: [64]u8 = undefined;
    const dir = try tmpDir(&buf);
    defer rmTree(dir);

    var c = try claimAuto(dir);
    const fd = try listenAt(dir, c.name());
    _ = linux.close(fd);
    try testing.expect(exists(dir, "wayland-0") and exists(dir, "wayland-0.lock"));
    c.remove();
    try testing.expect(!exists(dir, "wayland-0") and !exists(dir, "wayland-0.lock"));
    c.remove(); // idempotent
    var d = try claimAuto(dir);
    defer d.remove();
    try testing.expectEqualStrings("wayland-0", d.name());
}

test "the signal path unlinks what removeOnSignal armed, once" {
    var buf: [64]u8 = undefined;
    const dir = try tmpDir(&buf);
    defer rmTree(dir);

    var c = try claimAuto(dir);
    defer c.release();
    _ = linux.close(try listenAt(dir, c.name()));
    // arm without installing handlers (a test process must not trade its
    // own SIGINT/SIGTERM disposition): what onExitSignal runs
    @memcpy(exit_sock[0..c.path_len], c.path());
    exit_sock[c.path_len] = 0;
    exit_lock = c.lock_buf;
    armed.store(true, .seq_cst);
    try testing.expect(unlinkArmed());
    try testing.expect(!exists(dir, "wayland-0") and !exists(dir, "wayland-0.lock"));
    try testing.expect(!unlinkArmed());
}
