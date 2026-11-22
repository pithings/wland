// wland clipboard bridge: the Wayland clipboard (wl_data_device selection;
// not the primary) ⇄ the page's clipboard, plain text (UTF-8) both ways.
// createWland wires it in unless `clipboard: false`; an embedder composing
// the parts itself passes `hooks` to createInput and feeds `handle` every
// engine event.
//
// App → page. When an app sets the selection, its text is read at once
// (Engine.readSelection through the relay, bounded). Browsers write the
// page clipboard only around a user gesture, so a text owed to the page is
// written with navigator.clipboard.writeText right away if a key or button
// was pressed in the desktop within the last 5 s (the Ctrl+C or the menu
// click that made the app copy: Chromium writes in a focused page, Firefox
// within its transient activation), else at the next key or button press
// in the desktop (inside that event's handler: what Safari asks for), or
// the next copy event on it (Ctrl+C: setData, no permission needed). A
// refused write stays owed; nothing throws. A copy chord in the desktop
// keeps its browser default only while a text is owed (wantsCopy); input
// cancels every copy/cut event while the desktop has the focus, so the
// page's own selection (Firefox keeps one across a click into the desktop)
// is never what a Ctrl+C there copies.
//
// Page → app. The paste event a paste chord makes (Ctrl+V, Ctrl+Shift+V,
// Shift+Insert; Cmd+V on Apple platforms) carries the page clipboard: input
// holds the chord's key press until the bridge has made that text the
// selection (Engine.setSelection: the compositor's own source, offered to
// the focused client only), so the app's paste reads it. When the browser
// has already granted `clipboard-read` (never asked for here), focusing the
// desktop also reads the page clipboard (readText), so an app's own Paste
// menu sees text copied outside. Paste events and those reads are the only
// looks the bridge gets at the page clipboard.
//
// Which side is newer is decided by focus. "Inside": the desktop has the
// keyboard focus — tracked from focusin/focusout, the window's focus/blur
// and visibilitychange (not document.hasFocus(): headless Firefox says
// false throughout), and any key or button press in the desktop proves it.
// Leaving it (page UI, another tab or window, or nothing: a click on plain
// page text, an embedder's blur()) is when the page clipboard may change
// behind the bridge's back; so is a press outside the desktop that keeps
// the focus where it was (a toolbar button that copies). State: `owed`
// (text to write to the page; '' = clear it), `verify` (a write decided at
// the next look at the page clipboard: done if the page still holds
// `ifPage`, dropped if it changed), `pageKnown` (the page clipboard as last
// written or seen here; null: unknown, or not text), `wlText` (the Wayland
// clipboard's text, when known), `wlEmpty` (the Wayland clipboard holds
// nothing).
//
//   event                         inside                         outside
//   ----------------------------  -----------------------------  ---------------------------
//   app sets text S (read back)   S ≠ pageKnown: owed = S,       verify = {S, ifPage: pageKnown}
//                                 written if a gesture < 5 s     (the page is not touched)
//   app sets other types,         wlText, owed, verify cleared   same
//   the embedder sets its own
//   app clears (set_selection     page holds what the bridge     page holds the bridge's write
//   (null): its conn, no types)   wrote of it: owed = ''         of it: verify = {'', ifPage}
//   owner went (conn 0, no        wlText = null, wlEmpty; owed   same
//   types: app or link gone)      and verify kept (the page
//                                 keeps or still gets the text,
//                                 as a clipboard manager would)
//   key / button press in the     write owed now                 → inside, then as inside
//   desktop (gesture)
//   copy chord / copy event on    owed: chord keeps its default, (none: the desktop has focus)
//   the desktop                   setData(owed); nothing owed:
//                                 chord prevented. The event is
//                                 cancelled either way
//   look at the page (paste       verify: page = ifPage → owed   (none)
//   event; granted readText on    = write, written now, page
//   focus) showing P              text not taken; else dropped.
//                                 owed '' and P = pageKnown:
//                                 written now. P = pageKnown:
//                                 P is the selection if wlEmpty
//                                 and nothing is owed (the app
//                                 that copied it went), else
//                                 nothing. Else pageKnown = P;
//                                 owed text: kept (the app's is
//                                 newer); P ≠ wlText → P is the
//                                 selection
//   look showing no text but      the page changed: verify and   (none)
//   other types (an image         owed '' dropped, pageKnown =
//   copied elsewhere)             null; nothing written or set
//   leave (focusout to outside    owed → verify = {owed,         —
//   or nothing, window blur, tab  ifPage: pageKnown}
//   hidden, a press outside)
//   enter (focusin, focus)        —                              → inside; granted readText
//
// So an app copying while the user is elsewhere (a script's wl-copy, a
// background app) never writes the page clipboard while they are away:
// apps inside paste its text, and the user's next look at the page
// clipboard from the desktop decides — their next paste there or, if the
// browser already granted clipboard-read, their coming back — the page
// clipboard unchanged since the bridge last saw it: the app's text is
// newer, it is written to the page (and pasted); changed (the user copied
// something meanwhile, text or not): the page's content wins. An app
// clearing its selection (a password manager's timeout) clears the page
// clipboard too when it still holds that app's text; while the user is
// away, at their next look, if it still does. An app that merely goes away
// leaves the page clipboard alone, and its text still pastes from the page.
//
// It needs a relay that bridges the clipboard (Engine.selectionBridged():
// its FEATURE selection_cache). On a link whose relay can't (wlandr 0.1.0)
// the bridge is inert — one log line, at the link's first event past its
// FEATURE frames; no reads or writes either way; input's chords are plain
// keys, as with `clipboard: false` (hooks.active) — and decided again when
// a link opens.

import { NO_SELECTION_BRIDGE, readSelectionText, setSelectionText, TEXT_MIMES, type Engine, type Event as WlandEvent } from './engine.ts';
import type { ClipboardHooks } from './input.ts';

export interface ClipboardBridgeOptions {
  engine: Engine;
  /** The desktop: keyboard focus inside it (the IME sink) is the
   *  desktop's. */
  container: HTMLElement;
  /** Largest text either way, in UTF-8 bytes. Default 4 MiB. */
  maxBytes?: number;
  log?(line: string): void;
}

export interface ClipboardBridge {
  /** For createInput (InputOptions.clipboard). */
  hooks: ClipboardHooks;
  /** Feed every engine event. */
  handle(event: WlandEvent): void;
  /** Remove its listeners; pending reads and writes are dropped. */
  dispose(): void;
}

/** How long after a key or button press in the desktop an app's new
 *  selection is still written to the page at once (the browsers' transient
 *  activation is about as long). */
const GESTURE_MS = 5000;

export function createClipboardBridge(options: ClipboardBridgeOptions): ClipboardBridge {
  const { engine, container } = options;
  const maxBytes = options.maxBytes ?? 4 * 1024 * 1024;
  const log = options.log || (() => {});
  const enc = new TextEncoder();
  let disposed = false;

  // (the module comment's table has the rules)
  let wlText: string | null = null;    // the Wayland clipboard's text, when known
  let owed: string | null = null;      // to write to the page ('' = clear it)
  let verify: { write: string; ifPage: string | null } | null = null; // decided at the next look
  let pageKnown: string | null = null; // the page clipboard as last written or seen here
  let pageOurs = false;                // pageKnown is an app's text the bridge wrote
  let wlEmpty = !engine.selection().mimes.length; // the Wayland clipboard holds nothing
  let seq = 0;                         // selection changes seen (stale reads are dropped)
  let leaves = 0;                      // times the desktop was left (a read spanning one is "outside")
  let lastGesture = -Infinity;
  let refusedLogged = false;
  let taking = false;                  // inside look()'s setSelection
  let inertLogged = false;             // this link's relay can't bridge: said once

  // the link's relay bridges the clipboard (not yet known: not now either)
  function bridged(): boolean {
    const b = engine.selectionBridged();
    if (b === false && !inertLogged) {
      inertLogged = true;
      log(`clipboard: ${NO_SELECTION_BRIDGE}; the page clipboard is not bridged on this link (copy/paste chords are plain keys)`);
    }
    return b === true;
  }

  const clipboard = () => (typeof navigator !== 'undefined' ? navigator.clipboard : undefined);
  const desktopFocused = () => container.contains(document.activeElement);
  let inside = desktopFocused() && !document.hidden;

  function write(inGesture: boolean) {
    if (disposed || owed === null || !inside) return;
    if (!inGesture && performance.now() - lastGesture > GESTURE_MS) return;
    const cb = clipboard();
    if (!cb || typeof cb.writeText !== 'function') return; // (an insecure page) the copy event still can
    const text = owed;
    let p: Promise<void>;
    try { p = cb.writeText(text); } catch (e) { return refused(e); }
    Promise.resolve(p).then(() => {
      pageKnown = text;
      pageOurs = text !== '';
      if (owed === text) owed = null;
    }, refused);
  }
  function refused(e: unknown) {
    if (refusedLogged) return;
    refusedLogged = true;
    log(`clipboard: the browser refused a page clipboard write (${(e as { name?: string })?.name ?? e}); ` +
      'it is retried at the next key or click in the desktop, or Ctrl+C');
  }

  // a look at the page clipboard (a paste event, a permitted read) showing
  // `text`, or (`other`) no text but content of other types: the page
  // clipboard changed to something not bridged; `gesture`: inside a user
  // gesture's handler (a write may happen)
  function look(text: string, gesture: boolean, other = false) {
    if (disposed) return;
    const seen = other ? null : text; // (null never equals what was known)
    if (verify) {
      const v = verify;
      verify = null;
      if (seen !== null && seen === v.ifPage) { // unchanged since: the decided write is newer
        owed = v.write;
        write(gesture);
        return;
      }
    }
    if (owed === '') {
      if (seen !== null && seen === pageKnown) { write(gesture); return; } // still the cleared text: not pasted, cleared
      owed = null; // the page holds something else now: nothing to clear
    }
    if (other) { // the user's content: nothing to write over it, nothing to paste
      pageKnown = null;
      pageOurs = false;
      return;
    }
    if (!text) return;
    if (text === pageKnown) {
      // unchanged since this bridge last saw it: the Wayland side holds it,
      // or something newer — unless it holds nothing (the app that copied
      // it went, it cleared what the page did not hold, the link
      // reconnected): then the page's text is the clipboard again
      if (owed === null && wlEmpty) take(text);
      return;
    }
    if (enc.encode(text).length > maxBytes) {
      log(`clipboard: the page clipboard's text is over ${maxBytes} bytes; not pasted`);
      return;
    }
    pageKnown = text;
    pageOurs = false;
    if (owed !== null) return; // older than the app's selection the page never got
    if (text === wlText) return;
    take(text);
  }
  // make the page's text the selection (the bridge's own: conn 0)
  function take(text: string) {
    taking = true;
    try {
      if (setSelectionText(engine, text)) { wlText = text; wlEmpty = false; }
    } finally { taking = false; }
  }

  // focusing the desktop reads the page clipboard, if (and only if) the
  // browser has already granted clipboard-read
  function readGranted() {
    if (!bridged()) return;
    const cb = clipboard();
    const perms = typeof navigator !== 'undefined' ? navigator.permissions : undefined;
    if (!cb || typeof cb.readText !== 'function' || !perms || typeof perms.query !== 'function') return;
    let q: Promise<PermissionStatus>;
    try { q = perms.query({ name: 'clipboard-read' as PermissionName }); } catch { return; } // (Firefox: unknown name)
    Promise.resolve(q).then((st) => {
      if (st.state !== 'granted' || disposed || !inside) return;
      return cb.readText().then((text) => { if (inside) look(text, false); });
    }).catch(() => {});
  }

  function enter() {
    if (inside) return;
    inside = true;
    readGranted();
  }
  function leave() {
    if (!inside) return;
    inside = false;
    leaves++;
    // what the page was owed is decided when the user is back: the page
    // clipboard may change meanwhile
    if (owed !== null) verify = { write: owed, ifPage: pageKnown };
    owed = null;
  }
  const onFocusIn = (ev: FocusEvent) => {
    if (container.contains(ev.target as Node)) enter();
    else leave();
  };
  // Focus leaving for nothing focusable (a click on plain page text, an
  // embedder's blur()) fires no focusin anywhere: a focusout whose focus
  // did not land back in the desktop is a leave too — settled in a
  // microtask, so input's own blur-and-refocus of its sink is not one. (A
  // window blur fires focusout as well, with the focus still in place: the
  // window's blur below has it.)
  const onFocusOut = () => {
    queueMicrotask(() => { if (!disposed && !desktopFocused()) leave(); });
  };
  const onWindowBlur = () => leave();
  const onWindowFocus = () => { if (desktopFocused()) enter(); };
  const onVisibility = () => { if (document.hidden) leave(); };
  document.addEventListener('focusin', onFocusIn);
  document.addEventListener('focusout', onFocusOut);
  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('blur', onWindowBlur);
  window.addEventListener('focus', onWindowFocus);

  // the page clipboard's text in a paste event, and whether it holds other
  // content instead (an image, files: types without text/plain's text)
  function pasted(data: DataTransfer | null): { text: string; other: boolean } {
    if (!data) return { text: '', other: false };
    const text = data.getData('text/plain') || '';
    let types: readonly string[] = [];
    try { types = Array.from(data.types || []); } catch { /* (none) */ }
    return { text, other: !text && types.some((t) => t !== 'text/plain') };
  }

  const hooks: ClipboardHooks = {
    gesture() {
      lastGesture = performance.now();
      inside = true; // (a press in the desktop: it has the focus, whatever the events said)
      write(true);
    },
    outside() {
      leave();
    },
    active() {
      return !disposed && bridged();
    },
    wantsCopy() {
      return !disposed && owed !== null;
    },
    copy(data) {
      if (disposed || owed === null || !data) return false;
      data.setData('text/plain', owed);
      pageKnown = owed;
      pageOurs = owed !== '';
      owed = null;
      return true;
    },
    paste(data) {
      inside = true;
      if (!bridged()) return;
      const { text, other } = pasted(data);
      look(text, true, other);
    },
  };

  function handle(ev: WlandEvent) {
    if (disposed) return;
    if (ev.type === 'open') { inertLogged = false; return; } // a new link: its relay decides again
    if (!inertLogged) bridged(); // (logs at the first event of a link whose relay can't)
    if (ev.type !== 'selection' || !bridged()) return;
    const my = ++seq;
    wlEmpty = !ev.mimes.length;
    if (ev.conn === 0 && !ev.mimes.length) { // its owner went (or the embedder cleared its own)
      wlText = null;
      return;
    }
    if (ev.conn !== 0 && !ev.mimes.length) { // an app cleared it (set_selection(null))
      const cleared = wlText;
      wlText = null;
      owed = verify = null;
      if (cleared !== null && pageOurs && cleared === pageKnown) { // the page holds it
        if (inside) { owed = ''; write(false); }
        else verify = { write: '', ifPage: pageKnown };
      }
      return;
    }
    if (ev.conn === 0) { // the bridge's own (look() sets wlText), or another embedder's own
      if (!taking) wlText = null;
      owed = verify = null;
      return;
    }
    owed = verify = null;
    wlText = null;
    if (!TEXT_MIMES.some((m) => ev.mimes.includes(m))) return;
    const wasInside = inside, left = leaves;
    readSelectionText(engine, { maxBytes }).then((text) => {
      if (my !== seq || disposed) return;
      if (text == null) {
        log(`clipboard: app ${ev.conn}'s selection could not be read as text (over ${maxBytes} bytes, or no answer)`);
        return;
      }
      wlText = text;
      if (!(wasInside && inside && leaves === left)) { // set while the user was elsewhere
        verify = text === pageKnown ? null : { write: text, ifPage: pageKnown };
        return;
      }
      if (text === pageKnown) return;
      owed = text;
      write(false);
    }, () => {});
  }

  return {
    hooks,
    handle,
    dispose() {
      if (disposed) return;
      disposed = true;
      document.removeEventListener('focusin', onFocusIn);
      document.removeEventListener('focusout', onFocusOut);
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('blur', onWindowBlur);
      window.removeEventListener('focus', onWindowFocus);
    },
  };
}
