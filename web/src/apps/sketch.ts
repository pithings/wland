// Sketch — draw with the pointer. Each pointer motion damages just the
// bounding box of the new stroke segment (turn on "Damage" to see it), a
// press captures the pointer until release, and the crosshair cursor is
// picked by the client (wp_cursor_shape_v1). Strokes are kept as vectors and
// replayed into a layer, so a resize or a buffer-scale change stays sharp.
import type { AppModule, Rect } from '../wayland/app-types.ts';
import { FONT, theme, button, hit } from './ui.ts';

const BAR = 44;
const COLORS = ['#ededed', '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#a855f7'];
const SIZES = [2, 5, 10];

type Point = [x: number, y: number];
interface Stroke { color: number; size: number; points: Point[] }

const app: AppModule = {
  id: 'sketch',
  name: 'Sketch',
  blurb: 'Pointer capture, per-segment damage, cursors',
  width: 440, height: 340, minWidth: 340, minHeight: 240,
  create(win) {
    const strokes: Stroke[] = [];
    let current: Stroke | null = null;
    let color = 1, size = 1;
    let layer: OffscreenCanvas | null = null, layerKey = '';
    let boxes: { colors: Rect[]; sizes: Rect[]; clear: Rect | null } = { colors: [], sizes: [], clear: null };
    let hoverClear = false;

    const ink = (i: number): string => (i === 0 ? theme().fg : COLORS[i]);

    function ensureLayer() {
      const s = win.scale, w = win.width, h = win.height - BAR;
      const key = `${w}x${h}@${s}`;
      if (key === layerKey && layer) return;
      layerKey = key;
      layer = new OffscreenCanvas(Math.max(1, w * s), Math.max(1, h * s));
      const c = layer.getContext('2d')!;
      c.setTransform(s, 0, 0, s, 0, 0);
      for (const st of strokes) drawStroke(c, st, 1);
    }
    function drawStroke(c: OffscreenCanvasRenderingContext2D, st: Stroke, from: number) {
      c.strokeStyle = ink(st.color);
      c.fillStyle = ink(st.color);
      c.lineWidth = st.size;
      c.lineCap = 'round';
      c.lineJoin = 'round';
      const p = st.points;
      if (p.length === 1) { c.beginPath(); c.arc(p[0][0], p[0][1], st.size / 2, 0, Math.PI * 2); c.fill(); return; }
      c.beginPath();
      c.moveTo(...p[Math.max(0, from - 1)]);
      for (let i = Math.max(1, from); i < p.length; i++) c.lineTo(...p[i]);
      c.stroke();
    }

    return {
      paint(ctx, w, h) {
        const t = theme();
        ctx.fillStyle = t.bg;
        ctx.fillRect(0, 0, w, h);
        // dot grid
        ctx.fillStyle = t.faint;
        for (let y = BAR + 12; y < h; y += 20) for (let x = 10; x < w; x += 20) ctx.fillRect(x, y, 1, 1);
        ensureLayer();
        ctx.drawImage(layer!, 0, BAR, w, h - BAR); // ensureLayer() set it

        // toolbar
        ctx.fillStyle = t.chrome;
        ctx.fillRect(0, 0, w, BAR);
        ctx.fillStyle = t.border;
        ctx.fillRect(0, BAR - 1, w, 1);
        boxes.colors = COLORS.map((_, i) => {
          const x = 14 + i * 26, y = 12;
          if (i === color) {
            ctx.strokeStyle = t.fg; ctx.lineWidth = 1.5;
            ctx.beginPath(); ctx.arc(x + 10, y + 10, 10, 0, Math.PI * 2); ctx.stroke();
          }
          ctx.fillStyle = ink(i);
          ctx.beginPath(); ctx.arc(x + 10, y + 10, 7, 0, Math.PI * 2); ctx.fill();
          return [x, y, 20, 20];
        });
        const sx = 14 + COLORS.length * 26 + 14;
        ctx.fillStyle = t.border;
        ctx.fillRect(sx - 8, 12, 1, 20);
        boxes.sizes = SIZES.map((s, i) => {
          const x = sx + i * 28, y = 9;
          ctx.fillStyle = i === size ? t.hover : 'transparent';
          ctx.beginPath(); ctx.roundRect(x, y, 26, 26, 6); ctx.fill();
          ctx.fillStyle = t.fg;
          ctx.beginPath(); ctx.arc(x + 13, y + 13, Math.max(1.5, s / 2 + 0.5), 0, Math.PI * 2); ctx.fill();
          return [x, y, 26, 26];
        });
        ctx.font = `500 12px ${FONT}`;
        boxes.clear = button(ctx, w - 14 - 58, 9, 'Clear', { w: 58, hover: hoverClear });
        if (!strokes.length) {
          ctx.fillStyle = t.muted;
          ctx.font = `400 13px ${FONT}`;
          ctx.textBaseline = 'middle';
          const msg = 'Draw anywhere: each segment damages only its own box';
          ctx.fillText(msg, (w - ctx.measureText(msg).width) / 2, BAR + (h - BAR) / 2);
        }
      },
      pointer(ev) {
        const onCanvas = ev.y >= BAR;
        if (ev.type === 'move' && !current) {
          const overButton = boxes.colors.some((b) => hit(ev.x, ev.y, b)) || boxes.sizes.some((b) => hit(ev.x, ev.y, b)) || hit(ev.x, ev.y, boxes.clear);
          win.cursor(onCanvas ? 'crosshair' : overButton ? 'pointer' : 'default');
          const hc = hit(ev.x, ev.y, boxes.clear);
          if (hc !== hoverClear) { hoverClear = hc; win.invalidate([0, 0, win.width, BAR]); }
        }
        if (ev.type === 'down' && ev.button === 0) {
          const ci = boxes.colors.findIndex((b) => hit(ev.x, ev.y, b));
          if (ci >= 0) { color = ci; win.invalidate([0, 0, win.width, BAR]); return; }
          const si = boxes.sizes.findIndex((b) => hit(ev.x, ev.y, b));
          if (si >= 0) { size = si; win.invalidate([0, 0, win.width, BAR]); return; }
          if (hit(ev.x, ev.y, boxes.clear)) { strokes.length = 0; layerKey = ''; win.invalidate(); return; }
          if (!onCanvas) return;
          const empty = !strokes.length;
          current = { color, size: SIZES[size], points: [[ev.x, ev.y - BAR]] };
          strokes.push(current);
          ensureLayer();
          drawStroke(layer!.getContext('2d')!, current, 0);
          if (empty) win.invalidate();
          else { const r = current.size; win.invalidate([ev.x - r, ev.y - r, r * 2, r * 2]); }
          return;
        }
        if (ev.type === 'move' && current) {
          const p = current.points;
          const [lx, ly] = p[p.length - 1];
          const x = ev.x, y = Math.max(0, ev.y - BAR);
          if (Math.abs(x - lx) + Math.abs(y - ly) < 1.5) return;
          p.push([x, y]);
          ensureLayer();
          drawStroke(layer!.getContext('2d')!, current, p.length - 1);
          const r = current.size;
          const x0 = Math.min(lx, x) - r, y0 = Math.min(ly, y) - r;
          win.invalidate([x0, y0 + BAR, Math.abs(x - lx) + r * 2, Math.abs(y - ly) + r * 2]);
          return;
        }
        if ((ev.type === 'up' || ev.type === 'leave') && current) current = null;
      },
    };
  },
};
export default app;
