// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! The relay ⇄ engine link: carries STREAM messages (one or more whole
//! frames, protocol/STREAM.md) in both directions. The relay is link-agnostic;
//! implementations: ws_link.zig (browser WebSocket, served by server.zig) and
//! stream_link.zig (any connected byte-stream fd).
//!
//! Lifetime: the owner creates a link, then blocks in `relay.serveLink`,
//! which returns only once no relay thread can touch the link again — the
//! owner may then free it (the WS link lives on its HTTP thread's stack).

const std = @import("std");

pub const Link = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    /// Who fires wl_callback.done for wl_surface.frame requests.
    frame_callbacks: FrameCallbacks,
    /// Relay bookkeeping (guarded by the relay mutex): threads that may still
    /// call into this link — app conns bound to it, plus a taking-over
    /// link's kick. serveLink waits for 0 before returning.
    users: u32 = 0,

    pub const FrameCallbacks = enum {
        /// The relay intercepts wl_surface.frame and fires done itself once
        /// the commit's batch has gone out on the link (paced by the send
        /// draining plus a ~60 Hz floor). The engine never sees the request.
        /// Right for a remote engine: no round trip in the app's render loop.
        relay,
        /// wl_surface.frame is forwarded like any request; the engine fires
        /// done when it has presented (core compositor.tick). Right when the
        /// engine is local and its presentation clock should pace the app.
        engine,
    };

    pub const SendError = error{LinkGone};
    pub const RecvError = error{ EndOfStream, LinkGone, OutOfMemory };

    pub const VTable = struct {
        /// Send one message. Called from any relay thread, concurrently with
        /// itself, recv and kick; must keep messages whole and in order.
        send: *const fn (ctx: *anyopaque, msg: []const u8) SendError!void,
        /// Block for the next whole message from the engine and leave it in
        /// `out` (replacing its contents). Only the serveLink thread calls it.
        /// EndOfStream on orderly close.
        recv: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) RecvError!void,
        /// Take the link down from another thread (takeover, shutdown): a
        /// blocked recv must return promptly, later sends fail.
        kick: *const fn (ctx: *anyopaque) void,
    };

    pub fn send(self: *Link, msg: []const u8) SendError!void {
        return self.vtable.send(self.ctx, msg);
    }

    pub fn recv(self: *Link, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) RecvError!void {
        return self.vtable.recv(self.ctx, gpa, out);
    }

    pub fn kick(self: *Link) void {
        self.vtable.kick(self.ctx);
    }
};
