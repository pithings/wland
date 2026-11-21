// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Object-id → interface tracking for one wayland connection.
//! Client-allocated ids count up from 1; server/browser-side ids count up
//! from 0xff000000.

const std = @import("std");
const wire = @import("wire.zig");
const protocol = @import("protocol_gen.zig");

/// First id of the server-allocated range (ids ≥ this are compositor-created).
///
/// TWO interfaces get server ids — wl_data_offer (clipboard + dnd) and
/// zwp_primary_selection_offer_v1 (primary selection) — and both carry an
/// fd-bearing `receive` the server must intercept, at DIFFERENT opcodes
/// (data_offer.receive = 1, primary_offer.receive = 0). The id value CANNOT
/// encode the type: libwayland's client-side object map treats a server id as
/// a DENSE index (id − server_id_base into a growable array), so server ids
/// must be allocated CONTIGUOUSLY from server_id_base regardless of type — a
/// sparse/partitioned scheme makes libwayland reject the id ("not a valid new
/// object id"). Both types therefore draw from one contiguous per-conn
/// counter, and the type is conveyed OUT OF BAND: the browser emits a SRVOBJ
/// STREAM frame (0x06) for every primary offer so the server's fd interception
/// knows which receive opcode carries the fd (see relay.zig / STREAM.md).
pub const server_id_base: u32 = 0xff000000;

pub const Entry = struct {
    iface: *const protocol.Interface,
    version: u32,
};

pub const ObjectMap = struct {
    map: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

    pub fn deinit(self: *ObjectMap, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
    }

    pub fn get(self: *const ObjectMap, id: u32) ?Entry {
        return self.map.get(id);
    }

    pub fn put(self: *ObjectMap, gpa: std.mem.Allocator, id: u32, iface: *const protocol.Interface, version: u32) !void {
        try self.map.put(gpa, id, .{ .iface = iface, .version = version });
    }

    pub fn remove(self: *ObjectMap, id: u32) void {
        _ = self.map.remove(id);
    }

    /// Record objects created by a decoded message (typed and dynamic new_id
    /// args). Typed new_ids inherit `parent_version` per wayland semantics.
    /// Unknown interface names are ignored — messages addressed to them will
    /// decode as opaque.
    pub fn trackNewIds(
        self: *ObjectMap,
        gpa: std.mem.Allocator,
        msg: *const protocol.Message,
        args: []const wire.Value,
        parent_version: u32,
    ) !void {
        for (args) |arg| switch (arg) {
            .new_id => |id| {
                const name = msg.new_id_interface orelse continue;
                const iface = protocol.find(name) orelse continue;
                try self.put(gpa, id, iface, parent_version);
            },
            .new_id_dynamic => |v| {
                const iface = protocol.find(v.interface) orelse continue;
                try self.put(gpa, v.id, iface, v.version);
            },
            else => {},
        };
    }
};

test "track typed new_id from wl_display.get_registry" {
    const gpa = std.testing.allocator;
    var objects: ObjectMap = .{};
    defer objects.deinit(gpa);

    const wl_display = protocol.find("wl_display").?;
    try objects.put(gpa, 1, wl_display, 1);

    // decode get_registry(new_id=2)
    var buf: [16]u8 = undefined;
    const msg_bytes = wire.encodeMessage(&buf, 1, 1, &.{.{ .new_id = 2 }});
    const sig = &wl_display.requests[1];
    var vals: [wire.max_args]wire.Value = undefined;
    const args = try wire.decodeArgs(msg_bytes[wire.header_size..], sig.args, &vals);
    try objects.trackNewIds(gpa, sig, args, 1);

    try std.testing.expectEqualStrings("wl_registry", objects.get(2).?.iface.name);
    try std.testing.expectEqual(@as(u32, 1), objects.get(2).?.version);
}

test "track dynamic new_id from wl_registry.bind" {
    const gpa = std.testing.allocator;
    var objects: ObjectMap = .{};
    defer objects.deinit(gpa);

    const wl_registry = protocol.find("wl_registry").?;
    var buf: [64]u8 = undefined;
    const msg_bytes = wire.encodeMessage(&buf, 2, 0, &.{
        .{ .uint = 1 },
        .{ .new_id_dynamic = .{ .interface = "wl_seat", .version = 2, .id = 3 } },
    });
    const sig = &wl_registry.requests[0];
    var vals: [wire.max_args]wire.Value = undefined;
    const args = try wire.decodeArgs(msg_bytes[wire.header_size..], sig.args, &vals);
    try objects.trackNewIds(gpa, sig, args, 1);

    try std.testing.expectEqualStrings("wl_seat", objects.get(3).?.iface.name);
    try std.testing.expectEqual(@as(u32, 2), objects.get(3).?.version);
    try std.testing.expectEqual(@as(?Entry, null), objects.get(99));
}
