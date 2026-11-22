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
  backend (opt-in `--dmabuf`; readback: map + copy like shm; virtgpu: name
  the virtio-gpu resource, release on ACK) · keymap and
  dmabuf format table → memfd · clipboard/primary pipes → token table (and,
  for the engine's own selection reads and writes, a pipe it makes and
  reads / the core's bytes it keeps and writes: FDMSG pipe_read and
  own_pipe, one capped writer thread).
  No rendering.
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
  Protocols foot warns about on its first unkernel run (2026-11):
  - `xdg-activation-v1` (staging; foot: urgency/focus requests, launchers
    handing focus on). FD RULE: no fd args in any request or event (v1) —
    pure core work: tokens, `activate` → raise/focus by the wm policy.
  - `xdg-toplevel-icon-v1` (staging; window icons for the embedder's
    taskbar). FD RULE: no fd args, but `add_buffer` names a wl_shm buffer
    that is never committed to a surface, so the relay must ship its pixels
    on a new path (read at add_buffer/set_icon, under the pool SIGBUS guard;
    a new frame or COMMIT naming the icon) — relay + core + lib work.
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
- **GPU clients**. unkernel's guest now has the stock virtio_gpu DRM
  driver with virgl 3D (`/dev/dri/renderD128`, PRIME import/export, no
  blob resources): Mesa allocates dmabufs there, and the page's renderer
  knows each by its resource id (`vm.gl.gpu.texture(id)`). readback can't
  serve it (an mmap shows the guest's backing pages, not what the host
  rendered); `--dmabuf virtgpu` names the resource instead.
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
    image null, still ACKed. Checked with the JS test relay (`gpu: true`,
    kwshm exports as "resources", a stand-in resolver paints them):
    core/engine/headless/view unit tests, browser-e2e handle-demo `gpu=1`
    (2D and software GL).
  - Relay half, done: `wlandr --dmabuf virtgpu[:NODE]` (`virtgpu.zig`:
    PRIME_FD_TO_HANDLE + VIRTGPU_RESOURCE_INFO at create/create_immed, GEM
    handles refcounted relay-wide — buffers + un-ACKed COMMITs — and closed
    at the last; `dmabuf.zig` `Backend.virtgpu`: [AX]RGB/[AX]BGR8888 ×
    {MOD_INVALID, LINEAR}, one plane, refusals and first-of-a-kind logged
    once). Any `--buffers` mode: kind-2 COMMITs come from `relay.zig`
    `finishCommit` on the conn's one serial space and Pending/ACK ledger
    (shared with the handle backends); the conn gets the ACK path under
    copy too. Before each COMMIT a bounded (100 ms) poll on the dmabuf
    waits for its implicit write fences (STREAM.md "wlandr's emitter").
    The core now sends v1/v2 binders a `format` per MOD_INVALID format.
    Checked through the ioctl seam's stand-in (`virtgpu.Fake`: memfds as
    dmabufs, one handle per file, resource ids, a host-side `resolve`):
    unit tests (UAPI numbers/layouts against drm.h + virtgpu_drm.h,
    importer refcounts, refusals, the fence-wait timeout), harness tests
    (resource + pixels through the fake, release after the ACK once per
    busy period, destroy before the ACK, two buffers over one dmabuf,
    params.create, conn close in flight, beside procfd and kwshm handles,
    copy on a relay-paced link), headless-e2e and relay-e2e with the
    `dmabuf` fixture over the test-only `--dmabuf virtgpu:@fake` (WS +
    copy; stream + procfd beside a wl_shm client). Never run on a real
    virtio-gpu node or with real Mesa: which formats/modifiers Mesa picks
    there, whether RESOURCE_INFO works on its imports, and what unkernel's
    device makes of the fence wait are the first unkernel run's to show
    (the relay logs the first buffer of each kind and every refusal).
  - Open: that first run (unkernel's handoff); real-GPU verification of
    readback.
- **Embedder asks from unkernel (2026-11-21), lib side**, done:
  `HandleSource.readv` (all spans of a COMMIT in one call, one promise:
  one worker round trip per commit, damaged spans only) and
  `HandleSource.view` (the memory in place, sync; one view is the
  commit's pixels with no copy, a SharedArrayBuffer included; scattered
  page runs are gathered) — unit tests (handles.test: sync/async/throw/
  reject/close-during-readv, view single/scattered/shared/null/short/
  throw), handle-demo.test and run-poc handle-demo modes `shape=view`
  (WebGL) and `shape=readv` (async). Not run against unkernel's page yet
  (its working tree now has the glue — `web/src/wayland.ts` and a guest
  launcher, `/usr/lib/kw/bin/wland`, running `wlandr --link vsock:2:1023
  --buffers kwshm`, without `--dmabuf` so far; worker mode would use readv
  over `ShmFile.read`, inline mode view over `views()`). `createWland().output`
  (`setSize`/`setScale` pin, null follows; fractional scales; a 0-size
  container no longer reaches the core as a 1×1 desk) — fake-DOM tests.
  Firefox: `tools/firefox-smoke.ts` (headless 160 over WebDriver BiDi:
  handle demo modes incl. readv/view/gpu, wlandr + term typing) passes;
  WebKit (Playwright's 27.2 MiniBrowser) passed the same by hand, WebGL
  presenter included. Found and fixed on the way: the keypad (and
  PrintScreen, Pause, NumLock, ContextMenu, IntlBackslash) had no evdev
  mapping in any browser; then keypad digits arrived as navigation (the
  core never locked NumLock): now seat-wide Caps Lock/NumLock state,
  NumLock on, synced from the browser (`engine.keyboardLocks`) — core
  test, client.test, headless-e2e keypad step (fixture and real foot).
  Cross-cutting fixes (2026-11-22): a GPU-less page in front of a virtgpu
  relay offers no linux-dmabuf (FEATURE 2 dmabuf_kind before linux_dmabuf;
  `wland_set_gpu_source`), so GPU clients fall back to wl_shm instead of
  blank windows; a COMMIT ACKed with nothing new shown (no image, failed
  read) makes the surface's next one whole in the engine (the relay can't
  know); the lock state carried over a link reopen is the core's
  (`wland_keyboard_locks_state`), lock-key toggles included — core,
  relay-harness, engine/handles/headless/core-abi/handle-demo tests,
  headless-e2e (gpu-less page on the virtgpu relay).
  Review fixes (2026-11-22): a link reset during a pending read/resolve
  (stale staging writes, a clobbered pending-read record, unreleased gpu
  images), output validation/inertness after dispose, createWland
  teardown on a throw, SharedArrayBuffer pools in a browser (handle-demo
  `sab=1` via `test/support/isolated.ts`: Chromium 2D + WebGL, Firefox
  2D), no install-time `os` restriction (serverBinary fails at run time
  off Linux). Still unseen outside Chromium: Pointer Lock,
  the Fullscreen API, IME, hi-dpi cursor images, Firefox's WebGL path;
  real Safari not at all.
- **Page clipboard bridge** (unkernel's report, 2026-11-22), done for
  plain text both ways: core `setOwnSelection` (the embedder's own source,
  `Selection.conn == 0`; the core answers a receive with the bytes, the
  relay writes them) and `readSelection` (FDMSG pipe_read: the relay makes
  the pipe, reads it bounded, answers once); engine `selection()` /
  `setSelection` / `readSelection` + 'selection' events, `readSelectionText`
  / `setSelectionText`; `lib/clipboard.ts` (createWland `clipboard`, default
  on) on input's paste-chord hold; headless `readClipboard` /
  `writeClipboard`; the `term` fixture grew foot's Ctrl+Shift+V / C.
  Checked: core + relay-harness tests, test/clipboard.test.ts (engine over a
  scripted link; page side on the fake DOM: paste chord, late paste, refused
  write, steal guard, granted-only readText, size bound), headless-e2e
  (wl-copy → readClipboard, writeClipboard → wl-paste, foot fixture both
  ways), relay-e2e (stream link), run-poc `foot` group's `clipboard` phase
  in headless Chromium (fixture and real foot, both ways) and
  `tools/firefox-smoke.ts` step 3 (headless Firefox, term fixture, both
  ways). Version skew: the bridge is gated on FEATURE selection_cache
  (`Engine.selectionBridged()`, per link): without it the core sends no
  pipe_read / own_pipe and offers no own selection, readSelection rejects
  (NO_SELECTION_BRIDGE), setSelection is false, lib/clipboard.ts goes
  inert (one log, chords plain keys). Checked 2026-11-22: relay-e2e and
  headless-e2e (fixtures) against the 12e0e1d relay (WLAND_E2E_RELAY):
  pass, the bridge checks skip with a message, wl-paste / foot's paste
  return at once; the 0.1.0 engine in front of a new relay passed its own
  relay-e2e earlier. Open: other types (text/html, image/png: the engine API carries
  any mime; the bridge would need ClipboardItem / clipboardData types and
  a per-browser type list), the primary selection (no page equivalent),
  Safari/WebKit (not run: the copy-event and in-handler writeText paths are
  there for it), a human check with a real system clipboard. Review round
  (2026-11-22): a paste after the copying app went (or a link reconnect)
  sets the unchanged page text again; focusout to nothing and a press
  outside the desktop count as leaving; a paste event with only non-text
  types is a changed page; copy chords are prevented unless text is owed
  and copy/cut events on the desktop always cancelled (Firefox's stale page
  selection, firefox-smoke step 4); input's `pressed` keys released on
  leave / window blur / Cmd up, Apple chords sent whole at the press — all
  with fake-DOM tests in test/clipboard.test.ts. Relay, final round: a
  receive's fd must be a pipe (others closed at once: a FUSE/NFS/tty fd
  could block a close or write the link thread or writer made under a
  lock), the writer makes no syscall on a receiver's fd under its mutex
  and writes RWF_NOWAIT, EOF completes a pipe_read even after the source
  hung up (`wl-copy --paste-once`; fixture `copy -o`, headless-e2e), and
  a receive racing its conn's close is refused (writer tombstones). Open:
  an app thread stuck in a syscall on its client's fd (FUSE shm pool,
  stray FUSE fd closed at teardown) holds `link.users`, so a stream
  link's serveLink never returns and it never reconnects (gotchas).
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
    cursor surface drawn frozen while locked; Firefox/Safari untested
    (headless Firefox and WebKit only smoke-tested: no lock tried);
  - input feel: constant resize via CSD, clipboard between two foots, latency;
  - macOS / iPadOS keyboard (never run on Apple hardware in any browser;
    written from documented key-event behaviour): Cmd+V / Cmd+C / Cmd+X
    in foot and a GTK app (Safari, Chrome, Firefox on a Mac) — the chord
    arrives as Ctrl+V etc. once, nothing left held (Cmd up first, V up
    first, Cmd+V held for repeat, Cmd+Shift+V in foot), Cmd+A then Cmd up
    (A released), Cmd+Tab away and back (no Super stuck); Safari's
    write-at-next-gesture path (the copy reaching the page clipboard at the
    next key or click, or Cmd+C);
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
    origin, not from that box. Popups are placed by the book from a SET
    geometry (GTK's menus were ~20 px off without it), but a default
    geometry counts as the surface origin for popups (`popupGeomOffset`),
    which keeps satellite's menus where they were (unverified since:
    satellite isn't installed here).
  - fullscreen should now work (satellite maps `_NET_WM_STATE_FULLSCREEN`
    to `xdg_toplevel.set_fullscreen`, which gets its configure since the
    window-states work) — unverified: satellite isn't installed in this
    container. X windows still can't maximize (satellite advertises only
    `_NET_WM_STATE_FULLSCREEN`); whether satellite turns an X iconify
    request into `set_minimized` is unknown (unverified either way).
  - no xdg_activation → `_NET_ACTIVE_WINDOW` requests are dropped (inferred).
  - untested: X ⇄ Wayland dnd, INCR-sized transfers, pointer-lock apps
    (satellite's own relative-pointer / constraints use).
- **Deferred, doable if wanted** (xdg-activation and xdg-toplevel-icon:
  feature candidates above): pointer-gestures, idle-inhibit / ext-idle-notify, single-pixel-buffer,
  content-type, tearing-control, xdg_wm_base v7, tablet-v2,
  foreign-toplevel-list / layer-shell, xdg-dialog (modal hint), xdg-system-bell
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
- GPU clients only with a `--dmabuf` backend: readback (copy mode; LINEAR
  ARGB/XRGB8888; no y_invert; v1/v2 binders get no formats) or virtgpu (a
  virtio-gpu node only; [AX]RGB/[AX]BGR8888, implicit or LINEAR, one
  plane; the page needs a gpu source, `EngineOptions.gpu`, or the core
  offers no linux-dmabuf and GPU clients render in software over wl_shm —
  FEATURE dmabuf_kind). Both: one tranche, `get_surface_feedback` = the default
  feedback; a dmabuf the backend can't import is accepted but never shown,
  released per commit — not a `failed` event; never run against a real
  GPU. No explicit sync (drm-syncobj): readback waits ≤ 500 ms, virtgpu
  ≤ 100 ms for implicit fences. X11 apps need `xwayland-satellite` + Xwayland
  installed (software rendering, no maximize, fullscreen untested; see the
  satellite entry above); no in-tree Xwayland.
- dnd works between wland clients only, not to/from the host page.
- The page clipboard bridge carries text/plain (UTF-8, ≤ 4 MiB) only; an
  app's copy reaches the page clipboard only around a user gesture in the
  desktop (5 s window, the next key/click, or a copy event), and the page's
  clipboard enters only on a paste in the desktop or, with clipboard-read
  already granted, on focusing it. The primary selection stays inside. The
  Apple chord handling has not run on a Mac (human item).
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
- Window geometry is the window's box (placement, sizes, maximize) and
  what popups are placed from (to their own; a default geometry counts as
  the surface origin there: satellite); a set geometry is not clamped to
  the surface's bounds. No positioner constraint adjustment (flip, slide,
  resize): the core doesn't know where windows are, so a menu near the
  desk's edge can hang off it.
- xdg_toplevel.move/resize are honoured only with the serial of a press
  still held on the window (core and wm), wl_data_device.start_drag only
  with one of the client's held presses (the wm and headless still cancel
  a drag that starts with no button down). set_selection (clipboard and
  primary) only from the keyboard-focused client, or with a recent input
  serial of the client's while no other client had input since
  (`maySetSelection`); wl-copy maps a 1×1 window for the focus, like the
  `copy` fixture now.
- Input regions are applied (picking passes over a surface outside its
  region, through a hole inside the window geometry too). A region over 32 boxes degrades to a superset (`Region.max`);
  synchronized subsurfaces apply it at their own commit, like all their
  state.
- Subsurface z-order (place_above/place_below, a subsurface below its
  parent included) is applied at the parent's commit, as the protocol
  says; wl_subsurface.set_position is not: it moves the subsurface at once.
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
