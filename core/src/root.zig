// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! wland core: wayland wire protocol codec and object model.
//! Compiles natively (unit tests, server) and to wasm32-freestanding (browser).

const std = @import("std");

pub const wire = @import("wire.zig");
pub const protocol = @import("protocol_gen.zig");
pub const objects = @import("objects.zig");
pub const stream = @import("stream.zig");
pub const lz4 = @import("lz4.zig");
pub const pixels = @import("pixels.zig");
pub const compositor = @import("compositor.zig");

pub const version: u32 = 1;

test {
    std.testing.refAllDecls(@This());
}
