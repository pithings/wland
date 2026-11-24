// Clock — a frameless, round, translucent widget. Its buffer is ARGB8888
// with transparent corners, so the page (and the windows behind it) show
// through; it has no title bar, so a press anywhere starts an
// xdg_toplevel.move. Its input region (wl_surface.set_input_region) is the
// disc, as rows of rects, so presses in the transparent corners fall
// through to what is behind. Right-click for a menu. A finger moves it once it
// drags (the toolkit's long press is the menu). The second hand sweeps with
// frame callbacks while smooth mode is on; otherwise it ticks once a second
// and damages only the dial.
import type { AppModule, Rect } from '../wayland/app-types.ts';
import { FONT, MONO, theme, menu } from './ui.ts';

const app: AppModule = {
  id: 'clock',
  name: 'Clock',
  blurb: 'Frameless window, ARGB transparency, round input region',
  width: 200, height: 200, minWidth: 140, minHeight: 140,
  frameless: true,
  create(win) {
    let smooth = true;
    let digital = false;
    let timer: ReturnType<typeof setInterval> | undefined;
    let press: [x: number, y: number] | null = null; // a finger down, not yet a drag

    const start = () => {
      clearInterval(timer);
      win.animate(smooth);
      if (!smooth) timer = setInterval(() => win.invalidate(), 1000);
    };
    start();

    return {
      closed() { clearInterval(timer); win.animate(false); },
      tick() { win.invalidate(); },
      // the face's disc as 24 rows (the core keeps up to 32 boxes exactly)
      inputRegion(w, h) {
        const r = Math.min(w, h) / 2 - 2, cx = w / 2, cy = h / 2;
        const rows = 24, step = (2 * r) / rows;
        const add: Rect[] = [];
        for (let i = 0; i < rows; i++) {
          const y0 = Math.round(cy - r + i * step), y1 = Math.round(cy - r + (i + 1) * step);
          const dy = (y0 + y1) / 2 - cy;
          const half = Math.round(Math.sqrt(Math.max(0, r * r - dy * dy)));
          if (half > 0 && y1 > y0) add.push([Math.round(cx) - half, y0, 2 * half, y1 - y0]);
        }
        return { add };
      },
      paint(ctx, w, h) {
        const t = theme();
        const r = Math.min(w, h) / 2 - 2, cx = w / 2, cy = h / 2;
        const now = new Date();
        // translucent face: alpha < 255 travels to the page as-is
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        ctx.fillStyle = t.dark ? 'rgba(20,20,20,0.72)' : 'rgba(255,255,255,0.72)';
        ctx.fill();
        ctx.strokeStyle = t.border;
        ctx.lineWidth = 1;
        ctx.stroke();

        if (digital) {
          ctx.fillStyle = t.fg;
          ctx.textBaseline = 'middle';
          ctx.font = `500 ${Math.round(r * 0.38)}px ${MONO}`;
          const s = now.toTimeString().slice(0, 8);
          ctx.fillText(s, cx - ctx.measureText(s).width / 2, cy);
          ctx.font = `400 ${Math.round(r * 0.13)}px ${FONT}`;
          ctx.fillStyle = t.muted;
          const d = now.toDateString();
          ctx.fillText(d, cx - ctx.measureText(d).width / 2, cy + r * 0.36);
          return;
        }
        for (let i = 0; i < 60; i++) {
          const a = (i / 60) * Math.PI * 2, major = i % 5 === 0;
          const r0 = r * (major ? 0.82 : 0.88), r1 = r * 0.93;
          ctx.strokeStyle = major ? t.fg : t.faint;
          ctx.lineWidth = major ? 2 : 1;
          ctx.beginPath();
          ctx.moveTo(cx + Math.sin(a) * r0, cy - Math.cos(a) * r0);
          ctx.lineTo(cx + Math.sin(a) * r1, cy - Math.cos(a) * r1);
          ctx.stroke();
        }
        const ms = now.getMilliseconds();
        const sec = now.getSeconds() + (smooth ? ms / 1000 : 0);
        const min = now.getMinutes() + sec / 60;
        const hr = (now.getHours() % 12) + min / 60;
        const hand = (turn: number, len: number, width: number, color: string) => {
          const a = turn * Math.PI * 2;
          ctx.strokeStyle = color;
          ctx.lineWidth = width;
          ctx.lineCap = 'round';
          ctx.beginPath();
          ctx.moveTo(cx - Math.sin(a) * r * 0.1, cy + Math.cos(a) * r * 0.1);
          ctx.lineTo(cx + Math.sin(a) * r * len, cy - Math.cos(a) * r * len);
          ctx.stroke();
        };
        hand(hr / 12, 0.5, 3.5, t.fg);
        hand(min / 60, 0.72, 2.5, t.fg);
        hand(sec / 60, 0.8, 1.25, '#ef4444');
        ctx.fillStyle = '#ef4444';
        ctx.beginPath(); ctx.arc(cx, cy, 3, 0, Math.PI * 2); ctx.fill();
        ctx.font = `500 ${Math.round(r * 0.11)}px ${FONT}`;
        ctx.fillStyle = t.muted;
        ctx.textBaseline = 'middle';
        ctx.fillText('wland', cx - ctx.measureText('wland').width / 2, cy + r * 0.4);
      },
      pointer(ev) {
        if (ev.type === 'move' && press && Math.hypot(ev.x - press[0], ev.y - press[1]) > 4) {
          press = null;
          win.move(); // names the touch-down, still held
          return;
        }
        if (ev.type === 'move') win.cursor('grab');
        if (ev.type === 'up' || ev.type === 'leave') press = null;
        if (ev.type !== 'down') return;
        press = null;
        if (ev.button === 0 && ev.touch) { press = [ev.x, ev.y]; return; }
        if (ev.button === 0) { win.move(); return; }
        if (ev.button === 2) {
          menu(win, ev.x, ev.y, [
            { label: 'Smooth second hand', checked: smooth, action: () => { smooth = !smooth; start(); win.invalidate(); } },
            { label: 'Digital', checked: digital, action: () => { digital = !digital; win.invalidate(); } },
            '-',
            { label: 'Close', danger: true, action: () => win.close() },
          ], { width: 196 });
        }
      },
    };
  },
};
export default app;
