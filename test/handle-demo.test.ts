// The handle demo's pieces (test/support: synthetic clients, the JS
// relay, kwshm-style exports + HandleSource, the links) driven against the
// real engine in Node, no DOM: frames flow, every COMMIT is ACKed, buffers
// are released on the deferred rule, input reaches the client, and nothing
// is reported as a violation — over both links, sync and async sources, and
// both pixel deliveries. Needs a prior `zig build`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createEngine, createStreamLink, type Link, type PixelFormat } from '../lib/engine.ts';
import { createShm, createHandleSource } from './support/kwshm.js';
import { memoryLinks, streamPair } from './support/links.js';
import { createRelay } from './support/relay.js';
import { createClient, XRGB8888, ARGB8888 } from './support/test-client.js';

const wasm = await readFile(new URL('../lib/wland.wasm', import.meta.url));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function run({ link, async, rgba }: { link: string; async: boolean; rgba: boolean }) {
  const violations: string[] = [];
  const violation = (v: string) => violations.push(v);
  const shm = createShm();
  const source = createHandleSource(shm, { async, violation });
  let relayLink: Link, engineLink: Link;
  if (link === 'stream') {
    const pair = streamPair();
    relayLink = createStreamLink(pair.relay);
    engineLink = createStreamLink(pair.engine);
  } else {
    ({ relay: relayLink, engine: engineLink } = memoryLinks());
  }
  const relay = createRelay({ link: relayLink, shm, violation });
  const clients = [
    createClient({ title: 'a', format: XRGB8888, width: 200, height: 160 }),
    createClient({ title: 'b', format: ARGB8888, width: 180, height: 150 }),
  ];
  const commits: { conn: number; format: PixelFormat; opaque: boolean }[] = [];
  let opened!: () => void;
  const open = new Promise<void>((r) => { opened = r; });
  const engine = await createEngine({
    wasm, link: engineLink, buffers: source, rgba,
    onEvent(ev) {
      if (ev.type === 'commit') {
        // XRGB pixels carry X = 0: alpha must come out opaque
        let opaque = true;
        if (ev.format === 'rgba') for (let i = 3; i < Math.min(ev.pixels.length, 4000); i += 4) opaque &&= ev.pixels[i] === 255;
        commits.push({ conn: ev.conn, format: ev.format, opaque });
      } else if (ev.type === 'error') violation(ev.detail);
      else if (ev.type === 'open') opened();
    },
  });
  engine.setOutput(1280, 720);
  engine.start();
  await open;
  clients.forEach((c) => c.start(relay, violation));
  // the frame clock
  let t = 0;
  const clock = setInterval(() => engine.tick((t += 16)), 4);
  try {
    await sleep(400);
    // pointer + keyboard into the first window: conn 1, surface 8 (the
    // client allocates registry 2, sync 3, four binds 4-7, then its surface)
    engine.pointerEnter(1, 8, 50, 80);
    for (let i = 0; i < 10; i++) { engine.pointerMotion(1, i, 50 + i * 8, 80 + i * 4); await sleep(10); }
    engine.pointerButton(1, 100, 0x110, true);
    engine.pointerButton(1, 101, 0x110, false);
    engine.keyboardEnter(1, 8);
    for (const k of [35, 18, 38]) { engine.key(1, 200, k, true); engine.key(1, 201, k, false); } // H E L
    await sleep(300);
    // a compositor-side resize: new pool and buffers; the old buffers'
    // handles close once their COMMITs are ACKed
    engine.requestResize(1, 8, 260, 200);
    await sleep(300);
  } finally {
    clearInterval(clock);
  }
  await sleep(50); // let the last ACKs land
  relay.check();
  return { violations, relay, source, shm, clients, commits };
}

for (const link of ['memory', 'stream']) {
  for (const async of [false, true]) {
    for (const rgba of [false, true]) {
      test(`demo over ${link} link, ${async ? 'async' : 'sync'} source, ${rgba ? 'rgba' : 'bgra/bgrx'}`, async () => {
        const r = await run({ link, async, rgba });
        assert.deepEqual(r.violations, []);
        const [a, b] = r.clients;
        assert.ok(a.stats.frames > 10 && b.stats.frames > 10, `frames ${a.stats.frames} ${b.stats.frames}`);
        assert.ok(r.relay.stats.commits > 20);
        // every COMMIT got its ACK, and releases follow the ACKs
        assert.equal(r.relay.stats.acks, r.relay.stats.commits);
        assert.ok(r.relay.stats.releases >= r.relay.stats.commits - 6);
        assert.equal(r.commits.length, r.relay.stats.commits);
        const formats = new Set(r.commits.map((c) => `${c.conn}:${c.format}`));
        assert.deepEqual([...formats].sort(), rgba ? ['1:rgba', '2:rgba'] : ['1:bgrx', '2:bgra']);
        assert.ok(r.commits.every((c) => c.opaque));
        // resized: the old generation's handles are gone (≤ 3 per client)
        assert.deepEqual([a.width, a.height], [260, 200]);
        assert.ok(r.relay.stats.handles <= 6, `handles ${r.relay.stats.handles}`);
        // handles: one per live buffer, and the engine holds exactly those
        assert.equal(r.source.stats.open, r.relay.stats.handles);
        assert.equal(r.shm.live, r.relay.stats.handles);
        // input arrived
        assert.equal(a.stats.typed, 'HEL');
        assert.equal(a.stats.clicks, 1);
        assert.ok(a.stats.keymap > 1000, 'keymap delivered through the relay');
        // one presentation feedback per frame, each presented (stamped by
        // the relay on the clients' clock: no violation) or discarded; the
        // last one or two may still wait for a tick that never came
        for (const c of r.clients) {
          const { frames, presented, discarded } = c.stats;
          assert.ok(presented > 5, `presented ${presented}`);
          assert.ok(frames - presented - discarded >= 0 && frames - presented - discarded <= 2, `frames ${frames} presented ${presented} discarded ${discarded}`);
        }
      });
    }
  }
}
