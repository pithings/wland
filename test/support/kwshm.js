// Shared memory, both sides of it.
//
// createShm() stands in for unkernel's kwshm device: the guest side exports
// a byte range of a "memfd" (here an ArrayBuffer) and gets an id back
// (KWSHM_IOC_EXPORT), and releases it later (KWSHM_IOC_RELEASE). The real
// relay does exactly those two ioctls (protocol/STREAM.md, handle kind 1).
//
// createHandleSource() is the embedder's half — what unkernel's page passes
// as `buffers` to createWland: open() resolves an export id (unkernel:
// `vm.shm.openId(id)`), read() copies bytes out of it, close() lets it go.
// It also polices the engine: a read after close, a double close or a read
// of a released export is a protocol violation, reported to the page.
//
// createGpuSource() is a stand-in virgl host for the gpu mode: the relay
// names a kwshm export as a GPU "resource" (relay.js gpu: true), and
// resolve() paints its rows into a canvas — what a real page would do from
// virglrenderer's texture.

const PAGE = 4096;

export function createShm() {
  const exports = new Map(); // id → {mem: Uint8Array view of the export, released}
  let nextId = 1;            // kwshm ids are cyclic; never reused within this demo
  return {
    get live() { return exports.size; },
    /** KWSHM_IOC_EXPORT: `offset` must be page-aligned and the range inside
     *  the file. Returns the export id. */
    export(file, offset, length) {
      if (offset % PAGE) throw new Error(`kwshm: offset ${offset} not page-aligned`);
      if (offset + length > file.byteLength) throw new Error('kwshm: range outside the file');
      const id = nextId++;
      exports.set(id, { mem: new Uint8Array(file, offset, length), released: false });
      return id;
    },
    /** KWSHM_IOC_RELEASE: the host's view of the export is gone from now on. */
    release(id) {
      const e = exports.get(id);
      if (!e) throw new Error(`kwshm: release of unknown export ${id}`);
      e.released = true;
      exports.delete(id);
    },
    lookup: (id) => exports.get(id),
  };
}

/** The HandleSource over createShm()'s exports. `async: true` answers every
 *  open() and read() with a promise that settles on a later task — the shape
 *  unkernel has when its kernel runs in a worker (copies, asynchronously).
 *  `shape`: 'read' (one call per span), 'readv' (all spans of a commit in
 *  one call: one promise when async) or 'view' (the export's memory itself,
 *  synchronously — `async` then applies to open() only). */
export function createHandleSource(shm, { async = false, violation, shape = 'read' }) {
  // sharedViews: views handed out that are SharedArrayBuffer memory
  const stats = { open: 0, reads: 0, bytes: 0, sharedViews: 0 };
  const later = (fn) => new Promise((resolve, reject) => {
    setTimeout(() => { try { resolve(fn()); } catch (e) { reject(e); } }, 0);
  });

  function open(handle) {
    if (handle.kind !== 'kwshm') throw new Error(`demo source: ${handle.kind} handles are not supported`);
    // bind the token to THIS export: once the guest releases it, reads fail
    // instead of resolving the (cyclic) id again
    const e = shm.lookup(handle.id);
    if (!e) throw new Error(`no kwshm export ${handle.id}`);
    if (e.mem.length !== handle.size) throw new Error(`export ${handle.id} is ${e.mem.length} bytes, handle says ${handle.size}`);
    stats.open++;
    return { e, id: handle.id, closed: false };
  }
  function read(token, offset, dst) {
    if (token.closed) violation(`engine read handle-export ${token.id} after closing it`);
    if (token.e.released) throw new Error(`export ${token.id} released`);
    dst.set(token.e.mem.subarray(offset, offset + dst.length));
    stats.reads++;
    stats.bytes += dst.length;
  }

  function readv(token, reads) {
    for (const r of reads) read(token, r.offset, r.dst);
  }
  function view(token, offset, length) {
    if (token.closed) violation(`engine viewed handle-export ${token.id} after closing it`);
    if (token.e.released) throw new Error(`export ${token.id} released`);
    stats.reads++;
    if (!(token.e.mem.buffer instanceof ArrayBuffer)) stats.sharedViews++;
    return token.e.mem.subarray(offset, offset + length);
  }

  return {
    stats,
    open: async ? (h) => later(() => open(h)) : open,
    read: async ? (t, o, d) => later(() => read(t, o, d)) : read,
    ...(shape === 'readv' && { readv: async ? (t, r) => later(() => readv(t, r)) : readv }),
    ...(shape === 'view' && { view }),
    close(token) {
      if (token.closed) violation(`engine closed handle-export ${token.id} twice`);
      token.closed = true;
      stats.open--;
    },
  };
}

/** A GpuSource (wland/engine) over createShm()'s exports: resource id =
 *  export id. resolve() swizzles the export's BGRA/BGRX rows into one
 *  reused canvas (alpha forced for 'XR24') and returns it; the view draws
 *  it during the commit's dispatch. Polices the copy-on-commit rule: a
 *  resolve of a released export, or a release(image) of an image other than
 *  the last one, is a violation. */
export function createGpuSource(shm, { violation }) {
  const stats = { resolves: 0, released: 0 };
  let canvas = null, ctx = null, lent = null;
  return {
    stats,
    resolve(ref) {
      const e = shm.lookup(ref.resource);
      if (!e) { violation(`gpu resolve of resource ${ref.resource}: no such export (released before its ACK?)`); return null; }
      const { width: w, height: h, stride, offset } = ref;
      if (!canvas || canvas.width !== w || canvas.height !== h) {
        canvas = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(w, h) : Object.assign(document.createElement('canvas'), { width: w, height: h });
        ctx = canvas.getContext('2d');
      }
      const img = ctx.createImageData(w, h);
      const opaque = ref.format === 0x34325258;
      for (let y = 0; y < h; y++) {
        for (let x = 0, s = offset + y * stride, d = y * w * 4; x < w; x++, s += 4, d += 4) {
          img.data[d] = e.mem[s + 2];
          img.data[d + 1] = e.mem[s + 1];
          img.data[d + 2] = e.mem[s];
          img.data[d + 3] = opaque ? 255 : e.mem[s + 3];
        }
      }
      ctx.putImageData(img, 0, 0);
      stats.resolves++;
      lent = canvas;
      return canvas;
    },
    release(image) {
      if (image !== lent) violation('gpu release of an image that was not just lent');
      lent = null;
      stats.released++;
    },
  };
}
