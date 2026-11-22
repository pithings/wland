// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! The relay: owns the wayland app connections (unix socket) and relays
//! their wire protocol to ONE engine over a Link (link.zig), intercepting
//! every fd-carrying message on the way. It understands framing and message
//! boundaries but no wayland semantics beyond fd and buffer interception —
//! the engine (core/compositor.zig) is the compositor.
//!
//! Two pluggable ends: the Link (WebSocket, byte stream) carries STREAM
//! messages; the buffer backend (buffers.zig) decides how committed pixels
//! reach the engine, and the dmabuf backend (dmabuf.zig, optional) what a
//! linux-dmabuf buffer is to it. Everything protocol-shaped stays here: fd
//! capture, refcounted pools, dmabuf planes, attach/damage/commit tracking,
//! the wl_buffer.release ledger, frame-callback interception, clipboard pipe
//! tokens, SRVOBJ types, presentation timestamps (PRESENTED: the one clock
//! the apps can read is this machine's).
//!
//! Threads: one per app conn (reads the app, writes its batches to the link),
//! one per link (serveLink: reads the engine, writes events to apps), plus
//! the wayland accept loop.
//!
//! Locking. A conn's interception state — pools, buffers and their release
//! ledger, surfaces, the backend's handles — belongs to its app thread alone
//! and is never locked (virtgpu's GEM-handle counts are relay-wide and lock
//! inside virtgpu.Importer). The engine's ACKs (handle backends, virtgpu
//! dmabufs) arrive on the link thread, which does not touch that state: it appends the serial to the
//! conn's AppLink queue (`ack_mutex`, held only for the append/swap) and
//! signals the conn's eventfd; the app thread, polling the app socket and
//! that eventfd, takes the queue and settles the ACKs itself. So every
//! wl_buffer.release is decided and written on the app thread, in order with
//! the requests it answers. Shared by both threads, under `Relay.mutex`: the
//! conn table, pending clipboard fds, SRVOBJ flags, the link pointer, refs.
//! Each app socket's writes serialize on `AppLink.write_mutex`.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const core = @import("core");
const wire = core.wire;
const stream = core.stream;
const shm = @import("shm.zig");
const buffers = @import("buffers.zig");
const dmabuf = @import("dmabuf.zig");
const virtgpu = @import("virtgpu.zig");
const pipe_writer = @import("pipe_writer.zig");
const Link = @import("link.zig").Link;

pub const Relay = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// Buffer backend every app conn gets (fixed for the relay's life).
    backend: buffers.Backend = .copy,
    /// linux-dmabuf: null = the relay takes no dmabufs, the compositor never
    /// advertises zwp_linux_dmabuf_v1 (it does when the relay's FEATURE
    /// frames say so, first on every link — with virtgpu only if its
    /// embedder can draw GPU resources). Fixed for the relay's life, except
    /// that an on-demand relay whose render node did not resolve at startup
    /// sets it once, later: on the dial thread, under `mutex`, while no link
    /// is attached (main.zig `serveStreamLink`) — so app threads read it only
    /// once their link is attached (serveApp), never before.
    /// readback needs `backend == .copy` (main.zig checks).
    dmabuf: ?dmabuf.Config = null,
    /// Handle backends: handle ids are never reused within a run (≥ 1).
    next_handle_id: std.atomic.Value(u32) = .init(1),
    /// `--link-on-demand` (main.zig): the link is dialed for waiting apps.
    on_demand: ?OnDemand = null,
    mutex: Io.Mutex = .init,
    /// Broadcast when a link attaches (apps waiting for an engine wake up),
    /// and when an on-demand dial failed (they are refused).
    link_attached: Io.Condition = .init,
    /// Broadcast when the attached link has detached (a takeover waits).
    link_detached: Io.Condition = .init,
    /// Broadcast when some link's `users` drops to 0 (serveLink's exit).
    link_released: Io.Condition = .init,
    /// The attached engine link; one at a time, the newest takes over.
    link: ?*Link = null,
    conns: std.AutoHashMapUnmanaged(u32, *AppLink) = .empty,
    /// conn_ids are never reused within a run.
    next_conn_id: u32 = 1,
    /// Clipboard pipe fds parked while the engine routes the receive to the
    /// selection source (FDMSG kind 3). Drained (closed) on link detach; only
    /// conns of the attached link park.
    /// Tokens are never reused.
    pending_fds: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    next_fd_token: u32 = 1,
    /// Server-allocated ids the engine flagged as zwp_primary_selection_offer_v1
    /// via a SRVOBJ frame, keyed (conn_id << 32 | object_id). Server ids are one
    /// contiguous space shared with wl_data_offer, so the id value can't reveal
    /// the type; this set tells fd interception to watch primary_offer.receive
    /// (opcode 0) instead of data_offer.receive (opcode 1). Written by the
    /// link thread, read by app threads. An entry goes with its offer's
    /// destroy, a conn's entries when it closes.
    primary_offers: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The engine's own clipboard selection, as far as it sent it (FDMSG
    /// own_pipe; FEATURE selection_cache): its generation and the payloads
    /// received so far. Replaced by a newer generation's first payload,
    /// dropped at the engine's word (generation 0) and at link detach.
    own_cache: OwnCache = .{},
    /// Writes the own selection into receivers' pipes (one thread, capped).
    writer: pipe_writer.Writer = .{},
    /// own_pipe frames that carried a payload's bytes (tests: what crossed
    /// the link).
    own_payloads_received: usize = 0,
    /// A selection receive with a non-pipe fd was refused (logged once).
    non_pipe_logged: std.atomic.Value(bool) = .init(false),

    /// Only once every relay thread has finished (tests).
    pub fn deinit(relay: *Relay) void {
        std.debug.assert(relay.conns.count() == 0 and relay.link == null);
        relay.writer.deinit(relay.io);
        relay.own_cache.drop();
        var fd_it = relay.pending_fds.valueIterator();
        while (fd_it.next()) |fd| _ = std.os.linux.close(fd.*);
        relay.pending_fds.deinit(relay.gpa);
        relay.conns.deinit(relay.gpa);
        relay.primary_offers.deinit(relay.gpa);
    }

    /// `link` loses a user. relay.mutex held.
    fn unuse(relay: *Relay, link: *Link) void {
        link.users -= 1;
        if (link.users == 0) relay.link_released.broadcast(relay.io);
    }

    /// The app link for `conn_id` with a reference taken, or null if gone.
    fn acquireApp(relay: *Relay, conn_id: u32) ?*AppLink {
        relay.mutex.lockUncancelable(relay.io);
        defer relay.mutex.unlock(relay.io);
        const app = relay.conns.get(conn_id) orelse return null;
        app.refs += 1;
        return app;
    }

    fn releaseApp(relay: *Relay, app: *AppLink) void {
        relay.mutex.lockUncancelable(relay.io);
        app.refs -= 1;
        const last = app.refs == 0;
        relay.mutex.unlock(relay.io);
        if (last) app.destroy(relay.io, relay.gpa);
    }
};

/// `--link-on-demand`: no link is dialed until an app needs one. An app
/// that finds no link attached counts itself in `waiting` and waits for
/// the dial that wakes (`awaitDemand`, on main.zig's dial thread): the link
/// attaching takes it on as usual; the dial failing (`dialFailed`; the dial
/// is bounded, so a hung transport fails too) refuses every app waiting —
/// closed at once, so it fails fast instead of hanging. All under
/// `Relay.mutex`.
pub const OnDemand = struct {
    /// The --link SPEC as given (the refusal line names it).
    link_text: []const u8,
    /// Apps waiting for an engine. Zeroed by a failed dial (which refuses
    /// them all); an app taken on by an attaching link counts itself out.
    waiting: u32 = 0,
    /// Failed dials so far: an app that sees it move was refused.
    failures: u32 = 0,
    /// What the latest failed dial failed with.
    last_error: anyerror = error.ConnectFailed,
    /// Signalled when an app starts waiting (the dial thread sleeps on it).
    demand: Io.Condition = .init,
};

/// The stable prefix of the line logged (info) for each app an on-demand
/// relay refuses because no engine could be reached; documented for
/// embedders to match (README, usage text). Followed by the --link SPEC and
/// the reason in parentheses.
pub const refused_line = "wayland client refused: no engine on link ";

/// On demand, relay.mutex held: wait for the dial this app asks for (or
/// one already under way). True: a link is attached; false: the dial
/// failed and this app is refused.
fn awaitDial(relay: *Relay, od: *OnDemand) bool {
    const failures = od.failures;
    od.waiting += 1;
    od.demand.signal(relay.io);
    while (relay.link == null) {
        if (od.failures != failures) return false; // dialFailed counted us out
        relay.link_attached.waitUncancelable(relay.io, &relay.mutex);
    }
    // an app counted out by a failed dial that a later dial's link takes
    // on anyway is not in `waiting` any more
    if (od.failures == failures) od.waiting -= 1;
    return true;
}

/// On demand, the dial thread: block until some app waits for an engine.
pub fn awaitDemand(relay: *Relay) void {
    const od = &relay.on_demand.?;
    relay.mutex.lockUncancelable(relay.io);
    defer relay.mutex.unlock(relay.io);
    while (od.waiting == 0) od.demand.waitUncancelable(relay.io, &relay.mutex);
}

/// On demand, the dial thread: the dial `awaitDemand` woke for failed —
/// every app waiting is refused (and the next app dials again).
pub fn dialFailed(relay: *Relay, err: anyerror) void {
    const od = &relay.on_demand.?;
    relay.mutex.lockUncancelable(relay.io);
    od.failures +%= 1;
    od.waiting = 0;
    od.last_error = err;
    relay.mutex.unlock(relay.io);
    relay.link_attached.broadcast(relay.io);
}

/// Relay.own_cache: one generation's payloads, by the engine's blob index.
const OwnCache = struct {
    gen: u32 = 0,
    blobs: [core.compositor.own_selection_max_mimes]?*pipe_writer.Blob = @splat(null),

    /// relay.mutex held
    fn drop(self: *OwnCache) void {
        for (&self.blobs) |*b| if (b.*) |blob| {
            blob.unref();
            b.* = null;
        };
        self.gen = 0;
    }
};

/// Key for `Relay.primary_offers`.
fn srvObjKey(conn_id: u32, object_id: u32) u64 {
    return (@as(u64, conn_id) << 32) | object_id;
}

/// The write side of one app socket, shared by the app's own thread
/// (wl_buffer.release, frame callbacks) and the link thread (events,
/// keymap/pipe fd sends), so every write goes through `write_mutex` — one
/// unguarded send could land mid-batch and corrupt the wire stream.
/// Refcounted under relay.mutex: the app thread holds one reference, the
/// link thread takes one around each write; the last one closes the socket.
const AppLink = struct {
    stream: Io.net.Stream,
    write_mutex: Io.Mutex = .init,
    refs: u32 = 1,
    /// ACK serials the link thread hands to this conn's app thread (see the
    /// file comment). `ack_fd` is an eventfd the app thread polls beside the
    /// app socket; -1 when this relay sends no COMMIT (copy buffers and no
    /// virtgpu dmabufs): nothing is ever ACKed.
    ack_mutex: Io.Mutex = .init,
    acks: std.ArrayList(u32) = .empty,
    ack_fd: i32 = -1,
    /// DMABUF_CREATED frames the link thread hands to the app thread (also
    /// under `ack_mutex`). No wakeup: the app can only name the new buffer
    /// after the `created` event, which the link thread writes after the
    /// push; the app thread adopts before handling its next request.
    created: std.ArrayList(Created) = .empty,

    const Created = struct { params_id: u32, buffer_id: u32 };

    /// Link thread: a params.create made server wl_buffer `buffer_id`.
    fn pushCreated(self: *AppLink, io: Io, gpa: std.mem.Allocator, c: Created) void {
        self.ack_mutex.lockUncancelable(io);
        defer self.ack_mutex.unlock(io);
        self.created.append(gpa, c) catch std.log.err("dmabuf: out of memory, buffer {d} will not be shown", .{c.buffer_id});
    }

    /// Link thread: queue an ACK for the app thread and wake it.
    fn pushAck(self: *AppLink, io: Io, gpa: std.mem.Allocator, serial: u32) void {
        if (self.ack_fd < 0) return; // no COMMIT was ever sent: an unknown serial
        self.ack_mutex.lockUncancelable(io);
        const queued = self.acks.append(gpa, serial);
        self.ack_mutex.unlock(io);
        queued catch {
            std.log.err("ack queue: out of memory, ACK {d} lost", .{serial});
            return;
        };
        const one: u64 = 1;
        _ = linux.write(self.ack_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    fn write(self: *AppLink, io: Io, bytes: []const u8) !void {
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);
        var send_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &send_buf);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    fn sendWithFd(self: *AppLink, io: Io, bytes: []const u8, fd: i32) !void {
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);
        try shm.sendWithFd(self.stream.socket.handle, bytes, fd);
    }

    fn destroy(self: *AppLink, io: Io, gpa: std.mem.Allocator) void {
        self.stream.close(io);
        if (self.ack_fd >= 0) _ = linux.close(self.ack_fd);
        self.acks.deinit(gpa);
        self.created.deinit(gpa);
        gpa.destroy(self);
    }
};

/// Bind the wayland unix socket, taking over a stale socket file.
pub fn listenWayland(io: Io, socket_path: []const u8) !Io.net.Server {
    Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    const uaddr = try Io.net.UnixAddress.init(socket_path);
    return uaddr.listen(io, .{});
}

/// Wayland accept loop (blocks forever), one thread per app.
pub fn serveWayland(relay: *Relay, listener: *Io.net.Server) void {
    const io = relay.io;
    while (true) {
        const app = listener.accept(io) catch |err| {
            std.log.err("wayland accept failed: {t}", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveApp, .{ relay, app }) catch |err| {
            std.log.err("spawn failed: {t}", .{err});
            app.close(io);
            continue;
        };
        thread.detach();
    }
}

/// Serve one engine link until it closes or is taken over (blocks). On
/// return no relay thread references `link` any more. A link attaching while
/// another is attached kicks the old one and waits for it to detach; its app
/// conns are dropped — their compositor state lived in that engine.
pub fn serveLink(relay: *Relay, link: *Link) void {
    const io = relay.io;
    // what the relay can do, before anything else on this link (before any
    // CONN_OPEN): the engine's compositor offers dmabuf from it
    {
        // the dmabuf backend's (if any), then selection_cache: own-selection
        // payloads cross once (FDMSG own_pipe)
        var out: [dmabuf.Config.max_features_len + stream.feature_header_len]u8 = undefined;
        const n = if (relay.dmabuf) |cfg| cfg.featureFrames(out[0..dmabuf.Config.max_features_len]).len else 0;
        const cache = stream.encodeFeature(out[n..], .selection_cache, &.{});
        link.send(out[0 .. n + cache.len]) catch {}; // a dead link fails its recv below
    }
    relay.mutex.lockUncancelable(io);
    while (relay.link) |old| {
        old.users += 1; // keeps `old` alive across the unlocked kick
        relay.mutex.unlock(io);
        std.log.info("engine takeover: kicking the previous link", .{});
        old.kick();
        relay.mutex.lockUncancelable(io);
        relay.unuse(old);
        if (relay.link == old) relay.link_detached.waitUncancelable(io, &relay.mutex);
    }
    relay.link = link;
    relay.mutex.unlock(io);
    relay.link_attached.broadcast(io);
    std.log.info("engine attached", .{});

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(relay.gpa);
    while (true) {
        link.recv(relay.gpa, &msg) catch |err| {
            switch (err) {
                error.EndOfStream => {},
                // the peer went away (a page suspended or reloaded, a vsock
                // reset at snapshot restore): expected on a link that is
                // re-awaited. What is a real error (a bad record, a WS
                // protocol violation) was logged as one where it was seen.
                error.LinkGone => std.log.info("engine link dropped", .{}),
                error.OutOfMemory => std.log.err("engine link: {t}", .{err}),
            }
            break;
        };
        handleEngineMessage(relay, msg.items);
    }

    relay.mutex.lockUncancelable(io);
    relay.link = null;
    // routing state died with the engine: close parked clipboard fds, drop
    // its own selection's payloads (transfers of them end below)
    var fd_it = relay.pending_fds.valueIterator();
    while (fd_it.next()) |fd| _ = std.os.linux.close(fd.*);
    relay.pending_fds.clearRetainingCapacity();
    relay.own_cache.drop();
    // Wake this engine's app threads so they exit (apps can reconnect once
    // an engine returns). shutdown, not close: it unwedges a writer blocked
    // mid-send on a stuck app, and never blocks itself, so holding the relay
    // mutex (which keeps every AppLink alive) is fine.
    var dropped: usize = 0;
    var it = relay.conns.valueIterator();
    while (it.next()) |app| {
        app.*.stream.shutdown(io, .both) catch {};
        dropped += 1;
    }
    // under relay.mutex (relay → writer is the lock order; the writer never
    // waits holding its own): a link taking over can't start transfers
    // that this would then cancel
    relay.writer.dropAll(io);
    relay.mutex.unlock(io);
    relay.link_detached.broadcast(io);
    std.log.info("engine detached ({d} app conns dropped)", .{dropped});

    relay.mutex.lockUncancelable(io);
    while (link.users > 0) relay.link_released.waitUncancelable(io, &relay.mutex);
    relay.mutex.unlock(io);
}

/// Per-app-connection interception state. The wayland object model lives in
/// the engine; the relay keeps only what fd handling and buffer commits need.
const AppConn = struct {
    relay: *Relay,
    conn_id: u32,
    app: *AppLink,
    /// The engine link this conn is bound to, for its whole life.
    link: *Link,
    frames: Link.FrameCallbacks,
    /// Per-conn state of the relay's buffer backend.
    pixels: buffers.Conn,
    objects: core.objects.ObjectMap = .{},
    fds: shm.FdQueue = .{},
    /// wl_shm_pool object id → pool. Holds one ref; buffers hold their own
    /// (pool storage must survive wl_shm_pool.destroy while buffers live).
    pools: std.AutoHashMapUnmanaged(u32, *shm.Pool) = .empty,
    buffers: std.AutoHashMapUnmanaged(u32, Tracked) = .empty,
    /// zwp_linux_buffer_params_v1 id → the planes (fds) added so far.
    dmabuf_params: std.AutoHashMapUnmanaged(u32, dmabuf.Params) = .empty,
    /// params id → the buffer its `create` made, until the engine's
    /// DMABUF_CREATED names the server wl_buffer id (adoptCreated).
    dmabuf_creates: std.AutoHashMapUnmanaged(u32, *dmabuf.Buffer) = .empty,
    surfaces: std.AutoHashMapUnmanaged(u32, SurfaceState) = .empty,
    /// COMMIT notices not yet ACKed (handle backends, dmabuf virtgpu; a
    /// handful at most, so a list).
    pending: std.ArrayList(Pending) = .empty,
    /// The next COMMIT's serial: 1, 2, 3, … (never 0), one space for every
    /// COMMIT of this conn whatever its kind (STREAM.md).
    next_serial: u32 = 1,
    /// ACK serials taken from `app.acks` (swapped under its mutex).
    acks_taken: std.ArrayList(u32) = .empty,
    /// Frames produced by one app read burst; sent as ONE link message.
    batch: stream.Batch = .{},
    /// (frames == .relay) wl_surface.frame callback ids whose surface
    /// committed this burst; fired once the burst's message has been sent —
    /// see fireFrameCallbacks.
    frames_to_fire: std.ArrayList(u32) = .empty,
    /// Monotonic ns of the last frame-callback batch fired for this conn.
    last_frame_ns: i96 = 0,
    /// A virtgpu COMMIT of this conn went out past its fence wait (logged
    /// once per conn: no other client can use up the line).
    fence_timeout_logged: bool = false,

    fn init(relay: *Relay, conn_id: u32, app: *AppLink, link: *Link) AppConn {
        return .{
            .relay = relay,
            .conn_id = conn_id,
            .app = app,
            .link = link,
            .frames = link.frame_callbacks,
            .pixels = .init(relay.backend, relay.gpa, relay.io, conn_id, &relay.next_handle_id),
        };
    }

    fn advanceSerial(self: *AppConn) void {
        self.next_serial +%= 1;
        if (self.next_serial == 0) self.next_serial = 1;
    }

    fn surfaceState(self: *AppConn, surface_id: u32) !*SurfaceState {
        const gop = try self.surfaces.getOrPut(self.relay.gpa, surface_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    fn unrefPool(self: *AppConn, pool: *shm.Pool) void {
        pool.refs -= 1;
        if (pool.refs == 0) {
            pool.deinit();
            self.relay.gpa.destroy(pool);
        }
    }

    /// wl_buffer `id` is gone (destroyed, or its id reused): forgotten with
    /// no release, ever — a late release would hit whatever object takes
    /// the id next. Its un-ACKed COMMITs keep their handle (the backend's).
    /// A surface it was attached to keeps its content but no longer names
    /// it: a later commit without attach presents nothing new, and an attach
    /// still pending latches no buffer (as libwayland treats a destroyed
    /// pending buffer: attach(NULL)) — whatever object reuses the id.
    fn forgetBuffer(self: *AppConn, id: u32, tracked: Tracked) !void {
        self.dropSource(tracked.source);
        for (self.pending.items) |*p| {
            if (p.buffer_id == id) p.buffer_id = 0;
        }
        var surf_it = self.surfaces.valueIterator();
        while (surf_it.next()) |s| {
            if (s.buffer_id == id) s.buffer_id = 0;
        }
        try self.pixels.bufferDestroyed(id, &self.batch);
    }

    fn dropSource(self: *AppConn, source: Tracked.Source) void {
        switch (source) {
            .shm => |b| self.unrefPool(b.pool),
            .dmabuf => |d| {
                d.deinit(self.relay.gpa);
                self.relay.gpa.destroy(d);
            },
        }
    }

    /// Conn teardown (app hung up, engine CONN_CLOSE, link dropped):
    /// everything unsent is dropped — no releases, no HANDLE_CLOSE; the
    /// backend releases every handle backing.
    fn deinit(self: *AppConn) void {
        const gpa = self.relay.gpa;
        self.pixels.deinit();
        // un-ACKed virtgpu COMMITs: their GEM references go (the engine
        // forgets the conn's COMMITs with it)
        for (self.pending.items) |p| switch (p.hold) {
            .gem => |g| g.importer.unref(g.handle),
            .backend => {},
        };
        self.pending.deinit(gpa);
        self.acks_taken.deinit(gpa);
        var buf_it = self.buffers.valueIterator();
        while (buf_it.next()) |tracked| self.dropSource(tracked.source);
        var params_it = self.dmabuf_params.valueIterator();
        while (params_it.next()) |params| params.deinit();
        self.dmabuf_params.deinit(gpa);
        var create_it = self.dmabuf_creates.valueIterator();
        while (create_it.next()) |b| self.dropSource(.{ .dmabuf = b.* });
        self.dmabuf_creates.deinit(gpa);
        var pool_it = self.pools.valueIterator();
        while (pool_it.next()) |pool| self.unrefPool(pool.*);
        var surf_it = self.surfaces.valueIterator();
        while (surf_it.next()) |s| s.pending_frames.deinit(gpa);
        self.pools.deinit(gpa);
        self.buffers.deinit(gpa);
        self.surfaces.deinit(gpa);
        self.objects.deinit(gpa);
        self.batch.deinit(gpa);
        self.frames_to_fire.deinit(gpa);
        self.fds.drain();
    }
};

/// A wl_buffer the relay tracks, with its release ledger (STREAM.md
/// "Buffer release"; the decision is `settleRelease`) — the same ledger
/// whatever the buffer is made of.
const Tracked = struct {
    source: Source,
    /// An attach-latching commit of this buffer has not been released.
    owed: bool = false,
    /// COMMIT notices naming this buffer not yet ACKed (always 0 under the
    /// copy backend, so a release follows its commit at once).
    busy: u32 = 0,

    const Source = union(enum) {
        /// wl_shm_pool.create_buffer: a range of a refcounted pool
        shm: shm.Buffer,
        /// zwp_linux_buffer_params_v1.create/create_immed (owned)
        dmabuf: *dmabuf.Buffer,
    };
};

/// One COMMIT notice awaiting its ACK.
const Pending = struct {
    serial: u32,
    /// the committed wl_buffer; 0 once it was destroyed (nothing to release)
    buffer_id: u32,
    /// what the COMMIT keeps alive until its ACK
    hold: union(enum) {
        /// a buffer backend's (its handle), handed back to `acked`
        backend: u32,
        /// dmabuf virtgpu: a reference on the resource's GEM handle
        gem: struct { importer: *virtgpu.Importer, handle: u32 },
    },
};

/// Per-surface state the commit path needs.
const SurfaceState = struct {
    buffer_id: u32 = 0,
    /// True from wl_surface.attach until the commit that latches it. Only
    /// that commit owes a wl_buffer.release (see finishCommit).
    pending_attach: bool = false,
    damage: shm.DamageList = .{},
    /// What the engine was last shown of this surface: the buffer's dims
    /// and the kind of content. A change of either (or the first commit)
    /// forces one full-buffer damage rect — the engine's copy of the
    /// surface is resized, or was made by another path (a GL presenter
    /// starts a blank texture when stream/handle pixels follow a GPU image,
    /// and the copy backend's shadow knows nothing of a GPU image), hence
    /// gone. Reset by a commit that showed nothing (`forgetShown`), so the
    /// next one is full too (the engine missed changes). Two resources of
    /// the same size alternating (a swapchain) are one kind: damage is
    /// relative to the previous commit's content whichever buffer held it,
    /// and each buffer holds the whole surface (wl_surface.attach).
    last_w: u32 = 0,
    last_h: u32 = 0,
    last_kind: ShownKind = .none,

    /// wl_surface.set_buffer_scale — multiplies wl_surface.damage rects into
    /// buffer coords. Technically double-buffered state, but apps set it
    /// before their first commit, and a scale flip changes the buffer dims
    /// which forces a full-buffer rect anyway.
    scale: i32 = 1,
    /// The surface got a wp_viewport, or a buffer transform other than
    /// normal: wl_surface.damage (surface-local) then maps to buffer px
    /// through crop/scale/rotation the relay does not model, so it counts as
    /// full-buffer damage (shadow trimming, copy backend, still ships only
    /// what changed). Sticky for the viewport: wp_viewport.destroy is not
    /// tracked back to its surface (conservative, never wrong).
    viewport: bool = false,
    transform: i32 = 0,
    /// (frames == .relay) wl_surface.frame callback ids requested since the
    /// last commit; moved to AppConn.frames_to_fire when this surface
    /// commits. Intercepted so the engine never sees the request — otherwise
    /// both sides would fire wl_callback.done (a fatal double-fire).
    pending_frames: std.ArrayList(u32) = .empty,

    const ShownKind = enum {
        none,
        /// BUFFER frames or a COMMIT of kind shm (wl_shm, readback dmabufs)
        pixels,
        /// a COMMIT of kind virtgpu
        resource,
    };

    fn forgetShown(self: *SurfaceState) void {
        self.last_w = 0;
        self.last_h = 0;
        self.last_kind = .none;
    }
};

/// One thread per app: register with the attached engine (waiting for one
/// if needed), then relay until either side goes away. Public so tests can
/// drive a conn over a socketpair without a listener.
pub fn serveApp(relay: *Relay, app_stream: Io.net.Stream) void {
    const io = relay.io;
    const gpa = relay.gpa;
    const app = gpa.create(AppLink) catch {
        app_stream.close(io);
        return;
    };
    app.* = .{ .stream = app_stream };

    relay.mutex.lockUncancelable(io);
    if (relay.on_demand) |*od| {
        if (relay.link == null and !awaitDial(relay, od)) {
            const reason = od.last_error;
            relay.mutex.unlock(io);
            std.log.info(refused_line ++ "{s} ({t})", .{ od.link_text, reason });
            app.destroy(io, gpa); // the app reads EOF: its first round trip fails
            return;
        }
    } else while (relay.link == null) {
        std.log.info("app connected, waiting for an engine...", .{});
        relay.link_attached.waitUncancelable(io, &relay.mutex);
    }
    const link = relay.link.?;
    // relay.dmabuf is read only now, with a link attached: an on-demand
    // dial may have set it (see its field)
    const commits = relay.backend != .copy or if (relay.dmabuf) |cfg| cfg.backend.sendsCommits() else false;
    if (commits) {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) {
            relay.mutex.unlock(io);
            std.log.err("eventfd failed: {t}", .{linux.errno(rc)});
            app.destroy(io, gpa);
            return;
        }
        app.ack_fd = @intCast(rc);
    }
    const conn_id = relay.next_conn_id;
    // conn 0 is reserved (STREAM.md CONN_OPEN): never handed out, even
    // after 2^32 conns
    relay.next_conn_id +%= 1;
    if (relay.next_conn_id == 0) relay.next_conn_id = 1;
    relay.conns.put(gpa, conn_id, app) catch {
        relay.mutex.unlock(io);
        app.destroy(io, gpa);
        return;
    };
    link.users += 1;
    relay.mutex.unlock(io);

    var conn: AppConn = .init(relay, conn_id, app, link);
    std.log.info("app conn {d} attached", .{conn_id});
    const open_frame = stream.encodeConnFrame(.conn_open, conn_id);
    link.send(&open_frame) catch {};

    if (conn.objects.put(gpa, 1, core.protocol.find("wl_display").?, 1)) {
        appReadLoop(&conn) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed, error.LinkGone => {},
            else => std.log.err("conn {d} error: {t}", .{ conn_id, err }),
        };
    } else |_| {}
    conn.deinit();

    relay.mutex.lockUncancelable(io);
    _ = relay.conns.remove(conn_id);
    // drop this conn's primary-offer type flags (SRVOBJ registrations).
    // Restart the scan after each removal — removing invalidates the iterator.
    scan: while (true) {
        var po_it = relay.primary_offers.keyIterator();
        while (po_it.next()) |k| {
            if (@as(u32, @intCast(k.* >> 32)) == conn_id) {
                _ = relay.primary_offers.remove(k.*);
                continue :scan;
            }
        }
        break;
    }
    const still_attached = relay.link == link;
    relay.mutex.unlock(io);
    relay.writer.dropConn(io, conn_id); // its receives of the own selection end (and none start)
    if (still_attached) {
        const close_frame = stream.encodeConnFrame(.conn_close, conn_id);
        link.send(&close_frame) catch {};
    }
    std.log.info("app conn {d} closed", .{conn_id});

    // last touches of the relay: after unuse, serveLink may return
    relay.mutex.lockUncancelable(io);
    app.refs -= 1;
    const last = app.refs == 0;
    relay.unuse(link);
    relay.mutex.unlock(io);
    if (last) app.destroy(io, gpa);
}

fn appReadLoop(conn: *AppConn) !void {
    // recvmsg directly on the socket: SCM_RIGHTS fds are lost unless every
    // read supplies a control buffer (libwayland does the same).
    var buf: [64 * 1024]u8 = undefined;
    var fill: usize = 0;
    const sock = conn.app.stream.socket.handle;

    while (true) {
        // handle backends also wake for ACKs the link thread handed over
        if (conn.app.ack_fd < 0 or try waitAppOrAcks(conn, sock)) {
            const n = try shm.recvWithFds(sock, buf[fill..], &conn.fds);
            if (n == 0) return error.EndOfStream;
            fill += n;

            var off: usize = 0;
            while (fill - off >= wire.header_size) {
                const header = try wire.Header.parse(buf[off .. off + wire.header_size]);
                if (fill - off < header.size) break;
                try handleAppMessage(conn, header, buf[off .. off + header.size]);
                off += header.size;
            }
            std.mem.copyForwards(u8, buf[0 .. fill - off], buf[off..fill]);
            fill -= off;
        }

        // everything this burst produced goes out as one link message...
        try sendBatch(conn.link, conn.batch.finish(), stream.max_record_len);
        conn.batch.clear();
        conn.pixels.flushed(); // queued HANDLE_CLOSEs are out: drop their backings
        // ...then, once it has been sent, pace the apps: fire the frame
        // callbacks whose commit rode this burst.
        if (conn.frames == .relay) fireFrameCallbacks(conn);
    }
}

/// Send a burst's frames as one link message — or, when that would exceed
/// `max` (the record bound a stream link's peer enforces, STREAM.md: a burst
/// of large incompressible commits can), as several, split at frame
/// boundaries; order is kept. A single frame larger than `max` goes alone
/// (a stream link refuses it, dropping this conn).
pub fn sendBatch(link: *Link, msg: []const u8, max: usize) !void {
    var rest = msg;
    while (rest.len > max) {
        var n: usize = 0;
        while (true) {
            const len = (stream.parseNext(rest[n..]) catch unreachable).consumed; // frames we built
            if (n > 0 and n + len > max) break;
            n += len;
            if (n >= max) break;
        }
        try link.send(rest[0..n]);
        rest = rest[n..];
    }
    if (rest.len > 0) try link.send(rest);
}

/// Block until the app socket is readable (true) or ACKs were queued; the
/// ACKs are settled here, before the app's next requests. False = only ACKs.
fn waitAppOrAcks(conn: *AppConn, sock: i32) !bool {
    var pfds = [2]linux.pollfd{
        .{ .fd = sock, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = conn.app.ack_fd, .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        const rc = linux.poll(&pfds, pfds.len, -1);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => |e| {
                std.log.err("conn {d}: poll failed: {t}", .{ conn.conn_id, e });
                return error.ReadFailed;
            },
        }
    }
    if (pfds[1].revents != 0) try drainAcks(conn);
    return pfds[0].revents != 0;
}

/// Settle every ACK the link thread queued for this conn. The eventfd is
/// reset BEFORE the queue is taken, so an ACK pushed in between re-arms it.
fn drainAcks(conn: *AppConn) !void {
    const app = conn.app;
    const io = conn.relay.io;
    var count: u64 = undefined;
    _ = linux.read(app.ack_fd, std.mem.asBytes(&count), @sizeOf(u64)); // EAGAIN: nothing new
    app.ack_mutex.lockUncancelable(io);
    std.mem.swap(std.ArrayList(u32), &app.acks, &conn.acks_taken);
    app.ack_mutex.unlock(io);
    defer conn.acks_taken.clearRetainingCapacity();
    for (conn.acks_taken.items) |serial| try ackCommit(conn, serial);
}

/// The engine consumed COMMIT `serial`: its buffer is one notice less busy
/// (maybe releasable now) and its handle one reference lighter.
fn ackCommit(conn: *AppConn, serial: u32) !void {
    for (conn.pending.items, 0..) |p, i| {
        if (p.serial != serial) continue;
        _ = conn.pending.swapRemove(i);
        if (p.buffer_id != 0) {
            const tracked = conn.buffers.getPtr(p.buffer_id).?; // forgetBuffer zeroes buffer_id
            tracked.busy -= 1;
            settleRelease(conn, p.buffer_id, tracked);
        }
        switch (p.hold) {
            .backend => |token| try conn.pixels.acked(token, &conn.batch),
            .gem => |g| g.importer.unref(g.handle),
        }
        return;
    }
    // unknown serial (a duplicate, or never sent): ignored, per STREAM.md
}

/// Minimum spacing between frame-callback batches for one conn (~60 Hz). Two
/// backpressures pace an app's render loop under Link.FrameCallbacks.relay:
/// the link send draining (fireFrameCallbacks runs after the send, so a
/// slow/full pipe already delays us — the win on a real network) and this
/// floor. On localhost the pipe drains instantly, so without the floor an app
/// would be told "draw again" the instant it committed and spin unbounded (a
/// menu fade shipped ~470 frames, over-driving nautilus). The floor
/// reproduces the browser's rAF cadence there; on a link where the drain
/// already exceeds it, it costs nothing.
const frame_floor_ns: u64 = 16 * std.time.ns_per_ms;

/// Fire wl_callback.done + wl_display.delete_id for every frame callback whose
/// surface committed this burst, straight back to the app. done carries a
/// millisecond timestamp; delete_id lets libwayland reuse the client id. Both
/// are whole wire messages written under the app link's write_mutex (safe
/// against the link thread's concurrent event/fd writes).
fn fireFrameCallbacks(conn: *AppConn) void {
    if (conn.frames_to_fire.items.len == 0) return;
    const done_op = comptime core.protocol.find("wl_callback").?.eventIndex("done").?;
    const delete_op = comptime core.protocol.find("wl_display").?.eventIndex("delete_id").?;

    // hold the app to at most one frame batch per frame_floor_ns. Sleeping this
    // conn's own thread IS the throttle: the app blocks waiting for done before
    // drawing, so it has nothing to send meanwhile. (Only render-loop apps that
    // out-pace the floor ever sleep; slow/idle apps fire immediately.)
    const io = conn.relay.io;
    var now_ns = Io.Clock.now(.awake, io).nanoseconds;
    if (conn.last_frame_ns != 0) {
        const since: i96 = now_ns - conn.last_frame_ns;
        if (since >= 0 and since < frame_floor_ns) {
            io.sleep(.{ .nanoseconds = @as(i96, frame_floor_ns) - since }, .awake) catch {};
            now_ns = Io.Clock.now(.awake, io).nanoseconds;
        }
    }
    conn.last_frame_ns = now_ns;
    const time_ms: u32 = @truncate(@as(u64, @intCast(now_ns)) / std.time.ns_per_ms);

    // done(cb, time_ms) then delete_id(cb): both header + one uint = 12 bytes.
    const msg_len = wire.header_size + 4;
    for (conn.frames_to_fire.items) |cb| {
        var pair: [2 * msg_len]u8 = undefined;
        _ = wire.encodeMessage(pair[0..msg_len], cb, done_op, &.{.{ .uint = time_ms }});
        _ = wire.encodeMessage(pair[msg_len..], 1, delete_op, &.{.{ .uint = cb }});
        conn.app.write(io, &pair) catch break; // app gone; its thread tears down
        conn.objects.remove(cb); // client id freed by delete_id
    }
    conn.frames_to_fire.clearRetainingCapacity();
}

fn handleAppMessage(conn: *AppConn, header: wire.Header, msg_bytes: []const u8) !void {
    const gpa = conn.relay.gpa;
    // a params.create answered since: the buffer's server id may be named now
    if (conn.dmabuf_creates.count() > 0) try adoptCreated(conn);
    const entry = conn.objects.get(header.object_id);
    // wl_surface.commit defers its buffer handling until AFTER the commit is
    // forwarded as WIRE (see the commit branch), so the engine latches the
    // commit's state before it sees the pixels. 0 = not a commit.
    var commit_surface: u32 = 0;

    // Server-allocated ids are not in the request-side object map. They are one
    // contiguous space (objects.zig) shared by wl_data_offer (default) and
    // zwp_primary_selection_offer_v1 (flagged via SRVOBJ into primary_offers).
    // Both carry an fd-bearing `receive` we must intercept (park the pipe
    // write-end fd) — but at DIFFERENT opcodes, so pick by the offer's type.
    // Everything else on these ids (e.g. destroy) forwards as plain WIRE.
    if (header.object_id >= core.objects.server_id_base) {
        const relay = conn.relay;
        relay.mutex.lockUncancelable(relay.io);
        const is_primary = relay.primary_offers.contains(srvObjKey(conn.conn_id, header.object_id));
        relay.mutex.unlock(relay.io);
        const primary = comptime core.protocol.find("zwp_primary_selection_offer_v1").?;
        const receive_op = if (is_primary)
            comptime primary.requestIndex("receive").?
        else
            comptime core.protocol.find("wl_data_offer").?.requestIndex("receive").?;
        if (header.opcode == receive_op) {
            try interceptPipeReceive(conn, msg_bytes);
            return; // not forwarded as WIRE
        }
        if (is_primary and header.opcode == comptime primary.requestIndex("destroy").?) {
            relay.mutex.lockUncancelable(relay.io);
            _ = relay.primary_offers.remove(srvObjKey(conn.conn_id, header.object_id));
            relay.mutex.unlock(relay.io);
        }
    }

    decode: {
        const e = entry orelse break :decode;
        if (header.opcode >= e.iface.requests.len) break :decode;
        const msg = &e.iface.requests[header.opcode];
        var vals: [wire.max_args]wire.Value = undefined;
        const args = wire.decodeArgs(msg_bytes[wire.header_size..], msg.args, &vals) catch break :decode;
        try conn.objects.trackNewIds(gpa, msg, args, e.version);

        const iname = e.iface.name;
        if (std.mem.eql(u8, iname, "wl_shm") and std.mem.eql(u8, msg.name, "create_pool")) {
            const fd = conn.fds.pop() orelse {
                std.log.err("conn {d}: create_pool without fd", .{conn.conn_id});
                return error.ReadFailed;
            };
            const size = std.math.cast(usize, args[2].int) orelse {
                std.log.err("conn {d}: create_pool with size {d}", .{ conn.conn_id, args[2].int });
                _ = std.os.linux.close(fd);
                return error.ReadFailed;
            };
            const pool = gpa.create(shm.Pool) catch |err| {
                _ = std.os.linux.close(fd);
                return err;
            };
            pool.* = .{ .fd = fd, .size = size };
            const aux = conn.pixels.poolCreated(pool) catch |err| {
                pool.deinit();
                gpa.destroy(pool);
                return err;
            };
            const old = conn.pools.fetchPut(gpa, args[0].new_id, pool) catch |err| {
                pool.deinit();
                gpa.destroy(pool);
                return err;
            };
            if (old) |kv| conn.unrefPool(kv.value); // a live id reused: client bug
            // FDMSG instead of WIRE so the engine can track the pool object
            try conn.batch.fdMsg(gpa, conn.conn_id, .shm_pool, msg_bytes, aux);
            return;
        } else if (std.mem.eql(u8, iname, "wl_shm_pool")) {
            if (std.mem.eql(u8, msg.name, "resize")) {
                if (conn.pools.get(header.object_id)) |pool| {
                    pool.size = std.math.cast(usize, args[0].int) orelse {
                        std.log.err("conn {d}: pool resize to {d}", .{ conn.conn_id, args[0].int });
                        return error.ReadFailed;
                    };
                    try conn.pixels.poolResized(pool, &conn.batch);
                }
            } else if (std.mem.eql(u8, msg.name, "destroy")) {
                if (conn.pools.fetchRemove(header.object_id)) |kv| conn.unrefPool(kv.value);
            } else if (std.mem.eql(u8, msg.name, "create_buffer")) {
                if (conn.pools.get(header.object_id)) |pool| track: {
                    const buffer: shm.Buffer = .{
                        .pool = pool,
                        .offset = std.math.cast(u32, args[1].int) orelse break :track,
                        .width = std.math.cast(u32, args[2].int) orelse break :track,
                        .height = std.math.cast(u32, args[3].int) orelse break :track,
                        .stride = std.math.cast(u32, args[4].int) orelse break :track,
                        .format = args[5].uint,
                    };
                    // untracked (negative geometry) buffers are never read
                    // or released; the engine owns the protocol error
                    pool.refs += 1;
                    const old = conn.buffers.fetchPut(gpa, args[0].new_id, .{ .source = .{ .shm = buffer } }) catch |err| {
                        pool.refs -= 1;
                        return err;
                    };
                    if (old) |kv| try conn.forgetBuffer(kv.key, kv.value); // a live id reused: client bug
                }
            }
        } else if (std.mem.eql(u8, iname, "wp_viewporter") and std.mem.eql(u8, msg.name, "get_viewport")) {
            (try conn.surfaceState(args[1].object)).viewport = true;
        } else if (std.mem.eql(u8, iname, "zwp_linux_dmabuf_v1") and std.mem.eql(u8, msg.name, "create_params")) {
            const old = try conn.dmabuf_params.fetchPut(gpa, args[0].new_id, .{});
            if (old) |kv| { // a live id reused: client bug
                var params = kv.value;
                params.deinit();
            }
        } else if (std.mem.eql(u8, iname, "zwp_linux_buffer_params_v1")) {
            if (std.mem.eql(u8, msg.name, "add")) {
                try interceptDmabufAdd(conn, header.object_id, args, msg_bytes);
                return; // FDMSG, not WIRE
            } else if (std.mem.eql(u8, msg.name, "create_immed")) {
                // the client named the wl_buffer: it is tracked from now on
                if (try takeDmabufParams(conn, header.object_id, args[1..], "buffer", args[0].new_id)) |b| {
                    const old = conn.buffers.fetchPut(gpa, args[0].new_id, .{ .source = .{ .dmabuf = b } }) catch |err| {
                        conn.dropSource(.{ .dmabuf = b });
                        return err;
                    };
                    if (old) |kv| try conn.forgetBuffer(kv.key, kv.value); // a live id reused: client bug
                }
            } else if (std.mem.eql(u8, msg.name, "create")) {
                // the engine allocates the wl_buffer (a server id) and says
                // which with DMABUF_CREATED, before its `created` event
                if (try takeDmabufParams(conn, header.object_id, args, "params", header.object_id)) |b| {
                    const old = conn.dmabuf_creates.fetchPut(gpa, header.object_id, b) catch |err| {
                        conn.dropSource(.{ .dmabuf = b });
                        return err;
                    };
                    if (old) |kv| conn.dropSource(.{ .dmabuf = kv.value });
                }
            } else if (msg.destructor) {
                if (conn.dmabuf_params.fetchRemove(header.object_id)) |kv| {
                    var params = kv.value;
                    params.deinit();
                }
            }
        } else if (std.mem.eql(u8, iname, "wl_buffer") and msg.destructor) {
            if (conn.buffers.fetchRemove(header.object_id)) |kv| try conn.forgetBuffer(kv.key, kv.value);
            // a server id (params.create) is never reused: drop its type too
            if (header.object_id >= core.objects.server_id_base) conn.objects.remove(header.object_id);
        } else if (std.mem.eql(u8, iname, "wl_surface")) {
            if (std.mem.eql(u8, msg.name, "frame")) {
                if (conn.frames == .relay) {
                    // Record and DON'T forward: the relay fires done itself
                    // (fireFrameCallbacks) after the next commit's burst is
                    // sent. The engine must never see the request or it
                    // would fire a second done → protocol error.
                    const state = try conn.surfaceState(header.object_id);
                    try state.pending_frames.append(gpa, args[0].new_id);
                    return;
                }
            } else if (std.mem.eql(u8, msg.name, "destroy")) {
                // Drop the per-surface state so a reused id starts clean. A
                // surface destroyed before its next commit never presents;
                // hand off its uncommitted frame callbacks so they still get
                // done+delete_id (the client-side id would otherwise leak).
                if (conn.surfaces.fetchRemove(header.object_id)) |kv| {
                    var state = kv.value;
                    conn.frames_to_fire.appendSlice(gpa, state.pending_frames.items) catch {};
                    state.pending_frames.deinit(gpa);
                    conn.pixels.surfaceDestroyed(header.object_id);
                }
                // fall through: the engine needs the destroy too
            } else if (std.mem.eql(u8, msg.name, "attach")) {
                const state = try conn.surfaceState(header.object_id);
                state.buffer_id = args[0].object;
                state.pending_attach = true;
            } else if (std.mem.eql(u8, msg.name, "damage") or std.mem.eql(u8, msg.name, "damage_buffer")) {
                const state = try conn.surfaceState(header.object_id);
                // wl_surface.damage is surface-local (logical) — scale to
                // buffer coords; damage_buffer is already buffer-local.
                // Saturate: clients damage INT32_MAX-sized rects (nautilus),
                // and clamped() cuts to buffer dims anyway.
                const surface_local = std.mem.eql(u8, msg.name, "damage");
                if (surface_local and (state.viewport or state.transform != 0)) {
                    state.damage.add(.{ .x = 0, .y = 0, .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) });
                } else {
                    const s: i32 = if (surface_local) state.scale else 1;
                    state.damage.add(.{
                        .x = args[0].int *| s,
                        .y = args[1].int *| s,
                        .w = args[2].int *| s,
                        .h = args[3].int *| s,
                    });
                }
            } else if (std.mem.eql(u8, msg.name, "set_buffer_scale")) {
                (try conn.surfaceState(header.object_id)).scale = @max(1, args[0].int);
            } else if (std.mem.eql(u8, msg.name, "set_buffer_transform")) {
                (try conn.surfaceState(header.object_id)).transform = args[0].int;
            } else if (std.mem.eql(u8, msg.name, "commit")) {
                // The pixels (BUFFER frame) MUST follow this commit's WIRE,
                // so the engine latches the commit's double-buffered state
                // (viewport destination → surface-local/CSS size, M11)
                // BEFORE presenting them. Emitting the BUFFER first leaves the
                // view reading the stale pre-commit size → the canvas backing
                // store grows (e.g. maximize to 1600×917) but its CSS box
                // stays at the old size. Deferred to after the WIRE append.
                commit_surface = header.object_id;
            }
        }
    }

    // forward as WIRE (default path, including opaque/unknown messages)
    try conn.batch.wire(gpa, conn.conn_id, msg_bytes);

    if (commit_surface != 0) {
        try finishCommit(conn, commit_surface);
        // this commit is the frame those pending callbacks pace: queue them
        // to fire once this burst has been sent. Fires whether or not the
        // commit shipped pixels — an app that commits without damage still
        // owes its callback, or its render loop would stall forever.
        if (conn.frames == .relay) {
            if (conn.surfaces.getPtr(commit_surface)) |state| {
                try conn.frames_to_fire.appendSlice(gpa, state.pending_frames.items);
                state.pending_frames.clearRetainingCapacity();
            }
        }
    }
}

/// The commit path. A commit that latches attach(B) makes a release of B
/// owed; the backend presents the commit (or doesn't), and a COMMIT notice
/// makes B busy until the engine ACKs it; then `settleRelease` decides.
/// COMMIT notices come from the buffer backend (handles: shm buffers) or
/// straight from here (dmabuf virtgpu: a named resource) — one serial
/// space and one ACK ledger per conn either way.
/// Ordering: everything here runs while the app's `wl_surface.commit` is
/// handled, after that request's WIRE was appended to the burst; nothing is
/// deferred or reordered, so a COMMIT reaches the link after the commit
/// request that made it and before any later request of the app.
fn finishCommit(conn: *AppConn, surface_id: u32) !void {
    const state = conn.surfaces.getPtr(surface_id) orelse return;
    defer state.damage.reset(); // per-commit state, consumed whatever happens
    const latched = state.pending_attach;
    state.pending_attach = false;
    // attach(null), or a buffer we never tracked: nothing to read or release
    const tracked = conn.buffers.getPtr(state.buffer_id) orelse return;
    if (latched) tracked.owed = true;
    // what the commit's buffer is to the engine: shm is pixels in a pool; a
    // dmabuf is whatever its backend makes of it
    const view: dmabuf.View = switch (tracked.source) {
        .shm => |b| .{ .pixels = b },
        .dmabuf => |d| if (conn.relay.dmabuf) |cfg| d.view(cfg.backend, conn.relay.gpa, conn.conn_id, state.buffer_id) else .unreadable,
    };
    const dmabuf_buffer: ?*dmabuf.Buffer = if (tracked.source == .dmabuf) tracked.source.dmabuf else null;

    present: {
        const width: u32, const height: u32 = switch (view) {
            .unreadable => {
                state.forgetShown();
                break :present;
            },
            .pixels => |buffer| dims: {
                if (dmabuf_buffer != null and conn.pixels != .copy) {
                    // readback pixels ride the copy path only (main.zig
                    // refuses the combination; a harness could still build it)
                    state.forgetShown();
                    break :present;
                }
                if (!buffer.fits()) {
                    // unreadable geometry: nothing presented, but the client
                    // gets its buffer back (withholding the release would
                    // stall it)
                    std.log.warn("conn {d}: buffer {d} ({d}x{d} stride {d} @{d}) exceeds its {d} B pool", .{ conn.conn_id, state.buffer_id, buffer.width, buffer.height, buffer.stride, buffer.offset, buffer.pool.size });
                    state.forgetShown();
                    break :present;
                }
                break :dims .{ buffer.width, buffer.height };
            },
            .resource => |r| .{ r.ref.width, r.ref.height },
        };
        const kind: SurfaceState.ShownKind = if (view == .resource) .resource else .pixels;
        // a new size or a new kind of content: the engine's copy is gone
        const resized = state.last_w != width or state.last_h != height or state.last_kind != kind;

        var rect_buf: [shm.DamageList.cap]shm.Rect = undefined;
        const rects = state.damage.clamped(&rect_buf, width, height, resized);
        if (rects.len == 0) break :present; // nothing changed, nothing ships
        try conn.pending.ensureUnusedCapacity(conn.relay.gpa, 1);
        const serial = conn.next_serial;
        switch (view) {
            .unreadable => unreachable,
            .pixels => |buffer| {
                // a dmabuf's pending GPU writes land, and its CPU view is
                // synced, around the copy path's read
                if (dmabuf_buffer) |d| d.beginRead(conn.conn_id);
                defer if (dmabuf_buffer) |d| d.endRead();
                const settle = try conn.pixels.commit(.{
                    .conn_id = conn.conn_id,
                    .surface_id = surface_id,
                    .buffer_id = state.buffer_id,
                    .buffer = buffer,
                    .damage = rects,
                    .resized = resized,
                    .serial = serial,
                }, &conn.batch);
                switch (settle) {
                    .now => {},
                    .unshown => {
                        state.forgetShown();
                        break :present;
                    },
                    .busy => |b| {
                        std.debug.assert(b.serial == serial);
                        conn.advanceSerial();
                        tracked.busy += 1;
                        conn.pending.appendAssumeCapacity(.{ .serial = serial, .buffer_id = state.buffer_id, .hold = .{ .backend = b.token } });
                    },
                }
            },
            .resource => |r| {
                // the client's GPU work for this frame was submitted before
                // its commit request; wait (bounded) for the buffer's
                // implicit write fences so the engine's renderer has it —
                // unless --no-fence-wait says the device orders it anyway
                const fence_wait = conn.relay.dmabuf.?.fence_wait;
                if (fence_wait and !dmabuf_buffer.?.awaitWrites(virtgpu_fence_wait_ms)) {
                    // expected now and then (a first frame compiling its
                    // shaders): the COMMIT still follows the client's
                    // submission on the way to the host
                    if (!conn.fence_timeout_logged)
                        std.log.info("conn {d}: dmabuf buffer {d} (resource {d}): implicit fence not signalled within {d} ms; COMMIT sent without waiting longer (expected on slow first frames; logged once per conn)", .{ conn.conn_id, state.buffer_id, r.ref.resource, virtgpu_fence_wait_ms });
                    conn.fence_timeout_logged = true;
                }
                try conn.batch.virtgpuCommit(conn.relay.gpa, conn.conn_id, surface_id, serial, r.ref, rects);
                conn.advanceSerial();
                r.importer.ref(r.gem); // the resource lives until this COMMIT's ACK
                tracked.busy += 1;
                conn.pending.appendAssumeCapacity(.{ .serial = serial, .buffer_id = state.buffer_id, .hold = .{ .gem = .{ .importer = r.importer, .handle = r.gem } } });
                // the engine now shows a GPU image: the copy backend's
                // shadow no longer mirrors it and would trim the next
                // pixels away as "unchanged" (a full rect alone is not
                // enough). Dropped here, not at the switch back: an unshown
                // commit in between forgets the kind.
                conn.pixels.surfaceDestroyed(surface_id);
            },
        }
        state.last_w = width;
        state.last_h = height;
        state.last_kind = kind;
    }
    settleRelease(conn, state.buffer_id, tracked);
}

/// How long a virtgpu COMMIT waits for its dmabuf's implicit write fences
/// before going out anyway: long enough for a frame the host is still
/// executing, short enough that a hung GPU only slows the app's relay
/// thread (other apps and the link are unaffected). Skipped altogether
/// with `--no-fence-wait` (dmabuf.Config.fence_wait).
const virtgpu_fence_wait_ms = 100;

/// zwp_linux_buffer_params_v1.add(fd, plane_idx, offset, stride, mod_hi,
/// mod_lo): keep the plane's fd with its params and forward the message as
/// FDMSG kind dmabuf (the compositor tracks planes for its protocol errors).
/// Without a dmabuf backend the global was never advertised: the client
/// bound it anyway, and the conn goes (its fd is closed, the stream stays
/// in step).
fn interceptDmabufAdd(conn: *AppConn, params_id: u32, args: []const wire.Value, msg_bytes: []const u8) !void {
    const fd = conn.fds.pop() orelse {
        std.log.err("conn {d}: dmabuf add without fd", .{conn.conn_id});
        return error.ReadFailed;
    };
    if (conn.relay.dmabuf == null) {
        _ = linux.close(fd);
        std.log.warn("conn {d}: dmabuf add, but this relay takes no dmabufs; dropping the conn", .{conn.conn_id});
        return error.ReadFailed;
    }
    if (conn.dmabuf_params.getPtr(params_id)) |params| {
        _ = params.add(args[1].uint, .{
            .fd = fd,
            .offset = args[2].uint,
            .stride = args[3].uint,
            .modifier = (@as(u64, args[4].uint) << 32) | args[5].uint,
        });
    } else _ = linux.close(fd); // params never seen: nothing will use the fd
    try conn.batch.fdMsg(conn.relay.gpa, conn.conn_id, .dmabuf, msg_bytes, &.{});
}

/// create/create_immed (`a` = width, height, format, flags): the params'
/// planes become a buffer, which a naming backend names now (virtgpu;
/// `label`/`id` say which object in its log). Null if the params are
/// unknown or empty (the compositor raises the protocol error; nothing to
/// track).
fn takeDmabufParams(conn: *AppConn, params_id: u32, a: []const wire.Value, label: []const u8, id: u32) !?*dmabuf.Buffer {
    const params = conn.dmabuf_params.getPtr(params_id) orelse return null;
    if (params.planes[0] == null) return null;
    const b = try conn.relay.gpa.create(dmabuf.Buffer);
    b.* = params.take(a[0].int, a[1].int, a[2].uint, a[3].uint);
    if (conn.relay.dmabuf) |cfg| b.prepare(cfg.backend, conn.conn_id, label, id);
    return b;
}

/// Move buffers whose params.create the engine has answered (DMABUF_CREATED,
/// queued by the link thread) into the buffer table under their server id.
/// Runs before every app request while a create is outstanding, so the
/// buffer is tracked before the app's first request naming it.
fn adoptCreated(conn: *AppConn) !void {
    const app = conn.app;
    const io = conn.relay.io;
    const gpa = conn.relay.gpa;
    var taken: std.ArrayList(AppLink.Created) = .empty;
    defer taken.deinit(gpa);
    app.ack_mutex.lockUncancelable(io);
    std.mem.swap(std.ArrayList(AppLink.Created), &app.created, &taken);
    app.ack_mutex.unlock(io);
    for (taken.items) |c| {
        const kv = conn.dmabuf_creates.fetchRemove(c.params_id) orelse continue;
        if (c.buffer_id < core.objects.server_id_base) { // not a server id: a confused engine
            conn.dropSource(.{ .dmabuf = kv.value });
            continue;
        }
        const old = conn.buffers.fetchPut(gpa, c.buffer_id, .{ .source = .{ .dmabuf = kv.value } }) catch |err| {
            conn.dropSource(.{ .dmabuf = kv.value });
            return err;
        };
        if (old) |o| try conn.forgetBuffer(o.key, o.value);
        // so its wl_buffer.destroy decodes (client ids come from trackNewIds)
        try conn.objects.put(gpa, c.buffer_id, core.protocol.find("wl_buffer").?, 1);
    }
}

/// THE release decision, after every commit and every ACK, always on the
/// conn's app thread: release B when a release is owed and no COMMIT naming
/// B awaits its ACK — one wl_buffer.release per busy period, never one
/// without an attach. GTK commits WITHOUT attach for empty frames, and a
/// duplicate release makes GDK destroy the cairo surface it is painting
/// into (nautilus SIGSEGV in end_frame under constant resize). Under the
/// copy backend busy is always 0: released right after the commit-time
/// copy, before the batch is even sent, so the client's buffer-reuse loop
/// never waits for the engine. The engine never releases.
fn settleRelease(conn: *AppConn, buffer_id: u32, tracked: *Tracked) void {
    if (!tracked.owed or tracked.busy != 0) return;
    tracked.owed = false;
    sendRelease(conn, buffer_id);
}

fn sendRelease(conn: *AppConn, buffer_id: u32) void {
    const release_op = comptime core.protocol.find("wl_buffer").?.eventIndex("release").?;
    var msg: [wire.header_size]u8 = undefined;
    (wire.Header{ .object_id = buffer_id, .opcode = release_op, .size = wire.header_size }).write(&msg);
    conn.app.write(conn.relay.io, &msg) catch {}; // app gone; its thread tears down
}

/// wl_data_offer.receive / zwp_primary_selection_offer_v1.receive(mime, fd):
/// park the fd under a fresh token and ship the wire message + token to the
/// engine (FDMSG kind 3). The engine routes it to the selection source and
/// echoes the token back with the source's send event.
fn interceptPipeReceive(conn: *AppConn, msg_bytes: []const u8) !void {
    const relay = conn.relay;
    const fd = conn.fds.pop() orelse {
        std.log.err("conn {d}: offer receive without fd", .{conn.conn_id});
        return error.ReadFailed;
    };
    if (msg_bytes.len > 512) { // mime string; sane ones are tiny
        std.log.err("conn {d}: oversized receive message ({d}B), dropping", .{ conn.conn_id, msg_bytes.len });
        _ = std.os.linux.close(fd);
        return;
    }
    // Pipes only (STREAM.md FDMSG pipe). A parked fd is closed on the link
    // thread (forwarded, answered, or at detach under relay.mutex) or
    // written by the selection writer, and only a pipe's write and close
    // are sure not to block there: a FUSE file's close waits for its
    // server's FLUSH reply, a tty's for its output to drain, O_NONBLOCK or
    // not. Refused here, on this conn's own thread — what a client's
    // strange fd can stall is its own conn — and never sent on: the
    // receiver reads EOF.
    if (!pipe_writer.isPipe(fd)) {
        if (!conn.relay.non_pipe_logged.swap(true, .monotonic))
            std.log.warn("conn {d}: a selection receive with an fd that is not a pipe — refused (the receiver reads EOF); clients pass pipes", .{conn.conn_id});
        _ = std.os.linux.close(fd);
        return;
    }

    relay.mutex.lockUncancelable(relay.io);
    if (relay.link != conn.link) {
        // this conn's link detached (and closed the parked fds): it is
        // going away; parking now would keep the fd until the NEXT detach
        relay.mutex.unlock(relay.io);
        _ = std.os.linux.close(fd);
        return;
    }
    const token = relay.next_fd_token;
    relay.next_fd_token += 1;
    relay.pending_fds.put(relay.gpa, token, fd) catch {
        relay.mutex.unlock(relay.io);
        _ = std.os.linux.close(fd);
        return;
    };
    relay.mutex.unlock(relay.io);

    var aux: [4]u8 = undefined;
    std.mem.writeInt(u32, &aux, token, .little);
    conn.batch.fdMsg(relay.gpa, conn.conn_id, .pipe, msg_bytes, &aux) catch |err| {
        relay.mutex.lockUncancelable(relay.io);
        const parked = relay.pending_fds.fetchRemove(token);
        relay.mutex.unlock(relay.io);
        if (parked) |kv| _ = std.os.linux.close(kv.value); // else a detach closed it
        return err;
    };
}

/// How long a pipe read (the engine reading a source's selection) may take
/// in all; a write of the engine's own selection has pipe_writer's
/// deadline_ms (the same 5 s).
pub const pipe_deadline_ms = pipe_writer.deadline_ms;
/// Largest selection the relay reads for the engine, whatever it asks.
pub const pipe_read_max: u32 = 64 << 20;

/// A receive of the engine's own selection, answered (FDMSG own_pipe, or
/// pipe with the bytes from an engine that doesn't use own_pipe): write
/// `blob` into the fd parked under the receive's token — on the writer
/// thread, capped — unless its conn went meanwhile. Takes `fd` and the
/// caller's blob reference. The check here is unlocked by the time start()
/// runs; a conn that closes in between is caught by the writer's
/// tombstone for it (dropConn), so its fd is closed at once all the same.
fn serveOwnReceive(relay: *Relay, conn_id: u32, fd: i32, blob: *pipe_writer.Blob) void {
    relay.mutex.lockUncancelable(relay.io);
    const live = relay.conns.contains(conn_id);
    relay.mutex.unlock(relay.io);
    if (!live) {
        blob.unref();
        _ = linux.close(fd);
        return;
    }
    relay.writer.start(relay.io, relay.gpa, conn_id, fd, blob);
}

/// FDMSG own_pipe (STREAM.md): keep a payload's bytes if they came, then
/// serve the parked receive from the kept copy (EOF without one); gen 0
/// drops the copy.
fn handleOwnPipe(relay: *Relay, conn_id: u32, aux: []const u8) void {
    const io = relay.io;
    const m = stream.OwnPipe.decode(aux) catch {
        std.log.err("own_pipe fdmsg with bad aux len {d}", .{aux.len});
        return;
    };
    const valid = m.gen != 0 and m.blob < core.compositor.own_selection_max_mimes;
    if (m.gen != 0 and !valid) std.log.err("own_pipe fdmsg naming payload {d}", .{m.blob});
    // the copy, made before taking the lock (up to 64 MiB)
    const fresh: ?*pipe_writer.Blob = if (valid and m.flags & stream.OwnPipe.has_bytes != 0)
        pipe_writer.Blob.create(relay.gpa, m.bytes) catch null
    else
        null;
    relay.mutex.lockUncancelable(io);
    if (!valid) {
        if (m.gen == 0) relay.own_cache.drop();
    } else if (m.flags & stream.OwnPipe.has_bytes != 0) {
        relay.own_payloads_received += 1;
        if (relay.own_cache.gen != m.gen) relay.own_cache.drop();
        relay.own_cache.gen = m.gen;
        if (relay.own_cache.blobs[m.blob]) |old| old.unref();
        relay.own_cache.blobs[m.blob] = fresh; // null: out of memory, receives read EOF
    }
    const parked = if (m.token != 0) relay.pending_fds.fetchRemove(m.token) else null;
    const blob: ?*pipe_writer.Blob = if (valid and relay.own_cache.gen == m.gen)
        if (relay.own_cache.blobs[m.blob]) |b| b.ref() else null
    else
        null;
    relay.mutex.unlock(io);
    const fd = (parked orelse {
        if (blob) |b| b.unref();
        if (m.token != 0) std.log.err("own_pipe fdmsg with unknown token {d}", .{m.token});
        return;
    }).value;
    if (blob) |b| return serveOwnReceive(relay, conn_id, fd, b);
    _ = linux.close(fd); // nothing to write: the receiver reads EOF
}

/// FDMSG pipe_read from the engine: `wire_bytes` is a source's
/// send(mime, fd) event for conn `conn_id`, aux = read id ++ max bytes.
/// Make a pipe, send the event with its write end, read the other end on a
/// thread, and answer with pipe_read (aux = read id ++ status ++ bytes).
/// Every read gets exactly one answer while the link stays attached.
fn startPipeRead(relay: *Relay, conn_id: u32, wire_bytes: []const u8, aux: []const u8) void {
    const io = relay.io;
    if (aux.len != 8 or wire_bytes.len < wire.header_size) {
        std.log.err("pipe_read fdmsg with bad aux len {d}", .{aux.len});
        return;
    }
    const read_id = std.mem.readInt(u32, aux[0..4], .little);
    const max = @min(std.mem.readInt(u32, aux[4..8], .little), pipe_read_max);
    relay.mutex.lockUncancelable(io);
    const link = relay.link orelse {
        relay.mutex.unlock(io);
        return; // detached: no answer is owed to a gone engine
    };
    link.users += 1; // the reader's; it lets go after answering
    relay.mutex.unlock(io);
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS)
        return finishPipeRead(relay, link, conn_id, read_id, .failed, &.{});
    const sent = if (relay.acquireApp(conn_id)) |app| blk: {
        defer relay.releaseApp(app);
        app.sendWithFd(io, wire_bytes, fds[1]) catch break :blk false;
        break :blk true;
    } else false;
    _ = linux.close(fds[1]); // the source holds it now: EOF when it closes it
    if (!sent) {
        _ = linux.close(fds[0]);
        return finishPipeRead(relay, link, conn_id, read_id, .failed, &.{});
    }
    const thread = std.Thread.spawn(.{}, readPipe, .{ relay, link, conn_id, read_id, max, fds[0] }) catch {
        _ = linux.close(fds[0]);
        return finishPipeRead(relay, link, conn_id, read_id, .failed, &.{});
    };
    thread.detach();
}

/// The reader thread: read until EOF, `max` exceeded, the deadline, or the
/// link detaching (polls in short slices to notice), then answer.
fn readPipe(relay: *Relay, link: *Link, conn_id: u32, read_id: u32, max: u32, fd: i32) void {
    defer _ = linux.close(fd);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(relay.gpa);
    const status: stream.PipeReadStatus = status: {
        const deadline = Io.Clock.now(.awake, relay.io).toMilliseconds() + pipe_deadline_ms;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const left = deadline - Io.Clock.now(.awake, relay.io).toMilliseconds();
            if (left <= 0) break :status .timeout;
            relay.mutex.lockUncancelable(relay.io);
            const attached = relay.link == link;
            relay.mutex.unlock(relay.io);
            if (!attached) break :status .failed;
            var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const prc = linux.poll(&pfd, 1, @intCast(@min(left, 100)));
            if (linux.errno(prc) == .INTR or prc == 0) continue;
            if (linux.errno(prc) != .SUCCESS) break :status .failed;
            const rc = linux.read(fd, &chunk, chunk.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                else => break :status .failed,
            }
            // EOF is all of it, whether or not the source is still
            // connected: it is every Wayland receiver's only completion
            // signal, and a source may hand the write to a child and hang
            // up first (wl-copy --paste-once). One killed mid-write looks
            // the same here as to any receiver (STREAM.md status 0).
            if (rc == 0) break :status .ok;
            if (data.items.len + rc > max) break :status .too_large;
            data.appendSlice(relay.gpa, chunk[0..rc]) catch break :status .failed;
        }
    };
    finishPipeRead(relay, link, conn_id, read_id, status, if (status == .ok) data.items else &.{});
}

/// Send a pipe_read answer (if `link` is still the attached one) and drop
/// the reader's use of the link.
fn finishPipeRead(relay: *Relay, link: *Link, conn_id: u32, read_id: u32, status: stream.PipeReadStatus, bytes: []const u8) void {
    defer {
        relay.mutex.lockUncancelable(relay.io);
        relay.unuse(link);
        relay.mutex.unlock(relay.io);
    }
    const aux = relay.gpa.alloc(u8, 8 + bytes.len) catch return;
    defer relay.gpa.free(aux);
    std.mem.writeInt(u32, aux[0..4], read_id, .little);
    std.mem.writeInt(u32, aux[4..8], @intFromEnum(status), .little);
    @memcpy(aux[8..], bytes);
    const frame = relay.gpa.alloc(u8, 13 + 4 + aux.len) catch return;
    defer relay.gpa.free(frame);
    _ = stream.encodeFdMsg(frame, conn_id, .pipe_read, &.{}, aux);
    relay.mutex.lockUncancelable(relay.io);
    const attached = relay.link == link;
    relay.mutex.unlock(relay.io);
    if (attached) link.send(frame) catch {};
}

/// CLOCK_MONOTONIC now, less `age_us` (never below 0), in ns.
fn presentedTime(io: Io, age_us: u32) u64 {
    const now: u64 = @intCast(@max(0, Io.Clock.now(.awake, io).nanoseconds));
    return now -| @as(u64, age_us) * std.time.ns_per_us;
}

/// One message from the engine: one or more packed frames.
fn handleEngineMessage(relay: *Relay, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const p = stream.parseNext(rest) catch |err| {
            std.log.err("bad engine frame: {t}", .{err});
            return;
        };
        rest = rest[p.consumed..];
        handleEngineFrame(relay, p.frame);
    }
}

fn handleEngineFrame(relay: *Relay, frame: stream.Frame) void {
    const io = relay.io;
    switch (frame) {
        .wire => |w| {
            const app = relay.acquireApp(w.conn_id) orelse return; // app already gone
            defer relay.releaseApp(app);
            app.write(io, w.bytes) catch {}; // app gone; its thread tears down
        },
        .srvobj => |s| {
            // the engine flagged a server id's type (only primary offers are
            // announced; see STREAM.md). Record it so this conn's fd
            // interception watches the right receive opcode. Only for a live
            // conn: its teardown (under the same lock) drops its flags, and a
            // flag recorded after that would never go. The offer's destroy
            // request drops its flag (handleAppMessage).
            if (s.kind == @intFromEnum(stream.SrvObjKind.primary_offer)) {
                relay.mutex.lockUncancelable(io);
                if (relay.conns.contains(s.conn_id))
                    relay.primary_offers.put(relay.gpa, srvObjKey(s.conn_id, s.object_id), {}) catch {};
                relay.mutex.unlock(io);
            }
        },
        .conn_close => |conn_id| {
            // the compositor wants the app gone: shutdown wakes the app
            // thread's blocking read; it cleans up
            const app = relay.acquireApp(conn_id) orelse return;
            defer relay.releaseApp(app);
            app.stream.shutdown(io, .both) catch {};
        },
        .fdmsg => |f| switch (f.kind) {
            @intFromEnum(stream.FdMsgKind.memfd) => {
                const app = relay.acquireApp(f.conn_id) orelse return;
                defer relay.releaseApp(app);
                const fd = shm.createMemfd("wland-keymap", f.aux) catch |err| {
                    std.log.err("keymap memfd failed: {t}", .{err});
                    return;
                };
                defer _ = std.os.linux.close(fd); // SCM_RIGHTS dups it into the app
                app.sendWithFd(io, f.wire_bytes, fd) catch {};
            },
            @intFromEnum(stream.FdMsgKind.pipe_read) => startPipeRead(relay, f.conn_id, f.wire_bytes, f.aux),
            @intFromEnum(stream.FdMsgKind.own_pipe) => handleOwnPipe(relay, f.conn_id, f.aux),
            @intFromEnum(stream.FdMsgKind.pipe) => {
                // a selection source's send(mime, fd) event: attach the fd
                // parked under the echoed token
                if (f.aux.len < 4) {
                    std.log.err("pipe fdmsg with bad aux len {d}", .{f.aux.len});
                    return;
                }
                const token = std.mem.readInt(u32, f.aux[0..4], .little);
                relay.mutex.lockUncancelable(io);
                const parked = relay.pending_fds.fetchRemove(token);
                relay.mutex.unlock(io);
                const fd = (parked orelse {
                    std.log.err("pipe fdmsg with unknown token {d}", .{token});
                    return;
                }).value;
                // no wire message, bytes after the token: the compositor's
                // own selection from an engine that ignores FEATURE
                // selection_cache — written like an own_pipe's, from a copy
                // made for this receive alone
                if (f.wire_bytes.len == 0 and f.aux.len > 4) {
                    const blob = pipe_writer.Blob.create(relay.gpa, f.aux[4..]) catch {
                        _ = linux.close(fd);
                        return;
                    };
                    return serveOwnReceive(relay, f.conn_id, fd, blob);
                }
                defer _ = std.os.linux.close(fd); // SCM_RIGHTS dups it into the app
                // no wire message: the offer's source is gone — closing the
                // write end is the whole answer (the receiver reads EOF)
                if (f.wire_bytes.len == 0) return;
                const app = relay.acquireApp(f.conn_id) orelse return;
                defer relay.releaseApp(app);
                app.sendWithFd(io, f.wire_bytes, fd) catch {};
            },
            else => std.log.err("unsupported fdmsg kind {d} from engine", .{f.kind}),
        },
        .ack => |a| {
            // hand it to the conn's app thread, which owns the ledger (see
            // the file comment); a closed conn's ACKs are ignored
            const app = relay.acquireApp(a.conn_id) orelse return;
            defer relay.releaseApp(app);
            app.pushAck(io, relay.gpa, a.serial);
        },
        .dmabuf_created => |d| {
            // the app thread owns the buffer table: queue it there, before
            // the `created` event (a later frame) reaches the app
            const app = relay.acquireApp(d.conn_id) orelse return;
            defer relay.releaseApp(app);
            app.pushCreated(io, relay.gpa, .{ .params_id = d.params_id, .buffer_id = d.buffer_id });
        },
        .presented => |p| {
            // the engine's time is the page's clock; the app compares with
            // CLOCK_MONOTONIC (wp_presentation.clock_id), which is ours. The
            // frame began age_us before the engine sent this: now − age is
            // that moment plus the link's one-way latency.
            const app = relay.acquireApp(p.conn_id) orelse return;
            defer relay.releaseApp(app);
            var msg: [64]u8 = undefined;
            if (p.bytes.len > msg.len) {
                std.log.err("PRESENTED with a {d}-byte event", .{p.bytes.len});
                return;
            }
            @memcpy(msg[0..p.bytes.len], p.bytes);
            stream.stampPresented(msg[0..p.bytes.len], presentedTime(io, p.age_us)) catch {
                std.log.err("PRESENTED with a {d}-byte event", .{p.bytes.len});
                return;
            };
            app.write(io, msg[0..p.bytes.len]) catch {};
        },
        else => std.log.err("unexpected {t} frame from engine", .{std.meta.activeTag(frame)}),
    }
}

test "sendBatch splits a burst over the record bound at frame boundaries, in order" {
    const gpa = std.testing.allocator;
    const Capture = struct {
        sent: std.ArrayList([]u8) = .empty,
        fn send(ctx: *anyopaque, msg: []const u8) Link.SendError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.sent.append(std.testing.allocator, std.testing.allocator.dupe(u8, msg) catch unreachable) catch unreachable;
        }
        fn recv(_: *anyopaque, _: std.mem.Allocator, _: *std.ArrayList(u8)) Link.RecvError!void {
            return error.EndOfStream;
        }
        fn kick(_: *anyopaque) void {}
    };
    var cap: Capture = .{};
    defer {
        for (cap.sent.items) |m| gpa.free(m);
        cap.sent.deinit(gpa);
    }
    var link: Link = .{ .ctx = &cap, .vtable = &.{ .send = Capture.send, .recv = Capture.recv, .kick = Capture.kick }, .frame_callbacks = .engine };

    var batch: stream.Batch = .{};
    defer batch.deinit(gpa);
    try batch.wire(gpa, 1, &([_]u8{1} ** 40)); // 49 B
    try batch.handleClose(gpa, 1, 7); // 9 B
    try batch.wire(gpa, 2, &([_]u8{2} ** 100)); // 109 B: over the bound alone
    try batch.handleClose(gpa, 1, 8);
    try batch.handleClose(gpa, 1, 9);
    const msg = batch.finish();

    try sendBatch(&link, msg, 64);
    var lens: [8]usize = undefined;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (cap.sent.items, 0..) |m, i| {
        lens[i] = m.len;
        try joined.appendSlice(gpa, m);
        var rest: []const u8 = m; // whole frames only
        while (rest.len > 0) rest = rest[(try stream.parseNext(rest)).consumed..];
    }
    try std.testing.expectEqualSlices(usize, &.{ 58, 109, 18 }, lens[0..cap.sent.items.len]);
    try std.testing.expectEqualSlices(u8, msg, joined.items);

    // under the bound: one message, as ever
    for (cap.sent.items) |m| gpa.free(m);
    cap.sent.clearRetainingCapacity();
    try sendBatch(&link, msg, stream.max_record_len);
    try std.testing.expectEqual(@as(usize, 1), cap.sent.items.len);
}

test "a pipe fd intercepted by a conn whose link already detached is closed, not parked" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var relay: Relay = .{ .io = threaded.io(), .gpa = gpa };
    defer relay.deinit();
    var dead: Link = undefined; // the conn's link: no longer relay.link
    var app: AppLink = .{ .stream = undefined };
    var conn: AppConn = .init(&relay, 1, &app, &dead);
    defer conn.deinit();

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(pipe_fds[0]);
    conn.fds.fds[0] = pipe_fds[1];
    conn.fds.len = 1;
    var msg: [16]u8 = undefined;
    _ = wire.encodeMessage(&msg, core.objects.server_id_base, 1, &.{});
    try interceptPipeReceive(&conn, &msg);
    try std.testing.expectEqual(@as(usize, 0), relay.pending_fds.count());
    // the write end is closed: the read end sees EOF
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(pipe_fds[0], &byte, 1));
}

test "a selection receive whose fd is not a pipe is refused at once: closed, not parked, not sent on" {
    std.testing.log_level = .err; // the refusal warns
    defer std.testing.log_level = .warn;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var relay: Relay = .{ .io = threaded.io(), .gpa = gpa };
    defer relay.deinit();
    var link: Link = undefined; // attached: a pipe would be parked
    relay.link = &link;
    defer relay.link = null;
    var app: AppLink = .{ .stream = undefined };
    var conn: AppConn = .init(&relay, 1, &app, &link);
    defer conn.deinit();
    var msg: [16]u8 = undefined;
    _ = wire.encodeMessage(&msg, core.objects.server_id_base, 1, &.{});

    // a socket end (a FUSE file, a tty: closing one parked on the link
    // thread could block it; the socket stands in for "not a pipe")
    var sp: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sp));
    defer _ = linux.close(sp[1]);
    conn.fds.fds[0] = sp[0];
    conn.fds.len = 1;
    try interceptPipeReceive(&conn, &msg);
    // a regular file
    conn.fds.fds[0] = @intCast(linux.memfd_create("wland-test", linux.MFD.CLOEXEC));
    conn.fds.len = 1;
    try interceptPipeReceive(&conn, &msg);
    try std.testing.expectEqual(@as(usize, 0), relay.pending_fds.count());
    try std.testing.expectEqual(@as(usize, 0), conn.batch.bytes.items.len);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(sp[1], &byte, 1)); // EOF

    // a pipe is parked and sent on, as ever
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(pipe_fds[0]);
    conn.fds.fds[0] = pipe_fds[1];
    conn.fds.len = 1;
    try interceptPipeReceive(&conn, &msg);
    try std.testing.expectEqual(@as(usize, 1), relay.pending_fds.count());
    try std.testing.expect(conn.batch.bytes.items.len > 0);
}

test "a pipe token echoed with no wire message closes the parked fd: the receiver reads EOF" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var relay: Relay = .{ .io = threaded.io(), .gpa = gpa };
    defer relay.deinit();

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }));
    defer _ = linux.close(pipe_fds[0]);
    try relay.pending_fds.put(gpa, 9, pipe_fds[1]);

    // the engine's answer for an offer whose source is gone (conn 1 need not
    // exist: nothing is sent to an app)
    var aux: [4]u8 = undefined;
    std.mem.writeInt(u32, &aux, 9, .little);
    var frame: [32]u8 = undefined;
    const msg = stream.encodeFdMsg(&frame, 1, .pipe, &.{}, &aux);
    handleEngineMessage(&relay, msg);

    try std.testing.expectEqual(@as(usize, 0), relay.pending_fds.count());
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.read(pipe_fds[0], &byte, 1));
}

test "own selection frames: an old engine's pipe bytes and own_pipe payloads go through the writer; a payload the relay lacks, or a gone conn, reads EOF; gen 0 drops the copy" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var relay: Relay = .{ .io = threaded.io(), .gpa = gpa };
    defer relay.deinit();
    var app: AppLink = .{ .stream = undefined };
    try relay.conns.put(gpa, 1, &app); // a live receiving conn (never written to)
    defer _ = relay.conns.remove(1);

    const Park = struct {
        fn park(r: *Relay, token: u32) !i32 {
            var fds: [2]i32 = undefined;
            try std.testing.expectEqual(@as(usize, 0), linux.pipe2(&fds, .{ .CLOEXEC = true }));
            try r.pending_fds.put(r.gpa, token, fds[1]);
            return fds[0];
        }
        fn readAll(fd: i32, out: []u8) !usize {
            defer _ = linux.close(fd);
            var n: usize = 0;
            while (true) {
                const rc = linux.read(fd, out[n..].ptr, out.len - n);
                try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
                if (rc == 0) return n;
                n += rc;
            }
        }
        fn ownPipe(r: *Relay, conn: u32, m: stream.OwnPipe) void {
            var aux: [64]u8 = undefined;
            m.writeHeader(aux[0..stream.OwnPipe.header_len]);
            @memcpy(aux[stream.OwnPipe.header_len..][0..m.bytes.len], m.bytes);
            var frame: [128]u8 = undefined;
            handleEngineMessage(r, stream.encodeFdMsg(&frame, conn, .own_pipe, &.{}, aux[0 .. stream.OwnPipe.header_len + m.bytes.len]));
        }
    };
    var out: [64]u8 = undefined;

    // an engine that doesn't use own_pipe: token ++ bytes, every receive
    const r1 = try Park.park(&relay, 1);
    var aux: [16]u8 = undefined;
    std.mem.writeInt(u32, aux[0..4], 1, .little);
    @memcpy(aux[4..9], "hello");
    var frame: [64]u8 = undefined;
    handleEngineMessage(&relay, stream.encodeFdMsg(&frame, 1, .pipe, &.{}, aux[0..9]));
    try std.testing.expectEqualStrings("hello", out[0..try Park.readAll(r1, &out)]);

    // own_pipe: the bytes once, then the kept copy
    const r2 = try Park.park(&relay, 2);
    Park.ownPipe(&relay, 1, .{ .token = 2, .gen = 7, .blob = 3, .flags = stream.OwnPipe.has_bytes, .bytes = "kept" });
    try std.testing.expectEqualStrings("kept", out[0..try Park.readAll(r2, &out)]);
    const r3 = try Park.park(&relay, 3);
    Park.ownPipe(&relay, 1, .{ .token = 3, .gen = 7, .blob = 3, .flags = 0, .bytes = "" });
    try std.testing.expectEqualStrings("kept", out[0..try Park.readAll(r3, &out)]);
    try std.testing.expectEqual(@as(usize, 1), relay.own_payloads_received);
    // a payload it never got, another generation: EOF
    const r4 = try Park.park(&relay, 4);
    Park.ownPipe(&relay, 1, .{ .token = 4, .gen = 7, .blob = 4, .flags = 0, .bytes = "" });
    try std.testing.expectEqual(@as(usize, 0), try Park.readAll(r4, &out));
    const r5 = try Park.park(&relay, 5);
    Park.ownPipe(&relay, 1, .{ .token = 5, .gen = 8, .blob = 3, .flags = 0, .bytes = "" });
    try std.testing.expectEqual(@as(usize, 0), try Park.readAll(r5, &out));
    const r6 = try Park.park(&relay, 6);
    // a conn gone meanwhile: EOF, nothing started
    const r7 = try Park.park(&relay, 7);
    Park.ownPipe(&relay, 2, .{ .token = 7, .gen = 7, .blob = 3, .flags = 0, .bytes = "" });
    try std.testing.expectEqual(@as(usize, 0), try Park.readAll(r7, &out));
    // gen 0: the copy goes; what is parked for later reads EOF
    Park.ownPipe(&relay, 0, .{ .token = 0, .gen = 0, .blob = 0, .flags = 0, .bytes = "" });
    try std.testing.expectEqual(@as(u32, 0), relay.own_cache.gen);
    try std.testing.expectEqual(@as(?*pipe_writer.Blob, null), relay.own_cache.blobs[3]);
    Park.ownPipe(&relay, 1, .{ .token = 6, .gen = 7, .blob = 3, .flags = 0, .bytes = "" });
    try std.testing.expectEqual(@as(usize, 0), try Park.readAll(r6, &out));
    try std.testing.expectEqual(@as(usize, 0), relay.pending_fds.count());
}
