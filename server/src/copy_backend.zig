// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Copy backend: ships committed pixels to the engine inside the stream.
//! Pools are mmap'd read-only; at COMMIT time each damaged rect is swizzled
//! from wl_shm BGRA/BGRX into canvas-ready RGBA, trimmed against a per-surface
//! shadow of what the engine already shows, optionally LZ4-compressed, and
//! appended as a BUFFER (0x02) or BUFFER_LZ (0x07) frame. The client's buffer
//! is never read again after commit(), so the relay may release it at once
//! (commit() always settles `.now`).
//! See buffers.zig for the contract and STREAM.md for the frames.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const stream = core.stream;
const shm = @import("shm.zig");
const buffers = @import("buffers.zig");

/// Compress a BUFFER frame above this size; smaller payloads (cursor blinks,
/// tiny edits) skip the codec — the header/setup would dwarf any saving.
const lz_threshold: usize = 4096;

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn_id: u32,
    /// surface id → canvas-ready RGBA copy of the pixels last shipped (the
    /// full buffer, w*h*4). Clients over-damage (nautilus damages INT32_MAX
    /// rects; foot's cursor blink redamages whole rows), so before shipping a
    /// commit each damaged rect is swizzled and compared against this shadow,
    /// trimming the rect to the sub-region that actually changed (rects that
    /// changed nothing are dropped). (Re)allocated to the buffer dims, which
    /// forces a full ship anyway.
    shadows: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// Reused scratch for LZ4 of large payloads: lz_src holds the trimmed
    /// pixels assembled contiguously, lz_dst the compressed output.
    lz_src: std.ArrayList(u8) = .empty,
    lz_dst: std.ArrayList(u8) = .empty,
    /// bytes-shipped rate accounting (BUFFER frames only)
    ship_bytes: u64 = 0,
    ship_frames: u32 = 0,
    ship_window_ns: i96 = 0,
    /// Lifetime totals (logged at conn teardown) — the before/after instrument
    /// for the damage-trimming / compression perf work.
    total_ship_bytes: u64 = 0,
    total_ship_frames: u64 = 0,
    /// Uncompressed pixel bytes that WOULD have shipped without compression,
    /// summed over BUFFER + BUFFER_LZ frames; vs total_ship_bytes it shows
    /// the codec's win.
    total_raw_pixels: u64 = 0,
    /// Pixel bytes the CLAMPED (pre-trim) rects would have shipped — the
    /// baseline the shadow-trim is measured against.
    total_untrimmed_pixels: u64 = 0,

    pub fn deinit(self: *Conn) void {
        var it = self.shadows.valueIterator();
        while (it.next()) |s| if (s.len != 0) self.gpa.free(s.*);
        self.shadows.deinit(self.gpa);
        self.lz_src.deinit(self.gpa);
        self.lz_dst.deinit(self.gpa);
        if (self.total_ship_frames > 0)
            std.log.info("conn {d}: lifetime shipped {d} B in {d} BUFFER frames (trimmed pixels {d} B raw, {d} B pre-trim)", .{ self.conn_id, self.total_ship_bytes, self.total_ship_frames, self.total_raw_pixels, self.total_untrimmed_pixels });
    }

    pub fn poolCreated(self: *Conn, pool: *shm.Pool) ![]const u8 {
        pool.map() catch |err| {
            std.log.err("conn {d}: mmap pool failed: {t}", .{ self.conn_id, err });
            return error.ReadFailed;
        };
        return &.{};
    }

    pub fn poolResized(self: *Conn, pool: *shm.Pool, batch: *stream.Batch) !void {
        _ = batch;
        // remap so snapshots see the grown pool
        pool.remap() catch |err| {
            std.log.err("conn {d}: pool remap failed: {t}", .{ self.conn_id, err });
            return error.ReadFailed;
        };
    }

    pub fn surfaceDestroyed(self: *Conn, surface_id: u32) void {
        if (self.shadows.fetchRemove(surface_id)) |kv| {
            if (kv.value.len != 0) self.gpa.free(kv.value);
        }
    }

    // Copies hold nothing per buffer and never settle `.busy`: nothing to
    // drop, never ACKed, nothing waiting for the batch to go out.
    pub fn bufferDestroyed(self: *Conn, buffer_id: u32, batch: *stream.Batch) !void {
        _ = self;
        _ = buffer_id;
        _ = batch;
    }

    pub fn acked(self: *Conn, token: u32, batch: *stream.Batch) !void {
        _ = self;
        _ = token;
        _ = batch;
        unreachable;
    }

    pub fn flushed(self: *Conn) void {
        _ = self;
    }

    /// Ship the commit's damaged rects as canvas-ready RGBA. The swizzle must
    /// happen NOW, not at batch flush — the pool can be remapped (resize) or
    /// redrawn (it is released the moment this returns) before the send.
    ///
    /// Shadow trimming: each damaged rect is swizzled into the surface's
    /// shadow AND compared against it in one pass; the rect then ships
    /// trimmed to the bounding box of the pixels that actually changed
    /// (unchanged rects are dropped). On a fresh shadow the whole clamped
    /// rect ships (first ship / dim change is full anyway) but the shadow is
    /// still populated for next time.
    ///
    /// The client's file may be shorter than the pool it claimed, or be
    /// truncated under the buffer at any time (shm.zig, Pool): a read that
    /// runs past its end leaves everything this commit produced unsent and
    /// the commit unshown.
    pub fn commit(self: *Conn, c: buffers.Commit, batch: *stream.Batch) !buffers.Settle {
        const mark = batch.bytes.items.len;
        shm.beginAccess(c.buffer.pool);
        const settle = self.ship(c, batch);
        if (try shm.endAccess(c.buffer.pool)) return settle;
        std.log.warn("conn {d}: buffer {d} lies past the end of its pool's file; not shown", .{ self.conn_id, c.buffer_id });
        batch.bytes.shrinkRetainingCapacity(mark);
        // the shadow took in pixels the engine never got
        self.surfaceDestroyed(c.surface_id);
        return .unshown;
    }

    fn ship(self: *Conn, c: buffers.Commit, batch: *stream.Batch) !buffers.Settle {
        const gpa = self.gpa;
        const buffer = c.buffer;
        const pool = buffer.pool;
        const buf_w = buffer.width;
        const buf_h = buffer.height;

        const shadow_gop = try self.shadows.getOrPut(gpa, c.surface_id);
        if (!shadow_gop.found_existing) shadow_gop.value_ptr.* = &.{};
        const shadow = shadow_gop.value_ptr;
        // (Re)size the shadow to the current buffer dims. A size change gives
        // a fresh (zeroed) shadow and coincides with `resized` (one
        // full-buffer rect), so the whole buffer ships and populates it.
        const shadow_len = @as(usize, buf_w) * @as(usize, buf_h) * 4;
        var fresh_shadow = false;
        if (shadow.len != shadow_len) {
            if (shadow.len != 0) gpa.free(shadow.*);
            shadow.* = gpa.alloc(u8, shadow_len) catch &.{};
            if (shadow.len != 0) @memset(shadow.*, 0);
            fresh_shadow = true;
        }

        // baseline (pre-trim) cost, for the A/B measurement.
        for (c.damage) |rect|
            self.total_untrimmed_pixels += @as(u64, @intCast(rect.w)) * 4 * @as(u64, @intCast(rect.h));

        const alpha_or: u32 = if (buffer.format == 1) 0xff00_0000 else 0; // xrgb8888: force opaque

        // No shadow (alloc failed): ship the clamped rects raw, swizzling
        // straight into the batch (pre-trimming behaviour).
        if (shadow.len == 0) {
            try self.shipRawRects(c, alpha_or, batch);
            return .now;
        }

        // shm words are LE 0xAARRGGBB.
        const shadow32 = std.mem.bytesAsSlice(u32, shadow.*);
        var trimmed: [shm.DamageList.cap]shm.Rect = undefined;
        var n_trim: usize = 0;
        for (c.damage) |rect| {
            const rx: usize = @intCast(rect.x);
            const ry: usize = @intCast(rect.y);
            const rw: usize = @intCast(rect.w);
            const rh: usize = @intCast(rect.h);
            var min_col: usize = rw;
            var min_row: usize = rh;
            var max_col: usize = 0;
            var max_row: usize = 0;
            var changed = false;
            for (0..rh) |row| {
                const src_off = buffer.offset + (ry + row) * buffer.stride + rx * 4;
                const src = std.mem.bytesAsSlice(u32, pool.data[src_off..][0 .. rw * 4]);
                const shadow_row = (ry + row) * buf_w + rx;
                for (src, 0..) |s, col| {
                    const v = (s & 0xff00_ff00) | ((s >> 16) & 0xff) | ((s & 0xff) << 16) | alpha_or;
                    const idx = shadow_row + col;
                    if (shadow32[idx] != v) {
                        shadow32[idx] = v;
                        changed = true;
                        if (col < min_col) min_col = col;
                        if (col > max_col) max_col = col;
                        if (row < min_row) min_row = row;
                        if (row > max_row) max_row = row;
                    }
                }
            }
            if (fresh_shadow) {
                trimmed[n_trim] = rect; // full clamped rect; shadow now populated
                n_trim += 1;
            } else if (changed) {
                trimmed[n_trim] = .{
                    .x = rect.x + @as(i32, @intCast(min_col)),
                    .y = rect.y + @as(i32, @intCast(min_row)),
                    .w = @intCast(max_col - min_col + 1),
                    .h = @intCast(max_row - min_row + 1),
                };
                n_trim += 1;
            }
            // unchanged (and not fresh) → the engine already shows it; drop.
        }
        if (n_trim == 0) return .now;
        const rects = trimmed[0..n_trim];

        var pixel_bytes: usize = 0;
        for (rects) |rect|
            pixel_bytes += @as(usize, @intCast(rect.w)) * 4 * @as(usize, @intCast(rect.h));

        // Large payloads: try LZ4. Terminal/GTK content (flat colors, text)
        // compresses hard; incompressible pixels fall through to raw.
        if (pixel_bytes >= lz_threshold) {
            if (try self.shipCompressed(c, shadow.*, rects, pixel_bytes, batch)) return .now;
        }

        const head_len = stream.buffer_header_len + n_trim * 16;
        const out = try batch.frame(gpa, head_len + pixel_bytes);
        writeHeadAndRects(out, .buffer, c, rects);
        // the trimmed pixels are already swizzled in the shadow — copy them out.
        copyFromShadow(out[head_len..], shadow.*, buf_w, rects);
        self.total_raw_pixels += pixel_bytes;
        self.countShipped(head_len + pixel_bytes);
        return .now;
    }

    /// Try to ship the trimmed pixels as a BUFFER_LZ frame: assemble the
    /// (already swizzled) shadow pixels contiguously, LZ4 them, and write a
    /// 0x07 frame only if that shrinks the payload. False → ship raw.
    fn shipCompressed(self: *Conn, c: buffers.Commit, shadow: []const u8, rects: []const shm.Rect, pixel_bytes: usize, batch: *stream.Batch) !bool {
        const gpa = self.gpa;
        // contiguous (raw BUFFER pixel layout) so the codec can match across rows
        try self.lz_src.resize(gpa, pixel_bytes);
        copyFromShadow(self.lz_src.items, shadow, c.buffer.width, rects);

        try self.lz_dst.resize(gpa, core.lz4.compressBound(pixel_bytes));
        const comp_len = core.lz4.compress(self.lz_src.items[0..pixel_bytes], self.lz_dst.items) orelse return false;
        if (comp_len >= pixel_bytes) return false; // incompressible → ship raw

        const rects_end = stream.buffer_header_len + rects.len * 16;
        const head_len = rects_end + stream.buffer_lz_meta_len;
        const out = try batch.frame(gpa, head_len + comp_len);
        writeHeadAndRects(out, .buffer_lz, c, rects);
        std.mem.writeInt(u32, out[rects_end..][0..4], @intCast(pixel_bytes), .little);
        std.mem.writeInt(u32, out[rects_end + 4 ..][0..4], @intCast(comp_len), .little);
        @memcpy(out[head_len..][0..comp_len], self.lz_dst.items[0..comp_len]);

        self.total_raw_pixels += pixel_bytes;
        self.countShipped(head_len + comp_len);
        return true;
    }

    /// Fallback when the shadow couldn't be allocated: ship the clamped
    /// rects raw, swizzling straight from the pool into the batch.
    fn shipRawRects(self: *Conn, c: buffers.Commit, alpha_or: u32, batch: *stream.Batch) !void {
        const buffer = c.buffer;
        const pool = buffer.pool;
        var pixel_bytes: usize = 0;
        for (c.damage) |rect|
            pixel_bytes += @as(usize, @intCast(rect.w)) * 4 * @as(usize, @intCast(rect.h));
        const head_len = stream.buffer_header_len + c.damage.len * 16;
        const out = try batch.frame(self.gpa, head_len + pixel_bytes);
        writeHeadAndRects(out, .buffer, c, c.damage);
        var dst_off: usize = head_len;
        for (c.damage) |rect| {
            const row_bytes = @as(usize, @intCast(rect.w)) * 4;
            for (0..@intCast(rect.h)) |row| {
                const src_off = buffer.offset + (@as(usize, @intCast(rect.y)) + row) * buffer.stride + @as(usize, @intCast(rect.x)) * 4;
                const src = std.mem.bytesAsSlice(u32, pool.data[src_off..][0..row_bytes]);
                const dst = std.mem.bytesAsSlice(u32, out[dst_off..][0..row_bytes]);
                for (src, dst) |s, *d|
                    d.* = (s & 0xff00_ff00) | ((s >> 16) & 0xff) | ((s & 0xff) << 16) | alpha_or;
                dst_off += row_bytes;
            }
        }
        self.total_raw_pixels += pixel_bytes;
        self.countShipped(head_len + pixel_bytes);
    }

    /// Rolling bytes-shipped log, at most one line per second per conn (M7.1
    /// verify instrument; idle apps ship ~nothing so silence means ~0 B/s).
    fn countShipped(self: *Conn, frame_bytes: usize) void {
        const now_ns = Io.Clock.now(.awake, self.io).nanoseconds;
        if (self.ship_window_ns == 0) self.ship_window_ns = now_ns;
        self.ship_bytes += frame_bytes;
        self.ship_frames += 1;
        self.total_ship_bytes += frame_bytes;
        self.total_ship_frames += 1;
        const elapsed_ns = now_ns - self.ship_window_ns;
        if (elapsed_ns >= std.time.ns_per_s) {
            const rate = self.ship_bytes * std.time.ns_per_s / @as(u64, @intCast(elapsed_ns));
            std.log.info("conn {d}: shipped {d} B/s ({d} frames)", .{ self.conn_id, rate, self.ship_frames });
            self.ship_bytes = 0;
            self.ship_frames = 0;
            self.ship_window_ns = now_ns;
        }
    }
};

/// BUFFER / BUFFER_LZ share the header + rects layout (only the type differs).
fn writeHeadAndRects(out: []u8, frame_type: stream.FrameType, c: buffers.Commit, rects: []const shm.Rect) void {
    std.debug.assert(frame_type == .buffer or frame_type == .buffer_lz);
    stream.writeBufferHeader(out[0..stream.buffer_header_len], .{
        .conn_id = c.conn_id,
        .surface_id = c.surface_id,
        .width = c.buffer.width,
        .height = c.buffer.height,
        .n_rects = @intCast(rects.len),
    });
    out[0] = @intFromEnum(frame_type);
    for (rects, 0..) |rect, i|
        stream.writeRect(out[stream.buffer_header_len + i * 16 ..][0..16], rect.x, rect.y, rect.w, rect.h);
}

/// Concatenate the rects' rows (tightly packed, rect order) out of a
/// buf_w-wide RGBA shadow.
fn copyFromShadow(dst: []u8, shadow: []const u8, buf_w: u32, rects: []const shm.Rect) void {
    var off: usize = 0;
    for (rects) |rect| {
        const rx: usize = @intCast(rect.x);
        const row_bytes = @as(usize, @intCast(rect.w)) * 4;
        for (0..@intCast(rect.h)) |row| {
            const shadow_off = ((@as(usize, @intCast(rect.y)) + row) * buf_w + rx) * 4;
            @memcpy(dst[off..][0..row_bytes], shadow[shadow_off..][0..row_bytes]);
            off += row_bytes;
        }
    }
}
