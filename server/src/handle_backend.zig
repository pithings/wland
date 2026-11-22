// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Handle backend: ships no pixels. Each committed wl_buffer gets ONE buffer
//! handle — shared memory the engine reads in place — opened lazily just
//! before the buffer's first COMMIT notice and covering
//! `[page_floor(offset), offset + stride*height)` of its pool fd. COMMIT
//! frames (after the commit's WIRE) name the handle; the engine ACKs each
//! one once it has consumed the pixels (protocol/STREAM.md v2: HANDLE_OPEN,
//! HANDLE_CLOSE, COMMIT, ACK; "Buffer handles").
//!
//! Handle references: the wl_buffer while it lives, plus one per un-ACKed
//! COMMIT naming the handle. At zero the relay sends HANDLE_CLOSE and
//! releases the backing once that frame has gone out (`flushed`). A conn
//! ending (`deinit`) releases every backing with no HANDLE_CLOSE — the
//! engine drops a conn's handles on CONN_CLOSE / link close.
//!
//! What a handle IS comes from the Exporter: `procfd` (debug/tests: a dup of
//! the pool fd the engine opens via /proc/<pid>/fd/<fd>) or `kwshm` (an
//! unkernel /dev/kwshm export). The release ledger (owed/busy) is the
//! relay's; this file only owns handles. All of it runs on the conn's own
//! app thread (relay.zig hands ACKs over), so nothing here locks.

const std = @import("std");
const linux = std.os.linux;
const stream = @import("core").stream;
const shm = @import("shm.zig");
const buffers = @import("buffers.zig");
const kwshm = @import("kwshm.zig");

/// How handles are made; relay-global, chosen at startup.
pub const Exporter = union(enum) {
    procfd,
    /// the /dev/kwshm fd, open for the relay's life
    kwshm: i32,

    /// The resource keeping one handle's bytes alive.
    pub const Backing = union(enum) {
        /// our dup of the pool fd, named in the handle bytes
        procfd: i32,
        /// the kwshm export id
        kwshm: u32,
    };

    pub const Exported = struct {
        backing: Backing,
        kind: stream.HandleKind,
        bytes_buf: [stream.ProcfdHandle.len]u8 = undefined,
        bytes_len: usize,

        pub fn bytes(self: *const Exported) []const u8 {
            return self.bytes_buf[0..self.bytes_len];
        }
    };

    /// Make a handle for bytes `[start, start + len)` of `fd` (start is
    /// page aligned). The handle does not depend on `fd` staying open.
    pub fn exportRange(self: Exporter, fd: i32, start: u64, len: u64) !Exported {
        switch (self) {
            .procfd => {
                // the engine opens /proc/<pid>/fd/<dup> and keeps its own fd,
                // so ours only has to outlive the HANDLE_OPEN's processing;
                // holding it for the handle's life is what STREAM.md promises
                const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
                if (linux.errno(rc) != .SUCCESS) return error.DupFailed;
                var out: Exported = .{ .backing = .{ .procfd = @intCast(rc) }, .kind = .procfd, .bytes_len = stream.ProcfdHandle.len };
                (stream.ProcfdHandle{
                    .pid = @intCast(linux.getpid()),
                    .fd = @intCast(rc),
                    .offset = start,
                    .size = len,
                }).encode(out.bytes_buf[0..stream.ProcfdHandle.len]);
                return out;
            },
            .kwshm => |dev| {
                const e = try kwshm.exportRange(dev, fd, start, len);
                if (e.size < len) { // cannot happen (the kernel clamps only past EOF, which it refuses)
                    kwshm.release(dev, e.id);
                    return error.InvalidRange;
                }
                var out: Exported = .{ .backing = .{ .kwshm = e.id }, .kind = .kwshm, .bytes_len = stream.KwshmHandle.len };
                (stream.KwshmHandle{ .id = e.id, .size = e.size }).encode(out.bytes_buf[0..stream.KwshmHandle.len]);
                return out;
            },
        }
    }

    pub fn release(self: Exporter, backing: Backing) void {
        switch (backing) {
            .procfd => |fd| _ = linux.close(fd),
            .kwshm => |id| kwshm.release(self.kwshm, id),
        }
    }
};

const Handle = struct {
    refs: u32,
    backing: Exporter.Backing,
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    conn_id: u32,
    exporter: Exporter,
    /// relay-wide: handle ids are never reused within a run
    next_handle_id: *std.atomic.Value(u32),
    /// live wl_buffer id → its handle id; 0 = the export failed (the buffer
    /// stays unpresentable for its life — no retry per commit)
    by_buffer: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// every handle whose backing we hold, by handle id
    handles: std.AutoHashMapUnmanaged(u32, Handle) = .empty,
    /// backings of handles whose HANDLE_CLOSE sits in the unsent batch;
    /// released by `flushed` once it went out
    closing: std.ArrayList(Exporter.Backing) = .empty,

    pub fn init(gpa: std.mem.Allocator, conn_id: u32, exporter: Exporter, next_handle_id: *std.atomic.Value(u32)) Conn {
        return .{ .gpa = gpa, .conn_id = conn_id, .exporter = exporter, .next_handle_id = next_handle_id };
    }

    /// Conn teardown: every backing goes, no HANDLE_CLOSE (the conn or link
    /// is ending; the engine closes the conn's handles itself).
    pub fn deinit(self: *Conn) void {
        var it = self.handles.valueIterator();
        while (it.next()) |h| self.exporter.release(h.backing);
        self.flushed();
        self.handles.deinit(self.gpa);
        self.by_buffer.deinit(self.gpa);
        self.closing.deinit(self.gpa);
    }

    pub fn poolCreated(self: *Conn, pool: *shm.Pool) ![]const u8 {
        _ = self;
        _ = pool;
        return &.{}; // never mapped: the engine reads the client's pages
    }

    pub fn poolResized(self: *Conn, pool: *shm.Pool, batch: *stream.Batch) !void {
        // open handles never change (fixed size); a buffer's bytes never
        // move, and buffers past the old end get their handle at first commit
        _ = self;
        _ = pool;
        _ = batch;
    }

    pub fn surfaceDestroyed(self: *Conn, surface_id: u32) void {
        _ = self;
        _ = surface_id;
    }

    pub fn commit(self: *Conn, c: buffers.Commit, batch: *stream.Batch) !buffers.Settle {
        const b = c.buffer;
        if (b.format != stream.shm_format_argb8888 and b.format != stream.shm_format_xrgb8888) return .unshown;
        const page: u64 = std.heap.pageSize();
        const start: u64 = b.offset & ~(page - 1);
        const gop = try self.by_buffer.getOrPut(self.gpa, c.buffer_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
            gop.value_ptr.* = try self.open(c, start, batch);
        }
        const handle_id = gop.value_ptr.*;
        if (handle_id == 0) return .unshown;

        const serial = c.serial; // the conn's serial space (relay.zig)
        try batch.shmCommit(self.gpa, c.conn_id, c.surface_id, serial, .{
            .handle_id = handle_id,
            .offset = @intCast(b.offset - start),
            .width = b.width,
            .height = b.height,
            .stride = b.stride,
            .format = b.format,
        }, c.damage);
        self.handles.getPtr(handle_id).?.refs += 1;
        return .{ .busy = .{ .serial = serial, .token = handle_id } };
    }

    /// Export the buffer's range and queue its HANDLE_OPEN. 0 when the
    /// export failed (logged once: the buffer is never retried).
    fn open(self: *Conn, c: buffers.Commit, start: u64, batch: *stream.Batch) !u32 {
        const b = c.buffer;
        const len = @as(u64, b.offset) + @as(u64, b.stride) * b.height - start;
        const ex = self.exporter.exportRange(b.pool.fd, start, len) catch |err| {
            std.log.warn("conn {d}: buffer {d}: {t} handle for [{d}, +{d}) failed: {t}; it will not be shown", .{ self.conn_id, c.buffer_id, self.exporter, start, len, err });
            return 0;
        };
        const handle_id = self.next_handle_id.fetchAdd(1, .monotonic);
        self.handles.put(self.gpa, handle_id, .{ .refs = 1, .backing = ex.backing }) catch |err| {
            self.exporter.release(ex.backing);
            return err;
        };
        try batch.handleOpen(self.gpa, self.conn_id, handle_id, ex.kind, ex.bytes());
        return handle_id;
    }

    /// The wl_buffer is gone: drop its reference on its handle.
    pub fn bufferDestroyed(self: *Conn, buffer_id: u32, batch: *stream.Batch) !void {
        const kv = self.by_buffer.fetchRemove(buffer_id) orelse return;
        if (kv.value != 0) try self.unref(kv.value, batch);
    }

    /// The engine ACKed a COMMIT this backend sent (`token` = its handle).
    pub fn acked(self: *Conn, token: u32, batch: *stream.Batch) !void {
        try self.unref(token, batch);
    }

    /// The batch holding any queued HANDLE_CLOSE has been sent.
    pub fn flushed(self: *Conn) void {
        for (self.closing.items) |backing| self.exporter.release(backing);
        self.closing.clearRetainingCapacity();
    }

    fn unref(self: *Conn, handle_id: u32, batch: *stream.Batch) !void {
        const h = self.handles.getPtr(handle_id) orelse return;
        h.refs -= 1;
        if (h.refs > 0) return;
        const backing = h.backing;
        _ = self.handles.remove(handle_id);
        self.closing.append(self.gpa, backing) catch |err| {
            self.exporter.release(backing);
            return err;
        };
        try batch.handleClose(self.gpa, self.conn_id, handle_id);
    }
};
