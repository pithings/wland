// The page's one compositor session, and the bridge to React.
//
// The lib is imperative and owns the #desktop DOM outright; React owns the
// UI around it and reads this module through useSyncExternalStore. Options
// that the engine fixes at creation (the presenter, the link) restart the
// session in place: dispose, recreate, relaunch the apps that were open.
//
// The source (where the clients live) is an option too: the in-page apps, or
// — in dev, when vite runs wlandr — real host apps (sources.ts).
//
// The wire trace is NOT React state: every pointer motion is several
// messages. It lives in a ring buffer; the inspector subscribes and renders
// imperatively.
import { createWland } from 'wland/client';
import type { EngineStats, Wland } from 'wland/client';
import { createHostSource, createInPageSource, hostInfo, runHostApp } from './sources.ts';
import type { HostInfo, Source, SourceStats } from './sources.ts';
import { APPS, appById } from '../apps/index.ts';
import type { Metrics, Services } from '../wayland/app-types.ts';
import type { Client, WireTrace } from '../wayland/toolkit.ts';

const TRACE_MAX = 600;

export interface Options {
  /** page: the demo's in-page apps · host: real apps behind the dev wlandr */
  source: 'page' | 'host';
  webgl: 'auto' | 'always' | 'never';
  link: 'stream' | 'memory';
  damage: boolean;
}

export interface WindowInfo {
  key: string;
  conn: number | undefined;
  title: string;
  focused: boolean;
  minimized: boolean;
  fullscreen: boolean;
  app: string;
}

export interface ClientInfo {
  conn: number;
  appId: string;
  title: string;
}

export type SessionStats = SourceStats & { presented: number; engine: EngineStats };

export interface State {
  ready: boolean;
  error: string;
  opts: Options;
  kind: string;
  presenter: string;
  windows: WindowInfo[];
  clients: ClientInfo[];
  metrics: Metrics;
  stats: Partial<SessionStats>;
  violations: string[];
  /** The dev server's wlandr (null: none, the Host source is unavailable). */
  host: HostInfo | null;
  /** A client holds the browser's Pointer Lock (zwp_locked_pointer_v1). */
  pointerLocked: boolean;
}

/** A wire trace line, numbered and timed. */
export type TraceRecord = WireTrace & { seq: number; t: number };

/** A window's planned spot and size. */
interface Plan { w: number; h: number; x: number; y: number }

declare global {
  interface Window {
    /** Poke at the session from the devtools console. */
    wlandDemo?: unknown;
  }
}

let state: State = {
  ready: false,
  error: '',
  opts: { source: 'page', webgl: 'auto', link: 'stream', damage: false }, // webgl: the lib's default, GL only on a hardware GPU
  kind: '',
  presenter: '',
  windows: [],     // [{ key, conn, title, focused, app }]
  clients: [],     // [{ conn, appId, title }]
  metrics: { fps: 0, commitsPerSec: 0, kibPerSec: 0, readKibPerSec: 0, clients: 0, windows: 0, scale: 1 },
  stats: {},
  violations: [],
  host: null,
  pointerLocked: false,
};
const listeners = new Set<() => void>();
const traceListeners = new Set<(e: TraceRecord) => void>();
const trace: TraceRecord[] = [];
let traceSeq = 0;

let container: HTMLElement | null = null;
let wl: Wland | null = null;
let source: Source | null = null;
let clients: Client[] = [];
const debug = { damage: false };
let generation = 0;

function set(patch: Partial<State>) {
  state = { ...state, ...patch };
  for (const fn of listeners) fn();
}
export const subscribe = (fn: () => void) => (listeners.add(fn), () => listeners.delete(fn));
export const getState = (): State => state;
export const subscribeTrace = (fn: (e: TraceRecord) => void) => (traceListeners.add(fn), () => traceListeners.delete(fn));
export const getTrace = (): TraceRecord[] => trace;

function pushTrace(line: WireTrace) {
  const e = line as TraceRecord;
  e.seq = ++traceSeq;
  e.t = performance.now();
  trace.push(e);
  if (trace.length > TRACE_MAX) trace.splice(0, trace.length - TRACE_MAX);
  for (const fn of traceListeners) fn(e);
}

function violation(what: string) {
  console.warn('wland demo violation:', what);
  set({ violations: [...state.violations, what].slice(-20) });
}

// --- metrics -----------------------------------------------------------------
let presented = 0;
let lastSample = { t: performance.now(), presented: 0, bytes: 0, read: 0, frames: 0 };
let rafFrames = 0;
(function countFrames() { rafFrames++; requestAnimationFrame(countFrames); })();

function sample() {
  if (!wl) return;
  const now = performance.now();
  const dt = (now - lastSample.t) / 1000;
  const bytes = clients.reduce((n, c) => n + c.stats.bytes, 0);
  const sourceStats = source!.stats?.() ?? NO_STATS;
  const read = sourceStats.bytesRead;
  // max(0, …): a restart resets the counters under the last sample
  const metrics: Metrics = {
    fps: Math.round((rafFrames - lastSample.frames) / dt),
    commitsPerSec: Math.round((presented - lastSample.presented) / dt),
    kibPerSec: Math.max(0, Math.round((bytes - lastSample.bytes) / 1024 / dt)),
    readKibPerSec: Math.max(0, Math.round((read - lastSample.read) / 1024 / dt)),
    clients: clients.length,
    windows: state.windows.length,
    scale: Math.max(1, Math.min(4, Math.round(window.devicePixelRatio || 1))), // the engine's wl_output scale (lib/engine.ts setScale)
  };
  lastSample = { t: now, presented, bytes, read, frames: rafFrames };
  source!.check?.();
  set({ metrics, stats: { ...sourceStats, presented, engine: { ...wl.engine.stats } } });
}
setInterval(sample, 500);
const NO_STATS: SourceStats = { commits: 0, acks: 0, releases: 0, handles: 0, tokens: 0, exports: 0, reads: 0, bytesRead: 0 };

// what apps may ask of the page (a real client would use D-Bus or a portal)
const services: Services = {
  metrics: () => state.metrics,
  open: (id) => openApp(id),
};

// --- windows ------------------------------------------------------------------
const placed = new WeakSet<HTMLElement>();
let cascade = 0;
const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

// The first window of each app gets a planned spot and size for the output
// it lands on; later ones keep their default size and cascade.
const DOCK = 76; // the page's dock floats over the bottom of the output

function plan(id: string, W: number, H: number): Plan | null {
  H -= DOCK;
  const m = W < 760 ? 12 : 24, gap = 20;
  const bw = clamp(Math.round(W * 0.45), 360, 660);
  const rx = m + bw + gap, rw = W - rx - m; // the column right of Welcome
  const codeH = clamp(Math.round(H * 0.56), 260, 440);
  switch (id) {
    case 'welcome': return { w: bw, h: clamp(H - m * 2, 260, 640), x: m, y: m };
    case 'code': {
      const w = clamp(rw, 440, 600);
      return { w, h: codeH, x: Math.max(m, Math.min(rx, W - w - m)), y: m };
    }
    case 'pulse': {
      const w = clamp(rw - 180, 360, 460), h = clamp(H - codeH - m * 2 - gap, 220, 300);
      return { w, h, x: Math.max(m, Math.min(rx, W - w - m)), y: H - h - m };
    }
    case 'clock': return { w: 160, h: 160, x: W - 160 - m, y: H - 160 - m };
    case 'sketch': return { w: 460, h: 340, x: (W - 460) / 2, y: (H - 340) / 2 };
  }
  return null;
}
const planned = new Map<number, Plan>(); // conn → { x, y }
let focusAfter = 0; // the introduction gets keyboard focus once the first windows are placed

function refreshWindows() {
  if (!wl) return;
  // wl.windows() and view.windows() list the same windows in the same order
  const views = wl.view.windows();
  const windows = wl.windows().map((w, i): WindowInfo => {
    const conn = views[i]?.conn;
    const c = clients.find((x) => x.conn === conn);
    return { key: w.key, title: w.title, focused: w.focused, minimized: w.minimized, fullscreen: w.fullscreen, conn, app: c?.app.id ?? '' };
  });
  // host apps aren't Client objects: one row per connection with a window
  if (state.opts.source === 'host') {
    const hostClients: ClientInfo[] = [];
    for (const w of windows) {
      if (w.conn !== undefined && !hostClients.some((c) => c.conn === w.conn)) hostClients.push({ conn: w.conn, appId: '', title: w.title });
    }
    set({ windows, clients: hostClients });
  } else set({ windows });
}

// the view cascades new windows from the top-left; this demo places each
// one itself once its first commit sized it
function place() {
  if (!wl || !container) return;
  for (const w of wl.view.windows()) {
    if (placed.has(w.element) || !w.element.offsetWidth) continue;
    placed.add(w.element);
    const c = clients.find((x) => x.conn === w.conn);
    const W = container.clientWidth, H = container.clientHeight;
    const ew = w.element.offsetWidth, eh = w.element.offsetHeight;
    let x: number, y: number;
    const spot = c && planned.get(c.conn);
    if (spot) {
      planned.delete(c!.conn);
      x = clamp(spot.x, 0, Math.max(0, W - ew));
      y = clamp(spot.y, 0, Math.max(0, H - eh));
      if (c!.app.id === 'welcome') focusAfter = c!.conn;
    } else {
      const n = cascade++ % 5;
      x = Math.max(12, Math.min(W - ew - 12, (W - ew) / 2 - 90 + n * 44));
      y = Math.max(12, Math.min(H - eh - 12, (H - eh) / 2 - 50 + n * 34));
    }
    w.element.style.left = `${Math.round(x)}px`;
    w.element.style.top = `${Math.round(y)}px`;
  }
  if (focusAfter && planned.size === 0) {
    const conn = focusAfter;
    focusAfter = 0;
    setTimeout(() => focusApp(conn), 50); // after the window manager focused the last one mapped
  }
}

// --- lifecycle ---------------------------------------------------------------
async function start(openApps: string[]) {
  const gen = ++generation;
  set({ ready: false, error: '' });
  if (state.opts.source === 'host') {
    const host = await hostInfo();
    if (gen !== generation) return;
    set({ host });
    if (!host?.ok) {
      set({ error: `no host wlandr: ${host?.error || 'the dev server has none (vite-wlandr.ts)'}` });
      return;
    }
    source = createHostSource();
  } else {
    // a disposed session's link still reports its shutdown: not a violation
    source = createInPageSource({ link: state.opts.link, onViolation: (w) => gen === generation && violation(w) });
  }
  const host = state.opts.source === 'host';
  presented = 0;
  try {
    wl = await createWland({
      container: container!,
      link: source.link,
      buffers: source.buffers,
      webgl: state.opts.webgl,
      // a fullscreen window takes the browser's fullscreen too (Esc leaves both)
      browserFullscreen: true,
      onWindowsChange: refreshWindows,
      onEvent(ev) {
        if (gen !== generation) return;
        if (ev.type === 'commit') { presented++; place(); }
        else if (ev.type === 'error') violation(`engine: ${ev.detail}`);
        else if (ev.type === 'open') for (const id of openApps) launchApp(id);
        else if (ev.type === 'close' && host) {
          set({ ready: false, error: ev.takenOver ? 'another tab took over the host session' : 'the link to wlandr closed' });
        }
      },
    });
  } catch (e) {
    set({ error: (e as Error).message });
    return;
  }
  if (gen !== generation) { wl.dispose(); return; }
  window.wlandDemo = { wl, source, clients: () => clients, trace, state: () => state };
  set({
    ready: true,
    kind: source.kind,
    presenter: wl.view.webgl ? 'WebGL' : 'Canvas 2D',
  });
}

/** Mount the session in `el` (idempotent: StrictMode mounts twice). */
export function boot(el: HTMLElement, initialApps?: string[]): void {
  if (container) return;
  container = el;
  // the lib asks for Pointer Lock on a surface when a client locks the
  // pointer; the status bar says how to get out
  document.addEventListener('pointerlockchange', () => set({ pointerLocked: el.contains(document.pointerLockElement) }));
  hostInfo().then((host) => set({ host }));
  try {
    if (import.meta.env.DEV && localStorage.getItem('wland-source') === 'host') set({ opts: { ...state.opts, source: 'host' } });
  } catch { /* private mode */ }
  // the apps measure text: repaint once the web fonts are in
  document.fonts?.ready.then(repaintAll);
  document.fonts?.addEventListener?.('loadingdone', repaintAll);
  const narrow = el.clientWidth < 760;
  start(initialApps ?? (narrow ? ['welcome'] : ['welcome', 'code', 'pulse', 'clock']));
}

export function launchApp(id: string): void {
  let app = appById(id);
  if (!app || !source?.spawn) return;
  const W = container!.clientWidth, H = container!.clientHeight;
  const first = !clients.some((c) => c.app.id === id);
  const p = first ? plan(id, W, H) : null;
  // never larger than the output
  const w = Math.min(p?.w ?? app.width, W - 16), h = Math.min(p?.h ?? app.height, H - 16);
  app = { ...app, width: w, height: h, minWidth: Math.min(app.minWidth ?? w, w), minHeight: Math.min(app.minHeight ?? h, h) };
  const c = source.spawn(app, {
    trace: pushTrace,
    debug,
    services,
    onExit: (cl) => {
      clients = clients.filter((x) => x !== cl);
      set({ clients: clients.map(info) });
    },
  });
  clients.push(c);
  if (p) planned.set(c.conn, p);
  set({ clients: clients.map(info) });
}
const info = (c: Client): ClientInfo => ({ conn: c.conn, appId: c.app.id, title: c.title });

/** Focus the app's newest window, or launch it when none is open. */
export function openApp(id: string): void {
  const c = clients.findLast((x) => x.app.id === id);
  if (c) focusApp(c.conn); else launchApp(id);
}

export function closeApp(conn: number): void {
  clients.find((c) => c.conn === conn)?.close();
}

/** Raise and focus the app's window; a minimized one is restored. */
export function focusApp(conn: number): void {
  const i = wl ? wl.view.windows().findIndex((x) => x.conn === conn) : -1;
  if (i >= 0) wl!.windows()[i].raise(); // same order as view.windows()
}

/** Bring a minimized window back (the window list's key). */
export function restoreWindow(key: string): void {
  wl?.windows().find((w) => w.key === key)?.restore();
}

/** Start an app on the host (dev wlandr); its window shows up on its own. */
export async function runHost(cmd: string): Promise<void> {
  await runHostApp(cmd);
  set({ host: await hostInfo() });
}

/** Change options; the source, the presenter and the link restart the session. */
export function setOption<K extends keyof Options>(key: K, value: Options[K]): void {
  if (state.opts[key] === value) return;
  set({ opts: { ...state.opts, [key]: value } });
  if (key === 'source') {
    try { localStorage.setItem('wland-source', value as string); } catch { /* private mode */ }
  }
  if (key === 'damage') {
    debug.damage = value as boolean;
    for (const c of clients) c.repaint();
    return;
  }
  // in-page apps come back after a restart; host apps lose their connection
  let open = clients.map((c) => c.app.id);
  if (key === 'source' && value === 'page' && !open.length) open = ['welcome'];
  generation++; // silence the old session before it is torn down
  for (const c of clients) c.killed('session restarted');
  clients = [];
  wl?.dispose();
  wl = null;
  cascade = 0;
  planned.clear();
  focusAfter = 0;
  set({ clients: [], windows: [], violations: [] });
  start(open);
}

/** The page's theme changed: the apps repaint with the new palette. */
export function repaintAll(): void {
  for (const c of clients) c.repaint();
}

export { APPS };
