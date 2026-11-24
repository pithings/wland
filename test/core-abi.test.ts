// The core wasm's link-v2 ABI (core/src/wasm.zig, protocol/STREAM.md v2),
// exercised on the raw exports with stub imports: HANDLE_OPEN/HANDLE_CLOSE
// decoding into js_handle_open/js_handle_close, wland_commit_notice's decoded
// layout, wland_commit_ack's ACK frame, and wland_swizzle. Needs a prior
// `zig build` (lib/wland.wasm).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const bytes = await readFile(new URL('../lib/wland.wasm', import.meta.url));

type Wasm = (ptr: number, len: number) => number;

async function core() {
  const calls = { sent: [] as Uint8Array[], open: [] as number[][], close: [] as number[][], log: [] as string[] };
  let ex: any; // the raw exports
  const env = new Proxy<Record<string | symbol, (...a: number[]) => unknown>>({
    js_send: (ptr, len) => calls.sent.push(new Uint8Array(ex.memory.buffer, ptr, len).slice()),
    js_log: (ptr, len) => calls.log.push(new TextDecoder().decode(new Uint8Array(ex.memory.buffer, ptr, len))),
    js_handle_open: (...a) => calls.open.push(a),
    js_handle_close: (...a) => calls.close.push(a),
  }, { get: (t, k) => t[k] ?? (() => {}) });
  ({ instance: { exports: ex } } = await WebAssembly.instantiate(bytes, { env }));
  ex.wland_init(1, 120);
  // copy `u8` into wasm memory, call fn(ptr, len), free
  const withBytes = (u8: Uint8Array, fn: Wasm): number => {
    const ptr = ex.wland_alloc(u8.length);
    new Uint8Array(ex.memory.buffer, ptr, u8.length).set(u8);
    try { return fn(ptr, u8.length); } finally { ex.wland_free(ptr, u8.length); }
  };
  return { ex, calls, withBytes };
}

// little-endian builders
const u32 = (...v: number[]) => [...new Uint8Array(new Uint32Array(v).buffer)];
const u64 = (v: number) => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(v), true); return [...b]; };
const frame = (...parts: (number[] | Uint8Array)[]) => new Uint8Array(parts.flatMap((p) => [...p]));

const handleOpen = (conn: number, handle: number, kind: number, hb: number[]) => frame([0x08], u32(conn, handle, kind, hb.length), hb);
const kwshm = (id: number, size: number) => [...u32(id), ...u64(size)];
const procfd = (pid: number, fd: number, off: number, size: number) => [...u32(pid, fd), ...u64(off), ...u64(size)];
const shmCommit = (conn: number, surface: number, serial: number, ref: number[], rects: number[][]) =>
  frame([0x0a], u32(conn, surface, serial, rects.length, 1, 24), u32(...ref), u32(...rects.flat().map((v) => v >>> 0)));

test('HANDLE_OPEN / HANDLE_CLOSE decode into js_handle_open / js_handle_close', async () => {
  const { ex, calls, withBytes } = await core();
  const msg = frame(
    [...handleOpen(3, 10, 1, kwshm(77, 3 * 4096 + 12))],
    [...handleOpen(3, 11, 2, procfd(4242, 17, 8192, 2 ** 33))],
    [...handleOpen(3, 12, 9, [1, 2, 3])],            // unknown kind
    [...handleOpen(3, 13, 1, [1, 2, 3, 4])],         // kwshm bytes of the wrong length
    [0x09], u32(3, 10),
  );
  withBytes(msg, (p: number, n: number) => ex.wland_on_frame(p, n));
  assert.deepEqual(calls.open, [
    [3, 10, 1, 77, 0, 0, 3 * 4096 + 12],
    [3, 11, 2, 4242, 17, 8192, 2 ** 33],
    [3, 12, 0, 9, 0, 0, 0],
    [3, 13, 0, 1, 0, 0, 0],
  ]);
  assert.deepEqual(calls.close, [[3, 10]]);
  assert.equal(calls.sent.length, 0);
});

test('wland_commit_notice decodes a shm COMMIT; wland_commit_ack sends ACK', async () => {
  const { ex, calls, withBytes } = await core();
  // handle 4, offset 64, 10x5, stride 48, XRGB8888; two damage rects
  const f = shmCommit(2, 6, 17, [4, 64, 10, 5, 48, 1], [[0, 0, 10, 1], [9, 4, 1, 1]]);
  const ptr = withBytes(f, (p: number, n: number) => ex.wland_commit_notice(p, n));
  assert.ok(ptr);
  assert.equal(ptr % 4, 0);
  const w = new Uint32Array(ex.memory.buffer, ptr, 14 + 8);
  // conn, surface, serial, kind 1, n_rects; handle, offset, w, h, stride, format; 3 unused
  assert.deepEqual([...w.subarray(0, 14)], [2, 6, 17, 1, 2, 4, 64, 10, 5, 48, 1, 0, 0, 0]);
  assert.deepEqual([...new Int32Array(ex.memory.buffer, ptr + 56, 8)], [0, 0, 10, 1, 9, 4, 1, 1]);

  ex.wland_commit_ack(2, 17);
  assert.deepEqual([...calls.sent.at(-1)!], [0x0b, ...u32(2, 17)]);

  // a rect past the buffer edge: still decodes (kind 0, ack only)
  const bad = shmCommit(2, 6, 18, [4, 64, 10, 5, 48, 1], [[5, 0, 6, 1]]);
  const p2 = withBytes(bad, (p: number, n: number) => ex.wland_commit_notice(p, n));
  assert.deepEqual([...new Uint32Array(ex.memory.buffer, p2, 14)], [2, 6, 18, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  // an unknown wl_shm format: kind 0
  const fmt = shmCommit(2, 6, 19, [4, 64, 10, 5, 48, 0x34325258], [[0, 0, 1, 1]]);
  const p3 = withBytes(fmt, (p: number, n: number) => ex.wland_commit_notice(p, n));
  assert.equal(new Uint32Array(ex.memory.buffer, p3, 14)[3], 0);
  // not a whole COMMIT frame: 0
  assert.equal(withBytes(f.subarray(0, f.length - 1), (p: number, n: number) => ex.wland_commit_notice(p, n)), 0);
  assert.equal(withBytes(frame([0x0b], u32(1, 1)), (p: number, n: number) => ex.wland_commit_notice(p, n)), 0);
});

// COMMIT kind 2 (virtgpu): resource, width, height, format, flags, offset,
// stride (u32s), modifier (u64), then any bytes a later relay appends
const u64n = (v: bigint) => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, v, true); return [...b]; };
const virtgpuCommit = (conn: number, surface: number, serial: number, ref: number[], modifier: bigint, rects: number[][], extra: number[] = []) =>
  frame([0x0a], u32(conn, surface, serial, rects.length, 2, 36 + extra.length), u32(...ref), u64n(modifier), extra,
    u32(...rects.flat().map((v) => v >>> 0)));

test('wland_commit_notice decodes a virtgpu COMMIT (a longer ref too); an invalid one is kind 0', async () => {
  const { ex, withBytes } = await core();
  const MOD_INVALID = 0x00ffffffffffffffn;
  // resource 42, 64x32, XBGR8888, y_invert, offset 0, stride 256
  const f = virtgpuCommit(3, 9, 5, [42, 64, 32, 0x34324258, 1, 0, 256], MOD_INVALID, [[0, 0, 64, 32], [1, 2, 3, 4]]);
  const ptr = withBytes(f, (p: number, n: number) => ex.wland_commit_notice(p, n));
  assert.ok(ptr);
  assert.deepEqual([...new Uint32Array(ex.memory.buffer, ptr, 14)],
    [3, 9, 5, 2, 2, 42, 64, 32, 0x34324258, 1, 0, 256, 0xffffffff, 0x00ffffff]);
  assert.deepEqual([...new Int32Array(ex.memory.buffer, ptr + 56, 8)], [0, 0, 64, 32, 1, 2, 3, 4]);

  const longer = virtgpuCommit(3, 9, 6, [42, 64, 32, 0x34324258, 0, 0, 256], 0n, [[0, 0, 1, 1]], [7, 7, 7, 7]);
  const p2 = withBytes(longer, (p: number, n: number) => ex.wland_commit_notice(p, n));
  assert.deepEqual([...new Uint32Array(ex.memory.buffer, p2, 6)], [3, 9, 6, 2, 1, 42]);

  for (const bad of [
    virtgpuCommit(3, 9, 7, [0, 64, 32, 0x34324258, 0, 0, 256], 0n, [[0, 0, 1, 1]]),   // resource 0
    virtgpuCommit(3, 9, 8, [42, 64, 32, 0x34324258, 0, 0, 256], 0n, [[60, 0, 5, 1]]), // rect past the edge
    frame([0x0a], u32(3, 9, 9, 1, 2, 8), u32(42, 64), u32(0, 0, 1, 1)),              // short ref
  ]) {
    const p = withBytes(bad, (q: number, n: number) => ex.wland_commit_notice(q, n));
    assert.ok(p);
    assert.equal(new Uint32Array(ex.memory.buffer, p, 14)[3], 0);
  }
});

test('a COMMIT that reaches wland_on_frame is acked unpresented', async () => {
  const { ex, calls, withBytes } = await core();
  withBytes(shmCommit(5, 6, 99, [1, 0, 1, 1, 4, 0], [[0, 0, 1, 1]]), (p: number, n: number) => ex.wland_on_frame(p, n));
  assert.deepEqual([...calls.sent.at(-1)!], [0x0b, ...u32(5, 99)]);
});

test('wland_swizzle: strided BGRX/BGRA to tight RGBA, in place', async () => {
  const { ex } = await core();
  const src = new Uint8Array([
    1, 2, 3, 4, 5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee,
    9, 10, 11, 12, 13, 14, 15, 0, 0xee, 0xee, 0xee, 0xee,
  ]);
  const ptr = ex.wland_alloc(src.length);
  const mem = () => new Uint8Array(ex.memory.buffer, ptr, src.length);
  mem().set(src);
  ex.wland_swizzle(ptr, 12, ptr, 2, 2, 0); // ARGB: alpha passes through
  assert.deepEqual([...mem().subarray(0, 16)], [3, 2, 1, 4, 7, 6, 5, 8, 11, 10, 9, 12, 15, 14, 13, 0]);
  mem().set(src);
  ex.wland_swizzle(ptr, 12, ptr, 2, 2, 1); // XRGB: alpha forced opaque
  assert.deepEqual([...mem().subarray(0, 16)], [3, 2, 1, 255, 7, 6, 5, 255, 11, 10, 9, 255, 15, 14, 13, 255]);
  ex.wland_free(ptr, src.length);
});

test('wland_decode_buffer: raw_len must equal the rects\' pixel bytes, else 0 (never a frame that reads past its pixels)', async () => {
  const { ex, withBytes } = await core();
  // BUFFER_LZ: conn 1, surface 2, 2x2 buffer, one 2x2 rect (16 pixel bytes)
  const lz = (rawLen: number, comp: number[]) => frame([0x07], u32(1, 2, 2, 2, 1), u32(0, 0, 2, 2), u32(rawLen, comp.length), comp);
  const literals = (bytes: number[]) => bytes.length < 15 ? [bytes.length << 4, ...bytes] : [0xf0, bytes.length - 15, ...bytes];
  const px = Array.from({ length: 16 }, (_, i) => i + 1);

  const ok = withBytes(lz(16, literals(px)), (p: number, n: number) => ex.wland_decode_buffer(p, n));
  assert.ok(ok);
  assert.deepEqual([...new Uint8Array(ex.memory.buffer, ok, 21 + 16 + 16)],
    [0x02, ...u32(1, 2, 2, 2, 1), ...u32(0, 0, 2, 2), ...px]);
  // raw_len smaller than the rects need: the reconstructed 0x02 frame would
  // claim 16 pixel bytes with 4 behind it
  assert.equal(withBytes(lz(4, literals(px.slice(0, 4))), (p: number, n: number) => ex.wland_decode_buffer(p, n)), 0);
  // larger: as wrong
  const more = Array.from({ length: 20 }, (_, i) => i);
  assert.equal(withBytes(lz(20, literals(more)), (p: number, n: number) => ex.wland_decode_buffer(p, n)), 0);
});

test('wland_set_gpu_source: default on; off, FEATURE dmabuf_kind virtgpu keeps linux-dmabuf unadvertised, and it survives wland_init', async () => {
  const table = [...u32(0xe280, 0), ...u32(0x34325258, 0, 0, 0)];
  const features = frame([0x0c], u32(2, 4, 2), [0x0c], u32(1, table.length), table);
  // a fresh link's compositor: FEATUREs, an app, its registry → advertised?
  const advertised = (c: Awaited<ReturnType<typeof core>>) => {
    c.calls.sent.length = 0;
    c.withBytes(frame(features, [0x03], u32(5), [0x01], u32(5, 12), u32(1, (12 << 16) | 1, 2)), (p, n) => c.ex.wland_on_frame(p, n));
    return c.calls.sent.some((b) => new TextDecoder().decode(b).includes('zwp_linux_dmabuf_v1'));
  };
  const c = await core();
  assert.equal(advertised(c), true, 'an embedder that never says is unchanged');
  c.ex.wland_set_gpu_source(0);
  c.ex.wland_init(1, 120);
  assert.equal(advertised(c), false);
  assert.ok(c.calls.log.some((l) => /linux-dmabuf not offered/.test(l)));
  c.ex.wland_init(1, 120); // the next link: still off
  assert.equal(advertised(c), false);
  c.ex.wland_set_gpu_source(1);
  c.ex.wland_init(1, 120);
  assert.equal(advertised(c), true);
});

// COMMIT kind 3 (external): u64 id, width, height, format, flags (u32s),
// then any bytes a later relay appends
const ARGB8888 = 0x34325241, XBGR8888 = 0x34324258;
const externalCommit = (conn: number, surface: number, serial: number, id: bigint, ref: number[], rects: number[][], extra: number[] = []) =>
  frame([0x0a], u32(conn, surface, serial, rects.length, 3, 24 + extra.length), u64n(id), u32(...ref), extra,
    u32(...rects.flat().map((v) => v >>> 0)));

test('wland_commit_notice decodes an external COMMIT (id low/high words, a longer ref too); an invalid one is kind 0', async () => {
  const { ex, withBytes, calls } = await core();
  const id = 0x89abcdef01234567n;
  const f = externalCommit(3, 9, 5, id, [64, 32, XBGR8888, 1], [[0, 0, 64, 32], [1, 2, 3, 4]]);
  const ptr = withBytes(f, (p: number, n: number) => ex.wland_commit_notice(p, n));
  assert.ok(ptr);
  assert.deepEqual([...new Uint32Array(ex.memory.buffer, ptr, 14)],
    [3, 9, 5, 3, 2, 0x01234567, 0x89abcdef, 64, 32, XBGR8888, 1, 0, 0, 0]);
  assert.deepEqual([...new Int32Array(ex.memory.buffer, ptr + 56, 8)], [0, 0, 64, 32, 1, 2, 3, 4]);

  const longer = externalCommit(3, 9, 6, 7n, [16384, 1, ARGB8888, 0], [[0, 0, 1, 1]], [7, 7, 7, 7]);
  const p2 = withBytes(longer, (p: number, n: number) => ex.wland_commit_notice(p, n));
  assert.deepEqual([...new Uint32Array(ex.memory.buffer, p2, 11)], [3, 9, 6, 3, 1, 7, 0, 16384, 1, ARGB8888, 0]);

  for (const bad of [
    externalCommit(3, 9, 7, id, [64, 32, 0x3231564e, 0], [[0, 0, 1, 1]]),  // NV12: not a format the manager takes
    externalCommit(3, 9, 8, id, [0, 32, ARGB8888, 0], [[0, 0, 1, 1]]),     // width 0
    externalCommit(3, 9, 9, id, [64, 16385, ARGB8888, 0], [[0, 0, 1, 1]]), // height past 16384
    externalCommit(3, 9, 10, id, [64, 32, ARGB8888, 2], [[0, 0, 1, 1]]),   // unknown flag
    externalCommit(3, 9, 11, id, [64, 32, ARGB8888, 0], [[60, 0, 5, 1]]),  // rect past the edge
    externalCommit(3, 9, 12, id, [64, 32, ARGB8888, 0], []),               // no rects
    frame([0x0a], u32(3, 9, 13, 1, 3, 20), u64n(id), u32(64, 32, ARGB8888), u32(0, 0, 1, 1)), // short ref
  ]) {
    const p = withBytes(bad, (q: number, n: number) => ex.wland_commit_notice(q, n));
    assert.ok(p);
    assert.deepEqual([...new Uint32Array(ex.memory.buffer, p, 14)].slice(3), Array(11).fill(0));
  }
  assert.equal(calls.log.filter((l) => /kind external/.test(l)).length, 7, 'each one logged with why');
});

test('wland_set_gpu_source is a mask (bit 0 virtgpu, bit 1 external); wland_external_buffers: 2 until the FEATUREs settle, then 1 only with FEATURE external_buffer AND bit 1', async () => {
  const extFeature = frame([0x0c], u32(5, 0));
  const app = frame([0x03], u32(5), [0x01], u32(5, 12), u32(1, (12 << 16) | 1, 2));
  const table = [...u32(0xe280, 0), ...u32(0x34325258, 0, 0, 0)];
  const dmabuf = frame([0x0c], u32(2, 4, 2), [0x0c], u32(1, table.length), table);
  // a fresh link: its FEATUREs, then an app's registry; what each step says
  const link = async (mask: number | null, features: Uint8Array) => {
    const c = await core();
    if (mask !== null) c.ex.wland_set_gpu_source(mask);
    c.ex.wland_init(1, 120);
    const before = c.ex.wland_external_buffers();
    if (features.length) c.withBytes(features, (p, n) => c.ex.wland_on_frame(p, n));
    const featured = c.ex.wland_external_buffers();
    c.calls.sent.length = 0;
    c.withBytes(app, (p, n) => c.ex.wland_on_frame(p, n));
    const text = c.calls.sent.map((b) => new TextDecoder().decode(b)).join('');
    return {
      states: [before, featured, c.ex.wland_external_buffers()],
      external: text.includes('wland_external_buffer_manager_v1'),
      dmabuf: text.includes('zwp_linux_dmabuf_v1'),
    };
  };
  assert.deepEqual(await link(null, extFeature), { states: [2, 2, 0], external: false, dmabuf: false }, 'never called: no external');
  assert.deepEqual(await link(2, extFeature), { states: [2, 1, 1], external: true, dmabuf: false });
  assert.deepEqual(await link(3, extFeature), { states: [2, 1, 1], external: true, dmabuf: false });
  assert.deepEqual(await link(1, extFeature), { states: [2, 2, 0], external: false, dmabuf: false });
  assert.deepEqual(await link(2, new Uint8Array(0)), { states: [2, 2, 0], external: false, dmabuf: false }, 'no FEATURE: not offered');
  // bit 0 alone decides linux-dmabuf in front of a virtgpu relay
  assert.equal((await link(2, dmabuf)).dmabuf, false);
  assert.equal((await link(1, dmabuf)).dmabuf, true);
  assert.equal((await link(3, frame(dmabuf, extFeature))).dmabuf, true);
  assert.equal((await link(3, frame(dmabuf, extFeature))).external, true);
});
