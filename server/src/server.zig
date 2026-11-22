// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! HTTP side of the native server: serves the built web client and upgrades
//! /ws to a WebSocket link into the relay (one tab at a time; the newest
//! takes over). Binding is separate from serving so address errors surface
//! before any thread starts. Not compiled into a -Dhttp=false relay.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const core = @import("core");
const relay_mod = @import("relay.zig");
const WsLink = @import("ws_link.zig").WsLink;
const Session = @import("session.zig").Session;

pub const Options = struct {
    /// Where HTTP listens: loopback unless asked (`--host`). Port 0: the
    /// kernel picks one.
    address: Io.net.IpAddress = .{ .ip4 = .loopback(8080) },
    /// Directory served over HTTP — the built web client (vite dist output).
    web_root: []const u8 = "dist",
    /// --profile session: each /ws link is a viewer of this host, not the
    /// relay's engine
    session: ?*Session = null,
};

/// Listen on `address` (IPv4 or IPv6; default 127.0.0.1, see `--host`) with
/// SO_REUSEADDR only: a restart binds over TIME_WAIT connections, but a port
/// another process listens on fails with AddressInUse. (std's
/// `reuse_address` also sets SO_REUSEPORT, which let a second wlandr bind
/// the same port and silently take half the connections.)
/// Port 0: the kernel picks one; the returned address carries it.
pub fn listen(address: Io.net.IpAddress) !Io.net.Server {
    const Sa = extern union { in: linux.sockaddr.in, in6: linux.sockaddr.in6 };
    var sa: Sa = undefined;
    const family: u32, const sa_len: linux.socklen_t = switch (address) {
        .ip4 => |a| blk: {
            sa = .{ .in = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) } };
            break :blk .{ linux.AF.INET, @sizeOf(linux.sockaddr.in) };
        },
        .ip6 => |a| blk: {
            sa = .{ .in6 = .{ .port = std.mem.nativeToBig(u16, a.port), .flowinfo = 0, .addr = a.bytes, .scope_id = 0 } };
            break :blk .{ linux.AF.INET6, @sizeOf(linux.sockaddr.in6) };
        },
    };
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int));
    switch (linux.errno(linux.bind(fd, @ptrCast(&sa), sa_len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ACCES => return error.AccessDenied,
        .ADDRNOTAVAIL => return error.AddressUnavailable, // not one of this host's addresses
        else => return error.BindFailed,
    }
    if (linux.errno(linux.listen(fd, Io.net.default_kernel_backlog)) != .SUCCESS) return error.ListenFailed;
    var len: linux.socklen_t = sa_len;
    if (linux.errno(linux.getsockname(fd, @ptrCast(&sa), &len)) != .SUCCESS) return error.ListenFailed;
    var bound = address;
    bound.setPort(std.mem.bigToNative(u16, switch (address) {
        .ip4 => sa.in.port,
        .ip6 => sa.in6.port,
    }));
    return .{ .socket = .{ .handle = fd, .address = bound }, .options = {} };
}

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    relay: *relay_mod.Relay,
    web_root: []const u8,
    listener: Io.net.Server,
    session: ?*Session = null,

    /// Heap-allocated because connection threads keep the pointer forever;
    /// a Server is never freed once serving starts.
    pub fn create(gpa: std.mem.Allocator, io: Io, relay: *relay_mod.Relay, opts: Options) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        const web_root = try gpa.dupe(u8, opts.web_root);
        errdefer gpa.free(web_root);
        const listener = try listen(opts.address);
        self.* = .{ .gpa = gpa, .io = io, .relay = relay, .web_root = web_root, .listener = listener, .session = opts.session };
        // the actual port (--port 0): lib/index.ts startServer reads it here
        std.log.info("wlandr (core v{d}) listening on http://{f}", .{ core.version, listener.socket.address });
        return self;
    }

    /// HTTP+WS accept loop (blocks forever).
    pub fn serve(self: *Server) void {
        while (true) {
            const stream = self.listener.accept(self.io) catch |err| {
                std.log.err("accept failed: {t}", .{err});
                continue;
            };
            setTcpNoDelay(stream);
            const thread = std.Thread.spawn(.{}, handleConn, .{ self, stream }) catch |err| {
                std.log.err("spawn failed: {t}", .{err});
                stream.close(self.io);
                continue;
            };
            thread.detach();
        }
    }
};

/// Disable Nagle's algorithm on an accepted browser TCP socket. wland's WS
/// traffic is many tiny writes (key/pointer events, configures, frame-done)
/// against delayed ACKs — exactly what Nagle punishes with sporadic ~40 ms
/// stalls over real links (loopback hides it). Best effort: a failure just
/// leaves Nagle on. The wayland unix socket has no Nagle and is untouched.
fn setTcpNoDelay(stream: Io.net.Stream) void {
    const one: c_int = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch |err| std.log.warn("TCP_NODELAY failed: {t}", .{err});
}

fn handleConn(server: *Server, stream: Io.net.Stream) void {
    const io = server.io;
    defer stream.close(io);
    // recv must fit the largest browser→server WS message (keymap FDMSG ~68K)
    var recv_buf: [256 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch return;
        switch (request.upgradeRequested()) {
            .websocket => |key| {
                if (!originAllowed(&request)) {
                    request.respond("cross-origin WebSocket refused\n", .{ .status = .forbidden, .keep_alive = false }) catch {};
                    return;
                }
                var ws = request.respondWebSocket(.{ .key = key orelse return }) catch return;
                ws.flush() catch return;
                var link: WsLink = undefined;
                link.init(io, &ws, stream);
                // returns once no relay (or session) thread can touch
                // `link` (or `ws`)
                // (comptime: -Dsession=false never compiles the host)
                if (@import("build_options").session) {
                    if (server.session) |s| {
                        s.serveViewer(&link.link);
                        return;
                    }
                }
                relay_mod.serveLink(server.relay, &link.link);
                return;
            },
            .other => return,
            .none => serveStatic(server, &request) catch return,
        }
    }
}

/// The session is the user's desktop (every keystroke, the clipboard, input
/// injection), and browsers let any page open a WebSocket to 127.0.0.1. So a
/// /ws upgrade from a page must come from a page this server served: its
/// Origin names the host the request is addressed to (`Host`; the vite dev
/// proxy forwards both unchanged, so it passes too). No Origin at all is a
/// non-browser client (a page can't omit it), and is allowed.
fn originAllowed(request: *const std.http.Server.Request) bool {
    var origin: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
    }
    return sameOrigin(origin, host);
}

fn sameOrigin(origin: ?[]const u8, host: ?[]const u8) bool {
    const o = origin orelse return true;
    const h = host orelse return false;
    const sep = std.mem.indexOf(u8, o, "://") orelse return false; // includes "null"
    return std.ascii.eqlIgnoreCase(o[sep + 3 ..], h);
}

const StaticFile = struct { path: []const u8, content_type: []const u8 };

fn contentType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot..];
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "text/javascript";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".json") or std.mem.eql(u8, ext, ".map")) return "application/json";
    return "application/octet-stream";
}

// Any file under web_root: vite emits hashed asset names, so a static
// allowlist can't work. Rooted + ".."-free keeps requests inside the dir.
fn resolveStatic(buf: []u8, web_root: []const u8, target: []const u8) ?StaticFile {
    var path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;
    if (std.mem.eql(u8, path, "/")) path = "/index.html";
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    const full = std.fmt.bufPrint(buf, "{s}{s}", .{ web_root, path }) catch return null;
    return .{ .path = full, .content_type = contentType(full) };
}

fn serveStatic(server: *Server, request: *std.http.Server.Request) !void {
    var path_buf: [1024]u8 = undefined;
    const file = resolveStatic(&path_buf, server.web_root, request.head.target) orelse {
        try request.respond("not found\n", .{ .status = .not_found });
        return;
    };
    const body = Io.Dir.cwd().readFileAlloc(server.io, file.path, server.gpa, .limited(64 * 1024 * 1024)) catch {
        try request.respond("not found (build web/ first: cd web && bun install && bun run build)\n", .{ .status = .not_found });
        return;
    };
    defer server.gpa.free(body);
    try request.respond(body, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = file.content_type },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn tcpNoDelaySet(stream: Io.net.Stream) bool {
    var val: c_int = -1;
    var len: std.posix.socklen_t = @sizeOf(c_int);
    const rc = std.os.linux.getsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&val),
        &len,
    );
    return std.os.linux.errno(rc) == .SUCCESS and val != 0;
}

test "setTcpNoDelay disables Nagle on an accepted TCP socket" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) }; // ephemeral port
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    // loopback connect lands in the accept backlog immediately, so a single
    // thread can connect then accept without deadlocking.
    var client = try Io.net.IpAddress.connect(&listener.socket.address, io, .{ .mode = .stream });
    defer client.close(io);
    var accepted = try listener.accept(io);
    defer accepted.close(io);

    try std.testing.expect(!tcpNoDelaySet(accepted)); // Nagle on by default
    setTcpNoDelay(accepted);
    try std.testing.expect(tcpNoDelaySet(accepted)); // now off
}

test "resolveStatic maps routes" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("web/dist/index.html", resolveStatic(&buf, "web/dist", "/").?.path);
    try std.testing.expectEqualStrings("web/dist/index.html", resolveStatic(&buf, "web/dist", "/index.html?x=1").?.path);
    const wasm = resolveStatic(&buf, "web/dist", "/wland.wasm").?;
    try std.testing.expectEqualStrings("web/dist/wland.wasm", wasm.path);
    try std.testing.expectEqualStrings("application/wasm", wasm.content_type);
    const js = resolveStatic(&buf, "web/dist", "/assets/index-CqB3xzZ0.js").?;
    try std.testing.expectEqualStrings("web/dist/assets/index-CqB3xzZ0.js", js.path);
    try std.testing.expectEqualStrings("text/javascript", js.content_type);
    // the package's own page imports dist/*.mjs (module scripts need a JS type)
    try std.testing.expectEqualStrings("text/javascript", resolveStatic(&buf, "dist", "/client.mjs").?.content_type);
    try std.testing.expectEqual(@as(?StaticFile, null), resolveStatic(&buf, "web/dist", "/../build.zig"));
    try std.testing.expectEqual(@as(?StaticFile, null), resolveStatic(&buf, "web/dist", "etc/passwd"));
    // absolute web_root, as the npm CLI passes
    try std.testing.expectEqualStrings("/opt/pkg/dist/index.html", resolveStatic(&buf, "/opt/pkg/dist", "/").?.path);
}

test "sameOrigin: the page's origin must name the host it talks to" {
    try std.testing.expect(sameOrigin(null, "127.0.0.1:8080")); // not a browser
    try std.testing.expect(sameOrigin("http://localhost:8080", "localhost:8080"));
    try std.testing.expect(sameOrigin("https://LocalHost:5173", "localhost:5173")); // vite proxy
    try std.testing.expect(!sameOrigin("https://evil.example", "127.0.0.1:8080"));
    try std.testing.expect(!sameOrigin("http://localhost:8081", "localhost:8080"));
    try std.testing.expect(!sameOrigin("http://127.0.0.1:8080", "localhost:8080"));
    try std.testing.expect(!sameOrigin("null", "localhost:8080")); // opaque origins
    try std.testing.expect(!sameOrigin("http://localhost:8080", null));
}

/// One /ws upgrade against handleConn over a real loopback TCP socket;
/// returns the response's status line.
fn upgradeStatus(origin: ?[]const u8, buf: []u8) ![]const u8 {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var relay: relay_mod.Relay = .{ .io = io, .gpa = gpa };
    defer relay.deinit();

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var server: Server = .{ .gpa = gpa, .io = io, .relay = &relay, .web_root = "web/dist", .listener = listener };
    var client = try Io.net.IpAddress.connect(&listener.socket.address, io, .{ .mode = .stream });
    defer client.close(io);
    const accepted = try listener.accept(io);
    const thread = try std.Thread.spawn(.{}, handleConn, .{ &server, accepted });

    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /ws HTTP/1.1\r\nHost: localhost:8080\r\n{s}{s}{s}" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n", .{
        if (origin != null) "Origin: " else "", origin orelse "", if (origin != null) "\r\n" else "",
    });
    const fd = client.socket.handle;
    if (std.os.linux.write(fd, req.ptr, req.len) != req.len) return error.WriteFailed;
    var got: usize = 0;
    while (std.mem.indexOf(u8, buf[0..got], "\r\n") == null) {
        const rc = std.os.linux.read(fd, buf[got..].ptr, buf.len - got);
        if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) return error.ReadFailed;
        got += rc;
    }
    // hang up: an accepted link's serveLink sees EOF and returns
    _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.RDWR);
    thread.join();
    return buf[0..std.mem.indexOf(u8, buf[0..got], "\r\n").?];
}

test "/ws refuses a cross-origin upgrade, accepts a same-origin or Origin-less one" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("HTTP/1.1 403 Forbidden", try upgradeStatus("https://evil.example", &buf));
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols", try upgradeStatus("http://localhost:8080", &buf));
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols", try upgradeStatus(null, &buf));
}

test "listen: port 0 picks one; a port in use fails instead of being shared" {
    var a = try listen(.{ .ip4 = .loopback(0) });
    defer a.socket.close(std.testing.io);
    const port = a.socket.address.getPort();
    try std.testing.expect(port != 0);
    try std.testing.expectError(error.AddressInUse, listen(.{ .ip4 = .loopback(port) }));
    // a closed listener's port binds again at once (SO_REUSEADDR)
    var b = try listen(.{ .ip4 = .loopback(0) });
    const port_b = b.socket.address.getPort();
    b.socket.close(std.testing.io);
    var c = try listen(.{ .ip4 = .loopback(port_b) });
    c.socket.close(std.testing.io);
}

test "listen: other addresses (--host), and the log's URL form" {
    var buf: [64]u8 = undefined;
    var any = try listen(.{ .ip4 = .unspecified(0) });
    defer any.socket.close(std.testing.io);
    try std.testing.expect(any.socket.address.getPort() != 0);
    try std.testing.expectEqualStrings("0.0.0.0:", (try std.fmt.bufPrint(&buf, "{f}", .{any.socket.address}))[0..8]);
    // IPv6 where the kernel has it (containers may not)
    if (listen(.{ .ip6 = .loopback(0) })) |v6| {
        var s = v6;
        defer s.socket.close(std.testing.io);
        try std.testing.expect(s.socket.address.getPort() != 0);
        try std.testing.expectEqualStrings("[::1]:", (try std.fmt.bufPrint(&buf, "{f}", .{s.socket.address}))[0..6]);
    } else |_| {}
    // TEST-NET-1: not an address of this host
    try std.testing.expectError(error.AddressUnavailable, listen(.{ .ip4 = .{ .bytes = .{ 192, 0, 2, 1 }, .port = 0 } }));
}
