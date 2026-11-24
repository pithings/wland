// Lab — the compositor's newer features, one card each, to try by hand.
// Window states: buttons (and keys) for xdg_toplevel set_fullscreen /
// unset_fullscreen, set_maximized / unset_maximized and set_minimized; the
// window reacts to the configure that follows (fullscreen drops the title
// bar and fills the desktop) and shows the states it was given.
// Cursor surface: hovering a swatch sets a cursor the client drew itself
// (a role-less wl_surface given to wl_pointer.set_cursor, hotspot included).
// Pointer lock: a click in the pad asks for a oneshot
// zwp_locked_pointer_v1 over it; while locked the dot moves by
// zwp_relative_pointer_v1 deltas (the pointer itself stays put), Esc or a
// second click releases it. Touch: the pad takes raw wl_touch points and
// draws each live, with its id; counts frames and cancels. The footer counts wp_presentation feedback
// for the window's own commits.
import type { AppModule, CursorImage, Ctx, Rect } from '../wayland/app-types.ts';
import { FONT, MONO, theme, button, hit } from './ui.ts';

const PAD = 16, MAXW = 560;
const TOUCH_COLORS = ['#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#a855f7'];

// client-drawn cursors: a target ring (hotspot in the middle) and an arrow
// in the accent colour (hotspot at its tip)
const CURSORS: { label: string; image: CursorImage }[] = [
  {
    label: 'Ring', image: {
      width: 32, height: 32, hotX: 16, hotY: 16,
      paint(ctx) {
        ctx.lineWidth = 4; ctx.strokeStyle = '#ffffff';
        ctx.beginPath(); ctx.arc(16, 16, 11, 0, Math.PI * 2); ctx.stroke();
        ctx.lineWidth = 2; ctx.strokeStyle = '#ef4444';
        ctx.beginPath(); ctx.arc(16, 16, 11, 0, Math.PI * 2); ctx.stroke();
        ctx.fillStyle = '#ffffff'; ctx.beginPath(); ctx.arc(16, 16, 3.5, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = '#ef4444'; ctx.beginPath(); ctx.arc(16, 16, 2, 0, Math.PI * 2); ctx.fill();
      },
    },
  },
  {
    label: 'Arrow', image: {
      width: 24, height: 32, hotX: 2, hotY: 2,
      paint(ctx) {
        ctx.beginPath();
        ctx.moveTo(2, 2); ctx.lineTo(2, 26); ctx.lineTo(8, 20); ctx.lineTo(12, 29);
        ctx.lineTo(16, 27); ctx.lineTo(12, 18); ctx.lineTo(20, 18); ctx.closePath();
        ctx.fillStyle = '#10b981'; ctx.fill();
        ctx.lineWidth = 1.5; ctx.strokeStyle = '#ffffff'; ctx.lineJoin = 'round'; ctx.stroke();
      },
    },
  },
];

const app: AppModule = {
  id: 'lab',
  name: 'Lab',
  blurb: 'Window states, cursor surfaces, touch, pointer lock, presentation',
  width: 480, height: 610, minWidth: 360, minHeight: 220,
  create(win) {
    let boxes: Record<string, Rect> = {};
    let hover = '';
    // pointer lock pad
    let pad: Rect | null = null;
    let swatches: Rect[] = [];
    let lockState: 'off' | 'asked' | 'locked' = 'off';
    const dot = { x: 0.5, y: 0.5 }; // in the pad, 0..1
    let last = [0, 0], total = [0, 0], moves = 0;
    // touch pad: the points down (content coordinates), frames and cancels
    let touchPad: Rect | null = null;
    const points = new Map<number, [x: number, y: number]>();
    const tstats = { frames: 0, cancels: 0, max: 0 };
    // presentation feedback
    const pres = { presented: 0, discarded: 0, lastMs: 0, interval: 0, refresh: 0 };
    let footY = 0;
    // the counters change with every commit: show them once a second
    const timer = setInterval(() => win.invalidate([0, footY, win.width, 20]), 1000);

    const actions: Record<string, () => void> = {
      fullscreen: () => win.setFullscreen(!win.fullscreen),
      maximize: () => win.setMaximized(!win.maximized),
      minimize: () => win.minimize(),
    };

    function title(ctx: Ctx, x: number, y: number, text: string, tag: string) {
      const t = theme();
      ctx.textBaseline = 'alphabetic';
      ctx.font = `600 13px ${FONT}`;
      ctx.fillStyle = t.fg;
      ctx.fillText(text, x, y);
      const tw = ctx.measureText(text).width;
      ctx.font = `400 11px ${MONO}`;
      ctx.fillStyle = t.muted;
      ctx.fillText(tag, x + tw + 8, y);
    }

    function line(ctx: Ctx, x: number, y: number, text: string, font = `400 12px ${FONT}`, color = theme().muted) {
      ctx.textBaseline = 'alphabetic';
      ctx.font = font;
      ctx.fillStyle = color;
      ctx.fillText(text, x, y);
    }

    return {
      paint(ctx, w, h) {
        const t = theme();
        ctx.fillStyle = t.bg;
        ctx.fillRect(0, 0, w, h);
        const cw = Math.min(MAXW, w - PAD * 2);
        const x0 = Math.round((w - cw) / 2);
        let y = win.fullscreen ? Math.max(PAD, Math.round(h / 2 - 120)) : PAD;
        boxes = {};

        // --- window states
        title(ctx, x0, y + 13, 'Window state', 'xdg_toplevel');
        y += 26;
        const states = [win.fullscreen && 'fullscreen', win.maximized && 'maximized', win.focused && 'activated'].filter(Boolean);
        line(ctx, x0, y + 12, `${states.length ? states.join(' · ') : 'floating'} — ${win.width}×${win.height}`, `500 12px ${MONO}`, t.fg);
        y += 24;
        let x = x0;
        boxes.fullscreen = button(ctx, x, y, win.fullscreen ? 'Leave fullscreen' : 'Fullscreen', { active: win.fullscreen, hover: hover === 'fullscreen' });
        x += boxes.fullscreen[2] + 8;
        boxes.maximize = button(ctx, x, y, win.maximized ? 'Unmaximize' : 'Maximize', { active: win.maximized, hover: hover === 'maximize' });
        x += boxes.maximize[2] + 8;
        boxes.minimize = button(ctx, x, y, 'Minimize', { hover: hover === 'minimize' });
        y += 38;
        line(ctx, x0, y, 'Keys: f fullscreen · m maximize · n minimize (page: Alt+F11 / F10 / F9).');
        y += 18;
        line(ctx, x0, y, 'A minimized window comes back from the dock.');
        y += 26;

        // --- cursor surfaces
        title(ctx, x0, y + 13, 'Cursor surface', 'wl_pointer.set_cursor');
        y += 24;
        const sw = (cw - 8 * (CURSORS.length - 1)) / CURSORS.length;
        swatches = CURSORS.map((c, i) => {
          const r: Rect = [x0 + i * (sw + 8), y, sw, 40];
          ctx.fillStyle = t.card;
          ctx.beginPath(); ctx.roundRect(r[0] + 0.5, r[1] + 0.5, r[2] - 1, r[3] - 1, 8); ctx.fill();
          ctx.strokeStyle = t.border; ctx.lineWidth = 1; ctx.stroke();
          line(ctx, r[0] + 12, r[1] + 24, `Hover: ${c.label} (client-drawn)`, `500 12px ${FONT}`, t.fg);
          return r;
        });
        y += 56;

        // --- touch
        title(ctx, x0, y + 13, 'Touch', 'wl_touch');
        y += 24;
        touchPad = [x0, y, cw, 84];
        ctx.fillStyle = t.card;
        ctx.beginPath(); ctx.roundRect(x0 + 0.5, y + 0.5, cw - 1, 83, 8); ctx.fill();
        ctx.strokeStyle = points.size ? t.accent : t.border;
        ctx.lineWidth = points.size ? 2 : 1;
        ctx.stroke();
        line(ctx, x0 + 12, y + 20, !win.touch ? 'No wl_touch here: fingers arrive as the pointer'
          : tstats.frames ? `${points.size} down · ${tstats.frames} frames · ${tstats.cancels} cancelled · most ${tstats.max}`
            : 'Touch with one or more fingers', `500 12px ${FONT}`, points.size ? t.fg : t.muted);
        ctx.save();
        ctx.beginPath(); ctx.rect(x0, y, cw, 84); ctx.clip();
        for (const [id, [px, py]] of points) {
          const c = TOUCH_COLORS[id % TOUCH_COLORS.length];
          ctx.fillStyle = c + '33';
          ctx.beginPath(); ctx.arc(px, py, 18, 0, Math.PI * 2); ctx.fill();
          ctx.fillStyle = c;
          ctx.beginPath(); ctx.arc(px, py, 5, 0, Math.PI * 2); ctx.fill();
          line(ctx, px + 22, py + 4, `#${id} ${(px - x0).toFixed(0)},${(py - y).toFixed(0)}`, `400 11px ${MONO}`, t.fg);
        }
        ctx.restore();
        y += 84 + 18;

        // --- pointer lock
        title(ctx, x0, y + 13, 'Pointer lock', 'zwp_pointer_constraints_v1 · zwp_relative_pointer_v1');
        y += 24;
        const ph = Math.max(80, Math.min(160, h - y - 64));
        pad = [x0, y, cw, ph];
        ctx.fillStyle = t.card;
        ctx.beginPath(); ctx.roundRect(x0 + 0.5, y + 0.5, cw - 1, ph - 1, 8); ctx.fill();
        ctx.strokeStyle = lockState === 'locked' ? t.accent : t.border;
        ctx.lineWidth = lockState === 'locked' ? 2 : 1;
        ctx.stroke();
        // crosshair grid
        ctx.strokeStyle = t.faint; ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(x0 + cw / 2 + 0.5, y + 8); ctx.lineTo(x0 + cw / 2 + 0.5, y + ph - 8);
        ctx.moveTo(x0 + 8, y + ph / 2 + 0.5); ctx.lineTo(x0 + cw - 8, y + ph / 2 + 0.5);
        ctx.stroke();
        const dx = x0 + 10 + dot.x * (cw - 20), dy = y + 10 + dot.y * (ph - 20);
        ctx.fillStyle = lockState === 'locked' ? t.accent : t.muted;
        ctx.beginPath(); ctx.arc(dx, dy, 7, 0, Math.PI * 2); ctx.fill();
        ctx.textBaseline = 'alphabetic';
        ctx.font = `500 12px ${FONT}`;
        ctx.fillStyle = lockState === 'locked' ? t.fg : t.muted;
        ctx.fillText(lockState === 'locked' ? 'Locked: move the mouse · click or Esc to release'
          : lockState === 'asked' ? 'Waiting for the lock… (click again if the browser refused)' : 'Click to lock the pointer', x0 + 12, y + 20);
        y += ph + 18;
        footY = y + 6;
        line(ctx, x0, y + 18, `wp_presentation ${pres.presented} presented · ${pres.discarded} discarded · gap ${pres.interval.toFixed(0)} ms · refresh ${pres.refresh ? pres.refresh.toFixed(1) + ' ms' : '?'}`, `400 11px ${MONO}`);
        line(ctx, x0, y, `relative dx ${last[0].toFixed(1)} dy ${last[1].toFixed(1)} · total ${total[0].toFixed(0)}, ${total[1].toFixed(0)} · ${moves} motions`, `400 11px ${MONO}`);
      },
      pointer(ev) {
        if (ev.type === 'move' || ev.type === 'leave') {
          const h = ev.type === 'leave' ? '' : Object.keys(boxes).find((k) => hit(ev.x, ev.y, boxes[k])) ?? '';
          if (h !== hover) { hover = h; win.invalidate(); }
          const sw = ev.type === 'move' ? swatches.findIndex((r) => hit(ev.x, ev.y, r)) : -1;
          win.cursor(sw >= 0 ? CURSORS[sw].image : h ? 'pointer' : lockState === 'off' && hit(ev.x, ev.y, pad) ? 'crosshair' : 'default');
          return;
        }
        if (ev.type === 'down' && ev.button === 0 && lockState === 'locked') { win.unlockPointer(); return; }
        if (ev.type === 'down' && ev.button === 0 && hit(ev.x, ev.y, pad)) {
          if (lockState === 'asked') win.unlockPointer(); // ask again, from this click
          if (win.lockPointer(pad!)) { lockState = 'asked'; win.invalidate(); }
          return;
        }
        if (ev.type === 'down' && ev.button === 0) {
          const k = Object.keys(boxes).find((k) => hit(ev.x, ev.y, boxes[k]));
          if (k && actions[k]) actions[k]();
        }
      },
      // raw points in the touch pad (outside it fingers play the pointer)
      touch(ev) {
        if (ev.type === 'frame') { tstats.frames++; win.invalidate(touchPad ?? undefined); return; }
        if (ev.type === 'down' && !hit(ev.x, ev.y, touchPad)) return false;
        if (ev.type === 'down' || ev.type === 'move') points.set(ev.id, [ev.x, ev.y]);
        else points.delete(ev.id);
        if (ev.type === 'cancel') tstats.cancels++;
        tstats.max = Math.max(tstats.max, points.size);
        return true;
      },
      key(ev) {
        if (ev.ctrl || ev.alt || ev.meta) return;
        if (ev.key === 'f') actions.fullscreen();
        else if (ev.key === 'm') actions.maximize();
        else if (ev.key === 'n') actions.minimize();
        else if (ev.key === 'Escape' && win.fullscreen) win.setFullscreen(false);
      },
      focus() { win.invalidate(); },
      closed() { clearInterval(timer); },
      relative(rdx, rdy) {
        last = [rdx, rdy];
        total = [total[0] + rdx, total[1] + rdy];
        moves++;
        if (lockState === 'locked' && pad) {
          dot.x = Math.min(1, Math.max(0, dot.x + rdx / (pad[2] - 20)));
          dot.y = Math.min(1, Math.max(0, dot.y + rdy / (pad[3] - 20)));
        }
        win.invalidate();
      },
      presented(fb) {
        // counted only: repainting here would commit again, forever
        if (fb.discarded) { pres.discarded++; return; }
        pres.presented++;
        if (pres.lastMs) pres.interval = fb.ms - pres.lastMs;
        pres.lastMs = fb.ms;
        pres.refresh = fb.refresh;
      },
      locked(on) { lockState = on ? 'locked' : 'off'; win.invalidate(); },
    };
  },
};
export default app;
