// The transport between the demo's relay and the engine, two ways:
//
// - streamPair(): two in-page byte streams. Each end is wrapped in
//   createStreamLink, exactly as unkernel's page wraps a kwvsock connection
//   (`vm.vsock.listen(port)` → accept → {readable, writable}): u32-length
//   records, reassembled by the link. Relay→engine writes are cut at random
//   points on the way, like a real stream does.
// - memoryLinks(): a Link pair passing whole messages, no framing at all.
//
// Either way delivery is asynchronous (a later microtask or task), as it is
// on every real transport: the engine sends from inside a core call, and a
// synchronous reply would re-enter it.

/** Two Link ends wired to each other (lib/engine.ts `Link`). */
export function memoryLinks() {
  const end = () => ({
    cb: null,
    backlog: [],
    peer: null,
    bufferedAmount: 0,
    start(cb) {
      this.cb = cb;
      queueMicrotask(() => {
        cb.onOpen();
        for (const m of this.backlog.splice(0)) cb.onMessage(m);
      });
    },
    send(bytes) {
      const buf = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes.buffer : bytes.slice().buffer;
      const peer = this.peer;
      queueMicrotask(() => (peer.cb ? peer.cb.onMessage(buf) : peer.backlog.push(buf)));
    },
  });
  const engine = end(), relay = end();
  engine.peer = relay;
  relay.peer = engine;
  return { engine, relay };
}

/** Two ByteStreams (lib/engine.ts `ByteStream`) wired to each other. */
export function streamPair() {
  const toEngine = new TransformStream(), toRelay = new TransformStream();
  return {
    engine: { readable: toEngine.readable.pipeThrough(rechunk()), writable: toRelay.writable },
    relay: { readable: toRelay.readable, writable: toEngine.writable },
  };
}

// cut every chunk at random points: records reach the engine split across
// reads, as the kernel's socket buffers would deliver them
function rechunk() {
  return new TransformStream({
    transform(chunk, ctl) {
      for (let off = 0; off < chunk.length;) {
        const n = Math.min(chunk.length - off, 1 + Math.floor(Math.random() * (Math.random() < 0.5 ? 16 : 65536)));
        ctl.enqueue(chunk.subarray(off, off + n));
        off += n;
      }
    },
  });
}
