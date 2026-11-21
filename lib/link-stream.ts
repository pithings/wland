// The byte-stream link: the engine's other end is a relay started with
// `--link fd:N|unix:PATH|vsock:CID:PORT` (in unkernel, a kwvsock connection).
// A stream has no message boundaries, so every message travels as a record
// (protocol/STREAM.md "Stream transport"):
//
//   u32 len (little-endian, 1 ≤ len ≤ 256 MiB) · u8 message[len]
//
// where `message` is exactly what one WebSocket message carries. Records
// arrive split and coalesced arbitrarily; the reader reassembles them without
// knowing any frame type. The source is one stream (a promise of one), or an
// async iterable of streams — e.g. unkernel's VsockListener, which yields the
// relay's connection again each time it reconnects: the link then opens once
// per stream. createStreamLink's doc below is the contract.

import type { ClosableLink, LinkCallbacks } from './engine.ts';

/** A connected byte stream: web streams, as unkernel's `VsockConnection`
 *  has them (`vm.vsock.listen(port)` → accept), or Node's
 *  `stream.Duplex.toWeb(socket)`. */
export interface ByteStream {
  readonly readable: ReadableStream<Uint8Array>;
  readonly writable: WritableStream<Uint8Array>;
  /** Called once when the link is done with the stream (if present). */
  close?(): void;
}

/** What createStreamLink serves: one stream, a promise of one, or an async
 *  iterable of streams served one after another — unkernel's VsockListener
 *  (`vm.vsock.listen(port)`) is one, yielding the relay's connection again
 *  every time the relay reconnects (it does after every drop, e.g. a snapshot
 *  restore resetting vsock). */
export type StreamSource = ByteStream | Promise<ByteStream> | AsyncIterable<ByteStream>;

const MAX_RECORD = 256 * 1024 * 1024;

const reason = (e: unknown) => (e instanceof Error && e.message ? e.message : String(e));
const SILENT: LinkCallbacks = { onOpen() {}, onMessage() {}, onClose() {}, onError() {} };
const closeStream = (st: ByteStream | undefined) => { try { if (st && st.close) st.close(); } catch { /* its own problem */ } };
const isIterable = (s: StreamSource): s is AsyncIterable<ByteStream> & { close?(): void } =>
  !!s && typeof (s as AsyncIterable<ByteStream>)[Symbol.asyncIterator] === 'function';

/** The stream being served. */
interface Served {
  s: ByteStream;
  reader: ReadableStreamDefaultReader<Uint8Array>;
  writer: WritableStreamDefaultWriter<Uint8Array>;
  closed: boolean;
  buffered: number;
}

/**
 * A Link over a byte stream to a relay
 * started with `--link` (STREAM.md "Stream transport"): every message
 * travels as a record, `u32 len` (little-endian, 1 ≤ len ≤ 256 MiB) followed
 * by `len` bytes of packed STREAM frames, the same bytes one WebSocket
 * message carries.
 *
 * - start(): waits for `stream` if it is a promise, then onOpen(). Reads
 *   chunks (arbitrary boundaries: a record may be split across chunks or
 *   several may share one) and calls onMessage once per record with a fresh
 *   ArrayBuffer holding exactly that record's message (no header).
 * - send(bytes): writes the record header and `bytes` as one chunk, so
 *   records never interleave; writes stay in call order.
 * - bufferedAmount: bytes passed to send() whose write has not completed.
 * - A header outside the bounds is fatal: onError, then the stream is closed
 *   and onClose. The readable ending → onClose; either side erroring →
 *   onError, then onClose. onClose fires once per stream; `stream.close()`
 *   is called once, then. `takenOver` is always false (a stream link that
 *   loses a takeover is simply closed by the relay).
 * - An async iterable source: each stream it yields is served as above
 *   (onOpen … onClose; record reassembly starts afresh), then the next one.
 *   send() between streams is dropped. If the iterable throws: onError,
 *   onClose, and the link is done.
 * - close(): ends the stream being served (`stream.close()`), and an
 *   iterable source that has a close() method (unkernel's VsockListener:
 *   it stops listening, so the port is free for the next link); a stream
 *   the source yields afterwards is closed unserved. No callback after it.
 */
export function createStreamLink(source: StreamSource): ClosableLink {
  let cb: LinkCallbacks = SILENT; // start() sets the engine's
  let cur: Served | null = null;
  let stopped = false; // close() was called

  // Fatal or final for this stream: tell the engine once, release it once.
  function finish(c: Served, error?: string) {
    if (c.closed) return;
    c.closed = true;
    if (cur === c) cur = null;
    if (error !== undefined) cb.onError(String(error));
    c.reader.cancel().catch(() => {});
    c.writer.abort().catch(() => {});
    closeStream(c.s);
    cb.onClose({ takenOver: false });
  }

  // Serve one stream until it ends; resolves then (never rejects).
  async function serve(st: ByteStream) {
    let c: Served;
    try {
      c = { s: st, reader: st.readable.getReader(), writer: st.writable.getWriter(), closed: false, buffered: 0 };
    } catch (e) { // not a usable stream (e.g. already locked)
      cb.onError(reason(e));
      cb.onClose({ takenOver: false });
      return;
    }
    cur = c;
    cb.onOpen();

    // reassembly state: a partial header, or a record being filled
    const head = new Uint8Array(4);
    let headFill = 0;
    let rec: Uint8Array<ArrayBuffer> | null = null, recFill = 0;

    function feed(chunk: Uint8Array) {
      const n = chunk.length;
      let off = 0;
      while (off < n && !c.closed) {
        if (rec === null) {
          let len: number;
          if (headFill === 0 && n - off >= 4) {
            len = (chunk[off] | chunk[off + 1] << 8 | chunk[off + 2] << 16 | chunk[off + 3] << 24) >>> 0;
            off += 4;
          } else {
            const take = Math.min(4 - headFill, n - off);
            head.set(chunk.subarray(off, off + take), headFill);
            headFill += take;
            off += take;
            if (headFill < 4) break;
            headFill = 0;
            len = (head[0] | head[1] << 8 | head[2] << 16 | head[3] << 24) >>> 0;
          }
          if (len < 1 || len > MAX_RECORD) return finish(c, `stream link: bad record length ${len}`);
          if (n - off >= len) {
            // the whole record is in this chunk: one copy, into its own buffer
            // (not chunk.slice: on a Node Buffer that is a view of its pool)
            const msg = new Uint8Array(chunk.subarray(off, off + len));
            off += len;
            cb.onMessage(msg.buffer);
            continue;
          }
          rec = new Uint8Array(len);
          recFill = 0;
        }
        const take = Math.min(rec.length - recFill, n - off);
        rec.set(chunk.subarray(off, off + take), recFill);
        recFill += take;
        off += take;
        if (recFill === rec.length) {
          const msg = rec;
          rec = null;
          cb.onMessage(msg.buffer);
        }
      }
    }

    try {
      for (;;) {
        const { value, done } = await c.reader.read();
        if (c.closed) return;
        if (done) return finish(c);
        if (value && value.length) feed(value);
      }
    } catch (e) {
      finish(c, reason(e));
    }
  }

  return {
    start(callbacks) {
      if (stopped) return;
      cb = callbacks;
      const failed = (e: unknown) => {
        // the source itself failed: the link is done for good
        cb.onError(reason(e));
        cb.onClose({ takenOver: false });
      };
      if (isIterable(source)) {
        (async () => {
          for await (const st of source) {
            if (stopped) { closeStream(st); break; }
            await serve(st);
          }
        })().catch(failed);
      } else {
        Promise.resolve(source as ByteStream | Promise<ByteStream>).then((st) => (stopped ? closeStream(st) : serve(st)), failed);
      }
    },
    // For good, and silently (no callback after it): ends the stream being
    // served, and an iterable source that can be closed (unkernel's
    // VsockListener: stops listening) — a stream arriving later is closed.
    close() {
      if (stopped) return;
      stopped = true;
      cb = SILENT;
      if (cur) finish(cur);
      if (isIterable(source) && typeof source.close === 'function') {
        try { source.close(); } catch { /* the source's own problem */ }
      }
    },
    send(bytes) {
      const c = cur;
      if (!c) return; // not open (yet, or any more): dropped
      const n = bytes.length;
      const rec = new Uint8Array(4 + n);
      new DataView(rec.buffer).setUint32(0, n, true);
      rec.set(bytes, 4);
      c.buffered += n;
      // one chunk per record: records never interleave, writes keep call order
      c.writer.write(rec).then(() => { c.buffered -= n; }, (e) => finish(c, reason(e)));
    },
    get bufferedAmount() {
      return cur ? cur.buffered : 0;
    },
  };
}
