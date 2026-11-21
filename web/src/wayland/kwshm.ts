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

import type { BufferHandle, HandleSource } from 'wland/engine';

const PAGE = 4096;

/** One kwshm export. */
export interface ShmExport {
  mem: Uint8Array<ArrayBuffer>;
  released: boolean;
}

export interface Shm {
  readonly live: number;
  export(file: ArrayBuffer, offset: number, length: number): number;
  release(id: number): void;
  lookup(id: number): ShmExport | undefined;
}

export function createShm(): Shm {
  const exports = new Map<number, ShmExport>(); // id → {mem: Uint8Array view of the export, released}
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

/** What createHandleSource() hands out per open(): bound to one export. */
export interface ShmToken {
  e: ShmExport;
  id: number;
  closed: boolean;
}

export interface DemoHandleSource extends HandleSource<ShmToken> {
  stats: { open: number; reads: number; bytes: number };
}

/** The HandleSource over createShm()'s exports. `async: true` answers every
 *  open() and read() with a promise that settles on a later task — the shape
 *  unkernel has when its kernel runs in a worker (copies, asynchronously). */
export function createHandleSource(
  shm: Shm,
  { async = false, violation }: { async?: boolean; violation: (what: string) => void },
): DemoHandleSource {
  const stats = { open: 0, reads: 0, bytes: 0 };
  const later = <R>(fn: () => R) => new Promise<R>((resolve, reject) => {
    setTimeout(() => { try { resolve(fn()); } catch (e) { reject(e); } }, 0);
  });

  function open(handle: BufferHandle): ShmToken {
    if (handle.kind !== 'kwshm') throw new Error(`demo source: ${handle.kind} handles are not supported`);
    // bind the token to THIS export: once the guest releases it, reads fail
    // instead of resolving the (cyclic) id again
    const e = shm.lookup(handle.id);
    if (!e) throw new Error(`no kwshm export ${handle.id}`);
    if (e.mem.length !== handle.size) throw new Error(`export ${handle.id} is ${e.mem.length} bytes, handle says ${handle.size}`);
    stats.open++;
    return { e, id: handle.id, closed: false };
  }
  function read(token: ShmToken, offset: number, dst: Uint8Array): void {
    if (token.closed) violation(`engine read handle-export ${token.id} after closing it`);
    if (token.e.released) throw new Error(`export ${token.id} released`);
    dst.set(token.e.mem.subarray(offset, offset + dst.length));
    stats.reads++;
    stats.bytes += dst.length;
  }

  return {
    stats,
    open: async ? (h: BufferHandle) => later(() => open(h)) : open,
    read: async ? (t: ShmToken, o: number, d: Uint8Array) => later(() => read(t, o, d)) : read,
    close(token) {
      if (token.closed) violation(`engine closed handle-export ${token.id} twice`);
      token.closed = true;
      stats.open--;
    },
  };
}
