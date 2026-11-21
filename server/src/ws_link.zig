// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Browser WebSocket link (server.zig upgrades /ws and serves it). One WS
//! message = one STREAM message. Browsers fragment large messages, so reads
//! do their own RFC6455 reassembly (std's readSmallMessage rejects
//! continuation frames).

const std = @import("std");
const Io = std.Io;
const Link = @import("link.zig").Link;

const WebSocket = std.http.Server.WebSocket;

pub const WsLink = struct {
    io: Io,
    ws: *WebSocket,
    /// The underlying TCP stream, so kick can shut it down and wake recv.
    net: Io.net.Stream,
    /// Serializes every write to the socket: app threads' sends, recv's
    /// pongs, kick's close frame.
    write_mutex: Io.Mutex = .init,
    link: Link,

    /// In place: the embedded Link points back at `self`.
    pub fn init(self: *WsLink, io: Io, ws: *WebSocket, net: Io.net.Stream) void {
        self.* = .{ .io = io, .ws = ws, .net = net, .link = .{
            .ctx = self,
            .vtable = &vtable,
            .frame_callbacks = .relay,
        } };
    }

    const vtable: Link.VTable = .{ .send = send, .recv = recv, .kick = kick };

    fn send(ctx: *anyopaque, msg: []const u8) Link.SendError!void {
        const self: *WsLink = @ptrCast(@alignCast(ctx));
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.ws.writeMessage(msg, .binary) catch return error.LinkGone;
    }

    /// Politely close a tab that is being taken over, then force its read
    /// loop awake. 4000 is our private close code; the page shows "taken
    /// over" and does NOT auto-reload (a reload would steal the session back).
    ///
    /// Never blocks: a tab that stopped reading (its TCP window full) leaves
    /// an app thread blocked in send while holding `write_mutex` — only the
    /// shutdown frees it — and would block a close frame written the normal
    /// way too. So the close frame is best effort: sent without waiting, and
    /// only when no message is half written; that tab may then see a plain
    /// disconnect instead of "taken over".
    fn kick(ctx: *anyopaque) void {
        const self: *WsLink = @ptrCast(@alignCast(ctx));
        if (self.write_mutex.tryLock()) {
            if (self.ws.output.end == 0) {
                const close_frame = "\x88\x0a\x0f\xa0takeover"; // FIN|close, len 10, code 4000
                _ = std.os.linux.sendto(self.net.socket.handle, close_frame, close_frame.len, std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL, null, 0);
            }
            self.write_mutex.unlock(self.io);
        }
        self.net.shutdown(self.io, .both) catch {};
    }

    fn recv(ctx: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Link.RecvError!void {
        const self: *WsLink = @ptrCast(@alignCast(ctx));
        while (true) {
            const opcode = self.readMessage(gpa, out) catch |err| switch (err) {
                error.ConnectionClose, error.EndOfStream, error.ReadFailed => return error.EndOfStream,
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    std.log.err("browser ws: {t}", .{err});
                    return error.LinkGone;
                },
            };
            if (opcode == .binary) return; // text messages carry nothing for us
        }
    }

    /// RFC6455 read with fragmentation support — browsers may split any
    /// message into continuation frames (Chrome does for large sends).
    /// Control frames interleaved between fragments are handled here. The
    /// reassembled payload lands in `out`.
    fn readMessage(self: *WsLink, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !WebSocket.Opcode {
        const in = self.ws.input;
        out.clearRetainingCapacity();
        var msg_opcode: ?WebSocket.Opcode = null;

        while (true) {
            const hdr = try in.takeArray(2);
            const h0: WebSocket.Header0 = @bitCast(hdr[0]);
            const h1: WebSocket.Header1 = @bitCast(hdr[1]);
            const len: u64 = switch (h1.payload_len) {
                .len16 => try in.takeInt(u16, .big),
                .len64 => try in.takeInt(u64, .big),
                else => @intFromEnum(h1.payload_len),
            };
            if (!h1.mask) return error.MissingMaskBit;
            const mask = (try in.takeArray(4)).*;

            switch (h0.opcode) {
                .connection_close => return error.ConnectionClose,
                .ping, .pong => {
                    if (len > 125) return error.ProtocolViolation;
                    var control_buf: [125]u8 = undefined;
                    const payload = try in.take(@intCast(len));
                    for (payload, 0..) |b, i| control_buf[i] = b ^ mask[i & 3];
                    if (h0.opcode == .ping) {
                        self.write_mutex.lockUncancelable(self.io);
                        defer self.write_mutex.unlock(self.io);
                        try self.ws.writeMessage(control_buf[0..payload.len], .pong);
                    }
                    continue;
                },
                .binary, .text => {
                    if (msg_opcode != null) return error.ProtocolViolation;
                    msg_opcode = h0.opcode;
                },
                .continuation => {
                    if (msg_opcode == null) return error.ProtocolViolation;
                },
                _ => return error.ProtocolViolation,
            }

            // stream the payload out of the reader in whatever chunks are buffered
            var remaining = len;
            var mask_idx: usize = 0;
            while (remaining > 0) {
                if (in.bufferedLen() == 0) try in.fill(1);
                const avail = in.buffered();
                const chunk_len: usize = @intCast(@min(remaining, avail.len));
                try out.ensureUnusedCapacity(gpa, chunk_len);
                for (avail[0..chunk_len]) |b| {
                    out.appendAssumeCapacity(b ^ mask[mask_idx & 3]);
                    mask_idx += 1;
                }
                in.toss(chunk_len);
                remaining -= chunk_len;
            }
            if (h0.fin) return msg_opcode.?;
        }
    }
};

test "kick returns while an app thread is stuck sending to a tab that stopped reading" {
    const gpa = std.testing.allocator;
    const linux = std.os.linux;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]); // the tab: never reads
    const net: Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var rbuf: [64]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = net.reader(io, &rbuf);
    var writer = net.writer(io, &wbuf);
    var ws: WebSocket = .{ .key = "", .input = &reader.interface, .output = &writer.interface };
    var link: WsLink = undefined;
    link.init(io, &ws, net);

    // an app thread fills the socket and blocks mid-message, holding the write lock
    const big = try gpa.alloc(u8, 8 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 0x5a);
    const Sender = struct {
        fn run(l: *Link, msg: []const u8, failed: *std.atomic.Value(bool)) void {
            l.send(msg) catch failed.store(true, .release);
        }
    };
    var send_failed: std.atomic.Value(bool) = .init(false);
    const sender = try std.Thread.spawn(.{}, Sender.run, .{ &link.link, big, &send_failed });
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    const Kicker = struct {
        fn run(l: *Link, done: *std.atomic.Value(bool)) void {
            l.kick();
            done.store(true, .release);
        }
    };
    var kicked: std.atomic.Value(bool) = .init(false);
    const kicker = try std.Thread.spawn(.{}, Kicker.run, .{ &link.link, &kicked });
    var waited: u32 = 0;
    while (!kicked.load(.acquire) and waited < 2000) : (waited += 10) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    const kick_returned = kicked.load(.acquire);
    if (!kick_returned) _ = linux.shutdown(fds[0], linux.SHUT.RDWR); // unwedge, then fail
    kicker.join();
    sender.join();
    try std.testing.expect(kick_returned);
    try std.testing.expect(send_failed.load(.acquire)); // the stuck send was woken, not left hanging
}

test "kick on a healthy link sends close code 4000 first" {
    const linux = std.os.linux;
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    const net: Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var rbuf: [64]u8 = undefined;
    var wbuf: [64]u8 = undefined;
    var reader = net.reader(io, &rbuf);
    var writer = net.writer(io, &wbuf);
    var ws: WebSocket = .{ .key = "", .input = &reader.interface, .output = &writer.interface };
    var link: WsLink = undefined;
    link.init(io, &ws, net);
    link.link.kick();
    var got: [32]u8 = undefined;
    const n = linux.read(fds[1], &got, got.len);
    try std.testing.expectEqualSlices(u8, "\x88\x0a\x0f\xa0takeover", got[0..n]);
}
