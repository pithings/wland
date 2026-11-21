// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! `term`: foot's shape, as the tests see it. The toplevel surface is the
//! text grid; client-side decorations are five subsurfaces around it — a
//! titlebar above the grid (inside the window geometry) and four borders
//! just outside it. The grid draws from three buffers in one sparse pool
//! with partial damage (each buffer repaints what changed since it was last
//! used). Keys go through a US layout with Shift into a line editor; Enter
//! runs the line in a mini shell that knows what the tests type:
//!   printf 'FMT'   \033 \007 \n \\ escapes; OSC 2 (ESC ] 2 ; TITLE BEL) retitles
//!   echo WORDS     seq [FIRST] LAST     clear     exit
//! Commands chain with `;`. The pointer gets cursor shapes (text over the
//! grid); a press on the titlebar moves the window, on a border resizes it.
//! Buffer scale follows wl_surface.preferred_buffer_scale.
//! Extra arguments (foot's `bash --norc …`) are ignored.

const std = @import("std");
const wl = @import("wl.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const Plane = @import("pointer.zig").Plane;

const T = 26; // titlebar height
const B = 5; // border width
const CW = 8; // cell
const CH = 12;
const PAD = 4;
const BG = 0xff1c1c24;
const FG = 0xffd8d8c8;
const PROMPT = 0xff60c080;
const BTN_LEFT = 0x110;

const Deco = enum(u3) { titlebar, top, left, right, bottom };

const Ctx = struct {
    gpa: std.mem.Allocator,
    app: app_mod.App = undefined,
    win: app_mod.Window = undefined,
    decos: [5]Plane = undefined,
    subs: [5]u32 = undefined,
    pool: wl.Pool = .{ .mem = &.{}, .n = 0 },
    pool_scale: u32 = 0,
    w: u32 = 640,
    h: u32 = 384,
    title: std.ArrayList(u8) = .empty,
    lines: std.ArrayList([]u8) = .empty,
    input: std.ArrayList(u8) = .empty,
    /// the rows as last drawn (diffed for damage)
    shown: std.ArrayList([]u8) = .empty,
    dirty: wl.Rect = .{},
    over: u32 = 0,
    enter_serial: u32 = 0,
    shape: u32 = 0,
    px: f64 = 0,
    py: f64 = 0,
    ready: bool = false,
    done: bool = false,

    pub fn onEvent(ctx: *Ctx, ev: wl.Event) void {
        if (ctx.app.handle(ev)) return;
        if (ev.is("wl_buffer", "release")) {
            if (ctx.pool.released(ev.id)) return;
            for (&ctx.decos) |*d| if (d.pool.released(ev.id)) return;
            return;
        }
        if (!ctx.ready) return;
        if (ev.is("wl_keyboard", "key")) {
            if (ev.uint(3) == 1) ctx.key(ev.uint(2));
        } else if (ev.is("wl_keyboard", "enter") or ev.is("wl_keyboard", "leave")) {
            // focus: nothing to redraw (no cursor blink)
        } else if (ev.is("wl_pointer", "enter")) {
            ctx.over = ev.uint(1);
            ctx.enter_serial = ev.uint(0);
            ctx.shape = 0;
            ctx.pointerAt(ev.num(2), ev.num(3));
        } else if (ev.is("wl_pointer", "leave")) {
            ctx.over = 0;
        } else if (ev.is("wl_pointer", "motion")) {
            ctx.pointerAt(ev.num(1), ev.num(2));
        } else if (ev.is("wl_pointer", "button")) {
            if (ev.uint(3) == 1 and ev.uint(2) == BTN_LEFT) ctx.press(ev.uint(0));
        } else if (ev.is("wl_pointer", "axis")) {
            // no scrollback view
        } else switch (ctx.win.handle(&ctx.app, ev)) {
            .configure => ctx.configure(),
            .scale => ctx.configure(),
            .frame => if (!ctx.dirty.empty()) ctx.drawGrid(),
            .close => ctx.done = true,
            .none => {},
        }
    }

    // --- input -----------------------------------------------------------------

    fn key(ctx: *Ctx, code: u32) void {
        if (ctx.app.ctrl) {
            if (code == 32) ctx.done = true; // ^D
            if (code == 46) { // ^C
                ctx.output("^C");
                ctx.input.clearRetainingCapacity();
                ctx.changed();
            }
            return;
        }
        const ch = app_mod.keyChar(code, ctx.app.shift);
        switch (ch) {
            0, '\t' => return,
            '\n' => {
                const line = ctx.gpa.dupe(u8, ctx.input.items) catch return;
                var echoed: std.ArrayList(u8) = .empty;
                echoed.appendSlice(ctx.gpa, "$ ") catch {};
                echoed.appendSlice(ctx.gpa, line) catch {};
                ctx.lines.append(ctx.gpa, echoed.items) catch {};
                ctx.input.clearRetainingCapacity();
                ctx.run(line);
            },
            0x08 => {
                if (ctx.input.items.len > 0) _ = ctx.input.pop();
            },
            else => ctx.input.append(ctx.gpa, ch) catch {},
        }
        ctx.changed();
    }

    fn output(ctx: *Ctx, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| ctx.lines.append(ctx.gpa, ctx.gpa.dupe(u8, l) catch return) catch {};
        if (ctx.lines.items.len > 1000) {
            const drop = ctx.lines.items.len - 1000;
            std.mem.copyForwards([]u8, ctx.lines.items[0..1000], ctx.lines.items[drop..]);
            ctx.lines.shrinkRetainingCapacity(1000);
        }
    }

    /// The mini shell: `;`-separated commands, quotes respected.
    fn run(ctx: *Ctx, line: []const u8) void {
        var start: usize = 0;
        var quote: u8 = 0;
        for (line, 0..) |ch, i| {
            if (quote != 0) {
                if (ch == quote) quote = 0;
            } else if (ch == '\'' or ch == '"') {
                quote = ch;
            } else if (ch == ';') {
                ctx.command(line[start..i]);
                start = i + 1;
            }
        }
        ctx.command(line[start..]);
    }

    fn command(ctx: *Ctx, text: []const u8) void {
        var words: std.ArrayList([]const u8) = .empty;
        var word: std.ArrayList(u8) = .empty;
        var quote: u8 = 0;
        var in_word = false;
        for (text) |ch| {
            if (quote != 0) {
                if (ch == quote) quote = 0 else word.append(ctx.gpa, ch) catch {};
            } else if (ch == '\'' or ch == '"') {
                quote = ch;
                in_word = true;
            } else if (ch == ' ') {
                if (in_word) words.append(ctx.gpa, word.toOwnedSlice(ctx.gpa) catch "") catch {};
                in_word = false;
            } else {
                word.append(ctx.gpa, ch) catch {};
                in_word = true;
            }
        }
        if (in_word) words.append(ctx.gpa, word.toOwnedSlice(ctx.gpa) catch "") catch {};
        const w = words.items;
        if (w.len == 0) return;
        if (std.mem.eql(u8, w[0], "printf")) {
            if (w.len > 1) ctx.printf(w[1]);
        } else if (std.mem.eql(u8, w[0], "echo")) {
            ctx.output(std.mem.join(ctx.gpa, " ", w[1..]) catch "");
        } else if (std.mem.eql(u8, w[0], "seq")) {
            const first = if (w.len > 2) std.fmt.parseInt(u32, w[1], 10) catch 1 else 1;
            const last = std.fmt.parseInt(u32, w[w.len - 1], 10) catch 0;
            var n = first;
            while (n <= last) : (n += 1) ctx.output(std.fmt.allocPrint(ctx.gpa, "{d}", .{n}) catch "");
        } else if (std.mem.eql(u8, w[0], "clear")) {
            ctx.lines.clearRetainingCapacity();
        } else if (std.mem.eql(u8, w[0], "exit")) {
            ctx.done = true;
        } else {
            ctx.output(std.fmt.allocPrint(ctx.gpa, "{s}: command not found", .{w[0]}) catch "");
        }
    }

    fn printf(ctx: *Ctx, fmt: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            if (fmt[i] != '\\' or i + 1 == fmt.len) {
                out.append(ctx.gpa, fmt[i]) catch {};
                continue;
            }
            i += 1;
            switch (fmt[i]) {
                'n' => out.append(ctx.gpa, '\n') catch {},
                'e' => out.append(ctx.gpa, 0x1b) catch {},
                'a' => out.append(ctx.gpa, 0x07) catch {},
                '\\' => out.append(ctx.gpa, '\\') catch {},
                '0' => {
                    var v: u8 = 0;
                    var k: usize = 0;
                    while (k < 3 and i + 1 < fmt.len and fmt[i + 1] >= '0' and fmt[i + 1] <= '7') : (k += 1) {
                        i += 1;
                        v = v *% 8 +% (fmt[i] - '0');
                    }
                    out.append(ctx.gpa, v) catch {};
                },
                else => |c| {
                    out.append(ctx.gpa, '\\') catch {};
                    out.append(ctx.gpa, c) catch {};
                },
            }
        }
        // OSC 0/2 ; title BEL (or ESC \) sets the title; the rest is printed
        var text: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        const s = out.items;
        while (k < s.len) {
            if (s[k] == 0x1b and k + 3 < s.len and s[k + 1] == ']' and (s[k + 2] == '2' or s[k + 2] == '0') and s[k + 3] == ';') {
                const from = k + 4;
                var end = from;
                while (end < s.len and s[end] != 0x07 and s[end] != 0x1b) end += 1;
                ctx.setTitle(s[from..end]);
                k = if (end < s.len and s[end] == 0x1b) end + 2 else end + 1;
                continue;
            }
            text.append(ctx.gpa, s[k]) catch {};
            k += 1;
        }
        if (text.items.len > 0) ctx.output(std.mem.trimEnd(u8, text.items, "\n"));
    }

    fn setTitle(ctx: *Ctx, t: []const u8) void {
        ctx.title.clearRetainingCapacity();
        ctx.title.appendSlice(ctx.gpa, t) catch {};
        ctx.win.setTitle(&ctx.app, t);
        ctx.drawDecos();
        ctx.app.c.send(ctx.win.surface, "wl_surface", "commit", &.{});
    }

    fn which(ctx: *Ctx, surface: u32) ?Deco {
        for (ctx.decos, 0..) |d, i| if (d.surface == surface) return @enumFromInt(i);
        return null;
    }

    fn edges(ctx: *Ctx, d: Deco, x: f64, y: f64) u32 {
        const wf: f64 = @floatFromInt(ctx.w);
        const hf: f64 = @floatFromInt(ctx.h + T);
        return switch (d) {
            .titlebar => 0,
            .top => 1 | @as(u32, if (x < B + 16) 4 else if (x > wf + B - 16) 8 else 0),
            .bottom => 2 | @as(u32, if (x < B + 16) 4 else if (x > wf + B - 16) 8 else 0),
            .left => 4 | @as(u32, if (y < 16) 1 else if (y > hf - 16) 2 else 0),
            .right => 8 | @as(u32, if (y < 16) 1 else if (y > hf - 16) 2 else 0),
        };
    }

    fn pointerAt(ctx: *Ctx, x: f64, y: f64) void {
        ctx.px = x;
        ctx.py = y;
        var shape: u32 = 9; // text
        if (ctx.which(ctx.over)) |d| {
            shape = switch (ctx.edges(d, x, y)) {
                0 => 1,
                1 => 19,
                2 => 22,
                4 => 25,
                8 => 18,
                5 => 21,
                9 => 20,
                6 => 24,
                10 => 23,
                else => 1,
            };
        }
        if (shape != ctx.shape) {
            ctx.shape = shape;
            ctx.app.setShape(ctx.enter_serial, shape);
        }
    }

    fn press(ctx: *Ctx, serial: u32) void {
        const d = ctx.which(ctx.over) orelse return;
        const e = ctx.edges(d, ctx.px, ctx.py);
        if (e == 0) {
            ctx.app.c.send(ctx.win.toplevel, "xdg_toplevel", "move", &.{ .{ .object = ctx.app.seat }, .{ .uint = serial } });
        } else {
            ctx.app.c.send(ctx.win.toplevel, "xdg_toplevel", "resize", &.{ .{ .object = ctx.app.seat }, .{ .uint = serial }, .{ .uint = e } });
        }
    }

    // --- drawing ------------------------------------------------------------------

    fn rows(ctx: *Ctx) u32 {
        return @max((ctx.h - 2 * PAD) / CH, 1);
    }

    /// The visible rows: the tail of the scrollback, then the prompt with a
    /// cursor (\x01).
    fn visible(ctx: *Ctx, out: *std.ArrayList([]u8)) void {
        const n = ctx.rows();
        var prompt: std.ArrayList(u8) = .empty;
        prompt.appendSlice(ctx.gpa, "$ ") catch {};
        prompt.appendSlice(ctx.gpa, ctx.input.items) catch {};
        prompt.append(ctx.gpa, 1) catch {};
        const total = ctx.lines.items.len + 1;
        const first = if (total > n) total - n else 0;
        var i = first;
        while (i < total) : (i += 1) {
            out.append(ctx.gpa, if (i < ctx.lines.items.len) ctx.lines.items[i] else prompt.items) catch {};
        }
    }

    /// The scene changed: damage the rows that differ from what was shown.
    fn changed(ctx: *Ctx) void {
        var now: std.ArrayList([]u8) = .empty;
        ctx.visible(&now);
        const n = @max(now.items.len, ctx.shown.items.len);
        for (0..n) |i| {
            const a: []const u8 = if (i < now.items.len) now.items[i] else "";
            const b: []const u8 = if (i < ctx.shown.items.len) ctx.shown.items[i] else "";
            if (!std.mem.eql(u8, a, b)) ctx.dirty = ctx.dirty.join(.{ .x = 0, .y = @intCast(PAD + i * CH), .w = ctx.w, .h = CH });
        }
        for (ctx.shown.items) |r| ctx.gpa.free(r);
        ctx.shown.clearRetainingCapacity();
        for (now.items) |r| ctx.shown.append(ctx.gpa, ctx.gpa.dupe(u8, r) catch continue) catch {};
        ctx.dirty = ctx.dirty.clip(ctx.w, ctx.h);
        if (ctx.win.frame_cb == 0 and !ctx.dirty.empty()) ctx.drawGrid();
    }

    fn scaled(ctx: *Ctx, r: wl.Rect) wl.Rect {
        const s = ctx.win.scale;
        return .{ .x = r.x * s, .y = r.y * s, .w = r.w * s, .h = r.h * s };
    }

    fn drawGrid(ctx: *Ctx) void {
        const c = ctx.app.c;
        const s = ctx.win.scale;
        if (ctx.pool.n == 0 or ctx.pool.buffers[0].width != ctx.w * s or ctx.pool.buffers[0].height != ctx.h * s) {
            if (ctx.pool.n != 0) ctx.pool.destroy(c);
            ctx.pool = wl.Pool.create(c, ctx.app.shm, 3, ctx.w * s, ctx.h * s, wl.XRGB8888, 4096);
            ctx.dirty = .{ .x = 0, .y = 0, .w = ctx.w, .h = ctx.h };
        }
        ctx.pool.damage(ctx.scaled(ctx.dirty));
        const b = ctx.pool.free() orelse return; // a release comes; dirty stays
        var cv: draw.Canvas = .{ .px = b.pixels, .w = b.width, .h = b.height };
        const st = b.stale.clip(b.width, b.height);
        cv.setClip(st.x, st.y, st.w, st.h);
        const si: i32 = @intCast(s);
        cv.rect(0, 0, @intCast(b.width), @intCast(b.height), BG);
        for (ctx.shown.items, 0..) |row, i| {
            const y: i32 = @intCast((PAD + i * CH) * s);
            var x: i32 = PAD * si;
            for (row, 0..) |ch, k| {
                if (ch == 1) {
                    cv.rect(x, y, CW * si, (CH - 1) * si, FG);
                } else {
                    const color: u32 = if (k < 2 and row.len >= 2 and row[0] == '$') PROMPT else FG;
                    cv.text(x + si, y + si, 2 * si, color, &.{ch});
                }
                x += CW * si;
            }
        }
        b.stale = .{};
        const d = ctx.scaled(ctx.dirty);
        c.send(ctx.win.surface, "wl_surface", "set_buffer_scale", &.{.{ .int = si }});
        c.send(ctx.win.surface, "wl_surface", "attach", &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
        c.send(ctx.win.surface, "wl_surface", "damage_buffer", &.{ .{ .int = @intCast(d.x) }, .{ .int = @intCast(d.y) }, .{ .int = @intCast(d.w) }, .{ .int = @intCast(d.h) } });
        ctx.win.requestFrame(&ctx.app);
        c.send(ctx.win.surface, "wl_surface", "commit", &.{});
        b.busy = true;
        ctx.dirty = .{};
    }

    fn decoRect(ctx: *Ctx, d: Deco) [4]i32 {
        const w: i32 = @intCast(ctx.w);
        const h: i32 = @intCast(ctx.h);
        return switch (d) {
            .titlebar => .{ 0, -T, w, T },
            .top => .{ -B, -T - B, w + 2 * B, B },
            .left => .{ -B, -T, B, h + T },
            .right => .{ w, -T, B, h + T },
            .bottom => .{ -B, h, w + 2 * B, B },
        };
    }

    fn drawDecos(ctx: *Ctx) void {
        const c = ctx.app.c;
        for (&ctx.decos, 0..) |*p, i| {
            const d: Deco = @enumFromInt(i);
            const r = ctx.decoRect(d);
            p.scale = ctx.win.scale;
            const b = p.buffer(&ctx.app, @intCast(r[2]), @intCast(r[3])) orelse continue;
            var cv = Plane.canvas(b);
            const si: i32 = @intCast(p.scale);
            if (d == .titlebar) {
                cv.gradient(0, 0, @intCast(b.width), @intCast(b.height), 0xff3a3a48, 0xff2a2a34);
                cv.text(8 * si, 8 * si, 2 * si, 0xffe0e0e0, ctx.title.items);
                cv.rect(@as(i32, @intCast(b.width)) - 22 * si, 5 * si, 16 * si, 16 * si, 0xffc04040); // close box (drawn only)
            } else {
                cv.rect(0, 0, @intCast(b.width), @intCast(b.height), 0xff2a2a34);
            }
            c.send(ctx.subs[i], "wl_subsurface", "set_position", &.{ .{ .int = r[0] }, .{ .int = r[1] } });
            p.commit(&ctx.app, b);
        }
    }

    fn configure(ctx: *Ctx) void {
        if (ctx.win.want_w > 0) ctx.w = @max(ctx.win.want_w, 160);
        if (ctx.win.want_h > 0) ctx.h = @max(ctx.win.want_h, T + 3 * CH) - T;
        const c = ctx.app.c;
        c.send(ctx.win.xdg_surface, "xdg_surface", "set_window_geometry", &.{ .{ .int = 0 }, .{ .int = -T }, .{ .int = @intCast(ctx.w) }, .{ .int = @intCast(ctx.h + T) } });
        ctx.drawDecos();
        for (ctx.shown.items) |r| ctx.gpa.free(r);
        ctx.shown.clearRetainingCapacity();
        ctx.dirty = .{ .x = 0, .y = 0, .w = ctx.w, .h = ctx.h };
        var now: std.ArrayList([]u8) = .empty;
        ctx.visible(&now);
        for (now.items) |r| ctx.shown.append(ctx.gpa, ctx.gpa.dupe(u8, r) catch continue) catch {};
        // a configure is answered at once, frame callback pending or not
        ctx.drawGrid();
        if (!ctx.dirty.empty()) c.send(ctx.win.surface, "wl_surface", "commit", &.{});
    }
};

pub fn run(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    _ = args;
    var ctx: Ctx = .{ .gpa = gpa };
    ctx.app = app_mod.App.init(gpa, env, &ctx);
    const c = ctx.app.c;
    c.roundtrip(&ctx);
    try ctx.title.appendSlice(gpa, "term");
    ctx.win = app_mod.Window.create(&ctx.app, "term", "wland-fixture.term", ctx.w, ctx.h + T);
    for (&ctx.decos, 0..) |*p, i| {
        p.* = .{ .surface = ctx.app.surface(), .format = wl.ARGB8888 };
        ctx.subs[i] = ctx.app.subsurface(p.surface, ctx.win.surface);
    }
    ctx.ready = true;
    while (!ctx.done) if (!c.dispatch(&ctx, -1)) break;
}
