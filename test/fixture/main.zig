// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! wland-fixture: small Wayland clients standing in for the real apps the
//! E2E tests used to need. One binary, one mode per app it replaces; each
//! mode mirrors what the tests read off that app (its output format, its
//! protocol log under WAYLAND_DEBUG, its window layout), so a test phase
//! runs against the fixture or the real app alike (test/support/apps.ts).
//!
//!   info                         wayland-info: globals, shm formats, seat
//!   shm                          weston-simple-shm: an animated window
//!   presentation [-f]            weston-presentation-shm -f: feedback per frame
//!   copy [--primary] [--foreground] [--clear] [TEXT]   wl-copy
//!   paste [--primary] [--no-newline]                   wl-paste
//!   cursor                       weston-flower: a cursor surface (set_cursor)
//!   constraints                  weston-constraints: confine, then lock
//!   relative                     an SDL app in relative mouse mode
//!   term [ignored args…]         foot: CSD subsurfaces, keys, a mini shell
//!   files [DIR]                  nautilus: shadow, input region, popup menus
//!                                (hamburger, right-click; shadowed), double
//!                                click, minimize/maximize, drag and drop
//!   fullscreen [-f]              weston-fullscreen: `f` toggles fullscreen
//!   browser                      Firefox's seat shape: wl_seat bound twice
//!                                (GTK's v5, its own v8); acts on GTK's objects
//!   dmabuf                       weston-simple-dmabuf-egl: linux-dmabuf buffers
//!                                (memfds: needs a relay that takes them, e.g.
//!                                the test-only `--dmabuf virtgpu:@fake`)

const std = @import("std");
const wl = @import("wl.zig");

const usage =
    \\usage: wland-fixture <mode> [args]
    \\modes: info shm presentation copy paste cursor constraints relative term files fullscreen browser dmabuf
    \\
;

pub fn main(init: std.process.Init) !void {
    // a short-lived test client: everything goes in the arena, nothing is freed
    const gpa = init.arena.allocator();
    var it: std.process.Args.Iterator = .init(init.minimal.args);
    defer it.deinit();
    _ = it.next();
    const mode = it.next() orelse {
        wl.writeFd(2, usage);
        std.process.exit(2);
    };
    var rest: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| try rest.append(gpa, a);
    const args = rest.items;
    const env = init.environ_map;

    const modes = .{
        .{ "info", @import("info.zig").run },
        .{ "shm", @import("simple.zig").runShm },
        .{ "presentation", @import("simple.zig").runPresentation },
        .{ "copy", @import("clip.zig").runCopy },
        .{ "paste", @import("clip.zig").runPaste },
        .{ "cursor", @import("pointer.zig").runCursor },
        .{ "constraints", @import("pointer.zig").runConstraints },
        .{ "relative", @import("pointer.zig").runRelative },
        .{ "term", @import("term.zig").run },
        .{ "files", @import("files.zig").run },
        .{ "fullscreen", @import("fullscreen.zig").run },
        .{ "browser", @import("browser.zig").run },
        .{ "dmabuf", @import("dmabuf.zig").run },
    };
    inline for (modes) |m| {
        if (std.mem.eql(u8, mode, m[0])) return m[1](gpa, env, args);
    }
    wl.writeFd(2, usage);
    std.process.exit(2);
}
