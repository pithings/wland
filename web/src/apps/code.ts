// Code — a minimal editor showing how to use wland: one highlighted,
// editable wland.ts, a tab, a Copy button and a status bar, all painted by
// the client. What it exercises: keyboard focus (keys reach only the focused
// toplevel; the caret stops blinking without it), cursor shapes (text over
// the buffer, pointer over buttons), an xdg_popup context menu, wheel
// scrolling, and small damage: a caret blink repaints a 3×16 rect.
import type { AppModule, Rect, Theme } from '../wayland/app-types.ts';
import { MONO, FONT, theme, menu, hit, scroller } from './ui.ts';

const LINE = 20, PAD_Y = 12, GUTTER = 40, CODE_X = GUTTER + 18, TABS = 34, STATUS = 26;

const FILE = 'wland.ts';
const SOURCE = `import { createWland } from 'wland/client';
import { createWsLink } from 'wland/engine';

// Show a machine's Wayland apps in any element.
// Next to the apps, run the relay:  npx wland
const wl = await createWland({
  container: document.querySelector<HTMLElement>('#desktop')!,
  link: createWsLink('wss://box.example/ws'),
  webgl: 'auto', // or 'always' | 'never'
  onEvent(ev) {
    if (ev.type === 'error') console.warn(ev.detail);
  },
  onWindowsChange() {
    // a taskbar: titles, focus, minimized; raise() restores
    for (const w of wl.windows()) console.log(w.title, w.focused, w.minimized);
  },
});

// This page makes the same call with an in-page
// link, and \`buffers\` to read shared memory by handle.

// Unmount without a page reload.
addEventListener('pagehide', () => wl.dispose());
`;
const fresh = () => SOURCE.replace(/\n$/, '').split('\n');

const KEYWORDS = new Set(['import', 'from', 'export', 'default', 'const', 'let', 'await', 'async', 'return', 'if',
  'else', 'function', 'new', 'for', 'of', 'true', 'false', 'null', 'undefined', 'type', 'interface', 'as']);

type Kind = 'keyword' | 'string' | 'number' | 'comment' | 'fn' | 'prop' | 'type' | 'punct' | 'plain';

// one line → [[text, kind]]; good enough for the snippet above
function tokens(line: string): [text: string, kind: Kind][] {
  const out: [string, Kind][] = [];
  let i = 0;
  const push = (text: string, kind: Kind) => text && out.push([text, kind]);
  while (i < line.length) {
    const rest = line.slice(i);
    let m: RegExpExecArray | null;
    if (rest.startsWith('//')) { push(rest, 'comment'); break; }
    if ((m = /^(['"`])(?:\\.|(?!\1).)*\1?/.exec(rest))) { push(m[0], 'string'); i += m[0].length; continue; }
    if ((m = /^\d+(\.\d+)?/.exec(rest))) { push(m[0], 'number'); i += m[0].length; continue; }
    if ((m = /^[A-Za-z_$][\w$]*/.exec(rest))) {
      const w = m[0], after = line.slice(i + w.length);
      const kind: Kind = KEYWORDS.has(w) ? 'keyword' : /^[A-Z]/.test(w) && /^>/.test(after) ? 'type'
        : /^\s*[(<]/.test(after) ? 'fn' : /^:(\s|$)/.test(after) ? 'prop' : 'plain';
      push(w, kind); i += w.length; continue;
    }
    push(rest[0], 'punct'); i++;
  }
  return out;
}

function palette(t: Theme): Record<Kind, string> {
  return t.dark
    ? { keyword: '#f472b6', string: '#86efac', number: '#fdba74', comment: '#6b6b6b', fn: '#93c5fd', prop: '#c4b5fd', type: '#67e8f9', punct: '#a1a1a1', plain: t.fg }
    : { keyword: '#be185d', string: '#15803d', number: '#c2410c', comment: '#8f8f8f', fn: '#1d4ed8', prop: '#6d28d9', type: '#0e7490', punct: '#6b6b6b', plain: t.fg };
}

const app: AppModule = {
  id: 'code',
  name: 'Code',
  blurb: 'Keyboard focus, text cursor, popup menu',
  width: 600, height: 420, minWidth: 380, minHeight: 220,
  textInput: true, // touch devices get the on-screen keyboard here
  create(win) {
    let lines = fresh();
    let row = 0, col = 0, scroll = 0, dirty = false;
    let caretOn = true;
    let cw = 7.5; // measured on paint
    let focused = false;
    let blink: ReturnType<typeof setInterval> | undefined;
    let hoverCopy = false, copyBox: Rect | null = null, copied = -Infinity;

    const editorH = () => win.height - TABS - STATUS;
    const caretRect = (): Rect => [CODE_X + col * cw - 1, TABS + PAD_Y + row * LINE - scroll + 2, 3, LINE - 4];
    const lineRect = (r: number, tail = false): Rect => {
      const y = TABS + PAD_Y + r * LINE - scroll;
      return [0, Math.max(TABS, y), win.width, tail ? win.height - STATUS - y : LINE];
    };
    const statusRect = (): Rect => [0, win.height - STATUS, win.width, STATUS];
    const tabsRect = (): Rect => [0, 0, win.width, TABS];
    const maxScroll = () => Math.max(0, PAD_Y * 2 + lines.length * LINE - editorH());
    const scrollTo = (v: number) => {
      const s = Math.max(0, Math.min(maxScroll(), v));
      if (s !== scroll) { scroll = s; win.invalidate([0, TABS, win.width, editorH()]); }
    };
    // touch (and mouse) drags scroll the buffer
    const drag = scroller(() => scroll, scrollTo);
    let pressedInEditor = false;
    const keepVisible = () => {
      const y = PAD_Y + row * LINE;
      if (y - scroll < 0) scroll = Math.max(0, y - PAD_Y);
      else if (y + LINE - scroll > editorH()) scroll = y + LINE - editorH() + PAD_Y;
    };
    const restartBlink = () => {
      clearInterval(blink);
      caretOn = true;
      if (!focused) return;
      blink = setInterval(() => { caretOn = !caretOn; win.invalidate(caretRect()); }, 530);
    };
    // an edit damages the edited line (or everything below it), the tab
    // (its dirty dot, the first time) and the status bar
    const edited = (fromRow: number, tail = false) => {
      const wasDirty = dirty;
      dirty = true;
      const old = scroll;
      keepVisible();
      restartBlink();
      if (old !== scroll) return win.invalidate();
      win.invalidate(lineRect(fromRow, tail));
      win.invalidate(statusRect());
      if (!wasDirty) win.invalidate(tabsRect());
    };
    const moveCaret = (r: number, c: number) => {
      const before = caretRect();
      row = Math.max(0, Math.min(lines.length - 1, r));
      col = Math.max(0, Math.min(lines[row].length, c));
      const old = scroll;
      keepVisible();
      restartBlink();
      if (old !== scroll) return win.invalidate();
      // the current-line highlight moves with the caret
      win.invalidate([0, before[1] - 2, win.width, LINE]);
      win.invalidate(lineRect(row));
      win.invalidate(statusRect());
    };
    const insert = (text: string) => {
      const l = lines[row];
      lines[row] = l.slice(0, col) + text + l.slice(col);
      col += text.length;
      edited(row);
    };
    const toggleComment = () => {
      const l = lines[row];
      const m = /^(\s*)(\/\/ ?)?/.exec(l)!; // every line matches
      lines[row] = m[2] ? m[1] + l.slice(m[0].length) : `${m[1]}// ${l.slice(m[1].length)}`;
      col = Math.max(0, Math.min(col + (m[2] ? -m[2].length : 3), lines[row].length));
      edited(row);
    };
    const copy = () => {
      navigator.clipboard?.writeText(lines.join('\n') + '\n').catch(() => {});
      copied = performance.now();
      win.invalidate(tabsRect());
      setTimeout(() => win.invalidate(tabsRect()), 1300);
    };
    const revert = () => {
      lines = fresh();
      row = col = scroll = 0;
      dirty = false;
      win.invalidate();
    };

    win.setTitle(`${FILE} — Code`);

    return {
      caret: caretRect,
      focus(on) {
        focused = on;
        restartBlink();
        win.invalidate(lineRect(row));
        win.invalidate(statusRect());
      },
      closed() { clearInterval(blink); win.animate(false); },
      tick(now) {
        drag.tick(now);
        if (!drag.flinging) win.animate(false);
      },
      paint(ctx, w, h) {
        const t = theme();
        const pal = palette(t);
        ctx.fillStyle = t.bg;
        ctx.fillRect(0, 0, w, h);
        ctx.textBaseline = 'middle';

        // the tab
        ctx.fillStyle = t.chrome;
        ctx.fillRect(0, 0, w, TABS);
        ctx.fillStyle = t.border;
        ctx.fillRect(0, TABS - 1, w, 1);
        ctx.font = `400 12px ${FONT}`;
        const tw = Math.ceil(ctx.measureText(FILE).width) + 58;
        ctx.fillStyle = t.bg;
        ctx.fillRect(0, 0, tw, TABS);
        ctx.fillStyle = t.border;
        ctx.fillRect(tw - 1, 0, 1, TABS - 1);
        ctx.fillStyle = '#3178c6';
        ctx.font = `700 9px ${MONO}`;
        ctx.fillText('TS', 14, TABS / 2 + 1);
        ctx.font = `400 12px ${FONT}`;
        ctx.fillStyle = t.fg;
        ctx.fillText(FILE, 34, TABS / 2 + 0.5);
        if (dirty) {
          ctx.fillStyle = t.muted;
          ctx.beginPath(); ctx.arc(tw - 13, TABS / 2, 3, 0, Math.PI * 2); ctx.fill();
        }
        // copy button
        const justCopied = performance.now() - copied < 1200;
        const label = justCopied ? 'Copied' : 'Copy';
        ctx.font = `500 11.5px ${FONT}`;
        const bw = Math.ceil(ctx.measureText(label).width) + 18;
        copyBox = [w - bw - 8, 5, bw, 23];
        const [bx, by, , bh] = copyBox;
        ctx.fillStyle = hoverCopy ? t.hover : 'transparent';
        ctx.beginPath(); ctx.roundRect(bx + 0.5, by + 0.5, bw - 1, bh - 1, 5); ctx.fill();
        ctx.strokeStyle = t.border; ctx.lineWidth = 1; ctx.stroke();
        ctx.fillStyle = justCopied ? t.accent : t.fg;
        ctx.fillText(label, bx + 9, by + bh / 2 + 0.5);

        // the buffer
        ctx.save();
        ctx.beginPath(); ctx.rect(0, TABS, w, h - TABS - STATUS); ctx.clip();
        ctx.font = `400 12.5px ${MONO}`;
        cw = ctx.measureText('0000000000').width / 10;
        const first = Math.max(0, Math.floor((scroll - PAD_Y) / LINE));
        const last = Math.min(lines.length, Math.ceil((scroll + editorH()) / LINE));
        for (let i = first; i < last; i++) {
          const y = TABS + PAD_Y + i * LINE - scroll + LINE / 2;
          if (i === row && focused) {
            ctx.fillStyle = t.hover;
            ctx.fillRect(0, y - LINE / 2, w, LINE);
          }
          ctx.fillStyle = i === row ? t.fg : t.faint;
          const n = String(i + 1);
          ctx.fillText(n, GUTTER - ctx.measureText(n).width, y);
          let x = CODE_X;
          for (const [text, kind] of tokens(lines[i])) {
            ctx.fillStyle = pal[kind];
            ctx.fillText(text, x, y);
            x += text.length * cw;
          }
        }
        if (caretOn && focused) {
          const [x, y, cw2, ch] = caretRect();
          ctx.fillStyle = t.fg;
          ctx.fillRect(x + 0.5, y, cw2 - 1, ch);
        }
        ctx.restore();

        // status bar
        ctx.fillStyle = t.chrome;
        ctx.fillRect(0, h - STATUS, w, STATUS);
        ctx.fillStyle = t.border;
        ctx.fillRect(0, h - STATUS, w, 1);
        ctx.beginPath(); ctx.arc(14, h - STATUS / 2, 3, 0, Math.PI * 2);
        ctx.fillStyle = focused ? '#10b981' : t.faint;
        ctx.fill();
        ctx.font = `400 11.5px ${FONT}`;
        ctx.fillStyle = t.muted;
        ctx.fillText(focused ? 'keyboard focus' : 'click to focus', 24, h - STATUS / 2 + 0.5);
        const right = `Ln ${row + 1}, Col ${col + 1}  ·  Spaces: 2  ·  TypeScript`;
        ctx.fillText(right, w - 12 - ctx.measureText(right).width, h - STATUS / 2 + 0.5);
      },
      pointer(ev) {
        const inEditor = ev.y >= TABS && ev.y < win.height - STATUS;
        if (ev.type === 'leave') {
          if (drag.dragging) { drag.up(); if (drag.flinging) win.animate(true); }
          pressedInEditor = false;
          if (hoverCopy) { hoverCopy = false; win.invalidate(tabsRect()); }
          return;
        }
        if (ev.type === 'move' && drag.move(ev.y)) { pressedInEditor = false; return; }
        if (ev.type === 'move') {
          const hc = hit(ev.x, ev.y, copyBox);
          if (hc !== hoverCopy) { hoverCopy = hc; win.invalidate(tabsRect()); }
          win.cursor(inEditor ? 'text' : hc ? 'pointer' : 'default');
          return;
        }
        if (ev.type === 'wheel') { scrollTo(scroll + ev.dy); return; }
        const caretAt = () => moveCaret(Math.floor((ev.y - TABS + scroll - PAD_Y) / LINE), Math.round((ev.x - CODE_X) / cw));
        if (ev.type === 'up') {
          // a tap places the caret; a drag scrolled instead
          const dragged = drag.up();
          if (drag.flinging) win.animate(true);
          if (!dragged && pressedInEditor && inEditor) caretAt();
          pressedInEditor = false;
          return;
        }
        if (ev.type !== 'down') return;
        if (ev.button === 0 && hit(ev.x, ev.y, copyBox)) return copy();
        if (!inEditor) return;
        if (ev.button === 0) { drag.down(ev.y); pressedInEditor = true; return; }
        caretAt();
        if (ev.button === 2) {
          menu(win, ev.x, ev.y, [
            { label: 'Toggle comment', hint: 'Ctrl /', action: toggleComment },
            { label: 'Duplicate line', action: () => { lines.splice(row, 0, lines[row]); row++; edited(row - 1, true); } },
            { label: 'Delete line', action: () => {
              if (lines.length > 1) lines.splice(row, 1); else lines[0] = '';
              row = Math.min(row, lines.length - 1); col = Math.min(col, lines[row].length);
              edited(row, true);
            } },
            '-',
            { label: 'Copy file', action: copy },
            { label: 'Revert file', danger: true, action: revert },
          ], { width: 210 });
        }
      },
      key(ev) {
        const l = lines[row];
        if (ev.ctrl && ev.key === '/') return toggleComment();
        switch (ev.key) {
          case 'Enter': {
            const indent = /^\s*/.exec(l)![0] + (/[{([]\s*$/.test(l.slice(0, col)) ? '  ' : '');
            lines.splice(row, 1, l.slice(0, col), indent + l.slice(col));
            row++; col = indent.length;
            edited(row - 1, true);
            return;
          }
          case 'Backspace':
            if (col > 0) { lines[row] = l.slice(0, col - 1) + l.slice(col); col--; edited(row); }
            else if (row > 0) {
              col = lines[row - 1].length;
              lines[row - 1] += l;
              lines.splice(row, 1);
              row--;
              edited(row, true);
            }
            return;
          case 'Delete':
            if (col < l.length) { lines[row] = l.slice(0, col) + l.slice(col + 1); edited(row); }
            else if (row < lines.length - 1) { lines[row] += lines[row + 1]; lines.splice(row + 1, 1); edited(row, true); }
            return;
          case 'Tab': insert('  '); return;
          case 'ArrowLeft': return col > 0 ? moveCaret(row, col - 1) : moveCaret(row - 1, Infinity);
          case 'ArrowRight': return col < l.length ? moveCaret(row, col + 1) : row < lines.length - 1 && moveCaret(row + 1, 0);
          case 'ArrowUp': return moveCaret(row - 1, col);
          case 'ArrowDown': return moveCaret(row + 1, col);
          case 'PageUp': return moveCaret(row - Math.floor(editorH() / LINE), col);
          case 'PageDown': return moveCaret(row + Math.floor(editorH() / LINE), col);
          case 'Home': { const ind = /^\s*/.exec(l)![0].length; return moveCaret(row, col === ind ? 0 : ind); }
          case 'End': return moveCaret(row, Infinity);
        }
        if (ev.text) insert(ev.text);
      },
    };
  },
};
export default app;
