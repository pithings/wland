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
//     Firefox's seat shape (fixture `browser`, fixtures only): wl_seat bound
//     twice (GTK's v5, Firefox's own v8); GTK's wl_pointer and wl_keyboard
//     — the ones Firefox's input handling listens on — get every enter,
//     button, wheel, key and leave, with the same serials as its own
//     (each version-gated on its own); Ctrl+V pastes through GTK's data
//     device.
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
//  8. decorations (fixture `game`, real neverball): an SDL game is
//     client-side under the default; a scene with decorations 'server' (a
//     reload) has it decorated, told before its first commit (session: the
//     running game answered server_side at the attach); the fixture's
//     set_mode after the map undecorates and decorates it again; foot
//     (real) asks too, the term fixture never does.
//  9. a GPU client (fixtures only): a second relay with the test-only
//     `--dmabuf virtgpu:@fake` names the `dmabuf` fixture's buffers as
//     resources; COMMITs of kind virtgpu reach a headless client with a
//     gpu resolver, with the client's size, format and implicit modifier,
//     a resource per buffer; it keeps drawing (each release
//     came after its ACK); every resolved image released, no errors. Then
//     a page with no gpu source on the same relay: the core leaves
//     linux-dmabuf off (FEATURE dmabuf_kind), the GPU client exits for
//     want of the global (as weston-simple-dmabuf-egl does), a wl_shm
//     client draws.
//
// Needs `zig build` (wlandr, wland-fixture, lib/wland.wasm). Own
// XDG_RUNTIME_DIR, display name and port: it never touches a demo's session.
// Run: node tools/headless-e2e-test.ts   (V=1 shows the apps' stderr;
// WLAND_E2E_APPS=real for the real apps; WLAND_E2E_RELAY overrides the relay
// command, split on spaces — an older wlandr checks version skew: what it
// can't do, it skips with a message)

import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { GpuRef } from '../lib/engine.ts';
import {
  createHeadless, EDGE_BOTTOM, EDGE_LEFT, EDGE_TOP, NO_SELECTION_BRIDGE, ROLE_POPUP, ROLE_SUBSURFACE,
  type ConfigureEvent, type Headless, type HeadlessWindow, type RgbaImage,
} from '../lib/headless.ts';
import { xDisplayOf } from '../lib/index.ts';
import { app, appHome, appSet, available, realApps, type AppRole, type AppSpec } from '../test/support/apps.ts';
import { parsePresentationShm, presentationChecks } from '../test/support/presentation-shm.ts';

const RELAY = (process.env.WLAND_E2E_RELAY || fileURLToPath(new URL('../zig-out/bin/wlandr', import.meta.url))).split(' ');
const PORT = Number(process.env.PORT || 8937);
const dir = mkdtempSync('/tmp/wl-hl-');
const env: NodeJS.ProcessEnv = {
  ...process.env, XDG_RUNTIME_DIR: dir, WAYLAND_DISPLAY: 'wland-hl',
  // GTK: no GPU path here → the cairo renderer; pin the backend (tools/wland-run)
  GDK_BACKEND: 'wayland', GSK_RENDERER: 'cairo', XDG_SESSION_TYPE: 'wayland',
  // real apps: a home of their own (the developer's dotfiles stay out of
  // it, both ways: nautilus's saved maximized state, bash's history); the
  // session bus below and the services it activates share it
  ...(realApps ? appHome() : {}),
};
delete env.DISPLAY; // nothing here may fall back to X11

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
const relay = run(RELAY[0], [...RELAY.slice(1), '--port', String(PORT), '--web-root', webRoot, '--display', env.WAYLAND_DISPLAY!]);
let commits = 0, opened = false;
const errors: string[] = [];
const titles: string[] = [];
const grabs: string[] = []; // 'move' / 'resize' events: the grabs the core started
let synced = 0; // 'synced' events: scene replays of a session relay
const order: string[] = []; // 'decoration' events and each surface's first commit, in order
const configures: ConfigureEvent[] = []; // every 'configure' event
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
  const appId = realApps ? 'foot' : 'wland-fixture.term';
  check(win.appId === appId, `the window carries its app id ("${win.appId}")`);
  const shot0 = hl.screenshot();
  check(colours(shot0) >= 3, `screenshot non-blank (${colours(shot0)} colours sampled)`);

  // keys: shift and symbols must all arrive for the printf to parse
  const marker = 'Hello-Headless';
  hl.type(`printf '\\033]2;${marker}\\007'; echo TYPED OK\n`);
  await until(() => titles.includes(marker), 5000, 'foot to be retitled by the typed printf');
  check(hl.windows()[0]!.title === marker, 'typed keys reached the shell; the window list follows the title');
  await settle();
  check(hash(hl.screenshot()) !== hash(shot0), 'typing changed the pixels');

  // the keypad: NumLock is on (Mod2 locked) so its digits are digits; off, they
  // navigate (KP_Home…) and type nothing
  hl.type(`printf '\\033]2;KP-`);
  hl.press('Numpad1');
  hl.press('Numpad2');
  hl.press('NumpadDecimal');
  hl.press('Numpad7');
  hl.press('NumLock'); // off
  hl.press('Numpad9');
  hl.press('NumLock'); // on again
  hl.type(`\\007'\n`);
  await until(() => titles.some((t) => t.startsWith('KP-')), 5000, 'foot to be retitled by keypad digits');
  check(titles.includes('KP-12.7'), `keypad digits typed with NumLock on, none with it off (title ${titles.filter((t) => t.startsWith('KP-'))})`);

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

  // its left border (outside the box, foot's 5 px CSD border): a quick
  // click — the app's xdg_toplevel.resize comes after the release, and
  // the core starts no grab for it — then a press held while the pointer
  // drags, which does resize
  await settle();
  const w0 = hl.windows()[0]!;
  const bx = w0.x - 3, by = w0.y + Math.round(w0.height / 2);
  const g0 = grabs.length;
  hl.click(bx, by);
  await sleep(500);
  hl.pointerMove(bx + 280, by + 50);
  await settle();
  const w1 = hl.windows()[0]!;
  // (a session relay's compositor may see the app's request between the
  // press and the release, which cross as two messages: its 'resize' then
  // comes, and the scene ignores it — no button is held here any more)
  const quiet = hl.engine.session() ? true : grabs.length === g0;
  check(quiet && w1.x === w0.x && w1.width === w0.width,
    `a quick click on the border: no grab (${grabs.slice(g0)}), the window stays ${w1.width} wide at x=${w1.x}`);
  grabs.length = g0;
  hl.pointerMove(bx, by);
  hl.pointerDown();
  await until(() => grabs.length > g0, 5000, 'the resize request of a held press');
  hl.pointerMove(bx - 60, by);
  hl.pointerUp();
  await until(() => hl.windows()[0]!.width > w0.width + 30, 5000, 'foot to resize from its border');
  check(grabs.slice(g0).join() === 'resize', `held on the border: a resize grab, ${w0.width} → ${hl.windows()[0]!.width} px`);
  await settle();

  hl.resize(win, 900, 600);
  await until(() => Math.abs(hl.windows()[0]!.width - 900) < 40, 5000, 'foot to resize');
  await settle();
  const big = hl.windows()[0]!;
  check(colours(hl.screenshot({ window: big })) >= 3, `resized to ${big.width}x${big.height}, content rendered`);
  // close: xdg_toplevel.close, and foot exits by itself
  hl.close(big);
  await until(() => !alive(app), 5000, 'foot to exit when asked to close');
  check(true, 'close(): foot exited by itself');
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

  // hidden by the embedder: not drawn, still focused, not minimized
  hl.setVisible(win, false);
  check(hl.windows()[0]!.hidden && !hl.windows()[0]!.minimized && hl.focused()?.key === win.key && colours(hl.screenshot()) === 1,
    'hidden: not drawn, not minimized, still focused');
  hl.setVisible(win, true);
  await settle();
  check(colours(hl.screenshot()) >= 3, 'shown: drawn again');

  // snapped: the tiled states and a size in one configure; the app's
  // answer is told by the acked configure (foot rounds to whole cells)
  if (!configures.length) console.log('  skipped tiled: this relay sends no configure events (predates them)');
  else {
    const n = configures.length;
    const token = hl.setTiled(win, EDGE_LEFT | EDGE_TOP | EDGE_BOTTOM, 401, 303);
    const mine = () => configures.slice(n).find((c) => c.cause === token);
    await until(mine, 3000, 'the configure carrying the setTiled token');
    const cfg = mine()!;
    check(cfg.width === 401 && cfg.height === 303 && configures.slice(n).length === 1,
      `one configure: 401x303, tiled ${cfg.tiled} (told only from xdg_wm_base v2)`);
    await until(() => (hl.windows()[0]!.acked?.serial ?? 0) >= cfg.serial, 5000, 'foot to ack the tiled configure');
    await settle();
    const w2 = hl.windows()[0]!;
    check(w2.acked!.width === 401 && w2.acked!.height === 303 && w2.width <= 401 && w2.width > 300,
      `answered: acked ${w2.acked!.width}x${w2.acked!.height}, the window took ${w2.width}x${w2.height}`);
    hl.setTiled(win, 0);
  }
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
  if (hl.engine.selectionBridged() === false) return clipboardUnbridged(copy, paste);
  check(hl.engine.selectionBridged() === true, 'the relay bridges the clipboard (FEATURE selection_cache)');
  // the page bridge's halves, headless: the embedder reads the app's
  // selection through the relay (pipe_read), and sets its own, which the
  // next focused app pastes (the relay writes the core's bytes)
  const read = await hl.readClipboard();
  check(read === 'wland-headless-clip', `readClipboard() returned "${read}" (owner conn ${hl.engine.selection().conn})`);
  await stop(copy);
  await until(() => hl.engine.selection().mimes.length === 0, 5000, 'the selection to go with wl-copy');
  const text = 'from the embedder: héllo ✓';
  check(hl.writeClipboard(text) && hl.engine.selection().conn === 0, 'writeClipboard() made the embedder\'s own selection');
  const r2 = await exec(paste, 10000);
  check(r2.stdout === text, `wl-paste of the embedder's selection returned "${r2.stdout}"`);
  check(await hl.readClipboard() === text, 'readClipboard() of its own selection');
  // wl-copy --paste-once: the read is its one paste, and it hands the
  // write to a child and exits, so its conn is gone before the read's EOF
  // — EOF alone completes a read (STREAM.md pipe_read)
  const onceSpec = need('copy', ['--paste-once', 'wland-paste-once']);
  if (onceSpec) {
    const once = runApp(onceSpec);
    await until(() => hl.engine.selection().conn !== 0 && hl.engine.selection().mimes.length > 0, 5000, 'wl-copy --paste-once to own the clipboard');
    const got = await hl.readClipboard();
    check(got === 'wland-paste-once', `readClipboard() of wl-copy --paste-once returned "${got}"`);
    await until(() => hl.engine.selection().mimes.length === 0, 5000, 'wl-copy --paste-once to go after its paste');
    await stop(once);
  }

  // foot's keys: Ctrl+Shift+V pastes the selection into the shell (a
  // printf that retitles it); a word double-clicked and Ctrl+Shift+C copies
  // it (the fixture copies its last output line: the same word)
  const termSpec = need('term');
  if (!termSpec) return;
  const term = runApp(termSpec);
  await oneWindow(termSpec.name);
  await settle();
  hl.writeClipboard(`printf '\\033]2;PASTED-INTO-FOOT\\007'`);
  hl.press('ControlLeft', 'ShiftLeft', 'KeyV');
  hl.press('Enter');
  await until(() => titles.includes('PASTED-INTO-FOOT'), 5000, 'foot to run the pasted printf');
  check(true, 'Ctrl+Shift+V pasted the embedder\'s selection into foot');
  {
    hl.type('clear; echo wland-copied-from-foot\n'); // the word alone on the first row
    await sleep(500);
    const w = hl.focused()!;
    hl.click(w.originX + 40, w.originY + 8);
    hl.click(w.originX + 40, w.originY + 8);
    await sleep(300);
    hl.press('ControlLeft', 'ShiftLeft', 'KeyC');
    await until(() => hl.engine.selection().conn !== 0, 5000, 'foot to own the clipboard');
    const copied = await hl.readClipboard();
    check(copied === 'wland-copied-from-foot', `Ctrl+Shift+C in foot: readClipboard() returned "${copied}"`);
  }
  await stop(term);
  await noWindows();
}

async function browser() {
  console.log("== Firefox's seat shape: wl_seat bound twice ==");
  // real Firefox aborts here at GTK's first icon (glycin's sandbox): the
  // real check is by hand (testing.md)
  if (realApps) return console.log('  skipped: fixtures only (real Firefox: testing.md "Setup")');
  const spec = need('browser');
  const copySpec = need('copy', ['--foreground', 'wland-two-seats']);
  if (!spec || !copySpec) return;
  const copy = runApp(copySpec); // a selection for GTK's data device
  await until(() => hl.engine.selection().mimes.length > 0, 5000, 'wl-copy to own the clipboard');
  await noWindows();
  const ff = runLogged(spec);
  const win = await oneWindow(spec.name);
  const lines = () => ff.text().split('\n');
  const has = (re: RegExp) => lines().some((l) => re.test(l));
  /** pair → event → the serials it got, in order */
  const serials = (pair: 'gtk' | 'own', event: string) =>
    lines().filter((l) => l.startsWith(`${pair} ${event} `)).map((l) => Number(/serial=(\d+)/.exec(l)![1]));
  const same = (event: string) => {
    const g = serials('gtk', event), o = serials('own', event);
    return g.length > 0 && g.join() === o.join() ? g : null;
  };
  check(/seats gtk=v5 own=v8/.test(ff.text()), 'GTK bound wl_seat at v5, Firefox its own at v8');
  await until(() => same('wl_keyboard.enter') && same('wl_keyboard.modifiers'), 5000, 'both keyboards to get the enter');
  check(win.focused, `mapped focused: GTK's keyboard got enter + modifiers, the same serials as Firefox's (${same('wl_keyboard.enter')})`);
  check(has(/^gtk wl_data_device\.selection mimes=.*text\/plain/), "GTK's data device was offered the selection");

  const cx = win.x + win.width / 2, cy = win.y + win.height / 2;
  hl.pointerMove(cx, cy);
  hl.click(cx, cy);
  await until(() => serials('gtk', 'wl_pointer.button').length >= 2 && serials('own', 'wl_pointer.button').length >= 2, 5000, 'both pointers to get the click');
  check(same('wl_pointer.enter') && same('wl_pointer.button'), `a click: GTK's wl_pointer got enter + press + release, the serials Firefox's got (${same('wl_pointer.button')})`);
  check(has(/^gtk wl_pointer\.motion$/) && has(/^gtk wl_pointer\.frame$/), "GTK's pointer got motion and frames (v5)");
  hl.scroll(3);
  await until(() => has(/^gtk wl_pointer\.axis$/) && has(/^own wl_pointer\.axis$/), 5000, 'both pointers to get the wheel');
  check(has(/^gtk wl_pointer\.axis_discrete$/) && !has(/^gtk wl_pointer\.axis_value120$/) && has(/^own wl_pointer\.axis_value120$/) && !has(/^own wl_pointer\.axis_discrete$/),
    'the wheel, version-gated per object: axis_discrete for GTK\'s v5 pointer, axis_value120 for Firefox\'s v8 one');
  hl.type('a');
  await until(() => serials('gtk', 'wl_keyboard.key').length >= 2, 5000, "GTK's keyboard to get the key");
  check(same('wl_keyboard.key'), `a key: GTK's wl_keyboard got press + release, the serials Firefox's got (${same('wl_keyboard.key')})`);
  hl.press('ControlLeft', 'KeyV');
  await until(() => has(/^gtk paste: /), 5000, "Ctrl+V on GTK's keyboard");
  check(has(/^gtk paste: wland-two-seats$/), `Ctrl+V pasted through GTK's data device (${lines().find((l) => l.startsWith('gtk paste: '))})`);
  hl.pointerMove(1, 1);
  await until(() => serials('gtk', 'wl_pointer.leave').length > 0, 5000, "GTK's pointer to get the leave");
  check(same('wl_pointer.leave') && alive(ff.p), 'the pointer left: both got the leave (one serial); no version-gate failure');
  await stop(ff.p);
  await stop(copy);
  await noWindows();
}

/** The clipboard phase against a relay without FEATURE selection_cache (an
 *  older wlandr, WLAND_E2E_RELAY): the embedder's halves are refused at once
 *  and no app's paste blocks; apps still copy and paste among themselves. */
async function clipboardUnbridged(copy: ChildProcess, paste: AppSpec) {
  console.log('  skipped: readClipboard / writeClipboard (the relay sent no FEATURE selection_cache); checking they are refused');
  const t0 = Date.now();
  const err = await hl.readClipboard().then(() => null, (e: Error) => e.message);
  check(err === NO_SELECTION_BRIDGE && Date.now() - t0 < 1000, `readClipboard() rejected at once: "${err}"`);
  check(!hl.writeClipboard('from the embedder'), 'writeClipboard() refused');
  check(hl.engine.selection().conn !== 0, 'the app\'s selection stays');
  await stop(copy);
  await until(() => hl.engine.selection().mimes.length === 0, 5000, 'the selection to go with wl-copy');
  check(!hl.writeClipboard('from the embedder'), 'writeClipboard() refused with the clipboard empty');
  const p0 = Date.now();
  const r = await exec(paste, 10000);
  check(r.status !== null && r.stdout === '' && Date.now() - p0 < 3000, `wl-paste found nothing and exited at once (${r.status}), not blocked`);
  const termSpec = need('term');
  if (!termSpec) return;
  const term = runApp(termSpec);
  await oneWindow(termSpec.name);
  await settle();
  // foot's paste: no selection offered, nothing pasted, foot still takes keys
  hl.press('ControlLeft', 'ShiftLeft', 'KeyV');
  hl.type(`printf '\\033]2;STILL-TYPING\\007'\n`);
  await until(() => titles.includes('STILL-TYPING'), 5000, 'foot to take keys after its paste');
  check(true, 'Ctrl+Shift+V in foot pasted nothing and did not block it');
  await stop(term);
  await noWindows();
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
    // backend of its own (in appHome's XDG_CONFIG_HOME, fresh per run) shows
    // minimize + maximize — for the bus too: GTK reads the layout through
    // the settings portal it activates
    const settings = `${appHome().XDG_CONFIG_HOME}/glib-2.0/settings`;
    mkdirSync(settings, { recursive: true });
    writeFileSync(`${settings}/keyfile`,
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
  const popupList = () => hl.surfaces().filter((s) => s.role === ROLE_POPUP && s.conn === win.conn);
  const popups = () => popupList().length;
  hl.click(ox + 184, oy + 48); // the hamburger button
  await until(() => popups() > 0, 5000, 'the menu popup');
  check(true, 'hamburger menu opened as an xdg_popup');
  await settle();
  // placed below the button: positioners count from the window geometry
  // (inside the shadow), the menu's own shadow hangs outside its geometry
  // (GTK4's popover: a wide one, the arrow inside it — only the fixture's
  // geometry is known here, checked exactly below)
  const pop = popupList()[0]!;
  const px = win.originX + pop.x, py = win.originY + pop.y;
  check(px <= ox + 184 && px + pop.logicalWidth > ox + 184 && py > oy + 8 && py < oy + 48 + 24 && py + pop.logicalHeight > oy + 48 + 24,
    `the menu hangs below the button (its surface at ${px - ox},${py - oy} of the window's, ${pop.logicalWidth}x${pop.logicalHeight})`);
  // the fixture's menus: a 6 px shadow around their geometry, which
  // `POPUP at X,Y` (the configure) places from the window's box
  const PM = 6;
  const configured = (n: number) => {
    const all = [...app.text().matchAll(/POPUP at (-?\d+),(-?\d+)/g)];
    return all.length >= n ? [Number(all[n - 1]![1]), Number(all[n - 1]![2])] as const : null;
  };
  if (!realApps) {
    await until(() => configured(1), 3000, 'the menu\'s configure');
    const [cx, cy] = configured(1)!;
    check(px === win.x + cx - PM && py === win.y + cy - PM,
      `its geometry lands at the configured ${cx},${cy} of the window geometry (surface at ${px - win.x},${py - win.y})`);
    // maximized under the open menu: the window drops its shadow (geometry
    // 24,24 → 0,0) and the menu, which does not commit again, follows the
    // frame (a 'position' event): still at the configured offset of the box
    const menuCommits = hl.surfaces().find((s) => s.surface === pop.surface)!.commits;
    hl.setMaximized(win, true);
    await until(() => hl.windows()[0]?.maximized && hl.windows()[0]!.originX === hl.windows()[0]!.x, 5000, 'the maximized frame');
    await settle();
    const mw = hl.windows()[0]!, mp = popupList()[0];
    check(mp && mp.commits === menuCommits && mw.originX + mp.x === mw.x + cx - PM && mw.originY + mp.y === mw.y + cy - PM,
      `the open menu followed the frame to ${mp && mw.originX + mp.x - mw.x},${mp && mw.originY + mp.y - mw.y} of the maximized box without committing`);
    hl.setMaximized(mw, false);
    await until(() => !hl.windows()[0]?.maximized && hl.windows()[0]!.originX < hl.windows()[0]!.x, 5000, 'the floating frame');
    await settle();
    win = hl.windows()[0]!;
  }
  hl.click(ox + 500, oy + 450);
  await until(() => popups() === 0, 5000, 'the popup to be dismissed');
  check(true, 'an outside press dismissed it (popup_done → unmap)');

  if (!realApps) {
    // l3afpad's case: a right-click menu at the pointer; its frame's corner
    // is just past the click, and a click on an item hits that item
    await settle();
    const rx = ox + 600, ry = oy + 400;
    hl.click(rx, ry, 'right');
    await until(() => popups() > 0 && configured(2), 5000, 'the context menu');
    await settle();
    const ctxPop = popupList()[0]!;
    const qx = win.originX + ctxPop.x + PM, qy = win.originY + ctxPop.y + PM;
    check(qx === rx + 1 && qy === ry + 1, `right-click at ${rx},${ry}: the menu's corner at ${qx},${qy}`);
    hl.click(qx + 100, qy + 8 + 36 + 18); // its second item
    await until(() => /MENU /.test(app.text()) && popups() === 0, 3000, 'the item to be chosen');
    const item = /MENU (.+)/.exec(app.text())![1];
    check(item === 'Paste', `a click on the second item chose "${item}" and closed the menu`);
  }

  // a context menu near the output's bottom-right corner, the window
  // hanging past it: the scene told the core where the window is, so the
  // menu is constrained back inside the output (the fixture's positioner
  // slides, as GTK's may also flip and resize) instead of running off it
  if (configures.length) await edgeMenu(win, app, popupList, configured);
  else console.log('  skipped the edge menu: this relay predates window positions');
  win = hl.windows()[0]!;

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

/** nautilus's right-click menu with its window moved so the click lands
 *  150 px from the output's right and 40 px from its bottom edge: an
 *  unconstrained 200x160 menu would run off both. Back where it was after. */
async function edgeMenu(win: HeadlessWindow, app: { text(): string }, popupList: () => ReturnType<Headless['surfaces']>,
  configured: (n: number) => readonly [number, number] | null) {
  const out = hl.output, x0 = win.x, y0 = win.y;
  const n0 = [...app.text().matchAll(/POPUP at/g)].length;
  hl.move(win, out.width - 700, out.height - 500);
  await settle();
  const w = hl.windows()[0]!;
  const rx = out.width - 150, ry = out.height - 40;
  hl.click(rx, ry, 'right');
  await until(() => popupList().length > 0, 5000, 'the context menu near the edge');
  await settle();
  const pop = popupList()[0]!;
  const sx = w.originX + pop.x, sy = w.originY + pop.y; // its surface, shadow included
  if (!realApps) {
    await until(() => configured(n0 + 1), 3000, 'its configure');
    const [cx, cy] = configured(n0 + 1)!;
    // slid left and up until its geometry (200x160) fits: flush with the edges
    check(w.x + cx === out.width - 200 && w.y + cy === out.height - 160,
      `the menu slid inside the output: its geometry at ${w.x + cx},${w.y + cy} (unconstrained: ${rx + 1},${ry + 1})`);
  } else {
    // GTK's menu: its own shadow hangs outside its geometry (≤ 30 px here)
    check(sx + pop.logicalWidth <= out.width + 30 && sy + pop.logicalHeight <= out.height + 30 && sx < rx,
      `the menu stays inside the output: its surface at ${sx},${sy}, ${pop.logicalWidth}x${pop.logicalHeight} (click at ${rx},${ry})`);
  }
  hl.click(w.x + 300, w.y + 300); // an outside press dismisses it
  await until(() => popupList().length === 0, 3000, 'the menu to close');
  hl.move(win, x0, y0);
  await settle();
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

/** A scene on the main relay's link (the page; again after a "reload"). */
function attach(decorations: 'client' | 'server' = 'client'): Promise<Headless> {
  const seen = new Set<string>(); // surfaces with a commit in this scene
  return createHeadless({
    link: `ws://127.0.0.1:${PORT}/ws`, width: 1280, height: 800, decorations,
    onEvent(ev) {
      if (ev.type === 'decoration') order.push(`decoration c${ev.conn}s${ev.surface} ${ev.decorated}`);
      else if (ev.type === 'commit' && !seen.has(`c${ev.conn}s${ev.surface}`)) {
        seen.add(`c${ev.conn}s${ev.surface}`);
        order.push(`commit c${ev.conn}s${ev.surface}`);
      }
      if (ev.type === 'commit') commits++;
      else if (ev.type === 'open') opened = true;
      else if (ev.type === 'synced') synced++;
      else if (ev.type === 'error') errors.push(ev.detail);
      else if (ev.type === 'title') titles.push(ev.title);
      else if (ev.type === 'move' || ev.type === 'resize') grabs.push(ev.type);
      else if (ev.type === 'configure') configures.push(ev);
    },
  });
}

/** --profile session: the compositor is the relay's, so a viewer that goes
 *  (a page reload) takes no app with it and the next one is sent the scene
 *  as it is — a terminal's still image included, which no new commit brings. */
async function reattach() {
  console.log('== session: the viewer goes and another attaches (a page reload) ==');
  const sid = hl.engine.session()?.id;
  if (!sid) return console.log('  skipped: a passthrough relay (apps end with their link; --profile session keeps them)');
  const spec = need('term');
  if (!spec) return;
  const app = runApp(spec);
  const win = await oneWindow(spec.name);
  hl.type(`printf '\\033]2;Before-Reload\\007'; echo KEPT\n`);
  await until(() => titles.includes('Before-Reload'), 5000, 'foot to be retitled before the reload');
  await settle();
  const before = hl.screenshot();
  hl.dispose();
  await sleep(1500); // no viewer at all for a while
  check(alive(app), 'the app outlives its viewer');
  const s0 = synced;
  hl = await attach();
  await until(() => synced > s0, 10000, 'the scene replay (synced)');
  check(hl.engine.session()?.id === sid, `the same session (${sid})`);
  const again = hl.windows();
  check(again.length === 1 && again[0]!.title === 'Before-Reload' && again[0]!.width === win.width && again[0]!.height === win.height,
    `its window is back: "${again[0]?.title}" ${again[0]?.width}x${again[0]?.height}`);
  await settle();
  const after = hl.screenshot();
  check(colours(after) >= 3 && colours(after) === colours(before), `with its content, from the replay (${colours(after)} colours sampled, ${colours(before)} before)`);
  hl.click(again[0]!.x + again[0]!.width / 2, again[0]!.y + again[0]!.height / 2);
  hl.type(`printf '\\033]2;After-Reload\\007'\n`);
  await until(() => titles.includes('After-Reload'), 5000, 'foot to be retitled after the reload');
  check(alive(app), 'input reaches it again: typed keys retitled the window');
  await stop(app);
  await noWindows();
}

/** decorations 'client' (the default) and 'server': an SDL game binds
 *  xdg-decoration before its first commit and gets server_side only from
 *  a scene that draws frames, which knows it before the window's first
 *  commit; on a session relay a viewer of the other mode answers the
 *  running game again. */
async function decorations() {
  console.log('== decorations: an SDL game, client-side by default, server-side for a scene that draws frames ==');
  const spec = need('game');
  if (!spec) return;
  const session = !!hl.engine.session();
  let out = '';
  const start = () => {
    const p = runApp(spec);
    p.stdout!.on('data', (c) => { out += c; });
    return p;
  };
  // (a real game draws every frame: commits never settle)
  const mapped = async () => {
    await until(() => hl.windows().length === 1, 20000, `${spec.name}'s window`);
    await sleep(500);
    return hl.windows()[0]!;
  };
  let game = start();
  let win = await mapped();
  check(!win.decorated, `default: not decorated (${win.width}x${win.height})`);
  if (!realApps) check(/decoration: client_side/.test(out) && /Created a window/.test(out), 'the game was configured client_side and drew its window');

  // a scene that draws frames: a page reload with decorations 'server'
  hl.dispose();
  if (!session) await until(() => !alive(game), 5000, 'the game to end with its link (passthrough)');
  const s0 = synced, o0 = order.length;
  opened = false;
  hl = await attach('server');
  await until(() => opened, 10000, 'the link to open');
  if (session) {
    await until(() => synced > s0, 10000, 'the scene replay (synced)');
    if (!realApps) await until(() => /decoration: server_side/.test(out), 5000, 'the running game to be answered server_side');
    await until(() => hl.windows()[0]?.decorated, 5000, 'the running game to be decorated');
    check(true, 'session: the running game was answered server_side when the viewer attached');
  } else {
    out = '';
    game = start();
  }
  win = await mapped();
  check(win.decorated, `'server': decorated (${win.width}x${win.height})`);
  const key = `c${win.conn}s${win.surface}`;
  const told = order.indexOf(`decoration ${key} true`, o0), first = order.indexOf(`commit ${key}`, o0);
  check(told >= 0 && (session || (first >= 0 && told < first)), `known before its first commit (${order.slice(o0).filter((l) => l.includes(key)).join(', ')})`);
  if (!realApps) {
    check(/decoration: server_side/.test(out) && /Created a window/.test(out), 'the game was configured server_side and drew its window');
    check(win.width === 800 && win.height === 600, 'its box is its content, 800x600 (no frame added)');
    // SDL_SetWindowBordered(false): set_mode(client_side), then back
    hl.click(win.x + 400, win.y + 300);
    hl.press('KeyB');
    await until(() => !hl.windows()[0]?.decorated, 5000, 'client_side asked to undecorate it');
    hl.press('KeyB');
    await until(() => hl.windows()[0]?.decorated, 5000, 'server_side asked to decorate it again');
    check(true, 'set_mode(client_side) / set_mode(server_side) after the map: decorated follows');
  }
  await stop(game);
  await noWindows();

  // foot binds xdg-decoration and prefers server_side; its fixture, like
  // GTK, never asks: client-side under 'server' too
  const term = need('term');
  if (term) {
    const app = runApp(term);
    const t = await oneWindow(term.name);
    check(t.decorated === realApps, realApps ? 'foot asked for server_side: decorated' : 'a toplevel that never asks: not decorated');
    await stop(app);
    await noWindows();
  }

  // back to the default for whatever follows
  hl.dispose();
  opened = false;
  hl = await attach();
  await until(() => opened, 10000, 'the link to open');
}

async function gpu() {
  console.log('== a GPU client: dmabufs named as resources (--dmabuf virtgpu, test-only device) ==');
  if (realApps) return console.log('  skipped: fixtures only (virtgpu:@fake takes memfds, not a real GPU\'s dmabufs)');
  if (RELAY.includes('session')) return console.log('  skipped: a session relay takes the copy backend only (no --dmabuf virtgpu yet)');
  const spec = need('dmabuf');
  if (!spec) return;
  // a relay of its own: the main one takes no dmabufs
  const display = 'wland-hl-gpu', port = PORT + 1;
  if (!/virtgpu/.test(spawnSync(RELAY[0], [...RELAY.slice(1), '--help'], { encoding: 'utf8' }).stderr ?? '')) {
    return console.log('  skipped: this relay has no --dmabuf virtgpu (WLAND_E2E_RELAY: an older build)');
  }
  const relay2 = run(RELAY[0], [...RELAY.slice(1), '--port', String(port), '--web-root', webRoot, '--display', display, '--xwayland', 'off', '--dmabuf', 'virtgpu:@fake']);
  let hl2: Headless | null = null;
  const refs: GpuRef[] = [];
  const errs: string[] = [];
  let released = 0, open2 = false;
  try {
    for (let up = false; !up;) {
      if (!alive(relay2)) throw new Error('FAIL: the virtgpu relay exited at startup');
      up = await fetch(`http://127.0.0.1:${port}/`).then(() => true, () => false);
      if (!up) await sleep(50);
    }
    hl2 = await createHeadless({
      link: `ws://127.0.0.1:${port}/ws`, width: 800, height: 600,
      // a stand-in renderer: each resource a colour of its own
      gpu: {
        resolve(ref) {
          refs.push(ref);
          const data = new Uint8Array(ref.width * ref.height * 4);
          const c = [0x40 * (ref.resource % 4), 0x80, 0xff - 0x30 * (ref.resource % 4), 0xff];
          for (let i = 0; i < data.length; i += 4) data.set(c, i);
          return { width: ref.width, height: ref.height, data };
        },
        release() { released++; },
      },
      onEvent(ev) {
        if (ev.type === 'open') open2 = true;
        else if (ev.type === 'error') errs.push(ev.detail);
      },
    });
    await until(() => open2, 5000, 'the virtgpu link to open');
    const app2 = run(spec.cmd, spec.args, { ...spec.env, WAYLAND_DISPLAY: display });
    let out = '';
    app2.stdout!.on('data', (c) => { out += c; });
    await until(() => refs.length > 40 || !alive(app2), 10000, 'GPU commits');
    check(alive(app2) && refs.length > 40, `${refs.length} COMMITs of kind virtgpu, the client still drawing (its two buffers came back after their ACKs)`);
    check(/dmabuf: format XR24 modifier 0x00ffffffffffffff/.test(out), 'the client picked XRGB8888 with the implicit modifier from the feedback');
    const resources = new Set(refs.map((r) => r.resource));
    // (a buffer released before the next frame is drawn again: one or both)
    check(resources.size >= 1 && resources.size <= 2 && [...resources].every((r) => r >= 1), `a resource per buffer drawn (${[...resources].join(', ')} for its two)`);
    const bad = refs.filter((r) => r.width !== 256 || r.height !== 192 || r.format !== 0x34325258 || r.flags !== 0
      || r.offset !== 0 || r.stride !== 1024 || r.modifier !== 0x00ffffffffffffffn);
    check(bad.length === 0, 'every ref: 256x192 XR24, stride 1024, modifier MOD_INVALID, flags 0');
    const win = hl2.windows()[0]!;
    const surf = hl2.surfaces().find((s) => s.conn === win.conn && s.surface === win.surface)!;
    check(win.title === 'simple-dmabuf-egl' && surf.gpu?.kind === 'virtgpu', `its window ("${win.title}") shows a GPU buffer (resource ${surf.gpu?.resource})`);
    check(colours(hl2.screenshot({ window: win })) >= 1 && released > 0, `resolved images drawn and released (${released})`);
    await stop(app2);
    await until(() => hl2!.windows().length === 0, 5000, 'the window to go');
    check(released === refs.length, `every resolved image released (${released}/${refs.length})`);
    check(errs.length === 0, `no engine error events ${errs.join('; ')}`);

    // the same relay, a page with no gpu source: the relay's FEATURE
    // dmabuf_kind (virtgpu) makes the core leave linux-dmabuf off, so a GPU
    // client can't take a path nothing would show
    hl2.dispose();
    hl2 = null;
    const logs: string[] = [];
    let open3 = false;
    hl2 = await createHeadless({
      link: `ws://127.0.0.1:${port}/ws`, width: 800, height: 600,
      onEvent(ev) {
        if (ev.type === 'open') open3 = true;
        else if (ev.type === 'log') logs.push(ev.line);
        else if (ev.type === 'error') errs.push(ev.detail);
      },
    });
    await until(() => open3, 5000, 'the gpu-less link to open');
    await until(() => logs.some((l) => /linux-dmabuf not offered/.test(l)), 3000, 'the core to refuse linux-dmabuf');
    check(true, 'no gpu source: the core logged that linux-dmabuf is not offered');
    // weston-simple-dmabuf-egl exits without the global; so does its fixture
    const app3 = run(spec.cmd, spec.args, { ...spec.env, WAYLAND_DISPLAY: display });
    let err3 = '';
    app3.stderr!.on('data', (c) => { err3 += c; });
    await until(() => !alive(app3), 5000, 'the GPU client to give up');
    check(app3.exitCode !== 0 && /zwp_linux_dmabuf_v1 is not advertised/.test(err3), `the GPU client finds no zwp_linux_dmabuf_v1 and exits (${err3.trim()})`);
    const soft = need('shm');
    if (soft) {
      const app4 = run(soft.cmd, soft.args, { ...soft.env, WAYLAND_DISPLAY: display });
      await until(() => hl2!.windows().length > 0, 5000, 'a wl_shm window on the gpu-less link');
      await sleep(300);
      check(colours(hl2.screenshot({ window: hl2.windows()[0]! })) > 4, 'a wl_shm client still draws there');
      await stop(app4);
    }
    check(errs.length === 0, `no engine error events ${errs.join('; ')}`);
  } finally {
    hl2?.dispose();
    relay2.kill('SIGTERM');
    await until(() => !alive(relay2), 3000, 'the virtgpu relay to exit').catch(() => {});
  }
}

let code = 0;
try {
  // the WS link connects once: the relay must be listening first
  for (let up = false; !up;) {
    if (!alive(relay)) throw new Error('FAIL: the relay exited at startup (port in use?)');
    up = await fetch(`http://127.0.0.1:${PORT}/`).then(() => true, () => false);
    if (!up) await sleep(50);
  }
  hl = await attach();
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
  await browser();
  await nautilus();
  await x11();
  await scale2();
  await reattach();
  await decorations();
  await gpu();
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
