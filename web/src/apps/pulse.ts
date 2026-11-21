// Pulse — a live monitor of this very session. Animates at the display's
// frame rate, paced by wl_surface.frame callbacks (the engine fires them from
// requestAnimationFrame); each frame damages only the plot, so the header
// and legend stay put in the compositor's copy. The metric picker is an
// xdg_popup; the plot shows a crosshair cursor and a readout on hover.
import type { AppModule, Metrics, Rect } from '../wayland/app-types.ts';
import { FONT, MONO, theme, menu, button, hit } from './ui.ts';

const HEAD = 52, FOOT = 34, N = 240;

const METRICS = [
  { id: 'commits', label: 'Commits / s', unit: '/s', color: '#3b82f6' },
  { id: 'kib', label: 'Damage KiB / s', unit: 'KiB/s', color: '#a855f7' },
  { id: 'frames', label: 'Pulse frame time', unit: 'ms', color: '#10b981' },
  { id: 'wave', label: 'Synthetic signal', unit: '', color: '#f59e0b' },
];

const app: AppModule = {
  id: 'pulse',
  name: 'Pulse',
  blurb: 'Frame callbacks, partial damage, dropdown popup',
  width: 450, height: 290, minWidth: 360, minHeight: 240,
  create(win, services) {
    let metric = METRICS.find((m) => m.id === 'wave')!;
    const series = new Map(METRICS.map((m) => [m.id, new Float32Array(N)]));
    let head = 0;            // ring buffer write index
    let last = performance.now();
    let hover: number | null = null; // plot-local x
    let pickerHover = false;
    let pickerBox: Rect | null = null;
    let paused = false;
    let pauseBox: Rect | null = null;
    let t0 = performance.now();

    const plot = (): Rect => [16, HEAD, win.width - 32, win.height - HEAD - FOOT];

    // series has a ring for every METRICS id
    function sample(now: number) {
      const dt = now - last;
      last = now;
      const m: Partial<Metrics> = services.metrics ? services.metrics() : {};
      series.get('commits')![head] = m.commitsPerSec ?? 0;
      series.get('kib')![head] = m.kibPerSec ?? 0;
      series.get('frames')![head] = Math.min(dt, 100);
      const t = (now - t0) / 1000;
      series.get('wave')![head] = 50 + 30 * Math.sin(t * 2.1) + 12 * Math.sin(t * 5.3 + 1) + 6 * Math.sin(t * 13.7);
      head = (head + 1) % N;
    }

    win.animate(true);

    return {
      closed() { win.animate(false); },
      tick(now) {
        if (paused) return;
        sample(now);
        win.invalidate(plot());
        win.invalidate([0, win.height - FOOT, win.width, FOOT]);
      },
      paint(ctx, w, h) {
        const t = theme();
        ctx.fillStyle = t.bg;
        ctx.fillRect(0, 0, w, h);
        ctx.textBaseline = 'middle';

        // header: the metric picker and pause
        ctx.font = `500 12px ${FONT}`;
        const label = `${metric.label}  ▾`;
        const box: Rect = [16, 14, Math.ceil(ctx.measureText(label).width) + 34, 26];
        ctx.fillStyle = pickerHover ? t.hover : 'transparent';
        ctx.beginPath(); ctx.roundRect(box[0] + 0.5, box[1] + 0.5, box[2] - 1, box[3] - 1, 6); ctx.fill();
        ctx.strokeStyle = t.border; ctx.lineWidth = 1; ctx.stroke();
        ctx.fillStyle = metric.color;
        ctx.beginPath(); ctx.arc(box[0] + 13, box[1] + 13, 3.5, 0, Math.PI * 2); ctx.fill();
        ctx.fillStyle = t.fg;
        ctx.fillText(label, box[0] + 24, box[1] + 13.5);
        pickerBox = box;
        pauseBox = button(ctx, w - 16 - 70, 14, paused ? 'Resume' : 'Pause', { w: 70, active: paused });

        // plot
        const [px, py, pw, ph] = plot();
        const data = series.get(metric.id)!;
        let max = 1;
        for (const v of data) max = Math.max(max, v);
        max = niceMax(max);
        ctx.strokeStyle = t.border;
        ctx.lineWidth = 1;
        ctx.font = `400 10.5px ${MONO}`;
        for (let i = 0; i <= 4; i++) {
          const y = Math.round(py + (ph * i) / 4) + 0.5;
          ctx.beginPath(); ctx.setLineDash(i === 4 ? [] : [2, 4]); ctx.moveTo(px, y); ctx.lineTo(px + pw, y); ctx.stroke();
          ctx.fillStyle = t.muted;
          const v = fmt(max * (1 - i / 4));
          ctx.fillText(v, px + pw - ctx.measureText(v).width, i === 0 ? y + 9 : y - 8);
        }
        ctx.setLineDash([]);
        const xAt = (i: number) => px + (pw * i) / (N - 1);
        const yAt = (v: number) => py + ph - (ph * v) / max;
        const grad = ctx.createLinearGradient(0, py, 0, py + ph);
        grad.addColorStop(0, metric.color + '55');
        grad.addColorStop(1, metric.color + '00');
        ctx.beginPath();
        for (let i = 0; i < N; i++) {
          const v = data[(head + i) % N];
          if (i === 0) ctx.moveTo(xAt(i), yAt(v)); else ctx.lineTo(xAt(i), yAt(v));
        }
        ctx.strokeStyle = metric.color;
        ctx.lineWidth = 1.5;
        ctx.lineJoin = 'round';
        ctx.stroke();
        ctx.lineTo(xAt(N - 1), py + ph);
        ctx.lineTo(xAt(0), py + ph);
        ctx.closePath();
        ctx.fillStyle = grad;
        ctx.fill();

        if (hover !== null && hover >= 0 && hover <= pw) {
          const i = Math.round((hover / pw) * (N - 1));
          const v = data[(head + i) % N];
          const x = Math.round(xAt(i)) + 0.5, y = yAt(v);
          ctx.strokeStyle = t.muted;
          ctx.beginPath(); ctx.moveTo(x, py); ctx.lineTo(x, py + ph); ctx.stroke();
          ctx.fillStyle = metric.color;
          ctx.beginPath(); ctx.arc(x, y, 3.5, 0, Math.PI * 2); ctx.fill();
          const text = `${fmt(v)} ${metric.unit}`;
          ctx.font = `500 11px ${MONO}`;
          const tw = ctx.measureText(text).width + 14;
          const tx = Math.min(x + 8, px + pw - tw);
          ctx.fillStyle = t.dark ? '#1f1f1f' : '#ffffff';
          ctx.beginPath(); ctx.roundRect(tx, py + 6, tw, 22, 5); ctx.fill();
          ctx.strokeStyle = t.border; ctx.stroke();
          ctx.fillStyle = t.fg;
          ctx.fillText(text, tx + 7, py + 17.5);
        }

        // footer: current value + stats
        const now = data[(head + N - 1) % N];
        ctx.fillStyle = t.border;
        ctx.fillRect(0, h - FOOT, w, 1);
        ctx.font = `400 11.5px ${FONT}`;
        ctx.fillStyle = t.muted;
        const m: Partial<Metrics> = services.metrics ? services.metrics() : {};
        ctx.fillText(`now ${fmt(now)} ${metric.unit}`, 16, h - FOOT / 2 + 0.5);
        const right = `${m.clients ?? 0} clients · ${m.windows ?? 0} windows · ${win.scale}× buffers`;
        ctx.fillText(right, w - 16 - ctx.measureText(right).width, h - FOOT / 2 + 0.5);
      },
      pointer(ev) {
        const [px, py, pw, ph] = plot();
        const inPlot = ev.x >= px && ev.x < px + pw && ev.y >= py && ev.y < py + ph;
        if (ev.type === 'leave') { hover = null; pickerHover = false; win.invalidate(); return; }
        if (ev.type === 'move') {
          const ph2 = hit(ev.x, ev.y, pickerBox);
          if (ph2 !== pickerHover) { pickerHover = ph2; win.invalidate([0, 0, win.width, HEAD]); }
          win.cursor(inPlot ? 'crosshair' : ph2 || hit(ev.x, ev.y, pauseBox) ? 'pointer' : 'default');
          const hv = inPlot ? ev.x - px : null;
          if (hv !== hover) { hover = hv; win.invalidate(plot()); }
        }
        if (ev.type !== 'down' || ev.button !== 0) return;
        if (hit(ev.x, ev.y, pauseBox)) { paused = !paused; last = performance.now(); win.invalidate(); return; }
        if (hit(ev.x, ev.y, pickerBox)) {
          const pb = pickerBox!; // hit() is false for a null box
          menu(win, pb[0], pb[1] + pb[3] + 4, METRICS.map((m) => ({
            label: m.label, checked: m === metric,
            action: () => { metric = m; win.invalidate(); },
          })), { width: 210 });
        }
      },
    };
  },
};
export default app;


function niceMax(v: number): number {
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const k of [1, 2, 2.5, 5, 10]) if (v <= k * p) return k * p;
  return 10 * p;
}
function fmt(v: number): string {
  if (v >= 1000) return `${(v / 1000).toFixed(1)}k`;
  if (v >= 100) return v.toFixed(0);
  return v.toFixed(1);
}
