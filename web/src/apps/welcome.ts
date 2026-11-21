// Welcome — the introduction to wland, on one screen that never scrolls: the
// layout drops what doesn't fit the window instead. Its centre is the
// pipeline (clients → relay → link → core → view) drawn live: frames travel
// one way, and the pointer and key events this window receives travel back.
// Below it, four things to try that tick off as they happen. What it
// exercises: frame-paced animation with small damage (only the pipeline's
// band repaints each frame), cursor shapes, an xdg_popup context menu,
// keyboard focus, and xdg_toplevel maximize.
import type { AppModule, Ctx, Rect, Theme } from '../wayland/app-types.ts';
import { FONT, MONO, theme, menu, hit } from './ui.ts';

const REPO = 'https://github.com/pithings/wland';
const MAXW = 640;
const FRAMES = '#3b82f6', INPUT = '#f59e0b', OK = '#10b981';

const H1 = ['Wayland apps,', 'composited in the browser.'];
const P_FULL = 'wland is a Wayland compositor compiled to WebAssembly, ~50 kB gzipped in total. Apps speak the real wire protocol, share pixels through buffers, and show up as windows in a web page. This window is one of them.';
const P_SHORT = 'A Wayland compositor compiled to WebAssembly. Real clients, real protocol, windows in a web page.';

const STAGES: { name: string; what: string; here: string; prod: string }[] = [
  { name: 'Clients', what: 'Wayland apps, each on its own connection', here: 'imaginary apps, in JS', prod: 'foot, GTK, any app' },
  { name: 'Relay', what: 'owns the socket and the fds', here: 'relay.ts, in this tab', prod: 'wland relay (Zig)' },
  { name: 'Link', what: 'carries STREAM v2 frames', here: 'in-page byte stream', prod: 'WebSocket, vsock' },
  { name: 'Core', what: 'the compositor', here: 'WebAssembly', prod: 'WebAssembly' },
  { name: 'View', what: 'windows in the DOM', here: 'Canvas 2D or WebGL', prod: 'Canvas 2D or WebGL' },
];

type TryId = 'resize' | 'popup' | 'key' | 'sketch';
const TRIES: { id: TryId; label: string; tag: string }[] = [
  { id: 'resize', label: 'Resize me', tag: 'xdg_toplevel' },
  { id: 'popup', label: 'Right-click', tag: 'xdg_popup' },
  { id: 'key', label: 'Press a key', tag: 'wl_keyboard' },
  { id: 'sketch', label: 'Draw in Sketch', tag: 'wl_pointer' },
];

// The badge, longest first: the first that fits is shown.
const BADGE = ['No DOM: a Wayland client in this tab draws this window', 'No DOM: Wayland client pixels'];

const BUTTONS = [{ label: 'View on GitHub', primary: true }];

const F = {
  p: `400 14px ${FONT}`, small: `400 13px ${FONT}`, strong: `500 13px ${FONT}`,
  mono: `400 11px ${MONO}`, kicker: `500 10.5px ${MONO}`, node: `500 12px ${FONT}`,
};
const h1Font = (size: number) => `600 ${size}px ${FONT}`;
const h1Spacing = (size: number) => `${(-size * 0.035).toFixed(2)}px`;

const measure = new OffscreenCanvas(1, 1).getContext('2d')!;
function width(text: string, font: string, ls = '0px'): number {
  measure.font = font;
  measure.letterSpacing = ls;
  return measure.measureText(text).width;
}
function wrap(text: string, font: string, maxW: number): string[] {
  const out: string[] = [];
  let line = '';
  for (const word of text.split(' ')) {
    const next = line ? `${line} ${word}` : word;
    if (line && width(next, font) > maxW) { out.push(line); line = word; } else line = next;
  }
  if (line) out.push(line);
  return out;
}

// --- layout ------------------------------------------------------------------
// Everything is placed for one window size. Sections that don't fit are
// dropped, least important first; spare height goes to the pipeline.
interface Layout {
  x0: number;
  cw: number;
  badge: number | null; // top
  h1: { y: number; size: number; lh: number; lines: string[] };
  p: { y: number; lines: string[] } | null;
  pipe: {
    box: Rect; nodes: number[]; cy: number; r: number;
    /** What repaints every frame: the rails, the packets and the nodes. */
    band: Rect;
    /** Top of the caption; null when it was dropped. */
    caption: number | null;
    /** "here" and "prod" on one line. */
    oneLine: boolean;
  } | null;
  tiles: { boxes: Rect[]; tags: boolean } | null;
  buttons: Rect[];
  stats: boolean;
}

const LEVELS = 7; // how many things can be given up, in order (see `fit`)

function layout(W: number, H: number): Layout {
  const side = W < 460 ? 20 : 32;
  const cw = Math.min(MAXW, W - side * 2);
  const x0 = (W - cw) / 2;
  const narrow = cw < 460;

  const size = [36, 32, 28, 25, 22, 20].find((s) => width(H1[1], h1Font(s), h1Spacing(s)) <= cw) ?? 18;
  const lh = Math.round(size * 1.16);
  const r = narrow ? 14 : 17;
  const oneLine = width(`HERE  ${STAGES[0].here}     PROD  ${STAGES[0].prod}`, F.mono) + 40 <= cw;
  const captionH = oneLine ? 50 : 66;
  const btnW = BUTTONS.map((b) => Math.ceil(width(b.label, F.strong)) + (b.primary ? 48 : 30));
  const tileCols = 2, tileGap = 8, tileH = 40;
  const tileW = (cw - tileGap * (tileCols - 1)) / tileCols;

  const fit = (level: number) => {
    const on = { roomy: level < 1, full: level < 2, badge: level < 3, tiles: level < 4, p: level < 5, caption: level < 6, pipe: level < 7 };
    const k = on.roomy ? 1 : 0.6;
    const pad = Math.round((narrow ? 24 : 32) * (on.roomy ? 1 : 0.7));
    const pLines = wrap(on.full ? P_FULL : P_SHORT, F.p, cw);
    const rows: [key: string, h: number, gapBefore: number][] = [];
    if (on.badge) rows.push(['badge', 26, 0]);
    rows.push(['h1', lh * 2, 18 * k]);
    if (on.p) rows.push(['p', pLines.length * 22, 12 * k]);
    if (on.pipe) rows.push(['pipe', 34 + r * 2 + 36 + (on.caption ? captionH : 6), 22 * k]);
    if (on.tiles) rows.push(['tiles', tileH * 2 + tileGap, 14 * k]);
    rows.push(['buttons', 36, 22 * k]);
    rows[0][2] = 0;
    const total = pad * 2 + rows.reduce((a, [, h, g]) => a + h + g, 0);
    return { on, pad, pLines, rows, total };
  };
  let f = fit(0);
  for (let level = 1; level <= LEVELS && f.total > H; level++) f = fit(level);

  const spare = Math.max(0, H - f.total);
  const grow = f.on.pipe ? Math.min(spare, 56) : 0;
  let y = f.pad + (spare - grow) / 2;
  const L: Layout = {
    x0, cw, badge: null, h1: { y: 0, size, lh, lines: H1 }, p: null, pipe: null, tiles: null, buttons: [],
    stats: false,
  };
  for (const [key, h, gap] of f.rows) {
    y += gap;
    if (key === 'badge') L.badge = y;
    else if (key === 'h1') L.h1.y = y;
    else if (key === 'p') L.p = { y, lines: f.pLines };
    else if (key === 'pipe') {
      const ph = h + grow;
      const inset = narrow ? 30 : 46;
      const top = y + 34, bottom = y + ph - (f.on.caption ? captionH : 6);
      const cy = Math.round((top + bottom) / 2 - 9);
      L.pipe = {
        box: [x0, y, cw, ph], r, cy,
        nodes: STAGES.map((_, i) => x0 + inset + ((cw - inset * 2) * i) / (STAGES.length - 1)),
        band: [x0 + 1, cy - r - 6, cw - 2, r * 2 + 12],
        caption: f.on.caption ? bottom : null,
        oneLine,
      };
      y += grow;
    } else if (key === 'tiles') {
      L.tiles = {
        boxes: TRIES.map((_, i) => [x0 + (i % tileCols) * (tileW + tileGap), y + Math.floor(i / tileCols) * (tileH + tileGap), tileW, tileH]),
        tags: TRIES.every((t) => 38 + width(t.label, F.small) + 16 + width(t.tag, F.mono) + 14 + 12 <= tileW),
      };
    } else {
      let x = x0;
      L.buttons = btnW.map((w) => { const b: Rect = [x, y, w, 36]; x += w + 10; return b; });
      L.stats = x + 150 <= x0 + cw;
    }
    y += h;
  }
  return L;
}

// --- drawing -------------------------------------------------------------------
const STROKE = 1.3;
/** A stage's glyph, centred on (cx, cy), about 12px across. */
function glyph(ctx: Ctx, i: number, cx: number, cy: number) {
  ctx.beginPath();
  switch (i) {
    case 0: // clients: a window
      ctx.roundRect(cx - 6, cy - 5, 12, 10, 2);
      ctx.moveTo(cx - 6, cy - 1.5); ctx.lineTo(cx + 6, cy - 1.5);
      break;
    case 1: // relay: both ways
      ctx.moveTo(cx - 5.5, cy - 3); ctx.lineTo(cx + 5.5, cy - 3); ctx.moveTo(cx + 2.5, cy - 6); ctx.lineTo(cx + 5.5, cy - 3); ctx.lineTo(cx + 2.5, cy);
      ctx.moveTo(cx + 5.5, cy + 3); ctx.lineTo(cx - 5.5, cy + 3); ctx.moveTo(cx - 2.5, cy); ctx.lineTo(cx - 5.5, cy + 3); ctx.lineTo(cx - 2.5, cy + 6);
      break;
    case 2: // link: a wave
      ctx.moveTo(cx - 6.5, cy);
      ctx.bezierCurveTo(cx - 4, cy - 7, cx - 2.5, cy - 7, cx, cy);
      ctx.bezierCurveTo(cx + 2.5, cy + 7, cx + 4, cy + 7, cx + 6.5, cy);
      break;
    case 3: // core: a chip
      ctx.roundRect(cx - 4, cy - 4, 8, 8, 1.5);
      for (const d of [-2, 2]) {
        ctx.moveTo(cx + d, cy - 4); ctx.lineTo(cx + d, cy - 6.5); ctx.moveTo(cx + d, cy + 4); ctx.lineTo(cx + d, cy + 6.5);
        ctx.moveTo(cx - 4, cy + d); ctx.lineTo(cx - 6.5, cy + d); ctx.moveTo(cx + 4, cy + d); ctx.lineTo(cx + 6.5, cy + d);
      }
      break;
    default: // view: a screen
      ctx.roundRect(cx - 6.5, cy - 5.5, 13, 9, 1.5);
      ctx.moveTo(cx, cy + 3.5); ctx.lineTo(cx, cy + 6); ctx.moveTo(cx - 3, cy + 6); ctx.lineTo(cx + 3, cy + 6);
  }
  ctx.stroke();
}

/** A packet on a rail: frames go right (dir 1), input comes back (dir -1). */
interface Packet { dir: 1 | -1; t: number; speed: number }

type Hover = '' | `node:${number}` | `tile:${number}` | `btn:${number}`;

// --- the app ---------------------------------------------------------------------
const app: AppModule = {
  id: 'welcome',
  name: 'Welcome',
  title: 'Welcome to wland',
  blurb: 'What wland is, with the pipeline running live',
  width: 640, height: 600, minWidth: 340, minHeight: 300,
  create(win, services) {
    const born = performance.now();
    let cache: (Layout & { key: string }) | null = null;
    let hover: Hover = '';
    let stage = 0;          // the stage the caption describes
    let stageAt = born;     // when it last changed (the tour moves on by itself)
    let pinned = false;     // hovering a stage holds the tour
    const done: Record<TryId, boolean> = { resize: false, popup: false, key: false, sketch: false };
    let lastKey = '';
    let size: [number, number] | null = null;
    const packets: Packet[] = [];
    let last = born, nextFrame = born + 200, lastInput = 0;
    let stats = '';
    const layer = new OffscreenCanvas(1, 1), layerCtx = layer.getContext('2d')!;
    let layerKey = '';
    // Phones (and anyone who asked for less motion) get the light version:
    // the pipeline sends one frame per beat and animates at half rate, and
    // the window stops asking for frames whenever nothing is in flight.
    const lite = matchMedia('(pointer: coarse), (prefers-reduced-motion: reduce)').matches;
    let running = false, painted = 0;
    const wake = () => {
      if (running) return;
      running = true;
      last = performance.now();
      win.animate(true);
    };

    const lay = () => {
      const key = `${win.width}:${win.height}:${document.fonts?.status}`; // web fonts change metrics
      if (cache?.key !== key) cache = { key, ...layout(win.width, win.height) };
      return cache;
    };
    const check = (id: TryId) => {
      if (done[id]) return;
      done[id] = true;
      win.invalidate();
    };
    const setStage = (i: number, now = performance.now()) => {
      stageAt = now;
      if (i === stage) return;
      stage = i;
      const p = lay().pipe;
      if (p) win.invalidate(p.box);
    };
    /** An event reached this client: send a packet back down the pipeline. */
    const input = (burst = 1) => {
      const now = performance.now();
      if (burst === 1 && now - lastInput < 70) return;
      lastInput = now;
      for (let i = 0; i < burst && packets.length < 48; i++) packets.push({ dir: -1, t: -i * 0.05, speed: 1 / 1100 });
      wake();
    };
    const statsText = () => {
      const m = services.metrics?.();
      return m ? `${m.clients} client${m.clients === 1 ? "" : "s"} · ${m.fps} fps · ${win.scale}×` : '';
    };

    function contextMenu(x: number, y: number) {
      check('popup');
      menu(win, x, y, [
        { label: 'Open Sketch', action: () => { check('sketch'); services.open?.('sketch'); } },
        { label: 'Open Pulse', action: () => services.open?.('pulse') },
        '-',
        { label: win.maximized ? 'Restore' : 'Maximize', action: () => win.maximize() },
        { label: 'GitHub ↗', action: () => window.open(REPO, '_blank', 'noopener') },
      ], { width: 190 });
    }
    function act(h: Hover, x: number, y: number) {
      const [kind, n] = h.split(':');
      const i = +n;
      if (kind === 'node') { pinned = true; setStage(i); }
      else if (kind === 'btn') window.open(REPO, '_blank', 'noopener');
      else if (kind === 'tile') {
        const id = TRIES[i].id;
        if (id === 'resize') win.maximize();
        else if (id === 'popup') contextMenu(x, y);
        else if (id === 'sketch') { check('sketch'); services.open?.('sketch'); }
      }
    }
    function target(x: number, y: number): Hover {
      const L = lay();
      const b = L.buttons.findIndex((box) => hit(x, y, box));
      if (b >= 0) return `btn:${b}`;
      const t = L.tiles ? L.tiles.boxes.findIndex((box) => hit(x, y, box)) : -1;
      if (t >= 0) return `tile:${t}`;
      const p = L.pipe;
      if (p) {
        const half = Math.min(44, (p.nodes[1] - p.nodes[0]) / 2);
        const n = p.nodes.findIndex((nx) => hit(x, y, [nx - half, p.cy - p.r - 8, half * 2, p.r * 2 + 36]));
        if (n >= 0) return `node:${n}`;
      }
      return '';
    }

    /** Everything that holds still between events. It is drawn once into
     *  `layer` and blitted each frame, so an animation frame costs a copy
     *  and the pipeline's band, not the whole scene's text and shapes. */
    function still(ctx: Ctx, w: number, h: number, t: Theme, L: Layout) {
      const { x0, cw } = L;
      ctx.fillStyle = t.bg;
      ctx.fillRect(0, 0, w, h);
      ctx.textBaseline = 'middle';
      ctx.letterSpacing = '0px';
      const subtle = t.dark ? '#6f6f6f' : '#8f8f8f';

      if (L.badge !== null) {
        ctx.font = F.small;
        const y = L.badge, label = BADGE.find((s) => ctx.measureText(s).width + 36 <= cw) ?? BADGE[BADGE.length - 1];
        const bw = Math.min(cw, ctx.measureText(label).width + 36);
        ctx.strokeStyle = t.border; ctx.lineWidth = 1;
        ctx.beginPath(); ctx.roundRect(x0 + 0.5, y + 0.5, bw - 1, 25, 13); ctx.stroke();
        ctx.fillStyle = OK + '33';
        ctx.beginPath(); ctx.arc(x0 + 14, y + 13, 6, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = OK;
        ctx.beginPath(); ctx.arc(x0 + 14, y + 13, 3, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = t.muted;
        ctx.fillText(label, x0 + 25, y + 13.5);
      }

      // headline: the second line carries the pipeline's two colours
      ctx.font = h1Font(L.h1.size);
      ctx.letterSpacing = h1Spacing(L.h1.size);
      ctx.fillStyle = t.fg;
      ctx.fillText(L.h1.lines[0], x0, L.h1.y + L.h1.lh / 2);
      const hw = ctx.measureText(L.h1.lines[1]).width;
      const grad = ctx.createLinearGradient(x0, 0, x0 + hw, 0);
      grad.addColorStop(0, t.dark ? '#60a5fa' : '#2563eb');
      grad.addColorStop(0.55, t.dark ? '#a78bfa' : '#7c3aed');
      grad.addColorStop(1, t.dark ? '#fbbf24' : '#d97706');
      ctx.fillStyle = grad;
      ctx.fillText(L.h1.lines[1], x0, L.h1.y + L.h1.lh * 1.5);
      ctx.letterSpacing = '0px';

      if (L.p) {
        ctx.font = F.p;
        ctx.fillStyle = t.muted;
        L.p.lines.forEach((l, i) => ctx.fillText(l, x0, L.p!.y + i * 22 + 11));
      }

      const P = L.pipe;
      if (P) {
        const [px, py, pw, ph] = P.box;
        const panel = t.dark ? '#0f0f0f' : '#fafafa';
        ctx.save();
        ctx.beginPath(); ctx.roundRect(px + 0.5, py + 0.5, pw - 1, ph - 1, 12);
        ctx.fillStyle = panel; ctx.fill();
        ctx.clip();
        // a dot grid, fading towards the edges
        ctx.fillStyle = t.dark ? 'rgba(255,255,255,0.07)' : 'rgba(0,0,0,0.08)';
        for (let gy = py + 10; gy < py + ph; gy += 14) for (let gx = px + 10; gx < px + pw; gx += 14) ctx.fillRect(gx, gy, 1, 1);
        const glow = ctx.createRadialGradient(px + pw / 2, P.cy, 0, px + pw / 2, P.cy, pw * 0.55);
        glow.addColorStop(0, t.dark ? 'rgba(59,130,246,0.10)' : 'rgba(37,99,235,0.06)');
        glow.addColorStop(1, 'rgba(59,130,246,0)');
        ctx.fillStyle = glow;
        ctx.fillRect(px, py, pw, ph);
        ctx.restore();
        ctx.strokeStyle = t.border; ctx.lineWidth = 1;
        ctx.beginPath(); ctx.roundRect(px + 0.5, py + 0.5, pw - 1, ph - 1, 12); ctx.stroke();

        // header: what this is, and what the two colours are
        ctx.font = F.kicker;
        ctx.letterSpacing = '0.7px';
        ctx.fillStyle = subtle;
        ctx.fillText('HOW IT WORKS', px + 16, py + 19);
        ctx.letterSpacing = '0px';
        ctx.font = F.mono;
        const legend: [string, string][] = [['frames →', FRAMES], ['← your input', INPUT]];
        let lx = px + pw - 16;
        for (const [text, c] of legend.reverse()) {
          lx -= ctx.measureText(text).width;
          ctx.fillStyle = t.muted;
          ctx.fillText(text, lx, py + 19);
          ctx.fillStyle = c;
          ctx.beginPath(); ctx.arc(lx - 8, py + 18.5, 3, 0, Math.PI * 2); ctx.fill();
          lx -= 28;
        }

        // the names; the nodes themselves are drawn live
        ctx.font = F.node;
        P.nodes.forEach((nx, i) => {
          ctx.fillStyle = i === stage || hover === `node:${i}` ? t.fg : t.muted;
          const name = STAGES[i].name;
          ctx.fillText(name, nx - ctx.measureText(name).width / 2, P.cy + P.r + 15);
        });

        if (P.caption !== null) {
          const s = STAGES[stage], cy = P.caption;
          ctx.fillStyle = t.border;
          ctx.fillRect(px + 1, cy, pw - 2, 1);
          ctx.font = F.strong;
          ctx.fillStyle = t.fg;
          ctx.fillText(s.name, px + 16, cy + 17);
          const nw = ctx.measureText(s.name).width;
          ctx.font = F.small;
          ctx.fillStyle = t.muted;
          ctx.fillText(s.what, px + 16 + nw + 8, cy + 17);
          const pair = (label: string, value: string, c: string, x: number, y: number): number => {
            ctx.font = F.kicker; ctx.letterSpacing = '0.6px';
            ctx.fillStyle = c;
            ctx.fillText(label, x, y);
            const lw = ctx.measureText(label).width;
            ctx.letterSpacing = '0px';
            ctx.font = F.mono;
            ctx.fillStyle = t.dark ? '#b4b4b4' : '#4a4a4a';
            ctx.fillText(value, x + lw + 8, y);
            return x + lw + 8 + ctx.measureText(value).width;
          };
          const end = pair('HERE', s.here, OK, px + 16, cy + 36);
          if (P.oneLine) pair('PROD', s.prod, subtle, end + 22, cy + 36);
          else pair('PROD', s.prod, subtle, px + 16, cy + 52);
        }
      }

      if (L.tiles) {
        L.tiles.boxes.forEach(([x, y, tw, th], i) => {
          const it = TRIES[i], ok = done[it.id], hot = hover === `tile:${i}` && it.id !== 'key';
          ctx.beginPath(); ctx.roundRect(x + 0.5, y + 0.5, tw - 1, th - 1, 9);
          ctx.fillStyle = hot ? t.hover : ok ? OK + (t.dark ? '14' : '10') : 'transparent';
          ctx.fill();
          ctx.strokeStyle = ok ? OK + '66' : t.border; ctx.lineWidth = 1; ctx.stroke();
          const cx = x + 19, cy = y + th / 2;
          if (ok) {
            ctx.fillStyle = OK;
            ctx.beginPath(); ctx.arc(cx, cy, 7.5, 0, Math.PI * 2); ctx.fill();
            ctx.strokeStyle = t.dark ? '#0a0a0a' : '#ffffff'; ctx.lineWidth = 1.6; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
            ctx.beginPath(); ctx.moveTo(cx - 3.2, cy + 0.2); ctx.lineTo(cx - 0.8, cy + 2.6); ctx.lineTo(cx + 3.4, cy - 2.4); ctx.stroke();
            ctx.lineCap = 'butt';
          } else {
            ctx.strokeStyle = t.faint; ctx.lineWidth = 1.2;
            ctx.beginPath(); ctx.arc(cx, cy, 7, 0, Math.PI * 2); ctx.stroke();
          }
          ctx.font = F.small;
          ctx.fillStyle = t.fg;
          ctx.fillText(it.label, x + 36, cy + 0.5);
          if (L.tiles!.tags) {
            const tag = it.id === 'key' && lastKey ? lastKey : it.tag;
            ctx.font = F.mono;
            const gw = ctx.measureText(tag).width + 14;
            ctx.fillStyle = t.hover;
            ctx.beginPath(); ctx.roundRect(x + tw - gw - 10, cy - 10, gw, 20, 5); ctx.fill();
            ctx.fillStyle = ok ? t.fg : t.muted;
            ctx.fillText(tag, x + tw - gw - 3, cy + 0.5);
          }
        });
      }

      L.buttons.forEach(([x, y, bw, bh], i) => {
        const { label, primary } = BUTTONS[i], hot = hover === `btn:${i}`;
        ctx.font = F.strong;
        ctx.beginPath(); ctx.roundRect(x + 0.5, y + 0.5, bw - 1, bh - 1, 8);
        if (primary) {
          ctx.globalAlpha = hot ? 0.88 : 1;
          ctx.fillStyle = t.fg; ctx.fill();
          ctx.globalAlpha = 1;
          ctx.fillStyle = t.bg;
          ctx.fillText(label, x + 15, y + bh / 2 + 0.5);
          const ax = x + bw - 23 + (hot ? 2 : 0), ay = y + bh / 2;
          ctx.strokeStyle = t.bg; ctx.lineWidth = 1.4; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
          ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(ax + 9, ay); ctx.moveTo(ax + 5, ay - 4); ctx.lineTo(ax + 9, ay); ctx.lineTo(ax + 5, ay + 4); ctx.stroke();
          ctx.lineCap = 'butt';
        } else {
          ctx.fillStyle = hot ? t.hover : 'transparent'; ctx.fill();
          ctx.strokeStyle = t.border; ctx.lineWidth = 1; ctx.stroke();
          ctx.fillStyle = t.fg;
          ctx.fillText(label, x + 15, y + bh / 2 + 0.5);
        }
      });
      if (L.stats && stats) {
        ctx.font = F.mono;
        ctx.fillStyle = subtle;
        ctx.fillText(stats, x0 + cw - ctx.measureText(stats).width, L.buttons[0][1] + 18.5);
      }
    }

    /** The pipeline's band: rails, then packets, then the nodes over them. */
    function live(ctx: Ctx, P: NonNullable<Layout['pipe']>, t: Theme) {
      const panel = t.dark ? '#0f0f0f' : '#fafafa';
      const a = P.nodes[0], b = P.nodes[P.nodes.length - 1];
      const rail = (dir: 1 | -1) => P.cy - dir * 4;
      ctx.strokeStyle = t.border; ctx.lineWidth = 1;
      for (const d of [1, -1] as const) { ctx.beginPath(); ctx.moveTo(a, rail(d) + 0.5); ctx.lineTo(b, rail(d) + 0.5); ctx.stroke(); }
      const near = P.nodes.map(() => [0, 0]); // how close a packet of each kind is
      ctx.lineCap = 'round';
      for (const pk of packets) {
        if (pk.t < 0 || pk.t > 1) continue;
        const c = pk.dir === 1 ? FRAMES : INPUT;
        const x = pk.dir === 1 ? a + (b - a) * pk.t : b - (b - a) * pk.t, y = rail(pk.dir) + 0.5;
        const tail = x - pk.dir * 26;
        const g = ctx.createLinearGradient(tail, 0, x, 0);
        g.addColorStop(0, c + '00'); g.addColorStop(1, c);
        ctx.strokeStyle = g; ctx.lineWidth = 2;
        ctx.beginPath(); ctx.moveTo(tail, y); ctx.lineTo(x, y); ctx.stroke();
        ctx.fillStyle = c + '40';
        ctx.beginPath(); ctx.arc(x, y, 5, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = c;
        ctx.beginPath(); ctx.arc(x, y, 2.2, 0, Math.PI * 2); ctx.fill();
        P.nodes.forEach((nx, i) => {
          const k = 1 - Math.abs(x - nx) / (P.r + 22);
          if (k > near[i][pk.dir === 1 ? 0 : 1]) near[i][pk.dir === 1 ? 0 : 1] = k;
        });
      }
      ctx.lineCap = 'butt';
      P.nodes.forEach((nx, i) => {
        const active = i === stage, hot = hover === `node:${i}`;
        const [kf, ki] = near[i];
        if (kf > 0 || ki > 0) { // a packet is passing through
          const c = kf >= ki ? FRAMES : INPUT, k = Math.max(kf, ki);
          ctx.fillStyle = c + Math.round(k * 46).toString(16).padStart(2, '0');
          ctx.beginPath(); ctx.arc(nx, P.cy, P.r + 5, 0, Math.PI * 2); ctx.fill();
        }
        ctx.fillStyle = active ? t.fg : panel;
        ctx.beginPath(); ctx.arc(nx, P.cy, P.r, 0, Math.PI * 2); ctx.fill();
        ctx.strokeStyle = active ? t.fg : hot ? t.muted : t.dark ? 'rgba(255,255,255,0.22)' : 'rgba(0,0,0,0.20)';
        ctx.lineWidth = 1;
        ctx.beginPath(); ctx.arc(nx, P.cy, P.r - 0.5, 0, Math.PI * 2); ctx.stroke();
        ctx.strokeStyle = active ? t.bg : hot ? t.fg : t.muted;
        ctx.lineWidth = STROKE; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
        glyph(ctx, i, nx, P.cy);
        ctx.lineCap = 'butt';
      });
    }

    const frame = () => packets.length < 48 && packets.push({ dir: 1, t: 0, speed: 1 / (lite ? 1300 : 1700) });
    const beat = lite ? setInterval(() => {
      if (document.hidden) return;
      if (!pinned) setStage((stage + 1) % STAGES.length);
      frame();
      wake();
    }, 3200) : 0;
    frame();
    wake();

    return {
      closed() { clearInterval(beat); win.animate(false); },
      tick(now) {
        const dt = Math.min(64, now - last);
        last = now;
        const L = lay();
        // frames leave the clients at an uneven, lively pace
        if (!lite && now >= nextFrame) {
          frame();
          nextFrame = now + 240 + Math.random() * 420;
        }
        for (let i = packets.length - 1; i >= 0; i--) {
          packets[i].t += packets[i].speed * dt;
          if (packets[i].t > 1.08) packets.splice(i, 1);
        }
        if (!lite && !pinned && now - stageAt > 3200) setStage((stage + 1) % STAGES.length, now);
        const s = statsText();
        if (s !== stats) {
          stats = s;
          if (L.stats) win.invalidate([L.x0, L.buttons[0][1], L.cw, 36]);
        }
        const idle = lite && !packets.length; // the last frame clears the band, then rest
        if (idle) { running = false; win.animate(false); }
        if (L.pipe && (!lite || idle || now - painted >= 30)) { painted = now; win.invalidate(L.pipe.band); }
      },
      paint(ctx, w, h) {
        // a resize, once the window has settled into its first size
        if (!size || performance.now() - born < 1500) size = [w, h];
        else if (size[0] !== w || size[1] !== h) { size = [w, h]; done.resize = true; }
        const t = theme(), L = lay();
        const key = [L.key, win.scale, t.dark, stage, hover, lastKey, stats, ...Object.values(done)].join('|');
        if (key !== layerKey) {
          layerKey = key;
          const bw = w * win.scale, bh = h * win.scale;
          if (layer.width !== bw || layer.height !== bh) { layer.width = bw; layer.height = bh; }
          layerCtx.setTransform(win.scale, 0, 0, win.scale, 0, 0);
          still(layerCtx, w, h, t, L);
        }
        ctx.drawImage(layer, 0, 0, w, h);
        if (L.pipe) live(ctx, L.pipe, t);
      },
      pointer(ev) {
        if (ev.type === 'leave') {
          pinned = false;
          if (hover) { hover = ''; win.invalidate(); }
          return;
        }
        if (ev.type === 'wheel') { input(); return; }
        const h = target(ev.x, ev.y);
        if (ev.type === 'move') {
          input();
          if (h !== hover) { hover = h; win.invalidate(); }
          // hovering a stage holds the tour on it
          pinned = h.startsWith('node:');
          if (pinned) setStage(+h.slice(5));
          win.cursor(h && h !== `tile:${TRIES.findIndex((t) => t.id === 'key')}` ? 'pointer' : 'default');
          return;
        }
        if (ev.type !== 'down') return;
        input(3);
        if (ev.button === 2) { contextMenu(ev.x, ev.y); return; }
        if (ev.button === 0 && h) act(h, ev.x, ev.y);
      },
      key(ev) {
        input(3);
        lastKey = ev.key === ' ' ? 'Space' : ev.key.length === 1 ? ev.key.toUpperCase() : ev.key;
        done.key = true;
        win.invalidate();
        if (ev.key === 'ArrowRight') setStage((stage + 1) % STAGES.length);
        else if (ev.key === 'ArrowLeft') setStage((stage + STAGES.length - 1) % STAGES.length);
      },
    };
  },
};
export default app;
