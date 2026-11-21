// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Pixel conversion for the engine's 2D presenter (wasm export
//! wland_swizzle). wl_shm ARGB8888/XRGB8888 are little-endian 0xAARRGGBB
//! words, i.e. bytes B, G, R, A|X; a 2D canvas wants R, G, B, A.
//!
//! Alpha matches the copy backend's commit-time swizzle
//! (server/src/copy_backend.zig): XRGB alpha is forced to 0xff; ARGB alpha
//! passes through unchanged. wl_shm ARGB is premultiplied and a 2D canvas
//! takes straight alpha, so translucent pixels are slightly off — the same
//! approximation the copy path has always made.

const std = @import("std");

/// Convert a `width`×`height` rect of BGRA/BGRX pixels whose rows start
/// `src_stride` bytes apart into tightly packed RGBA rows (width × 4 bytes
/// each) at `dst`. `force_opaque` (XRGB8888) sets every alpha to 0xff.
/// `dst` may equal `src` (in-place compaction: each row's destination never
/// lies past its source); otherwise the two must not overlap.
pub fn bgraToRgba(src: [*]const u8, src_stride: usize, dst: [*]u8, width: usize, height: usize, force_opaque: bool) void {
    const alpha_or: u32 = if (force_opaque) 0xff00_0000 else 0;
    const row_bytes = width * 4;
    for (0..height) |row| {
        const s = src + row * src_stride;
        const d = dst + row * row_bytes;
        var i: usize = 0;
        while (i < row_bytes) : (i += 4) {
            const v = std.mem.readInt(u32, s[i..][0..4], .little);
            const out = (v & 0xff00_ff00) | ((v >> 16) & 0xff) | ((v & 0xff) << 16) | alpha_or;
            std.mem.writeInt(u32, d[i..][0..4], out, .little);
        }
    }
}

test "bgra → rgba: strided rows, opaque forcing, in place" {
    // 2×2, stride 12 (4 bytes of row padding): B G R A per pixel
    const src = [_]u8{
        1, 2, 3, 4, 5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee,
        9, 10, 11, 12, 13, 14, 15, 0, 0xee, 0xee, 0xee, 0xee,
    };
    var dst: [16]u8 = undefined;
    bgraToRgba(&src, 12, &dst, 2, 2, false);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4, 7, 6, 5, 8, 11, 10, 9, 12, 15, 14, 13, 0 }, &dst);
    bgraToRgba(&src, 12, &dst, 2, 2, true);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 0xff, 7, 6, 5, 0xff, 11, 10, 9, 0xff, 15, 14, 13, 0xff }, &dst);

    // in place: the strided source compacts into tight rows
    var buf = src;
    bgraToRgba(&buf, 12, &buf, 2, 2, true);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 0xff, 7, 6, 5, 0xff, 11, 10, 9, 0xff, 15, 14, 13, 0xff }, buf[0..16]);
}
