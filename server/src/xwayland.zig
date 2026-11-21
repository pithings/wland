// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! X11 apps, through xwayland-satellite (rootless Xwayland + the X11 window
//! manager, as one ordinary wayland client of ours). wlandr does the part a
//! compositor does for it (niri's integration is the model):
//!
//!  - claim an X display number the way X servers do: `/tmp/.X<n>-lock`
//!    holding our pid, then listen on `/tmp/.X11-unix/X<n>` and on the
//!    abstract socket of the same name. `DISPLAY=:<n>` is known at startup,
//!    before anything X runs.
//!  - on the first connection to either socket, start
//!    `xwayland-satellite :<n> -listenfd 3 [-listenfd 4]`. Xwayland inherits
//!    the listeners and accepts the waiting client, so that client never sees
//!    a refusal. No X app, no Xwayland.
//!  - when satellite exits, watch the sockets again.
//!
//! The child gets WAYLAND_DISPLAY = our socket and nothing else of ours: every
//! fd but the listeners is closed (the link is one of them — a child holding
//! it would keep the link open after wlandr is gone).

const std = @import("std");
const linux = std.os.linux;
const socket = @import("socket.zig");

/// How far `claim` looks (:0 … :31).
pub const max_display = 32;

/// A claimed X display: the lock file and the listening sockets.
pub const Display = struct {
    n: u32,
    unix_fd: i32,
    /// -1: no abstract socket (tests; a kernel without them).
    abstract_fd: i32 = -1,
    /// NUL-terminated paths.
    lock_buf: [64]u8 = @splat(0),
    sock_buf: [64]u8 = @splat(0),

    pub fn lockPath(self: *const Display) [*:0]const u8 {
        return @ptrCast(&self.lock_buf);
    }
    pub fn sockPath(self: *const Display) [*:0]const u8 {
        return @ptrCast(&self.sock_buf);
    }

    /// Stop listening and remove the socket and the lock. Idempotent.
    pub fn release(self: *Display) void {
        if (self.unix_fd < 0) return;
        _ = linux.close(self.unix_fd);
        if (self.abstract_fd >= 0) _ = linux.close(self.abstract_fd);
        self.unix_fd = -1;
        self.abstract_fd = -1;
        _ = linux.unlink(self.sockPath());
        _ = linux.unlink(self.lockPath());
    }
};

pub const Error = error{
    /// :0 … :31 all belong to live X servers.
    NoFreeDisplay,
    /// `<root>` isn't usable (not writable, no `.X11-unix`, bind failed).
    Unavailable,
};

/// Claim the first free display under `root` ("/tmp" for real). `abstract`
/// also binds the abstract socket, whose name is fixed (`/tmp/.X11-unix/X<n>`)
/// whatever `root` is — tests pass false.
pub fn claim(root: []const u8, abstract: bool) Error!Display {
    for (0..max_display) |n| {
        if (try tryClaim(root, @intCast(n), abstract)) |d| return d;
    }
    return error.NoFreeDisplay;
}

/// null: display `n` is someone's.
fn tryClaim(root: []const u8, n: u32, abstract: bool) Error!?Display {
    var d: Display = .{ .n = n, .unix_fd = -1 };
    const lock = std.fmt.bufPrintZ(&d.lock_buf, "{s}/.X{d}-lock", .{ root, n }) catch return error.Unavailable;
    const sock = std.fmt.bufPrintZ(&d.sock_buf, "{s}/.X11-unix/X{d}", .{ root, n }) catch return error.Unavailable;

    // the lock: created exclusively, holding the owner's pid. One left by a
    // dead server is replaced — unless its socket still answers (a server in
    // another pid namespace sharing this /tmp looks dead from here).
    var attempt: u32 = 0;
    const lock_fd: i32 = while (true) : (attempt += 1) {
        const rc = linux.open(lock, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o444);
        switch (linux.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .EXIST => {
                if (attempt > 0 or ownerAlive(lock) or socket.answers(sock)) return null;
                _ = linux.unlink(lock);
            },
            else => return error.Unavailable,
        }
    };
    var pid_buf: [16]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d:>10}\n", .{@as(u32, @intCast(linux.getpid()))}) catch unreachable;
    _ = linux.write(lock_fd, pid_text.ptr, pid_text.len);
    _ = linux.close(lock_fd);

    // a server that doesn't lock (-nolock): its socket is still its own
    if (socket.answers(sock)) {
        _ = linux.unlink(lock);
        return null;
    }
    var dir_buf: [64]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.X11-unix", .{root}) catch return error.Unavailable;
    if (linux.errno(linux.mkdir(dir, 0o1777)) == .SUCCESS) _ = linux.chmod(dir, 0o1777); // past the umask
    _ = linux.unlink(sock);

    var sa: linux.sockaddr.un = .{ .path = @splat(0) };
    const sock_len = sock.len;
    @memcpy(sa.path[0..sock_len], sock[0..sock_len]);
    d.unix_fd = listenOn(&sa, @sizeOf(linux.sockaddr.un)) orelse {
        _ = linux.unlink(lock);
        return error.Unavailable;
    };
    if (abstract) {
        // a leading NUL, then the name; the length counts exactly that
        var ab: linux.sockaddr.un = .{ .path = @splat(0) };
        const name = std.fmt.bufPrint(ab.path[1..], "/tmp/.X11-unix/X{d}", .{n}) catch unreachable;
        const len: u32 = @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + name.len);
        d.abstract_fd = listenOn(&ab, len) orelse {
            // taken by a server we couldn't see otherwise
            d.release();
            return null;
        };
    }
    return d;
}

fn listenOn(sa: *const linux.sockaddr.un, len: u32) ?i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    if (linux.errno(linux.bind(fd, @ptrCast(sa), len)) != .SUCCESS or
        linux.errno(linux.listen(fd, 16)) != .SUCCESS)
    {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// The pid written in an X lock file names a running process.
fn ownerAlive(lock: [*:0]const u8) bool {
    const rc = linux.open(lock, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return true; // unreadable: not ours to judge
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [32]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return true;
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..n], " \n"), 10) catch return false;
    var proc: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&proc, "/proc/{d}", .{pid}) catch return true;
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
}

/// `xwayland-satellite` on $PATH, as an absolute NUL-terminated path in `buf`.
pub fn findSatellite(path_env: []const u8, buf: []u8) ?[:0]const u8 {
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = std.fmt.bufPrintZ(buf, "{s}/xwayland-satellite", .{dir}) catch continue;
        if (linux.errno(linux.access(p, linux.X_OK)) == .SUCCESS) return p;
    }
    return null;
}

/// Starts satellite on demand, for the process lifetime. Everything the
/// child needs is prepared here, before any fork: between fork and exec only
/// raw syscalls run (the relay is multi-threaded).
pub const Launcher = struct {
    display: Display,
    /// satellite's path, then its arguments.
    argv: [7:null]?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    display_arg: [8]u8 = @splat(0),

    /// `bin` and `envp` must outlive the launcher (the process, in wlandr).
    pub fn init(self: *Launcher, display: Display, bin: [*:0]const u8, envp: [*:null]const ?[*:0]const u8) void {
        self.* = .{ .display = display, .argv = @splat(null), .envp = envp };
        _ = std.fmt.bufPrintZ(&self.display_arg, ":{d}", .{display.n}) catch unreachable;
        self.argv[0] = bin;
        self.argv[1] = @ptrCast(&self.display_arg);
        self.argv[2] = "-listenfd";
        self.argv[3] = "3";
        if (display.abstract_fd >= 0) {
            self.argv[4] = "-listenfd";
            self.argv[5] = "4";
        }
    }

    /// Thread body: wait for an X client, run satellite until it exits,
    /// repeat. A satellite that keeps dying at once (3 runs under 3 s each)
    /// is given up on, and the display released: X clients are then refused
    /// instead of left hanging.
    pub fn run(self: *Launcher) void {
        var quick_exits: u32 = 0;
        while (true) {
            var fds = [2]linux.pollfd{
                .{ .fd = self.display.unix_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.display.abstract_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const nfds: usize = if (self.display.abstract_fd >= 0) 2 else 1;
            switch (linux.errno(linux.poll(&fds, nfds, -1))) {
                .SUCCESS => {},
                .INTR => continue,
                else => |e| {
                    std.log.err("x11: poll failed ({t}); X11 apps are off", .{e});
                    return self.display.release();
                },
            }
            const started = monotonicMs();
            const pid = self.spawn() orelse {
                std.log.err("x11: cannot fork xwayland-satellite; X11 apps are off", .{});
                return self.display.release();
            };
            std.log.info("x11: an X client connected to :{d}; started xwayland-satellite (pid {d})", .{ self.display.n, pid });
            var status: u32 = 0;
            while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
            if (status & 0x7f == 0) {
                std.log.info("x11: xwayland-satellite exited (code {d})", .{(status >> 8) & 0xff});
            } else {
                std.log.info("x11: xwayland-satellite killed (signal {d})", .{status & 0x7f});
            }
            if (monotonicMs() - started < 3000) {
                quick_exits += 1;
                if (quick_exits >= 3) {
                    std.log.err("x11: xwayland-satellite keeps exiting at startup; X11 apps are off (is Xwayland installed?)", .{});
                    return self.display.release();
                }
                sleepMs(500);
            } else quick_exits = 0;
        }
    }

    /// fork + exec; the child's pid, or null if fork failed.
    fn spawn(self: *Launcher) ?linux.pid_t {
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) return null;
        if (rc != 0) return @intCast(rc);
        // --- the child: raw syscalls only ---
        // die with wlandr (a wayland client would notice anyway; this also
        // covers a satellite stuck before it connects)
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.TERM), 0, 0, 0);
        // the listeners become fds 3 and 4 (dup2 drops CLOEXEC); moved out
        // of the way first, in case one of them already is 3 or 4
        const a = linux.fcntl(self.display.unix_fd, linux.F.DUPFD, 10);
        _ = linux.dup2(@intCast(a), 3);
        var first_closed: i32 = 4;
        if (self.display.abstract_fd >= 0) {
            const b = linux.fcntl(self.display.abstract_fd, linux.F.DUPFD, 10);
            _ = linux.dup2(@intCast(b), 4);
            first_closed = 5;
        }
        _ = linux.close_range(first_closed, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false });
        _ = linux.execve(self.argv[0].?, &self.argv, self.envp);
        linux.exit_group(127);
    }
};

fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u32) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

fn tmpRoot(buf: []u8) ![:0]const u8 {
    const dir = try std.fmt.bufPrintZ(buf, "/tmp/wland-x11-test-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o700);
    return dir;
}

fn rmRoot(root: []const u8) void {
    var buf: [96]u8 = undefined;
    for (0..4) |n| {
        if (std.fmt.bufPrintZ(&buf, "{s}/.X{d}-lock", .{ root, n })) |p| _ = linux.unlink(p) else |_| {}
        if (std.fmt.bufPrintZ(&buf, "{s}/.X11-unix/X{d}", .{ root, n })) |p| _ = linux.unlink(p) else |_| {}
    }
    if (std.fmt.bufPrintZ(&buf, "{s}/.X11-unix", .{root})) |p| _ = linux.rmdir(p) else |_| {}
    if (std.fmt.bufPrintZ(&buf, "{s}", .{root})) |p| _ = linux.rmdir(p) else |_| {}
}

fn exists(path: [*:0]const u8) bool {
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
}

test "claim: the first free display, a lock holding our pid, a listening socket" {
    var buf: [64]u8 = undefined;
    const root = try tmpRoot(&buf);
    defer rmRoot(root);

    var a = try claim(root, false);
    try testing.expectEqual(@as(u32, 0), a.n);
    try testing.expect(ownerAlive(a.lockPath()));
    // what X servers write and read: "%10d\n"
    var text: [16]u8 = undefined;
    const lock_fd: i32 = @intCast(linux.open(a.lockPath(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    const len = linux.read(lock_fd, &text, text.len);
    _ = linux.close(lock_fd);
    var want: [16]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d:>10}\n", .{@as(u32, @intCast(linux.getpid()))}), text[0..len]);
    try testing.expectEqual(@as(usize, 11), len);
    try testing.expect(socket.answers(std.mem.span(a.sockPath())));
    // :0 is ours now: the next claim moves on
    var b = try claim(root, false);
    try testing.expectEqual(@as(u32, 1), b.n);

    a.release();
    try testing.expect(!exists(a.lockPath()) and !exists(a.sockPath()));
    a.release(); // idempotent
    b.release();
}

test "claim: a dead owner's lock is replaced; a live socket without a lock is left alone" {
    var buf: [64]u8 = undefined;
    const root = try tmpRoot(&buf);
    defer rmRoot(root);

    // :0 — a lock naming a pid that cannot exist
    var path: [96]u8 = undefined;
    const stale = try std.fmt.bufPrintZ(&path, "{s}/.X0-lock", .{root});
    const fd: i32 = @intCast(linux.open(stale, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o444));
    const text = "4194999999\n";
    _ = linux.write(fd, text.ptr, text.len);
    _ = linux.close(fd);
    var a = try claim(root, false);
    defer a.release();
    try testing.expectEqual(@as(u32, 0), a.n);

    // :1 — no lock, but something listens there (an X server run -nolock)
    var live: Display = .{ .n = 1, .unix_fd = -1 };
    var sa: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = try std.fmt.bufPrint(&sa.path, "{s}/.X11-unix/X1", .{root});
    live.unix_fd = listenOn(&sa, @sizeOf(linux.sockaddr.un)).?;
    defer _ = linux.close(live.unix_fd);
    var b = try claim(root, false);
    defer b.release();
    try testing.expectEqual(@as(u32, 2), b.n);
    var lock1: [96]u8 = undefined;
    try testing.expect(!exists(try std.fmt.bufPrintZ(&lock1, "{s}/.X1-lock", .{root}))); // backed off without a trace
}

test "claim: an unusable root is Unavailable" {
    try testing.expectError(error.Unavailable, claim("/nonexistent-wland-x11", false));
}
