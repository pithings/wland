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
import { createWland, type CursorEvent, type Wland } from '../../lib/client.ts';

declare global {
  interface Window { wland?: Wland; wlandStatus: Record<string, boolean>; wlandLog: string[]; wlandCursor?: CursorEvent }
}

window.wlandStatus = {};
window.wlandLog = [];
const status = document.getElementById('status')!;
function report(name: string, ok: boolean, detail: string) {
  window.wlandStatus[name] = ok;
  status.textContent += `${ok ? 'ok' : 'FAIL'} ${name}: ${detail}\n`;
}

const query = new URLSearchParams(location.search);
const webgl = query.get('webgl');
try {
  const wl = await createWland({
    container: document.getElementById('desktop')!,
    webgl: webgl === 'always' || webgl === 'never' ? webgl : 'auto',
    browserFullscreen: query.get('browserfs') === '1',
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
