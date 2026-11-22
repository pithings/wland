// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Wayland wire format: 8-byte message header, 32-bit aligned args.
//! Header: object_id (u32 LE), then u32 LE packing size (upper 16) | opcode (lower 16).
//! Size includes the header itself; minimum is 8, always a multiple of 4.

const std = @import("std");

pub const header_size = 8;

pub const Header = struct {
    object_id: u32,
    opcode: u16,
    /// Total message size in bytes, including this header.
    size: u16,

    pub const ParseError = error{ TooShort, InvalidSize };

    /// Parse a header from the first 8 bytes of `bytes`.
    pub fn parse(bytes: []const u8) ParseError!Header {
        if (bytes.len < header_size) return error.TooShort;
        const object_id = std.mem.readInt(u32, bytes[0..4], .little);
        const size_opcode = std.mem.readInt(u32, bytes[4..8], .little);
        const size: u16 = @intCast(size_opcode >> 16);
        const opcode: u16 = @intCast(size_opcode & 0xffff);
        if (size < header_size or size % 4 != 0) return error.InvalidSize;
        return .{ .object_id = object_id, .opcode = opcode, .size = size };
    }

    pub fn write(h: Header, out: *[header_size]u8) void {
        std.mem.writeInt(u32, out[0..4], h.object_id, .little);
        const size_opcode = (@as(u32, h.size) << 16) | h.opcode;
        std.mem.writeInt(u32, out[4..8], size_opcode, .little);
    }
};

/// Wire argument types. `fd` never appears in the byte stream (SCM_RIGHTS).
/// `new_id_dynamic` is wl_registry.bind's untyped new_id: on the wire it is
/// string (interface) + uint (version) + uint (id).
pub const ArgType = enum { int, uint, fixed, string, object, new_id, new_id_dynamic, array, fd };

pub const Value = union(ArgType) {
    int: i32,
    uint: u32,
    fixed: i32, // 24.8 fixed point
    string: ?[]const u8, // null = null string; excludes terminating NUL
    object: u32, // 0 = null object
    new_id: u32,
    new_id_dynamic: struct { interface: []const u8, version: u32, id: u32 },
    array: []const u8,
    fd: void,
};

pub const max_args = 16;

pub const DecodeError = error{ Truncated, BadString, TooManyArgs };

/// Decode the argument block (message bytes after the 8-byte header)
/// according to `sig`. Returned slices point into `body`.
pub fn decodeArgs(body: []const u8, sig: []const ArgType, out: *[max_args]Value) DecodeError![]Value {
    if (sig.len > max_args) return error.TooManyArgs;
    var off: usize = 0;
    var n: usize = 0;
    for (sig) |arg_type| {
        switch (arg_type) {
            .int => out[n] = .{ .int = @bitCast(try takeWord(body, &off)) },
            .uint => out[n] = .{ .uint = try takeWord(body, &off) },
            .fixed => out[n] = .{ .fixed = @bitCast(try takeWord(body, &off)) },
            .object => out[n] = .{ .object = try takeWord(body, &off) },
            .new_id => out[n] = .{ .new_id = try takeWord(body, &off) },
            .string => out[n] = .{ .string = try takeString(body, &off) },
            .array => out[n] = .{ .array = try takeArray(body, &off) },
            .new_id_dynamic => {
                const interface = (try takeString(body, &off)) orelse return error.BadString;
                const version = try takeWord(body, &off);
                const id = try takeWord(body, &off);
                out[n] = .{ .new_id_dynamic = .{ .interface = interface, .version = version, .id = id } };
            },
            .fd => out[n] = .fd,
        }
        n += 1;
    }
    return out[0..n];
}

fn takeWord(body: []const u8, off: *usize) DecodeError!u32 {
    if (body.len < off.* + 4) return error.Truncated;
    const v = std.mem.readInt(u32, body[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

fn takeString(body: []const u8, off: *usize) DecodeError!?[]const u8 {
    const len = try takeWord(body, off); // includes terminating NUL
    if (len == 0) return null; // null string
    const padded = std.mem.alignForward(usize, len, 4);
    if (body.len < off.* + padded) return error.Truncated;
    const s = body[off.*..][0 .. len - 1];
    if (body[off.* + len - 1] != 0) return error.BadString;
    off.* += padded;
    return s;
}

fn takeArray(body: []const u8, off: *usize) DecodeError![]const u8 {
    const len = try takeWord(body, off);
    const padded = std.mem.alignForward(usize, len, 4);
    if (body.len < off.* + padded) return error.Truncated;
    const a = body[off.*..][0..len];
    off.* += padded;
    return a;
}

/// Largest message the header's 16-bit size can name (a multiple of 4).
pub const max_message_size = 0xfffc;

pub const EncodeError = error{MessageTooLarge};

/// The encoded size of a message with `args` (header included), in u64 so
/// no client-sized string or array can wrap it.
pub fn messageSize(args: []const Value) u64 {
    var size: u64 = header_size;
    for (args) |arg| {
        size += switch (arg) {
            .int, .uint, .fixed, .object, .new_id => 4,
            .string => |opt| if (opt) |s| 4 + std.mem.alignForward(u64, @as(u64, s.len) + 1, 4) else 4,
            .array => |a| 4 + std.mem.alignForward(u64, a.len, 4),
            .new_id_dynamic => |v| 4 + std.mem.alignForward(u64, @as(u64, v.interface.len) + 1, 4) + 8,
            .fd => 0,
        };
    }
    return size;
}

/// Serialize a message (header + args) into `buf`; returns the written
/// slice. A message larger than `buf` (or than a header can name) is
/// refused before anything is written: strings and arrays may be sized by a
/// client, and ReleaseFast (the wasm build) does not bounds-check slices.
pub fn encode(buf: []u8, object_id: u32, opcode: u16, args: []const Value) EncodeError![]u8 {
    const size = messageSize(args);
    if (size > buf.len or size > max_message_size) return error.MessageTooLarge;
    return encodeUnchecked(buf, object_id, opcode, args);
}

/// `encode` for messages whose size the caller fixed (constant args, tests):
/// one that does not fit panics (a trap in wasm) — never a write past `buf`.
pub fn encodeMessage(buf: []u8, object_id: u32, opcode: u16, args: []const Value) []u8 {
    return encode(buf, object_id, opcode, args) catch @panic("wire.encodeMessage: message larger than its buffer");
}

fn encodeUnchecked(buf: []u8, object_id: u32, opcode: u16, args: []const Value) []u8 {
    var off: usize = header_size;
    for (args) |arg| {
        switch (arg) {
            .int => |v| putWord(buf, &off, @bitCast(v)),
            .uint => |v| putWord(buf, &off, v),
            .fixed => |v| putWord(buf, &off, @bitCast(v)),
            .object => |v| putWord(buf, &off, v),
            .new_id => |v| putWord(buf, &off, v),
            .string => |opt| putString(buf, &off, opt),
            .array => |a| {
                putWord(buf, &off, @intCast(a.len));
                putPadded(buf, &off, a);
            },
            .new_id_dynamic => |v| {
                putString(buf, &off, v.interface);
                putWord(buf, &off, v.version);
                putWord(buf, &off, v.id);
            },
            .fd => {},
        }
    }
    Header.write(.{ .object_id = object_id, .opcode = opcode, .size = @intCast(off) }, buf[0..header_size]);
    return buf[0..off];
}

fn putWord(buf: []u8, off: *usize, v: u32) void {
    std.mem.writeInt(u32, buf[off.*..][0..4], v, .little);
    off.* += 4;
}

fn putString(buf: []u8, off: *usize, opt: ?[]const u8) void {
    const s = opt orelse {
        putWord(buf, off, 0);
        return;
    };
    putWord(buf, off, @intCast(s.len + 1)); // include NUL
    const padded = std.mem.alignForward(usize, s.len + 1, 4);
    @memcpy(buf[off.*..][0..s.len], s);
    @memset(buf[off.* + s.len ..][0 .. padded - s.len], 0);
    off.* += padded;
}

fn putPadded(buf: []u8, off: *usize, bytes: []const u8) void {
    const padded = std.mem.alignForward(usize, bytes.len, 4);
    @memcpy(buf[off.*..][0..bytes.len], bytes);
    @memset(buf[off.* + bytes.len ..][0 .. padded - bytes.len], 0);
    off.* += padded;
}

test "header roundtrip" {
    const h: Header = .{ .object_id = 3, .opcode = 0, .size = 12 };
    var buf: [header_size]u8 = undefined;
    h.write(&buf);
    const parsed = try Header.parse(&buf);
    try std.testing.expectEqual(h, parsed);
}

test "header parse rejects garbage" {
    var buf: [header_size]u8 = undefined;
    Header.write(.{ .object_id = 1, .opcode = 1, .size = 7 }, &buf);
    try std.testing.expectError(error.InvalidSize, Header.parse(&buf));
    try std.testing.expectError(error.TooShort, Header.parse(buf[0..4]));
}

test "header parse of a real wl_display.get_registry message" {
    // wl_display (id 1), opcode 1 (get_registry), arg new_id=2 → size 12
    const bytes = [_]u8{ 1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0 };
    const h = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(u32, 1), h.object_id);
    try std.testing.expectEqual(@as(u16, 1), h.opcode);
    try std.testing.expectEqual(@as(u16, 12), h.size);
}

test "decode string, uint, array args" {
    // string "hi\0" padded to 4, then uint 7, then array {1,2,3,4,5} padded to 8
    var buf: [64]u8 = undefined;
    const msg = encodeMessage(&buf, 5, 2, &.{
        .{ .string = "hi" },
        .{ .uint = 7 },
        .{ .array = &.{ 1, 2, 3, 4, 5 } },
    });
    const h = try Header.parse(msg);
    try std.testing.expectEqual(@as(u16, 8 + 8 + 4 + 12), h.size);
    var vals: [max_args]Value = undefined;
    const args = try decodeArgs(msg[header_size..], &.{ .string, .uint, .array }, &vals);
    try std.testing.expectEqualStrings("hi", args[0].string.?);
    try std.testing.expectEqual(@as(u32, 7), args[1].uint);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, args[2].array);
}

test "decode null string" {
    var buf: [16]u8 = undefined;
    const msg = encodeMessage(&buf, 1, 0, &.{.{ .string = null }});
    var vals: [max_args]Value = undefined;
    const args = try decodeArgs(msg[header_size..], &.{.string}, &vals);
    try std.testing.expectEqual(@as(?[]const u8, null), args[0].string);
}

test "decode wl_registry.bind dynamic new_id" {
    var buf: [64]u8 = undefined;
    const msg = encodeMessage(&buf, 2, 0, &.{
        .{ .uint = 3 }, // global name
        .{ .new_id_dynamic = .{ .interface = "wl_compositor", .version = 4, .id = 10 } },
    });
    var vals: [max_args]Value = undefined;
    const args = try decodeArgs(msg[header_size..], &.{ .uint, .new_id_dynamic }, &vals);
    try std.testing.expectEqual(@as(u32, 3), args[0].uint);
    try std.testing.expectEqualStrings("wl_compositor", args[1].new_id_dynamic.interface);
    try std.testing.expectEqual(@as(u32, 4), args[1].new_id_dynamic.version);
    try std.testing.expectEqual(@as(u32, 10), args[1].new_id_dynamic.id);
}

test "decode rejects truncated body" {
    var vals: [max_args]Value = undefined;
    try std.testing.expectError(error.Truncated, decodeArgs(&.{ 1, 0 }, &.{.uint}, &vals));
    // string claiming 100 bytes but body ends
    const bad = [_]u8{ 100, 0, 0, 0, 'a', 'b', 0, 0 };
    try std.testing.expectError(error.Truncated, decodeArgs(&bad, &.{.string}, &vals));
}

test "encode refuses a message larger than its buffer, writing nothing past it" {
    var buf: [64 + 16]u8 = @splat(0xaa);
    const out = buf[0..64];
    const long = [_]u8{'m'} ** 100;
    try std.testing.expectError(error.MessageTooLarge, encode(out, 1, 0, &.{.{ .string = &long }}));
    try std.testing.expectError(error.MessageTooLarge, encode(out, 1, 0, &.{.{ .array = &long }}));
    try std.testing.expectError(error.MessageTooLarge, encode(out, 1, 0, &.{.{ .new_id_dynamic = .{ .interface = &long, .version = 1, .id = 2 } }}));
    // exactly full fits: 8 header + 4 len + 52 (51 chars + NUL) = 64
    const fits = [_]u8{'m'} ** 51;
    try std.testing.expectEqual(@as(usize, 64), (try encode(out, 1, 0, &.{.{ .string = &fits }})).len);
    const one_more = [_]u8{'m'} ** 52;
    try std.testing.expectError(error.MessageTooLarge, encode(out, 1, 0, &.{.{ .string = &one_more }}));
    for (buf[64..]) |b| try std.testing.expectEqual(@as(u8, 0xaa), b);
    // past what a header's u16 size can say, whatever the buffer
    var big: [max_message_size + 8]u8 = undefined;
    const huge = [_]u8{'m'} ** max_message_size;
    try std.testing.expectError(error.MessageTooLarge, encode(&big, 1, 0, &.{.{ .array = &huge }}));
    try std.testing.expectEqual(@as(u64, 8 + (4 + 52) + 4 + (4 + 8)), messageSize(&.{ .{ .string = &fits }, .{ .uint = 1 }, .{ .array = &.{ 1, 2, 3, 4, 5 } }, .fd }));
}

test "fixed point is 24.8 two's complement" {
    var buf: [16]u8 = undefined;
    // -1.5 in 24.8 = -384
    const msg = encodeMessage(&buf, 1, 0, &.{.{ .fixed = -384 }});
    var vals: [max_args]Value = undefined;
    const args = try decodeArgs(msg[header_size..], &.{.fixed}, &vals);
    try std.testing.expectEqual(@as(i32, -384), args[0].fixed);
}
