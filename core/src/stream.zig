// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

//! STREAM framing between relay and engine (WS or byte-stream link) — see
//! protocol/STREAM.md (v2). Shared by the relay (native) and the engine (wasm):
//! one parser, one set of encoders. Integers are little-endian; frames are
//! packed unaligned, so every field is read with readInt.

const std = @import("std");

pub const FrameType = enum(u8) {
    wire = 0x01,
    buffer = 0x02,
    conn_open = 0x03,
    conn_close = 0x04,
    fdmsg = 0x05,
    srvobj = 0x06,
    buffer_lz = 0x07,
    /// relay→engine: a buffer handle the engine opens through its buffer
    /// source (handle backends only).
    handle_open = 0x08,
    /// relay→engine: no commit will reference the handle again; close it.
    handle_close = 0x09,
    /// relay→engine: a commit notice — the engine reads the pixels in place
    /// (handle backends only; the copy backend ships BUFFER/BUFFER_LZ).
    commit = 0x0a,
    /// engine→relay: a commit notice's pixels are consumed; the relay may
    /// release the buffer.
    ack = 0x0b,
    /// relay→engine, first on a link: something the relay can do that
    /// changes what the compositor offers (FeatureKind; today linux-dmabuf).
    feature = 0x0c,
    /// engine→relay: a zwp_linux_buffer_params_v1.create made server-
    /// allocated wl_buffer `buffer_id`; sent just before the `created` event.
    dmabuf_created = 0x0d,
    /// engine→relay: a wp_presentation_feedback.presented event whose
    /// timestamp the relay writes (its CLOCK_MONOTONIC, less `age_us`)
    /// before passing it to the app.
    presented = 0x0e,
    /// viewer→relay (session profile): one embedder call (`CallOp`).
    call = 0x0f,
    /// relay→viewer (session profile): one embedder event (`EventOp`).
    event = 0x10,
    /// relay→viewer (session profile): a surface's synchronous state
    /// (`SurfaceFrame`).
    surface = 0x11,
};

/// A damage rect, buffer px.
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

fn readRect(b: *const [16]u8) Rect {
    return .{
        .x = std.mem.readInt(i32, b[0..4], .little),
        .y = std.mem.readInt(i32, b[4..8], .little),
        .w = std.mem.readInt(i32, b[8..12], .little),
        .h = std.mem.readInt(i32, b[12..16], .little),
    };
}

pub const BufferFrame = struct {
    conn_id: u32,
    surface_id: u32,
    width: u32,
    height: u32,
    n_rects: u32,
    /// n_rects × 16 bytes of {i32 x,y,w,h}, unaligned.
    rect_bytes: []const u8,
    /// Canvas-ready RGBA: tightly packed rows (w*4 bytes each) per rect,
    /// concatenated. The server swizzles from wl_shm BGRA at ship time.
    pixels: []const u8,

    pub fn rectAt(self: *const BufferFrame, i: u32) Rect {
        return readRect(self.rect_bytes[@as(usize, i) * 16 ..][0..16]);
    }
};


/// Like BufferFrame but the pixel section is LZ4-block compressed. Same header
/// + rects, then a u32 raw_len (uncompressed pixel byte count, = sum w*h*4) and
/// a u32 comp_len, then comp_len compressed bytes. The server ships this
/// instead of BUFFER when the pixels compress below the raw size and clear a
/// threshold; the browser wasm decodes it back to the raw BUFFER layout.
pub const BufferLzFrame = struct {
    conn_id: u32,
    surface_id: u32,
    width: u32,
    height: u32,
    n_rects: u32,
    rect_bytes: []const u8,
    raw_len: u32,
    comp: []const u8,

    pub fn rectAt(self: *const BufferLzFrame, i: u32) Rect {
        return readRect(self.rect_bytes[@as(usize, i) * 16 ..][0..16]);
    }
};

/// FDMSG `kind`. shm_pool and dmabuf travel relay→engine (the relay kept the
/// client's fd); memfd engine→relay (the relay makes a memfd from the aux
/// bytes: wl_keyboard.keymap, zwp_linux_dmabuf_feedback_v1.format_table);
/// pipe both ways (clipboard, token in aux); pipe_read both ways (the
/// engine reads the selection: engine→relay the source's send event, aux =
/// read id ++ max bytes; relay→engine the bytes, aux = read id ++ status ++
/// bytes, no wire message); own_pipe engine→relay only, to a relay that
/// announced FEATURE selection_cache (`OwnPipe`).
pub const FdMsgKind = enum(u32) { shm_pool = 1, memfd = 2, pipe = 3, dmabuf = 4, pipe_read = 5, own_pipe = 6 };

/// FDMSG own_pipe aux (engine→relay, no wire message): a receive of the
/// engine's own selection answered from the relay's copy of its payload.
/// `token` = the parked receive (0: none), `gen` = the own selection's
/// generation (0: the own selection is gone — drop the copy), `blob` = which
/// payload (< 32), `flags` bit 0 = the payload's bytes follow (the first
/// receive of it on this link): the relay keeps them (replacing what it
/// kept of an older generation) and serves this receive and later ones
/// from them. Without the bit, a payload the relay doesn't have reads EOF.
pub const OwnPipe = struct {
    token: u32,
    gen: u32,
    blob: u32,
    flags: u32,
    bytes: []const u8,

    pub const header_len = 16;
    pub const has_bytes: u32 = 1;

    pub fn writeHeader(self: OwnPipe, out: *[header_len]u8) void {
        std.mem.writeInt(u32, out[0..4], self.token, .little);
        std.mem.writeInt(u32, out[4..8], self.gen, .little);
        std.mem.writeInt(u32, out[8..12], self.blob, .little);
        std.mem.writeInt(u32, out[12..16], self.flags, .little);
    }

    pub fn decode(aux: []const u8) error{BadLength}!OwnPipe {
        if (aux.len < header_len) return error.BadLength;
        return .{
            .token = std.mem.readInt(u32, aux[0..4], .little),
            .gen = std.mem.readInt(u32, aux[4..8], .little),
            .blob = std.mem.readInt(u32, aux[8..12], .little),
            .flags = std.mem.readInt(u32, aux[12..16], .little),
            .bytes = aux[header_len..],
        };
    }
};

/// pipe_read reply `status` (relay→engine aux bytes 4..8).
pub const PipeReadStatus = enum(u32) {
    /// the source wrote, then closed: the bytes are all of it
    ok = 0,
    /// the source wrote more than max_bytes: no bytes sent
    too_large = 1,
    /// the source did not close the pipe before the relay's deadline
    timeout = 2,
    /// no such conn any more, or the pipe failed
    failed = 3,
};

/// FEATURE `feature`: which capability the frame announces. An engine that
/// does not know one skips it (the frame is self-delimiting).
pub const FeatureKind = enum(u32) {
    /// The relay takes dmabufs (zwp_linux_buffer_params_v1.add fds): the
    /// compositor advertises zwp_linux_dmabuf_v1. Bytes: `DmabufFeature`.
    linux_dmabuf = 1,
    /// How the relay's dmabuf commits reach the engine: as COMMITs of one
    /// buffer kind (today virtgpu — GPU resources only the embedder's
    /// renderer can draw). Sent just before linux_dmabuf; absent, dmabuf
    /// commits travel as pixels (readback), which every engine shows. An
    /// engine that can't show that kind does not offer linux-dmabuf.
    /// Bytes: `DmabufKindFeature`.
    dmabuf_kind = 2,
    /// The relay bridges the clipboard for the engine: it reads selections
    /// for it (FDMSG pipe_read) and keeps a copy of each payload of the
    /// engine's own selection it is sent (FDMSG own_pipe), serving every
    /// receive of it from that copy (each payload crosses once per link).
    /// Without it (a relay that predates it: wlandr 0.1.0) the engine sends
    /// neither and offers clients no selection of its own. Bytes: none (any
    /// are ignored).
    selection_cache = 3,
    /// The link runs the session profile (STREAM.md "Profiles"): the
    /// compositor lives in the relay and the engine is a viewer (CALL in,
    /// EVENT and SURFACE out). Bytes: `u64 session_id` (random per relay
    /// run).
    session = 4,
};

/// FEATURE bytes of kind dmabuf_kind: `u32 buffer_kind` (BufferKind, the
/// COMMIT kind every dmabuf commit carries). Fields are only ever
/// appended: a receiver reads the first 4 bytes and ignores the rest.
pub const DmabufKindFeature = struct {
    buffer_kind: u32,

    pub const len = 4;

    pub fn encode(self: DmabufKindFeature, out: *[len]u8) void {
        std.mem.writeInt(u32, out, self.buffer_kind, .little);
    }

    pub fn decode(bytes: []const u8) error{BadLength}!DmabufKindFeature {
        if (bytes.len < len) return error.BadLength;
        return .{ .buffer_kind = std.mem.readInt(u32, bytes[0..4], .little) };
    }
};

/// FEATURE bytes of kind linux_dmabuf: the dev_t clients should allocate on
/// (zwp_linux_dmabuf_feedback_v1 main_device / tranche_target_device), then
/// the format table exactly as the protocol ships it to clients — 16-byte
/// entries {u32 format (DRM fourcc), u32 0, u64 modifier}, native = little
/// endian. The compositor offers exactly these pairs, in one tranche.
pub const DmabufFeature = struct {
    main_device: u64,
    table: []const u8,

    pub const entry_len = 16;
    /// More would not fit one tranche_formats event in the compositor's
    /// 1 KiB event buffer; real tables are a handful of entries.
    pub const max_entries = 256;

    pub fn len(self: DmabufFeature) usize {
        return 8 + self.table.len;
    }

    pub fn encode(self: DmabufFeature, out: []u8) void {
        std.mem.writeInt(u64, out[0..8], self.main_device, .little);
        @memcpy(out[8..][0..self.table.len], self.table);
    }

    pub fn decode(bytes: []const u8) error{BadLength}!DmabufFeature {
        if (bytes.len < 8 + entry_len or (bytes.len - 8) % entry_len != 0) return error.BadLength;
        if ((bytes.len - 8) / entry_len > max_entries) return error.BadLength;
        return .{ .main_device = std.mem.readInt(u64, bytes[0..8], .little), .table = bytes[8..] };
    }

    pub fn count(self: DmabufFeature) usize {
        return self.table.len / entry_len;
    }

    pub fn entry(self: DmabufFeature, i: usize) struct { format: u32, modifier: u64 } {
        const e = self.table[i * entry_len ..][0..entry_len];
        return .{ .format = std.mem.readInt(u32, e[0..4], .little), .modifier = std.mem.readInt(u64, e[8..16], .little) };
    }
};

/// Write one format-table entry (DmabufFeature.table layout).
pub fn writeFormatEntry(out: *[DmabufFeature.entry_len]u8, format: u32, modifier: u64) void {
    std.mem.writeInt(u32, out[0..4], format, .little);
    std.mem.writeInt(u32, out[4..8], 0, .little);
    std.mem.writeInt(u64, out[8..16], modifier, .little);
}

/// SRVOBJ kind — the type of a server-allocated object id. Only primary offers
/// are announced (unregistered server ids default to wl_data_offer).
pub const SrvObjKind = enum(u32) { primary_offer = 1 };

// ---------------------------------------------------------------------------
// Link v2: buffer handles, commit notices, acknowledgements (STREAM.md 0x08–0x0b)
// ---------------------------------------------------------------------------

/// HANDLE_OPEN `kind`: what the handle bytes name. 0 is never valid.
pub const HandleKind = enum(u32) {
    /// An unkernel kwshm export (KWSHM_IOC_EXPORT): `KwshmHandle`.
    kwshm = 1,
    /// Debug/test: a file the relay holds open, read through
    /// /proc/<pid>/fd/<fd>: `ProcfdHandle`.
    procfd = 2,
};

/// Handle bytes of kind kwshm (12 bytes): the export id KWSHM_IOC_EXPORT
/// returned and the bytes exported (its `size` out field). Byte 0 of the
/// handle is byte 0 of the export.
pub const KwshmHandle = struct {
    id: u32,
    size: u64,

    pub const len = 12;

    pub fn encode(self: KwshmHandle, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], self.id, .little);
        std.mem.writeInt(u64, out[4..12], self.size, .little);
    }

    pub fn decode(bytes: []const u8) error{BadLength}!KwshmHandle {
        if (bytes.len != len) return error.BadLength;
        return .{
            .id = std.mem.readInt(u32, bytes[0..4], .little),
            .size = std.mem.readInt(u64, bytes[4..12], .little),
        };
    }
};

/// Handle bytes of kind procfd (24 bytes): the relay's pid, an fd it keeps
/// open for the handle's whole life, the file offset of handle byte 0, and
/// the handle's size in bytes. Byte `i` of the handle is byte `offset + i`
/// of the file.
pub const ProcfdHandle = struct {
    pid: u32,
    fd: u32,
    offset: u64,
    size: u64,

    pub const len = 24;

    pub fn encode(self: ProcfdHandle, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], self.pid, .little);
        std.mem.writeInt(u32, out[4..8], self.fd, .little);
        std.mem.writeInt(u64, out[8..16], self.offset, .little);
        std.mem.writeInt(u64, out[16..24], self.size, .little);
    }

    pub fn decode(bytes: []const u8) error{BadLength}!ProcfdHandle {
        if (bytes.len != len) return error.BadLength;
        return .{
            .pid = std.mem.readInt(u32, bytes[0..4], .little),
            .fd = std.mem.readInt(u32, bytes[4..8], .little),
            .offset = std.mem.readInt(u64, bytes[8..16], .little),
            .size = std.mem.readInt(u64, bytes[16..24], .little),
        };
    }
};

/// 0x08 HANDLE_OPEN. `kind` is kept raw (an unknown kind still frames, so
/// the engine can report it and ack the notices that use it).
pub const HandleOpenFrame = struct {
    conn_id: u32,
    handle_id: u32,
    kind: u32,
    bytes: []const u8,
};

/// COMMIT `kind`: what the buffer reference names. 0 is never valid.
pub const BufferKind = enum(u32) {
    /// A wl_shm buffer read in place through a handle: `ShmRef`.
    shm = 1,
    /// A GPU resource the embedder's renderer holds: `VirtgpuRef`. No
    /// pixels anywhere on the link; the engine's embedder resolves the
    /// resource id. wlandr `--dmabuf virtgpu` emits it.
    virtgpu = 2,
};

/// Buffer reference of kind virtgpu: `len` bytes, then possibly more —
/// later fields are appended and a receiver ignores what it does not know
/// (ref_len ≥ len). The plane fields are plane 0's, as the client gave
/// them in zwp_linux_buffer_params_v1.add; informational (the resource
/// alone names the pixels).
pub const VirtgpuRef = struct {
    /// resource id: whatever the embedder's renderer and its guest side
    /// agree on (e.g. a virgl resource id)
    resource: u32,
    /// the wl_buffer's size, buffer px
    width: u32,
    height: u32,
    /// DRM fourcc (drm_fourcc.h)
    format: u32,
    /// zwp_linux_buffer_params_v1 flags: 1 y_invert, 2 interlaced, 4 bottom_first
    flags: u32,
    offset: u32,
    stride: u32,
    /// DRM format modifier (DRM_FORMAT_MOD_INVALID = 0x00ffffffffffffff:
    /// implicit)
    modifier: u64,

    pub const len = 36;

    pub fn encode(self: VirtgpuRef, out: *[len]u8) void {
        inline for (.{ self.resource, self.width, self.height, self.format, self.flags, self.offset, self.stride }, 0..) |v, i|
            std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .little);
        std.mem.writeInt(u64, out[28..36], self.modifier, .little);
    }

    pub fn decode(bytes: []const u8) error{BadLength}!VirtgpuRef {
        if (bytes.len < len) return error.BadLength;
        return .{
            .resource = std.mem.readInt(u32, bytes[0..4], .little),
            .width = std.mem.readInt(u32, bytes[4..8], .little),
            .height = std.mem.readInt(u32, bytes[8..12], .little),
            .format = std.mem.readInt(u32, bytes[12..16], .little),
            .flags = std.mem.readInt(u32, bytes[16..20], .little),
            .offset = std.mem.readInt(u32, bytes[20..24], .little),
            .stride = std.mem.readInt(u32, bytes[24..28], .little),
            .modifier = std.mem.readInt(u64, bytes[28..36], .little),
        };
    }
};

/// wl_shm.format values a COMMIT may carry — exactly what the compositor
/// advertises (wl_shm.format events).
pub const shm_format_argb8888: u32 = 0;
pub const shm_format_xrgb8888: u32 = 1;

/// Buffer reference of kind shm (24 bytes). Pixel (x, y) is the 4 bytes at
/// handle byte `offset + y * stride + x * 4`, a little-endian
/// 0xAARRGGBB / 0xXXRRGGBB word (bytes B, G, R, A|X).
pub const ShmRef = struct {
    handle_id: u32,
    offset: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,

    pub const len = 24;

    pub fn encode(self: ShmRef, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], self.handle_id, .little);
        std.mem.writeInt(u32, out[4..8], self.offset, .little);
        std.mem.writeInt(u32, out[8..12], self.width, .little);
        std.mem.writeInt(u32, out[12..16], self.height, .little);
        std.mem.writeInt(u32, out[16..20], self.stride, .little);
        std.mem.writeInt(u32, out[20..24], self.format, .little);
    }

    pub fn decode(bytes: []const u8) error{BadLength}!ShmRef {
        if (bytes.len != len) return error.BadLength;
        return .{
            .handle_id = std.mem.readInt(u32, bytes[0..4], .little),
            .offset = std.mem.readInt(u32, bytes[4..8], .little),
            .width = std.mem.readInt(u32, bytes[8..12], .little),
            .height = std.mem.readInt(u32, bytes[12..16], .little),
            .stride = std.mem.readInt(u32, bytes[16..20], .little),
            .format = std.mem.readInt(u32, bytes[20..24], .little),
        };
    }

    /// Bytes of the handle the buffer occupies from `offset`: stride × height
    /// (the relay's fits() rule). The engine checks offset + span ≤ handle size.
    pub fn span(self: ShmRef) u64 {
        return @as(u64, self.stride) * self.height;
    }
};

/// 0x0a COMMIT. `kind` is kept raw so an unknown kind still frames (and
/// still gets its ack).
pub const CommitFrame = struct {
    conn_id: u32,
    surface_id: u32,
    serial: u32,
    n_rects: u32,
    kind: u32,
    /// `kind`-specific buffer reference (shm: ShmRef.len bytes)
    ref: []const u8,
    /// n_rects × 16 bytes of {i32 x,y,w,h}, unaligned
    rect_bytes: []const u8,

    pub fn rectAt(self: *const CommitFrame, i: u32) Rect {
        return readRect(self.rect_bytes[@as(usize, i) * 16 ..][0..16]);
    }

    pub const ShmError = error{ BadKind, BadLength, BadFormat, BadGeometry };

    /// Decode and validate a kind-shm notice (STREAM.md "COMMIT validity"):
    /// a 24-byte ref, width/height ≥ 1, stride ≥ width × 4, format
    /// ARGB8888/XRGB8888, n_rects ≥ 1, every rect non-empty and inside the
    /// buffer. Handle size is the engine's to check (ShmRef.span).
    pub fn shm(self: *const CommitFrame) ShmError!ShmRef {
        if (self.kind != @intFromEnum(BufferKind.shm)) return error.BadKind;
        const ref = try ShmRef.decode(self.ref);
        if (ref.format != shm_format_argb8888 and ref.format != shm_format_xrgb8888) return error.BadFormat;
        if (ref.width == 0 or ref.height == 0 or ref.stride < @as(u64, ref.width) * 4) return error.BadGeometry;
        try self.checkRects(ref.width, ref.height);
        return ref;
    }

    pub const VirtgpuError = error{ BadKind, BadLength, BadGeometry };

    /// Decode and validate a kind-virtgpu notice: a ref of ≥ 36 bytes,
    /// a resource id ≥ 1, width/height ≥ 1, n_rects ≥ 1, every rect
    /// non-empty and inside the buffer. Format and modifier are the
    /// resolver's to judge.
    pub fn virtgpu(self: *const CommitFrame) VirtgpuError!VirtgpuRef {
        if (self.kind != @intFromEnum(BufferKind.virtgpu)) return error.BadKind;
        const ref = try VirtgpuRef.decode(self.ref);
        if (ref.resource == 0 or ref.width == 0 or ref.height == 0) return error.BadGeometry;
        try self.checkRects(ref.width, ref.height);
        return ref;
    }

    fn checkRects(self: *const CommitFrame, width: u32, height: u32) error{BadGeometry}!void {
        if (self.n_rects == 0) return error.BadGeometry;
        var i: u32 = 0;
        while (i < self.n_rects) : (i += 1) {
            const r = self.rectAt(i);
            if (r.x < 0 or r.y < 0 or r.w <= 0 or r.h <= 0) return error.BadGeometry;
            if (@as(i64, r.x) + r.w > width or @as(i64, r.y) + r.h > height) return error.BadGeometry;
        }
    }
};

pub const Frame = union(FrameType) {
    wire: struct { conn_id: u32, bytes: []const u8 },
    buffer: BufferFrame,
    conn_open: u32,
    conn_close: u32,
    fdmsg: struct { conn_id: u32, kind: u32, wire_bytes: []const u8, aux: []const u8 },
    /// browser→server: server-allocated object `object_id` on `conn_id` has
    /// interface-kind `kind` (see SrvObjKind). Lets the server's fd
    /// interception pick the right receive opcode (STREAM.md SRVOBJ).
    srvobj: struct { conn_id: u32, object_id: u32, kind: u32 },
    buffer_lz: BufferLzFrame,
    handle_open: HandleOpenFrame,
    handle_close: struct { conn_id: u32, handle_id: u32 },
    commit: CommitFrame,
    ack: struct { conn_id: u32, serial: u32 },
    /// `feature` is kept raw: an unknown one still frames and is skipped.
    feature: struct { feature: u32, bytes: []const u8 },
    dmabuf_created: struct { conn_id: u32, params_id: u32, buffer_id: u32 },
    /// `bytes` is one wire message, the presented event (see stampPresented).
    presented: struct { conn_id: u32, age_us: u32, bytes: []const u8 },
    call: OpFrame,
    event: OpFrame,
    surface: SurfaceFrame,
};

pub const ParseError = error{ Truncated, UnknownType, BadLength };

pub const Parsed = struct { frame: Frame, consumed: usize };

/// `bytes` holds at least `n` bytes. Lengths are summed in u64: a hostile
/// u32 length must not wrap usize (wasm32) and pass the check.
fn have(bytes: []const u8, n: u64) ParseError!usize {
    if (bytes.len < n) return error.Truncated;
    return @intCast(n);
}

fn u32At(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

/// Parse the frame at the head of `bytes` — frames are self-delimiting, so a
/// WS message may pack several back to back; loop on `consumed` until the
/// message is drained. Slices point into `bytes`. Framing only: kind-specific
/// payloads (handle bytes, buffer refs) are decoded by their own decoders.
pub fn parseNext(bytes: []const u8) ParseError!Parsed {
    if (bytes.len < 1) return error.Truncated;
    const frame_type: FrameType = switch (bytes[0]) {
        0x01...0x11 => @enumFromInt(bytes[0]),
        else => return error.UnknownType,
    };
    switch (frame_type) {
        .wire => {
            _ = try have(bytes, wire_overhead);
            const byte_len = u32At(bytes, 5);
            const total = try have(bytes, @as(u64, wire_overhead) + byte_len);
            return .{
                .frame = .{ .wire = .{ .conn_id = u32At(bytes, 1), .bytes = bytes[wire_overhead..total] } },
                .consumed = total,
            };
        },
        .conn_open, .conn_close => {
            _ = try have(bytes, 5);
            const conn_id = u32At(bytes, 1);
            return .{
                .frame = if (frame_type == .conn_open) .{ .conn_open = conn_id } else .{ .conn_close = conn_id },
                .consumed = 5,
            };
        },
        .buffer => {
            _ = try have(bytes, buffer_header_len);
            var f: BufferFrame = .{
                .conn_id = u32At(bytes, 1),
                .surface_id = u32At(bytes, 5),
                .width = u32At(bytes, 9),
                .height = u32At(bytes, 13),
                .n_rects = u32At(bytes, 17),
                .rect_bytes = undefined,
                .pixels = undefined,
            };
            const rects_end = try have(bytes, buffer_header_len + @as(u64, f.n_rects) * 16);
            f.rect_bytes = bytes[buffer_header_len..rects_end];
            // pixel payload length derives from the rect dims (w*h*4 each)
            var pixels_len: u64 = 0;
            var i: u32 = 0;
            while (i < f.n_rects) : (i += 1) {
                const r = f.rectAt(i);
                if (r.w <= 0 or r.h <= 0) return error.BadLength;
                pixels_len += @as(u64, @intCast(r.w)) * @as(u64, @intCast(r.h)) * 4;
            }
            const total = try have(bytes, @as(u64, rects_end) + pixels_len);
            f.pixels = bytes[rects_end..total];
            return .{ .frame = .{ .buffer = f }, .consumed = total };
        },
        .buffer_lz => {
            _ = try have(bytes, buffer_header_len);
            const n_rects = u32At(bytes, 17);
            const rects_end = try have(bytes, buffer_header_len + @as(u64, n_rects) * 16);
            _ = try have(bytes, @as(u64, rects_end) + buffer_lz_meta_len);
            const raw_len = u32At(bytes, rects_end);
            const comp_len = u32At(bytes, rects_end + 4);
            const total = try have(bytes, @as(u64, rects_end) + buffer_lz_meta_len + comp_len);
            return .{ .frame = .{ .buffer_lz = .{
                .conn_id = u32At(bytes, 1),
                .surface_id = u32At(bytes, 5),
                .width = u32At(bytes, 9),
                .height = u32At(bytes, 13),
                .n_rects = n_rects,
                .rect_bytes = bytes[buffer_header_len..rects_end],
                .raw_len = raw_len,
                .comp = bytes[rects_end + buffer_lz_meta_len .. total],
            } }, .consumed = total };
        },
        .fdmsg => {
            _ = try have(bytes, 13);
            const byte_len = u32At(bytes, 9);
            const wire_end = try have(bytes, 13 + @as(u64, byte_len));
            _ = try have(bytes, @as(u64, wire_end) + 4);
            const aux_len = u32At(bytes, wire_end);
            const total = try have(bytes, @as(u64, wire_end) + 4 + aux_len);
            return .{ .frame = .{ .fdmsg = .{
                .conn_id = u32At(bytes, 1),
                .kind = u32At(bytes, 5),
                .wire_bytes = bytes[13..wire_end],
                .aux = bytes[wire_end + 4 .. total],
            } }, .consumed = total };
        },
        .srvobj => {
            _ = try have(bytes, srvobj_len);
            return .{ .frame = .{ .srvobj = .{
                .conn_id = u32At(bytes, 1),
                .object_id = u32At(bytes, 5),
                .kind = u32At(bytes, 9),
            } }, .consumed = srvobj_len };
        },
        .handle_open => {
            _ = try have(bytes, handle_open_header_len);
            const len = u32At(bytes, 13);
            const total = try have(bytes, @as(u64, handle_open_header_len) + len);
            return .{ .frame = .{ .handle_open = .{
                .conn_id = u32At(bytes, 1),
                .handle_id = u32At(bytes, 5),
                .kind = u32At(bytes, 9),
                .bytes = bytes[handle_open_header_len..total],
            } }, .consumed = total };
        },
        .handle_close => {
            _ = try have(bytes, handle_close_len);
            return .{ .frame = .{ .handle_close = .{
                .conn_id = u32At(bytes, 1),
                .handle_id = u32At(bytes, 5),
            } }, .consumed = handle_close_len };
        },
        .commit => {
            _ = try have(bytes, commit_header_len);
            const n_rects = u32At(bytes, 13);
            const ref_len = u32At(bytes, 21);
            const ref_end = try have(bytes, @as(u64, commit_header_len) + ref_len);
            const total = try have(bytes, @as(u64, ref_end) + @as(u64, n_rects) * 16);
            return .{ .frame = .{ .commit = .{
                .conn_id = u32At(bytes, 1),
                .surface_id = u32At(bytes, 5),
                .serial = u32At(bytes, 9),
                .n_rects = n_rects,
                .kind = u32At(bytes, 17),
                .ref = bytes[commit_header_len..ref_end],
                .rect_bytes = bytes[ref_end..total],
            } }, .consumed = total };
        },
        .ack => {
            _ = try have(bytes, ack_len);
            return .{ .frame = .{ .ack = .{
                .conn_id = u32At(bytes, 1),
                .serial = u32At(bytes, 5),
            } }, .consumed = ack_len };
        },
        .feature => {
            _ = try have(bytes, feature_header_len);
            const len = u32At(bytes, 5);
            const total = try have(bytes, @as(u64, feature_header_len) + len);
            return .{ .frame = .{ .feature = .{
                .feature = u32At(bytes, 1),
                .bytes = bytes[feature_header_len..total],
            } }, .consumed = total };
        },
        .dmabuf_created => {
            _ = try have(bytes, dmabuf_created_len);
            return .{ .frame = .{ .dmabuf_created = .{
                .conn_id = u32At(bytes, 1),
                .params_id = u32At(bytes, 5),
                .buffer_id = u32At(bytes, 9),
            } }, .consumed = dmabuf_created_len };
        },
        .presented => {
            _ = try have(bytes, presented_header_len);
            const byte_len = u32At(bytes, 9);
            const total = try have(bytes, @as(u64, presented_header_len) + byte_len);
            return .{ .frame = .{ .presented = .{
                .conn_id = u32At(bytes, 1),
                .age_us = u32At(bytes, 5),
                .bytes = bytes[presented_header_len..total],
            } }, .consumed = total };
        },
        .call, .event => {
            _ = try have(bytes, op_frame_header_len);
            const len = u32At(bytes, 3);
            const total = try have(bytes, @as(u64, op_frame_header_len) + len);
            const f: OpFrame = .{ .op = std.mem.readInt(u16, bytes[1..3], .little), .args = bytes[op_frame_header_len..total] };
            return .{ .frame = if (frame_type == .call) .{ .call = f } else .{ .event = f }, .consumed = total };
        },
        .surface => {
            _ = try have(bytes, SurfaceFrame.len);
            return .{ .frame = .{ .surface = SurfaceFrame.decode(bytes[0..SurfaceFrame.len]) }, .consumed = SurfaceFrame.len };
        },
    }
}

// ---------------------------------------------------------------------------
// Session profile (STREAM.md "Profiles"): CALL, EVENT, SURFACE
// ---------------------------------------------------------------------------

/// 0x0f CALL / 0x10 EVENT: `op` raw (an unknown one still frames and is
/// skipped), `args` encoded per the op's table row (`ArgReader`).
pub const OpFrame = struct { op: u16, args: []const u8 };

/// CALL / EVENT fixed part: type, u16 op, u32 len.
pub const op_frame_header_len = 7;

/// CALL `op`: one `wland_*` export of core/src/wasm.zig, args as listed in
/// STREAM.md.
pub const CallOp = enum(u16) {
    init = 1,
    set_gpu_source = 2,
    set_dpr = 3,
    desktop_size = 4,
    set_suspended = 5,
    pointer_enter = 6,
    pointer_leave = 7,
    pointer_motion = 8,
    pointer_lock_granted = 9,
    pointer_lock_lost = 10,
    pointer_button = 11,
    pointer_axis = 12,
    keyboard_enter = 13,
    keyboard_leave = 14,
    key = 15,
    keyboard_locks = 16,
    text_input_preedit = 17,
    text_input_commit_string = 18,
    set_maximized = 19,
    set_fullscreen = 20,
    set_minimized = 21,
    popup_dismiss = 22,
    request_resize = 23,
    drag_motion = 24,
    drag_drop = 25,
    drag_cancel = 26,
    set_selection = 27,
    read_selection = 28,
    close = 29,
    set_bounds = 30,
    set_visible = 31,
    set_tiled = 32,
    set_window_position = 33,
    touch_down = 34,
    touch_motion = 35,
    touch_up = 36,
    touch_frame = 37,
    touch_cancel = 38,
    _,
};

/// EVENT `op`: one `js_*` import of core/src/wasm.zig (plus `synced`).
pub const EventOp = enum(u16) {
    log = 1,
    set_title = 2,
    surface_event = 3,
    interactive = 4,
    cursor_shape = 5,
    cursor_surface = 6,
    text_input = 7,
    input_region = 8,
    pointer_lock = 9,
    selection = 10,
    selection_data = 11,
    keyboard_locks_state = 12,
    synced = 13,
    set_app_id = 14,
    size_limits = 15,
    decoration = 16,
    configure = 17,
    acked = 18,
    touch_bound = 19,
    _,
};

/// Write a CALL or EVENT frame (header + `args`) into `out`; returns it.
pub fn encodeOpFrame(out: []u8, frame_type: FrameType, op: u16, args: []const u8) []u8 {
    std.debug.assert(frame_type == .call or frame_type == .event);
    const total = op_frame_header_len + args.len;
    std.debug.assert(out.len >= total);
    out[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u16, out[1..3], op, .little);
    std.mem.writeInt(u32, out[3..7], @intCast(args.len), .little);
    @memcpy(out[op_frame_header_len..total], args);
    return out[0..total];
}

/// CALL / EVENT arguments, encoded: little-endian, unpadded; `bytes` is a
/// u32 length + the bytes. Appends to a caller-owned list.
pub const ArgWriter = struct {
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    pub fn u32_(self: ArgWriter, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.list.appendSlice(self.gpa, &b);
    }
    pub fn i32_(self: ArgWriter, v: i32) !void {
        return self.u32_(@bitCast(v));
    }
    pub fn f64_(self: ArgWriter, v: f64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, @bitCast(v), .little);
        try self.list.appendSlice(self.gpa, &b);
    }
    pub fn bytes(self: ArgWriter, v: []const u8) !void {
        try self.u32_(@intCast(v.len));
        try self.list.appendSlice(self.gpa, v);
    }
};

/// Decode CALL / EVENT arguments in order; a field past the end is
/// error.Truncated (bytes after the known fields are ignored).
pub const ArgReader = struct {
    rest: []const u8,

    pub fn u32_(self: *ArgReader) error{Truncated}!u32 {
        if (self.rest.len < 4) return error.Truncated;
        defer self.rest = self.rest[4..];
        return std.mem.readInt(u32, self.rest[0..4], .little);
    }
    pub fn i32_(self: *ArgReader) error{Truncated}!i32 {
        return @bitCast(try self.u32_());
    }
    pub fn f64_(self: *ArgReader) error{Truncated}!f64 {
        if (self.rest.len < 8) return error.Truncated;
        defer self.rest = self.rest[8..];
        return @bitCast(std.mem.readInt(u64, self.rest[0..8], .little));
    }
    pub fn bytes(self: *ArgReader) error{Truncated}![]const u8 {
        const n = try self.u32_();
        if (self.rest.len < n) return error.Truncated;
        defer self.rest = self.rest[n..];
        return self.rest[0..n];
    }
};

/// 0x11 SURFACE: what the synchronous `wland_surface_*` getters of
/// core/src/wasm.zig answer for one surface, as of when it was sent.
pub const SurfaceFrame = struct {
    conn_id: u32,
    surface_id: u32,
    role: u32,
    scale: i32,
    view_w: i32,
    view_h: i32,
    toplevel_state: u32,
    root: u32,
    parent: u32,
    abs_x: i32,
    abs_y: i32,
    z: i32,
    geom_x: i32,
    geom_y: i32,
    geom_w: i32,
    geom_h: i32,

    /// type + 16 four-byte fields
    pub const len = 65;

    pub fn encode(self: SurfaceFrame, out: *[len]u8) void {
        out[0] = @intFromEnum(FrameType.surface);
        const words = [16]u32{
            self.conn_id,         self.surface_id,      self.role,           @bitCast(self.scale),
            @bitCast(self.view_w), @bitCast(self.view_h), self.toplevel_state, self.root,
            self.parent,          @bitCast(self.abs_x), @bitCast(self.abs_y), @bitCast(self.z),
            @bitCast(self.geom_x), @bitCast(self.geom_y), @bitCast(self.geom_w), @bitCast(self.geom_h),
        };
        for (words, 0..) |w, i| std.mem.writeInt(u32, out[1 + i * 4 ..][0..4], w, .little);
    }

    pub fn decode(b: *const [len]u8) SurfaceFrame {
        var w: [16]u32 = undefined;
        for (&w, 0..) |*x, i| x.* = std.mem.readInt(u32, b[1 + i * 4 ..][0..4], .little);
        return .{
            .conn_id = w[0],
            .surface_id = w[1],
            .role = w[2],
            .scale = @bitCast(w[3]),
            .view_w = @bitCast(w[4]),
            .view_h = @bitCast(w[5]),
            .toplevel_state = w[6],
            .root = w[7],
            .parent = w[8],
            .abs_x = @bitCast(w[9]),
            .abs_y = @bitCast(w[10]),
            .z = @bitCast(w[11]),
            .geom_x = @bitCast(w[12]),
            .geom_y = @bitCast(w[13]),
            .geom_w = @bitCast(w[14]),
            .geom_h = @bitCast(w[15]),
        };
    }
};

/// FEATURE fixed part: type, feature, len.
pub const feature_header_len = 9;

/// Write a FEATURE frame (header + `bytes`) into `out`; returns it.
pub fn encodeFeature(out: []u8, feature: FeatureKind, bytes: []const u8) []u8 {
    const total = feature_header_len + bytes.len;
    std.debug.assert(out.len >= total);
    out[0] = @intFromEnum(FrameType.feature);
    std.mem.writeInt(u32, out[1..5], @intFromEnum(feature), .little);
    std.mem.writeInt(u32, out[5..9], @intCast(bytes.len), .little);
    @memcpy(out[feature_header_len..total], bytes);
    return out[0..total];
}

pub const dmabuf_created_len = 13;

pub fn writeDmabufCreated(buf: *[dmabuf_created_len]u8, conn_id: u32, params_id: u32, buffer_id: u32) void {
    buf[0] = @intFromEnum(FrameType.dmabuf_created);
    std.mem.writeInt(u32, buf[1..5], conn_id, .little);
    std.mem.writeInt(u32, buf[5..9], params_id, .little);
    std.mem.writeInt(u32, buf[9..13], buffer_id, .little);
}

/// PRESENTED fixed part: type, conn_id, age_us, byte_len.
pub const presented_header_len = 13;

/// Write a PRESENTED frame (header + the presented event `msg`) into `out`;
/// returns it.
pub fn encodePresented(out: []u8, conn_id: u32, age_us: u32, msg: []const u8) []u8 {
    const total = presented_header_len + msg.len;
    std.debug.assert(out.len >= total);
    out[0] = @intFromEnum(FrameType.presented);
    std.mem.writeInt(u32, out[1..5], conn_id, .little);
    std.mem.writeInt(u32, out[5..9], age_us, .little);
    std.mem.writeInt(u32, out[9..13], @intCast(msg.len), .little);
    @memcpy(out[presented_header_len..total], msg);
    return out[0..total];
}

/// The relay's half of PRESENTED: write a presentation timestamp, `ns` on
/// the clock wp_presentation.clock_id names, into the event's first three
/// args (tv_sec_hi, tv_sec_lo, tv_nsec, right after the 8-byte header).
/// The frame says nothing else about the event, so anything shorter than
/// those 20 bytes is refused.
pub fn stampPresented(msg: []u8, ns: u64) error{BadLength}!void {
    if (msg.len < 20) return error.BadLength;
    const sec = ns / std.time.ns_per_s;
    std.mem.writeInt(u32, msg[8..12], @truncate(sec >> 32), .little);
    std.mem.writeInt(u32, msg[12..16], @truncate(sec), .little);
    std.mem.writeInt(u32, msg[16..20], @intCast(ns % std.time.ns_per_s), .little);
}

pub const srvobj_len = 13;

/// Write a SRVOBJ frame into `buf[0..13]`.
pub fn writeSrvObj(buf: *[srvobj_len]u8, conn_id: u32, object_id: u32, kind: u32) void {
    buf[0] = @intFromEnum(FrameType.srvobj);
    std.mem.writeInt(u32, buf[1..5], conn_id, .little);
    std.mem.writeInt(u32, buf[5..9], object_id, .little);
    std.mem.writeInt(u32, buf[9..13], kind, .little);
}

/// Parse exactly one frame occupying all of `bytes` (tests + single-frame paths).
pub fn parse(bytes: []const u8) ParseError!Frame {
    const p = try parseNext(bytes);
    if (p.consumed != bytes.len) return error.BadLength;
    return p.frame;
}

pub const buffer_header_len = 21;

/// Write a BUFFER frame header (everything before rects) into buf[0..21].
pub fn writeBufferHeader(buf: *[buffer_header_len]u8, f: struct {
    conn_id: u32,
    surface_id: u32,
    width: u32,
    height: u32,
    n_rects: u32,
}) void {
    buf[0] = @intFromEnum(FrameType.buffer);
    std.mem.writeInt(u32, buf[1..5], f.conn_id, .little);
    std.mem.writeInt(u32, buf[5..9], f.surface_id, .little);
    std.mem.writeInt(u32, buf[9..13], f.width, .little);
    std.mem.writeInt(u32, buf[13..17], f.height, .little);
    std.mem.writeInt(u32, buf[17..21], f.n_rects, .little);
}

/// BUFFER_LZ fixed metadata after the rects: u32 raw_len + u32 comp_len.
pub const buffer_lz_meta_len = 8;

pub fn writeRect(buf: *[16]u8, x: i32, y: i32, w: i32, h: i32) void {
    std.mem.writeInt(i32, buf[0..4], x, .little);
    std.mem.writeInt(i32, buf[4..8], y, .little);
    std.mem.writeInt(i32, buf[8..12], w, .little);
    std.mem.writeInt(i32, buf[12..16], h, .little);
}

/// Write an FDMSG frame (fixed part + wire bytes + aux) into `out`; returns written slice.
pub fn encodeFdMsg(out: []u8, conn_id: u32, kind: FdMsgKind, wire_bytes: []const u8, aux: []const u8) []u8 {
    const total = 13 + wire_bytes.len + 4 + aux.len;
    std.debug.assert(out.len >= total);
    out[0] = @intFromEnum(FrameType.fdmsg);
    std.mem.writeInt(u32, out[1..5], conn_id, .little);
    std.mem.writeInt(u32, out[5..9], @intFromEnum(kind), .little);
    std.mem.writeInt(u32, out[9..13], @intCast(wire_bytes.len), .little);
    @memcpy(out[13..][0..wire_bytes.len], wire_bytes);
    std.mem.writeInt(u32, out[13 + wire_bytes.len ..][0..4], @intCast(aux.len), .little);
    @memcpy(out[13 + wire_bytes.len + 4 ..][0..aux.len], aux);
    return out[0..total];
}

pub const wire_overhead = 9;

/// Write a WIRE frame header for `byte_len` wire bytes into `buf[0..9]`.
pub fn writeWireHeader(buf: *[wire_overhead]u8, conn_id: u32, byte_len: u32) void {
    buf[0] = @intFromEnum(FrameType.wire);
    std.mem.writeInt(u32, buf[1..5], conn_id, .little);
    std.mem.writeInt(u32, buf[5..9], byte_len, .little);
}

pub fn encodeConnFrame(frame_type: FrameType, conn_id: u32) [5]u8 {
    var out: [5]u8 = undefined;
    out[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, out[1..5], conn_id, .little);
    return out;
}

/// HANDLE_OPEN fixed part: type, conn_id, handle_id, kind, len.
pub const handle_open_header_len = 17;

pub fn handleOpenLen(bytes_len: usize) usize {
    return handle_open_header_len + bytes_len;
}

/// Write a HANDLE_OPEN frame into `out` (≥ handleOpenLen); returns it.
pub fn encodeHandleOpen(out: []u8, conn_id: u32, handle_id: u32, kind: HandleKind, bytes: []const u8) []u8 {
    const total = handleOpenLen(bytes.len);
    std.debug.assert(out.len >= total);
    out[0] = @intFromEnum(FrameType.handle_open);
    std.mem.writeInt(u32, out[1..5], conn_id, .little);
    std.mem.writeInt(u32, out[5..9], handle_id, .little);
    std.mem.writeInt(u32, out[9..13], @intFromEnum(kind), .little);
    std.mem.writeInt(u32, out[13..17], @intCast(bytes.len), .little);
    @memcpy(out[handle_open_header_len..total], bytes);
    return out[0..total];
}

pub const handle_close_len = 9;

pub fn writeHandleClose(buf: *[handle_close_len]u8, conn_id: u32, handle_id: u32) void {
    buf[0] = @intFromEnum(FrameType.handle_close);
    std.mem.writeInt(u32, buf[1..5], conn_id, .little);
    std.mem.writeInt(u32, buf[5..9], handle_id, .little);
}

/// COMMIT fixed part: type, conn_id, surface_id, serial, n_rects, kind, ref_len.
pub const commit_header_len = 25;

/// Write a COMMIT header (everything before the ref) into buf[0..25]. The
/// caller appends `ref_len` ref bytes, then n_rects × writeRect.
pub fn writeCommitHeader(buf: *[commit_header_len]u8, h: struct {
    conn_id: u32,
    surface_id: u32,
    serial: u32,
    n_rects: u32,
    kind: u32,
    ref_len: u32,
}) void {
    buf[0] = @intFromEnum(FrameType.commit);
    std.mem.writeInt(u32, buf[1..5], h.conn_id, .little);
    std.mem.writeInt(u32, buf[5..9], h.surface_id, .little);
    std.mem.writeInt(u32, buf[9..13], h.serial, .little);
    std.mem.writeInt(u32, buf[13..17], h.n_rects, .little);
    std.mem.writeInt(u32, buf[17..21], h.kind, .little);
    std.mem.writeInt(u32, buf[21..25], h.ref_len, .little);
}

pub fn shmCommitLen(n_rects: usize) usize {
    return commit_header_len + ShmRef.len + n_rects * 16;
}

/// Write a kind-shm COMMIT into `out` (≥ shmCommitLen); returns it. `rects`
/// is a slice of any struct with i32 x, y, w, h (stream.Rect, shm.Rect).
pub fn encodeShmCommit(out: []u8, conn_id: u32, surface_id: u32, serial: u32, ref: ShmRef, rects: anytype) []u8 {
    var ref_bytes: [ShmRef.len]u8 = undefined;
    ref.encode(&ref_bytes);
    return encodeCommit(out, conn_id, surface_id, serial, .shm, &ref_bytes, rects);
}

pub fn virtgpuCommitLen(n_rects: usize) usize {
    return commit_header_len + VirtgpuRef.len + n_rects * 16;
}

/// Write a kind-virtgpu COMMIT into `out` (≥ virtgpuCommitLen); returns it.
pub fn encodeVirtgpuCommit(out: []u8, conn_id: u32, surface_id: u32, serial: u32, ref: VirtgpuRef, rects: anytype) []u8 {
    var ref_bytes: [VirtgpuRef.len]u8 = undefined;
    ref.encode(&ref_bytes);
    return encodeCommit(out, conn_id, surface_id, serial, .virtgpu, &ref_bytes, rects);
}

fn encodeCommit(out: []u8, conn_id: u32, surface_id: u32, serial: u32, kind: BufferKind, ref: []const u8, rects: anytype) []u8 {
    const total = commit_header_len + ref.len + rects.len * 16;
    std.debug.assert(out.len >= total);
    writeCommitHeader(out[0..commit_header_len], .{
        .conn_id = conn_id,
        .surface_id = surface_id,
        .serial = serial,
        .n_rects = @intCast(rects.len),
        .kind = @intFromEnum(kind),
        .ref_len = @intCast(ref.len),
    });
    @memcpy(out[commit_header_len..][0..ref.len], ref);
    const rects_off = commit_header_len + ref.len;
    for (rects, 0..) |r, i| writeRect(out[rects_off + i * 16 ..][0..16], r.x, r.y, r.w, r.h);
    return out[0..total];
}

pub const ack_len = 9;

pub fn writeAck(buf: *[ack_len]u8, conn_id: u32, serial: u32) void {
    buf[0] = @intFromEnum(FrameType.ack);
    std.mem.writeInt(u32, buf[1..5], conn_id, .little);
    std.mem.writeInt(u32, buf[5..9], serial, .little);
}

/// Outgoing frames accumulated for ONE batched send (STREAM.md: senders
/// batch, receivers loop). Consecutive WIRE bytes for the same conn coalesce
/// into a single WIRE frame; any other frame closes the open run first, so
/// frame order always equals call order.
pub const Batch = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// The open WIRE frame, if any: its conn and the offset of its header in
    /// `bytes` (byte_len is patched when the run closes).
    wire_run: ?struct { conn_id: u32, off: usize } = null,

    pub fn deinit(self: *Batch, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    /// Append whole wayland messages for `conn_id` (joins the open run if
    /// it is for the same conn).
    pub fn wire(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, msgs: []const u8) !void {
        if (self.wire_run) |run| {
            if (run.conn_id != conn_id) self.closeWireRun();
        }
        if (self.wire_run == null) {
            var header: [wire_overhead]u8 = undefined;
            writeWireHeader(&header, conn_id, 0); // byte_len patched at close
            try self.bytes.appendSlice(gpa, &header);
            self.wire_run = .{ .conn_id = conn_id, .off = self.bytes.items.len - wire_overhead };
        }
        try self.bytes.appendSlice(gpa, msgs);
    }

    /// Reserve `len` bytes for a non-WIRE frame the caller writes in place.
    /// The slice is valid until the next append.
    pub fn frame(self: *Batch, gpa: std.mem.Allocator, len: usize) ![]u8 {
        self.closeWireRun();
        const start = self.bytes.items.len;
        try self.bytes.resize(gpa, start + len);
        return self.bytes.items[start..];
    }

    pub fn fdMsg(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, kind: FdMsgKind, wire_bytes: []const u8, aux: []const u8) !void {
        const out = try self.frame(gpa, 13 + wire_bytes.len + 4 + aux.len);
        _ = encodeFdMsg(out, conn_id, kind, wire_bytes, aux);
    }

    pub fn handleOpen(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, handle_id: u32, kind: HandleKind, bytes: []const u8) !void {
        _ = encodeHandleOpen(try self.frame(gpa, handleOpenLen(bytes.len)), conn_id, handle_id, kind, bytes);
    }

    pub fn handleClose(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, handle_id: u32) !void {
        writeHandleClose((try self.frame(gpa, handle_close_len))[0..handle_close_len], conn_id, handle_id);
    }

    pub fn shmCommit(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, surface_id: u32, serial: u32, ref: ShmRef, rects: anytype) !void {
        _ = encodeShmCommit(try self.frame(gpa, shmCommitLen(rects.len)), conn_id, surface_id, serial, ref, rects);
    }

    pub fn virtgpuCommit(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, surface_id: u32, serial: u32, ref: VirtgpuRef, rects: anytype) !void {
        _ = encodeVirtgpuCommit(try self.frame(gpa, virtgpuCommitLen(rects.len)), conn_id, surface_id, serial, ref, rects);
    }

    pub fn ack(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, serial: u32) !void {
        writeAck((try self.frame(gpa, ack_len))[0..ack_len], conn_id, serial);
    }

    pub fn presented(self: *Batch, gpa: std.mem.Allocator, conn_id: u32, age_us: u32, msg: []const u8) !void {
        _ = encodePresented(try self.frame(gpa, presented_header_len + msg.len), conn_id, age_us, msg);
    }

    /// A CALL or EVENT frame with already-encoded `args` (ArgWriter).
    pub fn opFrame(self: *Batch, gpa: std.mem.Allocator, frame_type: FrameType, op: u16, args: []const u8) !void {
        _ = encodeOpFrame(try self.frame(gpa, op_frame_header_len + args.len), frame_type, op, args);
    }

    pub fn surface(self: *Batch, gpa: std.mem.Allocator, f: SurfaceFrame) !void {
        f.encode((try self.frame(gpa, SurfaceFrame.len))[0..SurfaceFrame.len]);
    }

    /// Close any open WIRE run and return everything batched so far.
    pub fn finish(self: *Batch) []const u8 {
        self.closeWireRun();
        return self.bytes.items;
    }

    pub fn clear(self: *Batch) void {
        self.bytes.clearRetainingCapacity();
        self.wire_run = null;
    }

    fn closeWireRun(self: *Batch) void {
        const run = self.wire_run orelse return;
        self.wire_run = null;
        const byte_len: u32 = @intCast(self.bytes.items.len - run.off - wire_overhead);
        std.mem.writeInt(u32, self.bytes.items[run.off + 5 ..][0..4], byte_len, .little);
    }
};

/// Stream transport (STREAM.md "Stream transport"): on a byte-stream link
/// every message (what one WS message carries: one or more whole frames) is
/// prefixed with its u32 LE byte length.
pub const record_header_len = 4;

/// Upper bound a receiver enforces on one record — far above any real
/// message (a full 4K BUFFER is ~33 MiB raw), low enough that a desynced
/// stream fails fast instead of allocating gigabytes.
pub const max_record_len: u32 = 256 * 1024 * 1024;

pub fn writeRecordHeader(buf: *[record_header_len]u8, len: u32) void {
    std.mem.writeInt(u32, buf, len, .little);
}

pub fn readRecordHeader(buf: *const [record_header_len]u8) error{BadLength}!u32 {
    const len = std.mem.readInt(u32, buf, .little);
    if (len == 0 or len > max_record_len) return error.BadLength;
    return len;
}

test "wire frame roundtrip" {
    var buf: [32]u8 = undefined;
    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    writeWireHeader(buf[0..wire_overhead], 42, payload.len);
    @memcpy(buf[wire_overhead..][0..payload.len], &payload);
    const frame = try parse(buf[0 .. wire_overhead + payload.len]);
    try std.testing.expectEqual(@as(u32, 42), frame.wire.conn_id);
    try std.testing.expectEqualSlices(u8, &payload, frame.wire.bytes);
}

test "conn frames" {
    const open = encodeConnFrame(.conn_open, 7);
    try std.testing.expectEqual(@as(u32, 7), (try parse(&open)).conn_open);
    const close = encodeConnFrame(.conn_close, 7);
    try std.testing.expectEqual(@as(u32, 7), (try parse(&close)).conn_close);
}

test "buffer frame roundtrip" {
    var buf: [128]u8 = undefined;
    writeBufferHeader(buf[0..buffer_header_len], .{
        .conn_id = 1,
        .surface_id = 2,
        .width = 2,
        .height = 1,
        .n_rects = 1,
    });
    writeRect(buf[buffer_header_len..][0..16], 0, 0, 2, 1);
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    @memcpy(buf[buffer_header_len + 16 ..][0..8], &pixels);
    const f = (try parse(buf[0 .. buffer_header_len + 16 + 8])).buffer;
    try std.testing.expectEqual(@as(u32, 2), f.width);
    try std.testing.expectEqual(@as(u32, 1), f.n_rects);
    try std.testing.expectEqual(@as(i32, 2), f.rectAt(0).w);
    try std.testing.expectEqualSlices(u8, &pixels, f.pixels);
}

test "buffer frame multi-rect and zero-rect" {
    var buf: [128]u8 = undefined;
    const head = .{
        .conn_id = 1,
        .surface_id = 2,
        .width = 4,
        .height = 4,
    };

    // two rects: 1×1 at (0,0) and 2×1 at (1,2); pixels concatenated in order
    writeBufferHeader(buf[0..buffer_header_len], .{
        .conn_id = head.conn_id,
        .surface_id = head.surface_id,
        .width = head.width,
        .height = head.height,
        .n_rects = 2,
    });
    writeRect(buf[buffer_header_len..][0..16], 0, 0, 1, 1);
    writeRect(buf[buffer_header_len + 16 ..][0..16], 1, 2, 2, 1);
    const pixels = [_]u8{0xaa} ** (4 + 8);
    @memcpy(buf[buffer_header_len + 32 ..][0..pixels.len], &pixels);
    const f = (try parse(buf[0 .. buffer_header_len + 32 + pixels.len])).buffer;
    try std.testing.expectEqual(@as(u32, 2), f.n_rects);
    try std.testing.expectEqual(@as(i32, 1), f.rectAt(1).x);
    try std.testing.expectEqual(@as(i32, 2), f.rectAt(1).y);
    try std.testing.expectEqual(@as(usize, 12), f.pixels.len);

    // zero rects parse fine (the server never sends them anymore, but the
    // decoder shouldn't choke on an empty frame)
    writeBufferHeader(buf[0..buffer_header_len], .{
        .conn_id = head.conn_id,
        .surface_id = head.surface_id,
        .width = head.width,
        .height = head.height,
        .n_rects = 0,
    });
    const z = (try parse(buf[0..buffer_header_len])).buffer;
    try std.testing.expectEqual(@as(u32, 0), z.n_rects);
    try std.testing.expectEqual(@as(usize, 0), z.pixels.len);
}

test "buffer_lz frame roundtrip" {
    var buf: [128]u8 = undefined;
    // BUFFER_LZ's header is BUFFER's with another type byte
    writeBufferHeader(buf[0..buffer_header_len], .{
        .conn_id = 3,
        .surface_id = 4,
        .width = 8,
        .height = 8,
        .n_rects = 1,
    });
    buf[0] = @intFromEnum(FrameType.buffer_lz);
    writeRect(buf[buffer_header_len..][0..16], 0, 0, 8, 8);
    const comp = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const raw_len: u32 = 8 * 8 * 4;
    std.mem.writeInt(u32, buf[buffer_header_len + 16 ..][0..4], raw_len, .little);
    std.mem.writeInt(u32, buf[buffer_header_len + 20 ..][0..4], comp.len, .little);
    @memcpy(buf[buffer_header_len + 24 ..][0..comp.len], &comp);
    const total = buffer_header_len + 16 + 8 + comp.len;
    const f = (try parse(buf[0..total])).buffer_lz;
    try std.testing.expectEqual(@as(u32, 3), f.conn_id);
    try std.testing.expectEqual(@as(u32, 1), f.n_rects);
    try std.testing.expectEqual(@as(i32, 8), f.rectAt(0).w);
    try std.testing.expectEqual(raw_len, f.raw_len);
    try std.testing.expectEqualSlices(u8, &comp, f.comp);
}

test "fdmsg roundtrip" {
    var out: [64]u8 = undefined;
    const wire_bytes = [_]u8{ 3, 0, 0, 0, 0, 0, 16, 0 };
    const framed = encodeFdMsg(&out, 9, .shm_pool, &wire_bytes, &.{});
    const f = (try parse(framed)).fdmsg;
    try std.testing.expectEqual(@as(u32, 9), f.conn_id);
    try std.testing.expectEqual(@as(u32, 1), f.kind);
    try std.testing.expectEqualSlices(u8, &wire_bytes, f.wire_bytes);
    try std.testing.expectEqual(@as(usize, 0), f.aux.len);
}

test "srvobj roundtrip" {
    var buf: [srvobj_len]u8 = undefined;
    writeSrvObj(&buf, 3, 0xff000004, @intFromEnum(SrvObjKind.primary_offer));
    const f = (try parse(&buf)).srvobj;
    try std.testing.expectEqual(@as(u32, 3), f.conn_id);
    try std.testing.expectEqual(@as(u32, 0xff000004), f.object_id);
    try std.testing.expectEqual(@as(u32, 1), f.kind);
}

test "feature and dmabuf_created roundtrip, truncation" {
    var table: [2 * DmabufFeature.entry_len]u8 = undefined;
    writeFormatEntry(table[0..16], 0x34325241, 0);
    writeFormatEntry(table[16..32], 0x34325258, 0);
    const feat: DmabufFeature = .{ .main_device = 0xe280, .table = &table };
    var bytes: [8 + table.len]u8 = undefined;
    feat.encode(&bytes);
    var out: [64]u8 = undefined;
    const framed = encodeFeature(&out, .linux_dmabuf, &bytes);
    try expectPrefixesTruncated(framed);
    const f = (try parse(framed)).feature;
    try std.testing.expectEqual(@as(u32, 1), f.feature);
    const d = try DmabufFeature.decode(f.bytes);
    try std.testing.expectEqual(@as(u64, 0xe280), d.main_device);
    try std.testing.expectEqual(@as(usize, 2), d.count());
    try std.testing.expectEqual(@as(u32, 0x34325258), d.entry(1).format);
    try std.testing.expectEqual(@as(u64, 0), d.entry(1).modifier);
    // a table must hold whole entries, at least one
    try std.testing.expectError(error.BadLength, DmabufFeature.decode(bytes[0..8]));
    try std.testing.expectError(error.BadLength, DmabufFeature.decode(bytes[0..20]));

    // dmabuf_kind: a u32 buffer kind; appended bytes are ignored
    var kb: [DmabufKindFeature.len + 4]u8 = @splat(0xee);
    (DmabufKindFeature{ .buffer_kind = @intFromEnum(BufferKind.virtgpu) }).encode(kb[0..4]);
    const kf = (try parse(encodeFeature(&out, .dmabuf_kind, &kb))).feature;
    try std.testing.expectEqual(@as(u32, 2), kf.feature);
    try std.testing.expectEqual(@as(u32, 2), (try DmabufKindFeature.decode(kf.bytes)).buffer_kind);
    try std.testing.expectError(error.BadLength, DmabufKindFeature.decode(kb[0..3]));

    var c: [dmabuf_created_len]u8 = undefined;
    writeDmabufCreated(&c, 4, 9, 0xff000002);
    try expectPrefixesTruncated(&c);
    const dc = (try parse(&c)).dmabuf_created;
    try std.testing.expectEqual(@as(u32, 4), dc.conn_id);
    try std.testing.expectEqual(@as(u32, 9), dc.params_id);
    try std.testing.expectEqual(@as(u32, 0xff000002), dc.buffer_id);
}

test "presented roundtrip, truncation, stamping" {
    var ev: [36]u8 = undefined;
    _ = @import("wire.zig").encodeMessage(&ev, 9, 1, &.{
        .{ .uint = 0 }, .{ .uint = 1 }, .{ .uint = 2 }, .{ .uint = 16666666 }, .{ .uint = 0 }, .{ .uint = 0 }, .{ .uint = 1 },
    });
    var out: [presented_header_len + ev.len]u8 = undefined;
    const framed = encodePresented(&out, 3, 1500, &ev);
    try expectPrefixesTruncated(framed);
    const p = (try parse(framed)).presented;
    try std.testing.expectEqual(@as(u32, 3), p.conn_id);
    try std.testing.expectEqual(@as(u32, 1500), p.age_us);
    try std.testing.expectEqualSlices(u8, &ev, p.bytes);

    // 2^32 + 5 s and 7 ns: the seconds' high word too; the rest untouched
    try stampPresented(&ev, ((@as(u64, 1) << 32) + 5) * std.time.ns_per_s + 7);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ev[8..12], .little));
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, ev[12..16], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, ev[16..20], .little));
    try std.testing.expectEqual(@as(u32, 16666666), std.mem.readInt(u32, ev[20..24], .little));
    try std.testing.expectError(error.BadLength, stampPresented(ev[0..19], 0));

    // a huge byte_len doesn't wrap
    var h: [presented_header_len]u8 = undefined;
    _ = encodePresented(&h, 1, 0, &.{});
    std.mem.writeInt(u32, h[9..13], 0xffff_fffc, .little);
    try std.testing.expectError(error.Truncated, parse(&h));
}

test "parse rejects garbage" {
    try std.testing.expectError(error.Truncated, parse(&.{}));
    try std.testing.expectError(error.UnknownType, parse(&.{0x77}));
    try std.testing.expectError(error.Truncated, parse(&.{ 0x01, 1, 0, 0, 0, 9, 0, 0, 0, 1 }));
    // trailing garbage after a whole frame
    try std.testing.expectError(error.BadLength, parse(&.{ 0x03, 1, 0, 0, 0, 0xaa }));
}

/// Every strict prefix of a whole frame is Truncated (never a misparse).
fn expectPrefixesTruncated(frame: []const u8) !void {
    for (0..frame.len) |n| try std.testing.expectError(error.Truncated, parseNext(frame[0..n]));
}

test "handle_open roundtrip: kwshm and procfd bytes, truncation" {
    var buf: [64]u8 = undefined;
    var kw: [KwshmHandle.len]u8 = undefined;
    (KwshmHandle{ .id = 77, .size = 3 * 4096 + 12 }).encode(&kw);
    const f1 = encodeHandleOpen(&buf, 5, 9, .kwshm, &kw);
    try std.testing.expectEqual(handleOpenLen(KwshmHandle.len), f1.len);
    const h1 = (try parse(f1)).handle_open;
    try std.testing.expectEqual(@as(u32, 5), h1.conn_id);
    try std.testing.expectEqual(@as(u32, 9), h1.handle_id);
    try std.testing.expectEqual(@intFromEnum(HandleKind.kwshm), h1.kind);
    const k = try KwshmHandle.decode(h1.bytes);
    try std.testing.expectEqual(@as(u32, 77), k.id);
    try std.testing.expectEqual(@as(u64, 3 * 4096 + 12), k.size);
    try expectPrefixesTruncated(f1);

    var pf: [ProcfdHandle.len]u8 = undefined;
    (ProcfdHandle{ .pid = 4242, .fd = 17, .offset = 8192, .size = 1 << 33 }).encode(&pf);
    const h2 = (try parse(encodeHandleOpen(&buf, 5, 10, .procfd, &pf))).handle_open;
    const p = try ProcfdHandle.decode(h2.bytes);
    try std.testing.expectEqual(ProcfdHandle{ .pid = 4242, .fd = 17, .offset = 8192, .size = 1 << 33 }, p);

    // handle bytes of the wrong length for their kind
    try std.testing.expectError(error.BadLength, KwshmHandle.decode(&pf));
    try std.testing.expectError(error.BadLength, ProcfdHandle.decode(&kw));

    // an unknown kind still frames (the engine reports it, acks its notices)
    const f3 = encodeHandleOpen(&buf, 5, 11, .kwshm, &kw);
    std.mem.writeInt(u32, f3[9..13], 99, .little);
    try std.testing.expectEqual(@as(u32, 99), (try parse(f3)).handle_open.kind);
}

test "handle_close and ack roundtrip, truncation" {
    var hc: [handle_close_len]u8 = undefined;
    writeHandleClose(&hc, 3, 0xabcdef);
    const c = (try parse(&hc)).handle_close;
    try std.testing.expectEqual(@as(u32, 3), c.conn_id);
    try std.testing.expectEqual(@as(u32, 0xabcdef), c.handle_id);
    try expectPrefixesTruncated(&hc);

    var ak: [ack_len]u8 = undefined;
    writeAck(&ak, 3, 41);
    const a = (try parse(&ak)).ack;
    try std.testing.expectEqual(@as(u32, 3), a.conn_id);
    try std.testing.expectEqual(@as(u32, 41), a.serial);
    try expectPrefixesTruncated(&ak);
}

test "shm commit roundtrip and validation" {
    var buf: [128]u8 = undefined;
    const ref: ShmRef = .{ .handle_id = 4, .offset = 64, .width = 10, .height = 5, .stride = 48, .format = shm_format_xrgb8888 };
    const rects = [_]Rect{ .{ .x = 0, .y = 0, .w = 10, .h = 1 }, .{ .x = 9, .y = 4, .w = 1, .h = 1 } };
    const framed = encodeShmCommit(&buf, 2, 6, 17, ref, &rects);
    try std.testing.expectEqual(shmCommitLen(2), framed.len);
    const f = (try parse(framed)).commit;
    try std.testing.expectEqual(@as(u32, 2), f.conn_id);
    try std.testing.expectEqual(@as(u32, 6), f.surface_id);
    try std.testing.expectEqual(@as(u32, 17), f.serial);
    try std.testing.expectEqual(@as(u32, 2), f.n_rects);
    try std.testing.expectEqual(rects[1], f.rectAt(1));
    try std.testing.expectEqual(ref, try f.shm());
    try std.testing.expectEqual(@as(u64, 240), ref.span());
    try expectPrefixesTruncated(framed);

    // validation failures — each still frames, so the engine can ack it
    const Case = struct { ref: ShmRef, rects: []const Rect, err: CommitFrame.ShmError };
    var argb = ref;
    argb.format = shm_format_argb8888;
    try std.testing.expectEqual(argb, try (try parse(encodeShmCommit(&buf, 2, 6, 18, argb, &rects))).commit.shm());
    var bad_format = ref;
    bad_format.format = 0x34325258; // XR24 fourcc: never advertised
    var narrow = ref;
    narrow.stride = 39; // < width * 4
    var empty = ref;
    empty.height = 0;
    const cases = [_]Case{
        .{ .ref = bad_format, .rects = &rects, .err = error.BadFormat },
        .{ .ref = narrow, .rects = &rects, .err = error.BadGeometry },
        .{ .ref = empty, .rects = &rects, .err = error.BadGeometry },
        .{ .ref = ref, .rects = &.{}, .err = error.BadGeometry }, // no rects
        .{ .ref = ref, .rects = &.{.{ .x = 5, .y = 0, .w = 6, .h = 1 }}, .err = error.BadGeometry }, // past the right edge
        .{ .ref = ref, .rects = &.{.{ .x = 0, .y = -1, .w = 1, .h = 1 }}, .err = error.BadGeometry },
        .{ .ref = ref, .rects = &.{.{ .x = 0, .y = 0, .w = 0, .h = 1 }}, .err = error.BadGeometry },
    };
    for (cases) |cs| {
        const g = (try parse(encodeShmCommit(&buf, 2, 6, 19, cs.ref, cs.rects))).commit;
        try std.testing.expectEqual(@as(u32, 19), g.serial);
        try std.testing.expectError(cs.err, g.shm());
    }

    // an unknown buffer kind frames by ref_len; shm() refuses it
    var gpu: [commit_header_len + 8 + 16]u8 = undefined;
    writeCommitHeader(gpu[0..commit_header_len], .{ .conn_id = 2, .surface_id = 6, .serial = 20, .n_rects = 1, .kind = 7, .ref_len = 8 });
    @memset(gpu[commit_header_len..][0..8], 0xee);
    writeRect(gpu[commit_header_len + 8 ..][0..16], 0, 0, 1, 1);
    const u = (try parse(&gpu)).commit;
    try std.testing.expectEqual(@as(u32, 7), u.kind);
    try std.testing.expectEqual(@as(usize, 8), u.ref.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1, .h = 1 }, u.rectAt(0));
    try std.testing.expectError(error.BadKind, u.shm());
    // kind shm with a short ref
    writeCommitHeader(gpu[0..commit_header_len], .{ .conn_id = 2, .surface_id = 6, .serial = 21, .n_rects = 1, .kind = 1, .ref_len = 8 });
    try std.testing.expectError(error.BadLength, (try parse(&gpu)).commit.shm());
    // ...and kind virtgpu with one: virtgpu() refuses it
    writeCommitHeader(gpu[0..commit_header_len], .{ .conn_id = 2, .surface_id = 6, .serial = 22, .n_rects = 1, .kind = 2, .ref_len = 8 });
    try std.testing.expectError(error.BadLength, (try parse(&gpu)).commit.virtgpu());
}

fn testVirtgpuRef(ref: VirtgpuRef) [VirtgpuRef.len]u8 {
    var out: [VirtgpuRef.len]u8 = undefined;
    ref.encode(&out);
    return out;
}

test "virtgpu commit roundtrip, validation, a longer ref from a later relay" {
    const ref: VirtgpuRef = .{ .resource = 42, .width = 64, .height = 32, .format = 0x34325258, .flags = 1, .offset = 0, .stride = 256, .modifier = 0x00ff_ffff_ffff_ffff };
    const rects = [_]Rect{ .{ .x = 0, .y = 0, .w = 64, .h = 32 }, .{ .x = 3, .y = 4, .w = 5, .h = 6 } };
    var buf: [25 + 36 + 32]u8 = undefined;
    const f = encodeVirtgpuCommit(&buf, 3, 9, 11, ref, &rects);
    try std.testing.expectEqual(virtgpuCommitLen(2), f.len);
    const c = (try parse(f)).commit;
    try std.testing.expectEqual(@as(u32, 2), c.kind);
    try std.testing.expectEqual(ref, try c.virtgpu());
    try std.testing.expectError(error.BadKind, c.shm());
    try std.testing.expectEqual(rects[1], c.rectAt(1));

    // a rect past the edge, resource 0
    var bad = buf;
    writeRect(bad[25 + 36 + 16 ..][0..16], 60, 0, 5, 1);
    try std.testing.expectError(error.BadGeometry, (try parse(&bad)).commit.virtgpu());
    var zero = ref;
    zero.resource = 0;
    var zbuf: [25 + 36 + 16]u8 = undefined;
    try std.testing.expectError(error.BadGeometry, (try parse(encodeCommit(&zbuf, 3, 9, 12, .virtgpu, &testVirtgpuRef(zero), rects[0..1]))).commit.virtgpu());

    // ref_len 40: four bytes a later version appended; still decodes
    var long: [25 + 40 + 16]u8 = undefined;
    writeCommitHeader(long[0..25], .{ .conn_id = 3, .surface_id = 9, .serial = 13, .n_rects = 1, .kind = 2, .ref_len = 40 });
    long[25..][0..36].* = testVirtgpuRef(ref);
    @memset(long[61..65], 0xab);
    writeRect(long[65..81], 0, 0, 1, 1);
    try std.testing.expectEqual(ref, try (try parse(&long)).commit.virtgpu());
}

test "hostile lengths are Truncated, never wrapped" {
    // wire byte_len near u32 max (9 + len would wrap a 32-bit usize)
    try std.testing.expectError(error.Truncated, parse(&.{ 0x01, 1, 0, 0, 0, 0xfa, 0xff, 0xff, 0xff }));
    // commit with a huge ref_len, then a huge n_rects
    var c: [commit_header_len]u8 = undefined;
    writeCommitHeader(&c, .{ .conn_id = 1, .surface_id = 2, .serial = 3, .n_rects = 1, .kind = 1, .ref_len = 0xffff_fff0 });
    try std.testing.expectError(error.Truncated, parse(&c));
    writeCommitHeader(&c, .{ .conn_id = 1, .surface_id = 2, .serial = 3, .n_rects = 0x1000_0000, .kind = 1, .ref_len = 0 });
    try std.testing.expectError(error.Truncated, parse(&c));
    // handle_open with a huge len
    var h: [handle_open_header_len]u8 = undefined;
    _ = encodeHandleOpen(&h, 1, 1, .kwshm, &.{});
    std.mem.writeInt(u32, h[13..17], 0xffff_fffc, .little);
    try std.testing.expectError(error.Truncated, parse(&h));
    // fdmsg whose byte_len wraps
    try std.testing.expectError(error.Truncated, parse(&.{ 0x05, 1, 0, 0, 0, 1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff }));
    // feature with a huge len
    var fh: [feature_header_len]u8 = undefined;
    _ = encodeFeature(&fh, .linux_dmabuf, &.{});
    std.mem.writeInt(u32, fh[5..9], 0xffff_fffc, .little);
    try std.testing.expectError(error.Truncated, parse(&fh));
    // a call with a huge len
    try std.testing.expectError(error.Truncated, parse(&.{ 0x0f, 1, 0, 0xfc, 0xff, 0xff, 0xff }));
    // the type space ends at 0x11
    try std.testing.expectError(error.UnknownType, parse(&.{0x12}));
    try std.testing.expectError(error.UnknownType, parse(&.{0x00}));
}

test "session frames: call and event roundtrip with encoded args, unknown ops frame, truncation" {
    const gpa = std.testing.allocator;
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(gpa);
    const w: ArgWriter = .{ .list = &args, .gpa = gpa };
    try w.u32_(7);
    try w.i32_(-256);
    try w.f64_(1234.5);
    try w.bytes("héllo");
    var buf: [64]u8 = undefined;
    const call = encodeOpFrame(&buf, .call, @intFromEnum(CallOp.pointer_motion), args.items);
    try std.testing.expectEqual(op_frame_header_len + 4 + 4 + 8 + 4 + 6, call.len);
    const f = (try parse(call)).call;
    try std.testing.expectEqual(CallOp.pointer_motion, @as(CallOp, @enumFromInt(f.op)));
    var r: ArgReader = .{ .rest = f.args };
    try std.testing.expectEqual(@as(u32, 7), try r.u32_());
    try std.testing.expectEqual(@as(i32, -256), try r.i32_());
    try std.testing.expectEqual(@as(f64, 1234.5), try r.f64_());
    try std.testing.expectEqualStrings("héllo", try r.bytes());
    try std.testing.expectError(error.Truncated, r.u32_());
    try expectPrefixesTruncated(call);
    // a bytes field longer than what is left
    var short: ArgReader = .{ .rest = &.{ 9, 0, 0, 0, 1, 2 } };
    try std.testing.expectError(error.Truncated, short.bytes());

    // an event; an op nobody knows still frames (and is skipped)
    const ev = encodeOpFrame(&buf, .event, 999, &.{ 1, 2, 3 });
    const e = (try parse(ev)).event;
    try std.testing.expectEqual(@as(u16, 999), e.op);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, e.args);
    const synced = encodeOpFrame(&buf, .event, @intFromEnum(EventOp.synced), &.{});
    try std.testing.expectEqual(@as(usize, 7), synced.len);
    try std.testing.expectEqual(EventOp.synced, @as(EventOp, @enumFromInt((try parse(synced)).event.op)));
}

test "session frames: touch calls and touch_bound (ops 34–38, EVENT 19) roundtrip with their args" {
    const gpa = std.testing.allocator;
    // the numbers are the wire contract (STREAM.md tables)
    try std.testing.expectEqual(@as(u16, 34), @intFromEnum(CallOp.touch_down));
    try std.testing.expectEqual(@as(u16, 35), @intFromEnum(CallOp.touch_motion));
    try std.testing.expectEqual(@as(u16, 36), @intFromEnum(CallOp.touch_up));
    try std.testing.expectEqual(@as(u16, 37), @intFromEnum(CallOp.touch_frame));
    try std.testing.expectEqual(@as(u16, 38), @intFromEnum(CallOp.touch_cancel));
    try std.testing.expectEqual(@as(u16, 19), @intFromEnum(EventOp.touch_bound));
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(gpa);
    const w: ArgWriter = .{ .list = &args, .gpa = gpa };
    // touch_down: conn, time_ms, surface, id, x_fixed, y_fixed
    try w.u32_(3);
    try w.u32_(0xffff_fff0);
    try w.u32_(6);
    try w.i32_(-1);
    try w.i32_(-5 * 256);
    try w.i32_(900 * 256);
    var buf: [64]u8 = undefined;
    const call = encodeOpFrame(&buf, .call, @intFromEnum(CallOp.touch_down), args.items);
    try std.testing.expectEqual(op_frame_header_len + 24, call.len);
    const f = (try parse(call)).call;
    try std.testing.expectEqual(CallOp.touch_down, @as(CallOp, @enumFromInt(f.op)));
    var r: ArgReader = .{ .rest = f.args };
    try std.testing.expectEqual(@as(u32, 3), try r.u32_());
    try std.testing.expectEqual(@as(u32, 0xffff_fff0), try r.u32_());
    try std.testing.expectEqual(@as(u32, 6), try r.u32_());
    try std.testing.expectEqual(@as(i32, -1), try r.i32_());
    try std.testing.expectEqual(@as(i32, -5 * 256), try r.i32_());
    try std.testing.expectEqual(@as(i32, 900 * 256), try r.i32_());
    try expectPrefixesTruncated(call);

    const ev = encodeOpFrame(&buf, .event, @intFromEnum(EventOp.touch_bound), &.{ 3, 0, 0, 0, 1, 0, 0, 0 });
    const e = (try parse(ev)).event;
    try std.testing.expectEqual(EventOp.touch_bound, @as(EventOp, @enumFromInt(e.op)));
    var er: ArgReader = .{ .rest = e.args };
    try std.testing.expectEqual(@as(u32, 3), try er.u32_());
    try std.testing.expectEqual(@as(u32, 1), try er.u32_());
}

test "session frames: surface roundtrip (65 bytes), truncation, batch order" {
    const gpa = std.testing.allocator;
    const s: SurfaceFrame = .{
        .conn_id = 1, .surface_id = 6, .role = 1, .scale = 2, .view_w = 0, .view_h = -1,
        .toplevel_state = 5, .root = 6, .parent = 0, .abs_x = -25, .abs_y = 30, .z = -2,
        .geom_x = 10, .geom_y = 11, .geom_w = 800, .geom_h = 600,
    };
    var out: [SurfaceFrame.len]u8 = undefined;
    s.encode(&out);
    try std.testing.expectEqual(@as(u8, 0x11), out[0]);
    try std.testing.expectEqual(s, (try parse(&out)).surface);
    try expectPrefixesTruncated(&out);

    var b: Batch = .{};
    defer b.deinit(gpa);
    try b.wire(gpa, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try b.surface(gpa, s);
    try b.opFrame(gpa, .event, @intFromEnum(EventOp.surface_event), &.{ 1, 0, 0, 0, 6, 0, 0, 0, 1, 0, 0, 0 });
    try b.wire(gpa, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var types: [4]FrameType = undefined;
    var n: usize = 0;
    var rest = b.finish();
    while (rest.len > 0) : (n += 1) {
        const p = try parseNext(rest);
        types[n] = std.meta.activeTag(p.frame);
        rest = rest[p.consumed..];
    }
    try std.testing.expectEqualSlices(FrameType, &.{ .wire, .surface, .event, .wire }, types[0..n]);
}

test "batch v2 helpers keep frame order" {
    const gpa = std.testing.allocator;
    var b: Batch = .{};
    defer b.deinit(gpa);
    var kw: [KwshmHandle.len]u8 = undefined;
    (KwshmHandle{ .id = 1, .size = 4096 }).encode(&kw);
    try b.handleOpen(gpa, 1, 1, .kwshm, &kw);
    try b.wire(gpa, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }); // the commit's WIRE…
    const ref: ShmRef = .{ .handle_id = 1, .offset = 0, .width = 1, .height = 1, .stride = 4, .format = 0 };
    try b.shmCommit(gpa, 1, 3, 1, ref, &[_]Rect{.{ .x = 0, .y = 0, .w = 1, .h = 1 }}); // …then its notice
    try b.handleClose(gpa, 1, 1);
    try b.ack(gpa, 1, 1);

    var types: [5]FrameType = undefined;
    var n: usize = 0;
    var rest = b.finish();
    while (rest.len > 0) : (n += 1) {
        const p = try parseNext(rest);
        types[n] = std.meta.activeTag(p.frame);
        rest = rest[p.consumed..];
    }
    try std.testing.expectEqualSlices(FrameType, &.{ .handle_open, .wire, .commit, .handle_close, .ack }, types[0..n]);
}

test "batch coalesces same-conn wire and keeps frame order" {
    const gpa = std.testing.allocator;
    var b: Batch = .{};
    defer b.deinit(gpa);
    try b.wire(gpa, 1, &.{ 1, 2, 3, 4 });
    try b.wire(gpa, 1, &.{ 5, 6, 7, 8 }); // joins the run
    const open = try b.frame(gpa, 5);
    @memcpy(open, &encodeConnFrame(.conn_open, 2));
    try b.wire(gpa, 2, &.{9});
    try b.wire(gpa, 3, &.{10}); // conn change closes the run

    var types: [4]FrameType = undefined;
    var n: usize = 0;
    var rest = b.finish();
    while (rest.len > 0) : (n += 1) {
        const p = try parseNext(rest);
        types[n] = std.meta.activeTag(p.frame);
        if (n == 0) try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, p.frame.wire.bytes);
        if (n == 3) try std.testing.expectEqual(@as(u32, 3), p.frame.wire.conn_id);
        rest = rest[p.consumed..];
    }
    try std.testing.expectEqualSlices(FrameType, &.{ .wire, .conn_open, .wire, .wire }, types[0..n]);
    b.clear();
    try std.testing.expectEqual(@as(usize, 0), b.finish().len);
}

test "record header bounds" {
    var h: [record_header_len]u8 = undefined;
    writeRecordHeader(&h, 9);
    try std.testing.expectEqual(@as(u32, 9), try readRecordHeader(&h));
    writeRecordHeader(&h, 0);
    try std.testing.expectError(error.BadLength, readRecordHeader(&h));
    writeRecordHeader(&h, max_record_len + 1);
    try std.testing.expectError(error.BadLength, readRecordHeader(&h));
}

test "parseNext walks packed frames" {
    var buf: [64]u8 = undefined;
    // CONN_OPEN + WIRE(4 bytes) + CONN_CLOSE packed into one message
    const open = encodeConnFrame(.conn_open, 7);
    @memcpy(buf[0..5], &open);
    writeWireHeader(buf[5..][0..wire_overhead], 7, 4);
    @memcpy(buf[14..][0..4], &[_]u8{ 1, 2, 3, 4 });
    const close = encodeConnFrame(.conn_close, 7);
    @memcpy(buf[18..][0..5], &close);

    var off: usize = 0;
    const p1 = try parseNext(buf[off..23]);
    try std.testing.expectEqual(@as(u32, 7), p1.frame.conn_open);
    off += p1.consumed;
    const p2 = try parseNext(buf[off..23]);
    try std.testing.expectEqual(@as(usize, 4), p2.frame.wire.bytes.len);
    off += p2.consumed;
    const p3 = try parseNext(buf[off..23]);
    try std.testing.expectEqual(@as(u32, 7), p3.frame.conn_close);
    try std.testing.expectEqual(@as(usize, 23), off + p3.consumed);
}
