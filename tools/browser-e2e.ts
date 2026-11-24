// Browser E2E: every check that needs a real browser, driven over CDP against
// the pages in test/browser (wland/client in a bare document; `build <dir>`
// bundles them into a web root). One phase per run; tools/run-poc.sh builds
// the pages, starts the server, chromium and the apps, and calls the phases
// in order.
//
//   bun tools/browser-e2e.ts <phase> [cdp_port=9222] [args...]
//
// These cover the browser surface only: lib/view.ts, present.ts, input.ts,
// wm.ts and client.ts. What an app does through the compositor is checked
// without a browser, by tools/headless-e2e-test.ts. Run them when that surface changed (see
// .agents/testing.md "What to run"); core, relay and engine behaviour is
// covered without a browser (zig build test, node --test, relay-e2e-test).
//
// The apps are test/support/apps.ts's: wland-fixture modes by default
// (`term` for foot, `files` for nautilus, `cursor` for weston-flower,
// `constraints` for weston-constraints, `touch` for weston-simple-touch),
// the real ones with WLAND_E2E_APPS=real. run-poc starts them from the same table.
//
// Phases (the app each expects is run-poc's to start, unless noted):
//   terminal     foot: typed keys (KeyboardEvent → evdev) render glyphs
//   sweep        any toplevel: pointer sweep, clicks, wheel; motion coalescing;
//                a drag out of the window keeps the pressed surface (implicit grab)
//   layout       foot: CSD subsurfaces assembled around the grid
//   resize       any toplevel: a quick click on the app's own resize border
//                starts no grab (its request comes after the release); a
//                drag on it resizes
//   hole         foot + a second term over it (Alt+dragged: the box captures)
//                with a border-only input region: a click in the hole reaches
//                the term behind (focus, raise); the border and the
//                fullscreen backdrop keep theirs
//   cursor       weston-flower: its cursor surface is the CSS cursor
//                (set_cursor, no cursor-shape); drawn as an element it
//                follows the pointer and takes no input; leaving resets it
//   constraints  weston-constraints (spawned with WAYLAND_DEBUG, read back):
//                a press confines to its subsurface and a drag out keeps the
//                motion clamped (pointer capture); the next press locks — the
//                browser grants Pointer Lock, relative motion only — and an
//                exit the page didn't ask for reaches the app as unlocked
//   touch        weston-simple-touch + weston-flower (spawned with
//                WAYLAND_DEBUG, read back): CDP fingers are wl_touch points —
//                a tap, a drag out of the window (its coordinates, no pan:
//                touch-action none), two fingers (ids reused), a title-strip
//                drag moving the window by the finger (the app's point
//                cancelled; fixture only), a pan with touch-action auto
//                cancelled — and no wl_pointer; flower (no wl_touch) gets the
//                finger as the pointer
//   dnd          fixture `files` only: its file dragged onto its folder (the
//                browser's pointer → wm dnd → wl_data_device) arrives
//   pagednd      spawns fixture `files` (stdout read back): an HTML drag from
//                outside the page (CDP Input.dispatchDragEvent: a link) over
//                its folder is the app's drag (lib/dnd.ts) — dropEffect none
//                until it accepts, then its preferred move; the drop reaches it (`DROPPED
//                <uri> ON folder`); a dropped file with no files hook is
//                its content (text/plain), after the drop, and does not
//                navigate the page; reloaded with ?dndfiles=1 (the page's
//                hook) a dropped file reaches the app as the hook's URI
//   gtk          nautilus: popup opens below its button, outside click
//                dismisses, navigation; the fixture's right-click menu
//                lands at the pointer (positioners from the window geometry);
//                Alt+dragged to the desktop's right edge, its right-click
//                menu stays inside the desktop (the wm told the core where
//                the window is: constraint adjustment)
//   csd          nautilus: headerbar drag moves, maximize and restore buttons
//   states       ?browserfs=1, spawns foot: Alt+F11 fills the desktop and
//                takes the browser's fullscreen, leaving that ends foot's;
//                Alt+F9 hides it, windows()[0].raise() restores it focused
//   embedder     reloads with ?embedder=1, ?altdrag=0, ?display=0, ?autofocus=0, spawns
//                terms itself: a blur mid-drag ends wland's own grab and an
//                embedder's input.grab (the next drag works); the embedder's
//                `interactive` takes a move, a resize and an Alt+drag with
//                their press (no grab of wland's); Alt+drag off leaves the
//                press to the app and Alt+F10 on; autoFocus off focuses
//                nothing by itself, input.focus() does; minimized hides the
//                element, with ?display=0 (manageDisplay off) the view
//                never writes its display
//   retina      dpr 2 → 2x buffers shown at logical size (spawns foot)
//   takeover     the first tab after a second connected: notice, no reload
//   webgl        forced GL present path, software GL at dpr 1 (spawns foot)
//   clipboard    foot: the clipboard bridge (lib/clipboard.ts) in a real
//                browser — the page clipboard's text (writeText; only write
//                access granted, so it must come in the paste event) pasted
//                into foot by Ctrl+Shift+V runs as a printf (retitle); a
//                word double-clicked in foot and Ctrl+Shift+C (the fixture
//                copies its last output line, the same word) reaches the
//                page clipboard (read back with clipboard-read); Ctrl+C and
//                the copy command in the desktop leave it as it was (no
//                page selection copied)
//   handle-demo [origin]   /handle-demo.html: link v2 handle path in one page
// Drivers, for exploring by hand (tools/dnd-test.sh uses `drag`):
//   drag x1 y1 x2 y2   slow drag, px relative to nautilus's main canvas
//   shot <file.png>    page screenshot      log [grep]   window.wlandLog tail

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { app as appFor, realApps, type AppRole } from "../test/support/apps.ts";
import { isolatedMirror } from "../test/support/isolated.ts";
import { moveRequests, pointerEvents, touchEvents, touchLines } from "../test/support/touch-log.ts";

const [phase = "", cdpPort = "9222", ...args] = process.argv.slice(2);

/** Start the app for `role` (fixture or real, test/support/apps.ts). */
function spawnApp(role: AppRole, opts: { env?: Record<string, string>; stderr?: "pipe" | "ignore" } = {}) {
  const a = appFor(role);
  return Bun.spawn([a.cmd, ...a.args], { stdout: "ignore", stderr: opts.stderr ?? "ignore", env: { ...process.env, ...a.env, ...opts.env } });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
function fail(msg: string): never {
  console.error(`${phase} FAIL: ${msg}`);
  process.exit(1);
}

// --- CDP -------------------------------------------------------------------

async function cdpTarget(): Promise<string> {
  for (let i = 0; i < 50; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json();
      const pages = list.filter((t: any) => t.type === "page");
      // handle-demo with an explicit origin takes any tab (it navigates it)
      const page = pages.find((t: any) => t.url.includes("127.0.0.1")) ??
        (phase === "handle-demo" && args[0] ? pages[0] : undefined);
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(200);
  }
  throw new Error("no CDP page target found");
}

let ws!: WebSocket;
let nextId = 1;
const pending = new Map<number, (v: any) => void>();

async function connect() {
  ws = new WebSocket(await cdpTarget());
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  ws.onmessage = (ev) => {
    const msg = JSON.parse(String(ev.data));
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)!(msg); pending.delete(msg.id); }
  };
}

// a hung renderer (software GL in headless) makes Runtime.evaluate never
// return — race a timeout so it fails loudly instead of hanging
function call(method: string, params: any = {}, tmo = 12000): Promise<any> {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return Promise.race([
    new Promise<any>((r) => pending.set(id, r)),
    new Promise<any>((r) => setTimeout(() => r({ __timeout: true }), tmo)),
  ]);
}

async function evalJs(expr: string): Promise<any> {
  const r = await call("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
  if (r.__timeout) fail(`renderer hung evaluating: ${expr.slice(0, 80)}`);
  if (r.result?.exceptionDetails) fail(`page exception: ${JSON.stringify(r.result.exceptionDetails).slice(0, 400)}`);
  return r.result?.result?.value;
}

const mouse = (type: string, x: number, y: number, more: any = {}) =>
  call("Input.dispatchMouseEvent", { type, x, y, ...more });

/** Move there, press and release the left button. `up` is the `buttons`
 *  value on release (CDP callers disagree; apps don't care). */
async function click(x: number, y: number, settle = 0, up = 0) {
  await mouse("mouseMoved", x, y);
  if (settle) await sleep(settle);
  await mouse("mousePressed", x, y, { button: "left", buttons: 1, clickCount: 1 });
  if (settle) await sleep(60);
  await mouse("mouseReleased", x, y, { button: "left", buttons: up, clickCount: 1 });
}

/** Press at `from`, move to `to` in `steps`, release there. */
async function drag(from: [number, number], to: [number, number], steps: number, pace: number, up = 1) {
  await mouse("mousePressed", from[0], from[1], { button: "left", buttons: 1, clickCount: 1 });
  for (let i = 1; i <= steps; i++) {
    await mouse("mouseMoved", from[0] + ((to[0] - from[0]) * i) / steps, from[1] + ((to[1] - from[1]) * i) / steps,
      { button: "left", buttons: 1 });
    await sleep(pace);
  }
  await mouse("mouseReleased", to[0], to[1], { button: "left", buttons: up, clickCount: 1 });
}

async function key(k: string, code: string, text?: string) {
  await call("Input.dispatchKeyEvent", { type: "keyDown", key: k, code, text });
  await call("Input.dispatchKeyEvent", { type: "keyUp", key: k, code });
}

/** Ctrl+Shift+<letter>, as a keyboard sends it (the browser maps it to its
 *  editing commands: Ctrl+Shift+V is a paste). */
async function ctrlShift(letter: string) {
  const L = letter.toUpperCase();
  const steps: [string, string, number, number][] = [
    ["Control", "ControlLeft", 17, 2], ["Shift", "ShiftLeft", 16, 10], [L, `Key${L}`, L.charCodeAt(0), 10],
  ];
  for (const [k, code, vk, modifiers] of steps)
    await call("Input.dispatchKeyEvent", { type: "rawKeyDown", key: k, code, windowsVirtualKeyCode: vk, modifiers });
  for (const [k, code, vk, modifiers] of steps.reverse())
    await call("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: vk, modifiers: k === "Control" ? 0 : modifiers & ~(k === "Shift" ? 8 : 0) });
}

/** Type plain text: lowercase letters, digits, space, '-', '=', ';'. */
async function typeText(text: string) {
  for (const ch of text) {
    const code = ch === " " ? "Space" : ch === "-" ? "Minus" : ch === "=" ? "Equal" : ch === ";" ? "Semicolon" : /[0-9]/.test(ch) ? `Digit${ch}` : `Key${ch.toUpperCase()}`;
    await key(ch, code, ch);
    await sleep(30);
  }
}

// --- page-side probes ------------------------------------------------------

// the largest visible canvas: an app's main plane (CSD borders are small)
const MAIN = `(() => {
  const cs = [...document.querySelectorAll('#desktop canvas')].filter(c => c.style.display !== 'none');
  return cs.length ? cs.reduce((a, b) => (a.width * a.height >= b.width * b.height ? a : b)) : null;
})()`;

interface Sample {
  key: string; w: number; h: number; cssW: number; cssH: number;
  /** viewport rect */
  x: number; y: number; cw: number; ch: number;
  /** checksum of every pixel, and how many are not near-black */
  sum: number; colored: number;
}

/** The main canvas: geometry and a 2D readback (null: none shown yet). */
const sample = (): Promise<Sample | null> => evalJs(`(() => {
  const c = ${MAIN};
  if (!c) return null;
  const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
  let sum = 0, colored = 0;
  for (let i = 0; i < d.length; i += 4) {
    sum = (sum * 31 + d[i] + d[i+1] * 7 + d[i+2] * 13) >>> 0;
    if (d[i] + d[i+1] + d[i+2] > 30) colored++;
  }
  const r = c.getBoundingClientRect();
  return { key: c.dataset.wland, w: c.width, h: c.height,
           cssW: parseFloat(c.style.width), cssH: parseFloat(c.style.height),
           x: r.left, y: r.top, cw: r.width, ch: r.height, sum, colored };
})()`);

async function waitMain(tries = 75): Promise<Sample> {
  for (let i = 0; i < tries; i++) {
    await sleep(200);
    const s = await sample();
    if (s) return s;
  }
  return fail("no canvas appeared");
}

/** nautilus's main canvas key (the first canvas at least `minWidth` wide). */
async function waitWide(minWidth: number): Promise<string> {
  for (let i = 0; i < 100; i++) {
    await sleep(200);
    const k = await evalJs(`(() => {
      window.scrollTo(0, 0);
      const c = [...document.querySelectorAll('#desktop canvas')].find(c => c.width >= ${minWidth});
      return c ? c.dataset.wland : "";
    })()`);
    if (k) return k;
  }
  return fail("nautilus canvas never appeared");
}

async function waitOnline() {
  for (let i = 0; i < 75; i++) {
    if (await evalJs("!!(window.wlandStatus && window.wlandStatus.websocket === true)")) return;
    await sleep(200);
  }
  fail("page did not come online");
}

const tag = (s: Sample) => `${s.w}x${s.h}:${s.sum}:${s.colored}`;

// --- phases ----------------------------------------------------------------

const phases: Record<string, () => Promise<void>> = {
  // M4: `echo hi` + Enter through Input.dispatchKeyEvent; the terminal's
  // pixels must change at each step
  async terminal() {
    await waitMain();
    await sleep(1500); // let the prompt settle
    // preventScroll: viewport-relative CDP coordinates must stay valid
    // (programmatic focus scrolls by default)
    await evalJs(`(() => { window.scrollTo(0, 0); ${MAIN}.focus({ preventScroll: true }); })()`);
    const before = (await sample())!;
    console.log(`before: ${tag(before)}`);
    const CODES: Record<string, string> = { e: "KeyE", c: "KeyC", h: "KeyH", o: "KeyO", i: "KeyI", " ": "Space" };
    for (const ch of "echo hi") {
      await key(ch, CODES[ch]!, ch);
      await sleep(50);
    }
    await sleep(700);
    const typed = (await sample())!;
    console.log(`typed:  ${tag(typed)}`);
    await key("Enter", "Enter", "\r");
    await sleep(1000);
    const after = (await sample())!;
    console.log(`after:  ${tag(after)}`);
    if (typed.sum === before.sum) fail("typing did not change the terminal");
    if (after.sum === typed.sum) fail("enter did not change the terminal");
    console.log("terminal ok: typing renders");
  },

  async clipboard() {
    const s = await waitMain();
    // headless: the page counts as focused (the bridge writes only then)
    await call("Emulation.setFocusEmulationEnabled", { enabled: true });
    const origin: string = await evalJs("location.origin");
    const grant = async (permissions: string[]) => {
      const r = await call("Browser.grantPermissions", { origin, permissions });
      if (r.error) fail(`Browser.grantPermissions(${permissions}): ${JSON.stringify(r.error)}`);
    };
    // page → foot. Write access only: no readText on focus, the text has
    // to come in the browser's paste event
    await grant(["clipboardSanitizedWrite"]);
    const readState = await evalJs("navigator.permissions.query({ name: 'clipboard-read' }).then((p) => p.state)");
    if (readState === "granted") fail("clipboard-read is granted already: this half would not test the paste event");
    const title = "PASTED-FROM-PAGE";
    const wrote = await evalJs(`navigator.clipboard.writeText("printf '\\\\033]2;${title}\\\\007'").then(() => true, (e) => String(e))`);
    if (wrote !== true) fail(`the page's writeText: ${wrote}`);
    await click(s.x + s.cw / 2, s.y + s.ch / 2, 100); // focus foot
    await sleep(300);
    await ctrlShift("v");
    await sleep(300);
    await key("Enter", "Enter", "\r");
    // (real foot's shell may retitle at its next prompt: the page's log
    // keeps the app's set_title requests)
    const retitled = `document.title.includes(${JSON.stringify(title)}) || window.wlandLog.some((l) => l.includes('set_title') && l.includes(${JSON.stringify(title)}))`;
    for (let i = 0; i < 50 && !(await evalJs(retitled)); i++) await sleep(100);
    const got: string = await evalJs("document.title");
    if (!(await evalJs(retitled))) fail(`Ctrl+Shift+V did not paste the page clipboard into foot (title "${got}"; log: ${await evalJs("window.wlandLog.slice(-5).join(' | ')")})`);
    console.log(`page → foot ok: the pasted printf retitled it (title now "${got}")`);

    // foot → page: `clear; echo` leaves the word alone on the first row; a
    // double click on it selects it in real foot (the fixture copies its
    // last output line, the same word), Ctrl+Shift+C copies
    await typeText("clear; echo wland-from-foot");
    await key("Enter", "Enter", "\r");
    await sleep(500);
    const [wx, wy] = [s.x + 40, s.y + 8]; // inside the 15-cell word for any cell over 3 px
    await mouse("mouseMoved", wx, wy);
    for (const n of [1, 2]) {
      await mouse("mousePressed", wx, wy, { button: "left", buttons: 1, clickCount: n });
      await mouse("mouseReleased", wx, wy, { button: "left", buttons: 0, clickCount: n });
    }
    await sleep(300);
    await ctrlShift("c"); // the gesture the write rides on
    await grant(["clipboardReadWrite", "clipboardSanitizedWrite"]);
    let page = "";
    for (let i = 0; i < 50; i++) {
      page = await evalJs("navigator.clipboard.readText().catch((e) => 'ERR ' + e)");
      if (page === "wland-from-foot") break;
      await sleep(100);
    }
    if (page !== "wland-from-foot") fail(`foot's Ctrl+Shift+C did not reach the page clipboard ("${page}"; log: ${await evalJs("window.wlandLog.filter((l) => l.includes('clipboard')).join(' | ')")})`);
    console.log("foot → page ok: the page clipboard holds foot's copy");

    // the page's selection is never copied from the desktop: Ctrl+C there
    // (an interrupt; nothing owed: a plain key) and the browser's copy
    // command (its copy event cancelled with nothing set) leave the page
    // clipboard as it was
    await evalJs(`(() => {
      const p = document.createElement('p');
      p.textContent = 'STALE PAGE TEXT';
      Object.assign(p.style, { position: 'fixed', left: '10px', bottom: '10px', margin: '0', zIndex: '10000', background: '#fff' });
      document.body.appendChild(p);
      getSelection().selectAllChildren(p);
      return true;
    })()`);
    await click(s.x + s.cw / 2, s.y + s.ch / 2, 100);
    await sleep(200);
    await call("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17, modifiers: 2 });
    await call("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "c", code: "KeyC", windowsVirtualKeyCode: 67, modifiers: 2 });
    await call("Input.dispatchKeyEvent", { type: "keyUp", key: "c", code: "KeyC", windowsVirtualKeyCode: 67, modifiers: 2 });
    await call("Input.dispatchKeyEvent", { type: "keyUp", key: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17, modifiers: 0 });
    await call("Runtime.evaluate", { expression: "document.execCommand('copy')", userGesture: true, returnByValue: true });
    await sleep(200);
    page = await evalJs("navigator.clipboard.readText().catch((e) => 'ERR ' + e)");
    if (page !== "wland-from-foot") fail(`Ctrl+C / the copy command in the desktop changed the page clipboard ("${page}")`);
    console.log("desktop copy chord ok: no page selection copied, a cancelled empty copy event keeps the clipboard");
  },

  // M7.4, and the check for input changes: many fast moves, left/right
  // click, wheel. The app must survive, and no more motions may ship than
  // raw pointermoves arrived.
  async sweep() {
    await evalJs(`(() => { const c = ${MAIN}; if (c) c.scrollIntoView({ block: 'center', inline: 'center' }); })()`);
    const rect = (await sample()) ?? fail("no canvas to sweep");
    console.log(`sweeping ${rect.cw}x${rect.ch} at (${rect.x},${rect.y}); stats before: ${await evalJs("JSON.stringify(window.wland.engine.stats)")}`);
    // 3 rows × 40 moves, fired WITHOUT awaiting each ack — awaiting round-trips
    // paces the events slower than rAF and defeats coalescing (measured: 1 move
    // per frame). A burst is also what real high-rate mice deliver.
    for (const fy of [0.25, 0.5, 0.75]) {
      const acks: Promise<any>[] = [];
      for (let i = 0; i <= 40; i++) acks.push(mouse("mouseMoved", rect.x + (rect.cw * i) / 40, rect.y + rect.ch * fy));
      await Promise.all(acks);
      await sleep(100);
    }
    const cx = rect.x + rect.cw / 2, cy = rect.y + rect.ch / 2;
    const press = (x: number, y: number, button: string, buttons: number) =>
      mouse("mousePressed", x, y, { button, buttons, clickCount: 1 })
        .then(() => mouse("mouseReleased", x, y, { button, buttons, clickCount: 1 }));
    await press(cx, cy, "left", 1);
    await sleep(300);
    // right click (may open a menu popup), then an outside click to dismiss
    await press(cx, cy, "right", 2);
    await sleep(700);
    await press(rect.x + 5, rect.y + 5, "left", 1);
    await sleep(300);
    await mouse("mouseWheel", cx, cy, { deltaX: 0, deltaY: 120 });
    await mouse("mouseWheel", cx, cy, { deltaX: 0, deltaY: -120 });
    await sleep(500);

    const stats = await evalJs("window.wland.engine.stats");
    console.log(`stats after: ${JSON.stringify(stats)}`);
    const alive = await sample();
    // Chromium itself coalesces pointermove to ≤1/frame (123 dispatched
    // events yielded 11 pointermoves), so huge raw counts are impossible here;
    // our rAF flush is the structural cap + backpressure gate on top.
    if (stats.motions < 6) fail(`sweep barely hit the canvas (motions=${stats.motions})`);
    if (stats.sentMotions < 1) fail("no motions shipped at all");
    if (stats.sentMotions > stats.motions) fail("more motions shipped than raw moves?!");
    if (!alive || alive.colored < 100) fail(`canvas blank/dead after sweep (colored=${alive?.colored})`);
    console.log(`sweep ok: app survived; ${stats.motions} raw moves → ${stats.sentMotions} shipped motions, ${stats.backpressured} backpressured`);

    // the implicit grab (pointer capture): a press, then a drag out of the
    // window keeps the pointer on the pressed surface — motion in its local
    // px past its edge, no leave — until the release, which brings the leave
    await evalJs(`(() => {
      const e = window.wland.engine, seen = window.grabSeen = [];
      for (const name of ['pointerLeave', 'pointerEnter', 'pointerMotion', 'pointerButton']) {
        const orig = e[name];
        e['_' + name] = orig;
        e[name] = (...a) => { seen.push([name, ...a]); return orig(...a); };
      }
    })()`);
    const outX = rect.x + rect.cw + 60, outY = rect.y + rect.ch / 2;
    await mouse("mouseMoved", cx, cy);
    await sleep(100);
    await drag([cx, cy], [outX, outY], 6, 40);
    await sleep(300);
    const seen: any[][] = await evalJs(`(() => {
      const e = window.wland.engine;
      for (const name of ['pointerLeave', 'pointerEnter', 'pointerMotion', 'pointerButton']) e[name] = e['_' + name];
      return window.grabSeen;
    })()`);
    const up = seen.findIndex((c) => c[0] === "pointerButton" && c[4] === false);
    const before = up < 0 ? seen : seen.slice(0, up);
    console.log(`drag out: ${seen.map((c) => c[0] === "pointerMotion" ? `motion(${Math.round(c[3])})` : c[0]).join(" ")}`);
    if (up < 0) fail("the release did not reach the pressed surface");
    if (before.some((c) => c[0] === "pointerLeave" || c[0] === "pointerEnter")) fail("the pointer left the pressed surface while the button was held");
    if (!before.some((c) => c[0] === "pointerMotion" && c[3] > rect.cw)) fail("no motion past the surface's edge while the button was held");
    if (!seen.slice(up).some((c) => c[0] === "pointerLeave")) fail("no leave after the release outside the window");
    console.log("implicit grab ok: a held button keeps the pressed surface; the leave comes with the release");
  },

  // M5: foot's CSD subsurfaces sit around the main grid (titlebar above,
  // borders around) inside one window element — not stacked
  async layout() {
    const read = async (): Promise<any[]> => JSON.parse(await evalJs(`JSON.stringify(
      [...document.querySelectorAll('#desktop .wland-window')].map(box => ({
        canvases: [...box.querySelectorAll('canvas')].map(c => {
          const r = c.getBoundingClientRect();
          return { w: c.width, h: c.height, left: r.left, top: r.top, right: r.right, bottom: r.bottom,
                   visible: c.style.display !== 'none' };
        }),
      })))`));
    // wait until a window holds foot's full canvas set (grid + decorations)
    let windows: any[] = [];
    for (let i = 0; i < 75; i++) {
      await sleep(200);
      windows = await read();
      if (windows.some((w) => w.canvases.length >= 5)) break;
    }
    const win = windows.find((w) => w.canvases.length >= 5) ?? fail(`no assembled window found: ${JSON.stringify(windows)}`);
    const visible = win.canvases.filter((c: any) => c.visible);
    const grid = visible.reduce((a: any, b: any) => (a.w * a.h >= b.w * b.h ? a : b));
    // titlebar: a wide and short canvas that is not the grid
    const titlebar = visible.find((c: any) => c !== grid && c.w > 4 * c.h && c.w > grid.w * 0.8) ??
      fail("no titlebar-shaped canvas found");
    console.log(`grid: ${grid.w}x${grid.h} at (${grid.left},${grid.top})`);
    console.log(`titlebar: ${titlebar.w}x${titlebar.h} at (${titlebar.left},${titlebar.top})`);
    if (!(titlebar.bottom <= grid.top + 2)) fail("titlebar is not above the grid — still stacked?");
    const overlap = Math.min(titlebar.right, grid.right) - Math.max(titlebar.left, grid.left);
    if (overlap < grid.w * 0.5) fail("titlebar does not horizontally overlap the grid");
    // every decoration within a sane bounding box of the grid (±64px)
    for (const c of visible) {
      if (c.left < grid.left - 64 || c.top < grid.top - 64 || c.right > grid.right + 64 || c.bottom > grid.bottom + 64) {
        fail(`canvas ${c.w}x${c.h} at (${c.left},${c.top}) is far from the window`);
      }
    }
    console.log("layout ok: CSD assembled around the grid");
  },

  // wl_pointer.set_cursor with a surface (weston's toytoolkit, as older
  // toolkits and X apps through satellite do): hovering the app, its window
  // element's CSS cursor is that surface's buffer as an image-set data URL
  // with the hotspot. The element fallback (images CSS can't show) is
  // forced by replaying the event with a hotspot off the image.
  async cursor() {
    await evalJs(`(() => { window.scrollTo(0, 0); window.wlandCursor = undefined; })()`);
    const s = await waitMain();
    const cx = Math.round(s.x + s.cw / 2), cy = Math.round(s.y + s.ch / 2);
    for (const d of [-6, -3, 0]) { await mouse("mouseMoved", cx + d, cy + d); await sleep(50); }
    const css = `(${MAIN}).closest('.wland-window').style.cursor`;
    let cursor = "";
    for (let i = 0; i < 50 && !/image-set\(url\("data:image\/png/.test(cursor); i++) {
      await sleep(100);
      cursor = await evalJs(css);
    }
    const m = /image-set\(url\("([^"]+)"\) ([\d.]+)x\) (-?\d+) (-?\d+), /.exec(cursor) ??
      fail(`no cursor image on the window: "${cursor.slice(0, 120)}"`);
    const [, url, scale, hx, hy] = m;
    const img = await evalJs(`(async () => {
      const i = new Image();
      i.src = ${JSON.stringify(url)};
      await i.decode();
      const c = document.createElement('canvas');
      c.width = i.naturalWidth; c.height = i.naturalHeight;
      const g = c.getContext('2d');
      g.drawImage(i, 0, 0);
      const d = g.getImageData(0, 0, c.width, c.height).data;
      let opaque = 0;
      for (let k = 3; k < d.length; k += 4) if (d[k] > 128) opaque++;
      return { w: i.naturalWidth, h: i.naturalHeight, opaque };
    })()`);
    console.log(`cursor image ${img.w}x${img.h} at ${scale}x, hotspot ${hx},${hy}, ${img.opaque} opaque px`);
    if (!(img.w > 0 && img.opaque > 10)) fail("the cursor image is empty");
    if (!(+hx >= 0 && +hy >= 0 && +hx < img.w / +scale && +hy < img.h / +scale)) fail("hotspot outside the image");
    const ev = await evalJs("window.wlandCursor");
    if (!ev || !ev.surface || ev.hotspotX !== +hx || ev.hotspotY !== +hy) fail(`cursor event ${JSON.stringify(ev)}`);
    // (through surfaceOf: the target may be an input region's hit element)
    const hit = `window.wland.view.surfaceOf(document.elementFromPoint(X, Y))?.surface`;
    const main = await evalJs(`window.wland.view.surfaceOf(${MAIN}).surface`);
    if (await evalJs(hit.replace("X", String(cx)).replace("Y", String(cy))) !== main) fail("the cursor surface took the pointer");

    // the element fallback: a hotspot CSS can't take puts the cursor canvas
    // at the pointer, with cursor: none, and the app keeps the hit-testing
    await evalJs(`window.wland.view.handle({ ...window.wlandCursor, hotspotX: -4, hotspotY: -4 })`);
    await mouse("mouseMoved", cx + 10, cy + 10);
    await sleep(100);
    const el = await evalJs(`(() => {
      const c = document.querySelector('canvas[data-wland="c${ev.conn}s${ev.surface}"]');
      const r = c && c.getBoundingClientRect();
      return c && { display: c.style.display, left: r.left, top: r.top, css: ${css} };
    })()`);
    console.log(`element fallback: ${JSON.stringify(el)}`);
    if (!el || el.display !== "block" || el.css !== "none") fail("the cursor canvas is not shown in place of the CSS cursor");
    if (Math.abs(el.left - (cx + 14)) > 1 || Math.abs(el.top - (cy + 14)) > 1) fail("the cursor canvas does not follow the pointer");
    if (await evalJs(hit.replace("X", String(cx + 16)).replace("Y", String(cy + 16))) !== main) fail("the cursor canvas intercepts the pointer");
    await evalJs(`window.wland.view.handle(window.wlandCursor)`);
    if (!/^image-set\(/.test(await evalJs(css))) fail("back to the CSS cursor");

    // off the window: the default pointer again
    const box = await evalJs(`(${MAIN}).closest('.wland-window').getBoundingClientRect().toJSON()`);
    const ox = box.right + 40 < 1590 ? box.right + 40 : 5, oy = Math.min(box.bottom + 40, 1090);
    await mouse("mouseMoved", ox, oy);
    for (let i = 0; i < 30 && (cursor = await evalJs(css)) !== ""; i++) await sleep(100);
    if (cursor !== "") fail(`leaving kept the cursor: "${cursor.slice(0, 80)}"`);
    console.log("cursor ok: the app's cursor surface is the pointer; the element fallback follows it; leaving resets it");
  },

  // pointer-constraints in a real browser, against a real client: the
  // browser's Pointer Lock (requested by input.ts when the core wants the
  // lock: the CDP press is the user activation) and the implicit grab
  // keeping a confined drag clamped. The client's side is its own
  // WAYLAND_DEBUG log. CDP's Escape doesn't exit a lock in headless
  // chromium, so the user's exit is document.exitPointerLock() from here:
  // one input.ts didn't ask for, which is what Esc is to it.
  async constraints() {
    const app = spawnApp("constraints", { stderr: "pipe", env: { WAYLAND_DEBUG: "1" } });
    let log = "";
    (async () => { for await (const c of app.stderr) log += new TextDecoder().decode(c); })();
    const after = (re: RegExp, from: number) => re.exec(log.slice(from));
    const waitLog = async (re: RegExp, from: number, what: string) => {
      for (let i = 0; i < 50 && !after(re, from); i++) await sleep(100);
      if (!after(re, from)) { app.kill(); fail(`no ${what} in the client's log`); }
      return from + after(re, from)!.index;
    };
    try {
      // its gray subsurface: the second canvas of its window, 125x100
      let sub: any = null;
      for (let i = 0; i < 75 && !sub; i++) {
        await sleep(200);
        sub = await evalJs(`(() => {
          window.scrollTo(0, 0);
          const c = [...document.querySelectorAll('#desktop canvas')].find(c => c.width === 125 && c.height === 100 && c.style.display !== 'none');
          if (!c) return null;
          const r = c.getBoundingClientRect();
          return { key: c.dataset.wland, x: r.left, y: r.top, w: r.width, h: r.height };
        })()`);
      }
      if (!sub) fail("weston-constraints' subsurface never appeared");
      await evalJs(`(() => {
        const e = window.wland.engine, seen = window.lockSeen = [];
        for (const name of ['pointerLockGranted', 'pointerLockLost', 'pointerMotion']) {
          const orig = e['_' + name] = e[name];
          e[name] = (...a) => { seen.push([name, ...a]); return orig(...a); };
        }
      })()`);
      const cx = Math.round(sub.x + sub.w / 2), cy = Math.round(sub.y + sub.h / 2);
      await mouse("mouseMoved", cx, cy);
      await sleep(200);
      // press 1: confined to the subsurface; dragged out with the button held
      // the client sees the pointer stop at its edge
      await mouse("mousePressed", cx, cy, { button: "left", buttons: 1, clickCount: 1 });
      const confined = await waitLog(/zwp_confined_pointer_v1#\d+\.confined\(\)/, 0, "confined()");
      for (const dx of [30, 60, 90, 120]) {
        await mouse("mouseMoved", cx + dx, cy, { button: "left", buttons: 1 });
        await sleep(50);
      }
      await waitLog(/wl_pointer#\d+\.motion\(\d+, 124\.\d+, /, confined, "a motion clamped to the subsurface's edge");
      console.log("confined: a drag 120 px out of the 125 px subsurface stops at x=124.99");
      await mouse("mouseMoved", cx, cy, { button: "left", buttons: 1 });
      await mouse("mouseReleased", cx, cy, { button: "left", buttons: 0, clickCount: 1 });
      await sleep(300);

      // press 2: the lock — the core wants it, input.ts asks the browser
      // (the press's activation), the browser grants, the app hears locked
      const from = log.length;
      await click(cx, cy);
      const locked = await waitLog(/zwp_locked_pointer_v1#\d+\.locked\(\)/, from, "locked()");
      const el = await evalJs(`(() => { const e = document.pointerLockElement; return e && window.wland.view.surfaceOf(e); })()`);
      if (!el || `c${el.conn}s${el.surface}` !== sub.key) fail(`the browser's pointer lock is on ${JSON.stringify(el)}, not ${sub.key}`);
      console.log(`locked: the browser's Pointer Lock is on ${sub.key}, the app got locked()`);
      // moves under the lock: movementX/Y, clientX/Y frozen → relative only
      for (const [x, y] of [[cx + 15, cy + 5], [cx + 30, cy + 10], [cx + 10, cy + 10]]) {
        await mouse("mouseMoved", x, y);
        await sleep(60);
      }
      await waitLog(/relative_motion\(/, locked, "relative_motion");
      const rel = [...log.slice(locked).matchAll(/relative_motion\(\d+, \d+, (-?[\d.]+), (-?[\d.]+), /g)].map((m) => [+m[1], +m[2]]);
      const sum = rel.reduce((a, r) => [a[0] + r[0], a[1] + r[1]], [0, 0]);
      console.log(`relative motion: ${JSON.stringify(rel)} (sum ${sum})`);
      if (sum[0] !== 10 || sum[1] !== 10) fail("the relative motion does not add up to the moves (10, 10)");
      if (after(/wl_pointer#\d+\.motion\(/, locked)) fail("a wl_pointer.motion while locked");
      // the user leaves the lock (what Esc does): unlocked
      await evalJs("document.exitPointerLock()");
      await waitLog(/zwp_locked_pointer_v1#\d+\.unlocked\(\)/, locked, "unlocked()");
      const seen: any[][] = await evalJs("window.lockSeen");
      const names = seen.filter((c) => c[0] !== "pointerMotion").map((c) => c[0]);
      if (names.join() !== "pointerLockGranted,pointerLockLost") fail(`engine calls: ${names}`);
      console.log("constraints ok: confined drag clamped; Pointer Lock granted → locked, relative motion only; the exit → unlocked");
    } finally {
      app.kill();
      await evalJs(`(() => { const e = window.wland.engine; for (const n of ['pointerLockGranted', 'pointerLockLost', 'pointerMotion']) if (e['_' + n]) e[n] = e['_' + n]; })()`);
    }
  },

  // Touch: real Chromium fingers (CDP Input.dispatchTouchEvent: PointerEvents
  // with pointerType 'touch', no touch emulation needed) on weston-simple-touch
  // (spawned with WAYLAND_DEBUG, read back through test/support/touch-log.ts)
  // are its wl_touch points and never its pointer; on weston-flower (no
  // wl_touch) a finger is the pointer. The container's touch-action: none
  // keeps a drag the app's: with it set back to auto for a moment, the same
  // drag is a browser pan — pointercancel → wl_touch.cancel.
  async touch() {
    const app = spawnApp("touch", { stderr: "pipe", env: { WAYLAND_DEBUG: "1" } });
    let log = "";
    (async () => { for await (const c of app.stderr) log += new TextDecoder().decode(c); })();
    let flower: ReturnType<typeof spawnApp> | null = null;
    const touch = (type: string, touchPoints: { x: number; y: number; id: number }[]) =>
      call("Input.dispatchTouchEvent", { type, touchPoints });
    // a canvas of that buffer size: its viewport rect and surface
    const find = (w: number, h: number): Promise<any> => evalJs(`(() => {
      window.scrollTo(0, 0);
      const c = [...document.querySelectorAll('#desktop canvas')].find(c => c.width === ${w} && c.height === ${h} && c.style.display !== 'none');
      if (!c) return null;
      const r = c.getBoundingClientRect(), s = window.wland.view.surfaceOf(c);
      return { conn: s.conn, surface: s.surface, x: r.left, y: r.top, bound: window.wland.engine.touchBound(s.conn) };
    })()`);
    const waitFor = async (w: number, h: number, what: string) => {
      for (let i = 0; i < 75; i++) {
        const s = await find(w, h);
        if (s) return s;
        await sleep(200);
      }
      return fail(`${what} never appeared`);
    };
    // the app's touch events since `from`, one line each (touch-log.ts)
    const lines = (from: number) => touchLines(touchEvents(log.slice(from)));
    // equal, coordinates within a px (the window may sit at a fractional place)
    const same = (got: string[], want: string[]) => got.length === want.length && got.every((g, i) => {
      const a = g.split(/[ ,]/), b = want[i]!.split(/[ ,]/);
      return a.length === b.length && a.every((x, j) => x === b[j] || Math.abs(Number(x) - Number(b[j])) <= 1);
    });
    const expectLines = async (from: number, want: string[], what: string) => {
      for (let i = 0; i < 30 && lines(from).length < want.length; i++) await sleep(100);
      await sleep(150); // nothing more may follow
      if (!same(lines(from), want)) fail(`${what}: got ${lines(from).join(" | ")}, want ${want.join(" | ")}`);
      if (pointerEvents(log.slice(from)).length) fail(`${what}: the app also got wl_pointer events: ${pointerEvents(log.slice(from)).map((e) => e.name)}`);
      console.log(`${what}: ${lines(from).join(" | ")}`);
    };
    // a finger's path, a frame apart (Chromium coalesces moves to ~1 per frame)
    const path = async (id: number, from: [number, number], to: [number, number], steps: number) => {
      for (let i = 1; i <= steps; i++) {
        await touch("touchMove", [{ x: from[0] + ((to[0] - from[0]) * i) / steps, y: from[1] + ((to[1] - from[1]) * i) / steps, id }]);
        await sleep(30);
      }
    };
    try {
      let s = await waitFor(600, 500, "weston-simple-touch's window");
      for (let i = 0; i < 25 && !s.bound; i++) { await sleep(200); s = await find(600, 500); }
      if (!s.bound) fail("its wl_touch never bound (touchBound false)");
      // every engine call input makes for the fingers and the pointer
      await evalJs(`(() => {
        const e = window.wland.engine, seen = window.touchSeen = [];
        for (const name of ['touchDown', 'touchMotion', 'touchUp', 'touchCancel', 'pointerEnter', 'pointerButton', 'pointerMotion', 'pointerLeave']) {
          const orig = e['_' + name] = e[name];
          e[name] = (...a) => { seen.push([name, a[0]]); return orig(...a); };
        }
      })()`);
      const seen = async (): Promise<string[]> => (await evalJs("window.touchSeen.splice(0)")).map((c: any[]) => `${c[0]} c${c[1]}`);

      // a tap
      let from = log.length;
      await touch("touchStart", [{ x: s.x + 300, y: s.y + 250, id: 0 }]);
      await touch("touchEnd", []);
      await expectLines(from, ["down 0 300,250", "frame", "up 0", "frame"], "a tap");
      const tapCalls = await seen();
      if (tapCalls.some((c) => c.startsWith("pointer"))) fail(`the tap also went the pointer path: ${tapCalls}`);

      // a drag out of the window, left then far right and down: the
      // surface's coordinates all along (the press captured the finger), and
      // no pan (touch-action: none): no pointercancel, so no cancel
      from = log.length;
      await touch("touchStart", [{ x: s.x + 300, y: s.y + 250, id: 0 }]);
      await path(0, [s.x + 300, s.y + 250], [s.x - 30, s.y + 10], 6);
      await path(0, [s.x - 30, s.y + 10], [s.x + 700, s.y + 560], 6);
      await touch("touchEnd", []);
      for (let i = 0; i < 30 && !lines(from).includes("up 0"); i++) await sleep(100);
      const drag = lines(from);
      if (!same(drag.slice(0, 2), ["down 0 300,250", "frame"]) || !same(drag.slice(-2), ["up 0", "frame"])) fail(`the drag: ${drag.join(" | ")}`);
      const moves = touchEvents(log.slice(from)).filter((e) => e.type === "motion") as { x: number; y: number }[];
      const last = moves.at(-1);
      if (!moves.some((m) => m.x < 0) || !last || Math.abs(last.x - 700) > 1 || Math.abs(last.y - 560) > 1)
        fail(`the drag's motion did not follow the finger out of the window: ${drag.join(" | ")}`);
      if (drag.includes("cancel") || (await seen()).includes(`touchCancel c${s.conn}`)) fail(`the drag was cancelled (a pan?): ${drag.join(" | ")}`);
      if (pointerEvents(log.slice(from)).length) fail("the drag also reached the app as wl_pointer");
      if (drag.filter((l) => l !== "frame").length * 2 !== drag.length) fail(`not every event framed: ${drag.join(" | ")}`);
      console.log(`a drag out of the window: ${moves.length} motions, x down to ${Math.min(...moves.map((m) => m.x))}, ending at ${last.x},${last.y}; no cancel (touch-action: none)`);

      // two fingers; the first lifts and a third takes its id
      from = log.length;
      const A = { x: s.x + 100, y: s.y + 300, id: 0 }, B = { x: s.x + 200, y: s.y + 300, id: 1 }, C = { x: s.x + 300, y: s.y + 300, id: 2 };
      await touch("touchStart", [A]);
      await touch("touchStart", [A, B]);
      await sleep(30);
      await touch("touchMove", [A, { ...B, x: B.x + 10 }]);
      await sleep(30);
      await touch("touchEnd", [A]);
      await touch("touchStart", [{ ...B, x: B.x + 10 }, C]);
      await touch("touchEnd", []);
      for (let i = 0; i < 30 && lines(from).filter((l) => l.startsWith("up")).length < 3; i++) await sleep(100);
      const two = lines(from);
      const head = ["down 0 100,300", "frame", "down 1 200,300", "frame", "motion 1 210,300", "frame", "up 0", "frame", "down 0 300,300", "frame"];
      if (!same(two.slice(0, head.length), head) || two.slice(head.length).filter((l) => l !== "frame").sort().join() !== "up 0,up 1")
        fail(`two fingers: ${two.join(" | ")}`);
      if (pointerEvents(log.slice(from)).length) fail("two fingers: the app also got wl_pointer events");
      console.log(`two fingers, a third reusing the freed id: ${two.join(" | ")}`);
      await seen();

      // a finger in the fixture's title strip: its move names the down; the
      // window manager drags the window by that finger, the app's point is
      // cancelled and nothing of the drag reaches it
      if (realApps) console.log("move by finger: skipped (weston-simple-touch has no title strip)");
      else {
        from = log.length;
        await touch("touchStart", [{ x: s.x + 300, y: s.y + 20, id: 0 }]);
        for (let i = 0; i < 50 && !(moveRequests(log.slice(from)).length && (await evalJs("document.body.style.cursor")) === "grabbing"); i++) await sleep(100);
        if (!moveRequests(log.slice(from)).length) fail("the touch-down in the title strip asked for no move");
        if ((await evalJs("document.body.style.cursor")) !== "grabbing") fail("the move request started no grab");
        await path(0, [s.x + 300, s.y + 20], [s.x + 400, s.y + 70], 8);
        await touch("touchEnd", []);
        await sleep(300);
        const moved = await find(600, 500);
        if (Math.abs(moved.x - s.x - 100) > 1 || Math.abs(moved.y - s.y - 50) > 1)
          fail(`the window did not follow the finger by (100, 50): ${s.x},${s.y} → ${moved.x},${moved.y}`);
        const down = touchEvents(log.slice(from)).find((e) => e.type === "down");
        if (down?.type !== "down" || !moveRequests(log.slice(from)).includes(down.serial)) fail("the move did not name the down's serial");
        await expectLines(from, ["down 0 300,20", "frame", "cancel"], "a title-strip drag: the app's lines");
        if ((await evalJs("document.body.style.cursor")) === "grabbing") fail("the grab did not end at the finger's lift");
        console.log(`the finger moved the window by (${moved.x - s.x}, ${moved.y - s.y}) and the app got wl_touch.cancel`);
        s = moved;
        await seen();
      }

      // touch-action back to auto for a moment: the same kind of drag is now
      // the browser's pan — pointercancel, so wl_touch.cancel
      from = log.length;
      await evalJs("document.getElementById('desktop').style.touchAction = 'auto'");
      await touch("touchStart", [{ x: s.x + 300, y: s.y + 250, id: 0 }]);
      await path(0, [s.x + 300, s.y + 250], [s.x + 300, s.y + 450], 6);
      await touch("touchEnd", []);
      await evalJs("document.getElementById('desktop').style.touchAction = 'none'");
      for (let i = 0; i < 20 && !lines(from).includes("cancel"); i++) await sleep(100);
      const panned = lines(from);
      if (!panned.includes("cancel") || panned.includes("up 0")) fail(`with touch-action auto the drag was not cancelled (the control): ${panned.join(" | ")}`);
      if (!(await seen()).includes(`touchCancel c${s.conn}`)) fail("pointercancel did not reach the engine as touchCancel");
      console.log(`control, touch-action auto: the drag became a pan — ${panned.join(" | ")}`);
      // and a tap after it is the app's again
      from = log.length;
      await touch("touchStart", [{ x: s.x + 50, y: s.y + 400, id: 0 }]);
      await touch("touchEnd", []);
      await expectLines(from, ["down 0 50,400", "frame", "up 0", "frame"], "touch-action none again: a tap");
      app.kill();

      // a client with no wl_touch: the finger is the pointer (the emulation)
      const before: string[] = await evalJs("window.wland.view.windows().map((w) => w.key)");
      flower = spawnApp("cursor", { stderr: "pipe", env: { WAYLAND_DEBUG: "1" } });
      let flog = "";
      (async () => { for await (const c of flower!.stderr!) flog += new TextDecoder().decode(c as Uint8Array); })();
      // its toplevel's canvas (the real one's buffer is not 240x240: frame, shadow)
      let f: any = null;
      for (let i = 0; i < 75 && !f; i++) {
        await sleep(200);
        f = await evalJs(`(() => {
          const wl = window.wland, w = wl.view.windows().find((w) => !${JSON.stringify(before)}.includes(w.key));
          const c = w && wl.view.canvas(w.conn, w.surface);
          if (!c || !c.width) return null;
          const r = c.getBoundingClientRect();
          return { conn: w.conn, surface: w.surface, x: r.left, y: r.top, bound: wl.engine.touchBound(w.conn) };
        })()`);
      }
      if (!f) fail("weston-flower's window never appeared");
      await sleep(300); // (its wl_touch, if it takes one, comes with its seat: before the map)
      f.bound = await evalJs(`window.wland.engine.touchBound(${f.conn})`);
      if (f.bound) console.log("the pointer emulation: skipped (this weston-flower binds wl_touch)");
      else {
        await seen();
        await touch("touchStart", [{ x: f.x + 100, y: f.y + 100, id: 0 }]);
        await path(0, [f.x + 100, f.y + 100], [f.x - 20, f.y + 100], 4);
        await touch("touchEnd", []);
        for (let i = 0; i < 30 && !pointerEvents(flog).some((e) => e.name === "leave"); i++) await sleep(100);
        const evs = pointerEvents(flog).filter((e) => e.name !== "axis");
        const names = evs.map((e) => e.name === "button" ? `button ${e.args[3]}` : e.name);
        const order = names.filter((n, i) => n !== names[i - 1]).join();
        const out = evs.filter((e) => e.name === "motion").at(-1);
        if (order !== "enter,button 1,motion,button 0,leave") fail(`the finger as the pointer: ${names.join(", ")}`);
        if (!out || Math.abs(+out.args[1]! + 20) > 1) fail(`the implicit grab did not keep the finger's pointer (last motion ${out?.args})`);
        const calls = await seen();
        if (calls.some((c) => c.startsWith("touch"))) fail(`the finger also went the touch path: ${calls}`);
        console.log(`no wl_touch: the finger is the pointer — ${order}; dragged out, x ${out.args[1]}`);
      }
      console.log("touch ok: fingers are wl_touch points (tap, drag out, two fingers, move by finger, cancel on a pan), the pointer for a client without wl_touch");
    } finally {
      app.kill();
      flower?.kill();
      await evalJs(`(() => { const e = window.wland.engine; for (const n of ['touchDown', 'touchMotion', 'touchUp', 'touchCancel', 'pointerEnter', 'pointerButton', 'pointerMotion', 'pointerLeave']) if (e['_' + n]) e[n] = e['_' + n]; })()`);
    }
  },

  // A hole in an input region INSIDE the window geometry passes the pointer
  // to what is behind: the window element takes none (canvases and hit
  // elements say auto). A second term maps over the first, is Alt+dragged
  // until its right edge sticks out (the box captures the pointer although
  // it is pointer-events: none), and gets a border-only region (fed to the
  // view as the core sends it: no installed app sets a holed one); a click
  // in its middle focuses and raises the term behind, one on its border
  // takes it back; fullscreen, the hole lands on the black backdrop, never
  // on the window behind.
  async hole() {
    await waitMain();
    const before: string[] = await evalJs("window.wland.view.windows().map((w) => w.key)");
    const top = spawnApp("term");
    const st = (): Promise<any> => evalJs(`(() => {
      window.scrollTo(0, 0);
      const wl = window.wland, vws = wl.view.windows(), es = wl.windows();
      const i = vws.findIndex((w) => !${JSON.stringify(before)}.includes(w.key));
      const j = vws.findIndex((w) => w.key === ${JSON.stringify(before[0] ?? "")});
      if (i < 0 || j < 0) return null;
      const t = vws[i], b = vws[j], c = wl.view.canvas(t.conn, t.surface), r = c.getBoundingClientRect();
      const backRight = Math.max(...[...b.element.querySelectorAll('canvas')].filter((c) => c.style.display !== 'none')
        .map((c) => c.getBoundingClientRect().right));
      return { key: t.key, conn: t.conn, surface: t.surface, x: r.left, y: r.top, w: parseFloat(c.style.width), h: parseFloat(c.style.height),
        left: t.element.offsetLeft, topZ: Number(t.element.style.zIndex), backZ: Number(b.element.style.zIndex),
        topFocused: es[i].focused, backFocused: es[j].focused, fs: es[i].fullscreen, back: [b.conn, b.surface], backRight };
    })()`);
    const until = async (ok: (s: any) => boolean, what: string) => {
      let s = await st();
      for (let i = 0; i < 50 && !(s && ok(s)); i++) { await sleep(200); s = await st(); }
      if (!(s && ok(s))) fail(`${what}: ${JSON.stringify(s)}`);
      return s;
    };
    // what the browser's hit-test finds at a point: [conn, root], or the element
    const at = (x: number, y: number): Promise<any> => evalJs(`(() => {
      const e = document.elementFromPoint(${x}, ${y}), s = window.wland.view.surfaceOf(e);
      return s ? [s.conn, s.root] : e ? (e.dataset.wlandWindow || e.id || e.tagName) : null;
    })()`);
    const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
    try {
      if (!before.length) fail("no window to hide behind (foot's, from run-poc)");
      const s0 = await until((s) => s.w > 100 && s.h > 100 && s.topFocused, "the second term mapped on top, focused");
      const B = 12, { w, h } = s0;

      // Alt+drag it right until its right border is clear of the term behind
      const shift = Math.max(60, Math.ceil(s0.backRight - (s0.x + w) + B + 20));
      const ax = s0.x + 40, ay = s0.y + h / 2;
      await mouse("mouseMoved", ax, ay);
      await mouse("mousePressed", ax, ay, { button: "left", buttons: 1, clickCount: 1, modifiers: 1 });
      await evalJs(`window.__moves = []; document.addEventListener('pointermove', window.__movesFn = (e) =>
        window.__moves.push(e.target.dataset && e.target.dataset.wlandWindow || e.target.tagName), true)`);
      for (let i = 1; i <= 8; i++) {
        await mouse("mouseMoved", ax + (shift * i) / 8, ay, { button: "left", buttons: 1, modifiers: 1 });
        await sleep(30);
      }
      await mouse("mouseReleased", ax + shift, ay, { button: "left", buttons: 0, clickCount: 1, modifiers: 1 });
      const moves: string[] = await evalJs(`(() => {
        document.removeEventListener('pointermove', window.__movesFn, true);
        return window.__moves;
      })()`);
      const s1 = await until((s) => Math.abs(s.left - (s0.left + shift)) <= 1, `Alt+drag moves the window ${shift} px`);
      console.log(`Alt+drag: box ${s0.left} → ${s1.left}; motion targets ${JSON.stringify([...new Set(moves)])}`);
      if (!moves.length || moves.some((m) => m !== s0.key)) fail("the Alt+drag's motion did not go to the captured window box");

      // a border-only region
      await evalJs(`window.wland.view.handle({ type: 'input-region', conn: ${s0.conn}, surface: ${s0.surface},
        region: new Int32Array([0, 0, ${w}, ${B}, 0, ${h - B}, ${w}, ${B}, 0, ${B}, ${B}, ${h - 2 * B}, ${w - B}, ${B}, ${B}, ${h - 2 * B}]) })`);
      const cx = s1.x + w / 2, cy = s1.y + h / 2, bx = s1.x + w - B / 2;
      if (!(cx < s1.backRight - 10 && bx > s1.backRight)) fail(`layout: hole ${cx}, border ${bx}, the term behind ends at ${s1.backRight}`);
      const hole = await at(cx, cy), border = await at(bx, cy);
      console.log(`hit-test: hole ${JSON.stringify(hole)}, border ${JSON.stringify(border)} (behind: ${JSON.stringify(s1.back)})`);
      if (!same(hole, s1.back)) fail("the hole does not show the window behind to the hit-test");
      if (!same(border, [s0.conn, s0.surface])) fail("the border lost the pointer");

      await click(cx, cy, 100);
      await until((s) => s.backFocused && !s.topFocused && s.backZ > s.topZ, "a click in the hole: the window behind focused and raised");
      console.log("click in the hole: the window behind is focused and raised");
      await click(bx, cy, 100);
      await until((s) => s.topFocused && s.topZ > s.backZ, "a click on the border: the holed window focused and raised");
      console.log("click on the border: the holed window takes it back");

      // fullscreen: the black backdrop covers what is below, the hole too
      await evalJs(`window.wland.wm.setFullscreen(${s0.conn}, ${s0.surface}, true)`);
      await until((s) => s.fs, "fullscreen");
      await sleep(500);
      const fsHit = await at(cx, cy);
      console.log(`fullscreen hit-test in the hole: ${JSON.stringify(fsHit)}`);
      if (fsHit !== s0.key) fail("the fullscreen backdrop lets the pointer through to what is below");
      await evalJs(`window.wland.wm.setFullscreen(${s0.conn}, ${s0.surface}, false)`);
      await until((s) => !s.fs, "out of fullscreen");
      console.log("hole ok: a hole in the region passes clicks to the window behind; the border, Alt+drag and the fullscreen backdrop keep theirs");
    } finally {
      top.kill();
      await sleep(300);
    }
  },

  // M7.3: drag the app's OWN resize border (xdg_toplevel.resize → wm grab);
  // the app must re-render larger. Where the band is depends on the app:
  // foot's CSD border subsurfaces sit just OUTSIDE the window box, GTK's
  // band just INSIDE its edge — so offsets around the bottom-right corner
  // are tried until one produces growth.
  async resize() {
    await waitMain();
    await sleep(800);
    const before = (await sample())!;
    console.log(`before: ${before.w}x${before.h} colored=${before.colored}`);
    const corner = await evalJs(`(() => {
      const c = ${MAIN};
      if (!c) return null;
      const r = c.closest('.wland-window').getBoundingClientRect();
      return { right: r.right, bottom: r.bottom };
    })()`) ?? fail("no window box found");
    if (corner.bottom < 0 || corner.bottom > 1100 || corner.right < 0 || corner.right > 1600) {
      fail(`corner off-viewport at ${corner.right},${corner.bottom}`);
    }
    const DX = 140, DY = 90;
    const OFFSETS = [[2, 2], [-3, -3], [-8, -8], [-14, -14]] as const;
    // a quick click on the border first: the app asks for the resize after
    // the release, and nothing may follow the pointer then (a grab started
    // anyway kept resizing until the next click)
    const boxNow = (): Promise<string> => evalJs(`(() => {
      const r = ${MAIN}.closest('.wland-window').getBoundingClientRect();
      return [r.left, r.top, r.width, r.height].join();
    })()`);
    const box0 = await boxNow();
    for (const [ox, oy] of OFFSETS) {
      const sx = corner.right + ox, sy = corner.bottom + oy;
      await click(sx, sy, 100);
      await sleep(300);
      await mouse("mouseMoved", sx + DX, sy + DY, { buttons: 0 });
      await sleep(300);
      await mouse("mouseMoved", sx + DX + 20, sy + DY + 10, { buttons: 0 });
      await sleep(500);
      const box1 = await boxNow();
      if (box1 !== box0) fail(`a quick click at the border (${ox},${oy}) moved or resized the window: ${box0} → ${box1}`);
    }
    console.log(`quick clicks on the border: the window stays ${box0}`);
    let after = before;
    const grew = () => after.w > before.w + 40;
    for (const [ox, oy] of OFFSETS) {
      const sx = corner.right + ox, sy = corner.bottom + oy;
      await mouse("mouseMoved", sx, sy);
      await sleep(100);
      await drag([sx, sy], [sx + DX, sy + DY], 7, 60);
      // the app re-renders asynchronously; poll for the canvas to grow
      for (let i = 0; i < 20 && !grew(); i++) {
        await sleep(200);
        after = (await sample()) ?? after;
      }
      if (grew()) break;
      console.log(`corner offset (${ox},${oy}) did not resize; trying next`);
    }
    console.log(`after:  ${after.w}x${after.h} colored=${after.colored}`);
    // terminals snap to the cell grid, so exact-match is wrong; require real growth
    if (!grew()) fail("canvas width did not grow after grip drag");
    if (after.colored < 100) fail("resized canvas looks blank");
    console.log(`resize ok: ${before.w}x${before.h} → ${after.w}x${after.h}, content rendered`);
  },

  // M6: nautilus renders, the hamburger menu opens (xdg_popup), an outside
  // click dismisses it (popup_done → unmap), double-clicking the folder
  // navigates (title change)
  async gtk() {
    const mainKey = await waitWide(900);
    const title0 = await evalJs("document.title");
    console.log(`nautilus canvas: ${mainKey}, title: ${title0}`);
    await sleep(1500);
    const origin = async (): Promise<{ l: number; t: number }> => evalJs(`(() => {
      window.scrollTo(0, 0);
      const r = document.querySelector('[data-wland="${mainKey}"]').getBoundingClientRect();
      return { l: r.left, t: r.top };
    })()`);
    const popupVisible = (): Promise<boolean> => evalJs(
      `[...document.querySelectorAll('#desktop canvas')].some(c => wland.view.surfaceOf(c)?.role === 4 && c.style.display !== 'none')`);
    const plainClick = async (x: number, y: number) => {
      await mouse("mouseMoved", x, y);
      await mouse("mousePressed", x, y, { button: "left", clickCount: 1 });
      await mouse("mouseReleased", x, y, { button: "left", clickCount: 1 });
    };

    // GTK's input region (frame + resize margin) is applied: the canvas is
    // inert, its hit element takes the pointer; the outer shadow falls
    // through to what is below, the margin just outside the frame does not
    const region = await evalJs(`(() => {
      window.scrollTo(0, 0);
      const c = document.querySelector('[data-wland="${mainKey}"]');
      const hit = document.querySelector('[data-wland-hit="${mainKey}"]');
      const r = c.getBoundingClientRect(), box = c.closest('.wland-window').getBoundingClientRect();
      const mine = (x, y) => { const e = document.elementFromPoint(x, y); return e === hit || e === c; };
      return { hit: !!hit, inert: c.style.pointerEvents === 'none', shadow: mine(r.left + 2, r.top + 2),
               margin: mine(box.left - 2, box.top + 100), inside: mine(box.left + 100, box.top + 100) };
    })()`);
    console.log(`input region: ${JSON.stringify(region)}`);
    if (!region.hit || !region.inert || region.shadow || !region.margin || !region.inside) fail("nautilus's input region is not applied");

    const popupRect = (): Promise<{ l: number; t: number; w: number; h: number } | null> => evalJs(`(() => {
      const c = [...document.querySelectorAll('#desktop canvas')].find(c => wland.view.surfaceOf(c)?.role === 4 && c.style.display !== 'none');
      if (!c) return null;
      const r = c.getBoundingClientRect();
      return { l: r.left, t: r.top, w: r.width, h: r.height };
    })()`);
    let cr = await origin();
    await plainClick(cr.l + 184, cr.t + 48);
    await sleep(1500);
    if (!(await popupVisible())) fail("hamburger menu popup did not open");
    // below the button: positioners count from the window geometry, inside
    // the shadow (GTK4's popover has a wide shadow: its surface may start a
    // little above the button's bottom)
    const pr = (await popupRect())!;
    if (!(pr.l <= cr.l + 184 && pr.l + pr.w > cr.l + 184 && pr.t > cr.t + 8 && pr.t < cr.t + 72 && pr.t + pr.h > cr.t + 72)) {
      fail(`the menu is not below its button: surface at ${pr.l - cr.l},${pr.t - cr.t} of the window's`);
    }
    console.log(`menu popup opened below its button (surface at ${pr.l - cr.l},${pr.t - cr.t})`);

    cr = await origin();
    await plainClick(cr.l + 500, cr.t + 450);
    await sleep(1500);
    if (await popupVisible()) fail("popup did not dismiss on outside click");
    console.log("menu popup dismissed");

    if (!realApps) {
      // the fixture's right-click menu (l3afpad's shape): anchored at the
      // pointer in window-geometry px, its frame 6 px inside its shadow —
      // the frame's corner lands just past the pointer
      cr = await origin();
      const rx = Math.round(cr.l + 600), ry = Math.round(cr.t + 400);
      await mouse("mouseMoved", rx, ry);
      await mouse("mousePressed", rx, ry, { button: "right", buttons: 2, clickCount: 1 });
      await mouse("mouseReleased", rx, ry, { button: "right", buttons: 0, clickCount: 1 });
      await sleep(1500);
      const q = await popupRect();
      if (!q) fail("the right-click menu did not open");
      const qx = q.l + 6, qy = q.t + 6;
      if (Math.abs(qx - (rx + 1)) > 0.5 || Math.abs(qy - (ry + 1)) > 0.5) fail(`right-click at ${rx},${ry}: the menu's corner at ${qx},${qy}`);
      console.log(`right-click menu at the pointer: corner ${qx},${qy} for a click at ${rx},${ry}`);
      await plainClick(qx + 100, qy + 8 + 36 + 18); // an item: the fixture closes it
      await sleep(1000);
      if (await popupVisible()) fail("a click on a menu item left the menu open");
    }

    // a menu at the desktop's right edge: wland's window manager tells the
    // core where the window is (here: after an Alt+drag moved it there), so
    // the menu is constrained back inside the output instead of running off
    {
      const desk = await evalJs(`(() => { const r = document.getElementById('desktop').getBoundingClientRect(); return { l: r.left, t: r.top, r: r.right, b: r.bottom }; })()`);
      const box = async () => evalJs(`(() => {
        window.scrollTo(0, 0);
        const r = document.querySelector('[data-wland="${mainKey}"]').closest('.wland-window').getBoundingClientRect();
        return { l: r.left, t: r.top, r: r.right, b: r.bottom };
      })()`);
      const altDrag = async (from: [number, number], dx: number, dy: number) => {
        await mouse("mouseMoved", from[0], from[1]);
        await mouse("mousePressed", from[0], from[1], { button: "left", buttons: 1, clickCount: 1, modifiers: 1 });
        for (let i = 1; i <= 8; i++) {
          await mouse("mouseMoved", from[0] + (dx * i) / 8, from[1] + (dy * i) / 8, { button: "left", buttons: 1, modifiers: 1 });
          await sleep(30);
        }
        await mouse("mouseReleased", from[0] + dx, from[1] + dy, { button: "left", buttons: 0, clickCount: 1, modifiers: 1 });
        await sleep(300);
      };
      const b0 = await box();
      // its box's left 450 px from the desktop's right edge (the window
      // hangs past it); a right-click 120 px from that edge
      const dx = Math.round(desk.r - 450 - b0.l);
      const grip: [number, number] = [Math.round(b0.l + 400), Math.round(b0.t + 300)];
      await altDrag(grip, dx, 0);
      const b1 = await box();
      if (Math.abs(b1.l - (b0.l + dx)) > 1) fail(`Alt+drag did not move the window: ${b0.l} → ${b1.l}`);
      const rx = Math.round(desk.r - 120), ry = Math.round(b1.t + 300);
      await mouse("mouseMoved", rx, ry);
      await mouse("mousePressed", rx, ry, { button: "right", buttons: 2, clickCount: 1 });
      await mouse("mouseReleased", rx, ry, { button: "right", buttons: 0, clickCount: 1 });
      let q = null;
      for (let i = 0; i < 25 && !q; i++) { await sleep(200); q = await popupRect(); }
      if (!q) fail("the right-click menu near the desktop's edge did not open");
      await sleep(500);
      q = (await popupRect())!;
      // (a menu's shadow may hang past its geometry: 30 px of slack)
      console.log(`menu near the edge: surface ${q.l},${q.t} ${q.w}x${q.h}, desktop right ${desk.r}, click at ${rx}`);
      if (q.l + q.w > desk.r + 30 || q.l >= rx) fail(`the menu runs off the desktop: its surface spans ${q.l}..${q.l + q.w}, the desktop ends at ${desk.r}`);
      if (!realApps && Math.abs(q.l + 6 + 200 - desk.r) > 1) fail(`the fixture's menu did not slide flush with the edge: geometry right ${q.l + 6 + 200}`);
      await plainClick(Math.round(b1.l + 200), Math.round(b1.t + 300)); // dismiss it
      await sleep(1000);
      if (await popupVisible()) fail("the edge menu did not dismiss");
      await altDrag([Math.round(b1.l + 400), Math.round(b1.t + 300)], -dx, 0); // back where it was
      console.log("edge menu ok: constrained inside the desktop after the window was moved to its edge");
    }

    // the first icon, ~(307,145) in nautilus's default view (run-poc opens
    // a fixture directory whose only entry is a folder)
    cr = await origin();
    const fx = cr.l + 307, fy = cr.t + 145;
    await mouse("mouseMoved", fx, fy);
    for (const n of [1, 2]) {
      await mouse("mousePressed", fx, fy, { button: "left", clickCount: n });
      await mouse("mouseReleased", fx, fy, { button: "left", clickCount: n });
    }
    let title1 = title0;
    for (let i = 0; i < 25 && title1 === title0; i++) {
      await sleep(200);
      title1 = await evalJs("document.title");
    }
    console.log(`title after double-click: ${title1}`);
    if (title1 === title0) fail("double-click did not navigate");
    console.log("gtk ok: nautilus renders, menu opens+dismisses, navigation works");
  },

  // drag and drop through the browser, within one client: the `files`
  // fixture's second icon (file.txt) dragged onto its first (the folder).
  // CDP's drag is the user's; the press starts the app's start_drag, the wm
  // carries it (enter/motion/drop over the same surface) and the app retitles
  // itself once the drop's data arrived. (Real nautilus: tools/dnd-test.sh.)
  async dnd() {
    const mainKey = await waitWide(900);
    await sleep(500);
    const r = await evalJs(`(() => {
      window.scrollTo(0, 0);
      const r = document.querySelector('[data-wland="${mainKey}"]').getBoundingClientRect();
      return { l: r.left, t: r.top };
    })()`);
    const from: [number, number] = [r.l + 427, r.t + 145], to: [number, number] = [r.l + 307, r.t + 145];
    await mouse("mouseMoved", from[0], from[1]);
    await sleep(100);
    await drag(from, to, 12, 50, 0);
    let title = "";
    // (the page titles itself "<focused window's title> — wland")
    for (let i = 0; i < 25 && !title.startsWith("moved file.txt"); i++) {
      await sleep(200);
      title = await evalJs("document.title");
    }
    if (!title.startsWith("moved file.txt")) fail(`the drop never arrived (title "${title}")`);
    console.log("dnd ok: file.txt dragged onto the folder through the browser");
  },

  async pagednd() {
    const dir = mkdtempSync(`${tmpdir()}/wland-pagednd.`);
    mkdirSync(`${dir}/folder`);
    let out = "";
    const spawnFiles = () => {
      const a = appFor("files", [dir]);
      const p = Bun.spawn([a.cmd, ...a.args], { stdout: "pipe", stderr: "ignore", env: { ...process.env, ...a.env } });
      (async () => { for await (const c of p.stdout) out += new TextDecoder().decode(c); })();
      return p;
    };
    let app = spawnFiles();
    // every engine call the bridge makes (dragBegin with its types and
    // actions, dragDrop with `later`, dragData with its types), and the
    // dropEffect it answers
    const instrument = () => evalJs(`(() => {
      const e = window.wland.engine;
      window.dndSeen = [];
      const show = { dragBegin: (m, a) => ':' + m.join('|') + ':' + a, dragDrop: (l) => l ? ':true' : '', dragData: (d) => ':' + Object.keys(d || {}).join('|') };
      for (const n of ['dragBegin', 'dragData', 'dragDrop', 'dragCancel']) {
        e['_' + n] = e[n];
        e[n] = (...a) => { window.dndSeen.push(n + (show[n] ? show[n](...a) : '')); return e['_' + n](...a); };
      }
      window.dndEffects = [];
      document.addEventListener('dragover', (ev) => window.dndEffects.push(ev.dataTransfer.dropEffect));
    })()`);
    const dragEvent = (type: string, x: number, y: number, data: unknown) => call("Input.dispatchDragEvent", { type, x, y, data });
    const TEXT_TYPES = "text/plain;charset=utf-8|UTF8_STRING|text/plain|TEXT|STRING";
    try {
      const mainKey = await waitWide(900);
      await sleep(500);
      const r = await evalJs(`(() => {
        window.scrollTo(0, 0);
        const r = document.querySelector('[data-wland="${mainKey}"]').getBoundingClientRect();
        return { l: r.left, t: r.top };
      })()`);
      await instrument();
      const uri = "https://example.org/dragged-into-wland";
      // copy | move (DragOperation bits: Copy 1, Link 2, Move 16)
      const link = { items: [{ mimeType: "text/uri-list", data: uri }, { mimeType: "text/plain", data: uri }], dragOperationsMask: 1 | 16 };
      const folder: [number, number] = [r.l + 307, r.t + 145], start: [number, number] = [r.l + 427, r.t + 145];
      await dragEvent("dragEnter", start[0], start[1], link);
      for (let i = 1; i <= 10; i++) {
        await dragEvent("dragOver", start[0] + ((folder[0] - start[0]) * i) / 10, folder[1], link);
        await sleep(50);
      }
      for (let i = 0; i < 40 && !(await evalJs("window.wland.engine.dragAction()")); i++) {
        await dragEvent("dragOver", folder[0], folder[1], link);
        await sleep(50);
      }
      await dragEvent("dragOver", folder[0], folder[1], link); // answered with the app's action now
      // the fixture accepts at its enter and prefers move (set_actions(copy |
      // move, move)): none until its answer arrived (it may beat the first
      // dragover), move after
      const effects: string[] = await evalJs("window.dndEffects");
      if (effects.some((e) => e !== "none" && e !== "move")) fail(`dropEffects: ${effects.join()}`);
      if (effects.at(-1) !== "move") fail(`the dropEffect once the app accepted: ${effects.at(-1)} (${effects.join()})`);
      await dragEvent("drop", folder[0], folder[1], link);
      for (let i = 0; i < 50 && !/DROPPED (\S+) ON folder/.test(out); i++) await sleep(100);
      const got = /DROPPED (\S+) ON folder/.exec(out)?.[1];
      if (got !== uri) fail(`the app read ${got ?? "nothing"} (stdout: ${out.trim()}; engine calls ${await evalJs("window.dndSeen.join()")})`);
      const seen: string[] = await evalJs("window.dndSeen");
      // (the types in the browser's order: Chromium lists text/plain first)
      const want = [...TEXT_TYPES.split("|"), "text/uri-list"].sort().join("|");
      const typesOf = (call: string) => call.split(":").slice(1, -1).join(":").split("|").sort().join("|");
      if (seen.length !== 3 || !seen[0].startsWith("dragBegin:") || !seen[0].endsWith(":3") || typesOf(seen[0]) !== want ||
          !seen[1].startsWith("dragData:") || [...seen[1].slice(9).split("|")].sort().join("|") !== want || seen[2] !== "dragDrop") {
        fail(`engine calls: ${seen.join()}`);
      }
      console.log(`pagednd ok: a link dragged in from outside (dropEffect ${effects[0]} → ${effects.at(-1)}) dropped onto the folder: ${got}`);

      // a file, no files hook (the default page): offered as its content
      // under its type (Chromium names a .txt text/plain), the drop made at
      // once and its bytes after; the page stays where it was
      writeFileSync(`${dir}/dropped.txt`, "dropped from the page\n");
      const href: string = await evalJs("location.href");
      const files = { items: [], files: [`${dir}/dropped.txt`], dragOperationsMask: 1 | 16 };
      await evalJs("window.dndSeen = []");
      const fileDrag = async () => {
        await dragEvent("dragEnter", folder[0], folder[1], files);
        for (let i = 0; i < 40 && !(await evalJs("window.wland.engine.dragAction()")); i++) {
          await dragEvent("dragOver", folder[0], folder[1], files);
          await sleep(50);
        }
        await dragEvent("dragOver", folder[0], folder[1], files);
        await dragEvent("drop", folder[0], folder[1], files);
      };
      await fileDrag();
      for (let i = 0; i < 25 && !(await evalJs("window.dndSeen.includes('dragData')")); i++) await sleep(100);
      const fileSeen: string[] = await evalJs("window.dndSeen");
      if (fileSeen.join() !== "dragBegin:text/plain:1,dragDrop:true,dragData:text/plain") fail(`a dropped file without a hook: engine calls ${fileSeen.join()}`);
      if ((await evalJs("location.href")) !== href) fail("a dropped file navigated the page");
      console.log("pagednd ok: a dropped file without a hook is its content (text/plain, copy only), handed over after the drop; the page stays");

      // ?dndfiles=1: the page's hook places dropped files; the app reads
      // their URIs (a reload drops the app: spawned again)
      app.kill();
      await call("Page.enable");
      await call("Page.navigate", { url: `${await evalJs("location.origin")}/?dndfiles=1` });
      await sleep(1000);
      await waitOnline();
      app = spawnFiles();
      const key2 = await waitWide(900);
      await sleep(500);
      const r2 = await evalJs(`(() => {
        window.scrollTo(0, 0);
        const r = document.querySelector('[data-wland="${key2}"]').getBoundingClientRect();
        return { l: r.left, t: r.top };
      })()`);
      folder[0] = r2.l + 307;
      folder[1] = r2.t + 145;
      await instrument();
      const before = out.length;
      await fileDrag();
      for (let i = 0; i < 50 && !/DROPPED (\S+) ON folder/.test(out.slice(before)); i++) await sleep(100);
      const hooked = /DROPPED (\S+) ON folder/.exec(out.slice(before))?.[1];
      if (hooked !== "file:///hooked/dropped.txt") fail(`with the hook the app read ${hooked ?? "nothing"} (engine calls ${await evalJs("window.dndSeen.join()")})`);
      if ((await evalJs("window.wlandDropped.join()")) !== "dropped.txt") fail(`the hook was handed ${await evalJs("window.wlandDropped.join()")}`);
      console.log(`pagednd ok: with the page's files hook a dropped file reaches the app as its URI: ${hooked}`);
    } finally {
      app.kill();
      // back to the default page for the groups after this one
      await call("Page.navigate", { url: `${await evalJs("location.origin")}/` }).catch(() => {});
      rmSync(dir, { recursive: true, force: true });
    }
  },

  // CSD window management: dragging nautilus's headerbar MOVES the window
  // (xdg_toplevel.move → wm grab), its maximize button fills the desktop
  // (box snapped to 0,0) and its restore button brings back the floating
  // position
  async csd() {
    const mainKey = await waitWide(900);
    const state = async (): Promise<any> => evalJs(`(() => {
      const c = document.querySelector('[data-wland="${mainKey}"]');
      const box = c.closest('.wland-window');
      const r = c.getBoundingClientRect();
      const desk = document.getElementById('desktop');
      return { boxL: box.offsetLeft, boxT: box.offsetTop,
               cssW: parseFloat(c.style.width), cssH: parseFloat(c.style.height),
               canvasL: r.left, canvasT: r.top, deskW: desk.clientWidth, deskH: desk.clientHeight };
    })()`);
    const until = async (ok: (s: any) => boolean) => {
      let s = await state();
      for (let i = 0; i < 50 && !ok(s); i++) {
        await sleep(200);
        s = await state();
      }
      return s;
    };
    const floating = (s: any) => s.cssW < s.deskW - 100;

    // nautilus persists its maximized state — if it started maximized, click
    // the restore button first so the stages below start from floating
    let s0 = await state();
    if (Math.abs(s0.cssW - s0.deskW) <= 2) {
      console.log("started maximized (saved state) — restoring first");
      await click(s0.canvasL + s0.cssW - 60, s0.canvasT + 22, 150);
      s0 = await until(floating);
      if (!floating(s0)) fail("could not restore startup-maximized window");
    }

    // 1. headerbar drag. (700, 45) from the canvas corner is empty headerbar
    // background: clear of GTK's top RESIZE band (~24px, which sends
    // xdg_toplevel.resize edges=top instead) and left of the buttons. A
    // small vertical move: the resize phase that follows needs the window's
    // bottom-right corner to stay inside the desktop.
    s0 = await state();
    const hx = s0.canvasL + 700, hy = s0.canvasT + 45;
    await mouse("mouseMoved", hx, hy);
    await sleep(100);
    await drag([hx, hy], [hx + 160, hy + 40], 8, 60);
    await sleep(500);
    const s1 = await state();
    console.log(`headerbar drag: box (${s0.boxL},${s0.boxT}) → (${s1.boxL},${s1.boxT})`);
    // GTK's drag threshold eats the first ~20px before xdg_toplevel.move arrives
    if (s1.boxL - s0.boxL < 100 || s1.boxT - s0.boxT < 25) fail("headerbar drag did not move the window (xdg_toplevel.move path)");

    // 2. the window's own maximize button: floating layout, center ≈ (w-86, 48)
    await click(s1.canvasL + s1.cssW - 86, s1.canvasT + 48, 150);
    const maxed = (s: any) => s.boxL === 0 && s.boxT === 0 && Math.abs(s.cssW - s.deskW) <= 2;
    const s2 = await until(maxed);
    console.log(`maximized: box (${s2.boxL},${s2.boxT}), ${s2.cssW}x${s2.cssH}, desktop ${s2.deskW}x${s2.deskH}`);
    if (!(maxed(s2) && Math.abs(s2.cssH - s2.deskH) <= 2)) fail("maximize button did not maximize to the desktop");

    // 3. the restore button (the maximized layout loses ~25px of window
    // border padding: its center shifts to (w-60, 22))
    await click(s2.canvasL + s2.cssW - 60, s2.canvasT + 22, 150);
    const s3 = await until(floating);
    console.log(`restored: box (${s3.boxL},${s3.boxT}), ${s3.cssW}x${s3.cssH}`);
    // GTK may pick its own floating size when unmaximizing (it saw no floating
    // configure it considers "user-sized"); assert floating + our exact position
    if (!floating(s3)) fail("restore button did not unmaximize");
    if (Math.abs(s3.boxL - s1.boxL) > 2 || Math.abs(s3.boxT - s1.boxT) > 2) {
      fail(`restore position mismatch: (${s3.boxL},${s3.boxT}) != (${s1.boxL},${s1.boxT})`);
    }
    console.log("csd ok: headerbar move, maximize button, restore button");
  },

  // Retina: at devicePixelRatio 2 apps attach 2x buffers and the page shows
  // them at buffer/2 CSS px (1:1 device pixels). Emulates dpr 2, reloads,
  // spawns foot itself (the app must connect AFTER the dpr-2 page owns the
  // session) and restores dpr 1 at the end.
  // Window states in a real browser, with createWland's browserFullscreen
  // (the page reloaded with ?browserfs=1, foot spawned here): Alt+F11 makes
  // foot fill the desktop (the box at 0,0, data-wland-fullscreen, foot
  // re-rendered to the size) and puts #desktop in the browser's fullscreen;
  // the browser leaving it (exitFullscreen: CDP's Escape doesn't reach the
  // browser's own handler) takes foot out too, back where it was; Alt+F9
  // hides it, the window list's raise() restores it, focused. The page is
  // reloaded without the option at the end.
  async states() {
    await call("Page.enable");
    const base = await evalJs("location.origin");
    await call("Page.navigate", { url: `${base}/?browserfs=1` });
    await sleep(1000);
    await waitOnline();
    const foot = spawnApp("term");
    const st = (): Promise<any> => evalJs(`(() => {
      window.scrollTo(0, 0);
      const w = window.wland.windows()[0];
      const vw = w && window.wland.view.windows()[0];
      if (!vw) return null;
      const el = vw.element, desk = document.getElementById('desktop');
      const r = el.getBoundingClientRect(), d = desk.getBoundingClientRect();
      const cs = [...el.querySelectorAll('canvas')].filter((c) => c.style.display !== 'none');
      const main = cs.reduce((a, b) => (a.width * a.height >= b.width * b.height ? a : b), cs[0]);
      return { fs: w.fullscreen, min: w.minimized, focused: w.focused, attr: 'wlandFullscreen' in el.dataset,
        display: el.style.display, left: el.offsetLeft, top: el.offsetTop, x: r.left, y: r.top, w: r.width, h: r.height,
        deskW: d.width, deskH: d.height, mainW: main ? parseFloat(main.style.width) : 0,
        browserFs: document.fullscreenElement === desk };
    })()`);
    const until = async (ok: (s: any) => boolean, what: string) => {
      let s = await st();
      for (let i = 0; i < 50 && !(s && ok(s)); i++) { await sleep(200); s = await st(); }
      if (!(s && ok(s))) { foot.kill(); fail(`${what}: ${JSON.stringify(s)}`); }
      return s;
    };
    const altKey = async (k: string, vk: number) => {
      await call("Input.dispatchKeyEvent", { type: "rawKeyDown", key: k, code: k, windowsVirtualKeyCode: vk, modifiers: 1 });
      await call("Input.dispatchKeyEvent", { type: "keyUp", key: k, code: k, windowsVirtualKeyCode: vk, modifiers: 1 });
    };
    try {
      const s0 = await until((s) => s.mainW > 100 && s.focused, "foot's window, focused");
      // a press in it: focus, and the page's user activation
      await click(s0.x + 60, s0.y + 80, 100);
      await altKey("F11", 122);
      const s1 = await until((s) => s.fs && s.browserFs && Math.abs(s.mainW - s.deskW) < 20, "Alt+F11: fullscreen, browser fullscreen, foot re-rendered");
      if (!(s1.attr && s1.left === 0 && s1.top === 0 && Math.abs(s1.w - s1.deskW) < 1 && Math.abs(s1.h - s1.deskH) < 1)) {
        fail(`the window does not fill the desktop: ${JSON.stringify(s1)}`);
      }
      console.log(`fullscreen: box ${s1.w}x${s1.h} at ${s1.left},${s1.top}, foot ${s1.mainW} wide, desktop ${s1.deskW}x${s1.deskH} (browser fullscreen)`);
      // the browser leaves its fullscreen: foot leaves its own, back in place
      await evalJs("document.exitFullscreen()");
      const s2 = await until((s) => !s.fs && !s.browserFs && Math.abs(s.mainW - s0.mainW) < 20, "out of the browser's fullscreen: foot back");
      if (s2.left !== s0.left || s2.top !== s0.top || s2.attr) fail(`not back in place: ${JSON.stringify(s2)} (was ${JSON.stringify(s0)})`);
      console.log(`browser fullscreen left: foot back to ${s2.mainW} wide at ${s2.left},${s2.top}`);
      // Alt+F11 twice: in and out, the browser's fullscreen with it
      await altKey("F11", 122);
      await until((s) => s.fs && s.browserFs, "Alt+F11 again");
      await altKey("F11", 122);
      await until((s) => !s.fs && !s.browserFs && !s.attr, "Alt+F11 out: the page leaves the browser's fullscreen too");
      // minimize, restore
      await altKey("F9", 120);
      await until((s) => s.min && s.display === "none" && !s.focused, "Alt+F9: hidden, unfocused");
      await sleep(300);
      await evalJs("window.wland.windows()[0].raise()");
      const s3 = await until((s) => !s.min && s.display === "" && s.focused, "raise(): restored and focused");
      if (s3.left !== s0.left || s3.top !== s0.top) fail(`restored elsewhere: ${JSON.stringify(s3)}`);
      console.log("states ok: Alt+F11 with the browser's fullscreen, its exit ends foot's, Alt+F9 hides, raise() restores");
    } finally {
      foot.kill();
      await call("Page.navigate", { url: `${base}/` });
      await sleep(1000);
      await waitOnline();
    }
  },

  // The embedder's window manager owning interaction and focus (each mode a
  // page reload with its query, term fixtures spawned here, killed after):
  //  default      a grab of wland's own (the term's titlebar → move) ended
  //               by a window blur mid-drag, then a second drag works
  //  ?embedder=1  the page's `interactive` takes a move (titlebar), a resize
  //               (border) and an Alt+drag, each with the press it came
  //               from: wland starts no grab (left/top and size stay, no
  //               requestResize), the page's input.grab holds the app off
  //               the pointer; a window blur mid-drag ends that grab, the
  //               next drag is taken again
  //  ?altdrag=0   an Alt+press goes to the app, the window stays; Alt+F10
  //               still maximizes
  //  ?autofocus=0 no window focused at map or press; input.focus() gives it
  //               (keys reach the app); the focused app going leaves none
  //               focused; focus() on the other works
  async embedder() {
    await call("Page.enable");
    const base = await evalJs("location.origin");
    const apps: ReturnType<typeof spawnApp>[] = [];
    const load = async (query: string) => {
      for (const a of apps.splice(0)) a.kill();
      await call("Page.navigate", { url: `${base}/${query}` });
      await sleep(1000);
      await waitOnline();
    };
    // the newest window (or window `key`): its box, the grid canvas, focus
    const st = (key = ""): Promise<any> => evalJs(`(() => {
      window.scrollTo(0, 0);
      const wl = window.wland, vws = wl.view.windows(), es = wl.windows();
      const i = ${JSON.stringify(key)} ? vws.findIndex((w) => w.key === ${JSON.stringify(key)}) : vws.length - 1;
      const w = vws[i];
      if (!w) return null;
      const c = wl.view.canvas(w.conn, w.surface), r = c.getBoundingClientRect();
      return { key: w.key, conn: w.conn, surface: w.surface, left: w.element.style.left, top: w.element.style.top,
        translate: w.element.style.translate || '', maximized: es[i].maximized, focused: es[i].focused,
        anyFocused: es.some((e) => e.focused), x: r.left, y: r.top, w: parseFloat(c.style.width), h: parseFloat(c.style.height),
        sinkFocused: document.activeElement && document.activeElement.contentEditable === 'true' };
    })()`);
    const until = async (ok: (s: any) => boolean, what: string, key = "") => {
      let s = await st(key);
      for (let i = 0; i < 50 && !(s && ok(s)); i++) { await sleep(200); s = await st(key); }
      if (!(s && ok(s))) fail(`${what}: ${JSON.stringify(s)}`);
      return s;
    };
    const spawnTerm = async (what: string) => {
      const before: string[] = await evalJs("window.wland.view.windows().map((w) => w.key)");
      apps.push(spawnApp("term"));
      return until((s) => !before.includes(s.key) && s.w > 100 && s.h > 100, what);
    };
    // engine calls the app side would see, recorded from here on
    const record = (names: string[]) => evalJs(`(() => {
      const e = window.wland.engine, seen = window.e2eSeen = [];
      for (const name of ${JSON.stringify(names)}) {
        if (!e['_' + name]) e['_' + name] = e[name];
        const orig = e['_' + name];
        e[name] = (...a) => { seen.push([name, ...a]); return orig(...a); };
      }
    })()`);
    const seen = async (): Promise<string[]> => (await evalJs("window.e2eSeen")).map((c: any[]) => c[0]);
    const blur = () => evalJs("window.dispatchEvent(new Event('blur'))");
    const press = (x: number, y: number, modifiers = 0) => mouse("mousePressed", x, y, { button: "left", buttons: 1, clickCount: 1, modifiers });
    const moveTo = async (x: number, y: number, modifiers = 0) => { await mouse("mouseMoved", x, y, { button: "left", buttons: 1, modifiers }); await sleep(40); };
    const release = (x: number, y: number, modifiers = 0) => mouse("mouseReleased", x, y, { button: "left", buttons: 0, clickCount: 1, modifiers });
    const close = (a: number, b: number) => Math.abs(a - b) <= 1;
    try {
      // --- default: wland's own grab, a blur mid-drag, a second drag -------
      await load("");
      let s = await spawnTerm("a term mapped");
      let tx = s.x + 60, ty = s.y - 13; // its titlebar (above the grid)
      await mouse("mouseMoved", tx, ty);
      await press(tx, ty);
      await sleep(200); // the app asks for the move
      const l0 = parseFloat(s.left);
      await moveTo(tx + 20, ty + 10);
      await moveTo(tx + 40, ty + 20);
      s = await until((v) => close(parseFloat(v.left), l0 + 40), "the titlebar drag moves the window (wland's grab)");
      const movedTo = s.left;
      await blur();
      await moveTo(tx + 140, ty + 60);
      await sleep(200);
      s = await st(s.key);
      if (s.left !== movedTo) fail(`the window's blur did not end wland's grab: ${movedTo} → ${s.left}`);
      if (await evalJs("document.body.style.cursor") !== "") fail("the grab's cursor is left on");
      await release(tx + 140, ty + 60);
      await sleep(200);
      tx = s.x + 60; ty = s.y - 13;
      await mouse("mouseMoved", tx, ty);
      await press(tx, ty);
      await sleep(200);
      await moveTo(tx + 30, ty + 15);
      await moveTo(tx + 60, ty + 30);
      await release(tx + 60, ty + 30);
      const s2 = await until((v) => close(parseFloat(v.left), l0 + 100), "a second drag after the blur moves the window again");
      console.log(`wland's grab: dragged to ${movedTo}, a blur ended it, the next drag moved it to ${s2.left}`);

      // --- ?embedder=1: the page's window manager takes them ---------------
      await load("?embedder=1");
      s = await spawnTerm("a term mapped (embedder page)");
      const asked = (): Promise<any[]> => evalJs("window.wlandEmbedder");
      const left0 = s.left, top0 = s.top;
      await record(["pointerMotion", "pointerButton", "requestResize"]);
      // a move from the app (its titlebar)
      tx = Math.round(s.x + 60); ty = Math.round(s.y - 13);
      await mouse("mouseMoved", tx, ty);
      await press(tx, ty);
      for (let i = 0; i < 25 && !(await asked()).length; i++) await sleep(100);
      await record(["pointerMotion", "pointerButton", "requestResize"]);
      await moveTo(tx + 25, ty + 10);
      await moveTo(tx + 50, ty + 20);
      await release(tx + 50, ty + 20);
      await sleep(200);
      let a = await asked();
      s = await st(s.key);
      const mv = a[0];
      console.log(`move: ${JSON.stringify(mv)}; box ${s.left},${s.top} translate "${s.translate}"; app saw ${JSON.stringify(await seen())}`);
      if (!mv || mv.type !== "move" || mv.conn !== s.conn || mv.surface !== s.surface) fail(`the hook was not asked for the move: ${JSON.stringify(a)}`);
      if (mv.press.pointerType !== "mouse" || mv.press.button !== 0 || mv.press.buttons !== 1 || !close(mv.press.clientX, tx) || !close(mv.press.clientY, ty)) {
        fail(`the press handed over is not the CDP press at ${tx},${ty}: ${JSON.stringify(mv.press)}`);
      }
      if (!mv.active || mv.ended !== "release" || mv.moves < 2) fail(`the page's grab: ${JSON.stringify(mv)}`);
      if (s.left !== left0 || s.top !== top0) fail(`wland moved the window itself: ${left0},${top0} → ${s.left},${s.top}`);
      if (s.translate !== "50px 20px") fail(`the embedder's move did not follow the pointer: "${s.translate}"`);
      if ((await seen()).length) fail("the app got pointer events during the embedder's grab");
      // a resize from the app (its right border, just outside the box)
      const rx = Math.round(s.x + s.w + 2), ry = Math.round(s.y + s.h / 2);
      const w0 = s.w;
      await mouse("mouseMoved", rx, ry);
      await press(rx, ry);
      for (let i = 0; i < 25 && (await asked()).length < 2; i++) await sleep(100);
      await moveTo(rx + 60, ry);
      await moveTo(rx + 120, ry);
      await release(rx + 120, ry);
      await sleep(500);
      a = await asked();
      s = await st(s.key);
      const rs = a[1];
      console.log(`resize: ${JSON.stringify(rs)}; grid ${w0} → ${s.w}`);
      if (!rs || rs.type !== "resize" || !(rs.edges & 8) || !close(rs.press.clientX, rx) || !close(rs.press.clientY, ry)) fail(`the hook was not asked for the resize as pressed: ${JSON.stringify(rs)}`);
      if (rs.ended !== "release" || s.w !== w0 || s.left !== left0) fail(`wland resized or moved the window itself: ${JSON.stringify(s)}`);
      if ((await seen()).includes("requestResize")) fail("wland asked the app for a size");
      // Alt+drag: an 'alt-drag', the page moves the window
      const ax = Math.round(s.x + s.w / 2), ay = Math.round(s.y + s.h / 2);
      await mouse("mouseMoved", ax, ay);
      await press(ax, ay, 1);
      await moveTo(ax + 30, ay + 30, 1);
      await release(ax + 30, ay + 30, 1);
      await sleep(200);
      a = await asked();
      s = await st(s.key);
      const ad = a[2];
      if (!ad || ad.type !== "alt-drag" || !close(ad.press.clientX, ax) || ad.ended !== "release" || ad.moves < 1) fail(`Alt+drag: ${JSON.stringify(a)}`);
      if (s.left !== left0 || s.translate !== "80px 50px") fail(`Alt+drag moved by wland or not by the page: ${JSON.stringify(s)}`);
      console.log(`alt-drag: ${JSON.stringify(ad)}; translate "${s.translate}"`);
      // a window blur mid-drag ends the page's grab (no pointerup: touch)
      tx = Math.round(s.x + 60); ty = Math.round(s.y - 13);
      await mouse("mouseMoved", tx, ty);
      await press(tx, ty);
      for (let i = 0; i < 25 && (await asked()).length < 4; i++) await sleep(100);
      await moveTo(tx + 10, ty);
      await blur();
      a = await asked();
      if (!a[3] || a[3].type !== "move" || a[3].ended !== "blur") fail(`a blur mid-drag: ${JSON.stringify(a[3])}`);
      await record(["pointerMotion", "pointerButton"]);
      await moveTo(tx + 20, ty);
      await release(tx + 20, ty);
      await sleep(200);
      if (!(await seen()).includes("pointerMotion")) fail("after the blur the app does not get the pointer back");
      // ... and the next drag is taken, and held, again
      s = await st(s.key);
      tx = Math.round(s.x + 60); ty = Math.round(s.y - 13);
      await mouse("mouseMoved", tx, ty);
      await press(tx, ty);
      for (let i = 0; i < 25 && (await asked()).length < 5; i++) await sleep(100);
      await record(["pointerMotion", "pointerButton"]);
      await moveTo(tx + 15, ty + 5);
      await release(tx + 15, ty + 5);
      await sleep(200);
      a = await asked();
      if (!a[4] || a[4].type !== "move" || !a[4].active || a[4].ended !== "release" || a[4].moves < 1) fail(`the drag after the blur: ${JSON.stringify(a[4])}`);
      if ((await seen()).length) fail(`the drag after the blur did not hold the app off: ${JSON.stringify(await seen())}`);
      console.log("embedder ok: move, resize and Alt+drag handed over with their press, no grab of wland's; a blur mid-drag ends the page's grab, the next drag is held again");

      // --- ?altdrag=0: Alt+press is the app's; Alt+F10 still works ---------
      await load("?altdrag=0");
      s = await spawnTerm("a term mapped (altdrag=0)");
      await record(["pointerButton"]);
      const bx = Math.round(s.x + s.w / 2), by = Math.round(s.y + s.h / 2);
      await mouse("mouseMoved", bx, by);
      await press(bx, by, 1);
      await moveTo(bx + 60, by + 40, 1);
      await release(bx + 60, by + 40, 1);
      await sleep(300);
      const s3 = await st(s.key);
      const buttons = (await evalJs("window.e2eSeen")).filter((c: any[]) => c[0] === "pointerButton").map((c: any[]) => c[4]);
      if (s3.left !== s.left || s3.top !== s.top) fail(`Alt+drag moved the window with drag off: ${s.left},${s.top} → ${s3.left},${s3.top}`);
      if (JSON.stringify(buttons) !== "[true,false]") fail(`the Alt+press did not reach the app: buttons ${JSON.stringify(buttons)}`);
      await call("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "F10", code: "F10", windowsVirtualKeyCode: 121, modifiers: 1 });
      await call("Input.dispatchKeyEvent", { type: "keyUp", key: "F10", code: "F10", windowsVirtualKeyCode: 121, modifiers: 1 });
      await until((v) => v.maximized, "Alt+F10 still maximizes with Alt+drag off", s.key);
      console.log("altdrag=0 ok: the Alt+press went to the app, the window stayed; Alt+F10 maximized it");

      // --- manageDisplay: the view hides a minimized window by default; with
      // ?display=0 it leaves the element's display to the page --------------
      const display = (key: string): Promise<any> => evalJs(`(() => {
        const wl = window.wland, w = wl.view.windows().find((w) => w.key === ${JSON.stringify(key)});
        return w && { minimized: w.minimized, display: w.element.style.display };
      })()`);
      const minimize = (key: string, on: boolean) => evalJs(`(() => {
        const e = window.wland.windows().find((e) => e.key === ${JSON.stringify(key)});
        ${on} ? e.minimize() : e.restore();
      })()`);
      const untilDisplay = async (key: string, ok: (d: any) => boolean, what: string) => {
        let d = await display(key);
        for (let i = 0; i < 25 && !(d && ok(d)); i++) { await sleep(200); d = await display(key); }
        if (!(d && ok(d))) fail(`${what}: ${JSON.stringify(d)}`);
        return d;
      };
      await minimize(s3.key, true);
      await untilDisplay(s3.key, (d) => d.minimized && d.display === "none", "minimized: the view hides the element (default)");
      await minimize(s3.key, false);
      await untilDisplay(s3.key, (d) => !d.minimized && d.display === "", "restored: shown again");
      await load("?display=0");
      const s4 = await spawnTerm("a term mapped (display=0)");
      await evalJs(`window.wland.view.window(${s4.conn}, ${s4.surface}).element.style.display = 'block'`); // the page's own
      await minimize(s4.key, true);
      await untilDisplay(s4.key, (d) => d.minimized, "minimized (display=0)");
      await sleep(300);
      let d4 = await display(s4.key);
      if (d4.display !== "block") fail(`the view wrote display with manageDisplay off: "${d4.display}"`);
      await evalJs(`window.wland.view.window(${s4.conn}, ${s4.surface}).element.style.display = 'none'`);
      await minimize(s4.key, false);
      await untilDisplay(s4.key, (d) => !d.minimized, "restored (display=0)");
      await sleep(300);
      d4 = await display(s4.key);
      if (d4.display !== "none") fail(`the view wrote display at the restore with manageDisplay off: "${d4.display}"`);
      console.log("manageDisplay ok: minimized hides the element by default; with display=0 the view never writes it");

      // --- ?autofocus=0: focus only when told ------------------------------
      await load("?autofocus=0");
      const t1 = await spawnTerm("the first term (autofocus=0)");
      const t2 = await spawnTerm("the second term (autofocus=0)");
      if (t1.anyFocused || t2.anyFocused) fail(`a window took focus at map: ${JSON.stringify(t2)}`);
      await click(Math.round(t2.x + t2.w / 2), Math.round(t2.y + t2.h / 2), 100);
      await sleep(200);
      if ((await st(t2.key)).anyFocused) fail("a press focused a window");
      await evalJs(`window.wland.input.focus(${t2.conn}, ${t2.surface})`);
      let f = await until((v) => v.focused && v.sinkFocused, "input.focus() gives it, the IME sink has the page's focus", t2.key);
      const sum = (): Promise<number> => evalJs(`(() => {
        const c = window.wland.view.canvas(${t2.conn}, ${t2.surface}), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
        let s = 0;
        for (let i = 0; i < d.length; i += 4) s = (s * 31 + d[i] + d[i + 1] * 7 + d[i + 2] * 13) >>> 0;
        return s;
      })()`);
      const before = await sum();
      await typeText("echo hi");
      await sleep(500);
      if ((await sum()) === before) fail("keys after input.focus() did not reach the app");
      // the focused app goes: nobody else is given the keyboard
      apps[1]!.kill();
      await until((v) => v.key === t1.key, "the second term gone", "");
      await sleep(500);
      f = await st(t1.key);
      if (f.anyFocused) fail(`focus passed on by itself: ${JSON.stringify(f)}`);
      await evalJs(`window.wland.input.focus(${t1.conn}, ${t1.surface})`);
      await until((v) => v.focused, "input.focus() on the one left", t1.key);
      console.log("autofocus=0 ok: nothing focused at map or press, focus() gives it (keys reach the app), the focused app going leaves none focused");
    } finally {
      for (const a of apps.splice(0)) a.kill();
      await call("Page.navigate", { url: `${base}/` });
      await sleep(1000);
      await waitOnline();
    }
  },

  async retina() {
    // (persists across reloads while this CDP session lives)
    await call("Emulation.setDeviceMetricsOverride", { width: 1600, height: 1100, deviceScaleFactor: 2, mobile: false });
    await call("Page.enable");
    await call("Page.reload");
    await sleep(1000);
    await waitOnline();
    const dpr = await evalJs("window.devicePixelRatio");
    if (dpr !== 2) fail(`emulated dpr is ${dpr}, wanted 2`);

    const foot = spawnApp("term");
    let s: Sample | null = null;
    for (let i = 0; i < 75 && !s; i++) {
      await sleep(200);
      s = await sample();
    }
    // The crispness invariant is buffer == 2 × logical (CSS) size, regardless
    // of mechanism: a fractional-scale-aware client (foot) reaches it via
    // wp_viewport.set_destination + wp_fractional_scale (buffer_scale stays
    // 1) instead of set_buffer_scale(2); the CSS box is buffer/2 either way.
    let failed = "";
    if (!s) failed = "no canvas appeared under dpr=2";
    else {
      console.log(`buffer ${s.w}x${s.h}, css ${s.cssW}x${s.cssH}, colored=${s.colored}`);
      if (Math.abs(s.w / s.cssW - 2) > 0.01 || Math.abs(s.h / s.cssH - 2) > 0.01) {
        failed = "canvas CSS box is not buffer/2 — retina buffers not displayed at logical size";
      } else if (s.colored < 100) failed = "retina canvas looks blank";
    }
    // restore dpr 1 for the phases after us, whatever the verdict
    foot.kill();
    await call("Emulation.clearDeviceMetricsOverride");
    await call("Page.reload");
    await sleep(1000);
    await waitOnline();
    if (failed) fail(failed);
    console.log("retina ok: 2x buffers rendered and displayed at logical size");
  },

  // After a second browser connects, the FIRST tab shows the "taken over"
  // notice (WS close code 4000) and does NOT auto-reload (a reload would
  // steal the session back — ping-pong). run-poc then proves the NEW tab
  // works by running `terminal` against its CDP port.
  async takeover() {
    const status = (): Promise<string> => evalJs("document.getElementById('status')?.innerText ?? ''");
    let s = "";
    for (let i = 0; i < 50; i++) {
      s = await status();
      if (s.includes("taken over")) break;
      await sleep(200);
    }
    if (!s.includes("taken over")) fail(`old tab never showed the takeover notice; status:\n${s}`);
    console.log("old tab kicked with takeover notice");
    // past the 3s auto-reload window: the notice must persist
    await sleep(4000);
    s = await status();
    if (!s.includes("taken over")) fail(`old tab reloaded and stole the session back; status:\n${s}`);
    console.log("takeover ok: old tab stayed kicked (no reload fight)");
  },

  // The GL present path. Production uses a WebGL texture per toplevel only
  // when WebGL is hardware-accelerated; software GL (SwiftShader in headless
  // CI) falls back to 2d, and in-DOM software GL deadlocks headless
  // compositing at large/retina sizes — so the other phases run 2d. This one
  // forces GL on (?webgl=always) at dpr 1, where small buffers are safe, and
  // asserts the toplevel renders through GL with non-blank pixels: the
  // channel-order / Y-flip / format canary. Not in run-poc.
  async webgl() {
    await call("Page.enable");
    const hasWebGL = await evalJs(
      "(()=>{try{const c=document.createElement('canvas');return !!(c.getContext('webgl2')||c.getContext('webgl'));}catch{return false;}})()");
    if (hasWebGL !== true) {
      // can't verify the GL path — say so and pass, don't invent a failure
      console.log("webgl SKIP: no WebGL context available in this browser");
      return;
    }
    await call("Emulation.clearDeviceMetricsOverride");
    const origin = await evalJs("location.origin");
    await call("Page.navigate", { url: `${origin}/?webgl=always` });
    await sleep(1200);
    await waitOnline();

    const foot = spawnApp("term");
    let info: any = null;
    for (let i = 0; i < 75 && !info; i++) {
      await sleep(300);
      // pixels through the view's present backend (GL draw + readPixels)
      info = await evalJs(`(() => {
        const c = ${MAIN};
        if (!c) return null;
        const m = c.dataset.wland.match(/^c(\\d+)s(\\d+)$/);
        const rb = window.wland.view.readPixels(+m[1], +m[2]);
        if (!rb) return null;
        let colored = 0;
        for (let j = 0; j < rb.data.length; j += 4) if (rb.data[j] + rb.data[j+1] + rb.data[j+2] > 30) colored++;
        // getContext('2d') is null on a canvas that already holds a GL context
        return { kind: c.getContext('2d') ? '2d' : 'webgl', w: c.width, h: c.height, colored, pixels: rb.data.length / 4 };
      })()`);
    }
    foot.kill();
    // a clean (non-forced) page for whatever runs after us
    await call("Page.navigate", { url: `${origin}/` });
    await sleep(500);
    if (!info) fail("no toplevel canvas appeared under forced GL");
    console.log(`webgl toplevel: ${info.kind} ${info.w}x${info.h}, colored ${info.colored}/${info.pixels}`);
    if (info.kind !== "webgl") fail(`toplevel used ${info.kind}, not WebGL — GL present path did not engage`);
    if (info.colored < 1000) fail("GL-rendered canvas is blank (channel/format/flip bug?)");
    console.log("webgl ok: toplevel rendered through the WebGL present path, pixels non-blank");
  },

  "handle-demo": handleDemo,

  // --- drivers ---
  async drag() {
    const [x1, y1, x2, y2] = args.map(Number) as [number, number, number, number];
    const k = await waitWide(700);
    const r = await evalJs(`(() => { const r = document.querySelector('[data-wland="${k}"]').getBoundingClientRect(); return { l: r.left, t: r.top }; })()`);
    const from: [number, number] = [r.l + x1, r.t + y1], to: [number, number] = [r.l + x2, r.t + y2];
    await mouse("mouseMoved", from[0], from[1]);
    await sleep(300);
    await mouse("mousePressed", from[0], from[1], { button: "left", buttons: 1, clickCount: 1 });
    await sleep(200);
    for (let i = 1; i <= 14; i++) {
      await mouse("mouseMoved", from[0] + ((to[0] - from[0]) * i) / 14, from[1] + ((to[1] - from[1]) * i) / 14,
        { button: "left", buttons: 1 });
      await sleep(70);
    }
    await sleep(600); // hover: GTK needs time to highlight the drop target
    await mouse("mouseReleased", to[0], to[1], { button: "left", buttons: 0, clickCount: 1 });
    await sleep(800);
    console.log("drag dispatched");
  },
  async shot() {
    const res = await call("Page.captureScreenshot", { format: "png" });
    await Bun.write(args[0] ?? fail("shot: output file?"), Buffer.from(res.result.data, "base64"));
    console.log(`wrote ${args[0]} (main canvas: ${JSON.stringify(await evalJs(`(() => { const c = ${MAIN}; if (!c) return null; const r = c.getBoundingClientRect(); return { l: r.left, t: r.top, w: r.width, h: r.height }; })()`))})`);
  },
  async log() {
    const lines = String(await evalJs(`(window.wlandLog || []).slice(-400).join("\\n")`));
    for (const l of lines.split("\n")) if (!args[0] || l.includes(args[0])) console.log(l);
  },
};

// /handle-demo.html — the link-v2 handle path in one page (synthetic
// clients, a JS relay, kwshm-style handles, the engine + view; no /ws
// session, so it never takes a session over). Per mode: both windows render
// non-blank and animate, the relay's counters advance with every COMMIT
// ACKed and zero violations, every client gets presentation feedback off
// the rAF clock (vsync, the measured interval; each time checked by the
// client against the relay's clock), and a click and typed keys reach the
// client under the pointer. Modes: 2D (core-swizzled rgba) and WebGL (bgra/bgrx
// rows, shader swizzle), sync and async HandleSource (also its readv and
// view shapes), stream and memory links. args[0]: the origin serving the built pages (default: the tab's).
async function handleDemo() {
  await call("Page.enable");
  await call("Emulation.clearDeviceMetricsOverride");
  const origin = args[0] ?? await evalJs("location.origin");

  // per window: a point on it that is not covered and not decoration (a
  // click there is a plain click), and pixel stats from the view's present
  // backend (2D getImageData or GL draw + readPixels)
  const SAMPLE = `(() => {
    const d = window.handleDemo;
    return d.wl.view.windows().map((w) => {
      const c = d.wl.view.canvas(w.conn, w.surface);
      const r = c.getBoundingClientRect();
      let point = null;
      for (let y = r.top + 70; y < r.bottom - 40 && !point; y += 13) {
        for (let x = r.left + 12; x < r.right - 30 && !point; x += 17) {
          if (document.elementFromPoint(x, y) === c) point = [Math.round(x), Math.round(y)];
        }
      }
      const rb = d.wl.view.readPixels(w.conn, w.surface);
      let colored = 0, opaque = 0, red = 0, hash = 0;
      for (let i = 0; i < rb.data.length; i += 4) {
        if (rb.data[i] + rb.data[i + 1] + rb.data[i + 2] > 30) colored++;
        // the close box is (220, 80, 70): with B and R swapped it would be blue
        if (rb.data[i] > 200 && rb.data[i + 1] < 100 && rb.data[i + 2] < 90) red++;
        if (rb.data[i + 3] === 255) opaque++;
        hash = (hash * 31 + rb.data[i] + rb.data[i + 1] * 7 + rb.data[i + 2] * 13) | 0;
      }
      const client = d.clients[w.conn - 1];
      return { conn: w.conn, surface: w.surface, w: rb.width, h: rb.height, colored, opaque, red,
               pixels: rb.data.length / 4, hash, point, frames: client.stats.frames,
               typed: client.stats.typed, clicks: client.stats.clicks };
    });
  })()`;

  // canvas-local point → viewport point for window `conn` (negative: from
  // the right/bottom edge)
  async function at(conn: number, x: number, y: number): Promise<[number, number]> {
    const r = await evalJs(`(() => { const w = handleDemo.wl.view.windows().find((w) => w.conn === ${conn});
      const b = handleDemo.wl.view.canvas(w.conn, w.surface).getBoundingClientRect();
      return [b.left, b.top, b.width, b.height]; })()`);
    return [Math.round(r[0] + (x < 0 ? r[2] + x : x)), Math.round(r[1] + (y < 0 ? r[3] + y : y))];
  }
  async function dragTo(from: [number, number], to: [number, number]) {
    await mouse("mouseMoved", from[0], from[1]);
    await drag(from, to, 6, 30, 0);
    await sleep(400);
  }
  const clientState = (conn: number) => evalJs(`(() => { const c = handleDemo.clients[${conn - 1}];
    return { alive: c.stats.alive, reason: c.stats.reason, w: c.width, h: c.height }; })()`);

  // the window decorations: close (the client hangs up: CONN_CLOSE, its
  // handles go without HANDLE_CLOSE), the resize grip (wm grab → configure →
  // a new pool and buffers: new handles, the old ones closed once ACKed),
  // maximize (configure to the desktop size)
  async function windowOps(mode: string) {
    await dragTo(await at(2, -15, 14), await at(2, -15, 14)); // close box of window 2
    if ((await clientState(2)).alive) fail(`[${mode}] window 2 did not close from its close button`);
    if (await evalJs("handleDemo.wl.view.windows().length") !== 1) fail(`[${mode}] closed window still shown`);

    const before = await clientState(1);
    const grip = await at(1, -6, -6);
    await dragTo(grip, [grip[0] + 60, grip[1] + 40]);
    const resized = await clientState(1);
    if (!(resized.w >= before.w + 40 && resized.h >= before.h + 25)) fail(`[${mode}] grip resize: ${before.w}x${before.h} → ${resized.w}x${resized.h}`);

    await dragTo(await at(1, -39, 14), await at(1, -39, 14)); // maximize box
    const max = await clientState(1);
    const desk = await evalJs("[document.getElementById('desktop').clientWidth, document.getElementById('desktop').clientHeight]");
    if (max.w !== desk[0] || max.h !== desk[1]) fail(`[${mode}] maximize: ${max.w}x${max.h}, desktop ${desk}`);
    await sleep(300);
    const s = await evalJs("handleDemo.stats()");
    if (s.tokens !== s.handles || s.exports !== s.handles || s.handles > 3) fail(`[${mode}] handles after close/resize/maximize: ${JSON.stringify(s)}`);
    console.log(`  close ok; grip resize ${before.w}x${before.h} → ${resized.w}x${resized.h}; maximize → ${max.w}x${max.h}; handles ${s.handles}`);
  }

  async function runMode(mode: string, ops: boolean, from = origin) {
    const bad = (msg: string): never => fail(`[${mode}] ${msg}`);
    await call("Page.navigate", { url: `${from}/handle-demo.html?${mode}` });
    let ready = false;
    for (let i = 0; i < 60 && !ready; i++) {
      await sleep(250);
      ready = await evalJs(`!!(window.handleDemo && handleDemo.wl.view.windows().length >= 2 &&
        handleDemo.clients.every((c) => c.stats.frames > 10))`) === true;
    }
    if (!ready) bad(`two animating windows never appeared: ${JSON.stringify(await evalJs("window.handleDemo && { stats: handleDemo.stats(), v: handleDemo.violations, log: handleDemo.log.slice(-15) }"))}`);

    const s0 = await evalJs("handleDemo.stats()");
    const a = await evalJs(SAMPLE);
    await sleep(600);
    const b = await evalJs(SAMPLE);
    const s1 = await evalJs("handleDemo.stats()");
    const kind = await evalJs("handleDemo.wl.view.stats.webgl > 0 ? 'webgl' : '2d'");
    if ((kind === "webgl") !== mode.includes("webgl=always")) bad(`presenter is ${kind}`);

    for (let i = 0; i < 2; i++) {
      const w0 = a[i], w1 = b[i];
      console.log(`  window c${w1.conn}s${w1.surface} ${w1.w}x${w1.h}: colored ${w1.colored}/${w1.pixels}, opaque ${w1.opaque}, red ${w1.red}, frames ${w0.frames}→${w1.frames}`);
      if (w1.colored < w1.pixels * 0.5) bad(`window ${i} is (mostly) blank`);
      if (w1.opaque < w1.pixels * 0.99) bad(`window ${i} is not opaque (alpha policy: xrgb X=0 must present as 255)`);
      if (w1.red < 18 * 18) bad(`window ${i}: red close box not found (${w1.red} px) — channel order wrong?`);
      if (w0.hash === w1.hash) bad(`window ${i} did not change in 600 ms (not animating)`);
      if (w1.frames <= w0.frames) bad(`client ${i} stopped drawing`);
    }
    if (!(s1.commits > s0.commits && s1.acks > s0.acks && s1.releases > s0.releases && s1.presented > s0.presented)) {
      bad(`counters did not advance: ${JSON.stringify(s0)} → ${JSON.stringify(s1)}`);
    }
    if (s1.acks < s1.commits - 4) bad(`ACKs lag COMMITs: ${s1.acks} vs ${s1.commits}`);
    if (s1.tokens !== s1.handles || s1.exports !== s1.handles) bad(`handle accounting: ${JSON.stringify(s1)}`);
    if (mode.includes("sab=1") && !(s1.isolated && (!mode.includes("shape=view") || s1.sharedViews > s0.sharedViews))) {
      bad(`sab mode: isolated ${s1.isolated}, shared views ${s0.sharedViews} → ${s1.sharedViews} (pixels straight from SharedArrayBuffer memory)`);
    }
    if (mode.includes("gpu=1") && !(s1.resolves > s0.resolves && s1.gpuReleased === s1.resolves && s1.reads === 0)) {
      bad(`gpu mode: resolves/releases/reads ${JSON.stringify(s1)} (every resolve released, no handle reads)`);
    }

    // a click and typed keys reach the client under the pointer
    const target = b.find((w: any) => w.point) ?? bad("no uncovered point on any window");
    await click(target.point[0], target.point[1]);
    await sleep(150);
    for (const ch of "wland") await key(ch, `Key${ch.toUpperCase()}`, ch);
    await sleep(400);
    const after = (await evalJs(SAMPLE)).find((w: any) => w.conn === target.conn);
    if (after.clicks !== target.clicks + 1) bad(`click not reflected: clicks ${target.clicks} → ${after.clicks}`);
    if (!after.typed.endsWith("WLAND")) bad(`keys not reflected: typed "${after.typed}"`);
    if (after.hash === target.hash) bad("the click/keys did not repaint the window");

    if (ops) await windowOps(mode);
    const end = await evalJs("handleDemo.stats()");
    const violations = await evalJs("handleDemo.violations");
    if (violations.length || end.violations) bad(`violations: ${JSON.stringify(violations)}`);
    // presentation feedback from the page's rAF clock: presented (each
    // dated by the JS relay, checked by its client), vsync, the interval
    // the frame loop measured
    const fb = end.feedback as [number, number, number][];
    if (!fb.every(([n, refresh, flags]) => n > 10 && flags === 1 && refresh > 5e6 && refresh < 1e8)) {
      bad(`presentation feedback [presented, refresh ns, flags] per client: ${JSON.stringify(fb)}`);
    }
    console.log(`  ${kind}: COMMIT ${end.commits} ACK ${end.acks} released ${end.releases} presented ${end.presented}, handles ${end.handles}, ` +
      `feedback ${fb.map(([n, r]) => `${n}@${(r / 1e6).toFixed(1)}ms`).join(' ')} vsync, click+keys ok, 0 violations`);
  }

  for (const mode of ["webgl=never", "webgl=never&async=1&link=memory", "webgl=always", "webgl=always&async=1",
    "webgl=always&shape=view", "webgl=never&async=1&shape=readv", "gpu=1&webgl=never", "gpu=1&webgl=always"]) {
    console.log(`handle demo: ${mode}`);
    await runMode(mode, mode === "webgl=never");
  }
  // SharedArrayBuffer pools: the page must be cross-origin isolated, which
  // wlandr's server isn't — a mirror of it that adds COOP/COEP is. With
  // shape=view the commit's pixels ARE shared memory: GL uploads them with
  // texSubImage2D (or its copy fallback), 2D has the core swizzle from them.
  const mirror = await isolatedMirror(origin);
  try {
    for (const mode of ["sab=1&shape=view&webgl=always", "sab=1&shape=view&webgl=never", "sab=1&async=1&shape=readv&webgl=always",
      "sab=1&gpu=1&webgl=never"]) {
      console.log(`handle demo (cross-origin isolated): ${mode}`);
      await runMode(mode, false, mirror.origin);
    }
  } finally {
    await mirror.close();
  }
  await call("Page.navigate", { url: "about:blank" });
  console.log("handle-demo ok: 2D + WebGL, sync + async source (read, readv, view), stream + memory link, virtgpu COMMITs through a gpu source, SharedArrayBuffer pools");
}

// --- main ------------------------------------------------------------------

// `build <dir>`: the pages the phases run against (test/browser), bundled
// into a web root for `wlandr --web-root`. Nothing here comes from
// web/: that is a demo, free to change without moving these checks.
if (phase === "build") {
  const out = process.argv[3] ?? fail("build: output directory?");
  const src = new URL("../test/browser/", import.meta.url).pathname;
  const built = await Bun.build({
    entrypoints: [`${src}page.ts`, `${src}handle-demo.js`], outdir: out, target: "browser", format: "esm",
  });
  if (!built.success) fail(`bundling test/browser: ${built.logs.join("\n")}`);
  for (const f of ["index.html", "handle-demo.html"]) await Bun.write(`${out}/${f}`, Bun.file(`${src}${f}`));
  // the engine loads wland.wasm from next to its module: the bundle
  await Bun.write(`${out}/wland.wasm`, Bun.file(new URL("../lib/wland.wasm", import.meta.url).pathname));
  console.log(`test pages built in ${out}`);
  process.exit(0);
}

const run = phases[phase];
if (!run) {
  console.error(`usage: bun tools/browser-e2e.ts <phase> [cdp_port] [args...]\nphases: ${Object.keys(phases).join(" ")}`);
  process.exit(2);
}
await connect();
await run();
ws.close();
process.exit(0);
