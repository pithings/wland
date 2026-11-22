// The remote core: what the engine talks to instead of the wasm core's
// compositor on a session link (protocol/STREAM.md "Profiles: passthrough
// and session"). There the compositor runs in the relay; the engine is a
// viewer. This object has the wasm exports' shape (CoreExports), so
// engine.ts swaps it in for them and the rest of the engine — commits,
// handles, motion coalescing, events — runs unchanged:
//
// - Stateless helpers stay the real wasm's: memory, wland_alloc/_free,
//   wland_swizzle, wland_decode_buffer, wland_commit_notice, wland_version.
// - A stateful call (input, output, window states, clipboard) is one CALL
//   frame (0x0f) sent to the relay. Text and bytes arguments are (ptr, len)
//   into wasm memory, as for the wasm export; they cross as `bytes`.
// - wland_on_frame parses the relay's frames: an EVENT (0x10) is the js_*
//   import of the same name called on the engine's handlers (byte payloads
//   are put in wasm memory for the call: the handlers read them there), a
//   SURFACE (0x11) updates the mirror the synchronous getters answer from,
//   CONN_CLOSE drops a conn's records and calls js_conn_close, HANDLE_OPEN
//   and HANDLE_CLOSE go to the real wasm (it decodes them without touching
//   compositor state).
// - The getters answer from the mirror; wland_surface_place and
//   wland_window_geometry write into a fixed region of wasm memory, as the
//   real ones do, so the engine reads them the same way.
// - No tick, no note_buffer_size: the relay does both itself.

/** A wasm export: every argument and result a wasm i32/u32 (or f64). */
export type CoreFn = (...args: number[]) => number;
/** The core's exports (core/src/wasm.zig): memory plus `wland_*`. */
export interface CoreExports {
  memory: WebAssembly.Memory;
  [name: `wland_${string}`]: CoreFn;
}
/** The core's imports: the engine's `js_*` handlers. */
export type CoreImports = { env: Record<`js_${string}`, (...args: number[]) => void> };

export interface RemoteCoreOptions {
  /** The instantiated wasm: its memory and stateless helpers are used. */
  real: CoreExports;
  /** The engine's js_* handlers, which EVENTs are delivered to. */
  env: CoreImports['env'];
  /** Send a CALL or ACK frame to the relay (an owned copy). */
  send(bytes: Uint8Array<ArrayBuffer>): void;
  /** The engine's frame length function (STREAM.md framing): byte length
   *  of the frame at `off`, or ≤ 0 when unknown or short. */
  frameLen(dv: DataView, off: number, total: number): number;
  /** EVENT synced: the scene replay that answered init is complete. */
  synced(): void;
  log(line: string): void;
  /** The keyboard lock state to report until the relay says (bit 0 Caps
   *  Lock, bit 1 NumLock). */
  locks: number;
}

/** STREAM.md frame types */
export const FRAME_CALL = 0x0f;
export const FRAME_EVENT = 0x10;
export const FRAME_SURFACE = 0x11;
/** SURFACE's fixed length: type + 16 × 4-byte fields. */
export const SURFACE_LEN = 65;

const FRAME_CONN_OPEN = 0x03, FRAME_CONN_CLOSE = 0x04, FRAME_HANDLE_OPEN = 0x08, FRAME_HANDLE_CLOSE = 0x09;
const FRAME_ACK = 0x0b, FRAME_FEATURE = 0x0c;
const SURFACE_DESTROYED = 0xffffffff;
const MAX_MIME = 256, MAX_MIMES = 32, MAX_SELECTION = 64 << 20; // core/src/compositor.zig's limits

// CALL ops whose arguments are numbers only: export → [op, argument kinds]
// (u u32, i i32, d f64), in the export's argument order
const CALLS: Record<string, readonly [number, string]> = {
  wland_init: [1, 'ii'],
  wland_set_gpu_source: [2, 'u'],
  wland_set_dpr: [3, 'ii'],
  wland_desktop_size: [4, 'ii'],
  wland_set_suspended: [5, 'u'],
  wland_pointer_enter: [6, 'uuii'],
  wland_pointer_leave: [7, 'u'],
  wland_pointer_motion: [8, 'uuiiiiiid'],
  wland_pointer_lock_granted: [9, 'uu'],
  wland_pointer_lock_lost: [10, 'u'],
  wland_pointer_button: [11, 'uuuu'],
  wland_pointer_axis: [12, 'uuuii'],
  wland_keyboard_enter: [13, 'uu'],
  wland_keyboard_leave: [14, 'u'],
  wland_key: [15, 'uuuu'],
  wland_keyboard_locks: [16, 'u'],
  wland_set_maximized: [19, 'uuu'],
  wland_set_fullscreen: [20, 'uuu'],
  wland_set_minimized: [21, 'uuu'],
  wland_popup_dismiss: [22, 'uu'],
  wland_request_resize: [23, 'uuii'],
  wland_drag_motion: [24, 'uuuii'],
  wland_drag_drop: [25, ''],
  wland_drag_cancel: [26, ''],
  wland_close: [29, 'uu'],
};
const OP_PREEDIT = 17, OP_COMMIT_STRING = 18, OP_SET_SELECTION = 27, OP_READ_SELECTION = 28;

/** A CALL (or EVENT) frame: `kinds` spells the arguments (u u32, i i32,
 *  d f64, b bytes = u32 len + bytes), little-endian, unpadded. Numbers
 *  wrap as a wasm call's would (ToInt32). */
export function encodeCall(op: number, kinds: string, args: readonly (number | Uint8Array)[], type: number = FRAME_CALL): Uint8Array<ArrayBuffer> {
  let len = 0;
  for (let i = 0; i < kinds.length; i++) {
    const k = kinds[i];
    len += k === 'd' ? 8 : k === 'b' ? 4 + (args[i] as Uint8Array).length : 4;
  }
  const out = new Uint8Array(7 + len);
  const dv = new DataView(out.buffer);
  out[0] = type;
  dv.setUint16(1, op, true);
  dv.setUint32(3, len, true);
  let at = 7;
  for (let i = 0; i < kinds.length; i++) {
    const k = kinds[i], v = args[i];
    if (k === 'b') {
      const b = v as Uint8Array;
      dv.setUint32(at, b.length, true);
      out.set(b, at + 4);
      at += 4 + b.length;
    } else if (k === 'd') {
      dv.setFloat64(at, Number(v), true);
      at += 8;
    } else {
      if (k === 'u') dv.setUint32(at, Number(v) >>> 0, true);
      else dv.setInt32(at, Number(v) | 0, true);
      at += 4;
    }
  }
  return out;
}

/** The last SURFACE the relay sent for a surface (STREAM.md 0x11). */
interface SurfaceRecord {
  role: number; scale: number; viewW: number; viewH: number; state: number; root: number; parent: number;
  x: number; y: number; z: number; gx: number; gy: number; gw: number; gh: number;
}

/** An EVENT's arguments, read in order; a read past the end throws. */
class Args {
  dv: DataView;
  bytes: Uint8Array;
  at: number;
  end: number;
  constructor(bytes: Uint8Array, start: number, end: number) {
    this.bytes = bytes;
    this.dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.at = start;
    this.end = end;
  }
  need(n: number): number {
    if (this.at + n > this.end) throw new RangeError('short');
    const at = this.at;
    this.at += n;
    return at;
  }
  u32(): number { return this.dv.getUint32(this.need(4), true); }
  i32(): number { return this.dv.getInt32(this.need(4), true); }
  data(): Uint8Array {
    const n = this.u32();
    const at = this.need(n);
    return this.bytes.subarray(at, at + n);
  }
}

/** The remote core of one session link (see the file comment). A new one
 *  per link: its mirror is that link's scene. */
export function createRemoteCore(options: RemoteCoreOptions): CoreExports {
  const { real, env, send, frameLen, log } = options;
  const surfaces = new Map<string, SurfaceRecord>(); // `${conn}:${surface}` → last SURFACE
  let positionsDirty = false;
  let locks = options.locks & 3;
  let selection: { conn: number; mimes: string[] } = { conn: 0, mimes: [] };
  const dec = new TextDecoder();

  // a fixed region for wland_surface_place (3 × i32) and
  // wland_window_geometry (4 × i32), 4-aligned, like the core's statics
  const fixedAlloc = real.wland_alloc(32);
  const placeAt = (fixedAlloc + 3) & ~3, geometryAt = placeAt + 12;
  if (!fixedAlloc) log('remote core: wland_alloc failed');

  const mem = (ptr: number, len: number) => new Uint8Array(real.memory.buffer, ptr, len);
  const call = (op: number, kinds: string, ...args: (number | Uint8Array)[]) => { send(encodeCall(op, kinds, args)); return 0; };
  // `bytes` in wasm memory (4-aligned: input_region's handler reads i32s)
  // for the length of `fn`
  function inWasm(bytes: Uint8Array, fn: (ptr: number, len: number) => void) {
    const size = bytes.length + 4;
    const p = real.wland_alloc(size);
    if (!p) { log('remote core: wland_alloc failed'); return; }
    const at = (p + 3) & ~3;
    mem(at, bytes.length).set(bytes);
    try { fn(at, bytes.length); } finally { real.wland_free(p, size); }
  }
  const record = (conn: number, surface: number) => surfaces.get(`${conn >>> 0}:${surface >>> 0}`);
  const getter = (field: keyof SurfaceRecord) => (conn: number, surface: number) => record(conn, surface)?.[field] ?? 0;

  function surfaceFrame(dv: DataView, off: number) {
    const f = (i: number) => dv.getInt32(off + 1 + i * 4, true);
    const u = (i: number) => dv.getUint32(off + 1 + i * 4, true);
    const key = `${u(0)}:${u(1)}`;
    const rec: SurfaceRecord = {
      role: u(2), scale: f(3), viewW: f(4), viewH: f(5), state: u(6), root: u(7), parent: u(8),
      x: f(9), y: f(10), z: f(11), gx: f(12), gy: f(13), gw: f(14), gh: f(15),
    };
    const old = surfaces.get(key);
    if (old && (old.x !== rec.x || old.y !== rec.y || old.z !== rec.z)) positionsDirty = true;
    surfaces.set(key, rec);
  }

  function dropConn(conn: number) {
    const prefix = `${conn}:`;
    for (const key of surfaces.keys()) if (key.startsWith(prefix)) surfaces.delete(key);
  }

  function event(op: number, a: Args) {
    switch (op) {
      case 1: return inWasm(a.data(), (p, n) => env.js_log(p, n));
      case 2: {
        const conn = a.u32(), surface = a.u32();
        return inWasm(a.data(), (p, n) => env.js_set_title(conn, surface, p, n));
      }
      case 3: {
        const conn = a.u32(), surface = a.u32(), value = a.u32();
        env.js_surface_event(conn, surface, value);
        // a surface's record ends with its destroyed value
        if (value === SURFACE_DESTROYED) surfaces.delete(`${conn}:${surface}`);
        return;
      }
      case 4: { const conn = a.u32(), surface = a.u32(), kind = a.u32(), value = a.u32(); return env.js_interactive(conn, surface, kind, value); }
      case 5: { const conn = a.u32(), shape = a.u32(); return env.js_cursor_shape(conn, shape); }
      case 6: { const conn = a.u32(), surface = a.u32(), hx = a.i32(), hy = a.i32(); return env.js_cursor_surface(conn, surface, hx, hy); }
      case 7: {
        const conn = a.u32(), active = a.u32(), x = a.i32(), y = a.i32(), w = a.i32(), h = a.i32();
        return env.js_text_input(conn, active, x, y, w, h);
      }
      case 8: {
        const conn = a.u32(), surface = a.u32(), infinite = a.u32(), n = a.u32();
        if (n > (a.end - a.at) / 16) throw new RangeError('short');
        const at = a.need(n * 16);
        return inWasm(a.bytes.subarray(at, at + n * 16), (p) => env.js_input_region(conn, surface, infinite, p, n));
      }
      case 9: { const conn = a.u32(), surface = a.u32(); return env.js_pointer_lock(conn, surface); }
      case 10: {
        const conn = a.u32(), mimes = a.data();
        selection = { conn, mimes: mimes.length ? dec.decode(mimes).split('\0') : [] };
        return inWasm(mimes, (p, n) => env.js_selection(conn, p, n));
      }
      case 11: {
        const id = a.u32(), status = a.u32();
        return inWasm(a.data(), (p, n) => env.js_selection_data(id, status, p, n));
      }
      case 12: locks = a.u32() & 3; return;
      case 13: return options.synced();
      case 14: {
        const conn = a.u32(), surface = a.u32();
        return inWasm(a.data(), (p, n) => env.js_set_app_id(conn, surface, p, n));
      }
      case 15: {
        const conn = a.u32(), surface = a.u32(), minW = a.i32(), minH = a.i32(), maxW = a.i32(), maxH = a.i32();
        return env.js_size_limits(conn, surface, minW, minH, maxW, maxH);
      }
      default: return; // an op this viewer does not know: skipped
    }
  }

  function onFrame(ptr: number, len: number) {
    // a copy: delivering an EVENT allocates wasm memory, which may grow it
    const bytes = mem(ptr, len).slice();
    const dv = new DataView(bytes.buffer);
    let off = 0;
    while (off < len) {
      const n = frameLen(dv, off, len);
      if (n <= 0 || off + n > len) { log(`session: bad frame at ${off} (${len}B run): rest dropped`); return 0; }
      const t = bytes[off];
      switch (t) {
        case FRAME_EVENT: {
          const op = dv.getUint16(off + 1, true);
          try {
            event(op, new Args(bytes, off + 7, off + n));
          } catch (e) {
            if (!(e instanceof RangeError)) throw e;
            log(`session: EVENT ${op} with ${n - 7} bytes of arguments: too short, skipped`);
          }
          break;
        }
        case FRAME_SURFACE: surfaceFrame(dv, off); break;
        case FRAME_CONN_OPEN: break; // the engine tracks it
        case FRAME_CONN_CLOSE: {
          const conn = dv.getUint32(off + 1, true);
          dropConn(conn);
          env.js_conn_close(conn);
          break;
        }
        // decoded by the wasm, which touches no compositor state for them
        case FRAME_HANDLE_OPEN: case FRAME_HANDLE_CLOSE: real.wland_on_frame(ptr + off, n); break;
        case FRAME_FEATURE: break; // (the engine read the session one)
        default: log(`session: frame type 0x${t.toString(16)} on a session link: skipped`);
      }
      off += n;
    }
    return 0;
  }

  // wland_set_selection's packed entries, checked as the core checks them:
  // { u32 mime_len, mime, u32 data_len | 0xffffffff, data }
  function wellFormed(b: Uint8Array): boolean {
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    let at = 0, blobs = 0, total = 0;
    const mimes = new Set<string>();
    while (at < b.length) {
      if (b.length - at < 4) return false;
      const ml = dv.getUint32(at, true);
      if (ml === 0 || ml > MAX_MIME || b.length - at - 4 < ml + 4) return false;
      const mime = b.subarray(at + 4, at + 4 + ml);
      if (mime.includes(0)) return false;
      at += 4 + ml;
      const dl = dv.getUint32(at, true);
      at += 4;
      if (dl === 0xffffffff) {
        if (!blobs) return false;
      } else {
        if (b.length - at < dl) return false;
        total += dl;
        if (total > MAX_SELECTION || blobs === MAX_MIMES) return false;
        blobs++;
        at += dl;
      }
      mimes.add(dec.decode(mime));
      if (mimes.size > MAX_MIMES) return false;
    }
    return true;
  }

  const core: CoreExports = {
    memory: real.memory,
    // stateless: the real wasm's
    wland_version: () => real.wland_version(),
    wland_alloc: (len) => real.wland_alloc(len),
    wland_free: (ptr, len) => real.wland_free(ptr, len),
    wland_swizzle: (...a) => real.wland_swizzle(...a),
    wland_decode_buffer: (ptr, len) => real.wland_decode_buffer(ptr, len),
    wland_commit_notice: (ptr, len) => real.wland_commit_notice(ptr, len),

    wland_on_frame: onFrame,
    // the relay runs the frame clock and notes buffer sizes itself
    wland_tick: () => 0,
    wland_note_buffer_size: () => 0,
    wland_commit_ack: (conn, serial) => {
      const f = new Uint8Array(9);
      const dv = new DataView(f.buffer);
      f[0] = FRAME_ACK;
      dv.setUint32(1, conn >>> 0, true);
      dv.setUint32(5, serial >>> 0, true);
      send(f);
      return 0;
    },

    wland_keyboard_locks: (l) => { locks = l & 3; return call(16, 'u', l); },
    wland_text_input_preedit: (conn, ptr, len, begin, end) =>
      call(OP_PREEDIT, 'ubii', conn, mem(ptr, len).slice(), begin, end),
    wland_text_input_commit_string: (conn, ptr, len) => call(OP_COMMIT_STRING, 'ub', conn, mem(ptr, len).slice()),
    // no synchronous result over a link: well-formed is set (the
    // `selection` EVENT tells), and a session relay always bridges
    wland_set_selection: (ptr, len) => {
      const b = len ? mem(ptr, len).slice() : new Uint8Array(0);
      if (len && !wellFormed(b)) return 0;
      call(OP_SET_SELECTION, 'b', b);
      return 1;
    },
    // asked only when an app's selection offers it (the answer is an
    // EVENT selection_data); else nothing to ask, as the core says
    wland_read_selection: (ptr, len, id, max) => {
      const mime = mem(ptr, len).slice();
      if (selection.conn === 0 || !selection.mimes.includes(dec.decode(mime))) return 0;
      call(OP_READ_SELECTION, 'buu', mime, id, max);
      return 1;
    },

    // the getters: the mirror (unknown surface: zeros)
    wland_surface_role: getter('role'),
    wland_surface_scale: getter('scale'),
    wland_surface_view_w: getter('viewW'),
    wland_surface_view_h: getter('viewH'),
    wland_toplevel_state: getter('state'),
    wland_surface_root: getter('root'),
    wland_surface_parent: getter('parent'),
    wland_surface_z: getter('z'),
    wland_surface_abs_x: getter('x'),
    wland_surface_abs_y: getter('y'),
    wland_surface_place: (conn, surface) => {
      const r = record(conn, surface);
      new Int32Array(real.memory.buffer, placeAt, 3).set(r ? [r.x, r.y, r.z] : [0, 0, 0]);
      return placeAt;
    },
    wland_window_geometry: (conn, surface) => {
      const r = record(conn, surface);
      new Int32Array(real.memory.buffer, geometryAt, 4).set(r ? [r.gx, r.gy, r.gw, r.gh] : [0, 0, 0, 0]);
      return geometryAt;
    },
    wland_take_positions_dirty: () => {
      const d = positionsDirty;
      positionsDirty = false;
      return d ? 1 : 0;
    },
    wland_keyboard_locks_state: () => locks,
    wland_selection_bridged: () => 1,
  };
  for (const [name, [op, kinds]] of Object.entries(CALLS)) {
    if (name === 'wland_keyboard_locks') continue; // (above: it also updates the mirror)
    core[name as `wland_${string}`] = (...args: number[]) => call(op, kinds, ...args.slice(0, kinds.length));
  }
  // The core resets a conn's cursor to the default as its pointer leaves,
  // within the call. Here that answer is a round trip away, so the reset is
  // made at once (the relay's own, later, repeats it): no app cursor is
  // shown past the window it belonged to.
  const pointerIn = new Set<number>();
  const enter = core.wland_pointer_enter, leave = core.wland_pointer_leave;
  core.wland_pointer_enter = (conn, ...rest) => {
    pointerIn.add(conn >>> 0);
    return enter(conn, ...rest);
  };
  core.wland_pointer_leave = (conn, ...rest) => {
    const r = leave(conn, ...rest);
    if (pointerIn.delete(conn >>> 0)) env.js_cursor_shape(conn, 0);
    return r;
  };
  return core;
}
