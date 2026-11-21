// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! The buffer-backend interface: what the relay does with a wl_shm pool and with
//! a committed buffer's pixels. relay.zig owns everything protocol-shaped
//! (fd interception, pool refcounts, attach/damage/commit tracking and the
//! wl_buffer.release ledger: owed/busy, STREAM.md "Buffer release"); a
//! backend only decides how pixels reach the engine.
//!
//! One backend per relay, chosen at startup; each app conn holds that
//! backend's per-conn state in a `Conn`. Adding a backend = one tag, one
//! union field, one file implementing the methods below (the `inline else`
//! dispatch picks it up). All methods run on the conn's app thread.
//!
//! Backend method contract (`b` = the per-conn state):
//!   b.deinit()                       conn teardown: free everything, send
//!                                    nothing
//!   b.poolCreated(pool) ![]const u8  storage for a new pool; returns the
//!                                    FDMSG(shm_pool) aux bytes (always none)
//!   b.poolResized(pool, batch) !void pool.size already updated
//!   b.surfaceDestroyed(surface_id)   drop per-surface state
//!   b.commit(commit, batch) !Settle  ship the commit's pixels (or a notice)
//!                                    into `batch`, after the commit's WIRE
//!                                    frame, and say when its buffer may be
//!                                    released
//!   b.bufferDestroyed(id, batch) !void  wl_buffer.destroy (or id reuse)
//!   b.acked(token, batch) !void      the engine ACKed a `.busy` commit
//!   b.flushed()                      `batch` has been sent on the link

const std = @import("std");
const Io = std.Io;
const stream = @import("core").stream;
const shm = @import("shm.zig");
const copy = @import("copy_backend.zig");
const handle = @import("handle_backend.zig");

/// The relay's buffer mode (`--buffers`), with its relay-global state.
pub const Backend = union(enum) {
    /// mmap, snapshot at commit time, swizzle, shadow-trim, LZ4, ship
    /// BUFFER/BUFFER_LZ frames. Release is immediate.
    copy,
    /// handles name a dup of the pool fd, read via /proc/<pid>/fd/<fd>
    /// (debug/tests: relay and engine on one Linux host, same user)
    procfd,
    /// handles are unkernel /dev/kwshm exports; the /dev/kwshm fd, held
    /// open for the relay's life (closing it releases every export)
    kwshm: i32,
};

pub const Kind = std.meta.Tag(Backend);

/// A commit that latched a buffer with readable geometry and some damage.
pub const Commit = struct {
    conn_id: u32,
    surface_id: u32,
    buffer_id: u32,
    buffer: shm.Buffer,
    /// Buffer-local, clamped to the buffer, non-empty; one full-buffer rect
    /// when `resized`.
    damage: []const shm.Rect,
    /// First commit on this surface or the buffer dims changed: the engine's
    /// copy of the surface is gone, everything ships.
    resized: bool,
};

/// What became of a commit's buffer, and when its wl_buffer.release may go
/// out (relevant only if a release is owed — the relay decides that).
pub const Settle = union(enum) {
    /// The engine shows the commit's pixels and the backend is done reading
    /// the client's buffer: release now.
    now,
    /// Nothing reached the engine (unsupported format, no handle): release
    /// now; the engine has no current copy of the surface.
    unshown,
    /// A COMMIT notice went out: the engine reads the client's buffer until
    /// it ACKs `serial`. `token` is handed back to `acked` then.
    busy: struct { serial: u32, token: u32 },
};

pub const Conn = union(enum) {
    copy: copy.Conn,
    handle: handle.Conn,

    pub fn init(backend: Backend, gpa: std.mem.Allocator, io: Io, conn_id: u32, next_handle_id: *std.atomic.Value(u32)) Conn {
        return switch (backend) {
            .copy => .{ .copy = .{ .gpa = gpa, .io = io, .conn_id = conn_id } },
            .procfd => .{ .handle = .init(gpa, conn_id, .procfd, next_handle_id) },
            .kwshm => |dev| .{ .handle = .init(gpa, conn_id, .{ .kwshm = dev }, next_handle_id) },
        };
    }

    pub fn deinit(self: *Conn) void {
        switch (self.*) {
            inline else => |*b| b.deinit(),
        }
    }

    pub fn poolCreated(self: *Conn, pool: *shm.Pool) ![]const u8 {
        switch (self.*) {
            inline else => |*b| return b.poolCreated(pool),
        }
    }

    pub fn poolResized(self: *Conn, pool: *shm.Pool, batch: *stream.Batch) !void {
        switch (self.*) {
            inline else => |*b| return b.poolResized(pool, batch),
        }
    }

    pub fn surfaceDestroyed(self: *Conn, surface_id: u32) void {
        switch (self.*) {
            inline else => |*b| b.surfaceDestroyed(surface_id),
        }
    }

    pub fn commit(self: *Conn, c: Commit, batch: *stream.Batch) !Settle {
        switch (self.*) {
            inline else => |*b| return b.commit(c, batch),
        }
    }

    pub fn bufferDestroyed(self: *Conn, buffer_id: u32, batch: *stream.Batch) !void {
        switch (self.*) {
            inline else => |*b| return b.bufferDestroyed(buffer_id, batch),
        }
    }

    pub fn acked(self: *Conn, token: u32, batch: *stream.Batch) !void {
        switch (self.*) {
            inline else => |*b| return b.acked(token, batch),
        }
    }

    pub fn flushed(self: *Conn) void {
        switch (self.*) {
            inline else => |*b| b.flushed(),
        }
    }
};
