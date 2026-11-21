// Drawing helpers shared by the demo apps: a popup menu (an xdg_popup), a
// flat button, and text measurement. Everything paints with Canvas 2D in the
// app's logical coordinates; the toolkit scales for HiDPI.
import { FONT, MONO, theme as toolkitTheme } from '../wayland/toolkit.ts';
import type { Ctx, PopupHandle, Rect, Theme, WindowApi } from '../wayland/app-types.ts';

export { FONT, MONO };
/** The apps' palette, typed on this side so the apps don't depend on how
 *  toolkit.ts annotates it. */
export const theme: () => Theme = toolkitTheme;

export interface MenuItem {
  label: string;
  hint?: string;
  checked?: boolean;
  danger?: boolean;
  action(): void;
}

const ITEM_H = 30, PAD = 5;

/** A context menu as an xdg_popup at content (x, y). items: [{ label, hint?,
 *  checked?, danger?, action() } | '-']. */
export function menu(win: WindowApi, x: number, y: number, items: (MenuItem | '-')[], { width = 200 }: { width?: number } = {}): PopupHandle {
  let hover = -1;
  const opened = performance.now();
  const rows = items.map((it) => (it === '-' ? 9 : ITEM_H));
  const height = rows.reduce((a, b) => a + b, 0) + PAD * 2;
  const rowAt = (py: number): number => {
    let top = PAD;
    for (let i = 0; i < items.length; i++) {
      if (py >= top && py < top + rows[i]) return items[i] === '-' ? -1 : i;
      top += rows[i];
    }
    return -1;
  };
  const pick = (i: number) => {
    const it = items[i];
    if (!it || it === '-') return;
    p.close();
    it.action();
  };
  const p = win.popup(x, y, {
    width, height,
    paint(ctx, w, h) {
      const t = theme();
      ctx.fillStyle = t.dark ? '#151515' : '#ffffff';
      ctx.beginPath(); ctx.roundRect(0.5, 0.5, w - 1, h - 1, 8); ctx.fill();
      ctx.strokeStyle = t.border; ctx.lineWidth = 1; ctx.stroke();
      let top = PAD;
      ctx.textBaseline = 'middle';
      items.forEach((it, i) => {
        if (it === '-') {
          ctx.fillStyle = t.border;
          ctx.fillRect(PAD, top + 4, w - PAD * 2, 1);
          top += 9;
          return;
        }
        if (i === hover) {
          ctx.fillStyle = t.hover;
          ctx.beginPath(); ctx.roundRect(PAD, top, w - PAD * 2, ITEM_H, 5); ctx.fill();
        }
        ctx.font = `400 13px ${FONT}`;
        ctx.fillStyle = it.danger ? '#e5484d' : t.fg;
        ctx.fillText(it.label, PAD + 26, top + ITEM_H / 2 + 0.5);
        if (it.checked) {
          ctx.strokeStyle = t.fg; ctx.lineWidth = 1.5;
          ctx.beginPath();
          ctx.moveTo(PAD + 9, top + 15); ctx.lineTo(PAD + 12, top + 18); ctx.lineTo(PAD + 18, top + 11);
          ctx.stroke();
        }
        if (it.hint) {
          ctx.font = `400 11px ${MONO}`;
          ctx.fillStyle = t.muted;
          const tw = ctx.measureText(it.hint).width;
          ctx.fillText(it.hint, w - PAD - 10 - tw, top + ITEM_H / 2 + 0.5);
        }
        top += ITEM_H;
      });
    },
    pointer(ev) {
      if (ev.type === 'move' || ev.type === 'leave') {
        const h = ev.type === 'leave' ? -1 : rowAt(ev.y);
        if (h !== hover) { hover = h; p.invalidate(); }
      } else if (ev.type === 'down' && ev.button === 0) pick(rowAt(ev.y));
      // press-drag-release: the press opened the menu, the release picks
      else if (ev.type === 'up' && performance.now() - opened > 250) pick(rowAt(ev.y));
    },
    key(ev) {
      const step = (d: number) => {
        let i = hover;
        for (let n = 0; n < items.length; n++) {
          i = (i + d + items.length) % items.length;
          if (items[i] !== '-') break;
        }
        hover = i;
        p.invalidate();
      };
      if (ev.key === 'ArrowDown') step(1);
      else if (ev.key === 'ArrowUp') step(-1);
      else if (ev.key === 'Enter') pick(hover);
      else return false;
      return true;
    },
  });
  return p;
}

/** A flat button; returns its box for hit-testing. */
export function button(
  ctx: Ctx, x: number, y: number, label: string,
  { active = false, hover = false, w, mono = false }: { active?: boolean; hover?: boolean; w?: number; mono?: boolean } = {},
): Rect {
  const t = theme();
  ctx.font = `500 12px ${mono ? MONO : FONT}`;
  const width = w ?? Math.ceil(ctx.measureText(label).width) + 20;
  ctx.fillStyle = active ? t.fg : hover ? t.hover : 'transparent';
  ctx.beginPath(); ctx.roundRect(x + 0.5, y + 0.5, width - 1, 25, 6); ctx.fill();
  if (!active) { ctx.strokeStyle = t.border; ctx.lineWidth = 1; ctx.stroke(); }
  ctx.fillStyle = active ? t.bg : t.fg;
  ctx.textBaseline = 'middle';
  ctx.fillText(label, x + (width - ctx.measureText(label).width) / 2, y + 13.5);
  return [x, y, width, 26];
}

export const hit = (x: number, y: number, box: Rect | null | undefined): boolean => !!box && x >= box[0] && x < box[0] + box[2] && y >= box[1] && y < box[1] + box[3];

/** Drag-to-scroll with a fling, for touch (the lib delivers a touch as a
 *  left-button press) and for mouse drags alike. The app feeds it presses
 *  and moves, owns the scroll value (`get`/`set` clamp), and runs `tick`
 *  from its own tick while `flinging` (win.animate). */
export interface Scroller {
  /** A drag passed the slop: the press is a scroll, not a tap. */
  readonly dragging: boolean;
  /** Still gliding after a flick. */
  readonly flinging: boolean;
  down(y: number): void;
  /** True while this move scrolled (the app should not treat it as hover). */
  move(y: number): boolean;
  /** Ends the press; true if it was a drag (so not a tap). */
  up(): boolean;
  tick(ms: number): void;
  stop(): void;
}

export function scroller(get: () => number, set: (v: number) => void): Scroller {
  const SLOP = 6;
  let pressed = false, dragging = false, flinging = false;
  let startY = 0, startScroll = 0, v = 0, last = 0;
  let samples: [t: number, y: number][] = [];
  return {
    get dragging() { return dragging; },
    get flinging() { return flinging; },
    down(y) {
      flinging = false;
      pressed = true;
      dragging = false;
      startY = y;
      startScroll = get();
      samples = [[performance.now(), y]];
    },
    move(y) {
      if (!pressed) return false;
      if (!dragging && Math.abs(y - startY) < SLOP) return false;
      dragging = true;
      set(startScroll - (y - startY));
      const now = performance.now();
      samples.push([now, y]);
      while (samples.length > 2 && now - samples[0][0] > 100) samples.shift();
      return true;
    },
    up() {
      const was = dragging;
      if (dragging && samples.length > 1) {
        const [t0, y0] = samples[0], [t1, y1] = samples[samples.length - 1];
        const idle = performance.now() - t1 > 60; // held still before lifting: no fling
        v = idle || t1 === t0 ? 0 : -(y1 - y0) / (t1 - t0); // px per ms
        flinging = Math.abs(v) > 0.15;
        last = performance.now();
      }
      pressed = dragging = false;
      return was;
    },
    tick(ms) {
      if (!flinging) return;
      const dt = Math.min(50, ms - last);
      last = ms;
      const before = get();
      set(before + v * dt);
      v *= Math.pow(0.994, dt); // ~0.9 per 16 ms frame
      if (Math.abs(v) < 0.02 || get() === before) flinging = false;
    },
    stop() { flinging = false; pressed = dragging = false; },
  };
}
