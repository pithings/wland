// A synthetic Wayland client — the moral equivalent of weston-simple-shm,
// speaking real wire bytes. In unkernel, this is any unmodified guest app
// (foot, GTK…) on the relay's unix socket.
//
// One xdg_toplevel with client-side decorations drawn into an shm pool that
// is an ArrayBuffer (the "memfd" the relay keeps). Three buffers; a buffer
// is drawn only while the compositor does not hold it (between its commit
// and its wl_buffer.release). Frames are paced by wl_surface.frame callbacks
// (fired by the engine's tick, i.e. requestAnimationFrame); each frame
// repaints and damages only what changed — a bouncing square, a frame
// counter, the pointer trail, typed keys, the click counter — and every
// damage rect is repainted whole from the scene, so any rect the relay or
// engine reads is correct. XRGB windows write X = 0 on purpose: a presenter
// that forgot to force alpha would show them transparent.
//
// Reacts to: configure (ack_configure; a new size reallocates the pool),
// pointer motion (trail) and buttons (title bar = move, the boxes = close /
// maximize, bottom-right grip = resize, elsewhere = click counter + flash),
// keys (echoed), close, ping.

import { wlMessage as m, wlEach, monotonicNs } from './proto.js';

const XRGB8888 = 1, ARGB8888 = 0;
const BTN_LEFT = 0x110;
const TITLE_H = 28, GRIP = 16, BOX = 18, BORDER = 4;
const NBUF = 3;

// evdev keycode → character
const KEYS = { 2: '1', 3: '2', 4: '3', 5: '4', 6: '5', 7: '6', 8: '7', 9: '8', 10: '9', 11: '0', 12: '-', 52: '.', 53: '/', 57: ' ' };
'QWERTYUIOP'.split('').forEach((c, i) => { KEYS[16 + i] = c; });
'ASDFGHJKL'.split('').forEach((c, i) => { KEYS[30 + i] = c; });
'ZXCVBNM'.split('').forEach((c, i) => { KEYS[44 + i] = c; });

// 3×5 pixel font: rows top to bottom, 3 bits each (MSB left)
const FONT = {
  0: 0o75557, 1: 0o26227, 2: 0o71747, 3: 0o71717, 4: 0o55711, 5: 0o74717, 6: 0o74757, 7: 0o71111,
  8: 0o75757, 9: 0o75717, A: 0o25755, B: 0o65656, C: 0o34443, D: 0o65556, E: 0o74647, F: 0o74644,
  G: 0o34553, H: 0o55755, I: 0o72227, J: 0o11152, K: 0o55655, L: 0o44447, M: 0o57755, N: 0o65555,
  O: 0o25552, P: 0o65644, Q: 0o25563, R: 0o65655, S: 0o34216, T: 0o72222, U: 0o55557, V: 0o55552,
  W: 0o55775, X: 0o55255, Y: 0o55222, Z: 0o71247, ' ': 0, '-': 0o00700, '.': 0o00002, ':': 0o02020,
  '/': 0o11244, '_': 0o00007, '>': 0o42124, '#': 0o57575,
};

// `shared`: the pools' "memfds" are SharedArrayBuffers (memory another
// thread could write: what a kernel in a worker would hand out)
export function createClient({ title, width = 420, height = 300, format = XRGB8888, hue = 210, shared = false }) {
  let sock = null;
  let nextId = 2;
  const objects = new Map([[1, 'wl_display']]);
  const out = [];
  let outFds = [];
  const send = (msg) => out.push(msg);
  const newId = (iface) => { const id = nextId++; objects.set(id, iface); return id; };
  const stats = { frames: 0, releases: 0, typed: '', clicks: 0, keymap: 0, alive: true, reason: '', violations: 0, presented: 0, discarded: 0, refresh: 0, flags: 0 };
  let onViolation = () => {};
  const violation = (what) => { stats.violations++; onViolation(`${title}: ${what}`); };

  const globals = {};
  const id = { registry: 0, sync: 0, compositor: 0, shm: 0, wm: 0, seat: 0, surface: 0, xsurface: 0, toplevel: 0, pointer: 0, keyboard: 0, presentation: 0 };

  // window + buffers
  let W = 0, H = 0;
  const pending = { w: 0, h: 0, maximized: false };
  let maximized = false;
  let pool = null;
  let bufs = [];        // {id, u32, held}
  let bg = new Uint32Array(0);
  let full = true;      // next frame repaints everything
  let frameCb = 0;      // the frame callback in flight
  let wantFrame = false;
  let damage = [];      // rects changed since the last frame

  // scene
  const sq = { x: 40, y: 60, vx: 3, vy: 2, size: 36 };
  const trail = [];
  let ptr = null;
  let serial = 0;       // last input serial (move/resize need it)
  let flash = 0;

  const px = (r, g, b) => ((format === ARGB8888 ? 0xff000000 : 0) | (r << 16) | (g << 8) | b) >>> 0;
  const WHITE = px(240, 240, 240), DARK = px(36, 38, 46), RED = px(220, 80, 70), GREEN = px(90, 190, 110);

  // --- painting: every rect is repainted whole from the scene -----------
  let cur = null; // the buffer being drawn
  function paint(rx, ry, rw, rh) {
    const u = cur.u32;
    for (let y = ry; y < ry + rh; y++) u.fill(bg[y], y * W + rx, y * W + rx + rw);
    const fill = (x, y, w, h, c) => {
      const x0 = Math.max(x, rx), y0 = Math.max(y, ry);
      const x1 = Math.min(x + w, rx + rw), y1 = Math.min(y + h, ry + rh);
      for (let yy = y0; yy < y1; yy++) if (x1 > x0) u.fill(c, yy * W + x0, yy * W + x1);
    };
    const text = (s, x, y, k, c) => {
      for (const ch of s) {
        const g = FONT[ch] ?? FONT['#'];
        for (let i = 0; i < 15; i++) if (g & (1 << (14 - i))) fill(x + (i % 3) * k, y + Math.floor(i / 3) * k, k, k, c);
        x += 4 * k;
      }
    };
    // decorations
    text(title.toUpperCase(), 10, 9, 2, WHITE);
    fill(W - BOX - 6, 5, BOX, BOX, RED);
    fill(W - 2 * BOX - 12, 5, BOX, BOX, GREEN);
    if (!maximized) fill(W - 2 * BOX - 8, 9, BOX - 8, BOX - 8, DARK);
    for (let i = 0; i < GRIP; i += 4) fill(W - GRIP + i, H - 2 - i, GRIP - i, 2, WHITE);
    // content
    fill(Math.round(sq.x), Math.round(sq.y), sq.size, sq.size, WHITE);
    for (const p of trail) fill(p.x - 3, p.y - 3, 6, 6, px(255, 220, 60));
    text(`FRAME ${stats.frames}`, 10, TITLE_H + 8, 2, WHITE);
    text(`CLICKS ${stats.clicks}`, 10, TITLE_H + 24, 2, WHITE);
    text(`>${stats.typed.slice(-Math.max(1, Math.floor((W - 40) / 12)))}_`, 10, H - 28, 3, WHITE);
    if (flash > 0) {
      fill(0, 0, W, BORDER, GREEN); fill(0, H - BORDER, W, BORDER, GREEN);
      fill(0, 0, BORDER, H, GREEN); fill(W - BORDER, 0, BORDER, H, GREEN);
    }
  }
  const dirty = (x, y, w, h) => damage.push([x, y, w, h]);
  const dirtyBorder = () => { dirty(0, 0, W, BORDER); dirty(0, H - BORDER, W, BORDER); dirty(0, 0, BORDER, H); dirty(W - BORDER, 0, BORDER, H); };
  const dirtyTyped = () => dirty(0, H - 32, W - GRIP - 2, 22);

  function frame() {
    if (!W || !stats.alive) return;
    const buf = bufs.find((b) => !b.held);
    if (!buf) { wantFrame = true; return; } // all held: draw on the next release
    wantFrame = false;
    // animate: the square moves, the counter ticks, the flash fades
    dirty(Math.round(sq.x), Math.round(sq.y), sq.size, sq.size);
    sq.x += sq.vx;
    sq.y += sq.vy;
    if (sq.x < BORDER || sq.x + sq.size > W - BORDER) { sq.vx = -sq.vx; sq.x = Math.max(BORDER, Math.min(sq.x, W - BORDER - sq.size)); }
    if (sq.y < TITLE_H + 40 || sq.y + sq.size > H - 36) { sq.vy = -sq.vy; sq.y = Math.max(TITLE_H + 40, Math.min(sq.y, H - 36 - sq.size)); }
    dirty(Math.round(sq.x), Math.round(sq.y), sq.size, sq.size);
    dirty(10, TITLE_H + 8, 160, 10);
    if (flash > 0 && --flash === 0) dirtyBorder();

    let rects = [];
    for (const [x, y, w, h] of full ? [[0, 0, W, H]] : damage) {
      const x0 = Math.max(0, x), y0 = Math.max(0, y), x1 = Math.min(W, x + w), y1 = Math.min(H, y + h);
      if (x1 > x0 && y1 > y0) rects.push([x0, y0, x1 - x0, y1 - y0]);
    }
    if (rects.length > 16) { // merge into one box; painting a box whole keeps it correct
      let [x0, y0, x1, y1] = [W, H, 0, 0];
      for (const [x, y, w, h] of rects) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x + w); y1 = Math.max(y1, y + h); }
      rects = [[x0, y0, x1 - x0, y1 - y0]];
    }
    full = false;
    damage = [];
    stats.frames++;
    cur = buf;
    for (const r of rects) paint(...r);

    send(m(id.surface, 3, [frameCb = newId('wl_callback')]));  // frame
    if (id.presentation) send(m(id.presentation, 1, [id.surface, newId('wp_presentation_feedback')])); // feedback
    send(m(id.surface, 1, [buf.id, 0, 0]));                     // attach
    for (const r of rects) send(m(id.surface, 9, r));           // damage_buffer
    send(m(id.surface, 6));                                     // commit
    buf.held = true;
  }

  function resize(w, h) {
    for (const b of bufs) send(m(b.id, 0));   // wl_buffer.destroy (held ones too)
    if (pool) send(m(pool.id, 1));            // wl_shm_pool.destroy
    W = w;
    H = h;
    const size = W * H * 4;
    pool = { id: newId('wl_shm_pool'), file: shared ? new SharedArrayBuffer(size * NBUF) : new ArrayBuffer(size * NBUF) };
    send(m(id.shm, 0, [pool.id, pool.file.byteLength])); // create_pool: the fd travels out of band
    outFds.push(pool.file);
    bufs = [];
    for (let i = 0; i < NBUF; i++) {
      const bid = newId('wl_buffer');
      // offsets are not page-aligned: the relay's handle skew covers that
      send(m(pool.id, 0, [bid, i * size, W, H, W * 4, format]));
      bufs.push({ id: bid, u32: new Uint32Array(pool.file, i * size, W * H), held: false });
    }
    bg = new Uint32Array(H);
    for (let y = 0; y < H; y++) bg[y] = y < TITLE_H ? DARK : hsl(hue, 0.55, 0.58 - 0.28 * (y / H));
    sq.x = Math.min(sq.x, W - sq.size - BORDER);
    sq.y = Math.min(sq.y, H - sq.size - 40);
    trail.length = 0;
    full = true;
  }

  function hsl(h, s, l) {
    const f = (n) => {
      const k = (n + h / 30) % 12, a = s * Math.min(l, 1 - l);
      return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))));
    };
    return px(f(0), f(8), f(4));
  }

  function bind(name, version) {
    const g = globals[name];
    if (!g) throw new Error(`${name} not advertised`);
    const nid = newId(name);
    send(m(id.registry, 0, [g.name, name, Math.min(version, g.version), nid]));
    return nid;
  }

  function onButton(button, pressed) {
    if (button !== BTN_LEFT || !pressed || !ptr || !W) return;
    const { x, y } = ptr;
    const inBox = (bx, by, s) => x >= bx && x < bx + s && y >= by && y < by + s;
    if (inBox(W - BOX - 6, 5, BOX)) return close('closed by its close button');
    if (inBox(W - 2 * BOX - 12, 5, BOX)) { send(m(id.toplevel, maximized ? 10 : 9)); return; } // (un)set_maximized
    if (y < TITLE_H) { send(m(id.toplevel, 5, [id.seat, serial])); return; }                   // move
    if (x >= W - GRIP && y >= H - GRIP) { send(m(id.toplevel, 6, [id.seat, serial, 10])); return; } // resize bottom-right
    stats.clicks++;
    dirty(10, TITLE_H + 24, 200, 10);
    if (flash === 0) dirtyBorder();
    flash = 12;
  }

  function onKey(key) {
    if (key === 14) stats.typed = stats.typed.slice(0, -1);
    else if (KEYS[key]) stats.typed += KEYS[key];
    else return;
    dirtyTyped();
  }

  function close(reason) {
    if (!stats.alive) return;
    stats.alive = false;
    stats.reason = reason;
    sock.close(); // an app that exits just hangs up
  }

  // --- events ------------------------------------------------------------
  function receive(bytes, fds) {
    if (!stats.alive) return;
    wlEach(bytes, (obj, op, r) => {
      const iface = objects.get(obj);
      switch (`${iface}.${op}`) {
        case 'wl_display.0': { r.u32(); const code = r.u32(); violation(`protocol error ${code}: ${r.str()}`); break; }
        case 'wl_display.1': objects.delete(r.u32()); break; // delete_id
        case 'wl_registry.0': { const name = r.u32(); const iface2 = r.str(); globals[iface2] = { name, version: r.u32() }; break; }
        case 'wl_callback.0':
          if (obj === id.sync) setup();
          else if (obj === frameCb) { frameCb = 0; frame(); }
          break;
        case 'xdg_wm_base.0': send(m(id.wm, 3, [r.u32()])); break; // ping → pong
        case 'xdg_toplevel.0': {
          pending.w = r.i32();
          pending.h = r.i32();
          const states = new Uint32Array(r.array().slice().buffer);
          pending.maximized = states.includes(1);
          break;
        }
        case 'xdg_toplevel.1': close('closed by the compositor'); return;
        case 'xdg_surface.0': {
          send(m(id.xsurface, 4, [r.u32()])); // ack_configure
          const w = pending.w || W || width, h = pending.h || H || height;
          maximized = pending.maximized;
          if (w !== W || h !== H) resize(w, h);
          full = true;
          if (!frameCb) frame();
          break;
        }
        case 'wl_seat.0': {
          const caps = r.u32();
          if (caps & 1 && !id.pointer) send(m(id.seat, 0, [id.pointer = newId('wl_pointer')]));
          if (caps & 2 && !id.keyboard) send(m(id.seat, 1, [id.keyboard = newId('wl_keyboard')]));
          break;
        }
        case 'wl_buffer.0': {
          const b = bufs.find((x) => x.id === obj);
          if (!b) break; // a destroyed generation: the relay must not release those
          if (!b.held) violation(`wl_buffer.release of buffer ${obj}, which the compositor does not hold`);
          b.held = false;
          stats.releases++;
          if (wantFrame) frame();
          break;
        }
        case 'wl_pointer.0': serial = r.u32(); r.u32(); ptr = { x: r.fixed(), y: r.fixed() }; break; // enter
        case 'wl_pointer.2': {                                                                       // motion
          r.u32();
          const p = { x: Math.round(r.fixed()), y: Math.round(r.fixed()) };
          const last = trail.at(-1);
          ptr = p;
          if (!last || Math.abs(last.x - p.x) + Math.abs(last.y - p.y) >= 4) {
            trail.push(p);
            dirty(p.x - 3, p.y - 3, 6, 6);
            if (trail.length > 48) { const o = trail.shift(); dirty(o.x - 3, o.y - 3, 6, 6); }
          }
          break;
        }
        case 'wl_pointer.3': { serial = r.u32(); r.u32(); const b = r.u32(); onButton(b, r.u32() === 1); break; }
        case 'wp_presentation.0': { const clk = r.u32(); if (clk !== 1) violation(`presentation clock ${clk}, not CLOCK_MONOTONIC`); break; }
        case 'wp_presentation_feedback.1': { // presented: on the relay's clock, which is ours
          const sec = (BigInt(r.u32()) << 32n) | BigInt(r.u32());
          const at = sec * 1000000000n + BigInt(r.u32());
          const ago = monotonicNs() - at;
          if (ago < 0n || ago > 2000000000n) violation(`presented ${ago} ns ago`);
          stats.presented++;
          stats.refresh = r.u32(); // ns
          r.u32(); r.u32(); // seq
          stats.flags = r.u32();
          break;
        }
        case 'wp_presentation_feedback.2': stats.discarded++; break;
        case 'wl_keyboard.0': r.u32(); stats.keymap = fds[0] && fds[0].keymap ? fds[0].keymap.length : -1; break;
        case 'wl_keyboard.1': serial = r.u32(); break;
        case 'wl_keyboard.3': { serial = r.u32(); r.u32(); const key = r.u32(); if (r.u32() === 1) onKey(key); break; }
      }
    });
    flush();
  }

  function setup() {
    id.compositor = bind('wl_compositor', 4);
    id.shm = bind('wl_shm', 1);
    id.wm = bind('xdg_wm_base', 2);
    id.seat = bind('wl_seat', 5);
    send(m(id.compositor, 0, [id.surface = newId('wl_surface')]));
    send(m(id.wm, 2, [id.xsurface = newId('xdg_surface'), id.surface]));
    send(m(id.xsurface, 1, [id.toplevel = newId('xdg_toplevel')]));
    send(m(id.toplevel, 2, [title]));
    send(m(id.toplevel, 3, ['wland.handle-demo']));
    send(m(id.toplevel, 8, [240, 180])); // set_min_size
    send(m(id.surface, 6));              // initial commit → configure
    // last, so the ids above stay what tests and pages expect
    if (globals.wp_presentation) id.presentation = bind('wp_presentation', 1);
  }

  function flush() {
    if (!out.length || !stats.alive) return;
    const bytes = new Uint8Array(out.reduce((n, x) => n + x.length, 0));
    let off = 0;
    for (const x of out) { bytes.set(x, off); off += x.length; }
    out.length = 0;
    const fds = outFds;
    outFds = [];
    sock.write(bytes, fds);
  }

  return {
    title, stats,
    get width() { return W; },
    get height() { return H; },
    /** Connect through `relay` (relay.connect is the socket accept). */
    start(relay, report) {
      onViolation = report;
      sock = relay.connect(this);
      send(m(1, 1, [id.registry = newId('wl_registry')])); // get_registry
      send(m(1, 0, [id.sync = newId('wl_callback')]));     // sync: globals are in by its done
      flush();
    },
    receive,
    killed(reason) { stats.alive = false; stats.reason = reason; },
    close,
  };
}

export { XRGB8888, ARGB8888 };
