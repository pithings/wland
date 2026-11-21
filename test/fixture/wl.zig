// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! A minimal Wayland client: the wire codec and the generated protocol
//! tables from core, plain Linux syscalls for the socket, fds and shm. No
//! libwayland. Strict where libwayland-client is: an event for an object
//! that never existed, an unknown opcode or a message whose size does not
//! match its signature ends the client, as does wl_display.error.
//!
//! WAYLAND_DEBUG=1 (or `client`) logs every request and event to stderr in
//! libwayland's format (`[ms] wl_pointer#12.motion(…)`), so a test that
//! reads a real app's protocol log reads a fixture's the same way.

const std = @import("std");
const linux = std.os.linux;
const core = @import("core");
const wire = core.wire;
const protocol = core.protocol;

pub const Value = wire.Value;
pub const Interface = protocol.Interface;

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "wland-fixture: " ++ fmt ++ "\n", args) catch "wland-fixture: (message too long)\n";
    writeFd(2, s);
    linux.exit_group(1);
}

pub fn writeFd(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR, .AGAIN => continue,
            else => return,
        }
    }
}

/// A line on stdout (what the tests read), written at once.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    writeFd(1, std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return);
}

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn nowMs() u64 {
    return nowNs() / std.time.ns_per_ms;
}

pub fn fixed(v: f64) i32 {
    return @intFromFloat(@round(v * 256.0));
}

pub fn fromFixed(v: i32) f64 {
    return @as(f64, @floatFromInt(v)) / 256.0;
}

pub fn iface(comptime name: []const u8) *const Interface {
    return comptime protocol.find(name) orelse @compileError("no interface " ++ name);
}

pub fn requestOp(comptime i: []const u8, comptime name: []const u8) u16 {
    return comptime iface(i).requestIndex(name) orelse @compileError("no request " ++ i ++ "." ++ name);
}

/// An event as the mode sees it: args decoded by the object's interface.
pub const Event = struct {
    id: u32,
    iface: *const Interface,
    opcode: u16,
    args: []const Value,
    /// the fd an fd-typed arg carried (-1: none); the receiver owns it
    fd: i32 = -1,

    pub fn is(ev: Event, comptime i: []const u8, comptime name: []const u8) bool {
        const want = comptime iface(i);
        const op = comptime (iface(i).eventIndex(name) orelse @compileError("no event " ++ i ++ "." ++ name));
        return ev.iface == want and ev.opcode == op;
    }
    pub fn uint(ev: Event, n: usize) u32 {
        return switch (ev.args[n]) {
            .uint => |v| v,
            .object => |v| v,
            .new_id => |v| v,
            .int => |v| @bitCast(v),
            else => unreachable,
        };
    }
    pub fn int(ev: Event, n: usize) i32 {
        return switch (ev.args[n]) {
            .int => |v| v,
            .fixed => |v| v,
            .uint => |v| @bitCast(v),
            else => unreachable,
        };
    }
    pub fn num(ev: Event, n: usize) f64 {
        return fromFixed(ev.args[n].fixed);
    }
    pub fn str(ev: Event, n: usize) []const u8 {
        return ev.args[n].string orelse "";
    }
    pub fn array(ev: Event, n: usize) []const u8 {
        return ev.args[n].array;
    }
};

const max_fds = 28;

pub const Client = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    sigfd: i32,
    debug: bool,
    next_id: u32 = 2,
    /// live objects (and zombies: destroyed by us, awaiting delete_id)
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    globals: std.ArrayList(Global) = .empty,
    registry: u32 = 0,

    rx: [64 * 1024]u8 = undefined,
    fill: usize = 0,
    rx_fds: [max_fds]i32 = undefined,
    n_rx_fds: usize = 0,
    tx: std.ArrayList(u8) = .empty,
    tx_fds: [max_fds]i32 = undefined,
    n_tx_fds: usize = 0,
    /// set by SIGINT/SIGTERM (through the signalfd)
    signalled: ?u32 = null,

    pub const Object = struct { iface: *const Interface, zombie: bool = false };
    pub const Global = struct { name: u32, interface: []const u8, version: u32 };

    /// Connect as libwayland does: $WAYLAND_DISPLAY (absolute, or under
    /// $XDG_RUNTIME_DIR; default wayland-0). SIGINT/SIGTERM are blocked and
    /// read through a signalfd, so a mode can wind down on them.
    pub fn connect(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !*Client {
        const display = environ.get("WAYLAND_DISPLAY") orelse "wayland-0";
        var path_buf: [108]u8 = @splat(0);
        const path = if (display.len > 0 and display[0] == '/')
            display
        else
            std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ environ.get("XDG_RUNTIME_DIR") orelse fail("XDG_RUNTIME_DIR is not set", .{}), display }) catch fail("socket path too long", .{});
        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
        if (path.len >= addr.path.len) fail("socket path too long: {s}", .{path});
        @memcpy(addr.path[0..path.len], path);
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) fail("socket failed", .{});
        const fd: i32 = @intCast(rc);
        if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) fail("cannot connect to {s}", .{path});

        var set = linux.sigemptyset();
        linux.sigaddset(&set, .INT);
        linux.sigaddset(&set, .TERM);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &set, null);
        const sfd = linux.signalfd(-1, &set, linux.SFD.CLOEXEC);

        const c = try gpa.create(Client);
        const debug = if (environ.get("WAYLAND_DEBUG")) |v| std.mem.eql(u8, v, "1") or std.mem.indexOf(u8, v, "client") != null else false;
        c.* = .{ .gpa = gpa, .fd = fd, .sigfd = @intCast(sfd), .debug = debug };
        try c.objects.put(gpa, 1, .{ .iface = iface("wl_display") });
        return c;
    }

    /// A new client-side object of interface `name`.
    pub fn new(c: *Client, comptime name: []const u8) u32 {
        const id = c.next_id;
        c.next_id += 1;
        c.objects.put(c.gpa, id, .{ .iface = iface(name) }) catch fail("out of memory", .{});
        return id;
    }

    /// Queue a request. A `.fd` arg takes the next of `fds`.
    pub fn send(c: *Client, id: u32, comptime i: []const u8, comptime name: []const u8, args: []const Value) void {
        c.sendFds(id, i, name, args, &.{});
    }

    pub fn sendFds(c: *Client, id: u32, comptime i: []const u8, comptime name: []const u8, args: []const Value, fds: []const i32) void {
        const opcode = comptime requestOp(i, name);
        var buf: [4096]u8 = undefined;
        const msg = wire.encodeMessage(&buf, id, opcode, args);
        c.tx.appendSlice(c.gpa, msg) catch fail("out of memory", .{});
        for (fds) |f| {
            if (c.n_tx_fds == max_fds) c.flush();
            c.tx_fds[c.n_tx_fds] = f;
            c.n_tx_fds += 1;
        }
        if (c.debug) c.log(" -> ", id, iface(i), iface(i).requests[opcode], args, fds);
        const m = iface(i).requests[opcode];
        if (m.destructor) {
            if (c.objects.getPtr(id)) |o| o.zombie = true;
        }
        if (c.tx.items.len > 32 * 1024) c.flush();
    }

    /// Destroy an object with its destructor request (`destroy` unless named).
    pub fn destroy(c: *Client, id: u32, comptime i: []const u8) void {
        c.send(id, i, "destroy", &.{});
    }

    pub fn flush(c: *Client) void {
        var off: usize = 0;
        while (off < c.tx.items.len) {
            var iov = [1]std.posix.iovec_const{.{ .base = c.tx.items.ptr + off, .len = c.tx.items.len - off }};
            const space = comptime cmsgAlign(@sizeOf(linux.cmsghdr));
            var cbuf: [space + max_fds * 4]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
            var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            if (c.n_tx_fds > 0) {
                const cm: *linux.cmsghdr = @ptrCast(&cbuf);
                cm.* = .{ .len = space + c.n_tx_fds * 4, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
                @memcpy(cbuf[space..][0 .. c.n_tx_fds * 4], std.mem.sliceAsBytes(c.tx_fds[0..c.n_tx_fds]));
                msg.control = &cbuf;
                msg.controllen = space + c.n_tx_fds * 4;
            }
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    off += rc;
                    c.n_tx_fds = 0;
                },
                .INTR => continue,
                .AGAIN => {
                    var p = [1]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&p, 1, 1000);
                },
                else => fail("the compositor hung up", .{}),
            }
        }
        c.tx.clearRetainingCapacity();
    }

    fn cmsgAlign(len: usize) usize {
        return std.mem.alignForward(usize, len, @sizeOf(usize));
    }

    /// Wait up to `timeout_ms` (-1: forever) for events or a signal and
    /// dispatch what arrived to `ctx.onEvent(ev)`. Returns false on a signal.
    pub fn dispatch(c: *Client, ctx: anytype, timeout_ms: i32) bool {
        c.flush();
        var p = [2]linux.pollfd{
            .{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = c.sigfd, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&p, 2, timeout_ms);
        if (linux.errno(rc) == .INTR) return true;
        if (p[1].revents & linux.POLL.IN != 0) {
            var info: linux.signalfd_siginfo = undefined;
            _ = linux.read(c.sigfd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
            c.signalled = info.signo;
            return false;
        }
        if (p[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) c.readEvents(ctx);
        return true;
    }

    fn readEvents(c: *Client, ctx: anytype) void {
        var iov = [1]std.posix.iovec{.{ .base = c.rx[c.fill..].ptr, .len = c.rx.len - c.fill }};
        var cbuf: [512]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &cbuf, .controllen = cbuf.len, .flags = 0 };
        const rc = linux.recvmsg(c.fd, &msg, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => return,
            else => fail("the compositor hung up", .{}),
        }
        if (rc == 0) fail("the compositor hung up", .{});
        // SCM_RIGHTS fds, in order
        var off: usize = 0;
        while (off + @sizeOf(linux.cmsghdr) <= msg.controllen) {
            const cm: *const linux.cmsghdr = @ptrCast(@alignCast(&cbuf[off]));
            if (cm.len < @sizeOf(linux.cmsghdr)) break;
            if (cm.level == linux.SOL.SOCKET and cm.type == linux.SCM.RIGHTS) {
                const space = cmsgAlign(@sizeOf(linux.cmsghdr));
                const data = cbuf[off + space .. off + cm.len];
                var i: usize = 0;
                while (i + 4 <= data.len) : (i += 4) {
                    if (c.n_rx_fds == max_fds) fail("too many fds queued", .{});
                    c.rx_fds[c.n_rx_fds] = std.mem.bytesToValue(i32, data[i..][0..4]);
                    c.n_rx_fds += 1;
                }
            }
            off += cmsgAlign(cm.len);
        }
        c.fill += rc;
        var pos: usize = 0;
        while (c.fill - pos >= wire.header_size) {
            const h = wire.Header.parse(c.rx[pos..c.fill]) catch fail("bad message header", .{});
            if (c.fill - pos < h.size) break;
            c.handle(ctx, h, c.rx[pos + wire.header_size .. pos + h.size]);
            pos += h.size;
        }
        std.mem.copyForwards(u8, c.rx[0 .. c.fill - pos], c.rx[pos..c.fill]);
        c.fill -= pos;
    }

    fn popFd(c: *Client) i32 {
        if (c.n_rx_fds == 0) fail("an fd arg arrived without an fd", .{});
        const f = c.rx_fds[0];
        std.mem.copyForwards(i32, c.rx_fds[0 .. c.n_rx_fds - 1], c.rx_fds[1..c.n_rx_fds]);
        c.n_rx_fds -= 1;
        return f;
    }

    fn handle(c: *Client, ctx: anytype, h: wire.Header, body: []const u8) void {
        const obj = c.objects.get(h.object_id) orelse fail("event for unknown object {d}", .{h.object_id});
        const i = obj.iface;
        if (h.opcode >= i.events.len) fail("unknown event {d} on {s}#{d}", .{ h.opcode, i.name, h.object_id });
        const m = i.events[h.opcode];
        var vals: [wire.max_args]Value = undefined;
        const args = wire.decodeArgs(body, m.args, &vals) catch |e| fail("{s}#{d}.{s}: {t}", .{ i.name, h.object_id, m.name, e });
        if (encodedSize(args) != body.len) fail("{s}#{d}.{s}: {d} bytes, the signature takes {d}", .{ i.name, h.object_id, m.name, body.len, encodedSize(args) });
        var fd: i32 = -1;
        for (m.args) |t| {
            if (t == .fd) fd = c.popFd();
        }
        // a new_id in an event: a server-created object
        for (args) |a| switch (a) {
            .new_id => |nid| {
                const ni = protocol.find(m.new_id_interface orelse fail("untyped new_id in {s}.{s}", .{ i.name, m.name })) orelse fail("unknown interface", .{});
                c.objects.put(c.gpa, nid, .{ .iface = ni }) catch fail("out of memory", .{});
            },
            else => {},
        };
        if (c.debug) c.log(" ", h.object_id, i, m, args, if (fd >= 0) &[1]i32{fd} else &.{});

        if (i == (comptime iface("wl_display"))) {
            if (h.opcode == 0) { // error
                fail("protocol error on object {d}, code {d}: {s}", .{ args[0].object, args[1].uint, args[2].string orelse "" });
            }
            if (h.opcode == 1) { // delete_id
                _ = c.objects.remove(args[0].uint);
                return;
            }
        }
        if (i == (comptime iface("wl_registry")) and h.opcode == 0) { // global
            c.globals.append(c.gpa, .{
                .name = args[0].uint,
                .interface = c.gpa.dupe(u8, args[1].string orelse "") catch fail("out of memory", .{}),
                .version = args[2].uint,
            }) catch fail("out of memory", .{});
        }
        // events to zombies are dropped (and close their fds)
        if (!obj.zombie) {
            ctx.onEvent(Event{ .id = h.object_id, .iface = i, .opcode = h.opcode, .args = args, .fd = fd });
        } else if (fd >= 0) _ = linux.close(fd);
        if (m.destructor) _ = c.objects.remove(h.object_id);
    }

    fn encodedSize(args: []const Value) usize {
        var n: usize = 0;
        for (args) |a| n += switch (a) {
            .int, .uint, .fixed, .object, .new_id => 4,
            .string => |s| if (s) |v| 4 + std.mem.alignForward(usize, v.len + 1, 4) else 4,
            .array => |v| 4 + std.mem.alignForward(usize, v.len, 4),
            .new_id_dynamic => |v| 12 + std.mem.alignForward(usize, v.interface.len + 1, 4),
            .fd => 0,
        };
        return n;
    }

    fn log(c: *Client, dir: []const u8, id: u32, i: *const Interface, m: protocol.Message, args: []const Value, fds: []const i32) void {
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const t = nowNs() / 1000;
        w.print("[{d:>7}.{d:0>3}] {s}{s}#{d}.{s}(", .{ t / 1000, t % 1000, dir, i.name, id, m.name }) catch {};
        var nfd: usize = 0;
        for (args, 0..) |a, k| {
            if (k > 0) w.writeAll(", ") catch {};
            switch (a) {
                .int => |v| w.print("{d}", .{v}) catch {},
                .uint => |v| w.print("{d}", .{v}) catch {},
                .fixed => |v| w.print("{d:.6}", .{fromFixed(v)}) catch {},
                .string => |s| if (s) |v| w.print("\"{s}\"", .{v}) catch {} else w.writeAll("nil") catch {},
                .object => |v| if (v == 0) w.writeAll("nil") catch {} else {
                    const o = c.objects.get(v);
                    w.print("{s}#{d}", .{ if (o) |x| x.iface.name else "[unknown]", v }) catch {};
                },
                .new_id => |v| {
                    const o = c.objects.get(v);
                    w.print("new id {s}#{d}", .{ if (o) |x| x.iface.name else "[unknown]", v }) catch {};
                },
                .new_id_dynamic => |v| w.print("new id {s}#{d}", .{ v.interface, v.id }) catch {},
                .array => |v| w.print("array[{d}]", .{v.len}) catch {},
                .fd => {
                    w.print("fd {d}", .{if (nfd < fds.len) fds[nfd] else -1}) catch {};
                    nfd += 1;
                },
            }
        }
        w.writeAll(")\n") catch {};
        writeFd(2, w.buffered());
    }

    // --- registry ------------------------------------------------------------

    /// get_registry + a roundtrip: `globals` holds every advertised global.
    pub fn start(c: *Client, ctx: anytype) void {
        c.registry = c.new("wl_registry");
        c.send(1, "wl_display", "get_registry", &.{.{ .new_id = c.registry }});
        c.roundtrip(ctx);
    }

    pub fn global(c: *Client, interface: []const u8) ?Global {
        for (c.globals.items) |g| {
            if (std.mem.eql(u8, g.interface, interface)) return g;
        }
        return null;
    }

    /// Bind `name` at min(advertised, `version`); 0 when not advertised.
    pub fn bind(c: *Client, comptime name: []const u8, version: u32) u32 {
        const g = c.global(name) orelse return 0;
        const id = c.new(name);
        c.send(c.registry, "wl_registry", "bind", &.{ .{ .uint = g.name }, .{ .new_id_dynamic = .{ .interface = name, .version = @min(version, g.version), .id = id } } });
        return id;
    }

    pub fn bindVersion(c: *Client, comptime name: []const u8, version: u32) u32 {
        const g = c.global(name) orelse return 0;
        return @min(version, g.version);
    }

    pub fn mustBind(c: *Client, comptime name: []const u8, version: u32) u32 {
        const id = c.bind(name, version);
        if (id == 0) fail("{s} is not advertised", .{name});
        return id;
    }

    /// wl_display.sync and dispatch until its done (events go to `ctx`).
    pub fn roundtrip(c: *Client, ctx: anytype) void {
        const cb = c.new("wl_callback");
        c.send(1, "wl_display", "sync", &.{.{ .new_id = cb }});
        const Wrap = struct {
            inner: @TypeOf(ctx),
            cb: u32,
            done: bool = false,
            pub fn onEvent(w: *@This(), ev: Event) void {
                if (ev.id == w.cb) w.done = true else w.inner.onEvent(ev);
            }
        };
        var w: Wrap = .{ .inner = ctx, .cb = cb };
        const deadline = nowMs() + 10_000;
        while (!w.done) {
            if (nowMs() > deadline) fail("roundtrip timed out", .{});
            if (!c.dispatch(&w, 1000)) linux.exit_group(0);
        }
    }
};

// --- shm buffers ----------------------------------------------------------------

pub const XRGB8888: u32 = 1;
pub const ARGB8888: u32 = 0;

pub const Buffer = struct {
    id: u32,
    width: u32,
    height: u32,
    stride: u32,
    offset: u32,
    pixels: []u32,
    busy: bool = false,
    /// damage to repaint before this buffer is reused (buffer age): what
    /// changed in the scene since it was last drawn
    stale: Rect = .{},
};

/// `n` buffers of one size in one memfd pool, `gap` bytes apart (so the
/// pool is sparse and offsets are non-trivial). The pool object is
/// destroyed at once (the buffers keep the storage), as weston-simple-shm does.
pub const Pool = struct {
    mem: []align(4096) u8,
    buffers: [4]Buffer = undefined,
    n: usize,

    pub fn create(c: *Client, shm: u32, n: usize, width: u32, height: u32, format: u32, gap: u32) Pool {
        const stride = width * 4;
        const one = std.mem.alignForward(u32, stride * height, 4096) + gap;
        const size: usize = @as(usize, one) * n;
        const mrc = linux.memfd_create("wland-fixture", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
        if (linux.errno(mrc) != .SUCCESS) fail("memfd_create failed", .{});
        const fd: i32 = @intCast(mrc);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) fail("ftruncate failed", .{});
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(addr) != .SUCCESS) fail("mmap failed", .{});
        const mem: []align(4096) u8 = @as([*]align(4096) u8, @ptrFromInt(addr))[0..size];
        const pool = c.new("wl_shm_pool");
        c.sendFds(shm, "wl_shm", "create_pool", &.{ .{ .new_id = pool }, .fd, .{ .int = @intCast(size) } }, &.{fd});
        var p: Pool = .{ .mem = mem, .n = n };
        for (0..n) |k| {
            const id = c.new("wl_buffer");
            const offset: u32 = @intCast(k * one + gap);
            c.send(pool, "wl_shm_pool", "create_buffer", &.{ .{ .new_id = id }, .{ .int = @intCast(offset) }, .{ .int = @intCast(width) }, .{ .int = @intCast(height) }, .{ .int = @intCast(stride) }, .{ .uint = format } });
            const px: [*]u32 = @ptrCast(@alignCast(mem.ptr + offset));
            p.buffers[k] = .{ .id = id, .width = width, .height = height, .stride = stride, .offset = offset, .pixels = px[0 .. width * height], .stale = .{ .x = 0, .y = 0, .w = width, .h = height } };
        }
        c.destroy(pool, "wl_shm_pool");
        c.flush(); // the fd travels now; then it can go
        _ = linux.close(fd);
        return p;
    }

    pub fn free(p: *Pool) ?*Buffer {
        for (p.buffers[0..p.n]) |*b| {
            if (!b.busy) return b;
        }
        return null;
    }

    /// wl_buffer.release for one of ours.
    pub fn released(p: *Pool, id: u32) bool {
        for (p.buffers[0..p.n]) |*b| {
            if (b.id == id) {
                b.busy = false;
                return true;
            }
        }
        return false;
    }

    /// Mark a scene change on every buffer (each repaints it when next used).
    pub fn damage(p: *Pool, r: Rect) void {
        for (p.buffers[0..p.n]) |*b| b.stale = b.stale.join(r);
    }

    pub fn destroy(p: *Pool, c: *Client) void {
        for (p.buffers[0..p.n]) |b| c.destroy(b.id, "wl_buffer");
        _ = linux.munmap(p.mem.ptr, p.mem.len);
        p.n = 0;
    }
};

pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn empty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }
    pub fn join(a: Rect, b: Rect) Rect {
        if (a.empty()) return b;
        if (b.empty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    pub fn clip(r: Rect, w: u32, h: u32) Rect {
        if (r.x >= w or r.y >= h) return .{};
        return .{ .x = r.x, .y = r.y, .w = @min(r.w, w - r.x), .h = @min(r.h, h - r.y) };
    }
};
