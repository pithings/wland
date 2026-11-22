// The handle path in a plain page, for tools/browser-e2e.ts `handle-demo`:
// wland's link-v2 handles with no server — synthetic clients, a JS relay and
// kwshm-style exports (test/support), the real engine and view.
//
//   guests (test-client.js) ⇄ relay (relay.js) ⇄ link (links.js) ⇄ engine + view (wland/client)
//                          └ kwshm exports (kwshm.js) ← HandleSource ┘
//
// Query parameters (the panel's toggles reload with them):
//   webgl=never|always   the view's presenter (default never: 2D, core-swizzled rgba)
//   async=1              the HandleSource answers with promises (worker-mode unkernel)
//   link=stream|memory   records over an in-page byte stream (default) or whole messages
//   gpu=1                COMMITs of kind virtgpu, resolved by a stand-in virgl host
//                        (createGpuSource) into a canvas the view draws
//   shape=readv|view     the HandleSource's batched read (one call per commit) or
//                        its in-place view (pixels straight from the export, no copy)
//   sab=1                the clients' pools are SharedArrayBuffers (with shape=view
//                        the commit's pixels are then shared memory); needs a
//                        cross-origin-isolated page (test/support/isolated.ts)
import { createWland } from '../../lib/client.ts';
import { createStreamLink } from '../../lib/engine.ts';
import { createShm, createHandleSource, createGpuSource } from '../support/kwshm.js';
import { memoryLinks, streamPair } from '../support/links.js';
import { createRelay } from '../support/relay.js';
import { createClient, XRGB8888, ARGB8888 } from '../support/test-client.js';

const params = new URLSearchParams(location.search);
const opts = {
  webgl: params.get('webgl') === 'always' ? 'always' : 'never',
  async: params.get('async') === '1',
  link: params.get('link') === 'memory' ? 'memory' : 'stream',
  gpu: params.get('gpu') === '1',
  shape: params.get('shape') === 'readv' || params.get('shape') === 'view' ? params.get('shape') : 'read',
  sab: params.get('sab') === '1',
};

const $ = (sel) => document.querySelector(sel);
const violations = [];
function violation(what) {
  violations.push(what);
  const li = document.createElement('li');
  li.textContent = what;
  $('#violations').append(li);
  console.warn('violation:', what);
}

// the guest side's shared memory, and the embedder's view of it
const shm = createShm();
const source = createHandleSource(shm, { async: opts.async, violation, shape: opts.shape });
const gpu = opts.gpu ? createGpuSource(shm, { violation }) : undefined;

// the link: two ends, one for the relay, one for the engine
let relayLink, engineLink;
if (opts.link === 'stream') {
  const pair = streamPair();
  relayLink = createStreamLink(pair.relay);
  engineLink = createStreamLink(pair.engine);
} else {
  ({ relay: relayLink, engine: engineLink } = memoryLinks());
}
const relay = createRelay({ link: relayLink, shm, violation, gpu: opts.gpu });

const clients = [];
const palette = [
  { title: 'xrgb window', format: XRGB8888, hue: 210, width: 420, height: 300 },
  { title: 'argb window', format: ARGB8888, hue: 330, width: 360, height: 260 },
];
if (opts.sab && !globalThis.crossOriginIsolated) {
  violation('sab=1: the page is not cross-origin isolated (COOP/COEP): no SharedArrayBuffer');
}
function spawn(i = clients.length) {
  const c = createClient({ ...palette[i % palette.length], shared: opts.sab });
  clients.push(c);
  c.start(relay, violation);
  return c;
}

const log = [];
let commitEvents = 0;
// the view cascades new windows; an embedder may place them itself (here:
// side by side, once each, after the first commit sized them)
const placed = new WeakSet();
let nextLeft = 24;
let wl = null;
function place() {
  if (!wl) return;
  for (const w of wl.view.windows()) {
    if (placed.has(w.element)) continue;
    placed.add(w.element);
    w.element.style.left = `${nextLeft}px`;
    w.element.style.top = '48px';
    nextLeft += w.element.offsetWidth + 24;
  }
}
wl = await createWland({
  container: $('#desktop'),
  link: engineLink,
  buffers: source,
  gpu,
  webgl: opts.webgl,
  onEvent(ev) {
    if (ev.type === 'commit') { commitEvents++; place(); }
    else if (ev.type === 'log') { log.push(ev.line); if (log.length > 2000) log.splice(0, 1000); }
    else if (ev.type === 'error') violation(`engine error: ${ev.detail}`);
    else if (ev.type === 'open') { spawn(); spawn(); }
  },
});

// --- the panel -------------------------------------------------------------
for (const [key, values] of Object.entries({ webgl: ['never', 'always'], async: [false, true], link: ['stream', 'memory'], gpu: [false, true], shape: ['read', 'readv', 'view'] })) {
  const box = $(`#opt-${key}`);
  for (const v of values) {
    const b = document.createElement('button');
    b.textContent = String(v === true ? 'on' : v === false ? 'off' : v);
    b.className = opts[key] === v ? 'on' : '';
    b.onclick = () => {
      const p = new URLSearchParams(location.search);
      p.set(key, v === true ? '1' : v === false ? '0' : v);
      location.search = p.toString();
    };
    box.append(b);
  }
}
$('#spawn').onclick = () => spawn();

const stats = () => ({
  commits: relay.stats.commits,
  acks: relay.stats.acks,
  releases: relay.stats.releases,
  presented: commitEvents,
  handles: relay.stats.handles,
  tokens: source.stats.open,
  exports: shm.live,
  reads: source.stats.reads,
  // sab=1: the page can make SharedArrayBuffers, and views handed out of one
  isolated: !!globalThis.crossOriginIsolated,
  sharedViews: source.stats.sharedViews,
  resolves: gpu ? gpu.stats.resolves : 0,
  gpuReleased: gpu ? gpu.stats.released : 0,
  violations: violations.length,
  frames: clients.map((c) => c.stats.frames),
  // presentation feedback per client: presented count, the last refresh (ns) and flags
  feedback: clients.map((c) => [c.stats.presented, c.stats.refresh, c.stats.flags]),
});

let lastT = performance.now(), lastCommits = 0;
setInterval(() => {
  relay.check();
  const s = stats();
  const now = performance.now();
  const fps = ((s.presented - lastCommits) * 1000) / (now - lastT);
  lastT = now;
  lastCommits = s.presented;
  $('#stats').textContent = [
    `COMMIT sent    ${s.commits}`,
    `ACK received   ${s.acks}`,
    `released       ${s.releases}`,
    `presented      ${s.presented}  (${fps.toFixed(0)}/s)`,
    `handles open   ${s.handles} relay · ${s.tokens} engine · ${s.exports} exports`,
    `reads          ${s.reads}  (${(source.stats.bytes / 1048576).toFixed(1)} MiB)`,
    `presenter      ${wl.view.stats.webgl ? 'webgl' : '2d'} · engine ${wl.view.webgl ? 'bgra/bgrx rows' : 'rgba (core swizzle)'}`,
    ...clients.map((c) => `${c.title.padEnd(14)} ${c.stats.alive ? `${c.stats.frames} frames, typed "${c.stats.typed}", ${c.stats.clicks} clicks` : c.stats.reason}`),
  ].join('\n');
  $('#violation-count').textContent = String(s.violations);
  $('#violation-count').className = s.violations ? 'bad' : 'good';
}, 250);

// the CDP test's view of the page (tools/browser-e2e.ts handle-demo)
window.handleDemo = { wl, opts, relay, source, shm, clients, stats, violations, log, spawn };
