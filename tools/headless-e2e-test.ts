#!/usr/bin/env node
// Real apps through the relay's WebSocket path, no browser:
//
//   wayland apps ─unix─► zig-out/bin/wlandr --port N  ─ws─► this
//                         process: wland/headless (engine + DOM-free scene)
//
// The app-level regression check: what an app does through the compositor
// (maps, draws, takes keys and pointer, pops up menus, resizes, survives a
// resize storm) is the core's and the relay's doing, and needs no browser to
// see. tools/browser-e2e.ts keeps only what is the browser's (DOM events,
// canvases, the window manager's grabs); tools/relay-e2e-test.ts covers the
// stream link and the handle backends.
//
// The apps are test/support/apps.ts's: wland-fixture modes by default (no
// dependency beyond `zig build`), the real apps named below with
// WLAND_E2E_APPS=real (a phase whose app is missing is then skipped).
// Phases, one headless client for all:
//  1. wayland-info: exit 0, the core globals.
//  2. weston-simple-shm: the screenshot is non-blank and animates.
//     weston-presentation-shm: wp_presentation over the WS link — frames
//     presented within 500 ms of their commit on the client's own
//     CLOCK_MONOTONIC (the relay stamps them), every feedback answered.
//     weston-flower (toytoolkit: wl_pointer.set_cursor with themed cursor
//     surfaces, no cursor-shape): hovering it, cursor() is its cursor
//     surface, with a drawn image and the hotspot inside it; leaving
//     resets it.
//     Pointer constraints + relative pointer, read off the clients'
//     WAYLAND_DEBUG / stdout: weston-constraints (a press on its subsurface
//     confines to it — dragged out with the button held the motion stays
//     clamped inside —, the next press locks: granted, relative motion only,
//     Escape breaks it without reaching the app); an SDL3 app through
//     python3 ctypes (skipped without them) in relative mouse mode: locked,
//     its xrel/yrel are the moves, re-locked by a press after Escape.
//     (fixtures: `cursor`, `constraints`, `relative`)
//  3. foot (fixture `term`): maps focused; typed keys (shift, symbols) run a printf that
//     retitles it; pixels change; CSD subsurfaces sit around the grid; a
//     pointer sweep, clicks and wheel leave it alive, motion coalesced;
//     the window policy's resize re-renders it.
//     Window states: foot put in and out of fullscreen by the compositor
//     (fills the output, takes keys, back to its size and place) and
//     minimized/restored (hidden, then raised and focused again);
//     weston-fullscreen asks itself ('f', and -f: mapped fullscreen).
//  4. clipboard: wl-copy → wl-paste across two conns.
//  5. nautilus (fixture `files`): renders; the hamburger menu is an
//     xdg_popup, an outside press dismisses it; its header bar's minimize
//     button (shown: wm_capabilities has minimize; nautilus's button layout
//     set in a keyfile of its own) hides it, restore() brings it back
//     focused; a double click navigates (title change); a resize storm
//     leaves it alive and drawing (the double-release regression: GTK's
//     commits without attach). The fixture also drags its file onto its
//     folder (wl_data_device dnd, one client).
//  6. x11 (real apps only, and only with xwayland-satellite, Xwayland and
//     xeyes installed): the relay claimed an X display; an X client
//     connecting to it starts satellite and gets a window.
//  7. output scale 2: foot attaches buffers at 2× its logical size.
//
// Needs `zig build` (wlandr, wland-fixture, lib/wland.wasm). Own
// XDG_RUNTIME_DIR, display name and port: it never touches a demo's session.
// Run: node tools/headless-e2e-test.ts   (V=1 shows the apps' stderr;
// WLAND_E2E_APPS=real for the real apps)

import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createHeadless, type Headless, type HeadlessWindow, type RgbaImage } from '../lib/headless.ts';
import { xDisplayOf } from '../lib/index.ts';
import { app, appSet, available, realApps, type AppRole, type AppSpec } from '../test/support/apps.ts';
import { parsePresentationShm, presentationChecks } from '../test/support/presentation-shm.ts';

const RELAY = fileURLToPath(new URL('../zig-out/bin/wlandr', import.meta.url));
const PORT = Number(process.env.PORT || 8937);
const dir = mkdtempSync('/tmp/wl-hl-');
const env: NodeJS.ProcessEnv = {
  ...process.env, XDG_RUNTIME_DIR: dir, WAYLAND_DISPLAY: 'wland-hl',
  // GTK: no GPU path here → the cairo renderer; pin the backend (tools/wland-run)
  GDK_BACKEND: 'wayland', GSK_RENDERER: 'cairo', XDG_SESSION_TYPE: 'wayland',
  // nautilus restores a maximized window from its saved state; the click
  // offsets below assume a floating start, so it gets a config of its own
  XDG_CONFIG_HOME: `${dir}/config`,
};
delete env.DISPLAY; // nothing here may fall back to X11

const ROLE_SUBSURFACE = 2, ROLE_POPUP = 4;
const procs = new Set<ChildProcess>();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function check(cond: unknown, what: string) {
  if (!cond) throw new Error(`FAIL: ${what}`);
  console.log(`  ok  ${what}`);
}
async function until(cond: () => unknown, ms: number, what: string) {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error(`timed out after ${ms} ms waiting for ${what}`);
    await sleep(20);
  }
}
function run(cmd: string, args: string[] = [], extra: NodeJS.ProcessEnv = {}): ChildProcess {
  if (process.env.V) console.log(`  $ ${cmd} ${args.map((a) => (a.length > 40 ? '…' : a)).join(' ')}`);
  const p = spawn(cmd, args, { env: { ...env, ...extra }, stdio: ['ignore', 'pipe', 'pipe'] });
  if (process.env.V) p.stderr!.on('data', (c) => process.stderr.write(c));
  p.stdout!.resume();
  procs.add(p);
  p.on('exit', () => procs.delete(p));
  return p;
}
const alive = (p: ChildProcess) => p.exitCode === null && p.signalCode === null;
async function stop(p: ChildProcess) {
  if (!alive(p)) return;
  p.kill();
  await until(() => !alive(p), 5000, 'an app to exit');
}
/** Run to completion WITHOUT blocking this process: the compositor serving
 *  the app is this event loop (spawnSync would deadlock it). */
function exec(spec: AppSpec, ms: number): Promise<{ status: number | null; stdout: string }> {
  return new Promise((resolve) => {
    const p = runApp(spec);
    let stdout = '';
    p.stdout!.on('data', (c) => { stdout += c; });
    const timer = setTimeout(() => p.kill('SIGKILL'), ms);
    p.on('close', (status) => { clearTimeout(timer); resolve({ status, stdout }); });
  });
}
/** Kill whatever still names our runtime dir (an app or the session bus
 *  left by a failed run). The services that bus activated don't name it:
 *  they exit when it goes. Bracketed so pkill does not match itself. */
function sweep() {
  spawnSync('pkill', ['-KILL', '-f', dir.replace('/tmp/wl-hl-', '/tmp/wl-hl[-]')]);
}
const have = (cmd: string) => spawnSync('sh', ['-c', `command -v ${cmd}`]).status === 0;
const runApp = (spec: AppSpec, extra: NodeJS.ProcessEnv = {}) => run(spec.cmd, spec.args, { ...spec.env, ...extra });
/** The app for a phase, or null (and a skip line) when it is not installed. */
function need(role: AppRole, args: string[] = []): AppSpec | null {
  const spec = app(role, args);
  if (available(spec)) return spec;
  console.log(`  skipped: ${spec.name} not installed`);
  return null;
}

const hash = (img: RgbaImage) => createHash('sha1').update(img.data).digest('hex');
/** Distinct colours among a sample of the pixels (blank = 1). */
function colours(img: RgbaImage): number {
  const px = new Uint32Array(img.data.buffer, img.data.byteOffset, img.data.byteLength >> 2);
  const seen = new Set<number>();
  for (let i = 0; i < px.length && seen.size < 256; i += 13) seen.add(px[i]!);
  return seen.size;
}

// --- the relay and one headless client for the whole run -------------------

// (an empty web root of its own: nothing is served, and sweep() must not
// find the relay by the runtime dir's name)
const webRoot = mkdtempSync('/tmp/wl-hlroot-');
const relay = run(RELAY, ['--port', String(PORT), '--web-root', webRoot, '--display', env.WAYLAND_DISPLAY!]);
let commits = 0, opened = false;
const errors: string[] = [];
const titles: string[] = [];
let hl!: Headless;

/** Commits stopped arriving for `quiet` ms. */
async function settle(quiet = 400) {
  for (let n = -1; n !== commits;) {
    n = commits;
    await sleep(quiet);
  }
}
async function oneWindow(what: string): Promise<HeadlessWindow> {
  await until(() => hl.windows().length === 1, 20000, `${what}'s window`);
  await settle();
  return hl.windows()[0]!;
}
async function noWindows() {
  await until(() => hl.windows().length === 0, 5000, 'the windows to go');
}

async function info() {
  console.log('== wayland-info ==');
  const spec = need('info');
  if (!spec) return;
  const r = await exec(spec, 15000);
  check(r.status === 0, 'wayland-info exited 0');
  for (const g of ['wl_compositor', 'wl_shm', 'wl_seat', 'xdg_wm_base', 'wl_data_device_manager',
    'zwp_relative_pointer_manager_v1', 'zwp_pointer_constraints_v1', 'wp_presentation']) {
    check(r.stdout.includes(g), `${g} advertised`);
  }
}

async function shm() {
  console.log('== weston-simple-shm ==');
  const spec = need('shm');
  if (!spec) return;
  const app = runApp(spec);
  const before = commits;
  await until(() => commits > before + 20, 10000, 'simple-shm commits');
  const a = hl.screenshot();
  await sleep(300);
  const b = hl.screenshot();
  check(colours(b) > 4, `screenshot non-blank (${colours(b)} colours sampled)`);
  check(hash(a) !== hash(b), 'animating: two screenshots differ');
  await stop(app);
  await noWindows();
}

async function presentation() {
  console.log('== weston-presentation-shm: presentation feedback ==');
  const spec = need('presentation', ['-f']);
  if (!spec) return;
  const app = runApp(spec);
  let out = '';
  app.stdout!.on('data', (c) => { out += c; });
  await sleep(2000);
  app.kill('SIGINT'); // it then prints the feedbacks still outstanding
  await until(() => !alive(app), 5000, 'presentation-shm to exit');
  for (const [ok, what] of presentationChecks(parsePresentationShm(out), 60)) check(ok, what);
  await noWindows();
}

async function cursor() {
  console.log('== weston-flower: a cursor surface (set_cursor) ==');
  const spec = need('cursor');
  if (!spec) return;
  const app = runApp(spec);
  const win = await oneWindow(spec.name);
  hl.pointerMove(win.x + win.width / 2, win.y + win.height / 2);
  await until(() => hl.cursor()?.surface, 5000, 'set_cursor with a surface');
  const c = hl.cursor()!;
  const s = hl.surfaces().find((x) => x.conn === c.conn && x.surface === c.surface);
  check(s && s.role === 3, `cursor() names its cursor surface (role ${s?.role})`);
  const img = hl.surfacePixels(c.conn, c.surface)!;
  check(img.width > 0 && colours(img) >= 2, `the image is drawn (${img.width}x${img.height}, ${colours(img)} colours)`);
  check(c.hotspotX >= 0 && c.hotspotY >= 0 && c.hotspotX < s!.logicalWidth && c.hotspotY < s!.logicalHeight,
    `hotspot ${c.hotspotX},${c.hotspotY} inside the ${s!.logicalWidth}x${s!.logicalHeight} image`);
  check(hl.surfaceAt(win.x + win.width / 2, win.y + win.height / 2)?.surface === win.surface, 'the cursor surface takes no input');
  hl.pointerMove(1, 1);
  check(hl.cursor() === null, 'leaving the window: the default pointer');
  await stop(app);
  await noWindows();
}

/** An app whose stdout and stderr are kept (WAYLAND_DEBUG goes to stderr). */
function runLogged(spec: AppSpec, extra: NodeJS.ProcessEnv = {}) {
  const p = runApp(spec, extra);
  let text = '';
  p.stdout!.on('data', (c) => { text += c; });
  p.stderr!.on('data', (c) => { text += c; });
  return { p, text: () => text };
}

async function constraints() {
  console.log('== pointer constraints + relative pointer: weston-constraints ==');
  // a press on its surfaces cycles unconstrained → confined → locked
  // (both oneshot), on the gray subsurface in the middle
  const spec = need('constraints');
  if (!spec) return;
  const app = runLogged(spec, { WAYLAND_DEBUG: '1' });
  const win = await oneWindow(spec.name);
  const sub = hl.surfaces().find((s) => s.conn === win.conn && s.role === ROLE_SUBSURFACE)!;
  const sx = win.originX + sub.x + sub.logicalWidth / 2, sy = win.originY + sub.y + sub.logicalHeight / 2;
  const since = (re: RegExp, from: number) => re.exec(app.text().slice(from));
  hl.pointerMove(sx, sy);
  hl.pointerDown();
  await until(() => /zwp_confined_pointer_v1#\d+\.confined\(\)/.test(app.text()), 5000, 'confined()');
  const confinedAt = app.text().search(/zwp_confined_pointer_v1#\d+\.confined\(\)/);
  check(true, `a press on the subsurface: confined to it (${sub.logicalWidth}x${sub.logicalHeight})`);
  // dragged out with the button held (the implicit grab keeps the surface):
  // the client sees the pointer stop at the confinement's edge
  hl.pointerMove(sx + sub.logicalWidth, sy + 5);
  const edge = new RegExp(`wl_pointer#\\d+\\.motion\\(\\d+, (${sub.logicalWidth - 1}\\.\\d+), `);
  await until(() => since(edge, confinedAt), 5000, 'a motion clamped to the edge');
  check(true, `dragged ${sub.logicalWidth / 2} px past its edge: motion clamped at x=${since(edge, confinedAt)![1]}`);
  hl.pointerMove(sx, sy);
  hl.pointerUp();
  // the next press: the lock, granted at once (autoLock), then relative motion only
  const lockFrom = app.text().length;
  hl.click(sx, sy);
  await until(() => since(/zwp_locked_pointer_v1#\d+\.locked\(\)/, lockFrom), 5000, 'locked()');
  check(hl.pointerLock()?.locked === true && hl.pointerLock()!.surface === sub.surface, 'the next press locks: the lock is wanted, granted, locked()');
  const lockedAt = lockFrom + since(/zwp_locked_pointer_v1#\d+\.locked\(\)/, lockFrom)!.index;
  // weston-constraints asks for its relative pointer only on locked(): a
  // move can beat that request to the core and reach no relative pointer
  await until(() => since(/get_relative_pointer\(/, lockedAt), 5000, 'get_relative_pointer');
  hl.pointerMoveBy(20, 10);
  for (let i = 0; !since(/relative_motion\(\d+, \d+, 20\.0+, 10\.0+, /, lockedAt); i++) {
    if (i === 25) throw new Error('timed out waiting for relative_motion(20, 10)');
    await sleep(200);
    if (!since(/relative_motion\(/, lockedAt)) hl.pointerMoveBy(20, 10); // it went nowhere: again
  }
  check(!since(/wl_pointer#\d+\.motion\(/, lockedAt), 'locked: a move is relative_motion(20, 10) and no wl_pointer.motion');
  hl.press('Escape');
  await until(() => since(/zwp_locked_pointer_v1#\d+\.unlocked\(\)/, lockedAt), 5000, 'unlocked()');
  check(!since(/wl_keyboard#\d+\.key\(\d+, \d+, 1, /, lockedAt), 'Escape broke the lock (unlocked()) and never reached the app');
  await stop(app.p);
  await noWindows();

  console.log('== pointer constraints + relative pointer: SDL3 relative mouse mode ==');
  const rel = need('relative');
  if (!rel) return;
  const sdl = runLogged(rel);
  const w = await oneWindow(rel.name);
  const cx = w.x + w.width / 2, cy = w.y + w.height / 2;
  hl.click(cx, cy);
  await until(() => /RELATIVE 1/.test(sdl.text()) && hl.pointerLock()?.locked, 5000, 'relative mouse mode');
  check(true, 'a press turns relative mouse mode on: SDL locks the pointer, granted');
  hl.pointerMoveBy(20, 10);
  await until(() => / 20\.00 10\.00 rel=1/.test(sdl.text()), 5000, 'an SDL motion of xrel 20, yrel 10');
  check(true, 'its mouse motion is the move (xrel 20, yrel 10)');
  hl.press('Escape');
  check(hl.pointerLock()?.locked === false, 'Escape breaks the lock; it stays wanted (persistent)');
  hl.click(cx, cy);
  check(hl.pointerLock()?.locked === true, 'the next press re-locks');
  const from = sdl.text().length;
  hl.pointerMoveBy(-6, 4);
  await until(() => / -6\.00 4\.00 rel=1/.test(sdl.text().slice(from)), 5000, 'an SDL motion of xrel -6, yrel 4');
  check(true, 're-locked: relative motion again');
  await stop(sdl.p);
  await noWindows();
}


async function foot() {
  console.log('== foot ==');
  const spec = need('term');
  if (!spec) return;
  const app = runApp(spec);
  const win = await oneWindow(spec.name);
  check(win.focused, `mapped with keyboard focus (${win.width}x${win.height} at ${win.x},${win.y})`);
  const shot0 = hl.screenshot();
  check(colours(shot0) >= 3, `screenshot non-blank (${colours(shot0)} colours sampled)`);

  // keys: shift and symbols must all arrive for the printf to parse
  const marker = 'Hello-Headless';
  hl.type(`printf '\\033]2;${marker}\\007'; echo TYPED OK\n`);
  await until(() => titles.includes(marker), 5000, 'foot to be retitled by the typed printf');
  check(hl.windows()[0]!.title === marker, 'typed keys reached the shell; the window list follows the title');
  await settle();
  check(hash(hl.screenshot()) !== hash(shot0), 'typing changed the pixels');

  // CSD: subsurfaces around the grid, the titlebar above it — placed by the
  // positions commits carry, relative to the toplevel
  const subs = hl.surfaces().filter((s) => s.role === ROLE_SUBSURFACE && s.conn === win.conn && s.root === win.surface);
  const titlebar = subs.find((s) => s.logicalWidth > 4 * s.logicalHeight && s.logicalWidth > win.width * 0.8 && s.y < 0);
  check(subs.length >= 4 && titlebar, `CSD assembled: ${subs.length} subsurfaces, titlebar ${titlebar?.logicalWidth}x${titlebar?.logicalHeight} at y=${titlebar?.y}`);
  check(subs.every((s) => s.x >= -64 && s.y >= -64 && s.x <= win.width + 64 && s.y <= win.height + 64), 'every decoration is next to the window');
  // the window's box is foot's window geometry: grid + titlebar, so the
  // toplevel (the grid) starts below the box's top
  const box = hl.windows()[0]!;
  const grid = hl.surfaces().find((s) => s.conn === win.conn && s.surface === win.surface)!;
  check(box.originX === box.x && box.originY > box.y && box.height === grid.logicalHeight + (box.originY - box.y),
    `the box holds the titlebar (borders hang outside): ${box.width}x${box.height}, grid at +${box.originX - box.x},+${box.originY - box.y}`);

  // pointer: a burst of moves between frames is coalesced to the newest
  const s0 = { ...hl.engine.stats };
  for (const fy of [0.25, 0.5, 0.75]) {
    for (let i = 0; i <= 40; i++) hl.pointerMove(win.x + (win.width * i) / 40, win.y + win.height * fy);
    await sleep(50);
  }
  const cx = win.x + win.width / 2, cy = win.y + win.height / 2;
  hl.click(cx, cy);
  hl.click(cx, cy, 'right');
  hl.click(win.originX + 5, win.originY + 5);
  hl.scroll(3);
  hl.scroll(-3);
  await sleep(300);
  const s1 = hl.engine.stats;
  const moves = s1.motions - s0.motions, sent = s1.sentMotions - s0.sentMotions;
  check(moves >= 100 && sent >= 1 && sent < moves / 4, `pointer sweep: ${moves} moves → ${sent} shipped motions`);
  check(alive(app) && hl.focused()?.key === win.key, 'foot survived the sweep, clicks and wheel, still focused');

  hl.resize(win, 900, 600);
  await until(() => Math.abs(hl.windows()[0]!.width - 900) < 40, 5000, 'foot to resize');
  await settle();
  const big = hl.windows()[0]!;
  check(colours(hl.screenshot({ window: big })) >= 3, `resized to ${big.width}x${big.height}, content rendered`);
  await stop(app);
  await noWindows();
}

async function states() {
  console.log('== window states: fullscreen, minimize ==');
  const spec = need('term');
  if (!spec) return;
  const app = runApp(spec);
  const win = await oneWindow(spec.name);
  const grid = () => hl.surfaces().find((s) => s.conn === win.conn && s.surface === win.surface)!;
  const out = hl.output;
  hl.setFullscreen(win, true);
  await until(() => grid().logicalWidth > out.width - 20 && grid().logicalHeight > out.height - 40, 5000, 'foot to fill the output');
  await settle();
  let w = hl.windows()[0]!;
  check(w.fullscreen && w.x === 0 && w.y === 0 && w.width === out.width && w.height === out.height,
    `fullscreen: the box is the output, the grid ${grid().logicalWidth}x${grid().logicalHeight} at ${w.originX},${w.originY}`);
  hl.type(`printf '\\033]2;FS-TYPED\\007'\n`);
  await until(() => titles.includes('FS-TYPED'), 5000, 'keys to reach fullscreen foot');
  check(true, 'keys reach it while fullscreen');
  hl.setFullscreen(win, false);
  await until(() => !hl.windows()[0]!.fullscreen && Math.abs(hl.windows()[0]!.width - win.width) < 20, 5000, 'foot back to its size');
  await settle();
  w = hl.windows()[0]!;
  check(w.x === win.x && w.y === win.y && Math.abs(w.height - win.height) < 20, `back to ${w.width}x${w.height} at ${w.x},${w.y}`);

  hl.minimize(win);
  await until(() => hl.windows()[0]!.minimized, 2000, 'the minimize event');
  check(!hl.focused() && colours(hl.screenshot()) === 1, 'minimized: hidden, nothing focused');
  await sleep(300);
  hl.restore(win);
  await until(() => !hl.windows()[0]!.minimized, 2000, 'the restore event');
  await settle();
  check(alive(app) && hl.focused()?.key === win.key && colours(hl.screenshot()) >= 3, 'restored: drawn, focused');
  hl.type(`printf '\\033]2;RESTORED\\007'\n`);
  await until(() => titles.includes('RESTORED'), 5000, 'keys to reach restored foot');
  check(true, 'keys reach it again');
  await stop(app);
  await noWindows();

  // the client asks: weston-fullscreen's 'f' toggles set_fullscreen
  const fs = need('fullscreen');
  if (!fs) return;
  const wf = runApp(fs);
  const fw = await oneWindow(fs.name);
  const top = () => hl.surfaces().find((s) => s.conn === fw.conn && s.surface === fw.surface)!;
  hl.type('f');
  await until(() => hl.windows()[0]!.fullscreen && top().logicalWidth === out.width && top().logicalHeight === out.height, 5000, 'weston-fullscreen to go fullscreen');
  check(true, `set_fullscreen from the app: ${top().logicalWidth}x${top().logicalHeight}`);
  hl.type('f');
  await until(() => !hl.windows()[0]!.fullscreen && top().logicalWidth < out.width, 5000, 'weston-fullscreen to leave fullscreen');
  check(true, `unset_fullscreen: back to ${top().logicalWidth}x${top().logicalHeight}`);
  await stop(wf);
  await noWindows();
  // -f: mapped fullscreen (set_fullscreen before the first commit)
  const wf2 = runApp(need('fullscreen', ['-f'])!);
  await until(() => hl.windows().length === 1 && hl.windows()[0]!.fullscreen, 20000, 'weston-fullscreen -f to map fullscreen');
  await settle();
  const f2 = hl.windows()[0]!;
  const t2 = hl.surfaces().find((s) => s.conn === f2.conn && s.surface === f2.surface)!;
  check(t2.logicalWidth === out.width && t2.logicalHeight === out.height && f2.focused, `mapped fullscreen: ${t2.logicalWidth}x${t2.logicalHeight}, focused`);
  await stop(wf2);
  await noWindows();
}

async function clipboard() {
  console.log('== clipboard ==');
  const spec = need('copy', ['--foreground', 'wland-headless-clip']);
  const paste = need('paste', ['--no-newline']);
  if (!spec || !paste) return;
  const copy = runApp(spec);
  await sleep(500);
  const r = await exec(paste, 10000);
  check(r.stdout === 'wland-headless-clip', `wl-paste returned "${r.stdout}"`);
  await stop(copy);
}

async function nautilus() {
  console.log('== nautilus ==');
  // the double click below opens the FIRST icon and expects a folder
  mkdirSync(`${dir}/files/folder`, { recursive: true });
  const spec = need('files', [`${dir}/files`]);
  if (!spec) return;
  let bus: ChildProcess | null = null;
  const extra: NodeJS.ProcessEnv = {};
  if (spec.bus) {
    if (!have('dbus-daemon')) return console.log('  skipped: dbus-daemon not installed');
    // GNOME's default button layout is "appmenu:close"; a keyfile GSettings
    // backend of its own (XDG_CONFIG_HOME is per run) shows minimize + maximize
    // — for the bus too: GTK reads the layout through the settings portal it
    // activates
    mkdirSync(`${dir}/config/glib-2.0/settings`, { recursive: true });
    writeFileSync(`${dir}/config/glib-2.0/settings/keyfile`,
      "[org/gnome/desktop/wm/preferences]\nbutton-layout='appmenu:minimize,maximize,close'\n");
    // GTK apps refuse to start without a session bus. Not dbus-run-session: a
    // signal to it leaves its bus up, and every service the bus activated
    // with it. A bus of our own at a path in the runtime dir dies by sweep()
    // or the SIGKILL in `finally`, and its services exit with it.
    const busPath = `${dir}/bus`;
    bus = run('dbus-daemon', ['--session', '--nofork', `--address=unix:path=${busPath}`], { GSETTINGS_BACKEND: 'keyfile' });
    await until(() => existsSync(busPath) || !alive(bus!), 5000, 'the session bus');
    check(alive(bus), 'a session bus of its own');
    extra.DBUS_SESSION_BUS_ADDRESS = `unix:path=${busPath}`;
    extra.GSETTINGS_BACKEND = 'keyfile';
  }
  const app = runLogged(spec, extra);
  await until(() => hl.windows().some((w) => w.width >= 700), 30000, "nautilus's window");
  await sleep(1500);
  await settle();
  let win = hl.windows()[0]!;
  const title0 = win.title;
  check(colours(hl.screenshot({ window: win })) >= 8, `renders (${win.width}x${win.height}, "${title0}")`);

  // GTK's window geometry is its frame; the shadow around it is outside the box
  const top = hl.surfaces().find((s) => s.conn === win.conn && s.surface === win.surface)!;
  check(win.originX < win.x && win.originY < win.y && top.logicalWidth > win.width && top.logicalHeight > win.height,
    `the box is the frame ${win.width}x${win.height}, inside a ${top.logicalWidth}x${top.logicalHeight} surface at ${win.originX - win.x},${win.originY - win.y}`);
  // GTK's input region is the frame plus a resize margin: a point in the
  // outer shadow misses the window (nothing is under it here), one just
  // outside the frame is still its (CSD resize from the edge)
  const hits = (x: number, y: number) => hl.surfaceAt(x, y)?.conn === win.conn;
  const region = top.inputRegion;
  check(!!region && !hits(win.originX + 1, win.originY + 1) && hits(win.x - 2, win.y + 100) && hits(win.x + 100, win.y + 100),
    `input region applied (${region ? region.length / 4 : 'no'} rects): the shadow falls through, the resize margin hits`);

  // offsets from the toplevel's origin, nautilus's default floating layout
  const ox = win.originX, oy = win.originY;
  const popups = () => hl.surfaces().filter((s) => s.role === ROLE_POPUP && s.conn === win.conn).length;
  hl.click(ox + 184, oy + 48); // the hamburger button
  await until(() => popups() > 0, 5000, 'the menu popup');
  check(true, 'hamburger menu opened as an xdg_popup');
  await settle();
  hl.click(ox + 500, oy + 450);
  await until(() => popups() === 0, 5000, 'the popup to be dismissed');
  check(true, 'an outside press dismissed it (popup_done → unmap)');

  // the header bar's minimize button: right of the path bar, left of
  // maximize and close (box-relative, the floating layout)
  await settle();
  hl.pointerMove(win.x + win.width - 97, win.y + 23); // GTK wants the hover before the press
  await sleep(300);
  hl.click(win.x + win.width - 97, win.y + 23);
  await until(() => hl.windows()[0]?.minimized, 5000, 'nautilus to minimize itself');
  check(!hl.focused() && alive(app.p), 'its minimize button (set_minimized): hidden, focus gone, alive');
  hl.restore(win);
  await until(() => hl.windows()[0] && !hl.windows()[0]!.minimized && hl.focused()?.key === win.key, 5000, 'nautilus restored');
  await settle();
  check(colours(hl.screenshot({ window: win })) >= 8, 'restored: drawn and focused');

  await settle();
  hl.click(ox + 307, oy + 145); // the first icon: the fixture's folder
  hl.click(ox + 307, oy + 145);
  await until(() => hl.windows()[0]?.title !== title0, 5000, 'the title to change');
  check(true, `double click navigated ("${hl.windows()[0]!.title}")`);

  // resize storm at the frame rate, oscillating sizes
  const before = commits;
  let calls = 0;
  for (const t0 = Date.now(); Date.now() - t0 < 6000; calls++) {
    const t = (Date.now() - t0) / 1000;
    hl.resize(win, 700 + Math.floor(300 * (1 + Math.sin(t * 6))), 450 + Math.floor(150 * (1 + Math.cos(t * 5))));
    await sleep(16);
  }
  await sleep(1500);
  await settle();
  win = hl.windows()[0]!;
  check(alive(app.p) && win, `survived a storm of ${calls} resizes (${commits - before} commits)`);
  check(colours(hl.screenshot({ window: win })) >= 8, `still drawing at ${win.width}x${win.height}`);
  await stop(app.p);
  if (bus) await stop(bus); // its services (gvfsd, portals, localsearch, at-spi) go with it
  await noWindows();

  if (!realApps) {
    // dnd within one client: the fixture's file.txt (the second icon) onto
    // its folder — start_drag, enter/motion/drop on the same surface, the
    // receive pipe served by the source in the same process
    mkdirSync(`${dir}/files2`, { recursive: true });
    const dnd = runLogged(need('files', [`${dir}/files2`])!);
    const w2 = await oneWindow('files');
    const from = [w2.originX + 427, w2.originY + 145] as const, to = [w2.originX + 307, w2.originY + 145] as const;
    hl.pointerMove(from[0], from[1]);
    hl.pointerDown();
    for (let i = 1; i <= 10; i++) {
      hl.pointerMove(from[0] + ((to[0] - from[0]) * i) / 10, from[1]);
      await sleep(30);
    }
    hl.pointerUp();
    await until(() => /DROPPED (\S+) ON folder/.test(dnd.text()), 5000, 'the drop');
    const uri = /DROPPED (\S+) ON folder/.exec(dnd.text())![1];
    check(uri === `file://${dir}/files2/file.txt`, `file.txt dragged onto the folder: the drop delivered ${uri}`);
    await until(() => hl.windows()[0]?.title === 'moved file.txt', 3000, 'the title after the move');
    check(true, 'the drag ended: the source moved its file');
    await stop(dnd.p);
    await noWindows();
  }
}

async function x11() {
  console.log('== x11 (xwayland-satellite) ==');
  if (!realApps) return console.log('  skipped: real apps only (WLAND_E2E_APPS=real); test/relay.test.ts runs a stand-in satellite');
  if (!have('xwayland-satellite') || !have('Xwayland') || !have('xeyes')) {
    return console.log('  skipped: xwayland-satellite, Xwayland or xeyes not installed');
  }
  // (the relay serves HTTP here: --xwayland defaults to auto)
  const display = xDisplayOf(`${dir}/${env.WAYLAND_DISPLAY}`);
  check(display, `the relay claimed an X display (${display}) and left it in <socket>.x11`);
  // nothing X is running yet: this connection is what starts satellite
  const app = run('env', [`DISPLAY=${display}`, 'xeyes']);
  const win = await oneWindow('xeyes');
  check(win.title === 'xeyes', `an X client's window, through satellite started on demand ("${win.title}", ${win.width}x${win.height})`);
  check(colours(hl.screenshot({ window: win })) >= 2, 'it draws');
  await stop(app);
  await noWindows();
}

async function scale2() {
  console.log('== output scale 2 ==');
  const spec = need('term');
  if (!spec) return;
  hl.setOutput(hl.output.width, hl.output.height, 2);
  const app = runApp(spec);
  const win = await oneWindow(spec.name);
  const top = hl.surfaces().find((s) => s.conn === win.conn && s.surface === win.surface)!;
  // whichever way the app gets there (buffer_scale 2, or a viewport and
  // fractional-scale), the invariant is buffer = 2 × logical
  check(Math.abs(top.width / top.logicalWidth - 2) < 0.01 && Math.abs(top.height / top.logicalHeight - 2) < 0.01,
    `buffer ${top.width}x${top.height} is 2× the logical ${top.logicalWidth}x${top.logicalHeight}`);
  const shot = hl.screenshot();
  check(shot.width === hl.output.width * 2 && colours(shot) >= 3, `screenshot in device px (${shot.width}x${shot.height}), non-blank`);
  await stop(app);
  await noWindows();
  hl.setOutput(hl.output.width, hl.output.height, 1);
}

let code = 0;
try {
  // the WS link connects once: the relay must be listening first
  for (let up = false; !up;) {
    if (!alive(relay)) throw new Error('FAIL: the relay exited at startup (port in use?)');
    up = await fetch(`http://127.0.0.1:${PORT}/`).then(() => true, () => false);
    if (!up) await sleep(50);
  }
  hl = await createHeadless({
    link: `ws://127.0.0.1:${PORT}/ws`, width: 1280, height: 800,
    onEvent(ev) {
      if (ev.type === 'commit') commits++;
      else if (ev.type === 'open') opened = true;
      else if (ev.type === 'error') errors.push(ev.detail);
      else if (ev.type === 'title') titles.push(ev.title);
    },
  });
  await until(() => opened || !alive(relay), 10000, 'the link to open');
  check(opened, `link open: ws://127.0.0.1:${PORT}/ws (apps: ${appSet})`);
  await info();
  await shm();
  await presentation();
  await cursor();
  await constraints();
  await foot();
  await states();
  await clipboard();
  await nautilus();
  await x11();
  await scale2();
  check(errors.length === 0, `no engine error events ${errors.join('; ')}`);
  console.log('HEADLESS-E2E PASS');
} catch (e) {
  code = 1;
  console.error(e instanceof Error ? e.message : e);
  console.error('HEADLESS-E2E FAIL');
} finally {
  hl?.dispose();
  // the relay first, and by SIGTERM: it then removes its sockets and locks
  // (the X display's too), where SIGKILL would leave them in /tmp
  relay.kill('SIGTERM');
  await until(() => !alive(relay), 3000, 'the relay to exit').catch(() => {});
  for (const p of procs) p.kill('SIGKILL');
  sweep();
  rmSync(webRoot, { recursive: true, force: true });
  // the GNOME services' FUSE mounts (gvfs, the document portal) go with
  // their processes, a moment later; a leftover dir in /tmp is not a failure
  for (let i = 0; i < 20; i++) {
    for (const m of ['gvfs', 'doc']) spawnSync('fusermount3', ['-u', '-z', `${dir}/${m}`], { stdio: 'ignore' });
    try { rmSync(dir, { recursive: true, force: true }); break; } catch { await sleep(100); }
  }
  setTimeout(() => process.exit(code), 100);
}
