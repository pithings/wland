// A HandleSource for `procfd` handles (protocol/STREAM.md handle kind 2):
// relay and engine on one Linux machine as the same user, the engine in
// Node. For tests and debugging only — no isolation of any kind. Node-only
// (node:fs); not part of the package: an example of the HandleSource an
// embedder supplies (EngineOptions.buffers).
//
//   import { createProcfdSource } from './handles-procfd.ts';
//   const engine = await createEngine({ link, buffers: createProcfdSource(), onEvent });

import { closeSync, openSync, readSync } from 'node:fs';
import type { BufferHandle, HandleSource } from '../../lib/engine.ts';

/** The token: our own fd on the relay's file, and the file offset of handle
 *  byte 0. */
export interface ProcfdToken {
  fd: number;
  base: number;
}

/** A HandleSource that is synchronous throughout and ignores `conn`. */
export interface ProcfdSource extends HandleSource<ProcfdToken> {
  open(handle: BufferHandle, conn?: number): ProcfdToken;
  read(token: ProcfdToken, offset: number, dst: Uint8Array): void;
}

/** open() opens `/proc/<pid>/fd/<fd>` read-only (synchronously) and keeps
 *  that fd until close(); read() is a synchronous pread loop; any other
 *  handle kind is refused (the engine then reports the handle broken). */
export function createProcfdSource(): ProcfdSource {
  return {
    // open our own fd now, so the relay closing or reusing its fd number
    // later cannot redirect the handle
    open(handle) {
      if (handle.kind !== 'procfd') throw new Error(`procfd source: cannot open a ${handle.kind} handle`);
      return { fd: openSync(`/proc/${handle.pid}/fd/${handle.fd}`, 'r'), base: handle.offset };
    },
    read(token, offset, dst) {
      for (let done = 0; done < dst.length;) {
        const n = readSync(token.fd, dst, done, dst.length - done, token.base + offset + done);
        if (n === 0) throw new Error(`procfd source: end of file at byte ${token.base + offset + done}`);
        done += n;
      }
    },
    close(token) {
      try { closeSync(token.fd); } catch { /* already gone */ }
    },
  };
}
