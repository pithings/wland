// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! wlandr entry: binds the wayland unix socket, then
//! serves ONE engine link — the browser over HTTP+WebSocket (default), or,
//! with --link, a byte stream and no HTTP at all. The relay logic lives in
//! relay.zig; HTTP in server.zig (absent from -Dhttp=false builds).

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const build_options = @import("build_options");
const relay_mod = @import("relay.zig");
const buffers = @import("buffers.zig");
const dmabuf = @import("dmabuf.zig");
const kwshm = @import("kwshm.zig");
const virtgpu = @import("virtgpu.zig");
const StreamLink = @import("stream_link.zig").StreamLink;
const socket = @import("socket.zig");
const xwayland = @import("xwayland.zig");

// libwayland clients connect to $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY, the name
// defaulting to "wayland-0". With no --display we take the first free
// wayland-N (socket.zig), so where no other compositor runs, apps connect
// with no env vars at all. The inherited $WAYLAND_DISPLAY is NOT read: run
// from a desktop's terminal it names the desktop's own socket.

// The usage text matches the build: a -Dhttp=false relay has no HTTP options.
const usage_synopsis = if (build_options.http)
    \\usage: wlandr [--port N] [--host ADDR] [--web-root DIR] [--display NAME] [--dmabuf MODE] [--xwayland MODE]
    \\                 serve the browser compositor (HTTP + /ws)
    \\       wlandr --link SPEC [--buffers MODE] [--display NAME] [--dmabuf MODE] [--xwayland MODE]
    \\                 serve one engine over a byte stream, no HTTP
    \\
    \\
else
    \\usage: wlandr --link SPEC [--buffers MODE] [--display NAME] [--dmabuf MODE] [--xwayland MODE]
    \\                 serve one engine over a byte stream (this build has no HTTP server: --link is required)
    \\
    \\
;
const usage_display =
    \\  --display NAME   wayland socket name in $XDG_RUNTIME_DIR; fails if another compositor has it
    \\                   (default: the first free wayland-N — usually wayland-0)
    \\
;
const usage_http = if (build_options.http)
    \\  --port N         HTTP port (default 8080; 0 = any free port, logged)
    \\  --host ADDR      IPv4/IPv6 address HTTP listens on (default 127.0.0.1). The session has no
    \\                   authentication: whoever reaches the port gets the desktop. 0.0.0.0 is for a
    \\                   container whose published port is itself bound to loopback.
    \\  --web-root DIR   directory served over HTTP (default dist)
    \\
else
    "";
const usage_link =
    \\  --link SPEC      fd:N             an inherited, connected stream socket (exit when it closes)
    \\                   unix:PATH        connect to a unix stream socket (reconnect when it closes)
    \\                   vsock:CID:PORT   connect over AF_VSOCK, e.g. vsock:2:PORT from an unkernel
    \\                                    guest to its host (reconnect when it closes)
    \\  --buffers MODE   how committed pixels reach the engine (default copy):
    \\                   copy    pixels travel in the stream (BUFFER frames)
    \\                   procfd  buffer handles read via /proc/<pid>/fd (same-host debug; --link only)
    \\                   kwshm   buffer handles exported via unkernel's /dev/kwshm (--link only)
    \\  --dmabuf MODE    take GPU clients' buffers (linux-dmabuf; default: off, not advertised):
    \\                   readback[:NODE]  map LINEAR ARGB/XRGB8888 dmabufs and copy them like shm
    \\                                    (needs --buffers copy)
    \\                   virtgpu[:NODE]   name each dmabuf by its virtio-gpu resource (COMMIT kind
    \\                                    virtgpu; the page's renderer resolves it): [AX]RGB8888 and
    \\                                    [AX]BGR8888, implicit modifier or LINEAR, one plane; any
    \\                                    --buffers mode (unkernel: --buffers kwshm --dmabuf virtgpu).
    \\                                    NODE must be a virtio_gpu node; it is held open only while
    \\                                    a GPU buffer exists
    \\                   Clients allocate on NODE (default: the first /dev/dri/renderD*).
    \\  --xwayland MODE  X11 apps through xwayland-satellite, started with the first X client:
    \\
;
const usage_xwayland_default = if (build_options.http)
    \\                   auto    if xwayland-satellite is on $PATH (the default without --link)
    \\                   off     no X11 (the default with --link)
    \\
else
    \\                   auto    if xwayland-satellite is on $PATH
    \\                   off     no X11 (the default)
    \\
;
const usage_tail =
    \\                   PATH    that xwayland-satellite binary
    \\                   The X display is the first free :N in /tmp; `x11 display: :N` is logged and
    \\                   written to <socket>.x11.
    \\
    \\The wayland socket is $XDG_RUNTIME_DIR/<display> ($XDG_RUNTIME_DIR unset: /tmp/wland-run), held
    \\with <display>.lock like libwayland's own compositors; `wayland socket: PATH` is logged once bound.
    \\On a --link stream, messages are length-prefixed records (protocol/STREAM.md) and
    \\wl_surface.frame callbacks are left to the engine (it fires them when it presents).
    \\When a reconnecting link drops, every app connected through it is disconnected (its
    \\compositor state lived in that engine); apps connecting meanwhile wait for the next one.
    \\
;
const usage = usage_synopsis ++ usage_display ++ usage_http ++ usage_link ++ usage_xwayland_default ++ usage_tail;

/// Where a no-HTTP relay finds its engine.
const LinkSpec = union(enum) {
    fd: i32,
    unix: []const u8,
    vsock: struct { cid: u32, port: u32 },

    fn parse(spec: []const u8) !LinkSpec {
        if (std.mem.startsWith(u8, spec, "fd:"))
            return .{ .fd = try std.fmt.parseInt(i32, spec[3..], 10) };
        if (std.mem.startsWith(u8, spec, "unix:") and spec.len > 5)
            return .{ .unix = spec[5..] };
        if (std.mem.startsWith(u8, spec, "vsock:")) {
            var it = std.mem.splitScalar(u8, spec[6..], ':');
            const cid = it.next() orelse return error.BadLinkSpec;
            const port = it.next() orelse return error.BadLinkSpec;
            if (it.next() != null) return error.BadLinkSpec;
            return .{ .vsock = .{
                .cid = try std.fmt.parseInt(u32, cid, 10),
                .port = try std.fmt.parseInt(u32, port, 10),
            } };
        }
        return error.BadLinkSpec;
    }
};

/// What the command line asks for, validated whole before anything is
/// opened (a device, a socket): a bad argument is reported as itself, not
/// as whatever the first device open happened to fail with.
const Options = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    web_root: []const u8 = "dist",
    link_spec: ?LinkSpec = null,
    link_text: []const u8 = "",
    display: ?[]const u8 = null,
    buffer_mode: buffers.Kind = .copy,
    xwayland: ?[]const u8 = null,
    dmabuf: ?DmabufMode = null,
    http_address: Io.net.IpAddress = undefined,
};

/// `--dmabuf readback[:NODE]` / `virtgpu[:NODE]`, parsed (nothing opened).
const DmabufMode = struct {
    tag: std.meta.Tag(dmabuf.Backend),
    /// NODE, or null for the first render node
    spec: ?[]const u8,
    text: []const u8,
};

/// Parse and validate the arguments (argv0 already taken). `out.print`
/// receives what a person should read; `--help` returns error.Help.
fn parseArgs(args: anytype, out: anytype) !Options {
    var o: Options = .{};
    while (args.next()) |arg| {
        if (build_options.http and std.mem.eql(u8, arg, "--port")) {
            o.port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPortValue, 10);
        } else if (build_options.http and std.mem.eql(u8, arg, "--host")) {
            o.host = args.next() orelse return error.MissingHostValue;
        } else if (build_options.http and std.mem.eql(u8, arg, "--web-root")) {
            o.web_root = args.next() orelse return error.MissingWebRootValue;
        } else if (std.mem.eql(u8, arg, "--display")) {
            const name = args.next() orelse return error.MissingDisplayValue;
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
                out.print("--display takes a socket name, not a path\n\n" ++ usage, .{});
                return error.BadDisplay;
            }
            o.display = name;
        } else if (std.mem.eql(u8, arg, "--link")) {
            o.link_text = args.next() orelse return error.MissingLinkValue;
            o.link_spec = LinkSpec.parse(o.link_text) catch {
                out.print(usage, .{});
                return error.BadLinkSpec;
            };
        } else if (std.mem.eql(u8, arg, "--dmabuf")) {
            const mode = args.next() orelse return error.MissingDmabufValue;
            const colon = std.mem.indexOfScalar(u8, mode, ':');
            const tag = std.meta.stringToEnum(std.meta.Tag(dmabuf.Backend), mode[0 .. colon orelse mode.len]) orelse {
                out.print("--dmabuf takes readback[:NODE] or virtgpu[:NODE]\n\n" ++ usage, .{});
                return error.BadDmabufMode;
            };
            o.dmabuf = .{ .tag = tag, .spec = if (colon) |c| mode[c + 1 ..] else null, .text = mode };
        } else if (std.mem.eql(u8, arg, "--xwayland")) {
            o.xwayland = args.next() orelse return error.MissingXwaylandValue;
        } else if (std.mem.eql(u8, arg, "--buffers")) {
            const mode = args.next() orelse return error.MissingBuffersValue;
            o.buffer_mode = std.meta.stringToEnum(buffers.Kind, mode) orelse {
                out.print(usage, .{});
                return error.BadBuffersMode;
            };
        } else {
            out.print(usage, .{});
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.Help;
            return error.UnknownArgument;
        }
    }
    if (!build_options.http and o.link_spec == null) {
        out.print("this relay was built with -Dhttp=false: --link is required\n\n" ++ usage, .{});
        return error.MissingLink;
    }
    if (o.buffer_mode != .copy and o.link_spec == null) {
        // a browser engine has no buffer source: it would show nothing
        out.print("--buffers {t} needs --link (the browser only takes copy)\n\n" ++ usage, .{o.buffer_mode});
        return error.BuffersNeedLink;
    }
    if (o.dmabuf) |d| if (d.tag == .readback and o.buffer_mode != .copy) {
        out.print("--dmabuf readback copies pixels into the stream: it needs --buffers copy\n\n" ++ usage, .{});
        return error.DmabufNeedsCopy;
    };
    // after the loop: --port may follow --host
    o.http_address = Io.net.IpAddress.parse(o.host, o.port) catch {
        out.print("--host takes an IPv4 or IPv6 address (e.g. 127.0.0.1, 0.0.0.0, ::1), not {s}\n\n" ++ usage, .{o.host});
        return error.BadHost;
    };
    return o;
}

const Stderr = struct {
    fn print(_: Stderr, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    defer args.deinit();
    _ = args.next(); // argv0
    const opts = parseArgs(&args, Stderr{}) catch |err| {
        if (err == error.Help) return;
        return err;
    };
    const link_spec = opts.link_spec;
    const link_text = opts.link_text;
    const display_arg = opts.display;
    const buffer_mode = opts.buffer_mode;
    const xwayland_arg = opts.xwayland;
    const port = opts.port;
    const host = opts.host;
    const web_root = opts.web_root;
    const http_address = opts.http_address;

    // every argument is valid: now open what they name
    const backend: buffers.Backend = switch (buffer_mode) {
        .copy => .copy,
        .procfd => .procfd,
        // held for the relay's life: closing it would release every export
        .kwshm => .{ .kwshm = kwshm.open() catch |err| {
            std.log.err("--buffers kwshm: cannot open {s}: {t}", .{ kwshm.dev_path, err });
            return err;
        } },
    };
    const dmabuf_config: ?dmabuf.Config = if (opts.dmabuf) |mode| try openDmabuf(io, gpa, mode) else null;

    // wayland unix socket in $XDG_RUNTIME_DIR (fallback: /tmp/wland-run)
    const runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse blk: {
        const fallback = "/tmp/wland-run";
        Io.Dir.createDirAbsolute(io, fallback, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        break :blk fallback;
    };
    var claimed = (if (display_arg) |name| socket.claim(runtime_dir, name) else socket.claimAuto(runtime_dir)) catch |err| {
        switch (err) {
            error.InUse => std.log.err("wayland socket {s}/{s} is in use by another compositor", .{ runtime_dir, display_arg.? }),
            error.NoFreeName => std.log.err("no free wayland-N in {s} (0..{d} all in use)", .{ runtime_dir, socket.max_auto - 1 }),
            error.NameTooLong => std.log.err("wayland socket path too long for AF_UNIX: {s}/{s}", .{ runtime_dir, display_arg orelse "wayland-N" }),
            error.LockFailed => std.log.err("cannot lock a wayland socket name in {s} (missing directory? permissions?)", .{runtime_dir}),
        }
        return err;
    };
    // `claimed` holds its lock fd for the process lifetime: wlandr never
    // gives the name back while it runs. At exit (a return, or SIGINT/TERM/
    // HUP) the socket and lock file are removed.
    socket.removeOnSignal(&claimed);
    defer claimed.remove();
    const socket_path = claimed.path();
    const display_name = claimed.name();

    // the relay lives as long as the process; threads keep its address
    const relay = try gpa.create(relay_mod.Relay);
    relay.* = .{ .io = io, .gpa = gpa, .backend = backend, .dmabuf = dmabuf_config };
    var wayland = try relay_mod.listenWayland(io, socket_path);

    // X11 apps: on by default where a person runs apps by hand (the HTTP
    // server), off for a --link relay (scripts, tests, a guest) unless asked
    const x11_display = startXwayland(gpa, init.environ_map, xwayland_arg orelse if (link_spec == null) "auto" else "off", runtime_dir, socket_path, display_name) catch |err| {
        std.log.err("--xwayland {s}: {t}", .{ xwayland_arg orelse "auto", err });
        return err;
    };

    if (dmabuf_config) |cfg| std.log.info("dmabuf: {t}, main device 0x{x}", .{ cfg.backend, cfg.main_device });

    // bind everything before announcing: lib/index.ts (the npm CLI) waits
    // for the "wayland socket:" line as its ready signal
    if (link_spec) |spec| {
        if (x11_display) |n| std.log.info("x11 display: :{d}", .{n});
        std.log.info("wayland socket: {s}", .{socket_path});
        std.log.info("buffers: {t}", .{buffer_mode});
        const thread = try std.Thread.spawn(.{}, relay_mod.serveWayland, .{ relay, &wayland });
        thread.detach();
        return serveStreamLink(relay, spec, link_text);
    }
    if (build_options.http) { // comptime: -Dhttp=false never compiles this
        const server = @import("server.zig");
        const srv = server.Server.create(gpa, io, relay, .{ .address = http_address, .web_root = web_root }) catch |err| {
            if (err == error.AddressInUse) std.log.err("HTTP port {d} is in use (another wlandr? pass --port, or --port 0 for any free one)", .{port});
            if (err == error.AddressUnavailable) std.log.err("--host {s}: not an address of this machine", .{host});
            return err;
        };
        if (x11_display) |n| std.log.info("x11 display: :{d} (X11 apps: xwayland-satellite starts with the first one)", .{n});
        std.log.info("wayland socket: {s}", .{socket_path});
        std.log.info("launch apps: wland run <app> — or plain, from a shell where XDG_RUNTIME_DIR={s} and WAYLAND_DISPLAY={s} (or unset, for wayland-0)", .{ runtime_dir, display_name });
        const thread = try std.Thread.spawn(.{}, relay_mod.serveWayland, .{ relay, &wayland });
        thread.detach();
        srv.serve();
    } else unreachable; // rejected above
}

/// `--dmabuf readback[:NODE]` / `virtgpu[:NODE]` → what the relay offers.
/// The device is the render node clients allocate on: NODE, else the first
/// /dev/dri/renderD*. virtgpu checks it is a virtio_gpu node now (a missing
/// or foreign node fails startup) but holds it open only while a GPU buffer
/// exists (virtgpu.zig: each open DRM file gets a host renderer context).
fn openDmabuf(io: Io, gpa: std.mem.Allocator, mode: DmabufMode) !dmabuf.Config {
    const tag = mode.tag;
    const spec = mode.spec;
    // TEST-ONLY, undocumented: `virtgpu:@fake` names memfds through an
    // in-process stand-in for a virtio-gpu node (virtgpu.Fake) — how the
    // E2E tests drive this backend with no /dev/dri. Nothing real can
    // allocate on it.
    if (tag == .virtgpu and spec != null and std.mem.eql(u8, spec.?, "@fake")) {
        std.log.warn("--dmabuf virtgpu:@fake: TEST-ONLY stand-in device, not a GPU", .{});
        const fake = try gpa.create(virtgpu.Fake);
        fake.* = .{};
        const imp = try gpa.create(virtgpu.Importer);
        imp.* = .init(io, gpa, .{ .fake = fake });
        return .{ .backend = .{ .virtgpu = imp }, .main_device = dmabuf.makedev(226, 128) };
    }
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    var node_buf: [32]u8 = undefined;
    const node: [:0]const u8 = if (spec) |path|
        try std.fmt.bufPrintZ(&path_buf, "{s}", .{path})
    else
        dmabuf.firstRenderNode(&node_buf) orelse {
            std.log.err("--dmabuf {t}: no render node in /dev/dri; name one: --dmabuf {t}:/dev/dri/renderDN", .{ tag, tag });
            return error.NoRenderNode;
        };
    const dev = dmabuf.deviceOf(node) catch |err| {
        std.log.err("--dmabuf {t}: {s}: {t}", .{ tag, node, err });
        return err;
    };
    const backend: dmabuf.Backend = switch (tag) {
        .readback => .readback,
        .virtgpu => blk: {
            // the importer reopens it by path: keep the path for the relay's life
            const drm: virtgpu.Device = .{ .path = try gpa.dupeZ(u8, node) };
            drm.check() catch |err| {
                switch (err) {
                    error.NotVirtioGpu => std.log.err("--dmabuf virtgpu: {s} is not a virtio-gpu render node (its DRM driver is not {s})", .{ node, virtgpu.driver_name }),
                    else => std.log.err("--dmabuf virtgpu: cannot open {s}: {t}", .{ node, err }),
                }
                return err;
            };
            const imp = try gpa.create(virtgpu.Importer);
            imp.* = .init(io, gpa, drm);
            break :blk .{ .virtgpu = imp };
        },
    };
    return .{ .backend = backend, .main_device = dev };
}

/// X11 through xwayland-satellite (xwayland.zig): claim an X display, leave
/// `<socket>.x11` saying which (how `wland run` finds DISPLAY), and start the
/// thread that launches satellite for the first X client. `mode`: "off",
/// "auto" (if `xwayland-satellite` is on $PATH and /tmp takes an X display;
/// otherwise quietly without X11) or satellite's path (then failing is an
/// error). Returns the display number, null without X11.
fn startXwayland(
    gpa: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    mode: []const u8,
    runtime_dir: []const u8,
    socket_path: []const u8,
    display_name: []const u8,
) !?u32 {
    var note_buf: [128]u8 = undefined;
    const note = try std.fmt.bufPrintZ(&note_buf, "{s}.x11", .{socket_path});
    _ = linux.unlink(note); // a predecessor's (SIGKILL leaves it): never point at a display that isn't ours
    if (std.mem.eql(u8, mode, "off")) return null;
    const auto = std.mem.eql(u8, mode, "auto");

    var bin_buf: [std.posix.PATH_MAX]u8 = undefined;
    const bin: [:0]const u8 = if (auto)
        xwayland.findSatellite(environ.get("PATH") orelse "", &bin_buf) orelse return null
    else blk: {
        const p = try std.fmt.bufPrintZ(&bin_buf, "{s}", .{mode});
        if (linux.errno(linux.access(p, linux.X_OK)) != .SUCCESS) return error.SatelliteNotExecutable;
        break :blk p;
    };
    const display = xwayland.claim("/tmp", true) catch |err| {
        if (!auto) return err;
        std.log.info("x11: no X display to claim in /tmp ({t}); running without X11 apps", .{err});
        return null;
    };

    // satellite's environment: ours, pointed at our socket
    var env = try environ.clone(gpa);
    try env.put("WAYLAND_DISPLAY", display_name);
    try env.put("XDG_RUNTIME_DIR", runtime_dir);
    _ = env.swapRemove("DISPLAY");
    const block = try env.createPosixBlock(gpa, .{});

    const launcher = try gpa.create(xwayland.Launcher);
    launcher.init(display, try gpa.dupeZ(u8, bin), block.slice.ptr);
    socket.removeAtExit(std.mem.span(display.sockPath()));
    socket.removeAtExit(std.mem.span(display.lockPath()));

    var text_buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, ":{d}\n", .{display.n});
    const rc = linux.open(note, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) == .SUCCESS) {
        _ = linux.write(@intCast(rc), text.ptr, text.len);
        _ = linux.close(@intCast(rc));
        socket.removeAtExit(std.mem.span(note.ptr));
    }

    const thread = try std.Thread.spawn(.{}, xwayland.Launcher.run, .{launcher});
    thread.detach();
    return display.n;
}

/// Run the relay over a byte-stream link. Frame callbacks: .engine — a
/// stream link's engine is local to its host (the page, over vsock) and
/// should pace apps by its own presentation, not by relay-side drain.
///
/// unix/vsock links reconnect forever (unkernel resets vsock connections
/// when it restores a snapshot). Each drop runs serveLink's normal detach:
/// every app conn of that link is disconnected, with its handles, parked
/// clipboard fds and SRVOBJ flags — the engine that held their compositor
/// state is gone, and nothing can resume them today. Apps that connect
/// while no link is up wait for the next one.
fn serveStreamLink(relay: *relay_mod.Relay, spec: LinkSpec, text: []const u8) !void {
    const io = relay.io;
    if (spec == .fd) {
        const fd = spec.fd;
        var link: StreamLink = undefined;
        link.init(io, fd, .engine);
        relay_mod.serveLink(relay, &link.link);
        _ = linux.close(fd);
        std.log.info("link {s} closed, exiting", .{text});
        return;
    }
    var reported = false;
    while (true) {
        const fd = dial(io, spec) catch |err| {
            if (!reported) std.log.info("link {s}: {t}; retrying every second", .{ text, err });
            reported = true;
            io.sleep(.fromSeconds(1), .awake) catch {};
            continue;
        };
        reported = false;
        std.log.info("link {s} connected", .{text});
        var link: StreamLink = undefined;
        link.init(io, fd, .engine);
        relay_mod.serveLink(relay, &link.link);
        _ = linux.close(fd);
        std.log.info("link {s} closed; reconnecting", .{text});
    }
}

/// Connect a unix or vsock link; the caller closes the fd.
fn dial(io: Io, spec: LinkSpec) !i32 {
    switch (spec) {
        .fd => unreachable,
        .unix => |path| {
            const addr = try Io.net.UnixAddress.init(path);
            const s = try addr.connect(io);
            return s.socket.handle;
        },
        .vsock => |v| {
            const rc = linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return vsockError(linux.errno(rc));
            const fd: i32 = @intCast(rc);
            const sa: linux.sockaddr.vm = .{ .port = v.port, .cid = v.cid, .flags = 0 };
            while (true) {
                const c = linux.connect(fd, &sa, @sizeOf(linux.sockaddr.vm));
                switch (linux.errno(c)) {
                    .SUCCESS => return fd,
                    .INTR => continue,
                    else => |e| {
                        _ = linux.close(fd);
                        return vsockError(e);
                    },
                }
            }
        },
    }
}

fn vsockError(e: linux.E) error{ NoVsockTransport, ConnectionRefused, ConnectionTimedOut, VsockUnsupported, PermissionDenied, ConnectFailed } {
    return switch (e) {
        .NODEV, .NETUNREACH => error.NoVsockTransport, // no kwvsock device (yet)
        .CONNREFUSED, .CONNRESET => error.ConnectionRefused, // nobody listening on the port
        .TIMEDOUT => error.ConnectionTimedOut,
        .AFNOSUPPORT => error.VsockUnsupported, // kernel without AF_VSOCK
        .PERM, .ACCES => error.PermissionDenied, // e.g. a container's seccomp
        else => error.ConnectFailed,
    };
}

test {
    _ = @import("shm.zig");
    _ = @import("relay.zig");
    _ = @import("copy_backend.zig");
    _ = @import("handle_backend.zig");
    _ = @import("dmabuf.zig");
    _ = @import("kwshm.zig");
    _ = @import("virtgpu.zig");
    _ = @import("pipe_writer.zig");
    _ = @import("stream_link.zig");
    _ = @import("relay_test.zig");
    _ = @import("socket.zig");
    _ = @import("xwayland.zig");
    if (build_options.http) _ = @import("server.zig");
}

test "link spec parsing" {
    try std.testing.expectEqual(@as(i32, 3), (try LinkSpec.parse("fd:3")).fd);
    try std.testing.expectEqualStrings("/run/x.sock", (try LinkSpec.parse("unix:/run/x.sock")).unix);
    try std.testing.expectError(error.BadLinkSpec, LinkSpec.parse("unix:"));
    try std.testing.expectError(error.InvalidCharacter, LinkSpec.parse("fd:x"));
    try std.testing.expectError(error.BadLinkSpec, LinkSpec.parse("tcp:1:2"));

    const v = (try LinkSpec.parse("vsock:2:7000")).vsock;
    try std.testing.expectEqual(@as(u32, 2), v.cid);
    try std.testing.expectEqual(@as(u32, 7000), v.port);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), (try LinkSpec.parse("vsock:4294967295:1")).vsock.cid); // VMADDR_CID_ANY
    try std.testing.expectError(error.BadLinkSpec, LinkSpec.parse("vsock:"));
    try std.testing.expectError(error.BadLinkSpec, LinkSpec.parse("vsock:2"));
    try std.testing.expectError(error.BadLinkSpec, LinkSpec.parse("vsock:2:7000:1"));
    try std.testing.expectError(error.InvalidCharacter, LinkSpec.parse("vsock:2:"));
    try std.testing.expectError(error.InvalidCharacter, LinkSpec.parse("vsock::7000"));
    try std.testing.expectError(error.InvalidCharacter, LinkSpec.parse("vsock:host:7000"));
    try std.testing.expectError(error.Overflow, LinkSpec.parse("vsock:-1:7000"));
    try std.testing.expectError(error.Overflow, LinkSpec.parse("vsock:2:4294967296"));
}

test "vsock sockaddr layout (struct sockaddr_vm)" {
    const sa: linux.sockaddr.vm = .{ .port = 7000, .cid = 2, .flags = 0 };
    const b = std.mem.asBytes(&sa);
    try std.testing.expectEqual(@as(usize, 16), b.len);
    try std.testing.expectEqual(@as(u16, linux.AF.VSOCK), std.mem.readInt(u16, b[0..2], .native));
    try std.testing.expectEqual(@as(u32, 7000), std.mem.readInt(u32, b[4..8], .native));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, b[8..12], .native));
}

const ArgList = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *ArgList) ?[]const u8 {
        if (self.i == self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};
const Quiet = struct {
    fn print(_: Quiet, comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
};
fn tryArgs(items: []const []const u8) !Options {
    var list: ArgList = .{ .items = items };
    return parseArgs(&list, Quiet{});
}

test "arguments are validated whole, whatever their order, before anything is opened" {
    // a bad --dmabuf is reported as itself, not as the kwshm open that
    // used to run first
    try std.testing.expectError(error.BadDmabufMode, tryArgs(&.{ "--link", "fd:3", "--buffers", "kwshm", "--dmabuf", "bogus" }));
    try std.testing.expectError(error.BadDmabufMode, tryArgs(&.{ "--dmabuf", "bogus:/dev/dri/renderD128", "--buffers", "kwshm", "--link", "fd:3" }));
    try std.testing.expectError(error.DmabufNeedsCopy, tryArgs(&.{ "--dmabuf", "readback", "--buffers", "kwshm", "--link", "fd:3" }));
    try std.testing.expectError(if (build_options.http) error.BuffersNeedLink else error.MissingLink, tryArgs(&.{ "--buffers", "procfd" }));
    try std.testing.expectError(error.BadBuffersMode, tryArgs(&.{ "--link", "fd:3", "--buffers", "gpu" }));
    try std.testing.expectError(error.MissingDmabufValue, tryArgs(&.{ "--link", "fd:3", "--dmabuf" }));
    try std.testing.expectError(error.Help, tryArgs(&.{"--help"}));
    const o = try tryArgs(&.{ "--link", "vsock:2:1023", "--buffers", "kwshm", "--dmabuf", "virtgpu:/dev/dri/renderD129" });
    try std.testing.expectEqual(buffers.Kind.kwshm, o.buffer_mode);
    try std.testing.expectEqual(std.meta.Tag(dmabuf.Backend).virtgpu, o.dmabuf.?.tag);
    try std.testing.expectEqualStrings("/dev/dri/renderD129", o.dmabuf.?.spec.?);
    if (build_options.http) {
        try std.testing.expectError(error.BadHost, tryArgs(&.{ "--host", "nope", "--port", "1" }));
        try std.testing.expectEqual(@as(u16, 9000), (try tryArgs(&.{ "--port", "9000", "--host", "::1" })).port);
    } else {
        // no HTTP server, no HTTP options
        try std.testing.expectError(error.MissingLink, tryArgs(&.{}));
        try std.testing.expectError(error.UnknownArgument, tryArgs(&.{ "--link", "fd:3", "--port", "9000" }));
    }
}

test "the usage text matches the build" {
    const has = struct {
        fn f(needle: []const u8) bool {
            return std.mem.indexOf(u8, usage, needle) != null;
        }
    }.f;
    try std.testing.expectEqual(build_options.http, has("--port N"));
    try std.testing.expectEqual(build_options.http, has("--host ADDR"));
    try std.testing.expectEqual(build_options.http, has("--web-root DIR"));
    // the synopsis names every mode flag
    try std.testing.expect(has("--link SPEC [--buffers MODE] [--display NAME] [--dmabuf MODE] [--xwayland MODE]"));
    try std.testing.expect(!has("virtgpu:@fake")); // test-only, never offered
}
