// The browser E2E's page (tools/browser-e2e.ts): wland/client in a bare
// document, nothing else. It is the tests' fixture, not a demo: the checks
// are about lib/ in a real browser, so they must not move when a demo page
// is redesigned.
//
// The page's contract with the tests:
//   window.wland         the createWland() result
//   window.wlandStatus   { wasm, websocket }: true once up, false once lost
//   window.wlandLog      every 'log' line
//   window.wlandCursor   the last 'cursor' event (a client's pointer image)
//   #status              one line per status change (the takeover notice)
//   document.title       `<focused toplevel's last title> — wland`
//   ?webgl=always|never  overrides the view's hardware probe
//   ?browserfs=1         createWland's browserFullscreen (the states phase)
//   ?embedder=1          an embedder's window manager takes interactive
//                        move/resize (createWland's `interactive`): each
//                        request is recorded in window.wlandEmbedder and
//                        taken with an input grab; a move or Alt+drag moves
//                        the window by CSS `translate` (not left/top: those
//                        are wland's own grab's), a resize changes nothing
//   ?altdrag=0           shortcuts { drag: false } (Alt+F9/F10/F11 stay)
//   ?autofocus=0         createWland's autoFocus: false (the embedder phase)
import { createWland, type CursorEvent, type InteractiveEvent, type PointerPress, type Wland } from '../../lib/client.ts';

/** One request the ?embedder=1 window manager took: `moves` counts its
 *  pointer's moves it saw while its grab was on, `ended` why the grab ended. */
interface EmbedderDrag {
  type: InteractiveEvent['type']; conn: number; surface: number; edges: number; press: PointerPress;
  active: boolean; moves: number; ended: string;
}

declare global {
  interface Window {
    wland?: Wland; wlandStatus: Record<string, boolean>; wlandLog: string[]; wlandCursor?: CursorEvent;
    wlandEmbedder: EmbedderDrag[];
  }
}

window.wlandStatus = {};
window.wlandLog = [];
window.wlandEmbedder = [];
const status = document.getElementById('status')!;
function report(name: string, ok: boolean, detail: string) {
  window.wlandStatus[name] = ok;
  status.textContent += `${ok ? 'ok' : 'FAIL'} ${name}: ${detail}\n`;
}

const query = new URLSearchParams(location.search);
const webgl = query.get('webgl');

// ?embedder=1: what an embedder's window manager does with a move/resize
// request — takes it, grabs the pointer, follows it until the grab ends
function interactive(ev: InteractiveEvent, press: PointerPress): boolean {
  const wl = window.wland, win = wl?.view.window(ev.conn, ev.surface);
  if (!wl || !win) return false;
  const rec: EmbedderDrag = { type: ev.type, conn: ev.conn, surface: ev.surface, edges: ev.type === 'resize' ? ev.edges : 0,
    press, active: false, moves: 0, ended: '' };
  window.wlandEmbedder.push(rec);
  const el = win.element;
  const [tx = 0, ty = 0] = (el.style.translate || '0px 0px').split(' ').map(parseFloat);
  const follow = (e: PointerEvent) => {
    if (e.pointerId !== press.pointerId) return;
    rec.moves++;
    if (ev.type !== 'resize') el.style.translate = `${tx + e.clientX - press.clientX}px ${ty + e.clientY - press.clientY}px`;
  };
  const grab = wl.input.grab(press.pointerId, { onEnd(reason) {
    rec.ended = reason;
    document.removeEventListener('pointermove', follow, true);
  } });
  rec.active = grab.active;
  if (grab.active) document.addEventListener('pointermove', follow, true);
  return true;
}
try {
  const wl = await createWland({
    container: document.getElementById('desktop')!,
    webgl: webgl === 'always' || webgl === 'never' ? webgl : 'auto',
    browserFullscreen: query.get('browserfs') === '1',
    interactive: query.get('embedder') === '1' ? interactive : undefined,
    shortcuts: query.get('altdrag') === '0' ? { drag: false } : true,
    autoFocus: query.get('autofocus') !== '0',
    onEvent(ev) {
      switch (ev.type) {
        case 'log': window.wlandLog.push(ev.line); break;
        case 'open': report('websocket', true, 'compositor online'); break;
        case 'error': report('websocket', false, ev.detail); break;
        case 'title': document.title = `${ev.title} — wland`; break;
        case 'cursor': window.wlandCursor = ev; break;
        case 'close':
          // Taken over: another tab claimed the session. No reload — that
          // would steal it right back, ping-ponging forever.
          if (ev.takenOver) report('websocket', false, 'session taken over by another tab');
          else {
            report('websocket', false, 'connection closed; reloading in 3s');
            setTimeout(() => location.reload(), 3000);
          }
          break;
      }
    },
  });
  report('wasm', true, `core v${wl.engine.version}`);
  window.wland = wl;
} catch (e) {
  report('wasm', false, String(e));
}
