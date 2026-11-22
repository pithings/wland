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
    \\       wlandr --link SPEC [--buffers MODE] [--display NAME] [--dmabuf MODE] [--xwayland MODE] [--link-on-demand]
    \\                 serve one engine over a byte stream, no HTTP
    \\       wlandr --version
    \\                 print the version and this build's features (below), exit 0
    \\
    \\
else
    \\usage: wlandr --link SPEC [--buffers MODE] [--display NAME] [--dmabuf MODE] [--xwayland MODE] [--link-on-demand]
    \\                 serve one engine over a byte stream (this build has no HTTP server: --link is required)
    \\       wlandr --version
    \\                 print the version and this build's features (below), exit 0
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
    \\  --link-on-demand with a unix: or vsock: link: dial it when an app connects, not at startup.
    \\                   Apps wait for that dial; if it fails (nothing listens, no transport, no
    \\                   answer within --link-timeout) each waiting app is closed (its first round
    \\                   trip fails at once) and `wayland client refused: no engine on link SPEC
    \\                   (REASON)` is logged; the next app dials again. A link that connected stays
    \\                   up while apps come and go; when it closes, the relay redials at once only
    \\                   if an app is waiting, else when the next one connects. A --dmabuf node that
    \\                   is missing at startup is not fatal: it is looked up again at each dial
    \\                   (linux-dmabuf is offered on links dialed once it is found)
    \\  --link-timeout MS  with --link-on-demand: how long a dial may take (default 5000)
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
    \\  --no-fence-wait  with --dmabuf virtgpu: send each COMMIT without first waiting (up to 100 ms)
    \\                   for the dmabuf's implicit write fences — for a device that delivers GPU work
    \\                   to the page ahead of the link's COMMIT on its own (unkernel: one channel)
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
    \\--version prints `wlandr VERSION`, then `features:` and space-separated tokens, one per thing
    \\this build supports (tokens are only ever added): http, link:fd, link:unix, link:vsock,
    \\buffers:MODE and dmabuf:MODE per mode above, no-fence-wait, selection_cache, xwayland,
    \\link-on-demand.
    \\
;
const usage = usage_synopsis ++ usage_display ++ usage_http ++ usage_link ++ usage_xwayland_default ++ usage_tail;

/// `wlandr --version`, on stdout: `wlandr VERSION` (package.json's at build
/// time, or -Dversion=), then `features:` and one space-separated token per
/// capability of this binary, for guest scripts to test instead of parsing
/// the usage text. A token, once listed, keeps its spelling; new ones are
/// appended. The modes come from the enums parseArgs takes them from.
const features = blk: {
    var f: []const u8 = if (build_options.http) "http " else "";
    f = f ++ "link:fd link:unix link:vsock";
    for (@typeInfo(buffers.Kind).@"enum".fields) |m| f = f ++ " buffers:" ++ m.name;
    for (@typeInfo(std.meta.Tag(dmabuf.Backend)).@"enum".fields) |m| f = f ++ " dmabuf:" ++ m.name;
    // --no-fence-wait; STREAM FEATURE selection_cache (the clipboard
    // bridge); --xwayland; --link-on-demand (with --link-timeout)
    break :blk f ++ " no-fence-wait selection_cache xwayland link-on-demand";
};
const version_text = "wlandr " ++ build_options.version ++ "\nfeatures: " ++ features ++ "\n";

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
    /// false: --no-fence-wait (virtgpu COMMITs skip the write-fence wait)
    fence_wait: bool = true,
    /// --link-on-demand: dial the link when an app connects
    on_demand: bool = false,
    /// --link-timeout: the bound on an on-demand dial
    link_timeout_ms: u32 = default_link_timeout_ms,
    link_timeout_given: bool = false,
    http_address: Io.net.IpAddress = undefined,
};

/// `--link-timeout` unset: an on-demand dial that has not connected by then
/// fails (and refuses the apps waiting for it). Above Linux's own vsock
/// connect timeout (2 s), so a transport that answers says why first.
const default_link_timeout_ms = 5000;

/// `--dmabuf readback[:NODE]` / `virtgpu[:NODE]`, parsed (nothing opened).
const DmabufMode = struct {
    tag: std.meta.Tag(dmabuf.Backend),
    /// NODE, or null for the first render node
    spec: ?[]const u8,
    text: []const u8,
};

/// Parse and validate the arguments (argv0 already taken). `out.print`
/// receives what a person should read; `--help` returns error.Help,
/// `--version` error.Version (main prints `version_text`).
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
        } else if (std.mem.eql(u8, arg, "--no-fence-wait")) {
            o.fence_wait = false;
        } else if (std.mem.eql(u8, arg, "--link-on-demand")) {
            o.on_demand = true;
        } else if (std.mem.eql(u8, arg, "--link-timeout")) {
            const ms = args.next() orelse return error.MissingLinkTimeoutValue;
            o.link_timeout_ms = std.fmt.parseInt(u32, ms, 10) catch 0;
            if (o.link_timeout_ms == 0) {
                out.print("--link-timeout takes milliseconds (a whole number > 0), not {s}\n\n" ++ usage, .{ms});
                return error.BadLinkTimeout;
            }
            o.link_timeout_given = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return error.Version;
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
    if (o.on_demand and (o.link_spec == null or o.link_spec.? == .fd)) {
        // only a link the relay dials can wait for its first app; fd: is
        // connected already, and the browser (HTTP) connects to the relay
        out.print("--link-on-demand needs a link the relay dials: --link unix:PATH or --link vsock:CID:PORT\n\n" ++ usage, .{});
        return error.OnDemandNeedsDialedLink;
    }
    if (o.link_timeout_given and !o.on_demand) {
        out.print("--link-timeout applies to --link-on-demand only\n\n" ++ usage, .{});
        return error.LinkTimeoutNeedsOnDemand;
    }
    if (!o.fence_wait and (o.dmabuf == null or o.dmabuf.?.tag != .virtgpu)) {
        // only virtgpu COMMITs wait; readback's read must see the GPU's writes
        out.print("--no-fence-wait applies to --dmabuf virtgpu only\n\n" ++ usage, .{});
        return error.FenceWaitNeedsVirtgpu;
    }
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
    const opts = parseArgs(&args, Stderr{}) catch |err| switch (err) {
        error.Help => return,
        error.Version => return Io.File.stdout().writeStreamingAll(io, version_text),
        else => return err,
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
    // on demand the relay may start at boot, before the render node exists:
    // a node that won't resolve is looked up again at each dial instead
    const dmabuf_config: ?dmabuf.Config = if (opts.dmabuf) |mode|
        openDmabuf(io, gpa, mode, opts.fence_wait, !opts.on_demand) catch |err| if (opts.on_demand) null else return err
    else
        null;
    const dmabuf_later: ?DmabufMode = if (dmabuf_config == null) opts.dmabuf else null;

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
    if (opts.on_demand) relay.on_demand = .{ .link_text = link_text };
    var wayland = try relay_mod.listenWayland(io, socket_path);

    // X11 apps: on by default where a person runs apps by hand (the HTTP
    // server), off for a --link relay (scripts, tests, a guest) unless asked
    const x11_display = startXwayland(gpa, init.environ_map, xwayland_arg orelse if (link_spec == null) "auto" else "off", runtime_dir, socket_path, display_name) catch |err| {
        std.log.err("--xwayland {s}: {t}", .{ xwayland_arg orelse "auto", err });
        return err;
    };

    if (dmabuf_config) |cfg| logDmabuf(cfg);

    // bind everything before announcing: lib/index.ts (the npm CLI) waits
    // for the "wayland socket:" line as its ready signal
    if (link_spec) |spec| {
        if (x11_display) |n| std.log.info("x11 display: :{d}", .{n});
        std.log.info("wayland socket: {s}", .{socket_path});
        std.log.info("buffers: {t}", .{buffer_mode});
        if (opts.on_demand) std.log.info("link {s}: on demand (dialed when an app connects, within {d} ms)", .{ link_text, opts.link_timeout_ms });
        const thread = try std.Thread.spawn(.{}, relay_mod.serveWayland, .{ relay, &wayland });
        thread.detach();
        return serveStreamLink(relay, spec, link_text, .{
            .timeout_ms = opts.link_timeout_ms,
            .dmabuf = dmabuf_later,
            .fence_wait = opts.fence_wait,
        });
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

fn logDmabuf(cfg: dmabuf.Config) void {
    std.log.info("dmabuf: {t}, main device 0x{x}{s}", .{ cfg.backend, cfg.main_device, if (cfg.fence_wait) "" else ", no fence wait" });
}

/// Why `--dmabuf` can't be set up: at startup an error (it fails), on
/// demand a warning (looked up again at the next dial).
fn dmabufFailed(fatal: bool, comptime fmt: []const u8, args: anytype) void {
    if (fatal)
        std.log.err(fmt, args)
    else
        std.log.warn(fmt ++ " — linux-dmabuf off for now (looked up again at the next dial)", args);
}

/// `--dmabuf readback[:NODE]` / `virtgpu[:NODE]` → what the relay offers.
/// The device is the render node clients allocate on: NODE, else the first
/// /dev/dri/renderD*. virtgpu checks it is a virtio_gpu node now (a missing
/// or foreign node fails startup, unless on demand: `fatal` false, then the
/// dial loop calls again) but holds it open only while a GPU buffer exists
/// (virtgpu.zig: each open DRM file gets a host renderer context).
fn openDmabuf(io: Io, gpa: std.mem.Allocator, mode: DmabufMode, fence_wait: bool, fatal: bool) !dmabuf.Config {
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
        return .{ .backend = .{ .virtgpu = imp }, .main_device = dmabuf.makedev(226, 128), .fence_wait = fence_wait };
    }
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    var node_buf: [32]u8 = undefined;
    const node: [:0]const u8 = if (spec) |path|
        try std.fmt.bufPrintZ(&path_buf, "{s}", .{path})
    else
        dmabuf.firstRenderNode(&node_buf) orelse {
            dmabufFailed(fatal, "--dmabuf {t}: no render node in /dev/dri; name one: --dmabuf {t}:/dev/dri/renderDN", .{ tag, tag });
            return error.NoRenderNode;
        };
    const dev = dmabuf.deviceOf(node) catch |err| {
        dmabufFailed(fatal, "--dmabuf {t}: {s}: {t}", .{ tag, node, err });
        return err;
    };
    const backend: dmabuf.Backend = switch (tag) {
        .readback => .readback,
        .virtgpu => blk: {
            // the importer reopens it by path: keep the path for the relay's life
            const path = try gpa.dupeZ(u8, node);
            const drm: virtgpu.Device = .{ .path = path };
            drm.check() catch |err| {
                gpa.free(path); // on demand this runs again at the next dial
                switch (err) {
                    error.NotVirtioGpu => dmabufFailed(fatal, "--dmabuf virtgpu: {s} is not a virtio-gpu render node (its DRM driver is not {s})", .{ node, virtgpu.driver_name }),
                    else => dmabufFailed(fatal, "--dmabuf virtgpu: cannot open {s}: {t}", .{ node, err }),
                }
                return err;
            };
            const imp = try gpa.create(virtgpu.Importer);
            imp.* = .init(io, gpa, drm);
            break :blk .{ .virtgpu = imp };
        },
    };
    return .{ .backend = backend, .main_device = dev, .fence_wait = fence_wait };
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

/// What an on-demand dial loop needs beside the spec (ignored otherwise).
const DialOptions = struct {
    /// the bound on each dial
    timeout_ms: u32 = default_link_timeout_ms,
    /// --dmabuf that did not resolve at startup: retried before each dial
    dmabuf: ?DmabufMode = null,
    fence_wait: bool = true,
};

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
///
/// On demand (`relay.on_demand`), the same loop dials only while an app
/// waits (relay.zig `OnDemand`): at startup, and after a link closes —
/// every app of a closed link was dropped with it, so it redials at once
/// only for apps that connected since, else at the next app. A failed
/// dial (bounded by `timeout_ms`) refuses the apps waiting for it rather
/// than retrying, so a relay where nothing listens never holds an app. A
/// link that connected is kept, apps or not: the engine side decides when
/// a link ends (a page that wants to unload closes it; the next app then
/// dials again).
fn serveStreamLink(relay: *relay_mod.Relay, spec: LinkSpec, text: []const u8, opts: DialOptions) !void {
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
    const on_demand = relay.on_demand != null;
    var dmabuf_later = opts.dmabuf;
    var reported = false;
    while (true) {
        if (on_demand) {
            relay_mod.awaitDemand(relay);
            if (dmabuf_later) |mode| {
                // no link is attached: the only moment relay.dmabuf may change
                if (openDmabuf(io, relay.gpa, mode, opts.fence_wait, false)) |cfg| {
                    relay.mutex.lockUncancelable(io);
                    relay.dmabuf = cfg;
                    relay.mutex.unlock(io);
                    dmabuf_later = null;
                    logDmabuf(cfg);
                } else |_| {}
            }
            std.log.info("link {s}: an app is waiting; dialing", .{text});
        }
        const fd = dial(io, spec, if (on_demand) opts.timeout_ms else null) catch |err| {
            if (on_demand) {
                relay_mod.dialFailed(relay, err); // each app refused logs relay_mod.refused_line
                continue;
            }
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
        std.log.info("link {s} closed; {s}", .{ text, if (on_demand) "dialing again for the next app" else "reconnecting" });
    }
}

/// Connect a unix or vsock link; the caller closes the fd. `timeout_ms`
/// (on demand) bounds the connect: a transport that never answers fails
/// with ConnectionTimedOut instead of holding the apps waiting for it.
fn dial(io: Io, spec: LinkSpec, timeout_ms: ?u32) !i32 {
    if (timeout_ms) |ms| return dialWithin(io, spec, ms);
    switch (spec) {
        .fd => unreachable,
        .unix => |path| {
            const addr = try Io.net.UnixAddress.init(path);
            const s = try addr.connect(io);
            return s.socket.handle;
        },
        .vsock => |v| {
            const rc = linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return connectError(linux.errno(rc));
            const fd: i32 = @intCast(rc);
            const sa: linux.sockaddr.vm = .{ .port = v.port, .cid = v.cid, .flags = 0 };
            while (true) {
                const c = linux.connect(fd, &sa, @sizeOf(linux.sockaddr.vm));
                switch (linux.errno(c)) {
                    .SUCCESS => return fd,
                    .INTR => continue,
                    else => |e| {
                        _ = linux.close(fd);
                        return connectError(e);
                    },
                }
            }
        },
    }
}

/// `dial` with a deadline: a non-blocking connect, waited for (vsock:
/// EINPROGRESS → poll) or retried (unix: EAGAIN, a full backlog) until
/// `ms` have passed; the connected fd is made blocking again (StreamLink).
fn dialWithin(io: Io, spec: LinkSpec, ms: u32) !i32 {
    var un: linux.sockaddr.un = undefined;
    var vm: linux.sockaddr.vm = undefined;
    const family: u32, const addr: *const linux.sockaddr, const addr_len: linux.socklen_t = switch (spec) {
        .fd => unreachable,
        .unix => |path| blk: {
            un = .{ .path = @splat(0) };
            if (path.len >= un.path.len) return error.NameTooLong;
            @memcpy(un.path[0..path.len], path);
            break :blk .{ linux.AF.UNIX, @ptrCast(&un), @sizeOf(linux.sockaddr.un) };
        },
        .vsock => |v| blk: {
            vm = .{ .port = v.port, .cid = v.cid, .flags = 0 };
            break :blk .{ linux.AF.VSOCK, @ptrCast(&vm), @sizeOf(linux.sockaddr.vm) };
        },
    };
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(rc) != .SUCCESS) return connectError(linux.errno(rc));
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    const deadline = Io.Clock.now(.awake, io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
    while (true) {
        switch (linux.errno(linux.connect(fd, addr, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .AGAIN => { // unix: the listener's backlog is full; it may drain
                if (msUntil(io, deadline) == 0) return error.ConnectionTimedOut;
                io.sleep(.fromMilliseconds(20), .awake) catch {};
            },
            .INPROGRESS => { // vsock: under way
                var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                while (true) {
                    const left = msUntil(io, deadline);
                    if (left == 0) return error.ConnectionTimedOut;
                    const n = linux.poll(&pfd, 1, left);
                    switch (linux.errno(n)) {
                        .SUCCESS => if (n == 1) break,
                        .INTR => {},
                        else => |e| return connectError(e),
                    }
                }
                var so_error: i32 = 0;
                var len: linux.socklen_t = @sizeOf(i32);
                const g = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&so_error), &len);
                if (linux.errno(g) != .SUCCESS) return connectError(linux.errno(g));
                if (so_error != 0) return connectError(@enumFromInt(so_error));
                break;
            },
            else => |e| return connectError(e),
        }
    }
    // SOCK.NONBLOCK is O_NONBLOCK's value (as the kernel defines it)
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(fl) != .SUCCESS) return connectError(linux.errno(fl));
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, fl & ~@as(usize, linux.SOCK.NONBLOCK))) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

/// Whole milliseconds left until `deadline` (awake clock ns), 0 if past.
fn msUntil(io: Io, deadline: i96) i32 {
    const left = deadline - Io.Clock.now(.awake, io).nanoseconds;
    if (left <= 0) return 0;
    return @intCast(@min(std.math.maxInt(i32), @divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
}

fn connectError(e: linux.E) error{ NoVsockTransport, ConnectionRefused, ConnectionTimedOut, VsockUnsupported, PermissionDenied, FileNotFound, ConnectFailed } {
    return switch (e) {
        .NODEV, .NETUNREACH => error.NoVsockTransport, // no kwvsock device (yet)
        .CONNREFUSED, .CONNRESET => error.ConnectionRefused, // nobody listening on the port
        .TIMEDOUT => error.ConnectionTimedOut,
        .AFNOSUPPORT => error.VsockUnsupported, // kernel without AF_VSOCK
        .PERM, .ACCES => error.PermissionDenied, // e.g. a container's seccomp
        .NOENT => error.FileNotFound, // unix: no socket at the path (nothing listens)
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
    try std.testing.expectError(error.Version, tryArgs(&.{"--version"}));
    try std.testing.expectError(error.Version, tryArgs(&.{ "--link", "fd:3", "--version", "--buffers", "gpu" })); // before the rest is checked
    // --no-fence-wait: only where a fence wait happens (virtgpu COMMITs)
    try std.testing.expectError(error.FenceWaitNeedsVirtgpu, tryArgs(&.{ "--link", "fd:3", "--no-fence-wait" }));
    try std.testing.expectError(error.FenceWaitNeedsVirtgpu, tryArgs(&.{ "--no-fence-wait", "--link", "fd:3", "--dmabuf", "readback" }));
    try std.testing.expect((try tryArgs(&.{ "--link", "fd:3", "--dmabuf", "virtgpu" })).fence_wait);
    try std.testing.expect(!(try tryArgs(&.{ "--no-fence-wait", "--link", "fd:3", "--buffers", "kwshm", "--dmabuf", "virtgpu" })).fence_wait);
    // --link-on-demand: only a link the relay dials; --link-timeout only with it
    try std.testing.expectError(error.OnDemandNeedsDialedLink, tryArgs(&.{ "--link", "fd:3", "--link-on-demand" }));
    try std.testing.expectError(if (build_options.http) error.OnDemandNeedsDialedLink else error.MissingLink, tryArgs(&.{"--link-on-demand"}));
    try std.testing.expectError(error.LinkTimeoutNeedsOnDemand, tryArgs(&.{ "--link", "unix:/x", "--link-timeout", "100" }));
    try std.testing.expectError(error.BadLinkTimeout, tryArgs(&.{ "--link", "unix:/x", "--link-on-demand", "--link-timeout", "0" }));
    try std.testing.expectError(error.BadLinkTimeout, tryArgs(&.{ "--link", "unix:/x", "--link-on-demand", "--link-timeout", "2s" }));
    try std.testing.expectError(error.MissingLinkTimeoutValue, tryArgs(&.{ "--link", "unix:/x", "--link-on-demand", "--link-timeout" }));
    {
        const d = try tryArgs(&.{ "--link-on-demand", "--link", "vsock:2:1023", "--buffers", "kwshm", "--dmabuf", "virtgpu", "--no-fence-wait" });
        try std.testing.expect(d.on_demand);
        try std.testing.expectEqual(@as(u32, default_link_timeout_ms), d.link_timeout_ms);
        const t = try tryArgs(&.{ "--link-timeout", "750", "--link", "unix:/run/l", "--link-on-demand" });
        try std.testing.expectEqual(@as(u32, 750), t.link_timeout_ms);
        try std.testing.expect(!(try tryArgs(&.{ "--link", "unix:/run/l" })).on_demand);
    }
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
    try std.testing.expect(has("--link SPEC [--buffers MODE] [--display NAME] [--dmabuf MODE] [--xwayland MODE] [--link-on-demand]"));
    try std.testing.expect(has("--link-timeout MS  with --link-on-demand"));
    // the refusal line embedders match is the one documented
    try std.testing.expect(has("`" ++ relay_mod.refused_line ++ "SPEC"));
    try std.testing.expect(!has("virtgpu:@fake")); // test-only, never offered
    try std.testing.expect(has("wlandr --version"));
    try std.testing.expect(has("--no-fence-wait  with --dmabuf virtgpu"));
}

test "--version: the build's version, then one token per feature of this build" {
    var lines = std.mem.splitScalar(u8, version_text, '\n');
    try std.testing.expectEqualStrings("wlandr " ++ build_options.version, lines.next().?);
    try std.testing.expect(build_options.version.len > 0);
    const line = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.startsWith(u8, line, "features: "));
    const has = struct {
        fn f(l: []const u8, token: []const u8) bool {
            var it = std.mem.splitScalar(u8, l["features: ".len..], ' ');
            while (it.next()) |t| if (std.mem.eql(u8, t, token)) return true;
            return false;
        }
    }.f;
    try std.testing.expectEqual(build_options.http, has(line, "http"));
    for ([_][]const u8{ "link:fd", "link:unix", "link:vsock", "buffers:copy", "buffers:procfd", "buffers:kwshm", "dmabuf:readback", "dmabuf:virtgpu", "no-fence-wait", "selection_cache", "xwayland", "link-on-demand" }) |t|
        try std.testing.expect(has(line, t));
    try std.testing.expect(std.mem.indexOf(u8, line, "@fake") == null); // test-only, never offered
    try std.testing.expect(std.mem.indexOf(u8, line, "  ") == null); // no empty token
}

test "an on-demand dial is bounded and reports why it failed; the link it makes is blocking" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/wlandr-dial-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o700);
    defer _ = linux.rmdir(dir);
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/link", .{dir});
    defer _ = linux.unlink(path);

    // nothing at the path: nobody listens
    try std.testing.expectError(error.FileNotFound, dial(io, .{ .unix = path }, 1000));
    // a listener: connected, and blocking again
    const addr = try Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    const fd = try dial(io, .{ .unix = path }, 1000);
    defer _ = linux.close(fd);
    try std.testing.expectEqual(@as(usize, 0), linux.fcntl(fd, linux.F.GETFL, 0) & linux.SOCK.NONBLOCK);
    const peer = try server.accept(io);
    peer.close(io);
    // the socket file left behind by a listener that went: refused
    server.deinit(io);
    try std.testing.expectError(error.ConnectionRefused, dial(io, .{ .unix = path }, 1000));

    // a listener that never accepts, its backlog full: the dial gives up at
    // its deadline instead of hanging
    _ = linux.unlink(path);
    const lfd: i32 = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(lfd);
    var sa: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(sa.path[0..path.len], path);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(lfd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(lfd, 0)));
    const filler = try dial(io, .{ .unix = path }, 1000); // backlog 0 still queues one
    defer _ = linux.close(filler);
    const t0 = Io.Clock.now(.awake, io).nanoseconds;
    try std.testing.expectError(error.ConnectionTimedOut, dial(io, .{ .unix = path }, 200));
    const took_ms = @divFloor(Io.Clock.now(.awake, io).nanoseconds - t0, std.time.ns_per_ms);
    try std.testing.expect(took_ms >= 190 and took_ms < 2000);
}
