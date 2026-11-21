// The relay's role, in JS — in unkernel this is the `wlandr` guest
// binary (server/src/relay.zig with the kwshm buffer backend). It sits
// between Wayland clients (here: client.js over a socket stand-in) and the
// engine (over a Link), and does only what protocol/STREAM.md says a relay
// does with a handle backend:
//
// - forwards requests as WIRE frames and events back to the client;
// - wl_shm.create_pool: keeps the fd (here an ArrayBuffer), sends an FDMSG
//   with the wire bytes and an empty aux;
// - per wl_buffer, lazily before its first COMMIT: exports its bytes from
//   the page floor of its offset (kwshm), sends HANDLE_OPEN;
// - wl_surface.commit with damage: WIRE first, then COMMIT naming the handle,
//   the buffer geometry and the damage (full-buffer on the first COMMIT of a
//   surface or after a size change);
// - wl_buffer.release on the deferred rule: one release per busy period, once
//   the commit latched an attach AND every COMMIT naming the buffer is ACKed;
// - HANDLE_CLOSE + export release when a handle's refs (its live buffer +
//   un-ACKed COMMITs) reach zero; all of a conn's exports go when it closes;
// - wl_keyboard.keymap FDMSG from the engine: makes the "memfd" for the client.
//
// With `gpu: true` it plays a GPU-resource emitter instead (wlandr has
// none): each COMMIT is kind virtgpu, its "resource" the buffer's kwshm
// export id (the page's createGpuSource resolves it, standing in for a
// virgl host), everything else — handles, ACKs, releases — unchanged.
//
// Frame callbacks are forwarded (this is a stream link): the engine fires
// them from its frame clock. It also polices both sides and reports
// violations: an ACK for an unknown serial, a COMMIT left un-ACKed, a release
// while a COMMIT of that buffer is un-ACKed (its own rule, checked against a
// separate record), a protocol error that made the engine kill a client.

import {
  wlEach, wlMessage, eachEngineFrame, createBatch, stampPresented, monotonicNs, FD, HANDLE,
  connOpen, connClose, fdmsg, handleOpen, handleClose, kwshmBytes, shmCommit, virtgpuCommit,
} from './proto.js';

// wl_shm format → DRM fourcc (ARGB8888 'AR24', XRGB8888 'XR24')
const FOURCC = [0x34325241, 0x34325258];

const PAGE = 4096;
const MAX_RECTS = 64;
const ACK_DEADLINE_MS = 2000;

export function createRelay({ link, shm, violation, gpu = false }) {
  const conns = new Map();
  const batch = createBatch();
  const stats = { commits: 0, acks: 0, releases: 0, handles: 0 };
  let nextConn = 1, nextHandle = 1, attached = false;
  const flush = () => {
    const m = batch.take();
    if (m && attached) link.send(new Uint8Array(m));
  };

  link.start({
    onOpen() { attached = true; },
    onMessage(buf) {
      eachEngineFrame(new Uint8Array(buf), (f) => {
        const c = conns.get(f.conn);
        if (!c) return; // a closed conn: ignored (STREAM.md)
        if (f.type === 'wire') c.client.receive(f.bytes.slice(), []);
        else if (f.type === 'fdmsg' && f.kind === FD.KEYMAP) c.client.receive(f.wire.slice(), [{ keymap: f.aux.slice() }]);
        else if (f.type === 'ack') onAck(c, f.serial);
        // wlandr's clock (CLOCK_MONOTONIC) replaces the page's frame time
        else if (f.type === 'presented') c.client.receive(stampPresented(f.bytes.slice(), monotonicNs(), f.age), []);
        else if (f.type === 'conn-close') {
          violation(`engine killed conn ${c.id} (protocol error — see the log)`);
          disconnect(c);
          c.client.killed('the compositor closed the connection');
        }
        // FDMSG pipe (clipboard) and SRVOBJ: no clipboard in this demo
      });
      flush();
    },
    onError(detail) { violation(`relay link error: ${detail}`); },
    onClose() { attached = false; for (const c of [...conns.values()]) disconnect(c); },
  });

  // un-ACKed COMMITs past the deadline are an engine bug (the page calls
  // this from its panel timer)
  function check() {
    const now = performance.now();
    for (const c of conns.values()) {
      for (const [serial, u] of c.unacked) {
        if (!u.late && now - u.at > ACK_DEADLINE_MS) {
          u.late = true;
          violation(`COMMIT conn ${c.id} serial ${serial} not ACKed after ${ACK_DEADLINE_MS} ms`);
        }
      }
    }
  }

  /** A client connects: the unix-socket accept. Returns its socket. */
  function connect(client) {
    const c = {
      id: nextConn++, client, serial: 0,
      objects: new Map([[1, 'wl_display']]),
      pools: new Map(), buffers: new Map(), surfaces: new Map(),
      unacked: new Map(), // serial → {buffer, handle, at}
      handles: new Set(),
    };
    conns.set(c.id, c);
    batch.push(connOpen(c.id));
    flush();
    return {
      id: c.id,
      write(bytes, fds) { if (conns.has(c.id)) { fromClient(c, bytes, fds); flush(); } },
      close() { if (conns.has(c.id)) disconnect(c); },
    };
  }

  function disconnect(c) {
    conns.delete(c.id);
    // the conn's handles die with it: no HANDLE_CLOSE (the engine closes
    // them on CONN_CLOSE), the exports are released
    for (const h of c.handles) shm.release(h.exportId);
    stats.handles -= c.handles.size;
    batch.push(connClose(c.id));
    flush();
  }

  // --- requests ------------------------------------------------------------
  function fromClient(c, bytes, fds) {
    wlEach(bytes, (obj, op, r, msg) => {
      const iface = c.objects.get(obj);
      const track = (id, name) => c.objects.set(id, name);
      switch (`${iface}.${op}`) {
        case 'wl_display.1': track(r.u32(), 'wl_registry'); break;          // get_registry
        case 'wl_registry.0': { r.u32(); const name = r.str(); r.u32(); track(r.u32(), name); break; } // bind
        case 'wl_compositor.0': {                                            // create_surface
          const id = r.u32();
          track(id, 'wl_surface');
          c.surfaces.set(id, { id, buffer: 0, attach: false, damage: [], scale: 1, dims: '' });
          break;
        }
        case 'wl_shm.0': {                                                   // create_pool(new_id, fd, size)
          const id = r.u32(), size = r.i32();
          track(id, 'wl_shm_pool');
          c.pools.set(id, { file: fds.shift(), size });
          // the fd stays here; the engine tracks the pool from the wire bytes
          batch.push(fdmsg(c.id, FD.SHM_POOL, msg));
          return;
        }
        case 'wl_shm_pool.0': {                                              // create_buffer
          const id = r.u32();
          track(id, 'wl_buffer');
          c.buffers.set(id, {
            id, pool: c.pools.get(obj), offset: r.i32(), width: r.i32(), height: r.i32(),
            stride: r.i32(), format: r.u32(), handle: null, owed: false, busy: 0,
          });
          break;
        }
        case 'wl_shm_pool.1': c.pools.delete(obj); break;                  // destroy (buffers keep the file)
        case 'wl_shm_pool.2': { const p = c.pools.get(obj); if (p) p.size = r.i32(); break; } // resize
        case 'wl_buffer.0': {                                                // destroy: never released again
          const b = c.buffers.get(obj);
          c.buffers.delete(obj);
          if (b && b.handle) unref(c, b.handle);
          break;
        }
        case 'wl_surface.0': c.surfaces.delete(obj); break;                // destroy
        case 'wl_surface.1': {                                               // attach
          const s = c.surfaces.get(obj);
          s.buffer = r.u32();
          s.attach = true;
          break;
        }
        case 'wl_surface.2': case 'wl_surface.9': {                          // damage, damage_buffer
          const s = c.surfaces.get(obj), k = op === 2 ? s.scale : 1;
          s.damage.push([r.i32() * k, r.i32() * k, r.i32() * k, r.i32() * k]);
          break;
        }
        case 'wl_surface.8': c.surfaces.get(obj).scale = Math.max(1, r.i32()); break; // set_buffer_scale
        case 'wl_surface.6':                                                 // commit: WIRE, then COMMIT
          batch.wire(c.id, msg);
          finishCommit(c, c.surfaces.get(obj));
          return;
      }
      batch.wire(c.id, msg);
    });
  }

  const fits = (b) => b.pool && (b.format === 0 || b.format === 1) && b.width > 0 && b.height > 0 &&
    b.stride >= b.width * 4 && b.offset >= 0 && b.offset + b.stride * b.height <= b.pool.size;

  function finishCommit(c, s) {
    if (!s) return;
    const owed = s.attach;
    s.attach = false;
    const b = s.buffer ? c.buffers.get(s.buffer) : null;
    if (b && owed) b.owed = true;
    let rects = [];
    for (const [x, y, w, h] of s.damage) {
      if (!b) break;
      const x0 = Math.max(0, x), y0 = Math.max(0, y);
      const x1 = Math.min(b.width, x + w), y1 = Math.min(b.height, y + h);
      if (x1 > x0 && y1 > y0) rects.push([x0, y0, x1 - x0, y1 - y0]);
    }
    s.damage = [];
    if (b && rects.length && fits(b)) {
      const dims = `${b.width}x${b.height}`;
      if (s.dims !== dims) rects = [[0, 0, b.width, b.height]]; // the engine's copy is gone
      else if (rects.length > MAX_RECTS) rects = [bbox(rects)];      // the cap: merge
      s.dims = dims;
      const h = b.handle || openHandle(c, b);
      if (h) {
        const serial = ++c.serial;
        batch.push(gpu
          ? virtgpuCommit(c.id, s.id, serial, { resource: h.exportId, width: b.width, height: b.height,
            format: FOURCC[b.format], offset: h.skew, stride: b.stride }, rects)
          : shmCommit(c.id, s.id, serial,
            { handle: h.id, offset: h.skew, width: b.width, height: b.height, stride: b.stride, format: b.format }, rects));
        b.busy++;
        h.refs++;
        c.unacked.set(serial, { buffer: b, handle: h, at: performance.now(), late: false });
        stats.commits++;
      }
    }
    if (b) releaseIfIdle(c, b);
  }

  function bbox(rects) {
    let [x0, y0, x1, y1] = [Infinity, Infinity, 0, 0];
    for (const [x, y, w, h] of rects) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x + w); y1 = Math.max(y1, y + h); }
    return [x0, y0, x1 - x0, y1 - y0];
  }

  // one handle per wl_buffer: [page_floor(offset), offset + stride·height)
  function openHandle(c, b) {
    const start = Math.floor(b.offset / PAGE) * PAGE;
    const size = b.offset + b.stride * b.height - start;
    let exportId;
    try { exportId = shm.export(b.pool.file, start, size); } catch (e) { violation(`export failed: ${e.message}`); return null; }
    const h = { id: nextHandle++, exportId, skew: b.offset - start, refs: 1 /* the buffer */ };
    b.handle = h;
    c.handles.add(h);
    stats.handles++;
    batch.push(handleOpen(c.id, h.id, HANDLE.KWSHM, kwshmBytes(exportId, size)));
    return h;
  }

  function unref(c, h) {
    if (--h.refs > 0) return;
    batch.push(handleClose(c.id, h.id));
    shm.release(h.exportId);
    c.handles.delete(h);
    stats.handles--;
  }

  function releaseIfIdle(c, b) {
    // a destroyed buffer is never released (its id may already be reused)
    if (!b.owed || b.busy > 0 || c.buffers.get(b.id) !== b) return;
    for (const u of c.unacked.values()) {
      if (u.buffer === b) violation(`relay released buffer ${b.id} while a COMMIT of it is un-ACKed`);
    }
    b.owed = false;
    stats.releases++;
    c.client.receive(wlMessage(b.id, 0), []); // wl_buffer.release
  }

  function onAck(c, serial) {
    const u = c.unacked.get(serial);
    if (!u) { violation(`ACK for unknown serial ${serial} on conn ${c.id}`); return; }
    c.unacked.delete(serial);
    stats.acks++;
    u.buffer.busy--;
    releaseIfIdle(c, u.buffer);
    unref(c, u.handle);
  }

  return { stats, connect, check, get conns() { return conns.size; } };
}
