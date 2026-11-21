// createStreamLink: u32-length records over a byte stream (STREAM.md
// "Stream transport"): reassembly across arbitrary chunk splits, bounds,
// write framing, close semantics. Web streams only, no engine.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStreamLink, type ByteStream, type StreamSource } from '../lib/engine.ts';

const tick = () => new Promise((r) => setTimeout(r, 0));

// a fake ByteStream: chunks we push become the readable; writes are recorded
function fakeStream() {
  let ctl!: ReadableStreamDefaultController<Uint8Array>;
  const written: Uint8Array[] = [];
  const s = {
    closes: 0,
    written,
    readable: new ReadableStream<Uint8Array>({ start(c) { ctl = c; } }),
    writable: new WritableStream<Uint8Array>({ write(chunk) { written.push(chunk); } }),
    close() { s.closes++; },
    push(bytes: Uint8Array) { ctl.enqueue(bytes); },
    end() { ctl.close(); },
    fail(e: unknown) { ctl.error(e); },
  };
  return s;
}

function record(bytes: Uint8Array) {
  const out = new Uint8Array(4 + bytes.length);
  new DataView(out.buffer).setUint32(0, bytes.length, true);
  out.set(bytes, 4);
  return out;
}

function started(stream: StreamSource) {
  const link = createStreamLink(stream);
  const got = { open: 0, messages: [] as number[][], errors: [] as string[], closes: [] as { takenOver: boolean }[] };
  link.start({
    onOpen: () => got.open++,
    onMessage: (buf) => { assert.ok(buf instanceof ArrayBuffer); got.messages.push([...new Uint8Array(buf)]); },
    onError: (d) => got.errors.push(d),
    onClose: (info) => got.closes.push(info),
  });
  return { link, got };
}

test('records reassemble across every chunk split', async () => {
  const msgs = [[1], [2, 3, 4, 5, 6], Array.from({ length: 300 }, (_, i) => i & 0xff), [7, 8]];
  const all = new Uint8Array(msgs.reduce((n, m) => n + 4 + m.length, 0));
  let off = 0;
  for (const m of msgs) { all.set(record(new Uint8Array(m)), off); off += 4 + m.length; }

  // every split point, every chunk size, plus one-byte drip
  const plans = [[all.length]];
  for (let cut = 1; cut < all.length; cut += 7) plans.push([cut, all.length - cut]);
  plans.push(Array(all.length).fill(1));
  for (const plan of plans) {
    const s = fakeStream();
    const { got } = started(s);
    await tick();
    let at = 0;
    for (const n of plan) { s.push(all.slice(at, at + n)); at += n; }
    await tick();
    assert.equal(got.open, 1);
    assert.deepEqual(got.messages, msgs, `split ${plan.length > 3 ? 'drip' : plan}`);
  }
});

test('send writes one record per call, in order; bufferedAmount tracks pending writes', async () => {
  const s = fakeStream();
  const { link } = started(Promise.resolve(s)); // a promised stream works too
  await tick();
  link.send(new Uint8Array([9, 9, 9]));
  link.send(new Uint8Array([1]));
  assert.equal(link.bufferedAmount, 4);
  await tick();
  assert.equal(link.bufferedAmount, 0);
  assert.deepEqual(s.written.map((c) => [...c]), [[3, 0, 0, 0, 9, 9, 9], [1, 0, 0, 0, 1]]);
});

test('a record length out of bounds is fatal: onError, close, onClose once', async () => {
  for (const len of [0, 256 * 1024 * 1024 + 1]) {
    const s = fakeStream();
    const { link, got } = started(s);
    await tick();
    const bad = new Uint8Array(8);
    new DataView(bad.buffer).setUint32(0, len, true);
    s.push(record(new Uint8Array([5])));
    s.push(bad);
    s.push(record(new Uint8Array([6]))); // never delivered
    await tick();
    assert.deepEqual(got.messages, [[5]]);
    assert.equal(got.errors.length, 1);
    assert.match(got.errors[0], /bad record length/);
    assert.deepEqual(got.closes, [{ takenOver: false }]);
    assert.equal(s.closes, 1);
    link.send(new Uint8Array([1])); // after close: dropped
    assert.equal(s.written.length, 0);
  }
});

test('end of stream → onClose once (no error); a stream error → onError, onClose', async () => {
  const a = fakeStream();
  const one = started(a);
  await tick();
  a.push(record(new Uint8Array([1, 2])).subarray(0, 3)); // a partial record at the end is dropped
  a.end();
  await tick();
  assert.deepEqual(one.got.errors, []);
  assert.deepEqual(one.got.closes, [{ takenOver: false }]);
  assert.equal(a.closes, 1);

  const b = fakeStream();
  const two = started(b);
  await tick();
  b.fail(new Error('reset by peer'));
  await tick();
  assert.equal(two.got.errors.length, 1);
  assert.match(two.got.errors[0], /reset by peer/);
  assert.deepEqual(two.got.closes, [{ takenOver: false }]);

  const c = started(Promise.reject(new Error('no such port')));
  await tick();
  assert.equal(c.got.open, 0);
  assert.match(c.got.errors[0], /no such port/);
  assert.equal(c.got.closes.length, 1);
});

test('Buffer chunks (a Uint8Array whose slice is a view of a shared pool) still give exact messages', async () => {
  const s = fakeStream();
  const { got } = started(s);
  await tick();
  // small Buffers come out of Node's shared allocation pool: byteOffset > 0,
  // .buffer is the whole pool, and Buffer#slice does not copy
  const chunk = Buffer.from([...record(new Uint8Array([1, 2, 3])), ...record(new Uint8Array([4]))]);
  assert.ok(chunk.byteOffset > 0 || chunk.buffer.byteLength > chunk.length, 'expected a pooled Buffer');
  s.push(chunk);
  await tick();
  assert.deepEqual(got.messages, [[1, 2, 3], [4]]);
});

test('an async iterable source: one open … close per stream, reassembly restarts, sends between streams dropped', async () => {
  const a = fakeStream(), b = fakeStream();
  let next!: () => void;
  const gate = new Promise<void>((r) => { next = r; });
  async function* streams() {
    yield a;
    await gate; // the relay reconnects later
    yield b;
  }
  const events: unknown[] = [];
  const link = createStreamLink(streams());
  link.start({
    onOpen: () => events.push('open'),
    onMessage: (buf) => events.push([...new Uint8Array(buf)]),
    onError: (d) => events.push(`error ${d}`),
    onClose: () => events.push('close'),
  });
  await tick();
  a.push(record(new Uint8Array([1])));
  a.push(record(new Uint8Array([2, 2])).subarray(0, 5)); // a partial record, then the stream ends
  link.send(new Uint8Array([7]));
  await tick();
  assert.deepEqual(a.written.map((c) => [...c]), [[1, 0, 0, 0, 7]]);
  a.end();
  await tick();
  assert.equal(a.closes, 1);
  link.send(new Uint8Array([8])); // between streams: dropped
  assert.equal(link.bufferedAmount, 0);
  next();
  await tick();
  b.push(record(new Uint8Array([3])));
  b.fail(new Error('reset'));
  await tick();
  assert.deepEqual(events, ['open', [1], 'close', 'open', [3], 'error reset', 'close']);
  assert.equal(b.written.length, 0);
  assert.equal(b.closes, 1);
});

test('an async iterable source that throws: onError, onClose, done', async () => {
  async function* streams(): AsyncGenerator<ByteStream> { throw new Error('listener closed'); }
  const events: string[] = [];
  createStreamLink(streams()).start({
    onOpen: () => events.push('open'),
    onMessage: () => events.push('message'),
    onError: (d) => events.push(`error ${d}`),
    onClose: () => events.push('close'),
  });
  await tick();
  assert.deepEqual(events, ['error listener closed', 'close']);
});

test('close(): ends the current stream and an iterable source with close(), silently; a late stream is closed unserved', async () => {
  type Fake = ByteStream & { closed: number };
  const calls: string[] = [];
  const streams: Fake[] = [];
  let sourceClosed = 0;
  let deliverNext!: (st: Fake) => void;
  const source = {
    close() { sourceClosed++; },
    async *[Symbol.asyncIterator]() {
      for (;;) {
        const st = await new Promise<Fake>((r) => { deliverNext = r; });
        yield st;
      }
    },
  };
  const mkStream = () => {
    const t = new TransformStream<Uint8Array, Uint8Array>();
    const st: Fake = { readable: t.readable, writable: new WritableStream(), closed: 0, close() { st.closed++; } };
    streams.push(st);
    return st;
  };
  // createStreamLink's links always have close(); Link declares it optional
  const link = createStreamLink(source);
  link.start({
    onOpen: () => calls.push('open'),
    onMessage: () => calls.push('message'),
    onClose: () => calls.push('close'),
    onError: (e) => calls.push(`error ${e}`),
  });
  await new Promise((r) => setTimeout(r, 0));
  deliverNext(mkStream());
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(calls, ['open']);

  link.close();
  link.close();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(calls, ['open'], 'no callback after close()');
  assert.equal(streams[0].closed, 1);
  assert.equal(sourceClosed, 1);
  link.send(new Uint8Array([1, 2, 3])); // dropped, no throw

  // the source yields once more anyway: closed, never served
  deliverNext(mkStream());
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(streams[1].closed, 1);
  assert.deepEqual(calls, ['open']);
});
