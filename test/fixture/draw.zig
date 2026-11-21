// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! Pixels into a wl_shm buffer (0xAARRGGBB words, little endian = BGRA
//! bytes): rects, gradients, a 3×5 pixel font scaled up.

const std = @import("std");

pub const Canvas = struct {
    px: []u32,
    w: u32,
    h: u32,
    /// clip: draws outside it are dropped (a repaint of one rect)
    clip_x0: u32 = 0,
    clip_y0: u32 = 0,
    clip_x1: u32 = std.math.maxInt(u32),
    clip_y1: u32 = std.math.maxInt(u32),

    pub fn setClip(c: *Canvas, x: u32, y: u32, w: u32, h: u32) void {
        c.clip_x0 = x;
        c.clip_y0 = y;
        c.clip_x1 = x + w;
        c.clip_y1 = y + h;
    }

    pub fn rect(c: *Canvas, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        const x0: u32 = @intCast(@max(x, @as(i32, @intCast(c.clip_x0))));
        const y0: u32 = @intCast(@max(y, @as(i32, @intCast(c.clip_y0))));
        const x1: u32 = @intCast(std.math.clamp(x + w, 0, @as(i32, @intCast(@min(c.w, c.clip_x1)))));
        const y1: u32 = @intCast(std.math.clamp(y + h, 0, @as(i32, @intCast(@min(c.h, c.clip_y1)))));
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            if (x0 < x1) @memset(c.px[yy * c.w + x0 .. yy * c.w + x1], color);
        }
    }

    /// A vertical gradient with a horizontal tint: many distinct colours.
    pub fn gradient(c: *Canvas, x: i32, y: i32, w: i32, h: i32, top: u32, bottom: u32) void {
        if (h <= 0) return;
        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const t: u32 = @intCast(@divTrunc(row * 255, h));
            c.rect(x, y + row, w, 1, mix(top, bottom, t));
        }
    }

    pub fn text(c: *Canvas, x: i32, y: i32, scale: i32, color: u32, s: []const u8) void {
        var cx = x;
        for (s) |ch| {
            const g = glyph(ch);
            var row: u5 = 0;
            while (row < 5) : (row += 1) {
                var col: u5 = 0;
                while (col < 3) : (col += 1) {
                    const bit = (g >> (3 * (4 - @as(u4, @intCast(row))) + (2 - @as(u4, @intCast(col))))) & 1;
                    if (bit != 0) c.rect(cx + col * scale, y + row * scale, scale, scale, color);
                }
            }
            cx += 4 * scale;
        }
    }
};

pub fn mix(a: u32, b: u32, t: u32) u32 {
    var out: u32 = 0xff000000;
    inline for (.{ 0, 8, 16 }) |sh| {
        const ca = (a >> sh) & 0xff;
        const cb = (b >> sh) & 0xff;
        out |= ((ca * (255 - t) + cb * t) / 255) << sh;
    }
    return out;
}

pub fn textWidth(s: []const u8, scale: i32) i32 {
    return @as(i32, @intCast(s.len)) * 4 * scale;
}

/// 3×5 glyphs: 15 bits, rows top to bottom, 3 bits each (MSB left).
fn glyph(ch: u8) u15 {
    const c = std.ascii.toUpper(ch);
    return switch (c) {
        '0' => 0o75557, '1' => 0o26227, '2' => 0o71747, '3' => 0o71717, '4' => 0o55711,
        '5' => 0o74717, '6' => 0o74757, '7' => 0o71111, '8' => 0o75757, '9' => 0o75717,
        'A' => 0o25755, 'B' => 0o65656, 'C' => 0o34443, 'D' => 0o65556, 'E' => 0o74647,
        'F' => 0o74644, 'G' => 0o34553, 'H' => 0o55755, 'I' => 0o72227, 'J' => 0o11152,
        'K' => 0o55655, 'L' => 0o44447, 'M' => 0o57755, 'N' => 0o65555, 'O' => 0o25552,
        'P' => 0o65644, 'Q' => 0o25563, 'R' => 0o65655, 'S' => 0o34216, 'T' => 0o72222,
        'U' => 0o55557, 'V' => 0o55552, 'W' => 0o55775, 'X' => 0o55255, 'Y' => 0o55222,
        'Z' => 0o71247, ' ' => 0, '-' => 0o00700, '.' => 0o00002, ':' => 0o02020,
        '_' => 0o00007, '/' => 0o11244, '\\' => 0o44211, '\'' => 0o22000, '"' => 0o55000,
        ';' => 0o02024, ',' => 0o00024, '!' => 0o22202, '?' => 0o71202, '=' => 0o07070,
        '+' => 0o02720, '*' => 0o05250, '(' => 0o12221, ')' => 0o42224, '[' => 0o32223,
        ']' => 0o62226, '<' => 0o12421, '>' => 0o42124, '#' => 0o57575, '$' => 0o37676,
        '%' => 0o51245, '&' => 0o25257, '@' => 0o75543, '^' => 0o25000, '|' => 0o22222,
        '{' => 0o32623, '}' => 0o62326, '~' => 0o00630, '`' => 0o42000,
        else => 0o77777,
    };
}
