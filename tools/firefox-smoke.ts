// Firefox smoke: wland/client in headless Firefox over WebDriver BiDi (no
// geckodriver, no playwright: Firefox's own --remote-debugging-port and
// Node's WebSocket). Not the browser E2E (that is chromium + CDP,
// tools/browser-e2e.ts); a bounded check that the client works in Gecko:
//
//   1. /handle-demo.html (synthetic clients, the JS relay, kwshm-style
//      handles; no server session) in several modes: two windows paint and
//      animate, opaque, channel order right, every COMMIT ACKed, no
//      violation, and a click and typed keys reach the client under the
//      pointer. The sab=1 modes (SharedArrayBuffer pools, pixels viewed in
//      shared memory) load through a cross-origin-isolated mirror of the
//      server (test/support/isolated.ts: COOP/COEP).
//   2. The test page against a real wlandr with the `term` fixture: the
//      window appears and paints, a click focuses it, typed keys and Enter
//      change its pixels.
//   3. The clipboard bridge there: the page clipboard's text pasted into the
//      term by Ctrl+Shift+V (Gecko's paste event targets the body and comes
//      after the keyup), the term's Ctrl+Shift+C reaching the page clipboard
//      (writeText within the key's activation), read back by Ctrl+V into a
//      textarea.
//   4. A page text selection made before clicking into the desktop (Gecko
//      keeps it: the press is preventDefault'ed, the sink's focus does not
//      move it) is never copied from there: Ctrl+C in the term (an
//      interrupt) and a copy command leave the page clipboard as it was.
//
//   node tools/firefox-smoke.ts        (after `zig build`; needs bun for the
//                                       page bundle, and firefox on PATH or
//                                       in $FIREFOX)
//
// Firefox runs with its TMPDIR in the profile (removed at the end: it copies
// a built-in add-on, ~4 MB, to $TMPDIR/tmp-XXX.xpi at every start) and is
// asked to close over BiDi before its process group is killed.
//
// Headless Firefox here has no WebGL (no GPU, and Gecko refuses software GL
// headless), so only the 2D presenter runs; the view would not pick WebGL
// on a software renderer anyway.

import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { app } from '../test/support/apps.ts';
import { isolatedMirror } from '../test/support/isolated.ts';

const ROOT = new URL('..', import.meta.url).pathname;
const PORT = Number(process.env.PORT || 8951);
const BIDI = Number(process.env.BIDI || 9351);
const DISPLAY = process.env.WAYLAND_DISPLAY_SMOKE || 'wayland-ffsmoke';
const FIREFOX = process.env.FIREFOX || 'firefox';
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const procs: ChildProcess[] = [];
const dirs: string[] = [];
// each child is spawned detached (its own process group): killing the group
// takes Firefox's content processes with it
function cleanup() {
  for (const p of procs.splice(0)) {
    try { if (p.pid) process.kill(-p.pid, 'SIGKILL'); } catch { try { p.kill('SIGKILL'); } catch { /* gone */ } }
  }
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
}
process.on('exit', cleanup);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) {
  process.on(sig, () => {
    console.error(`firefox-smoke: ${sig}, cleaning up`);
    cleanup();
    process.exit(128 + (sig === 'SIGINT' ? 2 : sig === 'SIGTERM' ? 15 : 1));
  });
}
function fail(msg: string): never {
  console.error(`firefox-smoke FAIL: ${msg}`);
  cleanup();
  process.exit(1);
}
// Firefox closes itself (its temp files with it) when asked over BiDi;
// cleanup's SIGKILL is for what does not
async function closeFirefox() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  const exited = new Promise<void>((res) => { if (firefox.exitCode !== null || firefox.signalCode !== null) res(); else firefox.once('exit', () => res()); });
  try { await send('browser.close', {}, 3000); } catch { /* closing: the answer may not come */ }
  await Promise.race([exited, sleep(5000)]);
}

// --- WebDriver BiDi ---------------------------------------------------------

let ws!: WebSocket;
let nextId = 0;
let context = '';
const waiting = new Map<number, { res: (v: any) => void; rej: (e: Error) => void }>();
function send(method: string, params: object = {}, timeout = 15000): Promise<any> {
  const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((res, rej) => {
    waiting.set(id, { res, rej });
    setTimeout(() => { if (waiting.delete(id)) rej(new Error(`${method}: no answer in ${timeout} ms`)); }, timeout);
  });
}
async function bidiConnect() {
  for (let i = 0; i < 100; i++) {
    try {
      ws = new WebSocket(`ws://127.0.0.1:${BIDI}/session`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('connect')); });
      break;
    } catch { await sleep(200); }
  }
  if (ws.readyState !== WebSocket.OPEN) fail(`no WebDriver BiDi on port ${BIDI}`);
  ws.onmessage = (m) => {
    const msg = JSON.parse(String(m.data));
    const w = msg.id !== undefined && waiting.get(msg.id);
    if (!w) return;
    waiting.delete(msg.id);
    if (msg.type === 'error') w.rej(new Error(`${msg.error}: ${msg.message}`));
    else w.res(msg.result);
  };
  const s = await send('session.new', { capabilities: {} });
  console.log(`firefox ${s.capabilities.browserVersion} (WebDriver BiDi)`);
  context = (await send('browsingContext.getTree', {})).contexts[0].context;
  await send('browsingContext.setViewport', { context, viewport: { width: 1600, height: 1100 } });
}
/** The JSON value of a page expression (awaited). */
async function evalJs(expr: string): Promise<any> {
  const r = await send('script.evaluate', {
    expression: `(async () => JSON.stringify(await (${expr})))()`, target: { context }, awaitPromise: true,
  });
  if (r.type === 'exception') fail(`page exception: ${r.exceptionDetails.text} in ${expr.slice(0, 120)}`);
  return r.result.value === undefined ? undefined : JSON.parse(r.result.value);
}
const navigate = (url: string) => send('browsingContext.navigate', { context, url, wait: 'complete' });
async function click(x: number, y: number) {
  await send('input.performActions', { context, actions: [{ type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' }, actions: [
    { type: 'pointerMove', x: Math.round(x), y: Math.round(y), origin: 'viewport' },
    { type: 'pointerDown', button: 0 }, { type: 'pause', duration: 50 }, { type: 'pointerUp', button: 0 },
  ] }] });
}
/** Type `text` (WebDriver key values: '\uE006' is Enter, code "Enter"; '\uE007' is NumpadEnter). */
async function type(text: string) {
  const actions = [...text].flatMap((value) => [{ type: 'keyDown', value }, { type: 'keyUp', value }]);
  await send('input.performActions', { context, actions: [{ type: 'key', id: 'kb', actions }] });
}

// --- the stack ----------------------------------------------------------------

const webRoot = mkdtempSync(join(tmpdir(), 'wland-ff-root.'));
dirs.push(webRoot);
const built = spawnSync('bun', ['tools/browser-e2e.ts', 'build', webRoot], { cwd: ROOT, stdio: 'inherit' });
if (built.status !== 0) fail('bundling test/browser (bun tools/browser-e2e.ts build) failed');

const runtime = process.env.XDG_RUNTIME_DIR || '/tmp/wland-run';
spawnSync('mkdir', ['-p', runtime]);
const appEnv = { ...process.env, XDG_RUNTIME_DIR: runtime, WAYLAND_DISPLAY: DISPLAY };
const server = spawn(join(ROOT, 'zig-out/bin/wlandr'), ['--port', String(PORT), '--web-root', webRoot, '--display', DISPLAY],
  { env: appEnv, stdio: ['ignore', 'ignore', 'inherit'], detached: true });
procs.push(server);

const profile = mkdtempSync(join(tmpdir(), 'wland-ff-profile.'));
dirs.push(profile);
writeFileSync(join(profile, 'user.js'), [
  'user_pref("browser.shell.checkDefaultBrowser", false);',
  'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
  'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
  'user_pref("browser.startup.homepage_override.mstone", "ignore");',
].join('\n'));
// no WAYLAND_DISPLAY: Firefox would try to be a client of the socket its own page serves
const ffEnv: NodeJS.ProcessEnv = { ...process.env, MOZ_HEADLESS: '1', TMPDIR: join(profile, 'tmp') };
mkdirSync(ffEnv.TMPDIR!);
delete ffEnv.WAYLAND_DISPLAY;
const firefox = spawn(FIREFOX, ['--headless', '--no-remote', '--profile', profile, '--remote-debugging-port', String(BIDI), 'about:blank'],
  { env: ffEnv, stdio: 'ignore', detached: true });
procs.push(firefox);
await bidiConnect();
const origin = `http://127.0.0.1:${PORT}`;
const mirror = await isolatedMirror(origin);

// --- 1. the handle demo ---------------------------------------------------------

const SAMPLE = `(() => {
  const d = window.handleDemo;
  return d.wl.view.windows().map((w) => {
    const c = d.wl.view.canvas(w.conn, w.surface);
    const r = c.getBoundingClientRect();
    let point = null;
    for (let y = r.top + 70; y < r.bottom - 40 && !point; y += 13) {
      for (let x = r.left + 12; x < r.right - 30 && !point; x += 17) {
        if (document.elementFromPoint(x, y) === c) point = [x, y];
      }
    }
    const rb = d.wl.view.readPixels(w.conn, w.surface);
    let colored = 0, opaque = 0, red = 0, hash = 0;
    for (let i = 0; i < rb.data.length; i += 4) {
      if (rb.data[i] + rb.data[i + 1] + rb.data[i + 2] > 30) colored++;
      if (rb.data[i] > 200 && rb.data[i + 1] < 100 && rb.data[i + 2] < 90) red++;
      if (rb.data[i + 3] === 255) opaque++;
      hash = (hash * 31 + rb.data[i] + rb.data[i + 1] * 7 + rb.data[i + 2] * 13) | 0;
    }
    const client = d.clients[w.conn - 1];
    return { conn: w.conn, colored, opaque, red, pixels: rb.data.length / 4, hash, point,
             frames: client.stats.frames, typed: client.stats.typed, clicks: client.stats.clicks };
  });
})()`;

for (const mode of ['webgl=never', 'webgl=never&async=1&link=memory', 'shape=view', 'async=1&shape=readv', 'gpu=1',
  'sab=1&shape=view', 'sab=1&async=1&shape=readv', 'sab=1&gpu=1']) {
  const bad = (msg: string): never => fail(`handle-demo [${mode}]: ${msg}`);
  await navigate(`${mode.includes('sab=1') ? mirror.origin : origin}/handle-demo.html?${mode}`);
  let ready = false;
  for (let i = 0; i < 60 && !ready; i++) {
    await sleep(250);
    ready = await evalJs(`!!(window.handleDemo && handleDemo.wl.view.windows().length >= 2 && handleDemo.clients.every((c) => c.stats.frames > 10))`);
  }
  if (!ready) bad(`two animating windows never appeared: ${JSON.stringify(await evalJs('window.handleDemo && { v: handleDemo.violations, log: handleDemo.log.slice(-10) }'))}`);
  const a = await evalJs(SAMPLE);
  await sleep(600);
  const b = await evalJs(SAMPLE);
  for (let i = 0; i < 2; i++) {
    const w = b[i];
    if (w.colored < w.pixels * 0.5) bad(`window ${i} is (mostly) blank`);
    if (w.opaque < w.pixels * 0.99) bad(`window ${i} is not opaque`);
    if (w.red < 18 * 18) bad(`window ${i}: no red close box (channel order?)`);
    if (a[i].hash === w.hash) bad(`window ${i} is not animating`);
  }
  const target = b.find((w: any) => w.point) ?? bad('no uncovered point on a window');
  await click(target.point[0], target.point[1]);
  await sleep(150);
  await type('wland');
  await sleep(400);
  const after = (await evalJs(SAMPLE)).find((w: any) => w.conn === target.conn);
  if (after.clicks !== target.clicks + 1) bad(`click not reflected: ${target.clicks} → ${after.clicks}`);
  if (!after.typed.endsWith('WLAND')) bad(`keys not reflected: typed "${after.typed}"`);
  const s = await evalJs('handleDemo.stats()');
  const v = await evalJs('handleDemo.violations');
  if (v.length) bad(`violations: ${JSON.stringify(v)}`);
  if (s.acks < s.commits - 4) bad(`ACKs lag COMMITs: ${s.acks} vs ${s.commits}`);
  if (mode.includes('sab=1') && !(s.isolated && (!mode.includes('shape=view') || s.sharedViews > 0))) {
    bad(`not cross-origin isolated or no shared views: ${JSON.stringify(s)}`);
  }
  const kind = await evalJs("handleDemo.wl.view.stats.webgl > 0 ? 'webgl' : '2d'");
  console.log(`handle-demo [${mode}] ok: ${kind}, COMMIT ${s.commits} ACK ${s.acks}, click + keys reach the client`);
}

// --- 2. a real relay and the term fixture ---------------------------------------

await navigate(`${origin}/`);
let online = false;
for (let i = 0; i < 75 && !online; i++) {
  online = await evalJs('!!(window.wlandStatus && window.wlandStatus.websocket === true)');
  if (!online) await sleep(200);
}
if (!online) fail(`page did not come online: ${JSON.stringify(await evalJs('[window.wlandStatus, document.getElementById("status").textContent]'))}`);
const term = app('term');
const termProc = spawn(term.cmd, term.args, { env: { ...appEnv, ...term.env }, stdio: 'ignore', detached: true });
procs.push(termProc);

const MAIN = `(() => {
  const cs = [...document.querySelectorAll('#desktop canvas')].filter((c) => c.style.display !== 'none');
  const c = cs.length ? cs.reduce((a, b) => (a.width * a.height >= b.width * b.height ? a : b)) : null;
  if (!c) return null;
  // through the view's present backend (2D getImageData or GL draw + readPixels)
  const m = c.dataset.wland.match(/^c(\\d+)s(\\d+)$/);
  const rb = window.wland.view.readPixels(+m[1], +m[2]);
  if (!rb) return null;
  const d = rb.data;
  let sum = 0, colored = 0;
  for (let i = 0; i < d.length; i += 4) {
    sum = (sum * 31 + d[i] + d[i + 1] * 7 + d[i + 2] * 13) >>> 0;
    if (d[i] + d[i + 1] + d[i + 2] > 30) colored++;
  }
  const r = c.getBoundingClientRect();
  return { w: c.width, h: c.height, x: r.left, y: r.top, cw: r.width, ch: r.height, sum, colored, title: document.title,
           kind: window.wland.view.stats.webgl > 0 ? 'webgl' : '2d' };
})()`;
let main: any = null;
for (let i = 0; i < 75 && !(main && main.colored > 0); i++) {
  await sleep(200);
  main = await evalJs(MAIN);
}
if (!main || !main.colored) fail(`the term window never painted: ${JSON.stringify(main)}`);
await sleep(1000);
await click(main.x + main.cw / 2, main.y + main.ch / 2);
await sleep(300);
const before = await evalJs(MAIN);
await type('echo hi');
await sleep(700);
const typed = await evalJs(MAIN);
await type('\uE006');
await sleep(1000);
const after = await evalJs(MAIN);
if (typed.sum === before.sum) fail('typing did not change the terminal');
if (after.sum === typed.sum) fail('Enter did not change the terminal');
console.log(`relay + term: ${main.w}x${main.h} window painted (${main.kind}, "${main.title}"), typed keys and Enter repaint it`);

// --- 3. the clipboard bridge (lib/clipboard.ts) in Gecko ------------------------
// page → term: text the page wrote (writeText, inside a user activation) is
// pasted by Ctrl+Shift+V (the paste event) and runs as a retitling printf;
// term → page: its Ctrl+Shift+C (copies its last output line) reaches the
// page clipboard, read back by Ctrl+V into a textarea outside the desktop
const chord = (key: string) => send('input.performActions', { context, actions: [{ type: 'key', id: 'kb', actions: [
  { type: 'keyDown', value: '\uE009' }, { type: 'keyDown', value: '\uE008' }, { type: 'keyDown', value: key },
  { type: 'keyUp', value: key }, { type: 'keyUp', value: '\uE008' }, { type: 'keyUp', value: '\uE009' },
] }] });
const wrote = await send('script.evaluate', { expression: `navigator.clipboard.writeText("printf '\\\\033]2;FF-PASTED\\\\007'").then(() => 'ok', (e) => String(e))`,
  target: { context }, awaitPromise: true, userActivation: true });
if (wrote.result?.value !== 'ok') fail(`the page's writeText: ${JSON.stringify(wrote.result ?? wrote)}`);
await click(main.x + main.cw / 2, main.y + main.ch / 2);
await sleep(300);
await chord('V');
await sleep(300);
await type('\uE006');
const pasted = `document.title.includes('FF-PASTED') || window.wlandLog.some((l) => l.includes('set_title') && l.includes('FF-PASTED'))`;
for (let i = 0; i < 50 && !(await evalJs(pasted)); i++) await sleep(100);
if (!(await evalJs(pasted))) fail(`Ctrl+Shift+V did not paste the page clipboard into the term (title "${await evalJs('document.title')}")`);
await type('clear; echo wland-from-term\uE006');
await sleep(500);
await chord('C');
await sleep(500);
await evalJs(`(() => { const t = document.createElement('textarea'); t.id = 'ffclip'; document.body.appendChild(t); t.focus(); return true; })()`);
await send('input.performActions', { context, actions: [{ type: 'key', id: 'kb', actions: [
  { type: 'keyDown', value: '\uE009' }, { type: 'keyDown', value: 'v' }, { type: 'keyUp', value: 'v' }, { type: 'keyUp', value: '\uE009' },
] }] });
await sleep(300);
const back = await evalJs(`document.getElementById('ffclip').value`);
if (back !== 'wland-from-term') fail(`the term's Ctrl+Shift+C did not reach the page clipboard ("${back}"; log: ${await evalJs("window.wlandLog.filter((l) => l.includes('clipboard')).join(' | ')")})`);
console.log('clipboard: page → term by the paste event, term → page by writeText after the key');

// --- 4. a stale page selection is never copied from the desktop ----------------
// (the reviewer's repro: before the fix Ctrl+C in the term — an interrupt —
// fired Gecko's default copy of the page selection over the clipboard)
const USER = 'USER CLIPBOARD';
const put = await send('script.evaluate', { expression: `navigator.clipboard.writeText(${JSON.stringify(USER)}).then(() => 'ok', (e) => String(e))`,
  target: { context }, awaitPromise: true, userActivation: true });
if (put.result?.value !== 'ok') fail(`the page's writeText: ${JSON.stringify(put.result ?? put)}`);
const stale = await evalJs(`(() => {
  const p = document.createElement('p');
  p.id = 'ffstale';
  p.textContent = 'STALE PAGE TEXT';
  Object.assign(p.style, { position: 'fixed', left: '10px', bottom: '10px', margin: '0', zIndex: '10000', font: '30px sans-serif', background: '#fff', color: '#000' });
  document.body.appendChild(p);
  const r = p.getBoundingClientRect();
  return { x: r.left, y: r.top + r.height / 2, w: r.width };
})()`);
await send('input.performActions', { context, actions: [{ type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' }, actions: [
  { type: 'pointerMove', x: Math.round(stale.x + 2), y: Math.round(stale.y), origin: 'viewport' }, { type: 'pointerDown', button: 0 },
  { type: 'pointerMove', x: Math.round(stale.x + stale.w - 2), y: Math.round(stale.y), origin: 'viewport', duration: 100 }, { type: 'pointerUp', button: 0 },
] }] });
const selected = await evalJs('String(getSelection())');
if (!selected.includes('STALE')) fail(`could not select the page text ("${selected}")`);
await click(main.x + main.cw / 2, main.y + main.ch / 2);
await sleep(300);
const kept = await evalJs(`[String(getSelection()), document.activeElement && document.activeElement.isContentEditable]`);
await send('input.performActions', { context, actions: [{ type: 'key', id: 'kb', actions: [
  { type: 'keyDown', value: '\uE009' }, { type: 'keyDown', value: 'c' }, { type: 'keyUp', value: 'c' }, { type: 'keyUp', value: '\uE009' },
] }] });
await sleep(300);
// the browser's Edit > Copy while the desktop has the focus: the copy event is cancelled, nothing set
const cmd = await send('script.evaluate', { expression: `document.execCommand('copy')`, target: { context }, awaitPromise: true, userActivation: true });
await sleep(200);
await evalJs(`(() => { const t = document.getElementById('ffclip'); t.value = ''; t.focus(); return true; })()`);
await send('input.performActions', { context, actions: [{ type: 'key', id: 'kb', actions: [
  { type: 'keyDown', value: '\uE009' }, { type: 'keyDown', value: 'v' }, { type: 'keyUp', value: 'v' }, { type: 'keyUp', value: '\uE009' },
] }] });
await sleep(300);
const clip = await evalJs(`document.getElementById('ffclip').value`);
if (clip !== USER) fail(`the page clipboard changed under a stale page selection ("${clip}"; selection kept across the click: ${JSON.stringify(kept)}, execCommand: ${JSON.stringify(cmd.result)})`);
console.log(`clipboard: a page selection kept across the click (${JSON.stringify(kept[0])}) is not copied by Ctrl+C or a copy command in the desktop`);

console.log('FIREFOX-SMOKE PASS');
await mirror.close();
await closeFirefox();
cleanup();
process.exit(0);
