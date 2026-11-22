#!/usr/bin/env node
// Real relay ⇄ Node engine, link v2 end to end, no browser:
//
//   wayland apps ─unix─► zig-out/bin/wlandr --link unix:… --buffers procfd
//                         ─stream records─► this process: createStreamLink +
//                           wland/engine + test/support/handles-procfd
//
// The two halves of link v2 (server/ and lib/) meet here for real. This is
// the page side of an unkernel embedding, faked in Node: unkernel's page
// replaces this file (vsock instead of a unix socket, a kwshm HandleSource
// instead of procfd); test/support fakes the other half (the guest).
//
// ONE engine serves the whole run, over a link whose source is the relay's
// successive connections (as unkernel's VsockListener is). Phases, each
// asserting no engine 'error' events, ACK count == COMMIT count and every
// opened handle closed:
//  1. weston-simple-shm: steady commits, raw bgrx rows, sane strides, pixels
//     non-blank and changing; prints commits/s and bytes read per second.
//     Minimized, its frame callbacks are held (the engine fires them on a
//     stream link) and it stops committing; restored, it goes on.
//  2. foot: a titled toplevel; typed keys run a printf in the shell that
//     retitles the window; the composite built from damage rects equals the
//     client's whole buffer (read straight from the relay's procfd handle)
//     after the prompt, typing, scrolling and two resizes; cursor shape.
//  3. wl-copy → wl-paste, regular and primary (FDMSG pipes over the stream).
//  4. wayland-info: exit 0, every global, both shm formats.
//     weston-presentation-shm: wp_presentation over the stream link —
//     frames presented within 500 ms of their commit on the client's own
//     CLOCK_MONOTONIC (the relay stamps them), every feedback answered.
//  5. link drop: the engine ends the app's conn ('disconnect' before
//     'close') and closes its handles, the relay drops the app and
//     reconnects, the link opens again; from here the buffer source is
//     ASYNC (promises, like unkernel's worker mode) and 1 and 2 run again.
//  6. a new relay run with --buffers copy connects to the same engine: rgba
//     commits; prints the link's bytes per second.
//  7. (fixtures only) a new relay run with --buffers procfd and the test-only
//     --dmabuf virtgpu:@fake: a GPU client (the `dmabuf` fixture) beside a
//     wl_shm one on the same link — kind-virtgpu COMMITs resolved by the
//     engine's gpu source next to procfd handles, one ACK per COMMIT, the
//     GPU client kept drawing (releases after ACKs). With --no-fence-wait
//     too (unkernel's shape) when the relay's --version lists it.
//
// The apps are test/support/apps.ts's: wland-fixture modes standing in for
// weston-simple-shm, foot (`term`), wl-clipboard, wayland-info and
// weston-presentation-shm; WLAND_E2E_APPS=real runs those instead.
// Needs `zig build` (relay, wland-fixture, lib/wland.wasm). Private
// XDG_RUNTIME_DIR (a short dir in /tmp: AF_UNIX paths are ≤ 108 bytes) and
// WAYLAND_DISPLAY: it never touches the demo's wayland-0.
// Run: node tools/relay-e2e-test.ts (run-poc does).

import { spawn, spawnSync, execFile, type ChildProcessByStdio } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, mkdtempSync, openSync, readFileSync, readSync, rmSync } from 'node:fs';
import { createServer, type Socket } from 'node:net';
import { Duplex, type Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import {
  createEngine, createStreamLink, NO_SELECTION_BRIDGE, readSelectionText, setSelectionText,
  type ByteStream, type CommitEvent, type Engine, type GpuRef, type HandleSource, type Link, type Role,
} from '../lib/engine.ts';
import { app as appFor, appSet, available, realApps, type AppRole, type AppSpec } from '../test/support/apps.ts';
import { createProcfdSource, type ProcfdToken } from '../test/support/handles-procfd.ts';
import { parsePresentationShm, presentationChecks } from '../test/support/presentation-shm.ts';

// WLAND_E2E_RELAY overrides the relay command (split on spaces), e.g. the
// aarch64 guest build under qemu-user: procfd works there too, since the
// emulated relay's fds are the qemu process's own.
const RELAY = (process.env.WLAND_E2E_RELAY || fileURLToPath(new URL('../zig-out/bin/wlandr', import.meta.url))).split(' ');
const wasm = readFileSync(new URL('../lib/wland.wasm', import.meta.url));

const dir = mkdtempSync('/tmp/wl-e2e-');
const linkPath = `${dir}/link`;
const env: NodeJS.ProcessEnv = { ...process.env, XDG_RUNTIME_DIR: dir, WAYLAND_DISPLAY: 'wland-e2e' };
delete env.DISPLAY; // nothing here may fall back to X11

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type App = ChildProcessByStdio<null, Readable, Readable> & {
  stdoutText: string;
  stderrText: string;
  exited: Promise<{ code: number | null; sig: NodeJS.Signals | null }>;
};
const children = new Set<App>();
// (a cast, not an annotation: it is assigned inside functions, and the
// finally block at the end must not narrow it to null)
let relay = null as ChildProcessByStdio<null, null, Readable> | null;

function fail(msg: string): never {
  throw new Error(msg);
}
function check(cond: unknown, msg: string) {
  if (!cond) fail(msg);
  console.log(`  ok  ${msg}`);
}
async function until(cond: () => unknown, ms: number, what: string) {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) fail(`timed out after ${ms} ms waiting for ${what}`);
    await sleep(20);
  }
}

// --- STREAM frames, counted on the wire (protocol/STREAM.md) ---------------
// Both directions: only frame lengths and types matter here.
function eachFrame(bytes: Uint8Array, fn: (t: number, dv: DataView, off: number) => void) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const u32 = (at: number) => dv.getUint32(at, true);
  for (let off = 0; off < bytes.length;) {
    const t = bytes[off];
    let len: number;
    switch (t) {
      case 0x01: len = 9 + u32(off + 5); break;                         // WIRE
      case 0x03: case 0x04: len = 5; break;                             // CONN_OPEN/CLOSE
      case 0x05: { const bl = u32(off + 9); len = 17 + bl + u32(off + 13 + bl); break; } // FDMSG
      case 0x06: len = 13; break;                                       // SRVOBJ
      case 0x08: len = 17 + u32(off + 13); break;                       // HANDLE_OPEN
      case 0x09: case 0x0b: len = 9; break;                             // HANDLE_CLOSE, ACK
      case 0x0a: len = 25 + u32(off + 21) + 16 * u32(off + 13); break;  // COMMIT
      case 0x0c: len = 9 + u32(off + 5); break;                         // FEATURE
      case 0x0d: len = 13; break;                                       // DMABUF_CREATED
      case 0x0e: len = 13 + u32(off + 9); break;                        // PRESENTED
      case 0x02: {                                                      // BUFFER (copy backend)
        const n = u32(off + 17);
        len = 21 + 16 * n;
        for (let i = 0; i < n; i++) len += 4 * dv.getInt32(off + 29 + 16 * i, true) * dv.getInt32(off + 33 + 16 * i, true);
        break;
      }
      case 0x07: len = 29 + 16 * u32(off + 17) + u32(off + 25 + 16 * u32(off + 17)); break; // BUFFER_LZ
      default: fail(`unknown frame type 0x${t.toString(16)}`);
    }
    fn(t, dv, off);
    off += len;
  }
}

// --- the embedder: ONE engine for the whole run -----------------------------
// What a page builds: a stream link over the relay's successive connections
// (an async iterable, as unkernel's VsockListener is), a buffer source, the
// engine, a presentation clock. The link opens again each time the relay
// reconnects. Commits are composited into a per-surface BGRX image so the
// test can look at what a view would show.
interface Image {
  width: number; height: number; data: Uint8Array; commits: number;
  hash?: string; hashes?: Set<string>;
}
interface ShmRef { conn: number; handle: number; offset: number; width: number; height: number; stride: number }
interface State {
  sock: Socket | null; async: boolean;
  open: boolean; opens: number; closes: number;
  commitFrames: number; acks: number; ackMismatch: string | null; handleOpens: number; handleCloses: number;
  tokens: number; tokenCloses: number; reads: number; bytesRead: number;
  errors: string[];
  surfaces: Map<string, { conn: number; surface: number; role: Role }>;
  titles: Map<string, string>; images: Map<string, Image>; cursors: string[];
  conns: Set<number>; disconnected: number[]; formats: Set<string>; badFrame: string | null;
  commitEvents: number;
  focus: string | null; focused: Set<string>;
  handleDesc: Map<string, { pid: number; fd: number; offset: number }>;
  lastRef: Map<string, ShmRef>;
  poolOffsets: Set<number>;
  gpuRefs: GpuRef[]; gpuReleases: number;
  ready?: Promise<Engine>;
  engine?: Engine;
  clock?: ReturnType<typeof setInterval>;
}
function startEngine() {
  const s: State = {
    sock: null, async: false,
    open: false, opens: 0, closes: 0,
    commitFrames: 0, acks: 0, ackMismatch: null, handleOpens: 0, handleCloses: 0,
    tokens: 0, tokenCloses: 0, reads: 0, bytesRead: 0,
    errors: [], surfaces: new Map(), titles: new Map(), images: new Map(), cursors: [],
    conns: new Set(), disconnected: [], formats: new Set(), badFrame: null,
    commitEvents: 0,
    focus: null, focused: new Set(), // keyboard focus: `${conn}/${surface}`; toplevels focused once
    handleDesc: new Map(), // `${conn}/${handle}` → procfd handle bytes, from HANDLE_OPEN
    lastRef: new Map(),    // `${conn}/${surface}` → the newest COMMIT's shm ref
    poolOffsets: new Set(), // pool byte offsets of committed buffers (handle base + COMMIT offset)
    gpuRefs: [], gpuReleases: 0, // COMMITs of kind virtgpu the gpu source resolved
  };

  // every connection the relay makes, as a ByteStream
  async function* connections(): AsyncGenerator<ByteStream> {
    for (;;) {
      const sock = await nextConnection();
      if (!sock) return;
      s.sock = sock;
      yield { ...(Duplex.toWeb(sock) as unknown as ByteStream), close: () => sock.destroy() };
    }
  }
  const inner = createStreamLink(connections());
  // count frames each way: with a synchronous buffer source every COMMIT is
  // ACKed by the time the message carrying it has been processed
  const link: Link = {
    start(cb) {
      inner.start({
        ...cb,
        onMessage(buf) {
          eachFrame(new Uint8Array(buf), (t, dv, off) => {
            const u32 = (at: number) => dv.getUint32(off + at, true);
            if (t === 0x0a) {
              s.commitFrames++;
              if (u32(17) === 1) s.poolOffsets.add((s.handleDesc.get(`${u32(1)}/${u32(25)}`)?.offset ?? 0) + u32(29));
              if (u32(17) === 1) s.lastRef.set(`${u32(1)}/${u32(5)}`, {
                conn: u32(1), handle: u32(25), offset: u32(29), width: u32(33), height: u32(37), stride: u32(41),
              });
            } else if (t === 0x08) {
              s.handleOpens++;
              if (u32(9) === 2) s.handleDesc.set(`${u32(1)}/${u32(5)}`, {
                pid: u32(17), fd: u32(21), offset: Number(dv.getBigUint64(off + 25, true)),
              });
            } else if (t === 0x09) s.handleCloses++;
            else if (t === 0x03) s.conns.add(u32(1));
          });
          cb.onMessage(buf);
          if (!s.async && s.acks !== s.commitFrames && !s.ackMismatch) s.ackMismatch = `${s.acks} ACKs for ${s.commitFrames} COMMITs`;
        },
      });
    },
    send(bytes) {
      eachFrame(bytes, (t) => { if (t === 0x0b) s.acks++; });
      inner.send(bytes);
    },
    get bufferedAmount() { return inner.bufferedAmount; },
  };

  // procfd, counted; with `s.async` every open/read answers with a promise
  // settled on a later macrotask, the way a kwshm source in unkernel's
  // worker mode does
  const procfd = createProcfdSource();
  const later = <R>(fn: () => R) => new Promise<R>((resolve, reject) => setTimeout(() => { try { resolve(fn()); } catch (e) { reject(e); } }, 1));
  const buffers: HandleSource<ProcfdToken> = {
    open(handle, conn) {
      s.tokens++;
      const open = () => procfd.open(handle, conn);
      return s.async ? later(open) : open();
    },
    read(token, offset, dst) {
      s.reads++;
      s.bytesRead += dst.length;
      const read = () => procfd.read(token, offset, dst);
      return s.async ? later(read) : read();
    },
    close(token) { s.tokenCloses++; procfd.close(token); },
  };

  // a stand-in renderer for COMMIT kind virtgpu: what unkernel's page does
  // with vm.gl.gpu, minus the GPU (a token image; nothing reads pixels)
  const gpu = {
    resolve(ref: GpuRef) { s.gpuRefs.push(ref); return { resource: ref.resource }; },
    release() { s.gpuReleases++; },
  };

  s.ready = createEngine({
    wasm, link, buffers, gpu,
    onEvent(ev) {
      const key = `${'conn' in ev ? ev.conn : undefined}/${'surface' in ev ? ev.surface : undefined}`;
      switch (ev.type) {
        case 'open': s.open = true; s.opens++; break;
        case 'close':
          // every conn got its 'disconnect' first; a new relay run reuses
          // conn ids, so forget the old link's
          s.open = false;
          s.closes++;
          for (const m of [s.conns, s.surfaces, s.titles, s.images, s.lastRef, s.handleDesc, s.focused, s.poolOffsets]) m.clear();
          break;
        case 'error': s.errors.push(ev.detail); console.log(`  engine error: ${ev.detail}`); break;
        case 'surface': s.surfaces.set(key, { conn: ev.conn, surface: ev.surface, role: ev.role }); break;
        case 'destroy':
          s.surfaces.delete(key);
          if (s.focus === key) s.focus = null; // focus dies silently with its surface: no leave
          break;
        case 'title': s.titles.set(key, ev.title); break;
        case 'cursor': s.cursors.push(ev.cursor); break;
        case 'disconnect':
          s.disconnected.push(ev.conn);
          for (const k of s.surfaces.keys()) if (k.startsWith(`${ev.conn}/`)) s.surfaces.delete(k);
          if (s.focus?.startsWith(`${ev.conn}/`)) s.focus = null;
          break;
        case 'commit':
          composite(s, key, ev);
          // focus follows map, as a desktop's would (wl-copy waits for it)
          if (ev.role === 1 && s.focus !== key && !s.focused.has(key)) {
            s.focused.add(key);
            if (s.focus) s.engine!.keyboardLeave(Number(s.focus.split('/')[0]));
            s.focus = key;
            s.engine!.keyboardEnter(ev.conn, ev.surface);
          }
          break;
      }
    },
  }).then((engine) => {
    s.engine = engine;
    engine.setOutput(1280, 720);
    engine.start();
    // the presentation clock: frame callbacks are engine-fired on stream links
    s.clock = setInterval(() => engine.tick(performance.now()), 16);
    return engine;
  });
  return s;
}

// Compare a surface's composite (built from damage rects only) with the
// whole buffer as it is in the client's memory right now, read straight from
// the relay's procfd handle. Call when the client is idle: any difference is
// a damage, offset, stride or ordering bug somewhere on the path.
function verifyComposite(s: State, key: string) {
  const ref = s.lastRef.get(key);
  const img = s.images.get(key);
  if (!ref || !img) return fail(`no commit for ${key}`);
  const h = s.handleDesc.get(`${ref.conn}/${ref.handle}`);
  if (!h) return fail(`no HANDLE_OPEN for handle ${ref.handle}`);
  const fd = openSync(`/proc/${h.pid}/fd/${h.fd}`, 'r');
  const buf = new Uint8Array(ref.stride * ref.height);
  try { readSync(fd, buf, 0, buf.length, h.offset + ref.offset); } finally { closeSync(fd); }
  let bad = 0;
  for (let y = 0; y < ref.height; y++) {
    for (let x = 0; x < ref.width; x++) {
      const a = y * ref.stride + x * 4, b = (y * img.width + x) * 4;
      if (buf[a] !== img.data[b] || buf[a + 1] !== img.data[b + 1] || buf[a + 2] !== img.data[b + 2]) bad++;
    }
  }
  return { bad, total: ref.width * ref.height, ref };
}

async function settle(s: State, quietMs = 400) {
  for (let n = -1; n !== s.commitEvents;) { n = s.commitEvents; await sleep(quietMs); }
}

function composite(s: State, key: string, ev: CommitEvent) {
  s.commitEvents++;
  s.formats.add(ev.format);
  // record, don't throw: this runs inside the engine's dispatch
  if (ev.format === 'gpu') return; // a named GPU resource: no pixels (State.gpuRefs)
  const packed = ev.format === 'rgba'; // copy backend: rects' rows packed, in rect order
  if (packed ? ev.stride !== 0 : ev.format !== 'bgrx' && ev.format !== 'bgra') s.badFrame ??= `format ${ev.format}, stride ${ev.stride}`;
  if (!packed && (ev.stride < ev.width * 4 || ev.stride % 4 || ev.stride > ev.width * 4 + 4096)) s.badFrame ??= `${ev.width}px, stride ${ev.stride}`;
  if (!packed && ev.pixels.length < (ev.height - 1) * ev.stride + ev.width * 4) s.badFrame ??= `pixels ${ev.pixels.length} B short`;
  let img = s.images.get(key);
  if (!img || img.width !== ev.width || img.height !== ev.height) {
    img = { width: ev.width, height: ev.height, data: new Uint8Array(ev.width * ev.height * 4), commits: 0 };
    s.images.set(key, img);
  }
  const d = ev.damage;
  let at = 0;
  for (let i = 0; i < d.length; i += 4) {
    const [x, y, w, h] = [d[i], d[i + 1], d[i + 2], d[i + 3]];
    for (let r = y; r < y + h; r++) {
      const src = packed ? at + (r - y) * w * 4 : r * ev.stride + x * 4;
      img.data.set(ev.pixels.subarray(src, src + w * 4), (r * ev.width + x) * 4);
    }
    at += w * h * 4;
  }
  img.commits++;
  img.hash = createHash('sha1').update(img.data).digest('hex');
  (img.hashes ??= new Set()).add(img.hash);
}

// distinct opaque colours in an image (alpha ignored: X is undefined)
function colours(img: Image) {
  const seen = new Set<number>();
  const v = new Uint32Array(img.data.buffer);
  for (let i = 0; i < v.length && seen.size < 64; i += 7) seen.add(v[i] & 0xffffff);
  return seen.size;
}

// --- relay + accept queue --------------------------------------------------
const server = createServer();
const waiting: ((sock: Socket | null) => void)[] = [];
const accepted: Socket[] = [];
server.on('connection', (sock) => {
  const w = waiting.shift();
  if (w) w(sock); else accepted.push(sock);
});
server.on('close', () => { for (const w of waiting.splice(0)) w(null); });
const nextConnection = () => new Promise<Socket | null>((resolve) => {
  if (accepted.length) resolve(accepted.shift()!);
  else waiting.push(resolve);
});

const relayLog: string[] = [];
function startRelay(buffers: string, extra: string[] = []) {
  relay = spawn(RELAY[0], [...RELAY.slice(1), '--link', `unix:${linkPath}`, '--buffers', buffers, '--display', env.WAYLAND_DISPLAY!, ...extra], { env, stdio: ['ignore', 'inherit', 'pipe'] });
  let partial = '';
  relay.stderr.on('data', (chunk: Buffer) => {
    partial += chunk;
    const lines = partial.split('\n');
    partial = lines.pop()!;
    for (const l of lines) { relayLog.push(l); console.log(`  relay| ${l}`); }
  });
  relay.on('exit', (code, sig) => { if (code !== null || sig !== 'SIGTERM') console.log(`  relay exited (${code ?? sig})`); });
}

/** The app for a role (test/support/apps.ts); every one is required here. */
function spec(role: AppRole, args: string[] = []): AppSpec {
  const s = appFor(role, args);
  if (!available(s)) fail(`${s.name} is not installed (WLAND_E2E_APPS=${appSet})`);
  return s;
}

function app(role: AppRole, args: string[] = []): App {
  const a = spec(role, args);
  const p = spawn(a.cmd, a.args, { env: { ...env, ...a.env }, stdio: ['ignore', 'pipe', 'pipe'] }) as App;
  p.stdoutText = p.stderrText = '';
  p.stdout.on('data', (c) => { p.stdoutText += c; });
  p.stderr.on('data', (c) => { p.stderrText += c; });
  p.exited = new Promise((r) => p.on('exit', (code, sig) => { children.delete(p); r({ code, sig }); }));
  children.add(p);
  return p;
}

const run = (role: AppRole, args: string[], ms: number) => new Promise<{ code: unknown; stdout: string; stderr: string }>((resolve) => {
  const a = spec(role, args);
  execFile(a.cmd, a.args, { env: { ...env, ...a.env }, timeout: ms }, (err, stdout, stderr) =>
    resolve({ code: err ? (err.code ?? err.signal) : 0, stdout, stderr }));
});

// --- evdev key codes for typing (US layout, the core's canned keymap) ------
const KEYS: Record<string, number | undefined> = {
  a: 30, b: 48, c: 46, d: 32, e: 18, f: 33, g: 34, h: 35, i: 23, j: 36, k: 37, l: 38, m: 50,
  n: 49, o: 24, p: 25, q: 16, r: 19, s: 31, t: 20, u: 22, v: 47, w: 17, x: 45, y: 21, z: 44,
  1: 2, 2: 3, 3: 4, 4: 5, 5: 6, 6: 7, 7: 8, 8: 9, 9: 10, 0: 11,
  ' ': 57, "'": 40, '\\': 43, ']': 27, ';': 39, '-': 12, '\n': 28,
};
async function type(engine: Engine, conn: number, text: string) {
  for (const ch of text) {
    const code = KEYS[ch];
    if (!code) fail(`no key for ${JSON.stringify(ch)}`);
    engine.key(conn, performance.now(), code, true);
    engine.key(conn, performance.now(), code, false);
    await sleep(4);
  }
}

const toplevelOf = (s: State, conn: number | undefined) => [...s.surfaces.values()].find((x) => x.conn === conn && x.role === 1);
const newConn = (s: State, before: Set<number>) => [...s.conns].find((c) => !before.has(c));

// foot: a toplevel with a title; typing reaches the shell; the composite
// matches the client's buffer after typing, scrolling and a resize; the
// pointer gets a cursor shape.
async function footPhase(s: State) {
  const engine = s.engine!;
  const before = new Set(s.conns);
  // a plain shell: no rc files that retitle the window on every prompt
  const foot = app('term');
  await until(() => { const c = newConn(s, before); return c && toplevelOf(s, c) && s.titles.has(`${c}/${toplevelOf(s, c)!.surface}`); },
    10000, 'a foot toplevel with a title');
  const conn = newConn(s, before)!;
  const top = toplevelOf(s, conn)!;
  const key = `${conn}/${top.surface}`;
  check(s.titles.get(key)!.length > 0, `foot toplevel titled "${s.titles.get(key)}"`);
  await until(() => (s.images.get(key)?.commits ?? 0) > 0, 5000, 'foot pixels');
  await settle(s); // the first frames and the prompt
  const img0 = s.images.get(key)!;
  const hash0 = img0.hash;
  check(colours(img0) >= 2, `foot drew something (${colours(img0)} colours sampled, ${img0.width}x${img0.height})`);
  const same = (what: string) => {
    const v = verifyComposite(s, key);
    check(v.bad === 0, `${what}: composite == client buffer (${v.bad}/${v.total} px differ; ${v.ref.width}x${v.ref.height}, stride ${v.ref.stride}, offset ${v.ref.offset})`);
  };
  same('after the prompt');

  if (s.focus !== key) engine.keyboardEnter(conn, top.surface); // focus-follows-map normally did it
  await sleep(100);
  // OSC 2 sets foot's title; the shell only prints it if every key arrived
  const marker = 'wland-e2e-ok';
  await type(engine, conn, `printf '\\033]2;${marker}\\007'\n`);
  await until(() => s.titles.get(key) === marker, 5000, `foot's title to become "${marker}" (typed through the shell)`);
  check(true, 'keys reached the shell: it ran the typed printf and foot retitled');
  await until(() => s.images.get(key)!.hash !== hash0, 3000, 'foot pixels to change');
  check(true, 'typing changed the surface pixels');
  await settle(s);
  same('after typing');

  // scrolling: foot scrolls by moving its buffers through a sparse pool
  const hashes = s.images.get(key)!.hashes!.size;
  await type(engine, conn, 'seq 1 400\n');
  await until(() => s.images.get(key)!.hashes!.size > hashes + 2, 5000, 'foot to scroll');
  await settle(s);
  same('after scrolling 400 lines');
  console.log(`  pool offsets of committed buffers so far: ${[...s.poolOffsets].slice(0, 12).join(', ')}${s.poolOffsets.size > 12 ? ` … (${s.poolOffsets.size})` : ''}`);

  // pointer: enter + motion over the text area → foot asks for a cursor shape
  const cursors = s.cursors.length;
  engine.pointerEnter(conn, top.surface, 100, 100);
  engine.pointerMotion(conn, performance.now(), 120, 110);
  await until(() => s.cursors.length > cursors, 3000, 'a cursor shape from foot');
  check(s.cursors.slice(cursors).includes('text'), `pointer over the terminal: cursor "${s.cursors.slice(cursors)}"`);
  engine.pointerLeave(conn);

  // resize: new, bigger buffers (new handles), then back down
  for (const [w, h] of [[900, 640], [500, 300]]) {
    const was = s.images.get(key)!;
    engine.requestResize(conn, top.surface, w, h);
    await until(() => s.images.get(key) !== was && s.images.get(key)!.width !== was.width, 5000, `foot to resize to ~${w}x${h}`);
    await settle(s);
    const img = s.images.get(key)!;
    check(Math.abs(img.width - w) <= 40 && Math.abs(img.height - h) <= 40, `resized to ${img.width}x${img.height} (asked ${w}x${h})`);
    same(`after resizing to ${img.width}x${img.height}`);
  }

  if (!s.async) check(s.acks === s.commitFrames && s.ackMismatch === null, `ACK count == COMMIT count (${s.acks}/${s.commitFrames})`);
  check(s.badFrame === null, `format, stride and pixel length sane${s.badFrame ? ` (${s.badFrame})` : ''}`);
  check(s.errors.length === 0, 'no engine error events');
  foot.kill();
  await foot.exited;
  await until(() => s.disconnected.includes(conn), 3000, 'foot conn close');
  await sleep(100);
  check(s.acks === s.commitFrames, `every COMMIT ACKed, also across the conn close (${s.acks}/${s.commitFrames})`);
  check(s.tokens === s.tokenCloses, `every opened handle closed (${s.tokens} opens, ${s.tokenCloses} closes)`);
}

// ---------------------------------------------------------------------------
async function main() {
  await new Promise<void>((r, j) => server.listen(linkPath, r).once('error', j));
  console.log(`== relay e2e: ${RELAY.join(' ')} --link unix:${linkPath} --buffers procfd (XDG_RUNTIME_DIR=${dir}, apps: ${appSet}) ==`);
  startRelay('procfd');
  await until(() => relayLog.some((l) => l.includes('wayland socket:')), 5000, 'the relay ready line');
  const s = startEngine();
  const engine = await s.ready!;
  await until(() => s.open, 5000, 'the relay to connect and the engine link to open');

  // --- weston-simple-shm: pixels, ACKs, handle lifetimes, rate --------------
  console.log('== weston-simple-shm ==');
  let before = new Set(s.conns);
  const shm = app('shm');
  await until(() => s.commitEvents >= 10, 10000, 'simple-shm commits');
  const shmConn = newConn(s, before)!;
  // measure over a fixed window once it is running
  const c0 = s.commitEvents, b0 = s.bytesRead, l0 = engine.stats.bytesIn, t0 = performance.now();
  await sleep(3000);
  const secs = (performance.now() - t0) / 1000;
  const rate = (s.commitEvents - c0) / secs;
  const readRate = (s.bytesRead - b0) / secs;
  const linkRate = (engine.stats.bytesIn - l0) / secs;
  const shmImg = s.images.get([...s.images.keys()].find((k) => k.startsWith(`${shmConn}/`))!);
  console.log(`  measured: ${rate.toFixed(1)} commits/s, ${(readRate / 1e6).toFixed(2)} MB/s read through the buffer source ` +
    `(${(readRate / Math.max(rate, 1) / 1024).toFixed(0)} KiB/commit), ${(linkRate / 1024).toFixed(1)} KiB/s of link messages`);
  check(rate > 30, `steady commit stream (${rate.toFixed(1)}/s > 30/s)`);
  check([...s.formats].every((f) => f === 'bgrx' || f === 'bgra'), `formats ${[...s.formats]} are raw wl_shm rows`);
  check(s.badFrame === null, `format, stride and pixel length sane for every commit${s.badFrame ? ` (${s.badFrame})` : ''}`);
  check(shmImg && colours(shmImg) > 4, `simple-shm pixels are not blank (${shmImg && colours(shmImg)} colours sampled)`);
  check(shmImg!.hashes!.size > 30, `pixels change between frames (${shmImg!.hashes!.size} distinct images)`);
  check(s.ackMismatch === null && s.acks === s.commitFrames, `ACK count == COMMIT count (${s.acks}/${s.commitFrames})${s.ackMismatch ? ` — ${s.ackMismatch}` : ''}`);
  check(s.commitEvents === s.commitFrames, `every COMMIT presented (${s.commitEvents} commit events)`);
  check(s.errors.length === 0, 'no engine error events');
  // simple-shm has 2 buffers and takes the first free one; with ACKs this
  // prompt it may never need the second
  check(s.handleOpens >= 1 && s.handleOpens <= 2, `one handle per wl_buffer (${s.handleOpens} HANDLE_OPENs)`);
  // minimized: no frame callbacks, so simple-shm (paced by them) stops
  const shmTop = toplevelOf(s, shmConn)!;
  engine.setMinimized(shmConn, shmTop.surface, true);
  await sleep(300); // what was in flight
  const m0 = s.commitEvents;
  await sleep(1000);
  check(s.commitEvents - m0 <= 1, `minimized: frame callbacks held, ${s.commitEvents - m0} commits in 1 s`);
  engine.setMinimized(shmConn, shmTop.surface, false);
  const r0 = s.commitEvents;
  await sleep(1000);
  check(s.commitEvents - r0 > 20, `restored: commits again (${s.commitEvents - r0} in 1 s)`);
  shm.kill();
  await shm.exited;
  await until(() => s.disconnected.includes(shmConn), 3000, 'simple-shm conn close');
  check(s.tokens === s.tokenCloses, `every opened handle closed with its conn (${s.tokens} opens, ${s.tokenCloses} closes)`);

  // --- foot ----------------------------------------------------------------
  console.log('== foot ==');
  await footPhase(s);

  // --- clipboard: FDMSG pipe tokens over the stream link ---------------------
  console.log('== clipboard + primary selection ==');
  for (const primary of [false, true]) {
    const flag = primary ? ['--primary'] : [];
    const text = `wland-e2e-${primary ? 'primary' : 'clip'}`;
    const copy = app('copy', [...flag, text]); // forks a daemon serving the selection
    await copy.exited;
    await sleep(300);
    const paste = await run('paste', [...flag, '--no-newline'], 5000);
    check(paste.code === 0 && paste.stdout === text, `wl-paste ${flag.join(' ')}returned "${paste.stdout}"`);
  }
  // the embedder's halves (the page bridge's) over the stream link: it
  // reads an app's selection (FDMSG pipe_read: the relay's pipe), sets its
  // own and wl-paste reads that (FDMSG own_pipe: the relay writes its copy)
  const bridgeCopy = app('copy', ['wland-e2e-bridge']);
  await bridgeCopy.exited;
  await sleep(300);
  if (engine.selectionBridged() === false) {
    // an older relay (wlandr 0.1.0: no FEATURE selection_cache): the engine
    // must not try — a prompt refusal, and an app's paste never blocks
    console.log('  skipped: the engine\'s clipboard halves (the relay sent no FEATURE selection_cache); checking they are refused');
    const t0 = Date.now();
    const err = await readSelectionText(engine).then(() => null, (e: Error) => e.message);
    check(err === NO_SELECTION_BRIDGE && Date.now() - t0 < 1000, `readSelectionText rejected at once: "${err}"`);
    check(!setSelectionText(engine, 'wland-e2e from the engine'), 'setSelectionText refused (nothing offered to apps)');
    const p0 = Date.now();
    const appPaste = await run('paste', ['--no-newline'], 5000);
    check(appPaste.code === 0 && appPaste.stdout === 'wland-e2e-bridge' && Date.now() - p0 < 3000, `wl-paste got the app's selection at once, not blocked: "${appPaste.stdout}"`);
  } else {
    check(engine.selectionBridged() === true, 'the relay bridges the clipboard (FEATURE selection_cache)');
    const fromApp = await readSelectionText(engine);
    check(fromApp === 'wland-e2e-bridge', `the engine read the app's selection: "${fromApp}"`);
    check(setSelectionText(engine, 'wland-e2e from the engine'), 'the engine set its own selection');
    const ownPaste = await run('paste', ['--no-newline'], 5000);
    check(ownPaste.code === 0 && ownPaste.stdout === 'wland-e2e from the engine', `wl-paste of the engine's selection returned "${ownPaste.stdout}"`);
  }
  await run('copy', ['--clear'], 3000);
  await run('copy', ['--primary', '--clear'], 3000);

  // --- wayland-info -----------------------------------------------------------
  console.log('== wayland-info ==');
  const info = await run('info', [], 10000);
  check(info.code === 0, `wayland-info exited 0${info.code ? ` (${info.code}: ${info.stderr.trim()})` : ''}`);
  const globals = ['wl_compositor', 'wl_subcompositor', 'wl_shm', 'wl_seat', 'wl_output', 'xdg_wm_base',
    'wl_data_device_manager', 'zxdg_decoration_manager_v1', 'wp_cursor_shape_manager_v1', 'wp_viewporter',
    'wp_fractional_scale_manager_v1', 'zwp_text_input_manager_v3', 'zwp_primary_selection_device_manager_v1',
    'zwp_relative_pointer_manager_v1', 'zwp_pointer_constraints_v1', 'wp_presentation'];
  const missing = globals.filter((g) => !info.stdout.includes(`'${g}'`));
  check(missing.length === 0, `all ${globals.length} globals advertised${missing.length ? ` (missing ${missing})` : ''}`);
  check(/1 = 'XR24'/.test(info.stdout) && /0 = 'AR24'/.test(info.stdout), 'wl_shm formats XRGB8888 + ARGB8888');
  check(/capabilities: pointer keyboard/.test(info.stdout), 'wl_seat has pointer + keyboard');

  // --- weston-presentation-shm: presentation feedback, stamped by the relay ---
  console.log('== weston-presentation-shm ==');
  const pres = app('presentation', ['-f']);
  await sleep(2000);
  pres.kill('SIGINT'); // it then prints the feedbacks still outstanding
  await pres.exited;
  for (const [ok, what] of presentationChecks(parsePresentationShm(pres.stdoutText), 60)) check(ok, what);

  // --- link drop: apps are dropped; the relay reconnects; the SAME engine --------
  // goes on (the link's source yields the new connection)
  console.log('== link drop + reconnect ==');
  before = new Set(s.conns);
  const doomed = app('shm');
  const c1 = s.commitEvents;
  await until(() => s.commitEvents > c1 + 10, 10000, 'simple-shm commits before the drop');
  const doomedConn = newConn(s, before)!;
  const logMark = relayLog.length, closes = s.closes, opens = s.opens, disc = s.disconnected.length;
  s.sock!.destroy(); // the page side goes away (unkernel: a snapshot restore resets vsock)
  await until(() => s.closes > closes, 2000, 'the engine close event');
  check(s.disconnected.slice(disc).includes(doomedConn), `the engine ended the app's conn before 'close' (disconnect ${doomedConn})`);
  check(s.surfaces.size === 0, 'no surfaces left over from the old link');
  check(s.tokens === s.tokenCloses, `the engine closed every handle on link close (${s.tokens}/${s.tokenCloses})`);
  const gone = await Promise.race([doomed.exited, sleep(5000).then(() => null)]);
  check(gone !== null, `the relay dropped the app (simple-shm exited: ${gone && (gone.code ?? gone.sig)})`);
  await until(() => s.opens > opens, 5000, 'the relay to reconnect and the link to open again');
  check(relayLog.slice(logMark).some((l) => l.includes('closed; reconnecting')), 'relay logged the drop and reconnected');
  check(s.errors.every((e) => /aborted/.test(e)), `only the drop's own abort was reported (${s.errors.join('; ')})`);
  s.errors.length = 0;
  const info2 = await run('info', [], 10000);
  check(info2.code === 0 && info2.stdout.includes("'xdg_wm_base'"), 'wayland-info works through the new link');

  // from here the buffer source answers with promises (every open/read
  // settled a macrotask later): unkernel's worker-mode shape, frames stall
  // in order behind each read
  s.async = true;
  console.log('== async buffer source: weston-simple-shm ==');
  before = new Set(s.conns);
  const h0 = s.handleOpens;
  const again = app('shm');
  const a00 = s.commitEvents;
  await until(() => s.commitEvents >= a00 + 10, 10000, 'simple-shm commits on the new link');
  const againConn = newConn(s, before)!;
  const a0 = s.commitEvents, ab0 = s.bytesRead, at0 = performance.now();
  await sleep(2000);
  const arate = (s.commitEvents - a0) / ((performance.now() - at0) / 1000);
  const abytes = (s.bytesRead - ab0) / ((performance.now() - at0) / 1000);
  console.log(`  measured: ${arate.toFixed(1)} commits/s, ${(abytes / 1e6).toFixed(2)} MB/s read (async source)`);
  check(arate > 20, `steady commit stream with an async source (${arate.toFixed(1)}/s > 20/s)`);
  check(s.handleOpens - h0 <= 2, `simple-shm buffers each got one handle (${s.handleOpens - h0} HANDLE_OPENs)`);
  again.kill();
  await again.exited;
  await until(() => s.disconnected.includes(againConn), 3000, 'simple-shm conn close');
  await sleep(100);
  check(s.acks === s.commitFrames, `every COMMIT ACKed, also across the conn close (${s.acks}/${s.commitFrames})`);
  check(s.tokens === s.tokenCloses, `every opened handle closed (${s.tokens}/${s.tokenCloses})`);
  check(s.errors.length === 0 && s.badFrame === null, 'no engine error events, sane frames');

  console.log('== async buffer source: foot ==');
  await footPhase(s);

  // --- the copy backend over the same stream transport -------------------------
  // a new relay run (--buffers copy) connects to the same engine: BUFFER and
  // BUFFER_LZ frames, engine-fired frame callbacks, the buffer source unused
  console.log('== copy backend over a stream link (--buffers copy), same engine ==');
  const procfdRelay = relay!;
  const closes2 = s.closes, opens2 = s.opens, h1 = s.handleOpens, k1 = s.commitFrames, ack1 = s.acks;
  procfdRelay.kill();
  await new Promise<void>((r) => (procfdRelay.exitCode !== null || procfdRelay.signalCode !== null ? r() : procfdRelay.once('exit', () => r())));
  await until(() => s.closes > closes2, 3000, 'the engine to see the relay go');
  s.errors.length = 0; // the relay's death may surface as a reset
  startRelay('copy');
  await until(() => s.opens > opens2, 5000, 'the copy relay to connect');
  const cp = app('shm');
  const k00 = s.commitEvents;
  s.formats.clear();
  await until(() => s.commitEvents >= k00 + 10, 10000, 'simple-shm commits in copy mode');
  const k0 = s.commitEvents, kl0 = engine.stats.bytesIn, kt0 = performance.now();
  await sleep(2000);
  const ksecs = (performance.now() - kt0) / 1000;
  const krate = (s.commitEvents - k0) / ksecs;
  console.log(`  measured: ${krate.toFixed(1)} commits/s, ${((engine.stats.bytesIn - kl0) / ksecs / 1e6).toFixed(2)} MB/s of link messages (swizzled, trimmed, LZ4)`);
  const kimg = [...s.images.values()][0];
  check(krate > 30, `steady commit stream in copy mode (${krate.toFixed(1)}/s)`);
  check([...s.formats].join() === 'rgba' && s.badFrame === null, `commits are packed rgba (${[...s.formats]})${s.badFrame ? ` — ${s.badFrame}` : ''}`);
  check(colours(kimg) > 4 && kimg.hashes!.size > 20, `pixels non-blank and changing (${kimg.hashes!.size} distinct images)`);
  check(s.commitFrames === k1 && s.handleOpens === h1 && s.acks === ack1, 'no handle frames, no ACKs');
  check(s.errors.length === 0, 'no engine error events');
  check(s.opens === 3 && s.closes === 2, `one engine served three relay connections (${s.opens} opens, ${s.closes} closes)`);
  cp.kill();
  await cp.exited;

  // --- GPU resources beside handles: --buffers procfd --dmabuf virtgpu ---------
  console.log('== dmabuf virtgpu beside procfd handles (--dmabuf virtgpu:@fake, test-only device) ==');
  if (realApps) {
    console.log('  skipped: fixtures only (virtgpu:@fake takes memfds, not a real GPU\'s dmabufs)');
    return;
  }
  if (!/virtgpu/.test(spawnSync(RELAY[0], [...RELAY.slice(1), '--help'], { encoding: 'utf8' }).stderr ?? '')) {
    console.log('  skipped: this relay has no --dmabuf virtgpu (WLAND_E2E_RELAY: an older build)');
    return;
  }
  const copyRelay = relay!;
  const closes3 = s.closes, opens3 = s.opens;
  copyRelay.kill();
  await new Promise<void>((r) => (copyRelay.exitCode !== null || copyRelay.signalCode !== null ? r() : copyRelay.once('exit', () => r())));
  await until(() => s.closes > closes3, 3000, 'the engine to see the copy relay go');
  s.errors.length = 0;
  s.async = false; // ACK count == COMMIT count per message again
  // unkernel runs it with --no-fence-wait; a relay from before it lacks the token
  const version = spawnSync(RELAY[0], [...RELAY.slice(1), '--version'], { encoding: 'utf8' });
  const noFenceWait = version.status === 0 && / no-fence-wait( |$)/m.test(version.stdout);
  startRelay('procfd', ['--dmabuf', 'virtgpu:@fake', ...(noFenceWait ? ['--no-fence-wait'] : [])]);
  await until(() => s.opens > opens3, 5000, 'the virtgpu relay to connect');
  const g0 = s.gpuRefs.length, gk0 = s.commitFrames, ga0 = s.acks, gt0 = s.tokens;
  const shmApp = app('shm');
  const gpuApp = app('dmabuf');
  await until(() => s.gpuRefs.length > g0 + 40 && s.tokens > gt0, 10000, 'GPU and shm commits on one link');
  const refs = s.gpuRefs.slice(g0);
  check(/dmabuf: format XR24 modifier 0x00ffffffffffffff/.test(gpuApp.stdoutText), 'the GPU client chose XRGB8888 with the implicit modifier');
  // (a buffer released before the next frame is drawn again: one or both)
  const named = new Set(refs.map((r) => r.resource));
  check(named.size >= 1 && named.size <= 2 && [...named].every((r) => r >= 1), `${refs.length} kind-virtgpu COMMITs naming its buffers' resources (${[...named].join(', ')})`);
  check(refs.every((r) => r.width === 256 && r.height === 192 && r.format === 0x34325258 && r.modifier === 0x00ffffffffffffffn), 'refs carry its size, XR24 and MOD_INVALID');
  check([...s.formats].includes('bgrx') && [...s.formats].includes('gpu'), `shm commits by handle and GPU commits on the same link (${[...s.formats]})`);
  check(s.ackMismatch === null && s.acks - ga0 === s.commitFrames - gk0, `one ACK per COMMIT of either kind (${s.acks - ga0}/${s.commitFrames - gk0})`);
  shmApp.kill();
  gpuApp.kill();
  await shmApp.exited;
  await gpuApp.exited;
  await sleep(200);
  check(s.gpuReleases === s.gpuRefs.length, `every resolved image released (${s.gpuReleases}/${s.gpuRefs.length})`);
  check(s.tokens === s.tokenCloses, `every opened handle closed (${s.tokens}/${s.tokenCloses})`);
  check(s.errors.length === 0 && s.badFrame === null, `no engine error events, sane frames${s.errors.length ? ` (${s.errors.join('; ')})` : ''}`);
}

let code = 0;
try {
  await main();
  console.log('RELAY-E2E PASS');
} catch (e) {
  code = 1;
  console.error(`RELAY-E2E FAIL: ${(e as Error)?.stack || e}`);
  for (const p of children) if (p.stderrText) console.error(`  [${p.spawnfile}] ${p.stderrText.trim().split('\n').slice(-5).join('\n  ')}`);
} finally {
  for (const p of children) p.kill('SIGKILL');
  if (relay) relay.kill();
  server.close();
  rmSync(dir, { recursive: true, force: true });
  // sockets, intervals and child pipes may linger: exit explicitly
  setTimeout(() => process.exit(code), 100);
}
