// wland input: DOM events → engine calls. Pointer events on any surface
// canvas (found through view.surfaceOf, so it works wherever windows are
// mounted), keyboard through a hidden IME sink, browser composition → text
// input. Motion is forwarded raw; the engine coalesces it next to the link
// (that is where the backpressure signal lives). The types below are the
// contract.

import type { Engine, Event as WlandEvent } from './engine.ts';
import type { View } from './view.ts';

export interface InputOptions {
  engine: Engine;
  view: View;
  /** Where the hidden IME sink element is appended. */
  container: HTMLElement;
  /** Keyboard focus moved to another toplevel, or was lost. */
  onFocusChange?(): void;
  /** The clipboard bridge (lib/clipboard.ts). With it, the paste chords
   *  keep the browser's default action, so the browser fires `paste` on the
   *  IME sink, and from a paste chord's press on, key events (and
   *  lock-state syncs, IME text) reach the app only after `paste` ran (from
   *  the paste event, or 300 ms later when none came), so the app reads the
   *  selection the paste set. The copy chords keep their default only while
   *  the bridge has text for the browser's `copy` event (wantsCopy); every
   *  copy/cut event while the desktop has the focus is cancelled, so the
   *  page's own selection is never copied from the desktop. The chords are
   *  the platform's: Ctrl+C/X/V (Ctrl+Insert, Shift+Insert) — on Apple
   *  platforms Cmd+C/X/V, which reach the app as Ctrl+C/X/V (see
   *  clipboardChord). */
  clipboard?: ClipboardHooks;
}

/** What input tells the clipboard bridge (InputOptions.clipboard). */
export interface ClipboardHooks {
  /** A paste event on the IME sink (a paste chord, Shift+Insert, the
   *  browser's Edit menu): the page clipboard's data. */
  paste(data: DataTransfer | null): void;
  /** Whether a copy chord pressed in the desktop now should keep its
   *  browser default (a `copy` event the bridge writes with). False: the
   *  chord is a plain key, no copy event happens. */
  wantsCopy(): boolean;
  /** A copy or cut event while the desktop has the focus: set the data if
   *  there is some to write (true), else leave it (false). The event is
   *  cancelled either way: what the page has selected is not copied. */
  copy(data: DataTransfer | null): boolean;
  /** A user gesture inside the desktop (a key or button press on it),
   *  before it goes to the app: the moment the browser allows a clipboard
   *  write. */
  gesture(): void;
  /** A button press outside the desktop (neither in the container nor on a
   *  surface): the user is elsewhere, though the keyboard focus may have
   *  stayed (a press whose default the page prevents). */
  outside(): void;
  /** Whether the bridge works now (absent: always). False (its link's
   *  relay can't bridge the clipboard): the chords are plain keys, as
   *  without a bridge — no paste hold, no copy default. */
  active?(): boolean;
}

/** Which clipboard chord a keydown is, if any: the keys the browser makes
 *  a paste or copy/cut event of. Elsewhere: Ctrl+V, Ctrl+Shift+V,
 *  Shift+Insert paste; Ctrl+C, Ctrl+Insert copy; Ctrl+X cut. On Apple
 *  platforms Cmd instead of Ctrl (and no Insert chords): there Ctrl+V is no
 *  paste — it goes to the app at once as a plain key — and Cmd+C/X/V reach
 *  the app as Ctrl+C/X/V (createInput), the chords Linux apps know (a
 *  terminal's Ctrl+V is literal-next: it pastes with Ctrl+Shift+V, which
 *  Cmd+Shift+V becomes). (The Apple half follows the browsers' documented
 *  behaviour; it has not run on a Mac.) */
function clipboardChord(ev: Pick<KeyboardEvent, 'code' | 'ctrlKey' | 'metaKey' | 'shiftKey' | 'altKey'>, apple: boolean): 'paste' | 'copy' | null {
  if (ev.altKey) return null;
  const mod = apple ? ev.metaKey && !ev.ctrlKey : ev.ctrlKey && !ev.metaKey;
  if (mod && ev.code === 'KeyV') return 'paste';
  if (mod && !ev.shiftKey && (ev.code === 'KeyC' || ev.code === 'KeyX')) return 'copy';
  if (apple) return null;
  if (ev.shiftKey && !ev.ctrlKey && !ev.metaKey && ev.code === 'Insert') return 'paste';
  if (mod && !ev.shiftKey && ev.code === 'Insert') return 'copy';
  return null;
}

/** macOS and iOS/iPadOS: Cmd is the clipboard modifier there. */
function applePlatform(): boolean {
  if (typeof navigator === 'undefined') return false;
  const nav = navigator as { userAgentData?: { platform?: string }; platform?: string };
  const p = nav.userAgentData?.platform || nav.platform || '';
  return /^(macOS|Mac|iPhone|iPad|iPod)/i.test(p);
}

export interface Input {
  /** Feed every engine event, after the view (focus dies silently with its
   *  surface and passes to the topmost window left; the IME sink follows
   *  the text cursor). */
  handle(event: WlandEvent): void;
  /** Give a toplevel keyboard focus (not a minimized one: restore it
   *  first). */
  focus(conn: number, surface: number): void;
  /** Whether a toplevel holds keyboard focus. */
  focused(conn: number, surface: number): boolean;
  /** While on, pointer events are not forwarded (a window-manager grab owns
   *  the pointer). */
  suppress(on: boolean): void;
  /** Remove its document listeners and the IME sink. DOM only: the engine
   *  is not told (dispose the engine as well, or stop feeding it). */
  dispose(): void;
}

// KeyboardEvent.code → linux evdev keycode
const EVDEV: Record<string, number | undefined> = {
  Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6, Digit6: 7, Digit7: 8,
  Digit8: 9, Digit9: 10, Digit0: 11, Minus: 12, Equal: 13, Backspace: 14, Tab: 15,
  KeyQ: 16, KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22, KeyI: 23, KeyO: 24,
  KeyP: 25, BracketLeft: 26, BracketRight: 27, Enter: 28, ControlLeft: 29, KeyA: 30,
  KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36, KeyK: 37, KeyL: 38,
  Semicolon: 39, Quote: 40, Backquote: 41, ShiftLeft: 42, Backslash: 43, KeyZ: 44,
  KeyX: 45, KeyC: 46, KeyV: 47, KeyB: 48, KeyN: 49, KeyM: 50, Comma: 51, Period: 52,
  Slash: 53, ShiftRight: 54, NumpadMultiply: 55, AltLeft: 56, Space: 57, CapsLock: 58,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68,
  F11: 87, F12: 88, ControlRight: 97, AltRight: 100, Home: 102, ArrowUp: 103,
  PageUp: 104, ArrowLeft: 105, ArrowRight: 106, End: 107, ArrowDown: 108,
  PageDown: 109, Insert: 110, Delete: 111, MetaLeft: 125, MetaRight: 126,
  // the keypad and the rest of a full keyboard (all in the core's keymap)
  NumLock: 69, ScrollLock: 70, Numpad7: 71, Numpad8: 72, Numpad9: 73, NumpadSubtract: 74,
  Numpad4: 75, Numpad5: 76, Numpad6: 77, NumpadAdd: 78, Numpad1: 79, Numpad2: 80,
  Numpad3: 81, Numpad0: 82, NumpadDecimal: 83, IntlBackslash: 86, NumpadEnter: 96,
  NumpadDivide: 98, PrintScreen: 99, NumpadEqual: 117, Pause: 119, ContextMenu: 127,
};
const BTN: Record<number, number | undefined> = { 0: 0x110, 1: 0x112, 2: 0x111 }; // left, middle, right
// the keypad keys NumLock turns from navigation into digits
const NUMLOCK_KEYS = new Set(['Numpad0', 'Numpad1', 'Numpad2', 'Numpad3', 'Numpad4', 'Numpad5', 'Numpad6',
  'Numpad7', 'Numpad8', 'Numpad9', 'NumpadDecimal']);

/** The keyboard's lock state as an event shows it (Engine.keyboardLocks),
 *  `was` the state known before. Caps Lock is getModifierState's. NumLock:
 *  a keypad key that NumLock changes says which it is in effect (it typed a
 *  digit: on; navigated: off) — unless Shift is held: the keymap's KEYPAD
 *  type navigates with Shift whatever NumLock is. Any other event can only
 *  say it is on: macOS has no NumLock (getModifierState is false there, yet
 *  the keypad types digits), so a false keeps `was`. The lock keys' own
 *  events change nothing: the core toggles on their press, and browsers
 *  differ on whether that event shows the state before or after. */
function browserLocks(ev: Pick<KeyboardEvent, 'getModifierState' | 'shiftKey'> & { code?: string; key?: string },
  was: { capsLock: boolean; numLock: boolean }): { capsLock: boolean; numLock: boolean } {
  if (typeof ev.getModifierState !== 'function' || ev.code === 'CapsLock' || ev.code === 'NumLock') return was;
  let numLock = was.numLock;
  if (ev.code && NUMLOCK_KEYS.has(ev.code) && typeof ev.key === 'string' && !ev.shiftKey) {
    numLock = /^[0-9.,]$/.test(ev.key);
  } else if (ev.getModifierState('NumLock')) {
    numLock = true;
  }
  return { capsLock: ev.getModifierState('CapsLock'), numLock };
}
const ROLE_TOPLEVEL = 1, ROLE_POPUP = 4;
/** How long a paste chord's keys wait for the browser's paste event. */
const PASTE_WAIT_MS = 300;
const KEY_CTRL = 29, KEY_META_LEFT = 125, KEY_META_RIGHT = 126;
const isMeta = (code: number) => code === KEY_META_LEFT || code === KEY_META_RIGHT;
// modifiers and locks (their releases do arrive under Cmd on macOS)
const MODIFIERS = new Set([42, 54, 29, 97, 56, 100, 125, 126, 58, 69]);

const now = () => performance.now() >>> 0;

type Focus = { conn: number; surface: number };
type Listener = [type: string, fn: (ev: any) => void, opts?: boolean | AddEventListenerOptions];

export function createInput(options: InputOptions): Input {
  const { engine, view, container, clipboard } = options;
  const onFocusChange = options.onFocusChange || (() => {});
  const apple = applePlatform();
  let suppressed = false; // a window-manager grab owns the pointer
  let active: Focus | null = null; // the toplevel holding keyboard focus

  const isActive = (conn: number, surface: number) => !!active && active.conn === conn && active.surface === surface;
  // document listeners, kept for dispose()
  const listening: Listener[] = [];
  const on = <K extends keyof DocumentEventMap>(type: K, fn: (ev: DocumentEventMap[K]) => void,
    opts?: boolean | AddEventListenerOptions) => {
    document.addEventListener(type, fn, opts);
    listening.push([type, fn, opts]);
  };

  // (transient activation: a user gesture just happened)
  const activation = () => (navigator as { userActivation?: { isActive: boolean } }).userActivation;

  // --- keyboard + IME sink (zwp_text_input_v3) ----------------------------
  // A canvas can't fire composition events, so real keyboard focus lives on
  // one hidden contenteditable. Focusing a toplevel canvas (click, map,
  // raise) redirects here. Plain keys go to evdev; the isComposing /
  // keyCode-229 guard keeps composition keystrokes out of evdev so composed
  // text isn't delivered twice — composition events drive text input.
  //
  // On touch devices a focused contenteditable opens the on-screen keyboard,
  // so the sink keeps inputmode="none" (hardware keys still arrive) and turns
  // the keyboard on only while the focused client has an enabled text input:
  // a press anywhere must not pop a keyboard over a client that takes no text.
  const sink = document.createElement('div');
  sink.contentEditable = 'true';
  sink.inputMode = 'none';
  sink.setAttribute('aria-hidden', 'true');
  Object.assign(sink.style, {
    position: 'fixed', left: '0px', top: '0px', width: '1px', height: '1em',
    opacity: '0', outline: 'none', border: 'none', padding: '0', margin: '0',
    background: 'transparent', color: 'transparent', caretColor: 'transparent',
    whiteSpace: 'pre', overflow: 'hidden', pointerEvents: 'none', zIndex: '40',
    // the view makes the container user-select: none (touch); an editable
    // under it must say text, or WebKit takes no typing
    userSelect: 'text', webkitUserSelect: 'text',
  });
  container.appendChild(sink);

  // the keyboard's lock state as last seen on an event (browserLocks); the
  // core's until then (NumLock on). Synced before every key and at enter.
  let locks = { capsLock: false, numLock: true };
  let locksSeen = false;
  const readLocks = (ev: KeyboardEvent | MouseEvent) => {
    if (typeof ev.getModifierState !== 'function') return;
    locks = browserLocks(ev, locks);
    locksSeen = true;
  };
  // before a key: a lock key's own press toggles in the core instead (and
  // here, to stay in step), its release changes nothing. In order with the
  // keys: while a paste holds them, the sync waits its turn too.
  const syncLocks = (ev?: KeyboardEvent) => {
    if (ev && (ev.code === 'CapsLock' || ev.code === 'NumLock')) {
      if (ev.type === 'keydown') {
        locks = ev.code === 'CapsLock' ? { ...locks, capsLock: !locks.capsLock } : { ...locks, numLock: !locks.numLock };
      }
      return;
    }
    if (!locksSeen) return;
    const { capsLock, numLock } = locks;
    later(() => engine.keyboardLocks(capsLock, numLock));
  };

  // conns whose text input is enabled (zwp_text_input_v3, from the core)
  const textInput = new Set<number>();
  // The on-screen keyboard opens only for a focus made inside a user
  // gesture. An app that enables its text input in answer to the tap
  // (Chromium: a page's field, the omnibox — foot has it on from the enter)
  // does so after the press, outside any gesture: the refocus below then
  // changes the mode without raising the keyboard. `keyboardOwed` has the
  // tap's release (the gesture itself for a touch, usually still to come),
  // or the next tap, do it again.
  let keyboardOwed = false;
  const refocus = () => {
    // browsers re-read inputmode on focus: refocus to show/hide the keyboard
    // (the blur handler sees the sink focused again and keeps the focus)
    sink.blur();
    sink.focus({ preventScroll: true });
  };
  function updateInputMode() {
    const mode = active && textInput.has(active.conn) ? 'text' : 'none';
    if (sink.inputMode === mode) return;
    sink.inputMode = mode;
    keyboardOwed = false;
    if (document.activeElement === sink) {
      refocus();
      keyboardOwed = mode === 'text' && !activation()?.isActive;
    }
  }
  on('pointerup', (ev) => {
    if (!keyboardOwed || ev.pointerType === 'mouse') return;
    keyboardOwed = false;
    if (document.activeElement === sink && sink.inputMode === 'text') refocus();
  }, true);

  function focus(conn: number, surface: number) {
    if (view.window(conn, surface)?.minimized) return; // hidden: the core refuses it too
    if (!isActive(conn, surface)) {
      releasePaste(); // queued keys go to the conn they were typed into
      if (active) {
        if (active.conn !== conn) releaseHeld(); // (another window of the same app keeps them)
        engine.keyboardLeave(active.conn);
      }
      active = { conn, surface };
      syncLocks(); // the enter's modifiers carry the browser's lock state
      engine.keyboardEnter(conn, surface);
      onFocusChange();
    }
    updateInputMode();
    if (document.activeElement !== sink) sink.focus({ preventScroll: true });
  }

  // the focused surface or conn went away: drop routing WITHOUT a leave (a
  // leave naming a dead surface kills the client), unless the surface lives
  // on unmapped (`leave`). Focus then passes to the topmost window left, as
  // closing a window does on a desktop: the keyboard was ours (active is
  // cleared when DOM focus leaves the sink), so it stays with us.
  function forget(matches: (a: Focus) => boolean, leave = false) {
    if (!active || !matches(active)) return;
    releasePaste();
    if (leave) { releaseHeld(); engine.keyboardLeave(active.conn); }
    active = null;
    const next = topWindow();
    if (next) return focus(next.conn, next.surface);
    onFocusChange();
    updateInputMode();
  }

  // the mapped window stacked highest: the view keeps the stacking in each
  // window element's z-index (view.raise); among equals, the newest.
  // Minimized windows are passed over.
  function topWindow(): Focus | null {
    let top: Focus | null = null, topZ = -Infinity;
    for (const w of view.windows()) {
      if (w.minimized) continue;
      const z = Number(w.element.style.zIndex) || 0;
      if (z >= topZ) { top = w; topZ = z; }
    }
    return top;
  }

  on('focusin', (ev) => {
    const s = view.surfaceOf(ev.target);
    if (s && s.role === ROLE_TOPLEVEL) focus(s.conn, s.surface);
  });

  // focus leaving the sink for something that ISN'T one of our canvases
  // (other page UI, another app) is a real keyboard-focus loss. The microtask
  // lets a canvas→sink redirect settle first.
  sink.addEventListener('blur', () => {
    queueMicrotask(() => {
      const ae = document.activeElement;
      if (ae === sink || view.surfaceOf(ae)) return;
      forgetBrowserKeys();
      if (active) {
        releasePaste();
        releaseHeld();
        engine.keyboardLeave(active.conn);
        active = null;
        onFocusChange();
        updateInputMode();
      }
    });
  });

  // From a paste chord's press until its paste event ran (clipboard),
  // everything keyboard-side the app would see queues here, in order: keys
  // (their repeats and releases too), lock-state syncs, IME text. Chromium
  // fires paste within the keydown's task; Firefox a little later (its
  // parent process handles the shortcut), often after the keyup; with no
  // paste event at all (refused) they go after PASTE_WAIT_MS. A focus
  // change sends them first, to the conn they were typed into.
  let pasteQueue: (() => void)[] | null = null;
  let pasteTimer: ReturnType<typeof setTimeout> | undefined;
  const releasePaste = () => {
    const q = pasteQueue;
    if (!q) return;
    pasteQueue = null;
    clearTimeout(pasteTimer);
    for (const fn of q) fn();
  };
  const later = (fn: () => void) => {
    if (pasteQueue) pasteQueue.push(fn);
    else fn();
  };
  const sendKey = (conn: number, code: number, pressed: boolean) => later(() => engine.key(conn, now(), code, pressed));

  // The keys the app has down: a press adds one, and a release goes to the
  // app only for one of them. Releases the browser never delivers — the
  // window lost focus mid-press (Alt+Tab, Cmd+Tab), macOS's keyups under
  // Cmd — would leave the key down in the app, and the core's modifier
  // state for that conn with it (its next keyboard enter would carry a
  // Ctrl or Super nobody holds): so every one is let go of before the
  // keyboard leaves its conn, when the window loses focus, and (Apple) when
  // Cmd goes up. A release arriving after that is ignored.
  const pressed = new Set<number>();
  const press = (conn: number, code: number) => { pressed.add(code); sendKey(conn, code, true); };
  const unpress = (conn: number, code: number) => { if (pressed.delete(code)) sendKey(conn, code, false); };
  function releaseHeld() {
    const conn = active?.conn;
    if (conn !== undefined) for (const code of pressed) sendKey(conn, code, false);
    pressed.clear();
    cmdKeys.clear();
  }
  // what the browser said is held, unknown once the focus went elsewhere
  function forgetBrowserKeys() {
    metaHeld.clear();
    cmdKeys.clear();
  }

  // Apple platforms. Cmd+C/X/V reach the app as Ctrl+C/X/V, a chord of its
  // own sent whole at the chord's press — Super up (the Cmd press already
  // went to the app), Ctrl down, the key down and up, Ctrl up, Super down
  // again while Cmd is held — so nothing depends on the key's release:
  // macOS browsers fire no keyup for a key released while Cmd is held, and
  // the real one, when it comes, finds the key not pressed. The same rule
  // for every other key pressed with Cmd held (`cmdKeys`): the last Cmd's
  // release lets go of them. `metaHeld`: the Cmd keys the browser has down.
  const metaHeld = new Set<number>(), cmdKeys = new Set<number>();
  function appleChord(conn: number, code: number) {
    const metas = [...pressed].filter(isMeta);
    for (const m of metas) unpress(conn, m);
    sendKey(conn, KEY_CTRL, true);
    sendKey(conn, code, true);
    sendKey(conn, code, false);
    sendKey(conn, KEY_CTRL, false);
    for (const m of metas) if (metaHeld.has(m)) press(conn, m);
  }

  sink.addEventListener('keydown', (ev) => {
    readLocks(ev);
    if (!active || ev.isComposing || ev.keyCode === 229) return; // IME owns it
    clipboard?.gesture();
    const code = EVDEV[ev.code];
    if (code !== undefined) {
      const conn = active.conn;
      syncLocks(ev); // first: the app reads the key with the browser's lock state
      const clip = clipboard && (!clipboard.active || clipboard.active()) ? clipboard : null;
      const chord = clip ? clipboardChord(ev, apple) : null;
      if (chord === 'paste' && !pasteQueue) {
        pasteQueue = [];
        pasteTimer = setTimeout(releasePaste, PASTE_WAIT_MS);
      }
      if (isMeta(code)) metaHeld.add(code);
      if (chord && apple) appleChord(conn, code);
      else {
        press(conn, code);
        if (apple && ev.metaKey && !MODIFIERS.has(code)) cmdKeys.add(code);
      }
      // a paste chord keeps its default action (the browser's paste
      // event); a copy chord only while the bridge has text for the copy
      // event — else the browser would copy whatever the page has selected
      if (!(chord === 'paste' || (chord === 'copy' && clip!.wantsCopy()))) ev.preventDefault();
    }
  });
  sink.addEventListener('keyup', (ev) => {
    readLocks(ev);
    if (!active || ev.isComposing) return;
    const code = EVDEV[ev.code];
    if (code === undefined) return;
    ev.preventDefault();
    syncLocks(ev);
    const conn = active.conn;
    if (isMeta(code)) {
      metaHeld.delete(code);
      if (apple && !ev.metaKey) { // the last Cmd went up: what it held up first
        for (const c of cmdKeys) unpress(conn, c);
        cmdKeys.clear();
      }
    }
    unpress(conn, code);
    cmdKeys.delete(code);
  });
  // the window lost focus (another window, Alt/Cmd+Tab): DOM focus stays on
  // the sink and the app keeps its keyboard focus, but the releases of what
  // is held now go to another window
  const onWindowBlur = () => {
    releaseHeld();
    forgetBrowserKeys();
  };
  window.addEventListener('blur', onWindowBlur);
  // on the document: Chromium targets the sink, Firefox the element holding
  // the page's selection (the body: an empty sink holds no caret). While the
  // sink has the focus, any of them is the desktop's.
  if (clipboard) {
    const hooks = clipboard;
    on('paste', (ev) => {
      if (document.activeElement !== sink) return;
      ev.preventDefault(); // nothing lands in the page
      hooks.paste(ev.clipboardData);
      releasePaste();
    });
    // cancelled whatever the bridge sets: with nothing set the clipboard is
    // left as it was, and what the page has selected is never copied from
    // the desktop (Firefox keeps a page selection across a click into it)
    const copy = (ev: ClipboardEvent) => {
      if (document.activeElement !== sink) return;
      ev.preventDefault();
      hooks.copy(ev.clipboardData);
    };
    on('copy', copy);
    on('cut', copy);
  }
  // compositionupdate carries the preedit, compositionend the committed text
  // (empty = cancelled → clear the preedit)
  // (queued behind a paste's keys like they are)
  sink.addEventListener('compositionupdate', (ev) => {
    if (!active) return;
    const conn = active.conn, text = ev.data || '';
    later(() => engine.textInputPreedit(conn, text));
  });
  sink.addEventListener('compositionend', (ev) => {
    if (active) {
      const conn = active.conn, text = ev.data;
      later(() => {
        if (text) engine.textInputCommit(conn, text);
        else engine.textInputPreedit(conn, '');
      });
    }
    sink.textContent = '';
  });

  // --- pointer: delegated, so windows can be mounted anywhere --------------
  const target = (ev: UIEvent) => (suppressed ? null : view.surfaceOf(ev.target));

  // The implicit grab: while a button is held the pressed surface keeps the
  // pointer (a Wayland seat's rule; the browser would hand it to whatever is
  // under it). Pointer capture on the press's target — the canvas or its
  // input region's hit element — makes the browser do it: every event goes
  // to that element, no pointerout fires on the way out (motion goes on in
  // its surface-local px, outside it too), and the boundary events after the
  // last release bring the leave/enter. It is let go where a grab takes the
  // pointer over: a window-manager grab or drag (suppress), and a popup of
  // the pressed client mapping (a popup grab: its surfaces then get the
  // pointer by position, as GTK's press-drag-release menus need).
  let captured: { el: Element; id: number; conn: number; surface: number } | null = null;
  function release() {
    const c = captured;
    captured = null;
    if (!c) return;
    try { if (c.el.hasPointerCapture(c.id)) c.el.releasePointerCapture(c.id); } catch { /* gone */ }
  }
  const local = (ev: MouseEvent) => {
    const r = (ev.target as Element).getBoundingClientRect();
    return [ev.clientX - r.left, ev.clientY - r.top];
  };

  // --- pointer lock (zwp_pointer_constraints_v1.lock_pointer) -------------
  // The core decides when a lock applies and names its surface in a
  // 'pointer-lock' event; this asks the browser for Pointer Lock on that
  // surface's hit target and reports what the browser does: a grant
  // (pointerlockchange to that element) → pointerLockGranted → the app's
  // `locked`; the lock ending unasked (Esc, the tab losing focus) →
  // pointerLockLost → `unlocked`. Browsers grant only during or shortly
  // after a user gesture and refuse for a while after the user left a lock,
  // so a request is made at once only while the page has transient
  // activation (the press that made the app ask), and otherwise — or after
  // a refusal — at the next press on that surface while it is still wanted.
  // Raw (unaccelerated) movement is asked for where the platform has it.
  let lockWant: { conn: number; surface: number } | null = null; // the core's last 'pointer-lock'
  let locked: { conn: number; surface: number } | null = null;   // granted and reported
  let rawMovement = true; // unadjustedMovement not refused yet (Linux has none)

  function requestLock() {
    const want = lockWant;
    const el = want && view.hitTarget(want.conn, want.surface);
    if (!want || !el || typeof el.requestPointerLock !== 'function') return;
    let p: unknown;
    try {
      p = (el.requestPointerLock as (o?: { unadjustedMovement?: boolean }) => unknown)(
        ...(rawMovement ? [{ unadjustedMovement: true }] : []));
    } catch { return; } // retried at the next press
    if (p && typeof (p as Promise<void>).then === 'function') {
      (p as Promise<void>).catch((e: { name?: string }) => {
        // the same request without the option, still within the gesture's
        // activation; any other refusal waits for the next press
        if (e && e.name === 'NotSupportedError' && rawMovement) {
          rawMovement = false;
          if (lockWant === want) requestLock();
        }
      });
    }
  }
  // let go of the browser's lock (the core no longer wants it: no report)
  function releaseLock() {
    const ours = view.surfaceOf(document.pointerLockElement);
    locked = null;
    if (ours) document.exitPointerLock();
  }
  on('pointerlockchange', () => {
    const s = view.surfaceOf(document.pointerLockElement);
    const want = lockWant;
    if (s && want && s.conn === want.conn && s.surface === want.surface) {
      if (!locked) {
        locked = want;
        engine.pointerLockGranted(want.conn, want.surface);
      }
      return;
    }
    if (locked) {
      const lost = locked;
      locked = null;
      engine.pointerLockLost(lost.conn);
    }
    // one of ours locked that nobody wants (a grant after the withdrawal)
    if (s) document.exitPointerLock();
  });

  // (no boundary events while the pointer is locked: it stays on its surface)
  on('pointerover', (ev) => {
    const s = locked ? null : target(ev);
    if (!s) return;
    const [x, y] = local(ev);
    engine.pointerEnter(s.conn, s.surface, x, y);
  });
  on('pointerout', (ev) => {
    const s = locked ? null : target(ev);
    if (s) engine.pointerLeave(s.conn);
  });
  // every motion carries its relative part (zwp_relative_pointer_v1):
  // movementX/Y, which goes on under Pointer Lock while clientX/Y freeze
  // (so does the position: the lock froze it)
  on('pointermove', (ev) => {
    const s = target(ev);
    if (!s) return;
    const [x, y] = local(ev);
    engine.pointerMotion(s.conn, now(), x, y, { dx: ev.movementX || 0, dy: ev.movementY || 0, time: ev.timeStamp * 1000 });
  });
  on('pointerdown', (ev) => {
    readLocks(ev); // what a focus this press makes tells the app
    if (clipboard && !container.contains(ev.target as Node) && !view.surfaceOf(ev.target)) clipboard.outside();
    if (ev.altKey) return; // Alt+drag belongs to the window manager
    const s = target(ev);
    if (!s) return;
    // a click anywhere in a window focuses its toplevel; preventDefault keeps
    // decoration clicks from moving DOM focus off the sink
    const root = view.surfaceOf(view.canvas(s.conn, s.root));
    if (root && root.role === ROLE_TOPLEVEL) focus(s.conn, s.root);
    clipboard?.gesture();
    const btn = BTN[ev.button];
    if (btn !== undefined) engine.pointerButton(s.conn, now(), btn, true);
    ev.preventDefault();
    const el = ev.target as Element;
    if (captured && !captured.el.isConnected) captured = null; // its surface went (no lostpointercapture at it)
    if (!captured && typeof el.setPointerCapture === 'function') {
      try {
        el.setPointerCapture(ev.pointerId);
        captured = { el, id: ev.pointerId, conn: s.conn, surface: s.surface };
      } catch { /* not an active pointer */ }
    }
    // a press on a surface whose lock is still wanted: the user gesture
    // the browser grants Pointer Lock in (after a refusal, an Esc, a blur)
    if (lockWant && !locked && lockWant.conn === s.conn && lockWant.surface === s.surface) requestLock();
  });
  // the last button went up (capture ends after pointerup), or the element
  // left the document (then the event goes to the document)
  on('lostpointercapture', (ev) => {
    if (captured && ev.pointerId === captured.id) captured = null;
  });
  on('pointerup', (ev) => {
    const s = target(ev);
    if (!s) return;
    const btn = BTN[ev.button];
    if (btn !== undefined) engine.pointerButton(s.conn, now(), btn, false);
    ev.preventDefault();
  });
  on('contextmenu', (ev) => {
    if (view.surfaceOf(ev.target)) ev.preventDefault();
  });
  on('wheel', (ev) => {
    const s = target(ev);
    if (!s) return;
    // WheelEvent delta → axis_value120 (120 per detent). Pixel mode: ~120px
    // = one notch (trackpad deltas stay fractional → smooth); line/page
    // modes scaled to land near a notch. The continuous value is scaled so a
    // detent ≈ 10 surface units. value120 is never 0 for a real scroll.
    const mult = ev.deltaMode === 1 ? 40 : ev.deltaMode === 2 ? 120 : 1;
    const t = now();
    const axis = (n: 0 | 1, delta: number) => {
      let v120 = Math.round(delta * mult);
      if (v120 === 0) v120 = delta > 0 ? 1 : -1;
      engine.pointerAxis(s.conn, t, n, v120 / 12, v120);
    };
    if (ev.deltaY) axis(0, ev.deltaY);
    if (ev.deltaX) axis(1, ev.deltaX);
    ev.preventDefault();
  }, { passive: false });

  function handle(ev: WlandEvent) {
    switch (ev.type) {
      case 'pointer-lock':
        if (ev.surface) {
          if (locked && (locked.conn !== ev.conn || locked.surface !== ev.surface)) releaseLock();
          lockWant = { conn: ev.conn, surface: ev.surface };
          if (!locked && activation()?.isActive !== false) requestLock();
        } else if (lockWant && lockWant.conn === ev.conn) {
          lockWant = null;
          releaseLock();
        }
        break;
      case 'commit':
        // a popup grab replaces the implicit grab (see `captured`)
        if (ev.role === ROLE_POPUP && captured && captured.conn === ev.conn && captured.surface !== ev.surface) release();
        break;
      case 'destroy': forget((a) => a.conn === ev.conn && a.surface === ev.surface); break;
      // minimized: the core already sent its keyboard leave (the one here
      // is then a no-op) and its pointer leave; focus passes on, and a
      // press held on it lets go
      case 'minimize':
        if (!ev.minimized) break;
        if (captured && captured.conn === ev.conn && view.surfaceOf(captured.el)?.root === ev.surface) release();
        forget((a) => a.conn === ev.conn && a.surface === ev.surface, true);
        break;
      // unmapped (its xdg_toplevel went) while the wl_surface lives on: it
      // gets its leave, and is a window no more
      case 'surface':
        if (ev.role !== ROLE_TOPLEVEL) forget((a) => a.conn === ev.conn && a.surface === ev.surface, true);
        break;
      case 'disconnect':
        textInput.delete(ev.conn);
        forget((a) => a.conn === ev.conn);
        if (lockWant && lockWant.conn === ev.conn) { lockWant = null; releaseLock(); }
        break;
      case 'text-input': {
        if (ev.active) textInput.add(ev.conn); else textInput.delete(ev.conn);
        updateInputMode();
        // put the sink at the text cursor so the OS candidate window shows
        // there; the rect is surface-local to the focused toplevel
        if (!ev.active || !active || active.conn !== ev.conn) break;
        const canvas = view.canvas(active.conn, active.surface);
        if (canvas && (ev.width > 0 || ev.height > 0)) {
          const r = canvas.getBoundingClientRect();
          sink.style.left = `${r.left + ev.x}px`;
          sink.style.top = `${r.top + ev.y}px`;
          sink.style.height = `${Math.max(1, ev.height)}px`;
        }
        break;
      }
    }
  }

  return {
    handle,
    focus,
    focused: isActive,
    // a grab owns the pointer from here: the implicit grab ends, so the
    // browser tracks what is under the pointer again (its boundary events
    // land while suppressed; the window manager re-enters at the end)
    suppress(on) {
      suppressed = !!on;
      if (suppressed) release();
    },
    // DOM only: the engine is not told (dispose it too, or it keeps routing)
    dispose() {
      for (const [type, fn, opts] of listening.splice(0)) document.removeEventListener(type, fn, opts);
      window.removeEventListener('blur', onWindowBlur);
      pressed.clear();
      forgetBrowserKeys();
      release();
      lockWant = null;
      if (locked) releaseLock();
      clearTimeout(pasteTimer);
      pasteQueue = null;
      active = null;
      sink.remove();
    },
  };
}
