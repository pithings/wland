# wland — plan & status

Done work is history in `git log` (one commit per step; the old session
journal and design notes are in git history too). This file holds only what
is current.

## Architecture

```
wayland app ──unix socket──► relay ──link (WS | stream)──► engine (wasm compositor) ──► view (canvases)
```

- **Relay (`server/`)**: thin so far. Owns the Wayland socket, relays raw
  wire over one engine link, intercepts only fd-carrying messages: shm
  create_pool → buffer backend (copy: snapshot + ship pixels; procfd/kwshm:
  name the memory, release on ACK) · linux-dmabuf params.add → dmabuf
  backend (opt-in `--dmabuf`; readback: map + copy like shm) · keymap and
  dmabuf format table → memfd · clipboard/primary pipes → token table. No
  rendering.
- **Engine (`core/` → wasm + `lib/engine.ts`)**: the real compositor —
  object model, xdg-shell, seat/input. `compositor.zig` never sees an fd or a
  pixel.
- Links: WebSocket (native `wlandr`, also serves the demo; test harness
  and remote mode) or byte stream (`fd:`/`unix:`/`vsock:`, the unkernel path).
  One engine link at a time.
- Advertised globals: wl_compositor 6, wl_subcompositor 1, wl_shm 2, wl_seat 9,
  wl_output 4, xdg_wm_base 6, wl_data_device_manager 3,
  zxdg_decoration_manager_v1 1 (always client_side), wp_cursor_shape_manager_v1
  1, wp_viewporter 1, wp_fractional_scale_manager_v1 1,
  zwp_text_input_manager_v3 1, zwp_primary_selection_device_manager_v1 1,
  zwp_relative_pointer_manager_v1 1, zwp_pointer_constraints_v1 1,
  wp_presentation 3;
  zwp_linux_dmabuf_v1 4 only when the relay has a dmabuf backend (`wlandr
  --dmabuf`, announced by the FEATURE frame first on the link).
- New protocol work, in order: (1) FD RULE check of the XML, version by
  version (`.agents/gotchas.md`); (2) copy it into `protocol/` AND append its
  path to the hardcoded `XMLS` list in `tools/gen_protocol.py`, run it, commit
  the regenerated `protocol_gen.zig` (not wired into `zig build`); (3) add a
  `globals` entry in `compositor.zig` (advertising and new-id tracking are
  automatic); (4) add dispatch branches + destructor handling; a fd-free
  protocol needs no relay change (it forwards as opaque WIRE).

## STATUS — open items

- **unkernel verification** happens in the unkernel repo, from a handoff
  doc kept outside this repo (§6 checklist, §7 open questions). kwshm (real
  ioctl), vsock and kwemu have never run the relay here.
- **Feature candidates** (not started; a rough value order, not a commitment):
  non-US keymaps · surviving a link reset (snapshot restore) · minimized
  windows' frame callbacks held over WS too (see Current limits).
- **Window states**, done: fullscreen and minimize next to maximize, core
  state (`Surface.maximized/fullscreen/minimized`, `applyMaximized/
  applyFullscreen/applyMinimized`), wm_capabilities = maximize, fullscreen,
  minimize. Checked: core unit tests, fake-DOM view/input/wm tests, headless
  tests, headless-e2e (foot fullscreen/minimize by the compositor,
  weston-fullscreen's own `f` and `-f`, nautilus's header-bar minimize
  button), relay-e2e (a minimized weston-simple-shm stops: frame callbacks
  held on the stream link), run-poc `states` (Alt+F11 with the browser's
  fullscreen in headless chromium, its exit, Alt+F9, restore). Not seen: a
  GTK app's own fullscreen (nautilus has no F11; gtk3-demo aborts here), X11
  (below), a real browser's Esc/fullscreen banner (human item).
- **GPU clients**. unkernel's GL is Mesa virgl over vtest (no kernel
  virtio-gpu driver, no DRM node, no dmabufs): GL apps present through the
  software winsys as wl_shm clients, which already work (kwshm handles;
  inferred from Mesa's structure, not run).
  - Step 1, done: linux-dmabuf v4 in core + relay. The core owns the
    objects and protocol errors (params planes, formats against the table,
    `create`'s server-id wl_buffer); the relay owns the fds (params.add →
    FDMSG kind 4, `dmabuf.zig` `Params`/`Buffer` in the conn's buffer
    table, same release ledger). Opt-in `--dmabuf readback[:NODE]`: LINEAR
    ARGB/XRGB8888 mapped and fed to the copy path (BUFFER frames, nothing
    new in the engine); FEATURE (0x0c) tells the core to advertise it,
    DMABUF_CREATED (0x0d) names `create`'s buffer to the relay. Checked:
    unit tests with memfd stand-ins (no /dev/dri here), real Mesa 26.2
    (weston-simple-egl) and wayland-info parsing the feedback with
    `readback:/dev/null` as the device (Mesa can't open it and falls back to
    wl_shm). Never run on a real GPU: no client has rendered into a dmabuf,
    the DMA_BUF_IOCTL_SYNC / fence-poll path never ran on a real one.
  - Page half of a resource-naming COMMIT, done: COMMIT kind 2 = virtgpu
    (ref: resource, size, fourcc, flags, plane 0 offset/stride/modifier;
    ≥ 36 bytes, append-only; the embedder contract is in STREAM.md) →
    `EngineOptions.gpu` (`GpuSource`: resolve(ref) → image, sync or
    promise; release(image); then ACK) → commit events of format 'gpu'
    (`gpu` ref + `image`); the view draws the image (2D clearRect+drawImage
    per damage rect; GL texImage2D of the whole image), headless copies an
    RgbaImage and exposes `HeadlessSurface.gpu`; no resolver = one error,
    image null, still ACKed. No relay here emits kind 2 (a `--dmabuf
    virtgpu` backend over a virtio-gpu node was dropped: unkernel has no
    DRM node); only the JS test relay does (`gpu: true`, kwshm exports as
    "resources", a stand-in resolver paints them): core/engine/headless/view
    unit tests, browser-e2e handle-demo `gpu=1` (2D and software GL).
  - Open: the guest half that names a vtest client's frame as a resource
    the page's renderer knows (unkernel's to design; the emitter then owns
    kind 2's ordering guarantee); real-GPU verification of readback.
- **Protocol bumps on offer** (`protocol/*.xml` synced with upstream main on
  2026-11-21 — wayland 1.26 / wayland-protocols 1.50; advertised versions
  unchanged, all additions are fd-free). Rough value order:
  - `zwp_text_input_v3` 2: `show_input_panel` / `hide_input_panel` requests
    (drive the mobile on-screen keyboard from the IME sink), `action` event
    (Enter-key "submit"), `set_available_actions`, `language`, `preedit_hint`
    events, three new `content_hint` flags.
  - `wp_cursor_shape_manager_v1` 2: shapes `dnd_ask` (35), `all_resize` (36)
    → CSS `all-scroll`/`move`; the smallest bump.
  - `wl_compositor` 7: `wl_surface.get_release` — a per-commit release
    wl_callback (double-buffered, bound to the pending buffer at commit;
    `no_buffer` error without an attach), plus `wl_compositor.release`.
    Lives next to `wl_buffer.release` in `settleRelease`; needs the callback
    tracked per commit on the app thread. `wl_region` jumps to 7 with it.
  - `wl_seat` 11: `wl_pointer.warp` event (compositor moved the pointer) —
    only useful together with pointer-warp-v1: nothing here moves the
    pointer (a page can't; a confinement's clamp is a motion, a lock leaves
    the pointer where it froze). Seat is still advertised at 9 (10 =
    `wl_keyboard.repeated`).
  - `wl_data_device_manager` 4 (`release`), `wl_shm` 3 (new format enum
    entries, `wl_shm_pool` errors), `wl_fixes` 2 (`ack_global_remove`; wl_fixes
    isn't advertised at all): housekeeping, no user-visible gain.
- **Human verification** (all `--demo` / run-poc, no code left):
  - fullscreen on a real browser: Alt+F11 (or an app's own F11) with the
    demo's browserFullscreen — the browser's banner, Esc ending both, the
    desktop reconfigured to the screen size; a game using Pointer Lock and
    fullscreen together (Esc order);
  - Pointer Lock on a real browser and screen: a game-like client (SDL3
    relative mode, weston-constraints) — the press that locks, Esc and
    the press that re-locks, the "press Esc" banner, raw movement where the
    platform has it (Windows/macOS/ChromeOS: `unadjustedMovement`), a
    cursor surface drawn frozen while locked; Firefox untested;
  - input feel: constant resize via CSD, clipboard between two foots, latency;
  - cursor-shape hover (CSS cursor changes over foot's text area);
  - cursor surfaces on a real screen: weston-flower's hand / a GTK3 app's
    themed cursors at dpr 1 and 2 (image-set scale, hotspot where it
    should be), an animated one (GTK3 `watch`) without flicker; none of the
    apps here renders a hi-dpi cursor (toytoolkit ignores the scale, GTK3
    demos abort in this container);
  - fractional dpr (e.g. 1.5): nautilus/foot sharpness + live dpr change;
  - real IME (CDP `Input.imeSetComposition` against foot);
  - primary selection: drag-select in one foot, middle-click into another;
  - WebGL present path on a real GPU: open the demo, expect
    `webgl probe: "…" → hardware, GL present ON` in `wlandLog` and toplevels
    logging `present: cNsM → webgl2`; measure main-thread present cost vs 2D
    (the GL code is only verified on software GL, browser-e2e `webgl`);
  - a full `tools/run-poc.sh` pass covering the above.
- **Test dependencies**: every test runs on `zig build` + node; the E2E
  apps are `wland-fixture` modes, the real apps an opt-in tier
  (`WLAND_E2E_APPS=real`, .agents/testing.md "Setup"). What is left: the
  browser E2E needs chromium (inherent) and bun (browser-e2e.ts's runtime
  and the test/browser bundle: Node's built-in WebSocket for CDP + an
  esbuild devDependency would retire it); the x11 phase needs
  xwayland-satellite/Xwayland/xeyes (real tier only; relay.test has a
  stand-in satellite).

## Tried, deferred, not pursued so far

The project has been a run of experiments. This records what was tried or
weighed and why it stopped, so the reasoning isn't redone from scratch. None
of it is final — reopen an item when its reason no longer holds or a better
approach shows up.

- **Not advertised (FD RULE)**: drm-lease, drm-syncobj (explicit sync:
  timeline fds), security-context, ext-data-control, color-management (ICC
  fds) — the relay doesn't handle their fds. wl_drm (legacy Mesa) isn't
  needed: Mesa 26 has no wl_drm client code at all, it finds its device
  through dmabuf v4 feedback.
- **linux-dmabuf through the relay** (was "not advertised"): the earlier
  idea was a COMMIT kind alone with no dmabuf fds through the relay; but a
  Mesa client hands the compositor dmabufs whatever the transport, so the
  relay takes the fds (step 1) and a backend decides what they become
  (readback: pixels; naming a GPU resource instead would be COMMIT kind 2).
- **Xwayland in-tree**: not pursued. Not blocked by the FD RULE (no dmabuf →
  software rendering over wl_shm; xwayland_shell_v1 is fd-free), but rootless
  Xwayland needs the compositor to be an X11 WM (ICCCM/EWMH, X window ↔
  wl_surface association, X selection ↔ clipboard bridging with INCR —
  wlroots' xwm ≈3.5k lines), and wland's window state lives in the page while
  the X socket is relay-side. Current plan: X11 through `xwayland-satellite` as
  a plain client.
- **X11 via xwayland-satellite — tried 2026-11-21** (v0.8.3 + Xwayland 24.1,
  headless only, no browser run): works unmodified. It needs only xdg_wm_base,
  wl_compositor, wl_subcompositor, wl_shm, wp_viewporter (xdg-output optional);
  xterm/xev/GTK3-on-X11 map, draw, take keys and pointer; override-redirect
  menus arrive as placed xdg_popups; clipboard + primary bridge both ways;
  integer scale 2 is right. Satellite draws its own 25 px titlebar subsurface
  (close + drag) when answered client_side; it is part of the window's box
  (window geometry: a resize to 700x500 is a 700x475 X window under it). Rootful `Xwayland :N -geometry WxH`
  also runs as a plain client (one window, bring an X WM). Fractional dpr:
  with `wl_surface.enter` sent, satellite hands the fractional scale to X
  clients (`Xft.dpi` 144 at 1.5, was 192 — it reads a surface's
  preferred_scale into its "output scale" only for a surface on an output);
  startup at 1.5 and a live 2 → 1.5 both checked. Launching is wlandr's
  (`server/src/xwayland.zig`, niri's model): it claims the first free X
  display in /tmp, logs `x11 display: :N`, leaves it in `<socket>.x11`, and
  starts `xwayland-satellite :N -listenfd …` when the first X client
  connects (`--xwayland auto|off|PATH`; auto without --link, off with it);
  `wland run` / `runApp` / `tools/wland-run` export that DISPLAY. Not
  shipped: satellite and Xwayland are the user's to install. Open, in order:
  - fractional dpr, what is left: the X screen is still `wl_output.mode` =
    desk × the INTEGER scale (2560x1600 for a 1280x800 desk at 1.5; Xwayland
    sizes its root from the mode, satellite has no say), so X sees a screen
    larger than the desk. A mode of desk × dpr would fix it but changes what
    every client sees — not decided. After a live dpr change satellite
    redraws its titlebar at once but only sets (never commits) the X
    window's new viewport: the window keeps its old logical size until the
    X client next repaints (satellite's behaviour, on any compositor).
  - popups: satellite sets no window geometry, so its box is toplevel +
    titlebar, origin at y = −25 — and it places menus from the X window's
    origin, not from that box. Per xdg-shell a popup is positioned against
    the parent's window geometry; wland still places it against the parent
    SURFACE, which is what makes satellite's menus land right (and GTK's,
    whose parent and popup shadow margins roughly cancel). Doing it by the
    book needs satellite to set its geometry or a quirk for it.
  - fullscreen should now work (satellite maps `_NET_WM_STATE_FULLSCREEN`
    to `xdg_toplevel.set_fullscreen`, which gets its configure since the
    window-states work) — unverified: satellite isn't installed in this
    container. X windows still can't maximize (satellite advertises only
    `_NET_WM_STATE_FULLSCREEN`); whether satellite turns an X iconify
    request into `set_minimized` is unknown (unverified either way).
  - no xdg_activation → `_NET_ACTIVE_WINDOW` requests are dropped (inferred).
  - untested: X ⇄ Wayland dnd, INCR-sized transfers, pointer-lock apps
    (satellite's own relative-pointer / constraints use).
- **Deferred, doable if wanted**: xdg-activation,
  pointer-gestures, idle-inhibit / ext-idle-notify, single-pixel-buffer,
  content-type, tearing-control, xdg_wm_base v7, tablet-v2,
  foreign-toplevel-list / layer-shell, xdg-toplevel-icon (window icons for
  the wm; shm buffers, fd-free), xdg-dialog (modal hint), xdg-system-bell
  (→ page beep/notification), keyboard-shortcuts-inhibit (pairs with the
  browser Keyboard Lock API), pointer-warp-v1, alpha-modifier, fifo /
  commit-timing, xdg-toplevel-tag, xdg-toplevel-drag, xdg-output, DOM-titlebar SSD for no-CSD apps,
  viewport src-crop compositing, HTML5-dnd bridge to the host page,
  OffscreenCanvas/worker present (after the GL path is hardware-verified; the
  frame-order invariant vs WIRE makes it non-trivial), WebGPU upload,
  multi-stream link / WebTransport (head-of-line blocking: one big frame from
  app A delays app B's input on the shared link).
- A generic "export device" buffer backend (`--buffers export:PATH`) was tried
  and dropped: no second device exists and any would have to clone kwshm's
  ioctl ABI verbatim, so it was renaming that changed the embedder API. Worth
  another look if a second device appears.
- Compression beyond LZ4 on BUFFER (deflate / permessage-deflate) and
  present-ack pacing: evaluated, only pay off on slow links.
- True multi-tab (N mirrored tabs): needs compositor state outside the tab.

## Current limits

Known gaps of the current state (so they aren't mistaken for regressions).
Any of them is fair game to lift.

- Move/resize/maximize/minimize work via app CSD; Alt+drag moves no-CSD
  windows (no resize for them); Alt+F11 / F10 / F9 toggle fullscreen /
  maximize and minimize the focused window (the keys are swallowed, the Alt
  press before them reaches the app: a lone Alt tap to it). No window menu
  (`show_window_menu` ignored, not advertised).
- Fullscreen fills the container (#desktop), not the screen; the browser's
  Fullscreen API only with `browserFullscreen` (the demo sets it): requested
  at once when the page has user activation (the key or click that made the
  app ask), else at the next press in the container; the browser leaving it
  (Esc, a tab switch) takes every window out of fullscreen; the last shown
  fullscreen window leaving it (or minimized) leaves the browser's.
  `set_fullscreen`'s output is ignored (one output). There is no fullscreen
  layer: a window raised or mapped later stacks above a fullscreen one,
  which stays fullscreen. A desktop resize reconfigures maximized and
  fullscreen windows (with configure_bounds); floating windows are sent no
  new bounds. `activated` is still in every toplevel configure, focused or
  not.
- Minimize: no taskbar in the lib (the embedder builds one from
  `windows()`; the demo's docks restore); popups of a minimized window are
  dismissed; v6 clients get `suspended`; its presentation feedback is
  discarded. Its frame callbacks are held only on stream links (the
  engine's): over WS the relay fires them at its 16 ms pace whatever the
  window's state — holding them there needs an engine→relay frame naming
  the surface tree (subsurfaces made while minimized too) and an app-thread
  wakeup under the copy backend, which polls no eventfd. `set_minimized`
  before the initial commit is ignored.
- One engine link at a time: newest tab takes over (old tab gets WS close 4000);
  takeover/reload drops apps; apps never survive a link drop (a stream link is
  redialled and the engine starts empty).
- GPU clients only with `--dmabuf readback` (copy mode; LINEAR ARGB/XRGB8888;
  one tranche, `get_surface_feedback` = the default feedback; no y_invert;
  v1/v2 binders get no formats; a dmabuf the backend can't import is
  accepted but never shown, released per commit — not a `failed` event;
  never run against a real GPU). No explicit sync (drm-syncobj): readback
  waits ≤ 500 ms for implicit fences. X11 apps need `xwayland-satellite` + Xwayland
  installed (software rendering, no maximize, fullscreen untested; see the
  satellite entry above); no in-tree Xwayland.
- dnd works between wland clients only, not to/from the host page.
- Pointer constraints: a lock is the browser's Pointer Lock, so it needs a
  user gesture — granted at once only while the page has transient
  activation (the press that made the app ask), else at the next press on
  the surface; the browser shows its own "press Esc" banner, Esc or a tab
  switch ends it (`unlocked`; persistent locks re-lock at the next press,
  oneshot ones are dead). A confinement is soft: a page can't hold the OS
  pointer, so the client sees motion clamped to the region while the real
  pointer is over the surface (or held there by a pressed button, the
  implicit grab) and the confinement ends (`unconfined`) when it leaves —
  persistent ones come back on re-entry. Outside the region but on the
  surface the client's clamped position and the visible pointer differ.
  `set_cursor_position_hint` is ignored (a page can't move the pointer
  when the lock ends). While locked the browser hides the pointer: a
  cursor surface is drawn frozen where the lock began, a cursor shape not
  at all (most locking clients set none). Relative motion is the browser's movementX/Y,
  summed per frame (no pointerrawupdate), with `dx_unaccel` = `dx`: one
  stream — unaccelerated while a lock got `unadjustedMovement`, the OS's
  accelerated motion otherwise (Linux has no raw movement).
- Presentation feedback (wp_presentation) is dated by the relay: its
  CLOCK_MONOTONIC when the PRESENTED frame arrives, less the frame's age
  on the page's clock — so the time the browser frame after the commit
  began (the first rAF tick after it), plus the link's one-way latency
  (unseen: loopback ≪ 1 ms, a remote browser its network latency). The
  real light is a frame or two later (the browser's compositor pipeline;
  not observable from a page). `refresh` is the rAF interval as measured
  (median of 15 deltas; 0 for the first 5 frames and always 0 headless),
  `seq` is 0, flags are `vsync` in a browser and none headless; the v3
  fixed_rate/variable_rate flags are never set. wl_output's mode still
  says 60 Hz whatever the measured rate. Frame-callback `done` times are
  the relay's CLOCK_MONOTONIC ms over WS but the page's `performance.now()`
  over a stream link (the spec leaves their base undefined;
  weston-presentation-shm's f2c column assumes the presentation clock, so
  it reads garbage on a stream link). Input event times are the page's
  clock everywhere.
- Keymap is canned US; composed input (dead keys, CJK, emoji) works via
  text-input-v3 + a hidden IME sink.
- Pointer images: shapes (cursor-shape-v1) and cursor surfaces
  (`wl_pointer.set_cursor`) are CSS on the client's windows; a cursor image
  over 128 CSS px (or a hotspot off it, a non-uniform viewport scale, no
  image-set) is drawn as an element a frame behind the pointer instead.
  Chromium drops a CSS cursor image not wholly inside the viewport, so near
  the page edges the default arrow shows (the element fallback isn't used
  for that: the browser's choice can't be observed). Firefox's limits and
  hotspot scaling are unverified. viewport src-crop of a cursor surface is
  ignored like any surface's.
- Window geometry is the window's box (placement, sizes, maximize), but
  popups are placed against the parent surface's origin, not its geometry; a
  set geometry is not clamped to the surface's bounds.
- Input regions are applied (picking passes over a surface outside its
  region, through a hole inside the window geometry too). A region over 32 boxes degrades to a superset (`Region.max`);
  synchronized subsurfaces apply it at their own commit, like all their
  state.
- The implicit grab (a held button keeps the pressed surface) is pointer
  capture; a popup of the pressed client mapping lets it go, as a popup
  grab would — whether or not the client asked for `xdg_popup.grab` (the
  core ignores it).
- wp_viewport source-rect cropping is tracked + validated but not composited;
  a surface that ever had a viewport treats damage as full-buffer for life.
- wl_output reports the live desktop size as its current mode.
- `/ws` Origin check does not stop DNS rebinding; no auth against other local
  users.
- Over a stream link, one copy-mode frame over 256 MiB drops that app (bursts
  are split; single frames can't be).
