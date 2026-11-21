// Byte-level protocol helpers for the handle demo: the Wayland wire format
// (what the synthetic client writes and reads) and the STREAM v2 frames
// (protocol/STREAM.md — what the demo's relay sends the engine and reads
// back). Plain JS, no DOM; test/handles.test.ts builds its frames with it too.
// Everything is little-endian; Wayland messages are 4-byte aligned, STREAM
// frames are packed unaligned.

const te = new TextEncoder();
const td = new TextDecoder();

// --- Wayland wire ----------------------------------------------------------
// A message: u32 object id, u32 (size << 16 | opcode), then the args. Args
// here: a number = one 32-bit word (uint, int, object, new_id; fixed = v*256
// done by the caller), a string = a wl string, {array: Uint8Array} = a wl
// array. fd args never appear in the bytes (they travel out of band).

const pad4 = (n) => (n + 3) & ~3;

export function wlMessage(object, opcode, args = []) {
  let size = 8;
  const enc = args.map((a) => {
    if (typeof a === 'number') { size += 4; return a; }
    const bytes = typeof a === 'string' ? te.encode(a + '\0') : a.array;
    size += 4 + pad4(bytes.length);
    return bytes;
  });
  const out = new Uint8Array(size);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, object, true);
  dv.setUint32(4, (size << 16) | opcode, true);
  let off = 8;
  for (const a of enc) {
    if (typeof a === 'number') { dv.setUint32(off, a >>> 0, true); off += 4; continue; }
    dv.setUint32(off, a.length, true);
    out.set(a, off + 4);
    off += 4 + pad4(a.length);
  }
  return out;
}

/** Walk whole Wayland messages: fn(object, opcode, reader, messageBytes). */
export function wlEach(bytes, fn) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let off = 0;
  while (off + 8 <= bytes.length) {
    const object = dv.getUint32(off, true), word = dv.getUint32(off + 4, true);
    const size = word >>> 16;
    if (size < 8 || off + size > bytes.length) throw new Error(`bad wayland message at ${off}`);
    let at = off + 8;
    const r = {
      u32: () => { const v = dv.getUint32(at, true); at += 4; return v; },
      i32: () => { const v = dv.getInt32(at, true); at += 4; return v; },
      fixed: () => { const v = dv.getInt32(at, true) / 256; at += 4; return v; },
      str: () => {
        const n = dv.getUint32(at, true);
        const s = n ? td.decode(bytes.subarray(at + 4, at + 4 + n - 1)) : '';
        at += 4 + pad4(n);
        return s;
      },
      array: () => {
        const n = dv.getUint32(at, true);
        const a = bytes.slice(at + 4, at + 4 + n);
        at += 4 + pad4(n);
        return a;
      },
    };
    fn(object, word & 0xffff, r, bytes.subarray(off, off + size));
    off += size;
  }
}

// --- STREAM v2 frames (protocol/STREAM.md) ----------------------------------

export const T = {
  WIRE: 0x01, BUFFER: 0x02, CONN_OPEN: 0x03, CONN_CLOSE: 0x04, FDMSG: 0x05, SRVOBJ: 0x06,
  BUFFER_LZ: 0x07, HANDLE_OPEN: 0x08, HANDLE_CLOSE: 0x09, COMMIT: 0x0a, ACK: 0x0b,
  PRESENTED: 0x0e,
};
export const FD = { SHM_POOL: 1, KEYMAP: 2, PIPE: 3 };
export const HANDLE = { KWSHM: 1, PROCFD: 2 };
export const SHM = { ARGB8888: 0, XRGB8888: 1 };

// a frame from fields: numbers are u32 (i32 written as two's complement),
// {u64: n} a u64, Uint8Array raw bytes
function frame(type, ...fields) {
  let len = 1;
  for (const f of fields) len += typeof f === 'number' ? 4 : f instanceof Uint8Array ? f.length : 8;
  const out = new Uint8Array(len);
  const dv = new DataView(out.buffer);
  out[0] = type;
  let off = 1;
  for (const f of fields) {
    if (typeof f === 'number') { dv.setUint32(off, f >>> 0, true); off += 4; }
    else if (f instanceof Uint8Array) { out.set(f, off); off += f.length; }
    else { dv.setBigUint64(off, BigInt(f.u64), true); off += 8; }
  }
  return out;
}

export const wireFrame = (conn, bytes) => frame(T.WIRE, conn, bytes.length, bytes);
export const connOpen = (conn) => frame(T.CONN_OPEN, conn);
export const connClose = (conn) => frame(T.CONN_CLOSE, conn);
export const fdmsg = (conn, kind, wire, aux = new Uint8Array(0)) =>
  frame(T.FDMSG, conn, kind, wire.length, wire, aux.length, aux);
export const handleOpen = (conn, handle, kind, bytes) => frame(T.HANDLE_OPEN, conn, handle, kind, bytes.length, bytes);
export const kwshmBytes = (id, size) => frame(0, id, { u64: size }).subarray(1);
export const procfdBytes = (pid, fd, offset, size) => frame(0, pid, fd, { u64: offset }, { u64: size }).subarray(1);
export const handleClose = (conn, handle) => frame(T.HANDLE_CLOSE, conn, handle);
/** COMMIT with buffer kind 1 = shm. ref: {handle, offset, width, height,
 *  stride, format}; rects: [[x, y, w, h], ...] in buffer px. */
export function shmCommit(conn, surface, serial, ref, rects) {
  const r = frame(0, ref.handle, ref.offset, ref.width, ref.height, ref.stride, ref.format).subarray(1);
  return frame(T.COMMIT, conn, surface, serial, rects.length, 1, r.length, r, ...rects.flat());
}

/** COMMIT with buffer kind 2 = virtgpu. ref: {resource, width, height,
 *  format (DRM fourcc), flags, offset, stride, modifier (bigint)}. */
export function virtgpuCommit(conn, surface, serial, ref, rects) {
  const r = frame(0, ref.resource, ref.width, ref.height, ref.format, ref.flags ?? 0, ref.offset ?? 0, ref.stride ?? ref.width * 4,
    { u64: ref.modifier ?? 0x00ffffffffffffffn }).subarray(1);
  return frame(T.COMMIT, conn, surface, serial, rects.length, 2, r.length, r, ...rects.flat());
}

/** Concatenate frames into one link message (an ArrayBuffer). */
export function pack(frames) {
  let n = 0;
  for (const f of frames) n += f.length;
  const out = new Uint8Array(n);
  let off = 0;
  for (const f of frames) { out.set(f, off); off += f.length; }
  return out.buffer;
}

/** Decode the engine→relay frames of one link message: WIRE, CONN_CLOSE,
 *  FDMSG, SRVOBJ, ACK, PRESENTED (the engine sends nothing else). */
export function eachEngineFrame(bytes, fn) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const u32 = (at) => dv.getUint32(at, true);
  let off = 0;
  while (off < bytes.length) {
    const t = bytes[off];
    if (t === T.WIRE) {
      const n = u32(off + 5);
      fn({ type: 'wire', conn: u32(off + 1), bytes: bytes.subarray(off + 9, off + 9 + n) });
      off += 9 + n;
    } else if (t === T.CONN_CLOSE) {
      fn({ type: 'conn-close', conn: u32(off + 1) });
      off += 5;
    } else if (t === T.FDMSG) {
      const n = u32(off + 9), a = u32(off + 13 + n);
      fn({ type: 'fdmsg', conn: u32(off + 1), kind: u32(off + 5),
           wire: bytes.subarray(off + 13, off + 13 + n), aux: bytes.subarray(off + 17 + n, off + 17 + n + a) });
      off += 17 + n + a;
    } else if (t === T.SRVOBJ) {
      fn({ type: 'srvobj', conn: u32(off + 1), object: u32(off + 5), kind: u32(off + 9) });
      off += 13;
    } else if (t === T.ACK) {
      fn({ type: 'ack', conn: u32(off + 1), serial: u32(off + 5) });
      off += 9;
    } else if (t === T.PRESENTED) {
      const n = u32(off + 9);
      fn({ type: 'presented', conn: u32(off + 1), age: u32(off + 5), bytes: bytes.subarray(off + 13, off + 13 + n) });
      off += 13 + n;
    } else {
      throw new Error(`unexpected engine frame type ${t} at ${off}`);
    }
  }
}

/** A relay's half of PRESENTED (STREAM.md): write the presentation time
 *  into the presented event's tv_sec_hi/lo, tv_nsec, in place — `nowNs`
 *  (the relay's clock, a bigint) less `ageUs`. */
export function stampPresented(event, nowNs, ageUs) {
  const dv = new DataView(event.buffer, event.byteOffset, event.byteLength);
  let ns = nowNs - BigInt(ageUs) * 1000n;
  if (ns < 0n) ns = 0n;
  const sec = ns / 1000000000n;
  dv.setUint32(8, Number(sec >> 32n), true);
  dv.setUint32(12, Number(sec & 0xffffffffn), true);
  dv.setUint32(16, Number(ns % 1000000000n), true);
  return event;
}

/** CLOCK_MONOTONIC in ns where there is one (Node's hrtime is it on
 *  Linux), else the page's clock — what wlandr stamps PRESENTED with. */
export const monotonicNs = () =>
  globalThis.process?.hrtime?.bigint ? globalThis.process.hrtime.bigint() : BigInt(Math.round(performance.now() * 1e6));

/** Frames for one link message. Consecutive WIRE bytes of one conn coalesce
 *  into a single WIRE frame, as the relay batches (STREAM.md). */
export function createBatch() {
  let frames = [], wireConn = 0, wire = [];
  const closeWire = () => {
    if (!wire.length) return;
    let n = 0;
    for (const w of wire) n += w.length;
    const bytes = new Uint8Array(n);
    let off = 0;
    for (const w of wire) { bytes.set(w, off); off += w.length; }
    frames.push(wireFrame(wireConn, bytes));
    wire = [];
  };
  return {
    wire(conn, bytes) {
      if (wire.length && conn !== wireConn) closeWire();
      wireConn = conn;
      wire.push(bytes);
    },
    push(f) { closeWire(); frames.push(f); },
    /** The packed message, or null when empty; the batch starts over. */
    take() {
      closeWire();
      if (!frames.length) return null;
      const out = pack(frames);
      frames = [];
      return out;
    },
  };
}
