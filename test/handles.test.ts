// The engine's link-v2 handle path (protocol/STREAM.md HANDLE_OPEN,
// HANDLE_CLOSE, COMMIT, ACK) driven over a scripted link with an in-memory
// HandleSource. Frames come from the demo's STREAM encoder
// (test/support/proto.js), cross-checked here against hand-built
// bytes in the layout test/core-abi.test.ts pins. Needs a prior `zig build`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createEngine, type BufferHandle, type CommitEvent, type ExternalRef, type GpuRef, type GpuSource, type HandleRead, type HandleSource, type LinkCallbacks } from '../lib/engine.ts';
import { swizzleRect } from '../lib/present.ts';
import { createView } from '../lib/view.ts';
import { installFakeDom } from './fake-dom.ts';
import {
  wlMessage as msg, wlEach, eachEngineFrame, pack, T, FD, HANDLE, SHM,
  connOpen, connClose, wireFrame, fdmsg, handleOpen, handleClose, kwshmBytes, procfdBytes, shmCommit, virtgpuCommit, externalCommit,
} from './support/proto.js';

const wasm = await readFile(new URL('../lib/wland.wasm', import.meta.url));

// object ids of the client below
const REG = 2, COMP = 3, SHM_ID = 4, WM = 5, SURF = 6, XSURF = 7, TOP = 8, POOL = 9, BUF = 10;
const W = 8, H = 4, STRIDE = 40; // 8x4 px, 8 bytes of row padding

interface ScriptedLink {
  sent: Uint8Array[];
  bufferedAmount: number;
  cb: LinkCallbacks;
  start(cb: LinkCallbacks): void;
  send(bytes: Uint8Array<ArrayBuffer>): void;
  close?(): void;
}
function scriptedLink(): ScriptedLink {
  const link = { sent: [], bufferedAmount: 0, cb: null } as unknown as ScriptedLink;
  link.start = (cb) => { link.cb = cb; };
  link.send = (bytes) => { link.sent.push(bytes); };
  return link;
}

// every engine→relay frame sent so far, decoded
function sentFrames(link: ScriptedLink) {
  const out: any[] = [];
  for (const b of link.sent) eachEngineFrame(b, (f: any) => out.push(f));
  return out;
}
const acks = (link: ScriptedLink) => sentFrames(link).filter((f) => f.type === 'ack').map((f) => [f.conn, f.serial]);

// An in-memory HandleSource over named ArrayBuffers ("exports"), recording
// every call. `exports` maps kwshm id → Uint8Array.
interface MemToken { mem: Uint8Array; id: number; closed: boolean }
function memorySource(exports: Map<number, Uint8Array>, { async = false } = {}) {
  const calls: any[][] = [];
  const live = new Set<MemToken>();
  const later = <R>(fn: () => R): R | Promise<R> => (async ? Promise.resolve().then(fn) : fn());
  const source: HandleSource<MemToken> & { calls: any[][]; live: Set<MemToken> } = {
    calls, live,
    open(handle, conn) {
      calls.push(['open', handle, conn]);
      return later(() => {
        const id = (handle as Extract<BufferHandle, { kind: 'kwshm' }>).id;
        const mem = exports.get(id);
        if (!mem) throw new Error(`no export ${id}`);
        const token = { mem, id, closed: false };
        live.add(token);
        return token;
      });
    },
    read(token, offset, dst) {
      calls.push(['read', token.id, offset, dst.length]);
      assert.equal(token.closed, false, 'read after close');
      return later(() => dst.set(token.mem.subarray(offset, offset + dst.length)));
    },
    close(token) {
      calls.push(['close', token.id]);
      assert.equal(token.closed, false, 'double close');
      token.closed = true;
      live.delete(token);
    },
  };
  return source;
}

// BGRX pixels: byte i of the buffer = i & 0xff, so any misplaced read shows
function pixelBytes(size: number) {
  return new Uint8Array(size).map((_, i) => i & 0xff);
}

// engine + a mapped toplevel on `conn` with an 8x4 buffer, ready for COMMITs
// `peek` sees each commit event as dispatched (its pixels still the engine's view)
async function setup({ conn = 1, source, rgba = false, gpu, peek }:
  { conn?: number; source?: HandleSource; rgba?: boolean; gpu?: GpuSource; peek?: (ev: CommitEvent) => void } = {}) {
  const link = scriptedLink();
  const events: any[] = [];
  const engine = await createEngine({
    wasm, link, buffers: source, rgba, gpu,
    onEvent(ev) {
      // pixels are a view valid only during dispatch: copy; and note how
      // many ACKs had been sent when the commit was dispatched
      if (ev.type === 'commit') peek?.(ev);
      if (ev.type === 'commit') events.push({ ...ev, pixels: ev.pixels.slice(), acksBefore: acks(link).length });
      else events.push(ev);
    },
  });
  engine.start();
  link.cb.onOpen();
  const deliver = (...frames: Uint8Array[]) => link.cb.onMessage(pack(frames));

  // a client with a mapped toplevel and its buffer on `conn` (again after
  // a link reopens); returns its commit WIRE maker
  const client = (conn: number) => {
    deliver(connOpen(conn), wireFrame(conn, msg(1, 1, [REG])));
    const globals: Record<string, { name: number; version: number }> = {};
    for (const f of sentFrames(link)) {
      if (f.type === 'wire') wlEach(f.bytes, (obj: number, op: number, r: any) => {
        if (obj === REG && op === 0) { const name = r.u32(); globals[r.str()] = { name, version: r.u32() }; }
      });
    }
    const bind = (iface: string, version: number, id: number) => msg(REG, 0, [globals[iface].name, iface, version, id]);
    deliver(wireFrame(conn, concat(
      bind('wl_compositor', 4, COMP), bind('wl_shm', 1, SHM_ID), bind('xdg_wm_base', 1, WM),
      msg(COMP, 0, [SURF]), msg(WM, 2, [XSURF, SURF]), msg(XSURF, 1, [TOP]), msg(TOP, 2, ['handles']),
      msg(SURF, 6), // initial commit → configure
    )));
    let serial = 0;
    for (const f of sentFrames(link)) {
      if (f.type === 'wire') wlEach(f.bytes, (obj: number, op: number, r: any) => { if (obj === XSURF && op === 0) serial = r.u32(); });
    }
    assert.ok(serial, 'xdg_surface.configure');
    // ack_configure, then the pool (an FDMSG: the fd stays in the relay, aux
    // empty) and a buffer in it
    deliver(
      wireFrame(conn, msg(XSURF, 4, [serial])),
      fdmsg(conn, FD.SHM_POOL, msg(SHM_ID, 0, [POOL, 4096])),
      wireFrame(conn, msg(POOL, 0, [BUF, 0, W, H, STRIDE, SHM.XRGB8888])),
    );
    link.sent.length = 0;
    events.length = 0;
    // one commit's WIRE: attach + damage + commit
    const commitWire = () => wireFrame(conn, concat(msg(SURF, 1, [BUF, 0, 0]), msg(SURF, 9, [0, 0, W, H]), msg(SURF, 6)));
    return commitWire;
  };
  const commitWire = client(conn);
  return { engine, link, events, deliver, commitWire, conn, client };
}

function concat(...parts: Uint8Array[]) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

const ref = (handle: number, over = {}) => ({ handle, offset: 0, width: W, height: H, stride: STRIDE, format: SHM.XRGB8888, ...over });

test('encoder cross-check: HANDLE_OPEN, HANDLE_CLOSE and COMMIT match the pinned layout', () => {
  const u32 = (...v: number[]) => [...new Uint8Array(new Uint32Array(v).buffer)];
  const u64 = (v: number) => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(v), true); return [...b]; };
  assert.deepEqual([...handleOpen(3, 10, HANDLE.KWSHM, kwshmBytes(77, 2 ** 33))],
    [0x08, ...u32(3, 10, 1, 12, 77), ...u64(2 ** 33)]);
  assert.deepEqual([...handleOpen(3, 11, HANDLE.PROCFD, procfdBytes(4242, 17, 8192, 4096))],
    [0x08, ...u32(3, 11, 2, 24, 4242, 17), ...u64(8192), ...u64(4096)]);
  assert.deepEqual([...handleClose(3, 10)], [0x09, ...u32(3, 10)]);
  assert.deepEqual([...shmCommit(2, 6, 17, { handle: 4, offset: 64, width: 10, height: 5, stride: 48, format: 1 }, [[0, 0, 10, 1], [9, 4, 1, 1]])],
    [0x0a, ...u32(2, 6, 17, 2, 1, 24), ...u32(4, 64, 10, 5, 48, 1), ...u32(0, 0, 10, 1, 9, 4, 1, 1)]);
});

test('COMMIT: the damaged span is read through the source, presented as bgrx, then ACKed once', async () => {
  const mem = pixelBytes(STRIDE * H);
  const source = memorySource(new Map([[77, mem]]));
  const { engine, link, events, deliver, commitWire, conn } = await setup({ source });

  deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
    shmCommit(conn, SURF, 1, ref(5), [[2, 1, 3, 2]]));
  assert.deepEqual(source.calls[0], ['open', { kind: 'kwshm', id: 77, size: mem.length }, conn]);
  // one read: from (2,1) to the end of (4,2) — the bounding span of the damage
  assert.deepEqual(source.calls[1], ['read', 77, 1 * STRIDE + 2 * 4, STRIDE + 3 * 4]);

  const commits = events.filter((e) => e.type === 'commit');
  assert.equal(commits.length, 1);
  const c = commits[0];
  assert.equal(c.format, 'bgrx');
  assert.equal(c.stride, STRIDE);
  assert.equal(c.width, W);
  assert.equal(c.height, H);
  assert.equal(c.role, 1);
  assert.deepEqual([...c.damage], [2, 1, 3, 2]);
  assert.ok(c.pixels.length >= (H - 1) * STRIDE + W * 4);
  for (let y = 1; y < 3; y++) {
    for (let x = 2; x < 5; x++) {
      const o = y * STRIDE + x * 4;
      assert.deepEqual([...c.pixels.subarray(o, o + 4)], [...mem.subarray(o, o + 4)], `pixel ${x},${y}`);
    }
  }
  // the ACK came after the commit's dispatch, exactly once
  assert.equal(c.acksBefore, 0);
  assert.deepEqual(acks(link), [[conn, 1]]);
  assert.equal(engine.stats.commits, 1);
  for (const ev of events) assert.deepEqual(structuredClone(ev), ev);

  // a second COMMIT on the same handle: the staging buffer is reused
  deliver(commitWire(), shmCommit(conn, SURF, 2, ref(5), [[0, 0, W, H]]));
  assert.deepEqual(source.calls.at(-1), ['read', 77, 0, (H - 1) * STRIDE + W * 4]);
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]);
});

test('rgba option: the core swizzles packed RGBA per rect (bgrx alpha forced, bgra alpha kept)', async () => {
  const mem = pixelBytes(STRIDE * H);
  const source = memorySource(new Map([[77, mem]]));
  const { events, deliver, commitWire, conn } = await setup({ source, rgba: true });
  deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
    shmCommit(conn, SURF, 1, ref(5), [[0, 0, 2, 1], [6, 2, 2, 2]]),
    shmCommit(conn, SURF, 2, ref(5, { format: SHM.ARGB8888 }), [[1, 3, 1, 1]]));
  const [a, b] = events.filter((e) => e.type === 'commit');
  assert.equal(a.format, 'rgba');
  assert.equal(a.stride, 0);
  const expect = (rects: number[][], opaque: boolean) => {
    const out: number[] = [];
    for (const [x, y, w, h] of rects) {
      for (let r = 0; r < h; r++) {
        for (let i = 0; i < w; i++) {
          const o = (y + r) * STRIDE + (x + i) * 4;
          out.push(mem[o + 2], mem[o + 1], mem[o], opaque ? 255 : mem[o + 3]);
        }
      }
    }
    return out;
  };
  assert.deepEqual([...a.pixels], expect([[0, 0, 2, 1], [6, 2, 2, 2]], true));
  assert.deepEqual([...b.pixels], expect([[1, 3, 1, 1]], false));
});

test("present.ts swizzleRect (the 2D presenter's bgra/bgrx path) matches the core's wland_swizzle", async () => {
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, { env: new Proxy({}, { get: () => () => {} }) });
  const ex = exports as any;
  const stride = 52, w = 11, h = 7, off = 2 * stride + 3 * 4; // a rect at (3, 2)
  const src = new Uint8Array(stride * 10).map(() => Math.random() * 256);
  for (const opaque of [false, true]) {
    const js = new Uint8Array(w * h * 4);
    swizzleRect(src, off, stride, w, h, opaque, js);
    const p = ex.wland_alloc(src.length), q = ex.wland_alloc(js.length);
    new Uint8Array(ex.memory.buffer, p, src.length).set(src);
    ex.wland_swizzle(p + off, stride, q, w, h, opaque ? 1 : 0);
    assert.deepEqual(js, new Uint8Array(ex.memory.buffer, q, js.length).slice());
  }
});

test('unpresentable COMMITs are ACKed without a commit event', async () => {
  const mem = pixelBytes(STRIDE * H);
  const source = memorySource(new Map([[77, mem]]));
  source.read = (token) => { if (token.id === 77) throw new Error('memory gone'); };
  const { events, link, deliver, commitWire, conn } = await setup({ source });
  deliver(
    commitWire(),
    handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
    handleOpen(conn, 6, HANDLE.KWSHM, kwshmBytes(99, mem.length)),     // source refuses: broken
    handleOpen(conn, 7, 9, new Uint8Array([1, 2, 3])),                  // unknown handle kind
    handleOpen(conn + 1, 8, HANDLE.KWSHM, kwshmBytes(77, mem.length)),  // another conn's
    handleOpen(conn, 12, HANDLE.KWSHM, kwshmBytes(77, 16)),             // too small for the buffer
    shmCommit(conn, SURF, 1, ref(5), [[0, 0, 1, 1]]),                   // read throws
    shmCommit(conn, SURF, 2, ref(6), [[0, 0, 1, 1]]),                   // broken handle
    shmCommit(conn, SURF, 3, ref(7), [[0, 0, 1, 1]]),                   // unusable handle
    shmCommit(conn, SURF, 4, ref(8), [[0, 0, 1, 1]]),                   // not this conn's
    shmCommit(conn, SURF, 5, ref(11), [[0, 0, 1, 1]]),                  // never opened
    shmCommit(conn, SURF, 6, ref(12), [[0, 0, 1, 1]]),                  // past the handle's end
    shmCommit(conn, SURF, 7, ref(5, { format: 0x34325258 }), [[0, 0, 1, 1]]), // format
    shmCommit(conn, SURF, 8, ref(5), [[7, 0, 2, 1]]),                   // rect outside
    shmCommit(conn, SURF, 9, ref(5, { stride: 8 }), [[0, 0, 1, 1]]),    // stride < width*4
    // an unknown buffer kind still frames (ref_len) and is ACKed
    new Uint8Array([T.COMMIT, ...u32b(conn, SURF, 10, 1, 9, 3), 1, 2, 3, ...u32b(0, 0, 1, 1)]),
  );
  assert.equal(events.filter((e) => e.type === 'commit').length, 0);
  assert.deepEqual(acks(link), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((s) => [conn, s]));
  const errors = events.filter((e) => e.type === 'error').map((e) => e.detail);
  assert.equal(errors.length, 2, errors.join('\n')); // the refused open and the unusable kind
});

function u32b(...v: number[]) { return [...new Uint8Array(new Uint32Array(v).buffer)]; }

test('no buffer source: an error per HANDLE_OPEN, its COMMITs ACKed unpresented', async () => {
  const { events, link, deliver, commitWire, conn } = await setup({ source: undefined });
  deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, 4096)),
    handleOpen(conn, 6, HANDLE.PROCFD, procfdBytes(1, 2, 0, 4096)),
    shmCommit(conn, SURF, 1, ref(5), [[0, 0, 1, 1]]));
  const errors = events.filter((e) => e.type === 'error');
  assert.equal(errors.length, 2);
  assert.match(errors[0].detail, /no buffer source/);
  assert.equal(events.filter((e) => e.type === 'commit').length, 0);
  assert.deepEqual(acks(link), [[conn, 1]]);
});

test('async source: later frames and messages wait for each promise, in order', async () => {
  const mem = pixelBytes(STRIDE * H);
  const exports = new Map([[77, mem]]);
  // promises settled by hand
  const waiting: (() => void)[] = [];
  const calls: string[] = [];
  const source: HandleSource<{ id: number }> = {
    open(h) { calls.push('open'); return new Promise((res) => waiting.push(() => res({ id: (h as { id: number }).id }))); },
    read(t, off, dst) {
      calls.push('read');
      return new Promise((res) => waiting.push(() => { dst.set(exports.get(t.id)!.subarray(off, off + dst.length)); res(); }));
    },
    close() { calls.push('close'); },
  };
  const { engine, events, link, deliver, commitWire, conn } = await setup({ source });
  const settle = async () => { waiting.shift()!(); await new Promise((r) => setTimeout(r, 0)); };
  const kinds = () => events.filter((e) => e.type === 'commit' || e.type === 'title').map((e) => e.type === 'title' ? e.title : e.surface);

  // the first commit also latches a frame callback (new id 20)
  const withFrame = wireFrame(conn, concat(msg(SURF, 3, [20]), msg(SURF, 1, [BUF, 0, 0]), msg(SURF, 9, [0, 0, W, H]), msg(SURF, 6)));
  const done = () => sentFrames(link).some((f) => f.type === 'wire' && (() => {
    let hit = false;
    wlEach(f.bytes, (obj: number, op: number) => { if (obj === 20 && op === 0) hit = true; });
    return hit;
  })());
  deliver(withFrame, handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
    shmCommit(conn, SURF, 1, ref(5), [[0, 0, W, H]]),
    wireFrame(conn, msg(TOP, 2, ['after-1'])));
  deliver(commitWire(), shmCommit(conn, SURF, 2, ref(5), [[0, 0, 1, 1]]), wireFrame(conn, msg(TOP, 2, ['after-2'])));
  assert.deepEqual(calls, ['open']);
  assert.deepEqual(kinds(), []);
  // input carries on while frames wait; tick fires no frame callbacks
  engine.key(conn, 1, 30, true);
  engine.tick(16);
  assert.equal(done(), false, 'frame callback fired while presentation is stalled');

  await settle(); // open resolves → the COMMIT reads
  assert.deepEqual(calls, ['open', 'read']);
  assert.deepEqual(kinds(), []);
  assert.deepEqual(acks(link), []);

  await settle(); // read resolves → commit 1 presented + ACKed, title, next COMMIT reads
  assert.deepEqual(kinds(), [SURF, 'after-1']);
  assert.deepEqual(acks(link), [[conn, 1]]);
  assert.deepEqual(calls, ['open', 'read', 'read']);

  await settle();
  assert.deepEqual(kinds(), [SURF, 'after-1', SURF, 'after-2']);
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]);
  assert.equal(waiting.length, 0);
  engine.tick(32);
  assert.equal(done(), true, 'frame callback fires at the first tick once unstalled');
});

test('handles close exactly once: HANDLE_CLOSE, CONN_CLOSE, link close', async () => {
  const mem = pixelBytes(STRIDE * H);
  const source = memorySource(new Map([[1, mem], [2, mem], [3, mem], [4, mem]]));
  const { link, deliver, conn } = await setup({ source });
  deliver(connOpen(conn + 1),
    handleOpen(conn, 1, HANDLE.KWSHM, kwshmBytes(1, 64)),
    handleOpen(conn, 2, HANDLE.KWSHM, kwshmBytes(2, 64)),
    handleOpen(conn + 1, 3, HANDLE.KWSHM, kwshmBytes(3, 64)),
    handleOpen(conn + 1, 4, HANDLE.KWSHM, kwshmBytes(4, 64)));
  const closed = () => source.calls.filter((c) => c[0] === 'close').map((c) => c[1]);
  deliver(handleClose(conn, 1), handleClose(conn, 1), handleClose(conn + 1, 2), handleClose(conn, 42));
  assert.deepEqual(closed(), [1]); // repeat, wrong conn and unknown ids ignored
  deliver(connClose(conn));
  assert.deepEqual(closed(), [1, 2]);
  link.cb.onClose({ takenOver: false });
  assert.deepEqual(closed(), [1, 2, 3, 4]);
  assert.equal(source.live.size, 0);
});

test('an async open that settles after the link closed is closed, never used', async () => {
  let resolve!: (token: string) => void;
  const calls: unknown[] = [];
  const source: HandleSource<string> = {
    open() { return new Promise((r) => { resolve = r; }); },
    read() { calls.push('read'); },
    close(t) { calls.push(['close', t]); },
  };
  const { link, deliver, conn } = await setup({ source });
  deliver(handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, 4096)), shmCommit(conn, SURF, 1, ref(5), [[0, 0, 1, 1]]));
  link.cb.onClose({ takenOver: false });
  resolve('token');
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(calls, [['close', 'token']]);
});

test('reads: one per damage span (merged within 4 KiB); one in all once the source is async', async () => {
  const tall = { width: W, height: 300, stride: STRIDE }; // 12000 bytes
  const mem = pixelBytes(STRIDE * 300);
  for (const async of [false, true]) {
    const source = memorySource(new Map([[77, mem]]), { async });
    const { events, link, deliver, commitWire, conn } = await setup({ source });
    deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
      shmCommit(conn, SURF, 1, ref(5, tall), [[0, 0, 1, 1]]),                            // learns sync/async
      shmCommit(conn, SURF, 2, ref(5, tall), [[0, 299, 2, 1], [1, 0, 1, 2], [3, 1, 1, 1]]));
    for (let i = 0; i < 10; i++) await new Promise((r) => setTimeout(r, 0));
    const reads = source.calls.filter((c) => c[0] === 'read').slice(1).map((c) => [c[2], c[3]]);
    assert.deepEqual(reads, async
      ? [[4, 299 * STRIDE + 8 - 4]]                       // one span over all three rects
      : [[4, STRIDE + 16 - 4], [299 * STRIDE, 8]]);       // the two nearby rects merged, the far one alone
    const c = events.filter((e) => e.type === 'commit')[1];
    for (const o of [299 * STRIDE, 299 * STRIDE + 4, 4, STRIDE + 4, STRIDE + 12]) {
      assert.deepEqual([...c.pixels.subarray(o, o + 4)], [...mem.subarray(o, o + 4)], `byte ${o}`);
    }
    assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]);
  }
});

test('dispose: the link is closed, every token closed once, nothing emitted or sent after', async () => {
  const mem = pixelBytes(STRIDE * H);
  const source = memorySource(new Map([[1, mem], [2, mem]]));
  const { engine, link, events, deliver, commitWire, conn } = await setup({ source });
  let closes = 0;
  link.close = () => { closes++; };
  deliver(handleOpen(conn, 1, HANDLE.KWSHM, kwshmBytes(1, 64)), handleOpen(conn, 2, HANDLE.KWSHM, kwshmBytes(2, mem.length)));
  events.length = 0;
  link.sent.length = 0;

  engine.dispose();
  engine.dispose();
  assert.equal(closes, 1);
  assert.equal(source.live.size, 0);
  assert.deepEqual(source.calls.filter((c) => c[0] === 'close').map((c) => c[1]), [1, 2]);
  // a link that keeps calling back, and calls into the engine: all no-ops
  deliver(commitWire(), shmCommit(conn, SURF, 1, ref(2), [[0, 0, 1, 1]]), connClose(conn));
  link.cb.onError('late');
  link.cb.onClose({ takenOver: false });
  link.cb.onOpen();
  engine.key(conn, 1, 30, true);
  engine.setOutput(100, 100);
  engine.tick(16);
  assert.deepEqual(events, []);
  assert.deepEqual(link.sent, []);
  assert.equal(source.calls.filter((c) => c[0] === 'read').length, 0);
});

test('a token is never closed under a pending read: the link closing mid-read closes it once the read settles', async () => {
  const mem = pixelBytes(STRIDE * H);
  for (const outcome of ['resolve', 'reject']) {
    let settle!: () => void;
    const calls: string[] = [];
    const source: HandleSource<{ id: number }> = {
      open: (h) => ({ id: (h as { id: number }).id }),
      read(t) { calls.push('read'); return new Promise<void>((res, rej) => { settle = outcome === 'resolve' ? res : () => rej(new Error('gone')); }); },
      close(t) { calls.push('close'); },
    };
    const { engine, link, events, deliver, commitWire, conn } = await setup({ source });
    deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)), shmCommit(conn, SURF, 1, ref(5), [[0, 0, 1, 1]]));
    assert.deepEqual(calls, ['read']);
    link.cb.onClose({ takenOver: false });
    assert.deepEqual(calls, ['read'], `${outcome}: not closed while its read is pending`);
    settle();
    await new Promise((r) => setTimeout(r, 0));
    assert.deepEqual(calls, ['read', 'close'], `${outcome}: closed once it settled`);
    assert.equal(events.filter((e) => e.type === 'commit').length, 0);
    assert.deepEqual(acks(link), []); // the link is gone: nothing to ACK on
    // dispose meanwhile changes nothing: still exactly once
    engine.dispose();
    assert.deepEqual(calls, ['read', 'close']);
  }
});

test('conn ids ≥ 2^31 (wasm hands u32 over as i32): events carry them unsigned, CONN_CLOSE closes their handles', async () => {
  const mem = pixelBytes(STRIDE * H);
  const source = memorySource(new Map([[77, mem]]));
  const conn = 0x80000001;
  const { events, deliver } = await setup({ conn, source });
  deliver(handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)), wireFrame(conn, msg(TOP, 2, ['big'])));
  assert.deepEqual(events.find((e) => e.type === 'title'), { type: 'title', conn, surface: SURF, title: 'big' });
  deliver(connClose(conn));
  assert.equal(source.live.size, 0, 'the conn\'s handle was closed');
  assert.deepEqual(events.at(-1), { type: 'disconnect', conn });
});

// --- HandleSource.readv / view: the batched and the in-place shapes --------

const TALL = { width: W, height: 300, stride: STRIDE }; // 12000 bytes
// three rects: two near the top (one merged span), one at the bottom
const SPREAD = [[0, 299, 2, 1], [1, 0, 1, 2], [3, 1, 1, 1]];
const SPREAD_SPANS = [[4, STRIDE + 16 - 4], [299 * STRIDE, 8]]; // [offset, length], ascending
const SPREAD_BYTES = [299 * STRIDE, 299 * STRIDE + 4, 4, STRIDE + 4, STRIDE + 12];
const ticks = async (n = 10) => { for (let i = 0; i < n; i++) await new Promise((r) => setTimeout(r, 0)); };
function assertSpread(c: any, mem: Uint8Array) {
  for (const o of SPREAD_BYTES) assert.deepEqual([...c.pixels.subarray(o, o + 4)], [...mem.subarray(o, o + 4)], `byte ${o}`);
}

test('readv: all spans of a COMMIT in one call (sync or one promise), read() never called', async () => {
  const mem = pixelBytes(STRIDE * 300);
  for (const async of [false, true]) {
    const calls: any[] = [];
    const waiting: (() => void)[] = [];
    const source: HandleSource<{ id: number }> = {
      open: (h) => ({ id: (h as { id: number }).id }),
      read() { throw new Error('read() called beside readv()'); },
      readv(token, reads) {
        calls.push(reads.map((r) => [r.offset, r.dst.length]));
        const copy = () => { for (const r of reads) r.dst.set(mem.subarray(r.offset, r.offset + r.dst.length)); };
        if (!async) return copy();
        return new Promise<void>((res) => waiting.push(() => { copy(); res(); }));
      },
      close() {},
    };
    const { events, link, deliver, commitWire, conn } = await setup({ source });
    deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
      shmCommit(conn, SURF, 1, ref(5, TALL), SPREAD),
      wireFrame(conn, msg(TOP, 2, ['after-1'])),
      commitWire(), shmCommit(conn, SURF, 2, ref(5, TALL), [[0, 0, 1, 1]]));
    const titles = () => events.filter((e) => e.type === 'title').map((e) => e.title);
    if (async) {
      // one promise for the commit: the frames after it wait, in order
      assert.deepEqual(calls, [SPREAD_SPANS]);
      assert.deepEqual(titles(), []);
      assert.deepEqual(acks(link), []);
      waiting.shift()!();
      await ticks();
      assert.deepEqual(titles(), ['after-1']);
      assert.deepEqual(acks(link), [[conn, 1]]);
      waiting.shift()!();
      await ticks();
    }
    // the far rect is NOT merged into one span over everything (async or not)
    assert.deepEqual(calls, [SPREAD_SPANS, [[0, 4]]]);
    const commits = events.filter((e) => e.type === 'commit');
    assert.equal(commits.length, 2);
    assertSpread(commits[0], mem);
    assert.deepEqual(acks(link), [[conn, 1], [conn, 2]], `async ${async}`);
  }
});

test('readv: a throw or a rejection skips the commit (ACKed), a close waits for the pending call', async () => {
  const mem = pixelBytes(STRIDE * H);
  const calls: string[] = [];
  let settle!: () => void;
  const source: HandleSource<{ id: number }> = {
    open: (h) => ({ id: (h as { id: number }).id }),
    read() { throw new Error('unused'); },
    readv(t) {
      calls.push(`readv ${t.id}`);
      if (t.id === 1) throw new Error('memory gone');
      if (t.id === 2) return Promise.reject(new Error('gone too'));
      return new Promise<void>((res) => { settle = res; });
    },
    close(t) { calls.push(`close ${t.id}`); },
  };
  const { events, link, deliver, commitWire, conn } = await setup({ source });
  deliver(commitWire(),
    handleOpen(conn, 1, HANDLE.KWSHM, kwshmBytes(1, mem.length)),
    handleOpen(conn, 2, HANDLE.KWSHM, kwshmBytes(2, mem.length)),
    handleOpen(conn, 3, HANDLE.KWSHM, kwshmBytes(3, mem.length)),
    shmCommit(conn, SURF, 1, ref(1), [[0, 0, 1, 1]]),
    shmCommit(conn, SURF, 2, ref(2), [[0, 0, 1, 1]]),
    shmCommit(conn, SURF, 3, ref(3), [[0, 0, 1, 1]]));
  await ticks();
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]);
  assert.deepEqual(calls, ['readv 1', 'readv 2', 'readv 3']);
  // the link closes with handle 3's readv pending: 1 and 2 close now, 3 once it settles
  link.cb.onClose({ takenOver: false });
  assert.deepEqual(calls.slice(3).sort(), ['close 1', 'close 2']);
  settle();
  await ticks();
  assert.deepEqual(calls.slice(5), ['close 3']);
  assert.equal(events.filter((e) => e.type === 'commit').length, 0);
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]); // nothing ACKed on a closed link
});

test('view: one view is the commit\'s pixels with no copy (bgrx), the core swizzles from it (rgba); no reads', async () => {
  const mem = pixelBytes(STRIDE * 300);
  for (const rgba of [false, true]) {
    const calls: any[] = [];
    const source: HandleSource<{ id: number }> = {
      open: (h) => ({ id: (h as { id: number }).id }),
      read() { throw new Error('read() called beside view()'); },
      readv() { throw new Error('readv() called beside view()'); },
      view(t, offset, length) { calls.push([t.id, offset, length]); return mem.subarray(offset, offset + length); },
      close() {},
    };
    let same = false;
    const { events, link, deliver, commitWire, conn } = await setup({ source, rgba, peek: (ev) => { same = ev.pixels.buffer === mem.buffer; } });
    deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
      shmCommit(conn, SURF, 1, ref(5, { ...TALL, offset: 40, height: 299 }), SPREAD.slice(1)));
    // the buffer's extent: its first byte to its last pixel's
    assert.deepEqual(calls, [[77, 40, 298 * STRIDE + W * 4]]);
    const [c] = events.filter((e) => e.type === 'commit');
    if (!rgba) {
      assert.equal(same, true, 'pixels view the source\'s memory');
      assert.equal(c.format, 'bgrx');
      assert.equal(c.pixels.length, 298 * STRIDE + W * 4);
      assert.deepEqual([...c.pixels.subarray(4, 8)], [...mem.subarray(44, 48)]);
    } else {
      assert.equal(same, false);
      assert.equal(c.format, 'rgba');
      // rects (1,0,1,2) then (3,1,1,1), packed, X forced opaque
      const px = (x: number, y: number) => { const o = 40 + y * STRIDE + x * 4; return [mem[o + 2], mem[o + 1], mem[o], 255]; };
      assert.deepEqual([...c.pixels], [...px(1, 0), ...px(1, 1), ...px(3, 1)]);
    }
    assert.deepEqual(acks(link), [[conn, 1]]);
  }
});

test('view: scattered page runs are gathered (damaged spans only); a SharedArrayBuffer view is passed through', async () => {
  const mem = pixelBytes(STRIDE * 300);
  // the export as page runs at odd places of a shared "kernel memory"
  const kernel = new Uint8Array(new SharedArrayBuffer(20000));
  const runs: { at: number; off: number; len: number }[] = [
    { at: 9000, off: 0, len: 4096 }, { at: 100, off: 4096, len: 4096 }, { at: 15000, off: 8192, len: 12000 - 8192 },
  ];
  for (const r of runs) kernel.set(mem.subarray(r.off, r.off + r.len), r.at);
  const pages = (offset: number, length: number) => {
    const out: Uint8Array[] = [];
    for (const r of runs) {
      const s = Math.max(offset, r.off), e = Math.min(offset + length, r.off + r.len);
      if (s < e) out.push(kernel.subarray(r.at + s - r.off, r.at + e - r.off));
    }
    return out;
  };
  let whole = false;
  const source: HandleSource<{ id: number }> = {
    open: (h) => ({ id: (h as { id: number }).id }),
    read() { throw new Error('unused'); },
    view: (t, offset, length) => whole ? new Uint8Array(kernel.buffer, 0, length) : pages(offset, length),
    close() {},
  };
  let shared = false;
  const { events, link, deliver, commitWire, conn } = await setup({ source, peek: (ev) => { shared = ev.pixels.buffer instanceof SharedArrayBuffer; } });
  deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
    // rects that straddle the run boundaries at 4096 and 8192
    shmCommit(conn, SURF, 1, ref(5, TALL), [...SPREAD, [0, 101, 8, 2], [2, 204, 3, 1]]));
  const [c] = events.filter((e) => e.type === 'commit');
  assert.equal(shared, false, 'gathered into the staging buffer');
  assertSpread(c, mem);
  for (const [x, y, w, h] of [[0, 101, 8, 2], [2, 204, 3, 1]]) {
    for (let r = 0; r < h; r++) {
      const o = (y + r) * STRIDE + x * 4;
      assert.deepEqual([...c.pixels.subarray(o, o + w * 4)], [...mem.subarray(o, o + w * 4)], `rect at ${x},${y + r}`);
    }
  }
  whole = true;
  deliver(commitWire(), shmCommit(conn, SURF, 2, ref(5, TALL), [[0, 0, 1, 1]]));
  assert.equal(shared, true, 'one view: no copy, shared memory and all');
  const c2 = events.filter((e) => e.type === 'commit')[1];
  assert.equal(c2.pixels.buffer instanceof SharedArrayBuffer, false, 'slice() of it is an ordinary copy');
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]);
});

test('view: null falls back to readv/read for that commit; a throw or a short view skips it (ACKed)', async () => {
  const mem = pixelBytes(STRIDE * H);
  const calls: string[] = [];
  let answer: 'null' | 'throw' | 'short' | 'many-short' = 'null';
  const base = memorySource(new Map([[77, mem]]));
  const source: HandleSource<MemToken> = {
    open: base.open,
    read(t, o, d) { calls.push('read'); return base.read(t, o, d); },
    view(t, offset, length) {
      calls.push(`view ${answer}`);
      if (answer === 'throw') throw new Error('export released');
      if (answer === 'short') return t.mem.subarray(offset, offset + length - 1);
      if (answer === 'many-short') return [t.mem.subarray(offset, offset + 4), t.mem.subarray(offset + 8, offset + length)];
      return null;
    },
    close: base.close,
  };
  const { events, link, deliver, commitWire, conn } = await setup({ source });
  deliver(commitWire(), handleOpen(conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)), shmCommit(conn, SURF, 1, ref(5), [[0, 0, 2, 1]]));
  assert.deepEqual(calls, ['view null', 'read']);
  assert.deepEqual([...events.filter((e) => e.type === 'commit')[0].pixels.subarray(0, 8)], [...mem.subarray(0, 8)]);
  for (const a of ['throw', 'short', 'many-short'] as const) {
    answer = a;
    deliver(commitWire(), shmCommit(conn, SURF, 2, ref(5), [[0, 0, 1, 1]]));
  }
  assert.deepEqual(calls.slice(2), ['view throw', 'view short', 'view many-short']);
  assert.equal(events.filter((e) => e.type === 'commit').length, 1);
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2], [conn, 2], [conn, 2]]);
});

// --- GPU buffers: COMMIT kind virtgpu (STREAM.md), EngineOptions.gpu -------

const XBGR8888 = 0x34324258, MOD_INVALID = 0x00ffffffffffffffn;
const gref = (resource: number, over: Partial<GpuRef> = {}) =>
  ({ resource, width: W, height: H, format: XBGR8888, flags: 0, offset: 0, stride: W * 4, modifier: MOD_INVALID, ...over });

test('virtgpu COMMIT: resolved during the walk, dispatched with the ref and the image, released, then ACKed once', async () => {
  const calls: any[] = [];
  const image = { tag: 'bitmap' };
  const gpu: GpuSource<typeof image> = {
    resolve(ref, commit) { calls.push(['resolve', ref, commit.conn, commit.surface, [...commit.damage]]); return image; },
    release(img) { calls.push(['release', img]); },
  };
  const { events, link, deliver, commitWire, conn } = await setup({ gpu });
  deliver(commitWire(), virtgpuCommit(conn, SURF, 1, gref(42, { flags: 1 }), [[0, 0, W, H], [1, 1, 2, 2]]));
  const ref: GpuRef = { kind: 'virtgpu', ...gref(42, { flags: 1 }) };
  assert.deepEqual(calls[0], ['resolve', ref, conn, SURF, [0, 0, W, H, 1, 1, 2, 2]]);
  const [c] = events.filter((e) => e.type === 'commit');
  assert.equal(c.format, 'gpu');
  assert.deepEqual(c.gpu, ref);
  assert.equal(c.image, image);
  assert.equal(c.pixels.length, 0);
  assert.deepEqual([c.width, c.height, c.logicalWidth, c.logicalHeight, c.stride], [W, H, W, H, 0]);
  assert.deepEqual([...c.damage], [0, 0, W, H, 1, 1, 2, 2]);
  assert.equal(c.acksBefore, 0, 'the ACK follows the dispatch');
  assert.deepEqual(calls[1], ['release', image], 'released after the dispatch');
  assert.deepEqual(acks(link), [[conn, 1]]);
});

test('virtgpu COMMIT without a gpu source: one error, each commit still laid out (image null) and ACKed', async () => {
  const { events, link, deliver, commitWire, conn } = await setup();
  deliver(commitWire(), virtgpuCommit(conn, SURF, 1, gref(42), [[0, 0, W, H]]),
    commitWire(), virtgpuCommit(conn, SURF, 2, gref(43), [[0, 0, 1, 1]]));
  const errors = events.filter((e) => e.type === 'error');
  assert.equal(errors.length, 1);
  assert.match(errors[0].detail, /no gpu source/);
  const commits = events.filter((e) => e.type === 'commit');
  assert.deepEqual(commits.map((e) => [e.format, e.gpu.resource, e.image]), [['gpu', 42, null], ['gpu', 43, null]]);
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]);
});

test('virtgpu: a promise stalls later frames until it settles; throwing, rejecting or null shows nothing new; invalid refs are ACKed unseen', async () => {
  const waiting: (() => void)[] = [];
  const released: unknown[] = [];
  const gpu: GpuSource<string> = {
    resolve(ref) {
      if (ref.resource === 1) return new Promise((res) => waiting.push(() => res('late')));
      if (ref.resource === 2) throw new Error('no such resource');
      if (ref.resource === 3) return Promise.reject(new Error('gone'));
      return null;
    },
    release(img) { released.push(img); },
  };
  const { events, link, deliver, commitWire, conn } = await setup({ gpu });
  deliver(commitWire(), virtgpuCommit(conn, SURF, 1, gref(1), [[0, 0, W, H]]), wireFrame(conn, msg(TOP, 2, ['after'])));
  const titles = () => events.filter((e) => e.type === 'title').map((e) => e.title);
  assert.deepEqual(titles(), [], 'the title frame waits for the promise');
  assert.deepEqual(acks(link), []);
  waiting.shift()!();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(titles(), ['after']);
  assert.deepEqual(events.filter((e) => e.type === 'commit').map((e) => e.image), ['late']);
  assert.deepEqual(released, ['late']);
  assert.deepEqual(acks(link), [[conn, 1]]);

  deliver(
    commitWire(), virtgpuCommit(conn, SURF, 2, gref(2), [[0, 0, 1, 1]]),   // throws
    commitWire(), virtgpuCommit(conn, SURF, 3, gref(3), [[0, 0, 1, 1]]),   // rejects
    commitWire(), virtgpuCommit(conn, SURF, 4, gref(4), [[0, 0, 1, 1]]),   // null
    virtgpuCommit(conn, SURF, 5, gref(0), [[0, 0, 1, 1]]),                 // resource 0: invalid
    virtgpuCommit(conn, SURF, 6, gref(5), [[W - 1, 0, 2, 1]]),             // rect outside
  );
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(events.filter((e) => e.type === 'commit').map((e) => [e.gpu.resource, e.image]),
    [[1, 'late'], [2, null], [3, null], [4, null]]);
  assert.deepEqual(released, ['late'], 'nothing to release for null');
  assert.deepEqual(acks(link).map(([, s]) => s).sort(), [1, 2, 3, 4, 5, 6]);
});

// --- a link reset while a buffer-source / gpu promise is pending -----------

// a readv/read source whose every call is a promise settled by hand; each
// read fills its spans with the token's id, and a token must never close
// under its pending call
function handSource(kind: 'readv' | 'read') {
  const pend: { id: number; settle: () => void }[] = [];
  const violations: string[] = [];
  const closed: number[] = [];
  const fill = (t: any, dsts: Uint8Array[], res: () => void) => pend.push({ id: t.id, settle: () => {
    for (const d of dsts) d.fill(t.id);
    t.busy--;
    res();
  } });
  const source: HandleSource<{ id: number; busy: number }> = {
    open: (h) => ({ id: (h as Extract<BufferHandle, { kind: 'kwshm' }>).id, busy: 0 }),
    read(t, _offset, dst) {
      if (kind !== 'read') throw new Error('unused');
      t.busy++;
      return new Promise<void>((res) => fill(t, [dst], res));
    },
    close(t) {
      closed.push(t.id);
      if (t.busy) violations.push(`token ${t.id} closed while its read is pending`);
    },
  };
  if (kind === 'readv') source.readv = (t, reads) => {
    t.busy++;
    return new Promise<void>((res) => fill(t, reads.map((r) => r.dst), res));
  };
  return { source, pend, violations, closed };
}

for (const kind of ['readv', 'read'] as const) {
  test(`${kind}: a read pending when the link resets writes nowhere the next link reads; settling never clobbers the next link's read`, async () => {
    const { source, pend, violations, closed } = handSource(kind);
    const firstPixel: number[] = []; // each commit's first byte, as dispatched
    const s = await setup({ source, peek: (ev) => firstPixel.push(ev.pixels[0]) });
    const size = STRIDE * H;
    s.deliver(s.commitWire(), handleOpen(s.conn, 1, HANDLE.KWSHM, kwshmBytes(1, size)), shmCommit(s.conn, SURF, 1, ref(1), [[0, 0, 1, 1]]));
    assert.equal(pend.length, 1, 'link 1: read pending');
    s.link.cb.onClose({ takenOver: false });
    s.link.cb.onOpen();
    const cw = s.client(2);
    s.deliver(cw(), handleOpen(2, 2, HANDLE.KWSHM, kwshmBytes(2, size)), shmCommit(2, SURF, 1, ref(2), [[0, 0, 1, 1]]));
    assert.deepEqual(pend.map((p) => p.id), [1, 2], 'link 2: its own read pending too');

    // (a) the new link's read lands, then the dead link's: the new commit
    // must show the new link's bytes (2), not the dead link's (1)
    pend[1].settle();
    pend[0].settle();
    await ticks();
    assert.deepEqual(firstPixel, [2]);
    assert.deepEqual(acks(s.link), [[2, 1]], 'only the live link\'s commit is ACKed');
    assert.deepEqual(closed, [1], 'the dead link\'s token closed once its read settled');

    // (b) the dead link's read settles first, while the new one's is pending:
    // dispose must still wait for the new one before closing its token
    s.deliver(cw(), shmCommit(2, SURF, 2, ref(2), [[0, 0, 1, 1]]));
    s.link.cb.onClose({ takenOver: false });
    s.link.cb.onOpen();
    const cw3 = s.client(3);
    s.deliver(cw3(), handleOpen(3, 3, HANDLE.KWSHM, kwshmBytes(3, size)), shmCommit(3, SURF, 1, ref(3), [[0, 0, 1, 1]]));
    assert.deepEqual(pend.slice(2).map((p) => p.id), [2, 3]);
    pend[2].settle(); // the dead link's (token 2)
    await ticks();
    s.engine.dispose(); // token 3's read still pending
    assert.deepEqual(violations, []);
    assert.deepEqual(closed, [1, 2], 'token 3 waits for its read');
    pend[3].settle();
    await ticks();
    assert.deepEqual(closed, [1, 2, 3]);
    assert.deepEqual(violations, []);
    assert.deepEqual(firstPixel, [2], 'nothing presented after the reset or dispose');
  });
}

test('virtgpu: a resolve pending when the link resets is neither dispatched nor ACKed on the next link, and its image is still released', async () => {
  const waiting: ((img: string) => void)[] = [];
  const released: unknown[] = [];
  const gpu: GpuSource<string> = {
    resolve: () => new Promise((res) => waiting.push(res)),
    release(img) { released.push(img); },
  };
  const s = await setup({ gpu });
  s.deliver(s.commitWire(), virtgpuCommit(s.conn, SURF, 1, gref(1), [[0, 0, W, H]]));
  assert.equal(waiting.length, 1);
  s.link.cb.onClose({ takenOver: false });
  s.link.cb.onOpen();
  const cw = s.client(2);
  s.deliver(cw(), virtgpuCommit(2, SURF, 1, gref(2), [[0, 0, W, H]]), wireFrame(2, msg(TOP, 2, ['after'])));
  assert.equal(waiting.length, 2);
  waiting[0]('stale'); // the dead link's settles while the new link waits on its own
  await ticks();
  const commits = () => s.events.filter((e) => e.type === 'commit').map((e) => [e.conn, e.image]);
  assert.deepEqual(commits(), []);
  assert.deepEqual(acks(s.link), []);
  assert.deepEqual(released, ['stale']);
  assert.deepEqual(s.events.filter((e) => e.type === 'title').map((e) => e.title), [], 'the new link still waits');
  waiting[1]('fresh');
  await ticks();
  assert.deepEqual(commits(), [[2, 'fresh']]);
  assert.deepEqual(acks(s.link), [[2, 1]]);
  assert.deepEqual(released, ['stale', 'fresh']);
  assert.deepEqual(s.events.filter((e) => e.type === 'title').map((e) => e.title), ['after']);
  // dispose with one pending: released when it settles, nothing dispatched
  s.deliver(cw(), virtgpuCommit(2, SURF, 2, gref(3), [[0, 0, W, H]]));
  s.engine.dispose();
  waiting[2]('orphan');
  await ticks();
  assert.deepEqual(released, ['stale', 'fresh', 'orphan']);
  assert.deepEqual(commits(), [[2, 'fresh']]);
});

// --- a COMMIT that showed nothing: the relay believes it was shown ---------

test('after a COMMIT that showed nothing (null, throw, no resolver; a failed read) the surface\'s next COMMIT is whole, for the resolver and the event; then the relay\'s damage again', async () => {
  let answer: 'img' | 'null' | 'throw' = 'img';
  const seen: number[][] = [];
  const gpu: GpuSource<string> = {
    resolve(_ref, c) {
      seen.push([...c.damage]);
      if (answer === 'throw') throw new Error('lost');
      return answer === 'img' ? 'img' : null;
    },
  };
  const { events, link, deliver, commitWire, conn } = await setup({ gpu });
  const damages = () => events.filter((e) => e.type === 'commit').map((e) => [...e.damage]);
  const send = (serial: number, rect: number[], a: typeof answer = 'img') => {
    answer = a;
    deliver(commitWire(), virtgpuCommit(conn, SURF, serial, gref(1 + (serial % 2)), [rect]));
  };
  send(1, [0, 0, W, H]);         // the first: whole (the relay's rule)
  send(2, [1, 1, 2, 2]);         // shown: damage as sent
  send(3, [2, 0, 1, 1], 'null'); // nothing new shown
  send(4, [3, 1, 1, 1]);         // → whole
  send(5, [3, 1, 1, 1]);         // up to date again: as sent
  send(6, [0, 0, 1, 1], 'throw');
  send(7, [0, 0, 1, 1]);         // → whole
  const whole = [0, 0, W, H];
  const want = [whole, [1, 1, 2, 2], [2, 0, 1, 1], whole, [3, 1, 1, 1], [0, 0, 1, 1], whole];
  assert.deepEqual(seen, want);
  assert.deepEqual(damages(), want);
  assert.deepEqual(acks(link).map(([, s]) => s), [1, 2, 3, 4, 5, 6, 7]);
});

test('no gpu source: every GPU commit shows nothing, so each one after the first is whole too; a failed shm read makes the next shm COMMIT whole', async () => {
  const { events, deliver, commitWire, conn } = await setup();
  deliver(commitWire(), virtgpuCommit(conn, SURF, 1, gref(1), [[0, 0, W, H]]),
    commitWire(), virtgpuCommit(conn, SURF, 2, gref(1), [[1, 1, 1, 1]]));
  assert.deepEqual(events.filter((e) => e.type === 'commit').map((e) => [...e.damage]), [[0, 0, W, H], [0, 0, W, H]]);

  const mem = pixelBytes(STRIDE * H);
  let fail = true;
  const base = memorySource(new Map([[77, mem]]));
  const source: HandleSource<MemToken> = {
    open: base.open, close: base.close,
    read(t, o, d) { if (fail) throw new Error('export gone'); return base.read(t, o, d); },
  };
  const s = await setup({ source });
  s.deliver(s.commitWire(), handleOpen(s.conn, 5, HANDLE.KWSHM, kwshmBytes(77, mem.length)),
    shmCommit(s.conn, SURF, 1, ref(5), [[0, 0, W, H]]));
  fail = false;
  s.deliver(s.commitWire(), shmCommit(s.conn, SURF, 2, ref(5), [[2, 1, 1, 1]]),
    s.commitWire(), shmCommit(s.conn, SURF, 3, ref(5), [[2, 1, 1, 1]]));
  const commits = s.events.filter((e) => e.type === 'commit');
  assert.deepEqual(commits.map((e) => [...e.damage]), [[0, 0, W, H], [2, 1, 1, 1]], 'serial 1 failed: serial 2 whole, serial 3 as sent');
  assert.deepEqual([...commits[0].pixels.subarray(0, (H - 1) * STRIDE + W * 4)], [...mem.subarray(0, (H - 1) * STRIDE + W * 4)]);
  assert.deepEqual(acks(s.link).map(([, n]) => n), [1, 2, 3]);
});

test('2D view through the engine: the image after one that never came is drawn whole, not just the damaged rect over the stale canvas', async () => {
  const dom = installFakeDom();
  try {
    const view = createView({ container: dom.container(), webgl: 'never' });
    const images: Record<number, { width: number; height: number } | null> = { 1: { width: W, height: H }, 2: null, 3: { width: W, height: H } };
    const gpu: GpuSource = { resolve: (ref) => images[ref.resource] };
    const { deliver, commitWire, conn } = await setup({ gpu, peek: (ev) => view.handle(ev) });
    deliver(commitWire(), virtgpuCommit(conn, SURF, 1, gref(1), [[0, 0, W, H]]));
    const canvas = view.canvas(conn, SURF) as any;
    assert.deepEqual(canvas.draws, [['clear', 0, 0, W, H], ['draw', images[1], 0, 0, W, H, 0, 0, W, H]], 'the first: whole');
    canvas.draws.length = 0;
    deliver(commitWire(), virtgpuCommit(conn, SURF, 2, gref(2), [[0, 0, 2, 2]])); // resolves to nothing
    assert.deepEqual(canvas.draws, [], 'the canvas keeps resource 1\'s content');
    deliver(commitWire(), virtgpuCommit(conn, SURF, 3, gref(3), [[6, 3, 1, 1]]));
    assert.deepEqual(canvas.draws, [['clear', 0, 0, W, H], ['draw', images[3], 0, 0, W, H, 0, 0, W, H]],
      'resource 2\'s changes (0,0 2x2) were never drawn: the whole image, not just (6,3)');
    canvas.draws.length = 0;
    deliver(commitWire(), virtgpuCommit(conn, SURF, 4, gref(3), [[6, 3, 1, 1]]));
    assert.deepEqual(canvas.draws, [['clear', 6, 3, 1, 1], ['draw', images[3], 6, 3, 1, 1, 6, 3, 1, 1]], 'then the damage again');
  } finally {
    dom.uninstall();
  }
});

// --- external buffers: COMMIT kind external (STREAM.md), GpuSource.resolveExternal

const ARGB8888 = 0x34325241;
// ids past 2^53 with bit 63 set: a Number-based assembly would lose or sign them
const BIG = 0x8000_0001_2345_6789n;
const xref = (id: bigint, over: Partial<ExternalRef> = {}): ExternalRef => ({ id, width: W, height: H, format: XBGR8888, flags: 0, ...over });

test('encoder cross-check: an external COMMIT matches the pinned layout', () => {
  const u32 = (...v: number[]) => [...new Uint8Array(new Uint32Array(v).buffer)];
  assert.deepEqual([...externalCommit(2, 6, 17, xref(0x0102030405060708n, { flags: 1 }), [[0, 0, 1, 1]])],
    [0x0a, ...u32(2, 6, 17, 1, 3, 24), 8, 7, 6, 5, 4, 3, 2, 1, ...u32(W, H, XBGR8888, 1), ...u32(0, 0, 1, 1)]);
});

test('external COMMIT: resolveExternal gets the ref (a u64 id, high bit set) and the commit; dispatched with `external` and the image, released, then ACKed once; resolve is never asked', async () => {
  const calls: any[] = [];
  const image = { tag: 'frame' };
  const gpu: GpuSource<typeof image> = {
    resolve() { calls.push(['resolve']); return null; },
    resolveExternal(ref, commit) { calls.push(['resolveExternal', ref, commit.conn, commit.surface, [...commit.damage]]); return image; },
    release(img) { calls.push(['release', img]); },
  };
  const { events, link, deliver, commitWire, conn } = await setup({ gpu });
  for (const [serial, id] of [[1, BIG], [2, 0xffff_ffff_ffff_ffffn], [3, 0x1_0000_0000n]] as const) {
    deliver(commitWire(), externalCommit(conn, SURF, serial, xref(id, { flags: 1, format: ARGB8888 }), [[0, 0, W, H], [1, 1, 2, 2]]));
  }
  const ids = calls.filter((c) => c[0] === 'resolveExternal').map((c) => c[1].id);
  assert.deepEqual(ids, [BIG, 0xffff_ffff_ffff_ffffn, 0x1_0000_0000n]);
  assert.ok(ids.every((id) => typeof id === 'bigint'));
  assert.deepEqual(calls[0], ['resolveExternal', xref(BIG, { flags: 1, format: ARGB8888 }), conn, SURF, [0, 0, W, H, 1, 1, 2, 2]]);
  assert.deepEqual(calls[1], ['release', image], 'released after the dispatch');
  assert.equal(calls.filter((c) => c[0] === 'resolve').length, 0);
  assert.equal(calls.filter((c) => c[0] === 'release').length, 3, 'once per image');
  const [c] = events.filter((e) => e.type === 'commit');
  assert.equal(c.format, 'gpu');
  assert.deepEqual(c.external, xref(BIG, { flags: 1, format: ARGB8888 }));
  assert.equal(c.gpu, undefined, 'exactly one of gpu / external');
  assert.equal(c.image, image);
  assert.equal(c.pixels.length, 0);
  assert.deepEqual([c.width, c.height, c.logicalWidth, c.logicalHeight, c.stride], [W, H, W, H, 0]);
  assert.deepEqual([...c.damage], [0, 0, W, H, 1, 1, 2, 2]);
  assert.equal(c.acksBefore, 0, 'the ACK follows the dispatch');
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2], [conn, 3]]);
});

test('external: a promise stalls later frames until it settles; throwing, rejecting or null shows nothing new; invalid refs (format, 0 or 16385 px, flags 2) are ACKed unseen', async () => {
  const waiting: (() => void)[] = [];
  const released: unknown[] = [];
  const asked: bigint[] = [];
  const gpu: GpuSource<string> = {
    resolveExternal(ref) {
      asked.push(ref.id);
      if (ref.id === 1n) return new Promise((res) => waiting.push(() => res('late')));
      if (ref.id === 2n) throw new Error('no such id');
      if (ref.id === 3n) return Promise.reject(new Error('gone'));
      return null;
    },
    release(img) { released.push(img); },
  };
  const { events, link, deliver, commitWire, conn } = await setup({ gpu });
  deliver(commitWire(), externalCommit(conn, SURF, 1, xref(1n), [[0, 0, W, H]]), wireFrame(conn, msg(TOP, 2, ['after'])),
    commitWire(), externalCommit(conn, SURF, 2, xref(4n), [[0, 0, W, H]]));
  const titles = () => events.filter((e) => e.type === 'title').map((e) => e.title);
  assert.deepEqual(titles(), [], 'the title frame waits for the promise');
  assert.deepEqual(asked, [1n], 'so does the next COMMIT');
  assert.deepEqual(acks(link), []);
  waiting.shift()!();
  await ticks();
  assert.deepEqual(titles(), ['after']);
  assert.deepEqual(asked, [1n, 4n]);
  assert.deepEqual(events.filter((e) => e.type === 'commit' || e.type === 'title').map((e) => e.type === 'title' ? e.title : e.image),
    ['late', 'after', null], 'order holds');
  assert.deepEqual(released, ['late']);
  assert.deepEqual(acks(link), [[conn, 1], [conn, 2]]);

  const logs = events.filter((e) => e.type === 'log').length;
  deliver(
    commitWire(), externalCommit(conn, SURF, 3, xref(2n), [[0, 0, 1, 1]]),   // throws
    commitWire(), externalCommit(conn, SURF, 4, xref(3n), [[0, 0, 1, 1]]),   // rejects
    commitWire(), externalCommit(conn, SURF, 5, xref(5n), [[0, 0, 1, 1]]),   // null
    externalCommit(conn, SURF, 6, xref(6n, { format: 0x3231564e }), [[0, 0, 1, 1]]),           // NV12
    externalCommit(conn, SURF, 7, xref(7n, { width: 0 }), [[0, 0, 1, 1]]),                     // 0 px
    externalCommit(conn, SURF, 8, xref(8n, { width: 16385, height: 1 }), [[0, 0, 1, 1]]),      // past 16384
    externalCommit(conn, SURF, 9, xref(9n, { flags: 2 }), [[0, 0, 1, 1]]),                     // unknown flag
    externalCommit(conn, SURF, 10, xref(10n), [[W - 1, 0, 2, 1]]),                              // rect outside
  );
  await ticks();
  assert.deepEqual(events.filter((e) => e.type === 'commit').map((e) => [e.external.id, e.image]),
    [[1n, 'late'], [4n, null], [2n, null], [3n, null], [5n, null]]);
  assert.deepEqual(asked, [1n, 4n, 2n, 3n, 5n], 'invalid ones never reach the resolver');
  assert.deepEqual(released, ['late'], 'nothing to release for null');
  assert.deepEqual(acks(link).map(([, s]) => s).sort((a, b) => a - b), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  const lines = events.filter((e) => e.type === 'log').slice(logs).map((e) => e.line);
  assert.ok(lines.some((l) => /resolveExternal of id 0x2 failed/.test(l)), lines.join('\n'));
  assert.ok(lines.some((l) => /resolveExternal of id 0x3 failed/.test(l)), lines.join('\n'));
  assert.ok(lines.filter((l) => /kind external/.test(l)).length >= 5, 'the core says why each invalid one was refused');
});

test('external: a resolve pending when the link resets is neither dispatched nor ACKed on the next link, and its image is still released', async () => {
  const waiting: ((img: string) => void)[] = [];
  const released: unknown[] = [];
  const gpu: GpuSource<string> = {
    resolveExternal: () => new Promise((res) => waiting.push(res)),
    release(img) { released.push(img); },
  };
  const s = await setup({ gpu });
  s.deliver(s.commitWire(), externalCommit(s.conn, SURF, 1, xref(BIG), [[0, 0, W, H]]));
  assert.equal(waiting.length, 1);
  s.link.cb.onClose({ takenOver: false });
  s.link.cb.onOpen();
  const cw = s.client(2);
  s.deliver(cw(), externalCommit(2, SURF, 1, xref(BIG + 1n), [[0, 0, W, H]]), wireFrame(2, msg(TOP, 2, ['after'])));
  assert.equal(waiting.length, 2);
  waiting[0]('stale');
  await ticks();
  const commits = () => s.events.filter((e) => e.type === 'commit').map((e) => [e.conn, e.image]);
  assert.deepEqual(commits(), []);
  assert.deepEqual(acks(s.link), []);
  assert.deepEqual(released, ['stale']);
  waiting[1]('fresh');
  await ticks();
  assert.deepEqual(commits(), [[2, 'fresh']]);
  assert.deepEqual(acks(s.link), [[2, 1]]);
  assert.deepEqual(released, ['stale', 'fresh']);
  assert.deepEqual(s.events.filter((e) => e.type === 'title').map((e) => e.title), ['after']);
});

for (const shape of ['no gpu source', 'resolve only'] as const) {
  test(`external COMMIT with ${shape}: resolve never called, one error per link, each laid out (image null) and ACKed, the next one whole`, async () => {
    const resolved: unknown[] = [];
    const gpu: GpuSource | undefined = shape === 'resolve only' ? { resolve: (ref) => { resolved.push(ref); return 'img'; } } : undefined;
    const s = await setup({ gpu });
    s.deliver(s.commitWire(), externalCommit(s.conn, SURF, 1, xref(1n), [[0, 0, W, H]]),
      s.commitWire(), externalCommit(s.conn, SURF, 2, xref(2n), [[1, 1, 1, 1]]));
    const errors = () => s.events.filter((e) => e.type === 'error').map((e) => e.detail);
    assert.equal(errors().length, 1);
    assert.match(errors()[0], /resolveExternal/);
    assert.deepEqual(resolved, []);
    const commits = s.events.filter((e) => e.type === 'commit');
    assert.deepEqual(commits.map((e) => [e.format, e.external.id, e.image, e.gpu]), [['gpu', 1n, null, undefined], ['gpu', 2n, null, undefined]]);
    assert.deepEqual(commits.map((e) => [...e.damage]), [[0, 0, W, H], [0, 0, W, H]], 'nothing shown: the next one is whole');
    assert.deepEqual(acks(s.link), [[s.conn, 1], [s.conn, 2]]);
    // a virtgpu commit is still the resolver's (or the no-source error's)
    s.deliver(s.commitWire(), virtgpuCommit(s.conn, SURF, 3, gref(9), [[0, 0, 1, 1]]));
    assert.equal(resolved.length, shape === 'resolve only' ? 1 : 0);
    assert.equal(errors().length, shape === 'resolve only' ? 1 : 2);
    // the next link: the error again, once
    s.link.cb.onClose({ takenOver: false });
    s.link.cb.onOpen();
    const cw = s.client(2);
    const before = errors().length;
    s.deliver(cw(), externalCommit(2, SURF, 1, xref(3n), [[0, 0, W, H]]), cw(), externalCommit(2, SURF, 2, xref(3n), [[0, 0, W, H]]));
    assert.equal(errors().length, before + 1);
    assert.deepEqual(acks(s.link).slice(-2), [[2, 1], [2, 2]]);
  });
}

test('resolveExternal only: a virtgpu COMMIT is not handed to it — one error, image null, ACKed', async () => {
  const asked: unknown[] = [];
  const { events, link, deliver, commitWire, conn } = await setup({ gpu: { resolveExternal: (ref) => { asked.push(ref); return 'img'; } } });
  deliver(commitWire(), virtgpuCommit(conn, SURF, 1, gref(42), [[0, 0, W, H]]));
  assert.deepEqual(asked, []);
  const errors = events.filter((e) => e.type === 'error');
  assert.equal(errors.length, 1);
  assert.match(errors[0].detail, /no gpu source with resolve/);
  assert.deepEqual(events.filter((e) => e.type === 'commit').map((e) => [e.gpu.resource, e.image, e.external]), [[42, null, undefined]]);
  assert.deepEqual(acks(link), [[conn, 1]]);
});

test('virtgpu and external COMMITs alternating on one link: each reaches its own resolver, in order, every image released once; neither forces a whole commit on the other', async () => {
  const order: string[] = [];
  const released: string[] = [];
  const gpu: GpuSource<string> = {
    resolve: (ref) => { order.push(`v${ref.resource}`); return `v${ref.resource}`; },
    resolveExternal: (ref) => {
      order.push(`x${ref.id}`);
      return ref.id === 2n ? Promise.resolve(`x${ref.id}`) : `x${ref.id}`;
    },
    release: (img) => { released.push(img); },
  };
  const { events, link, deliver, commitWire, conn } = await setup({ gpu });
  deliver(
    commitWire(), virtgpuCommit(conn, SURF, 1, gref(1), [[0, 0, W, H]]),
    commitWire(), externalCommit(conn, SURF, 2, xref(2n), [[1, 1, 1, 1]]), // a promise: the rest waits
    commitWire(), virtgpuCommit(conn, SURF, 3, gref(3), [[2, 1, 1, 1]]),
    commitWire(), externalCommit(conn, SURF, 4, xref(4n), [[3, 1, 1, 1]]),
  );
  assert.deepEqual(order, ['v1', 'x2']);
  await ticks();
  assert.deepEqual(order, ['v1', 'x2', 'v3', 'x4']);
  const commits = events.filter((e) => e.type === 'commit');
  assert.deepEqual(commits.map((e) => [e.image, e.gpu?.resource ?? null, e.external?.id ?? null]),
    [['v1', 1, null], ['x2', null, 2n], ['v3', 3, null], ['x4', null, 4n]]);
  assert.deepEqual(commits.map((e) => [...e.damage]), [[0, 0, W, H], [1, 1, 1, 1], [2, 1, 1, 1], [3, 1, 1, 1]]);
  assert.deepEqual(released, ['v1', 'x2', 'v3', 'x4']);
  assert.deepEqual(acks(link).map(([, n]) => n), [1, 2, 3, 4]);
});

test('2D view through the engine: an external commit\'s image is drawn like a GPU one; after one that resolved to nothing, whole', async () => {
  const dom = installFakeDom();
  try {
    const view = createView({ container: dom.container(), webgl: 'never' });
    const images: Record<string, { width: number; height: number } | null> = { 1: { width: W, height: H }, 2: null, 3: { width: W, height: H } };
    const gpu: GpuSource = { resolveExternal: (ref) => images[String(ref.id)] };
    const { deliver, commitWire, conn } = await setup({ gpu, peek: (ev) => view.handle(ev) });
    deliver(commitWire(), externalCommit(conn, SURF, 1, xref(1n), [[0, 0, W, H]]));
    const canvas = view.canvas(conn, SURF) as any;
    assert.deepEqual(canvas.draws, [['clear', 0, 0, W, H], ['draw', images[1], 0, 0, W, H, 0, 0, W, H]]);
    canvas.draws.length = 0;
    deliver(commitWire(), externalCommit(conn, SURF, 2, xref(2n), [[0, 0, 2, 2]]));
    assert.deepEqual(canvas.draws, []);
    deliver(commitWire(), externalCommit(conn, SURF, 3, xref(3n), [[6, 3, 1, 1]]));
    assert.deepEqual(canvas.draws, [['clear', 0, 0, W, H], ['draw', images[3], 0, 0, W, H, 0, 0, W, H]]);
  } finally {
    dom.uninstall();
  }
});
