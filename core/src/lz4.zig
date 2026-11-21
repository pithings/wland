// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Minimal LZ4 block codec — hand-rolled, no allocations, compiles native AND
//! wasm32-freestanding (like the rest of core/). Used to compress the pixel
//! section of large BUFFER frames (server encodes, browser wasm decodes).
//!
//! This is the LZ4 *block* format (not the framed .lz4 file format): a stream
//! of sequences, each = a token byte, optional literal-length extension bytes,
//! the literals, a 2-byte little-endian match offset, and optional match-length
//! extension bytes. The token packs literal length (high nibble) and match
//! length-minus-4 (low nibble); a nibble of 15 means "read extension bytes,
//! 255 = continue". The final sequence is literals only (no offset/match).
//! See https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md.
//!
//! The encoder is greedy single-probe (fast, ~LZ4 default ratio, not HC). The
//! decoder is tiny and fully bounds-checked so malformed input can never write
//! out of range — it runs on browser-supplied bytes... actually server-supplied,
//! but it stays defensive regardless.

const std = @import("std");

const MIN_MATCH = 4;
const HASH_LOG = 13;
const HASH_SIZE = 1 << HASH_LOG;
const MAX_OFFSET = 65535;
const LAST_LITERALS = 5;
/// No match is searched within the final MFLIMIT bytes (keeps the last
/// LAST_LITERALS bytes as literals and leaves room for a 4-byte read).
const MFLIMIT = 12;

inline fn read32(src: []const u8, p: usize) u32 {
    return std.mem.readInt(u32, src[p..][0..4], .little);
}

inline fn hash32(v: u32) u32 {
    return (v *% 2654435761) >> (32 - HASH_LOG);
}

/// Upper bound on the compressed size of `n` input bytes (worst case is all
/// literals: one token per 255 bytes plus the length bytes).
pub fn compressBound(n: usize) usize {
    return n + n / 255 + 16;
}

/// Compress `src` into `dst`. Returns the compressed length, or null if it does
/// not fit in `dst` (size `dst` with compressBound to guarantee success). The
/// output can be larger than the input on incompressible data — the caller
/// decides whether the result is worth shipping.
pub fn compress(src: []const u8, dst: []u8) ?usize {
    var op: usize = 0;
    if (src.len < MFLIMIT + 1) return emitLastLiterals(src, 0, dst, &op);

    var table = [_]u32{0} ** HASH_SIZE;
    const mflimit = src.len - MFLIMIT; // search matches only at positions < mflimit
    const matchlimit = src.len - LAST_LITERALS; // matches may extend up to here
    var anchor: usize = 0; // start of the current literal run
    var ip: usize = 0;

    table[hash32(read32(src, 0))] = 0;
    ip = 1;
    while (ip < mflimit) {
        const h = hash32(read32(src, ip));
        const ref = table[h]; // an earlier position (or 0 sentinel)
        table[h] = @intCast(ip);
        if (ip - ref > MAX_OFFSET or read32(src, ref) != read32(src, ip)) {
            ip += 1;
            continue;
        }

        // match at ip against ref — extend it backwards over the literal run.
        var mref = ref;
        while (ip > anchor and mref > 0 and src[mref - 1] == src[ip - 1]) {
            ip -= 1;
            mref -= 1;
        }

        const lit_len = ip - anchor;
        const token_pos = op;
        if (op >= dst.len) return null;
        op += 1;
        if (lit_len >= 15) {
            dst[token_pos] = 0xf0;
            var l = lit_len - 15;
            while (l >= 255) : (l -= 255) {
                if (op >= dst.len) return null;
                dst[op] = 255;
                op += 1;
            }
            if (op >= dst.len) return null;
            dst[op] = @intCast(l);
            op += 1;
        } else {
            dst[token_pos] = @intCast(lit_len << 4);
        }
        if (op + lit_len > dst.len) return null;
        @memcpy(dst[op..][0..lit_len], src[anchor..ip]);
        op += lit_len;

        // 2-byte little-endian offset
        const offset = ip - mref;
        if (op + 2 > dst.len) return null;
        dst[op] = @intCast(offset & 0xff);
        dst[op + 1] = @intCast((offset >> 8) & 0xff);
        op += 2;

        // count the full match length (>= MIN_MATCH)
        var mp = ip + MIN_MATCH;
        var rp = mref + MIN_MATCH;
        while (mp < matchlimit and src[mp] == src[rp]) {
            mp += 1;
            rp += 1;
        }
        const match_len = mp - ip;
        const ml = match_len - MIN_MATCH;
        if (ml >= 15) {
            dst[token_pos] |= 0x0f;
            var m = ml - 15;
            while (m >= 255) : (m -= 255) {
                if (op >= dst.len) return null;
                dst[op] = 255;
                op += 1;
            }
            if (op >= dst.len) return null;
            dst[op] = @intCast(m);
            op += 1;
        } else {
            dst[token_pos] |= @intCast(ml);
        }

        ip += match_len;
        anchor = ip;
        if (ip >= mflimit) break;
        // re-index one position inside the match tail to catch overlapping runs
        table[hash32(read32(src, ip - 2))] = @intCast(ip - 2);
    }

    return emitLastLiterals(src, anchor, dst, &op);
}

fn emitLastLiterals(src: []const u8, anchor: usize, dst: []u8, op: *usize) ?usize {
    const lit = src.len - anchor;
    const token_pos = op.*;
    if (op.* >= dst.len) return null;
    op.* += 1;
    if (lit >= 15) {
        dst[token_pos] = 0xf0;
        var l = lit - 15;
        while (l >= 255) : (l -= 255) {
            if (op.* >= dst.len) return null;
            dst[op.*] = 255;
            op.* += 1;
        }
        if (op.* >= dst.len) return null;
        dst[op.*] = @intCast(l);
        op.* += 1;
    } else {
        dst[token_pos] = @intCast(lit << 4);
    }
    if (op.* + lit > dst.len) return null;
    @memcpy(dst[op.*..][0..lit], src[anchor..]);
    op.* += lit;
    return op.*;
}

/// Decompress `src` into `dst`. Returns the decompressed length, or null on
/// malformed input or if the output would exceed `dst` (fully bounds-checked —
/// a bad stream can never corrupt memory). `dst` must be sized to the known
/// uncompressed length.
pub fn decompress(src: []const u8, dst: []u8) ?usize {
    var ip: usize = 0;
    var op: usize = 0;
    while (ip < src.len) {
        const token = src[ip];
        ip += 1;

        var lit: usize = token >> 4;
        if (lit == 15) {
            while (true) {
                if (ip >= src.len) return null;
                const b = src[ip];
                ip += 1;
                lit += b;
                if (b != 255) break;
            }
        }
        if (ip + lit > src.len or op + lit > dst.len) return null;
        @memcpy(dst[op..][0..lit], src[ip..][0..lit]);
        ip += lit;
        op += lit;

        if (ip == src.len) break; // final sequence: literals only
        if (ip + 2 > src.len) return null;
        const offset = @as(usize, src[ip]) | (@as(usize, src[ip + 1]) << 8);
        ip += 2;
        if (offset == 0 or offset > op) return null;

        var mlen: usize = token & 0x0f;
        if (mlen == 15) {
            while (true) {
                if (ip >= src.len) return null;
                const b = src[ip];
                ip += 1;
                mlen += b;
                if (b != 255) break;
            }
        }
        mlen += MIN_MATCH;
        if (op + mlen > dst.len) return null;
        // byte-by-byte so overlapping matches (offset < mlen) replicate correctly
        var m: usize = 0;
        while (m < mlen) : (m += 1) {
            dst[op] = dst[op - offset];
            op += 1;
        }
    }
    return op;
}

fn roundtrip(gpa: std.mem.Allocator, data: []const u8) !void {
    const dst = try gpa.alloc(u8, compressBound(data.len));
    defer gpa.free(dst);
    const clen = compress(data, dst) orelse return error.CompressFailed;
    const out = try gpa.alloc(u8, data.len);
    defer gpa.free(out);
    const dlen = decompress(dst[0..clen], out) orelse return error.DecompressFailed;
    try std.testing.expectEqual(data.len, dlen);
    try std.testing.expectEqualSlices(u8, data, out[0..dlen]);
}

test "roundtrip: empty and tiny" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "");
    try roundtrip(gpa, "a");
    try roundtrip(gpa, "hello");
    try roundtrip(gpa, "0123456789abc"); // 13 bytes, just past MFLIMIT boundary
}

test "roundtrip: flat color compresses hard" {
    const gpa = std.testing.allocator;
    var flat: [64 * 1024]u8 = undefined;
    // simulate a solid-fill RGBA window: same 4 bytes repeated
    var i: usize = 0;
    while (i < flat.len) : (i += 4) {
        flat[i] = 0x20;
        flat[i + 1] = 0x30;
        flat[i + 2] = 0x40;
        flat[i + 3] = 0xff;
    }
    try roundtrip(gpa, &flat);
    // must actually shrink a lot
    const dst = try gpa.alloc(u8, compressBound(flat.len));
    defer gpa.free(dst);
    const clen = compress(&flat, dst).?;
    try std.testing.expect(clen < flat.len / 20); // >20x
}

test "roundtrip: text-like repetitive data" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const line = "the quick brown fox jumps over the lazy dog. ";
    for (0..2000) |_| try buf.appendSlice(gpa, line);
    try roundtrip(gpa, buf.items);
    const dst = try gpa.alloc(u8, compressBound(buf.items.len));
    defer gpa.free(dst);
    const clen = compress(buf.items, dst).?;
    try std.testing.expect(clen < buf.items.len / 5); // >5x
}

test "roundtrip: incompressible random data" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    var rnd: [40000]u8 = undefined;
    prng.random().bytes(&rnd);
    try roundtrip(gpa, &rnd);
    // incompressible: output is input + small overhead, never smaller
    const dst = try gpa.alloc(u8, compressBound(rnd.len));
    defer gpa.free(dst);
    const clen = compress(&rnd, dst).?;
    try std.testing.expect(clen >= rnd.len);
}

test "roundtrip: mixed runs and literals" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..500) |_| {
        // a random literal blob followed by a long repeated run
        var blob: [37]u8 = undefined;
        prng.random().bytes(&blob);
        try buf.appendSlice(gpa, &blob);
        try buf.appendNTimes(gpa, 0xAB, 200);
    }
    try roundtrip(gpa, buf.items);
}

test "decompress rejects malformed input" {
    var out: [64]u8 = undefined;
    // offset past the output so far
    try std.testing.expectEqual(@as(?usize, null), decompress(&.{ 0x40, 0x05, 0x00 }, &out));
    // literal length runs off the end
    try std.testing.expectEqual(@as(?usize, null), decompress(&.{ 0xf0, 0xff }, &out));
}
