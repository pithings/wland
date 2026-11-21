// A tiny Wayland client toolkit for in-page apps. Every app built on it is a
// real Wayland client: it writes wire bytes to a socket stand-in (the relay's
// connect()), owns an shm pool per surface (an ArrayBuffer — the "memfd"),
// and reacts to the events the compositor sends back. Nothing here talks to
// the engine or the DOM directly; pixels reach the page only the way a guest
// app's would (relay → link → engine → view).
//
// What it does for an app:
//   - one xdg_toplevel with client-side decorations (title bar, maximize,
//     close, resize from every edge, double-click to maximize), and the
//     window states: maximized, fullscreen (no decorations), minimize;
//   - xdg_popup menus placed by an xdg_positioner, grabbed, dismissed on
//     popup_done (the page's window manager sends it on an outside click);
//   - painting with Canvas 2D into an OffscreenCanvas, then copying only the
//     damaged rects into a free wl_buffer (buffer age: each buffer catches up
//     on the rects it missed), damage_buffer + commit, paced by frame
//     callbacks;
//   - HiDPI: wl_compositor v6 preferred_buffer_scale → set_buffer_scale;
//   - an app-shaped input region (wl_surface.set_input_region), re-sent
//     when it changes;
//   - pointer lock (zwp_pointer_constraints_v1, oneshot, over a content
//     rect) and relative motion (zwp_relative_pointer_v1);
//   - presentation feedback (wp_presentation) per commit, for apps that
//     listen (AppInstance.presented);
//   - cursors via wp_cursor_shape_v1, or client-drawn ones: a role-less
//     wl_surface handed to wl_pointer.set_cursor; keys through a US keymap (the core's
//     canned us.xkb), pointer/wheel in surface-local coordinates.
//
// Pixels are ARGB8888 with straight alpha: wland's presenters show bgra
// as-is (lib/present.ts), so straight alpha is what looks right here.
//
// An app module is { id, name, width, height, minWidth?, minHeight?,
// frameless?, create(win) → { paint(ctx, w, h), pointer?(ev), key?(ev),
// tick?(ms), focus?(on), closed?() } }. `win` is the handle documented on
// makeWindowApi below.

import { wlMessage, wlEach } from './proto.ts';
import type { WlArg } from './proto.ts';
import type { ClientFd, Relay, RelayClient, RelaySocket } from './relay.ts';
import type {
  AppInstance, AppKeyEvent, AppModule, AppPointerEvent, CursorImage, CursorName, Ctx, PopupHandle, PopupOptions, Rect,
  Services, Theme, WindowApi,
} from './app-types.ts';

/** One line of the wire trace. */
export interface WireTrace {
  dir: 'req' | 'evt';
  conn: number;
  app: string;
  msg: string;
  args: string;
}

/** What launch() takes besides the app and the relay. */
export interface LaunchEnv {
  trace?(entry: WireTrace): void;
  debug?: { damage: boolean };
  services?: Services;
  onExit?(client: Client): void;
}

export interface ClientStats {
  frames: number;
  commits: number;
  /** Damage bytes copied into buffers. */
  bytes: number;
  alive: boolean;
  reason: string;
}

/** A running app: what launch() returns. */
export interface Client extends RelayClient {
  readonly app: AppModule;
  readonly stats: ClientStats;
  conn: number;
  readonly title: string;
  close(): void;
  /** Repaint every surface (the page's theme changed). */
  repaint(): void;
}

type Painter = (ctx: Ctx, w: number, h: number) => void;
type PointerType = AppPointerEvent['type'];

interface Buf { id: number; u32: Uint32Array<ArrayBuffer>; held: boolean; missed: Rect[] }

/** A surface record (createSurface). */
interface Surf {
  kind: 'toplevel' | 'popup';
  id: number;
  xsurf: number;
  role: number;
  W: number;
  H: number;
  scale: number;
  scaleSent: number;
  pending: { w: number; h: number; states: number[] };
  configured: boolean;
  pool: { id: number; file: ArrayBuffer } | null;
  bufs: Buf[];
  canvas: OffscreenCanvas | null;
  ctx: Ctx | null;
  damage: Rect[];
  full: boolean;
  frameCb: number;
  wantFrame: boolean;
  queued: boolean;
  paint: Painter;
  pointer: ((ev: AppPointerEvent) => void) | null;
  key: ((ev: AppKeyEvent) => boolean) | null;
  flashes: Rect[];
  gen: number;
}

/** Decoration under the pointer. */
type Zone = '' | 'max' | 'close' | 'title' | 'content' | 'edge';

const ARGB8888 = 0;
const NBUF = 3;
const BTN_LEFT = 0x110, BTN_RIGHT = 0x111;

export const TITLE_H = 38;
const EDGE = 6;
const RADIUS = 10;

// request / event names per interface, for the wire trace
const REQ: Record<string, string[]> = {
  wl_display: ['sync', 'get_registry'],
  wl_registry: ['bind'],
  wl_compositor: ['create_surface', 'create_region'],
  wl_region: ['destroy', 'add', 'subtract'],
  zwp_pointer_constraints_v1: ['destroy', 'lock_pointer', 'confine_pointer'],
  zwp_locked_pointer_v1: ['destroy', 'set_cursor_position_hint', 'set_region'],
  zwp_relative_pointer_manager_v1: ['destroy', 'get_relative_pointer'],
  zwp_relative_pointer_v1: ['destroy'],
  wp_presentation: ['destroy', 'feedback'],
  wl_shm: ['create_pool', 'release'],
  wl_shm_pool: ['create_buffer', 'destroy', 'resize'],
  wl_buffer: ['destroy'],
  wl_surface: ['destroy', 'attach', 'damage', 'frame', 'set_opaque_region', 'set_input_region', 'commit',
    'set_buffer_transform', 'set_buffer_scale', 'damage_buffer', 'offset'],
  wl_seat: ['get_pointer', 'get_keyboard', 'get_touch', 'release'],
  wl_pointer: ['set_cursor', 'release'],
  wl_keyboard: ['release'],
  wl_output: ['release'],
  xdg_wm_base: ['destroy', 'create_positioner', 'get_xdg_surface', 'pong'],
  xdg_positioner: ['destroy', 'set_size', 'set_anchor_rect', 'set_anchor', 'set_gravity',
    'set_constraint_adjustment', 'set_offset', 'set_reactive', 'set_parent_size', 'set_parent_configure'],
  xdg_surface: ['destroy', 'get_toplevel', 'get_popup', 'set_window_geometry', 'ack_configure'],
  xdg_toplevel: ['destroy', 'set_parent', 'set_title', 'set_app_id', 'show_window_menu', 'move', 'resize',
    'set_max_size', 'set_min_size', 'set_maximized', 'unset_maximized', 'set_fullscreen', 'unset_fullscreen',
    'set_minimized'],
  xdg_popup: ['destroy', 'grab', 'reposition'],
  wp_cursor_shape_manager_v1: ['destroy', 'get_pointer', 'get_tablet_tool_v2'],
  wp_cursor_shape_device_v1: ['destroy', 'set_shape'],
  zwp_text_input_manager_v3: ['destroy', 'get_text_input'],
  zwp_text_input_v3: ['destroy', 'enable', 'disable', 'set_surrounding_text', 'set_text_change_cause',
    'set_content_type', 'set_cursor_rectangle', 'commit'],
};
const EVT: Record<string, string[]> = {
  wl_display: ['error', 'delete_id'],
  wl_registry: ['global', 'global_remove'],
  wl_callback: ['done'],
  wl_buffer: ['release'],
  wl_surface: ['enter', 'leave', 'preferred_buffer_scale', 'preferred_buffer_transform'],
  wl_seat: ['capabilities', 'name'],
  wl_pointer: ['enter', 'leave', 'motion', 'button', 'axis', 'frame', 'axis_source', 'axis_stop',
    'axis_discrete', 'axis_value120', 'axis_relative_direction'],
  wl_keyboard: ['keymap', 'enter', 'leave', 'key', 'modifiers', 'repeat_info'],
  wl_output: ['geometry', 'mode', 'done', 'scale', 'name', 'description'],
  wl_shm: ['format'],
  xdg_wm_base: ['ping'],
  xdg_surface: ['configure'],
  xdg_toplevel: ['configure', 'close', 'configure_bounds', 'wm_capabilities'],
  xdg_popup: ['configure', 'popup_done', 'repositioned'],
  zwp_locked_pointer_v1: ['locked', 'unlocked'],
  zwp_relative_pointer_v1: ['relative_motion'],
  wp_presentation: ['clock_id'],
  wp_presentation_feedback: ['sync_output', 'presented', 'discarded'],
  zwp_text_input_v3: ['enter', 'leave', 'preedit_string', 'commit_string', 'delete_surrounding_text', 'done'],
};

// wp_cursor_shape_device_v1.shape
const CURSORS: Record<CursorName, number> = {
  default: 1, 'context-menu': 2, help: 3, pointer: 4, progress: 5, wait: 6, cell: 7, crosshair: 8,
  text: 9, move: 13, 'not-allowed': 15, grab: 16, grabbing: 17, 'n-resize': 19, 'ne-resize': 20,
  'nw-resize': 21, 's-resize': 22, 'se-resize': 23, 'sw-resize': 24, 'e-resize': 18, 'w-resize': 25,
  'ew-resize': 26, 'ns-resize': 27, 'zoom-in': 33, 'zoom-out': 34,
};

// xdg_toplevel.resize_edge → cursor
const EDGE_CURSOR: Record<number, CursorName> = {
  1: 'n-resize', 2: 's-resize', 4: 'w-resize', 8: 'e-resize',
  5: 'nw-resize', 9: 'ne-resize', 6: 'sw-resize', 10: 'se-resize',
};

// evdev keycode → [key, shifted]: a US layout, matching the core's us.xkb
const KEYMAP: Record<number, string[]> = {
  1: ['Escape'], 14: ['Backspace'], 15: ['Tab'], 28: ['Enter'], 57: [' ', ' '],
  102: ['Home'], 103: ['ArrowUp'], 104: ['PageUp'], 105: ['ArrowLeft'], 106: ['ArrowRight'],
  107: ['End'], 108: ['ArrowDown'], 109: ['PageDown'], 111: ['Delete'],
  12: ['-', '_'], 13: ['=', '+'], 26: ['[', '{'], 27: [']', '}'], 39: [';', ':'], 40: ["'", '"'],
  41: ['`', '~'], 43: ['\\', '|'], 51: [',', '<'], 52: ['.', '>'], 53: ['/', '?'],
};
'1234567890'.split('').forEach((c, i) => { KEYMAP[2 + i] = [c, '!@#$%^&*()'[i]]; });
for (const [start, row] of [[16, 'qwertyuiop'], [30, 'asdfghjkl'], [44, 'zxcvbnm']] as const) {
  row.split('').forEach((c, i) => { KEYMAP[start + i] = [c, c.toUpperCase()]; });
}
const MOD_SHIFT = 1, MOD_CAPS = 2, MOD_CTRL = 4, MOD_ALT = 8, MOD_LOGO = 64;

/** Start `app` as a new Wayland client of `relay`.
 *  env: { trace?(entry), debug?: { damage: boolean }, onExit?(client) } */
export function launch(app: AppModule, relay: Relay, env: LaunchEnv = {}): Client {
  const trace = env.trace || null;
  const debug = env.debug || { damage: false };
  let sock: RelaySocket | null = null;
  let nextId = 2;
  const objects = new Map<number, string>([[1, 'wl_display']]);
  const out: Uint8Array[] = [];
  let outFds: ArrayBuffer[] = [];
  let writing = false;
  const inbox: [Uint8Array, ClientFd[]][] = [];
  const globals: Record<string, { name: number; version: number }> = {};
  const g = { registry: 0, sync: 0, compositor: 0, shm: 0, wm: 0, seat: 0, pointer: 0, keyboard: 0, cursorMgr: 0, cursorDev: 0, textMgr: 0, textInput: 0,
    constraints: 0, relMgr: 0, relPtr: 0, lock: 0, presentation: 0 };
  const stats: ClientStats = { frames: 0, commits: 0, bytes: 0, alive: true, reason: '' };
  const surfaces = new Map<number, Surf>(); // wl_surface id → surface record

  const newId = (iface: string) => { const id = nextId++; objects.set(id, iface); return id; };
  function req(obj: number, op: number, args: readonly WlArg[] = []) {
    out.push(wlMessage(obj, op, args));
    if (trace) {
      const iface = objects.get(obj);
      trace({ dir: 'req', conn: client.conn, app: app.name, msg: `${iface}@${obj}.${REQ[iface ?? '']?.[op] ?? op}`, args: fmtArgs(args) });
    }
  }
  const evt = (iface: string | undefined, obj: number, op: number, args = '') =>
    trace && trace({ dir: 'evt', conn: client.conn, app: app.name, msg: `${iface}@${obj}.${EVT[iface ?? '']?.[op] ?? op}`, args });

  function bind(name: string, version: number) {
    const gl = globals[name];
    if (!gl) return 0;
    const id = newId(name);
    req(g.registry, 0, [gl.name, name, Math.min(version, gl.version), id]);
    return id;
  }

  // --- surfaces --------------------------------------------------------------
  // A surface: one wl_surface + xdg_surface + role (toplevel or popup), its
  // pool, buffers and canvas, and the painter that fills it.
  function createSurface(kind: Surf['kind'], paint: Painter): Surf {
    const s: Surf = {
      kind, id: newId('wl_surface'), xsurf: 0, role: 0,
      W: 0, H: 0, scale: 1, scaleSent: 1, pending: { w: 0, h: 0, states: [] },
      configured: false, pool: null, bufs: [], canvas: null, ctx: null,
      damage: [], full: true, frameCb: 0, wantFrame: false, queued: false,
      paint, pointer: null, key: null, flashes: [], gen: 0,
    };
    surfaces.set(s.id, s);
    req(g.compositor, 0, [s.id]);
    s.xsurf = newId('xdg_surface');
    req(g.wm, 2, [s.xsurf, s.id]);
    return s;
  }

  function destroySurface(s: Surf) {
    for (const b of s.bufs) req(b.id, 0);
    if (s.pool) req(s.pool.id, 1);
    if (s.role) req(s.role, 0);
    req(s.xsurf, 0);
    req(s.id, 0);
    surfaces.delete(s.id);
    s.bufs = [];
    s.pool = null;
  }

  function allocate(s: Surf) {
    for (const b of s.bufs) req(b.id, 0); // held ones too: destroyed buffers are never released
    if (s.pool) req(s.pool.id, 1);
    const BW = s.W * s.scale, BH = s.H * s.scale, size = BW * BH * 4;
    s.pool = { id: newId('wl_shm_pool'), file: new ArrayBuffer(size * NBUF) };
    req(g.shm, 0, [s.pool.id, s.pool.file.byteLength]); // create_pool: the fd travels out of band
    outFds.push(s.pool.file);
    s.bufs = [];
    for (let i = 0; i < NBUF; i++) {
      const id = newId('wl_buffer');
      req(s.pool.id, 0, [id, i * size, BW, BH, BW * 4, ARGB8888]);
      s.bufs.push({ id, u32: new Uint32Array(s.pool.file, i * size, BW * BH), held: false, missed: [[0, 0, BW, BH]] });
    }
    s.gen++;
    s.flashes = [];
    s.canvas = new OffscreenCanvas(BW, BH);
    s.ctx = s.canvas.getContext('2d', { willReadFrequently: true });
    s.full = true;
  }

  function invalidate(s: Surf, rect?: Rect) {
    if (!rect) s.full = true;
    else s.damage.push(rect);
    schedule(s);
  }

  function schedule(s: Surf) {
    if (s.queued || s.frameCb) { if (s.frameCb) s.wantFrame = true; return; }
    s.queued = true;
    queueMicrotask(() => { s.queued = false; draw(s); flush(); });
  }

  function draw(s: Surf) {
    if (!stats.alive || !s.configured || !s.W || !surfaces.has(s.id)) return;
    if (s.frameCb) { s.wantFrame = true; return; }
    const animating = s.kind === 'toplevel' && win.animating;
    if (animating && api.tick) api.tick(performance.now());
    const BW = s.W * s.scale, BH = s.H * s.scale;

    // this frame's damage, in buffer pixels
    let rects: Rect[] = [];
    if (s.full) rects = [[0, 0, BW, BH]];
    else {
      for (const [x, y, w, h] of s.damage) {
        const x0 = Math.max(0, Math.floor(x * s.scale)), y0 = Math.max(0, Math.floor(y * s.scale));
        const x1 = Math.min(BW, Math.ceil((x + w) * s.scale)), y1 = Math.min(BH, Math.ceil((y + h) * s.scale));
        if (x1 > x0 && y1 > y0) rects.push([x0, y0, x1 - x0, y1 - y0]);
      }
    }
    const real = rects.length > 12 ? [bbox(rects)] : rects;
    // expired damage outlines are repainted clean (and not outlined again)
    rects = real.concat(s.flashes);
    s.flashes = [];
    if (rects.length > 12) rects = [bbox(rects)];

    if (!rects.length) {
      // nothing changed: keep an animation's clock running with a bare
      // frame request (no attach, so no COMMIT and no release)
      if (animating) { req(s.id, 3, [s.frameCb = newId('wl_callback')]); req(s.id, 6); }
      s.damage = [];
      return;
    }
    const buf = s.bufs.find((b) => !b.held);
    if (!buf) { s.wantFrame = true; return; } // all held: draw on the next release
    s.wantFrame = false;
    s.damage = [];
    s.full = false;

    // paint the whole scene (cheap in Canvas 2D), copy what this buffer missed
    const ctx = s.ctx!;
    ctx.setTransform(s.scale, 0, 0, s.scale, 0, 0);
    ctx.clearRect(0, 0, s.W, s.H);
    s.paint(ctx, s.W, s.H);
    for (const b of s.bufs) if (b !== buf) b.missed.push(...rects);
    const copy = buf.missed.concat(rects);
    buf.missed = [];
    for (const r of copy.length > 12 ? [bbox(copy)] : copy) copyRect(ctx, buf.u32, BW, r);
    if (debug.damage) {
      // outline this frame's real damage in this buffer only; the next
      // buffers repaint it clean anyway (it is in their `missed`), and a
      // timer damages it again once it has been seen
      for (const r of real) outline(buf.u32, BW, r);
      const gen = s.gen;
      setTimeout(() => {
        if (s.gen !== gen || !stats.alive) return;
        s.flashes.push(...real);
        schedule(s);
        flush();
      }, 180);
    }

    if (s.scaleSent !== s.scale) { req(s.id, 8, [s.scale]); s.scaleSent = s.scale; }
    if (s === top && api.inputRegion) sendInputRegion(api.inputRegion(s.W, s.H));
    req(s.id, 3, [s.frameCb = newId('wl_callback')]);
    req(s.id, 1, [buf.id, 0, 0]);
    for (const r of rects) req(s.id, 9, r);
    if (s === top && g.presentation && api.presented) req(g.presentation, 1, [s.id, newId('wp_presentation_feedback')]);
    req(s.id, 6);
    buf.held = true;
    stats.frames++;
    stats.commits++;
    for (const [, , w, h] of rects) stats.bytes += w * h * 4;
  }

  // set_input_region through a throwaway wl_region, when it changed
  let inputKey = '';
  function sendInputRegion(shape: { add: readonly Rect[]; subtract?: readonly Rect[] }) {
    const key = JSON.stringify(shape);
    if (key === inputKey) return;
    inputKey = key;
    const region = newId('wl_region');
    req(g.compositor, 1, [region]);
    for (const r of shape.add) req(region, 1, r.map(Math.round));
    for (const r of shape.subtract ?? []) req(region, 2, r.map(Math.round));
    req(top!.id, 5, [region]);
    req(region, 0);
  }

  function onConfigure(s: Surf, serial: number) {
    req(s.xsurf, 4, [serial]); // ack_configure
    let w = s.pending.w, h = s.pending.h;
    if (s.kind === 'toplevel') {
      const was = win.maximized || win.fullscreen;
      win.maximized = s.pending.states.includes(1);
      win.fullscreen = s.pending.states.includes(2);
      chrome = app.frameless || win.fullscreen ? 0 : TITLE_H;
      if (!was && (win.maximized || win.fullscreen) && s.W) floating = { w: s.W, h: s.H };
      if (was && !win.maximized && !win.fullscreen && !w && floating) ({ w, h } = floating);
      w = Math.max(w || s.W || app.width, app.minWidth || 160);
      h = Math.max(h || s.H || app.height, app.minHeight || 120);
    }
    s.configured = true;
    if (w !== s.W || h !== s.H || !s.pool) { s.W = w; s.H = h; allocate(s); }
    s.full = true;
    draw(s);
  }

  function setScale(s: Surf, scale: number) {
    scale = Math.max(1, Math.min(4, scale | 0));
    if (scale === s.scale) return;
    s.scale = scale;
    if (s.configured) { allocate(s); draw(s); }
  }

  // --- the toplevel and its decorations ------------------------------------
  let top: Surf | null = null;
  let api: Partial<AppInstance> = {};
  let ptr: { surface: Surf | null; x: number; y: number; serial: number; enterSerial: number; cursor: string | CursorImage } =
    { surface: null, x: 0, y: 0, serial: 0, enterSerial: 0, cursor: '' };
  let lastDown = 0;
  let hover: Zone = '';  // decoration under the pointer: '', 'max', 'close', 'title', 'content', 'edge'
  let mods = 0;
  let inputSerial = 0;
  let popup: Surf | null = null;

  const win = {
    maximized: false, fullscreen: false, activated: false, animating: false,
    get width() { return top ? top.W : app.width; },
    get height() { return top ? top.H - chrome : app.height; },
    get scale() { return top ? top.scale : 1; },
  };

  // the title bar's height: none for frameless apps and fullscreen windows
  let chrome = app.frameless ? 0 : TITLE_H;
  let floating: { w: number; h: number } | null = null; // the size before maximize/fullscreen
  const buttons = (): { close: Rect; max: Rect } => ({ close: [top!.W - 36, 7, 26, 24], max: [top!.W - 66, 7, 26, 24] });
  const inBox = (x: number, y: number, [bx, by, bw, bh]: Rect) => x >= bx && x < bx + bw && y >= by && y < by + bh;

  function edgeAt(x: number, y: number) {
    if (win.maximized || win.fullscreen) return 0;
    let e = 0;
    if (y < EDGE) e |= 1; else if (y >= top!.H - EDGE) e |= 2;
    if (x < EDGE) e |= 4; else if (x >= top!.W - EDGE) e |= 8;
    return e;
  }

  function paintTop(ctx: Ctx, W: number, H: number) {
    // frameless: the app paints every pixel, alpha included
    if (app.frameless) { api.paint!(ctx, W, H); return; }
    // fullscreen: no decorations, the content fills the surface
    if (!chrome) { ctx.fillStyle = theme().bg; ctx.fillRect(0, 0, W, H); api.paint!(ctx, W, H); return; }
    const r = win.maximized ? 0 : RADIUS;
    const t = theme();
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(0, 0, W, H, r);
    ctx.clip();
    if (!app.frameless) {
      ctx.fillStyle = t.bg;
      ctx.fillRect(0, 0, W, H);
      ctx.fillStyle = t.chrome;
      ctx.fillRect(0, 0, W, TITLE_H);
      ctx.fillStyle = t.border;
      ctx.fillRect(0, TITLE_H - 1, W, 1);
      // title
      ctx.font = `500 13px ${FONT}`;
      ctx.textBaseline = 'middle';
      ctx.fillStyle = win.activated ? t.fg : t.muted;
      ctx.fillText(app.title || app.name, 14, TITLE_H / 2 + 0.5);
      // buttons
      const b = buttons();
      for (const [name, box] of Object.entries(b)) {
        const [bx, by, bw, bh] = box;
        if (hover === name) {
          ctx.fillStyle = name === 'close' ? '#e5484d' : t.hover;
          ctx.beginPath(); ctx.roundRect(bx, by, bw, bh, 6); ctx.fill();
        }
        ctx.strokeStyle = hover === name && name === 'close' ? '#fff' : (win.activated ? t.fg : t.muted);
        ctx.lineWidth = 1.25;
        const cx = bx + bw / 2, cy = by + bh / 2;
        ctx.beginPath();
        if (name === 'close') { ctx.moveTo(cx - 4, cy - 4); ctx.lineTo(cx + 4, cy + 4); ctx.moveTo(cx + 4, cy - 4); ctx.lineTo(cx - 4, cy + 4); }
        else if (win.maximized) { ctx.rect(cx - 3, cy - 2, 7, 7); ctx.moveTo(cx - 1, cy - 4); ctx.lineTo(cx + 6, cy - 4); ctx.lineTo(cx + 6, cy + 3); }
        else ctx.rect(cx - 4.5, cy - 4.5, 9, 9);
        ctx.stroke();
      }
    }
    // content
    ctx.save();
    ctx.translate(0, chrome);
    ctx.beginPath();
    ctx.rect(0, 0, W, H - chrome);
    ctx.clip();
    api.paint!(ctx, W, H - chrome);
    ctx.restore();
    ctx.restore();
    // hairline border
    if (!win.maximized) {
      ctx.strokeStyle = t.border;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.roundRect(0.5, 0.5, W - 1, H - 1, r);
      ctx.stroke();
    }
  }

  function setCursor(name: CursorName | CursorImage) {
    if (!ptr.surface || ptr.cursor === name) return;
    if (typeof name !== 'string') {
      if (!g.pointer) return;
      ptr.cursor = name;
      req(g.pointer, 0, [ptr.enterSerial, cursorSurface(name), name.hotX, name.hotY]); // set_cursor
      return;
    }
    if (!g.cursorDev) return;
    ptr.cursor = name;
    req(g.cursorDev, 1, [ptr.enterSerial, CURSORS[name] || 1]);
  }

  // a client-drawn cursor: a role-less wl_surface with one buffer, painted
  // once (at the window's scale) and kept for the next set_cursor
  const cursorSurfaces = new Map<CursorImage, number>();
  function cursorSurface(c: CursorImage): number {
    const known = cursorSurfaces.get(c);
    if (known) return known;
    const sc = top ? top.scale : 1;
    const BW = c.width * sc, BH = c.height * sc, size = BW * BH * 4;
    const id = newId('wl_surface');
    req(g.compositor, 0, [id]);
    const pool = newId('wl_shm_pool'), file = new ArrayBuffer(size);
    req(g.shm, 0, [pool, size]);
    outFds.push(file);
    const buf = newId('wl_buffer');
    req(pool, 0, [buf, 0, BW, BH, BW * 4, ARGB8888]);
    req(pool, 1);
    const ctx = new OffscreenCanvas(BW, BH).getContext('2d', { willReadFrequently: true })!;
    ctx.setTransform(sc, 0, 0, sc, 0, 0);
    c.paint(ctx, c.width, c.height);
    copyRect(ctx, new Uint32Array(file), BW, [0, 0, BW, BH]);
    if (sc !== 1) req(id, 8, [sc]);
    req(id, 1, [buf, 0, 0]);
    req(id, 9, [0, 0, BW, BH]);
    req(id, 6);
    cursorSurfaces.set(c, id);
    return id;
  }

  const invalidateTitle = () => top && invalidate(top, [0, 0, top.W, TITLE_H]);

  function setHover(h: Zone) {
    if (h === hover) return;
    const chromeChanged = ['max', 'close'].includes(h) || ['max', 'close'].includes(hover);
    hover = h;
    if (chromeChanged) invalidateTitle();
  }

  // pointer on the toplevel, surface-local coordinates. The app sees content
  // coordinates; a press in the content captures moves and the release even
  // when they wander over the decorations.
  let captured = false;
  const btn = (b: number): 0 | 1 | 2 => (b === BTN_LEFT ? 0 : b === BTN_RIGHT ? 2 : 1);
  function topPointer(type: Exclude<PointerType, 'wheel'>, x: number, y: number, button: number) {
    const toApp = (t: PointerType) =>
      api.pointer?.({ type: t, x, y: y - chrome, button: btn(button), shift: !!(mods & MOD_SHIFT), dx: 0, dy: 0 });
    if (type === 'leave') {
      if (hover === 'content' || captured) toApp('leave');
      captured = false;
      setHover('');
      return;
    }
    if (captured) {
      toApp(type);
      if (type === 'up') captured = false;
      return;
    }
    const edge = edgeAt(x, y);
    const b = chrome ? buttons() : null;
    let zone: Zone = 'content';
    if (edge) zone = 'edge';
    else if (b && inBox(x, y, b.close)) zone = 'close';
    else if (b && inBox(x, y, b.max)) zone = 'max';
    else if (chrome && y < TITLE_H) zone = 'title';

    const wasContent = hover === 'content';
    setHover(zone);
    if (zone !== 'content') {
      if (wasContent) toApp('leave');
      setCursor(zone === 'edge' ? EDGE_CURSOR[edge] : 'default');
      if (type !== 'down' || button !== BTN_LEFT) return;
      if (zone === 'edge') return req(top!.role, 6, [g.seat, inputSerial, edge]);  // resize
      if (zone === 'close') return close('closed by its close button');
      if (zone === 'max') return toggleMaximize();
      const now = performance.now();                                              // title
      if (now - lastDown < 350) { lastDown = 0; return toggleMaximize(); }
      lastDown = now;
      return req(top!.role, 5, [g.seat, inputSerial]);                            // move
    }
    if (!wasContent) setCursor('default'); // the app's move handler may pick another
    if (type === 'down') captured = true;
    toApp(type);
  }

  function setFocus(on: boolean) {
    if (on === win.activated) return;
    win.activated = on;
    api.focus?.(on);
    invalidateTitle();
  }

  // --- text input (zwp_text_input_v3): apps with `textInput` enable it while
  // focused; the page shows the on-screen keyboard only then. Composed text
  // (commit_string) and deletions arrive on done and reach the app as keys.
  const text = { commit: '', deleteBefore: 0 };
  function enableTextInput() {
    req(g.textInput, 1); // enable
    const c = api.caret?.();
    if (c) req(g.textInput, 6, [Math.round(c[0]), Math.round(c[1] + chrome), Math.max(1, Math.round(c[2])), Math.max(1, Math.round(c[3]))]);
    req(g.textInput, 7); // commit
  }
  function textDone() {
    const plain = { shift: false, ctrl: false, alt: false, meta: false };
    for (let i = 0; i < text.deleteBefore; i++) api.key?.({ key: 'Backspace', text: '', ...plain });
    if (text.commit) api.key?.({ key: text.commit, text: text.commit, ...plain });
    text.commit = '';
    text.deleteBefore = 0;
  }

  function toggleMaximize() { req(top!.role, win.maximized ? 10 : 9); }
  // set_fullscreen(output: null) / unset_fullscreen
  function setFullscreen(on: boolean) { if (on) req(top!.role, 11, [0]); else req(top!.role, 12); }

  // --- popups ----------------------------------------------------------------
  /** Open a menu-like popup at content coordinates (x, y). opts: { width,
   *  height, paint(ctx, w, h), pointer?(ev), key?(ev) → true when handled }.
   *  Returns { close(), invalidate(rect?) }. One popup at a time. */
  function openPopup(x: number, y: number, opts: PopupOptions): PopupHandle {
    closePopup();
    const s = createSurface('popup', opts.paint);
    s.pointer = opts.pointer || null;
    s.key = opts.key || null;
    const pos = newId('xdg_positioner');
    req(g.wm, 1, [pos]);
    req(pos, 1, [opts.width, opts.height]);                                    // set_size
    req(pos, 2, [Math.round(x), Math.round(y) + chrome, 1, 1]);                // set_anchor_rect
    req(pos, 3, [5]);                                                          // anchor: top_left
    req(pos, 4, [8]);                                                          // gravity: bottom_right
    req(pos, 5, [1 | 2 | 4 | 8]);                                              // slide + flip
    s.role = newId('xdg_popup');
    req(s.xsurf, 2, [s.role, top!.xsurf, pos]);                                // get_popup
    req(pos, 0);
    req(s.role, 1, [g.seat, inputSerial]);                                     // grab
    s.scale = top!.scale;
    s.pending = { w: opts.width, h: opts.height, states: [] };
    req(s.id, 6);                                                              // initial commit
    popup = s;
    flush();
    return {
      close: () => { if (popup === s) closePopup(); },
      invalidate: (rect) => invalidate(s, rect),
    };
  }

  function closePopup() {
    if (!popup) return;
    const s = popup;
    popup = null;
    if (ptr.surface === s) ptr.surface = null;
    destroySurface(s);
    flush();
  }

  // --- keys ------------------------------------------------------------------
  function onKey(code: number, pressed: boolean) {
    if (!pressed) return;
    const entry = KEYMAP[code];
    if (!entry) return;
    const shift = !!(mods & MOD_SHIFT), caps = !!(mods & MOD_CAPS);
    let key = entry[0];
    if (entry.length === 2) {
      const upper = entry[1];
      const letter = key.length === 1 && key >= 'a' && key <= 'z';
      key = (letter ? shift !== caps : shift) ? upper : key;
    }
    const ev: AppKeyEvent = {
      key, text: key.length === 1 && !(mods & (MOD_CTRL | MOD_ALT | MOD_LOGO)) ? key : '',
      shift, ctrl: !!(mods & MOD_CTRL), alt: !!(mods & MOD_ALT), meta: !!(mods & MOD_LOGO),
    };
    if (popup) {
      if (key === 'Escape') { closePopup(); return; }
      if (popup.key && popup.key(ev)) return;
    }
    api.key?.(ev);
  }

  // --- events ------------------------------------------------------------------
  function handle(bytes: Uint8Array, fds: ClientFd[]) {
    wlEach(bytes, (obj, op, r) => {
      const iface = objects.get(obj);
      if (!stats.alive) return;
      switch (`${iface}.${op}`) {
        case 'wl_display.0': {
          const o = r.u32(), code = r.u32(), msg = r.str();
          evt(iface, obj, op, `${o}, ${code}, "${msg}"`);
          close(`protocol error ${code}: ${msg}`);
          return;
        }
        case 'wl_display.1': { const id = r.u32(); objects.delete(id); evt(iface, obj, op, String(id)); break; }
        case 'wl_registry.0': {
          const name = r.u32(), i = r.str(), version = r.u32();
          globals[i] = { name, version };
          evt(iface, obj, op, `${name}, "${i}", ${version}`);
          break;
        }
        case 'wl_callback.0': {
          evt(iface, obj, op);
          if (obj === g.sync) { g.sync = 0; setup(); break; }
          for (const s of surfaces.values()) {
            if (s.frameCb !== obj) continue;
            s.frameCb = 0;
            if (s.wantFrame || s.full || s.damage.length || s.flashes.length || (s === top && win.animating)) draw(s);
          }
          break;
        }
        case 'xdg_wm_base.0': { const serial = r.u32(); evt(iface, obj, op, String(serial)); req(g.wm, 3, [serial]); break; }
        case 'xdg_toplevel.0': {
          const w = r.i32(), h = r.i32();
          const states = [...new Uint32Array(r.array().slice().buffer)];
          top!.pending = { w, h, states };
          evt(iface, obj, op, `${w}, ${h}, [${states.map((x) => STATE[x] || x).join(', ')}]`);
          break;
        }
        case 'xdg_toplevel.1': evt(iface, obj, op); close('closed by the compositor'); return;
        case 'xdg_popup.0': {
          const x = r.i32(), y = r.i32(), w = r.i32(), h = r.i32();
          evt(iface, obj, op, `${x}, ${y}, ${w}, ${h}`);
          const s = [...surfaces.values()].find((v) => v.role === obj);
          if (s) s.pending = { w: w || s.pending.w, h: h || s.pending.h, states: [] };
          break;
        }
        case 'xdg_popup.1': {
          evt(iface, obj, op);
          if (popup && popup.role === obj) closePopup();
          break;
        }
        case 'xdg_surface.0': {
          const serial = r.u32();
          evt(iface, obj, op, String(serial));
          const s = [...surfaces.values()].find((v) => v.xsurf === obj);
          if (s) onConfigure(s, serial);
          break;
        }
        case 'wl_surface.2': {
          const scale = r.i32();
          evt(iface, obj, op, String(scale));
          const s = surfaces.get(obj);
          if (s) setScale(s, scale);
          break;
        }
        case 'wl_seat.0': {
          const caps = r.u32();
          evt(iface, obj, op, String(caps));
          if (caps & 1 && !g.pointer) {
            req(g.seat, 0, [g.pointer = newId('wl_pointer')]);
            if (g.cursorMgr) req(g.cursorMgr, 1, [g.cursorDev = newId('wp_cursor_shape_device_v1'), g.pointer]);
            if (g.relMgr) req(g.relMgr, 1, [g.relPtr = newId('zwp_relative_pointer_v1'), g.pointer]);
          }
          if (caps & 2 && !g.keyboard) req(g.seat, 1, [g.keyboard = newId('wl_keyboard')]);
          break;
        }
        case 'wl_buffer.0': {
          evt(iface, obj, op);
          for (const s of surfaces.values()) {
            const b = s.bufs.find((x) => x.id === obj);
            if (!b) continue;
            b.held = false;
            if (s.wantFrame && !s.frameCb) draw(s);
          }
          break;
        }
        case 'wl_pointer.0': {
          const serial = r.u32(), sid = r.u32(), x = r.fixed(), y = r.fixed();
          evt(iface, obj, op, `${serial}, ${sid}, ${x.toFixed(1)}, ${y.toFixed(1)}`);
          ptr = { ...ptr, surface: surfaces.get(sid) || null, x, y, enterSerial: serial, cursor: '' };
          pointerEvent('move', x, y);
          break;
        }
        case 'wl_pointer.1': {
          const serial = r.u32(), sid = r.u32();
          evt(iface, obj, op, `${serial}, ${sid}`);
          pointerEvent('leave', ptr.x, ptr.y);
          ptr.surface = null;
          break;
        }
        case 'wl_pointer.2': {
          r.u32();
          const x = r.fixed(), y = r.fixed();
          evt(iface, obj, op, `${x.toFixed(1)}, ${y.toFixed(1)}`);
          ptr.x = x; ptr.y = y;
          pointerEvent('move', x, y);
          break;
        }
        case 'wl_pointer.3': {
          const serial = r.u32(); r.u32();
          const button = r.u32(), state = r.u32();
          evt(iface, obj, op, `${serial}, 0x${button.toString(16)}, ${state ? 'pressed' : 'released'}`);
          inputSerial = serial;
          pointerEvent(state ? 'down' : 'up', ptr.x, ptr.y, button);
          break;
        }
        case 'wl_pointer.4': {
          r.u32();
          const axis = r.u32(), value = r.fixed();
          evt(iface, obj, op, `${axis ? 'horizontal' : 'vertical'}, ${value.toFixed(1)}`);
          pointerEvent('wheel', ptr.x, ptr.y, 0, axis ? 0 : value, axis ? value : 0);
          break;
        }
        case 'zwp_relative_pointer_v1.0': {
          r.u32(); r.u32();
          const dx = r.fixed(), dy = r.fixed();
          evt(iface, obj, op, `${dx.toFixed(2)}, ${dy.toFixed(2)}`);
          api.relative?.(dx, dy);
          break;
        }
        case 'zwp_locked_pointer_v1.0': evt(iface, obj, op); if (obj === g.lock) api.locked?.(true); break;
        case 'zwp_locked_pointer_v1.1': {
          // a oneshot lock is over for good: drop the object
          evt(iface, obj, op);
          if (obj === g.lock) { req(g.lock, 0); g.lock = 0; api.locked?.(false); }
          break;
        }
        case 'wp_presentation_feedback.1': {
          const hi = r.u32(), lo = r.u32(), nsec = r.u32(), refresh = r.u32();
          r.u32(); r.u32();
          const flags = r.u32();
          const ms = (hi * 2 ** 32 + lo) * 1000 + nsec / 1e6;
          evt(iface, obj, op, `${ms.toFixed(3)} ms, refresh ${refresh}, flags 0x${flags.toString(16)}`);
          api.presented?.({ ms, refresh: refresh / 1e6, discarded: false });
          break;
        }
        case 'wp_presentation_feedback.2': evt(iface, obj, op); api.presented?.({ ms: 0, refresh: 0, discarded: true }); break;
        case 'wl_keyboard.0': evt(iface, obj, op, `xkb_v1, fd (${fds[0]?.keymap?.length ?? 0} bytes)`); break;
        // keyboard focus is what the title bar and the app show as "focused"
        // (the core's configure marks every toplevel activated)
        case 'wl_keyboard.1': {
          inputSerial = r.u32();
          const sid = r.u32();
          evt(iface, obj, op, `${inputSerial}, ${sid}`);
          if (top && sid === top.id) setFocus(true);
          break;
        }
        case 'wl_keyboard.2': {
          r.u32();
          const sid = r.u32();
          evt(iface, obj, op, String(sid));
          mods = 0;
          if (top && sid === top.id) setFocus(false);
          break;
        }
        case 'zwp_text_input_v3.0': {
          const sid = r.u32();
          evt(iface, obj, op, String(sid));
          if (top && sid === top.id) enableTextInput();
          break;
        }
        case 'zwp_text_input_v3.3': {
          text.commit = r.str();
          evt(iface, obj, op, JSON.stringify(text.commit));
          break;
        }
        case 'zwp_text_input_v3.4': {
          text.deleteBefore = r.u32(); r.u32();
          evt(iface, obj, op, String(text.deleteBefore));
          break;
        }
        case 'zwp_text_input_v3.5': evt(iface, obj, op); textDone(); break;
        case 'wl_keyboard.3': {
          inputSerial = r.u32(); r.u32();
          const key = r.u32(), state = r.u32();
          evt(iface, obj, op, `${inputSerial}, ${key}, ${state ? 'pressed' : 'released'}`);
          onKey(key, state === 1);
          break;
        }
        case 'wl_keyboard.4': {
          r.u32();
          const depressed = r.u32(), latched = r.u32(), locked = r.u32();
          mods = depressed | latched | locked;
          evt(iface, obj, op, `${depressed}, ${latched}, ${locked}`);
          break;
        }
        default:
          if (iface && EVT[iface]) evt(iface, obj, op);
      }
    });
  }

  function pointerEvent(type: PointerType, x: number, y: number, button = 0, dy = 0, dx = 0) {
    const s = ptr.surface;
    if (!s) return;
    if (s === top) {
      if (type === 'wheel') api.pointer?.({ type, x, y: y - chrome, button: 0, shift: !!(mods & MOD_SHIFT), dx, dy });
      else topPointer(type, x, y, button);
    } else if (s === popup && s.pointer) {
      if (type === 'move') setCursor('default');
      s.pointer({ type, x, y, button: button === BTN_LEFT ? 0 : button === BTN_RIGHT ? 2 : 1, shift: !!(mods & MOD_SHIFT), dx, dy });
    }
  }

  function setup() {
    g.compositor = bind('wl_compositor', 6);
    g.shm = bind('wl_shm', 1);
    g.wm = bind('xdg_wm_base', 3);
    g.seat = bind('wl_seat', 5);
    g.cursorMgr = bind('wp_cursor_shape_manager_v1', 1);
    g.constraints = bind('zwp_pointer_constraints_v1', 1);
    g.relMgr = bind('zwp_relative_pointer_manager_v1', 1);
    g.presentation = bind('wp_presentation', 1);
    if (app.textInput) {
      g.textMgr = bind('zwp_text_input_manager_v3', 1);
      if (g.textMgr) req(g.textMgr, 1, [g.textInput = newId('zwp_text_input_v3'), g.seat]);
    }
    top = createSurface('toplevel', paintTop);
    top.role = newId('xdg_toplevel');
    req(top.xsurf, 1, [top.role]);
    req(top.role, 2, [app.title || app.name]);
    req(top.role, 3, [`dev.wland.demo.${app.id}`]);
    req(top.role, 8, [app.minWidth || 160, app.minHeight || 120]);
    api = app.create(windowApi, env.services || {}) || {};
    req(top.id, 6); // initial commit → configure
  }

  // --- the app's handle ------------------------------------------------------
  const windowApi: WindowApi = {
    get width() { return win.width; },
    get height() { return win.height; },
    get scale() { return win.scale; },
    get focused() { return win.activated; },
    get maximized() { return win.maximized; },
    get fullscreen() { return win.fullscreen; },
    /** Repaint: a content-space rect, or everything. */
    invalidate(rect) {
      if (!top) return;
      invalidate(top, rect ? [rect[0], rect[1] + chrome, rect[2], rect[3]] : undefined);
    },
    /** Call tick(ms) before every frame while on (frame callbacks pace it). */
    animate(on) {
      win.animating = !!on;
      if (on && top) schedule(top);
    },
    cursor(name) { if (ptr.surface === top && hover === 'content') setCursor(name); },
    popup: openPopup,
    closePopup,
    move() { req(top!.role, 5, [g.seat, inputSerial]); flush(); },
    maximize() { toggleMaximize(); flush(); },
    setMaximized(on) { req(top!.role, on ? 9 : 10); flush(); },
    setFullscreen(on) { setFullscreen(on); flush(); },
    minimize() { req(top!.role, 13); flush(); },
    lockPointer(rect) {
      if (!g.constraints || !g.pointer || g.lock || !top) return false;
      let region = 0;
      if (rect) {
        req(g.compositor, 1, [region = newId('wl_region')]);
        req(region, 1, [Math.round(rect[0]), Math.round(rect[1] + chrome), Math.round(rect[2]), Math.round(rect[3])]);
      }
      req(g.constraints, 1, [g.lock = newId('zwp_locked_pointer_v1'), top.id, g.pointer, region, 1]); // oneshot
      if (region) req(region, 0);
      flush();
      return true;
    },
    unlockPointer() {
      if (!g.lock) return;
      req(g.lock, 0);
      g.lock = 0;
      api.locked?.(false);
      flush();
    },
    close: () => close('closed by the app'),
    setTitle(t) { app = { ...app, title: t }; req(top!.role, 2, [t]); invalidateTitle(); flush(); },
  };

  function close(reason: string) {
    if (!stats.alive) return;
    stats.alive = false;
    stats.reason = reason;
    api.closed?.();
    sock!.close(); // an app that exits just hangs up
    env.onExit?.(client);
  }

  function flush() {
    if (!out.length || !stats.alive || writing) return;
    const bytes = new Uint8Array(out.reduce((n, x) => n + x.length, 0));
    let off = 0;
    for (const x of out) { bytes.set(x, off); off += x.length; }
    out.length = 0;
    const fds = outFds;
    outFds = [];
    // the relay may answer synchronously (a wl_buffer.release); events wait
    // until this write is done so requests never interleave
    writing = true;
    try { sock!.write(bytes, fds); } finally { writing = false; }
    while (inbox.length) { const [b, f] = inbox.shift()!; handle(b, f); }
    if (out.length) flush();
  }

  const client: Client = {
    app, stats, conn: 0,
    get title() { return app.title || app.name; },
    receive(bytes, fds) {
      if (!stats.alive) return;
      if (writing) { inbox.push([bytes, fds]); return; }
      handle(bytes, fds);
      flush();
    },
    killed(reason) {
      if (!stats.alive) return;
      stats.alive = false;
      stats.reason = reason;
      api.closed?.();
      env.onExit?.(client);
    },
    close: () => close('closed by the page'),
    /** Repaint every surface (the page's theme changed). */
    repaint() {
      for (const s of surfaces.values()) invalidate(s);
      flush();
    },
  };

  sock = relay.connect(client);
  client.conn = sock.id;
  req(1, 1, [g.registry = newId('wl_registry')]);
  req(1, 0, [g.sync = newId('wl_callback')]);
  flush();
  return client;
}

const STATE: Record<number, string> = { 1: 'maximized', 2: 'fullscreen', 3: 'resizing', 4: 'activated' };

// request args for the trace: numbers, "strings", arrays by length
const fmtArgs = (args: readonly WlArg[]) => args.map((a) => (typeof a === 'number' ? a : typeof a === 'string' ? `"${a}"` : `[${a.array.length} bytes]`)).join(', ');

function bbox(rects: readonly Rect[]): Rect {
  let x0 = Infinity, y0 = Infinity, x1 = 0, y1 = 0;
  for (const [x, y, w, h] of rects) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x + w); y1 = Math.max(y1, y + h); }
  return [x0, y0, x1 - x0, y1 - y0];
}

// canvas RGBA (u32 0xAABBGGRR) → ARGB8888 (u32 0xAARRGGBB)
function copyRect(ctx: Ctx, dst: Uint32Array, BW: number, [x, y, w, h]: Rect) {
  const src = new Uint32Array(ctx.getImageData(x, y, w, h).data.buffer);
  for (let row = 0; row < h; row++) {
    let si = row * w, di = (y + row) * BW + x;
    for (const end = si + w; si < end; si++, di++) {
      const v = src[si];
      dst[di] = (v & 0xff00ff00) | ((v & 0xff) << 16) | ((v >>> 16) & 0xff);
    }
  }
}

// the damage overlay: a 2px outline, drawn into the buffer after the copy
function outline(dst: Uint32Array, BW: number, [x, y, w, h]: Rect) {
  const c = 0xffff3d8b >>> 0;
  const line = (yy: number) => { if (yy >= y && yy < y + h) dst.fill(c, yy * BW + x, yy * BW + x + w); };
  for (let i = 0; i < 2; i++) { line(y + i); line(y + h - 1 - i); }
  for (let yy = y; yy < y + h; yy++) {
    for (let i = 0; i < Math.min(2, w); i++) { dst[yy * BW + x + i] = c; dst[yy * BW + x + w - 1 - i] = c; }
  }
}

export const FONT = '"Geist", ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif';
export const MONO = '"Geist Mono", ui-monospace, SFMono-Regular, Menlo, monospace';

// The apps' palette follows the page's theme (a client would read a
// settings portal; these read a data attribute the page sets).
export function theme(): Theme {
  const dark = typeof document === 'undefined' || document.documentElement.dataset.theme !== 'light';
  return dark
    ? { bg: '#0a0a0a', chrome: '#111111', fg: '#ededed', muted: '#8f8f8f', faint: '#3a3a3a', border: 'rgba(255,255,255,0.12)', hover: 'rgba(255,255,255,0.08)', accent: '#3b82f6', card: '#161616', dark: true }
    : { bg: '#ffffff', chrome: '#fafafa', fg: '#171717', muted: '#6b6b6b', faint: '#d4d4d4', border: 'rgba(0,0,0,0.10)', hover: 'rgba(0,0,0,0.05)', accent: '#2563eb', card: '#f5f5f5', dark: false };
}
