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
};
const BTN: Record<number, number | undefined> = { 0: 0x110, 1: 0x112, 2: 0x111 }; // left, middle, right
const ROLE_TOPLEVEL = 1, ROLE_POPUP = 4;

const now = () => performance.now() >>> 0;

type Focus = { conn: number; surface: number };
type Listener = [type: string, fn: (ev: any) => void, opts?: boolean | AddEventListenerOptions];

export function createInput(options: InputOptions): Input {
  const { engine, view, container } = options;
  const onFocusChange = options.onFocusChange || (() => {});
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
  });
  container.appendChild(sink);

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
      if (active) engine.keyboardLeave(active.conn);
      active = { conn, surface };
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
    if (leave) engine.keyboardLeave(active.conn);
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
      if (active) {
        engine.keyboardLeave(active.conn);
        active = null;
        onFocusChange();
        updateInputMode();
      }
    });
  });

  sink.addEventListener('keydown', (ev) => {
    if (!active || ev.isComposing || ev.keyCode === 229) return; // IME owns it
    const code = EVDEV[ev.code];
    if (code !== undefined) { engine.key(active.conn, now(), code, true); ev.preventDefault(); }
  });
  sink.addEventListener('keyup', (ev) => {
    if (!active || ev.isComposing) return;
    const code = EVDEV[ev.code];
    if (code !== undefined) { engine.key(active.conn, now(), code, false); ev.preventDefault(); }
  });
  // compositionupdate carries the preedit, compositionend the committed text
  // (empty = cancelled → clear the preedit)
  sink.addEventListener('compositionupdate', (ev) => {
    if (active) engine.textInputPreedit(active.conn, ev.data || '');
  });
  sink.addEventListener('compositionend', (ev) => {
    if (active) {
      if (ev.data) engine.textInputCommit(active.conn, ev.data);
      else engine.textInputPreedit(active.conn, '');
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
    if (ev.altKey) return; // Alt+drag belongs to the window manager
    const s = target(ev);
    if (!s) return;
    // a click anywhere in a window focuses its toplevel; preventDefault keeps
    // decoration clicks from moving DOM focus off the sink
    const root = view.surfaceOf(view.canvas(s.conn, s.root));
    if (root && root.role === ROLE_TOPLEVEL) focus(s.conn, s.root);
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
      release();
      lockWant = null;
      if (locked) releaseLock();
      active = null;
      sink.remove();
    },
  };
}
