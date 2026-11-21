// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Byte-stream link: any connected stream socket fd (socketpair, unix
//! socket, AF_VSOCK). A byte stream has no message boundaries, so each STREAM
//! message travels as a record: u32 LE length + the message (STREAM.md
//! "Stream transport"). The link never closes the fd; its owner does, after
//! serveLink returns.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const stream = @import("core").stream;
const Link = @import("link.zig").Link;

pub const StreamLink = struct {
    io: Io,
    fd: i32,
    /// Serializes writers so records never interleave.
    write_mutex: Io.Mutex = .init,
    link: Link,

    /// In place: the embedded Link points back at `self`. Frame callbacks
    /// default to the engine (see main.zig's --link help for why).
    pub fn init(self: *StreamLink, io: Io, fd: i32, frame_callbacks: Link.FrameCallbacks) void {
        self.* = .{ .io = io, .fd = fd, .link = .{
            .ctx = self,
            .vtable = &vtable,
            .frame_callbacks = frame_callbacks,
        } };
    }

    const vtable: Link.VTable = .{ .send = send, .recv = recv, .kick = kick };

    fn send(ctx: *anyopaque, msg: []const u8) Link.SendError!void {
        const self: *StreamLink = @ptrCast(@alignCast(ctx));
        if (msg.len > stream.max_record_len) { // the peer would fail the whole link on it
            std.log.err("stream link: a {d} B frame exceeds the record bound; not sent", .{msg.len});
            return error.LinkGone;
        }
        var hdr: [stream.record_header_len]u8 = undefined;
        stream.writeRecordHeader(&hdr, @intCast(msg.len));
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        sendAll(self.fd, &.{ &hdr, msg }) catch return error.LinkGone;
    }

    fn recv(ctx: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Link.RecvError!void {
        const self: *StreamLink = @ptrCast(@alignCast(ctx));
        var hdr: [stream.record_header_len]u8 = undefined;
        if (!try readExact(self.fd, &hdr)) return error.EndOfStream;
        const len = stream.readRecordHeader(&hdr) catch {
            std.log.err("stream link: bad record length {d}", .{std.mem.readInt(u32, &hdr, .little)});
            return error.LinkGone;
        };
        try out.resize(gpa, len);
        if (!try readExact(self.fd, out.items)) {
            std.log.err("stream link: closed mid-record", .{});
            return error.LinkGone;
        }
    }

    fn kick(ctx: *anyopaque) void {
        const self: *StreamLink = @ptrCast(@alignCast(ctx));
        _ = linux.shutdown(self.fd, linux.SHUT.RDWR);
    }
};

/// Fill `buf` completely. False on a clean EOF before the first byte.
fn readExact(fd: i32, buf: []u8) error{LinkGone}!bool {
    var got: usize = 0;
    while (got < buf.len) {
        const rc = linux.read(fd, buf.ptr + got, buf.len - got);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    if (got == 0) return false;
                    return error.LinkGone;
                }
                got += rc;
            },
            .INTR => continue,
            .CONNRESET => if (got == 0) return false else return error.LinkGone,
            else => |e| {
                std.log.err("stream link read: {t}", .{e});
                return error.LinkGone;
            },
        }
    }
    return true;
}

/// sendmsg every byte of `parts` (MSG_NOSIGNAL: a dead peer is an error, not
/// a SIGPIPE).
fn sendAll(fd: i32, parts: []const []const u8) error{WriteFailed}!void {
    var iov: [2]std.posix.iovec_const = undefined;
    std.debug.assert(parts.len <= iov.len);
    for (parts, 0..) |p, i| iov[i] = .{ .base = p.ptr, .len = p.len };
    var first: usize = 0;
    while (first < parts.len) {
        if (iov[first].len == 0) {
            first += 1;
            continue;
        }
        const msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = iov[first..parts.len].ptr,
            .iovlen = parts.len - first,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const rc = linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                // advance past what was written
                var n: usize = rc;
                while (n > 0) {
                    const take = @min(n, iov[first].len);
                    iov[first].base += take;
                    iov[first].len -= take;
                    n -= take;
                    if (iov[first].len == 0) first += 1;
                }
            },
            .INTR, .AGAIN => continue,
            .PIPE, .CONNRESET => return error.WriteFailed, // peer gone: expected
            else => |e| {
                std.log.err("stream link write: {t}", .{e});
                return error.WriteFailed;
            },
        }
    }
}

test "records round-trip over a socketpair, including a partial-read split" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    var a: StreamLink = undefined;
    a.init(threaded.io(), fds[0], .engine);
    var b: StreamLink = undefined;
    b.init(threaded.io(), fds[1], .engine);

    try a.link.send("hello");
    try a.link.send(&[_]u8{0xab} ** 3000);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try b.link.recv(gpa, &out);
    try std.testing.expectEqualStrings("hello", out.items);
    try b.link.recv(gpa, &out);
    try std.testing.expectEqual(@as(usize, 3000), out.items.len);

    // a record written in two pieces still arrives whole
    var hdr: [4]u8 = undefined;
    stream.writeRecordHeader(&hdr, 4);
    try sendAll(fds[0], &.{ &hdr, "ab" });
    try sendAll(fds[0], &.{"cd"});
    try b.link.recv(gpa, &out);
    try std.testing.expectEqualStrings("abcd", out.items);

    // kick: the peer sees an orderly close, later sends fail
    a.link.kick();
    try std.testing.expectError(error.EndOfStream, b.link.recv(gpa, &out));
    try std.testing.expectError(error.LinkGone, a.link.send("late"));
}
