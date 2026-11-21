# Testing & environment

## Setup

Fedora container, no host compositor (we ARE the compositor). Zig 0.16.0 via
zvm, node, bun for tools, chromium for headless. That is all the tests need:
the E2E apps are `wland-fixture` modes (`test/fixture/`, built by `zig build`
next to wlandr; `test/support/apps.ts` maps roles to modes). The real apps
are the optional compatibility tier, `WLAND_E2E_APPS=real` on any E2E (a
phase whose app is missing is skipped; relay-e2e requires them all):

```sh
sudo dnf install -y wayland-utils foot wl-clipboard weston-demo nautilus
```

What the fixtures don't cover, the real apps do: libwayland-client's own
checks, xkbcommon compiling our keymap (the fixture only checks it is xkb
text), GTK's real commit patterns, foot's fractional-scale path, X11 through
satellite. Run the real tier before a release and after protocol work.
A fixture is strict like libwayland (unknown object/opcode, wrong message
size, wl_display.error → it exits 1 with the reason on stderr) and logs in
libwayland's WAYLAND_DEBUG format. To give a test a new app behaviour, grow
the fixture mode (mirroring the real app) rather than adding a dependency.

No /dev/dri, /dev/udmabuf or dma-heap here: no real dmabuf can exist, so
linux-dmabuf runs only against memfd stand-ins (`relay_test.zig`). Real
Mesa clients still bind it: `wlandr --dmabuf readback:/dev/null` (any char
device passes as the "render node") makes `wayland-info` print the feedback
and `weston-simple-egl` read it, fail to open the device and fall back to
wl_shm. A client really rendering into a dmabuf needs a host with a GPU.
COMMIT kind 2 (GPU resources) has no emitter in wlandr: only the JS test
relay sends it (the handle demo's `gpu=1` mode names kwshm exports as
resources).

Real clients that set cursor surfaces (`wl_pointer.set_cursor`, no
cursor-shape): weston's toytoolkit apps (`weston-flower`; it loads its
cursors at size 24 whatever the output scale), GTK3, X apps through
satellite. GTK3 demos (`gtk3-demo`, `gtk3-widget-factory`) abort here at
their first icon: glycin's bwrap'd SVG loader fails in this container. GTK4
and foot use cursor-shape.

Pointer-constraint clients: `weston-constraints` (weston-demo; a press on
its gray subsurface cycles unconstrained → confined → locked, both
oneshot; read its WAYLAND_DEBUG for `confined()`/`locked()`/
`relative_motion`) and SDL3 (`SDL3` + `sdl2-compat` are installed, no SDL
app is: headless-e2e drives one through `python3` ctypes, relative mouse
mode = a persistent lock + a relative pointer). SDL3 must run with
`SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0`: libdecor's GTK plugin aborts on the
same glycin icon failure as the GTK3 demos.

Presentation feedback: `weston-presentation-shm -f` (weston-demo) prints a
line per presented frame — `c2p` is commit → presentation on its own
clock_gettime(clock_id), printed unsigned (a presentation dated before its
commit shows as a huge number), `discarded N` per discarded one, and on
SIGINT `clean up feedback N` for every feedback it still holds, which
includes the LAST PRESENTED one (kept for the next p2p): not a leak. Its
`f2c` column compares frame-callback times with that clock, garbage on a
stream link (the engine's `done` time is the page's clock).
`test/support/presentation-shm.ts` parses it for both E2Es.

Window states: `weston-fullscreen` (weston-demo; keys `f` fullscreen,
`z` size, `-f` maps fullscreen). foot has no fullscreen binding by default
(`fullscreen=none`): drive it from the compositor side. nautilus's header
bar shows only close under GNOME's default `button-layout`; minimize and
maximize appear with `GSETTINGS_BACKEND=keyfile` and a keyfile
(`$XDG_CONFIG_HOME/glib-2.0/settings/keyfile`, `[org/gnome/desktop/wm/
preferences] button-layout='appmenu:minimize,maximize,close'`) — set for the
session bus too: GTK reads the layout through the settings portal the bus
activates (headless-e2e does this).

`weston-simple-shm` is in `weston-demo`; `xkbcli` (keymap regen) in
`libxkbcommon-utils`. Core dumps land as `core.<pid>` in the crashing
process's CWD (gitignored); gtk4-debuginfo helps read them. This container's
seccomp refuses AF_VSOCK (EPERM), so `--link vsock:` is only seen retrying.

## What to run

Tests do not depend on `web/` (a demo, free to change): Node tests take their
Wayland helpers from `test/support/`, the browser E2E serves its own pages
from `test/browser/`, smoke serves a throwaway root.

Browser E2E (`tools/run-poc.sh`: chromium + real apps, minutes, timing-fuzzy)
is NOT the default check. Run it only when the browser surface changed, and
then only the groups concerned (`tools/run-poc.sh foot gtk`). Every browser
check lives in one file, `tools/browser-e2e.ts` (one phase per check). What
apps do through the compositor is checked without a browser, by
`tools/headless-e2e-test.ts` (wland/headless over the relay's WebSocket).

| Changed | Run |
| --- | --- |
| `core/`, protocol logic | `zig build test` (also `-Doptimize=Debug`) + `node tools/headless-e2e-test.ts` (and with `WLAND_E2E_APPS=real`) |
| `server/` relay: WS path, wire handling, copy buffers | `zig build test` + `node tools/headless-e2e-test.ts` |
| `server/src/xwayland.zig`, the X11 launch path | `zig build test` + `node --test test/relay.test.ts` (a stand-in satellite) + `WLAND_E2E_APPS=real node tools/headless-e2e-test.ts` with `xwayland-satellite`, `Xwayland`, `xeyes` on PATH (the x11 phase skips otherwise) |
| `server/` relay: `--link`, STREAM framing, handle backends | `zig build test` + `node tools/relay-e2e-test.ts` |
| linux-dmabuf (`dmabuf.zig`, the dmabuf paths in relay/core) | `zig build test` (memfds stand in for dmabufs) + both Node E2Es for the shm paths it shares; a real GPU client is a human check (see Setup) |
| GPU commits in the engine/view/headless (`EngineOptions.gpu`, format 'gpu') | `node --test test/handles.test.ts test/client.test.ts test/headless.test.ts` + run-poc `handle-demo` (its `gpu=1` modes, 2D and GL) |
| `lib/engine.ts`, links, handles | `npm run typecheck` + `node --test test/*.test.ts` + both Node E2Es |
| `lib/index.ts` (`startServer`, `startRelay`, `serverBinary`) | `node --test test/relay.test.ts` (real wlandr on an fd link + headless + fixtures) + `tools/smoke.sh` |
| `lib/headless.ts` | `node --test test/headless.test.ts` + `node tools/headless-e2e-test.ts` |
| Presentation feedback (core `Feedback`, PRESENTED in relay/wasm/engine, the frame loop's refresh) | `zig build test` (also Debug) + `node --test test/engine.test.ts test/client.test.ts test/handle-demo.test.ts` + both Node E2Es (weston-presentation-shm on each link) + run-poc `handle-demo` (its synthetic clients check every presented time in the browser) |
| `lib/view.ts`, `lib/present.ts` | run-poc `foot retina handle-demo`; GL code: `bun tools/browser-e2e.ts webgl` |
| Pointer images (cursor surfaces/shapes: core, `view.ts`, headless) | `zig build test` + `node --test test/client.test.ts test/headless.test.ts` + `node tools/headless-e2e-test.ts` (weston-flower) + run-poc `cursor` |
| `lib/input.ts` (DOM events → engine) | run-poc `foot` (its `sweep` phase is the pointer-path check) |
| Pointer constraints / relative pointer (core, engine, `input.ts` Pointer Lock, headless) | `zig build test` + `node --test test/engine.test.ts test/client.test.ts test/headless.test.ts` + `node tools/headless-e2e-test.ts` (weston-constraints, SDL3) + run-poc `constraints` |
| `lib/wm.ts` (grabs, maximize, popups, dnd) | run-poc `foot gtk` (gtk's `dnd` phase drags in the `files` fixture); real nautilus: `tools/dnd-test.sh` |
| Window states (fullscreen, minimize, maximize: core, view, wm, input, headless) | `zig build test` (also Debug) + `node --test test/client.test.ts test/headless.test.ts` + both Node E2Es (headless: foot, weston-fullscreen, nautilus's minimize button — fixtures `term`, `fullscreen`, `files`; relay: a minimized simple-shm stops on the stream link) + run-poc `states` |
| `lib/client.ts`, the server's page serving and takeover | run-poc `foot takeover` |
| `test/support/`, `test/browser/` | `node --test test/*.test.ts` + run-poc `handle-demo` |
| `test/fixture/` (wland-fixture), `test/support/apps.ts` | `zig build` + both Node E2Es + the run-poc groups using the mode changed (`term`: foot, states; `files`: gtk; `cursor`; `constraints`) |
| `web/` | nothing here: build it and look (`tools/run-poc.sh --demo`) |
| Before a release, or a change that cuts across the above | all of the above: `npm test`, both Node E2Es, the whole `tools/run-poc.sh`; then the same with `WLAND_E2E_APPS=real` |

run-poc groups, in run order: `foot gtk cursor constraints states retina takeover handle-demo relay`
(`relay` is relay-e2e; alone it starts no browser).

## Approach

- Protocol logic is quickest to debug with native unit tests in `core/` (drive
  `Compositor` with the TestSink pattern in compositor.zig); the browser loop
  is slow and noisy.
- Relay logic: `server/src/relay_test.zig` + `harness.zig` (scripted client ⇄
  relay ⇄ StreamLink ⇄ core). `.backend = .procfd` / `.{ .kwshm = fd }`
  exercise the handle paths (`auto_ack = false` + `engine.ack()` holds ACKs);
  the kwshm one runs against `kwshm.fake`, the only place that path runs here.
  A client can't tell which event an SCM_RIGHTS fd belongs to, so the harness
  pops fds from a queue.
- Engine in Node: `test/*.test.ts` (`test/fake-dom.ts` stubs the DOM for
  view/input/wm). With apps: `tools/headless-e2e-test.ts`; a script that
  runs an app to completion must not block the event loop (`spawnSync`
  deadlocks: the compositor serving the app is that loop).
- A GTK app's session bus activates services (gvfsd, portals, localsearch,
  at-spi; ~12 processes, each holding an inotify instance, 128 per user)
  that exit only when the bus goes. A signal to `dbus-run-session` leaves its
  bus up: stop the APP and let it tear the bus down (run-poc's
  `stop_nautilus`), or own the bus (headless-e2e runs `dbus-daemon` on a path
  in its runtime dir, so `sweep` and SIGKILL reach it). The services' FUSE
  mounts in `XDG_RUNTIME_DIR` want `fusermount3 -u` before removing it.
- Browser debugging: dump `window.wlandLog` via CDP `Runtime.evaluate` 
  (`bun tools/browser-e2e.ts log [grep]`; `shot x.png` for a screenshot); the wasm logs every decoded
  message. For a client's view, `WAYLAND_DEBUG=1` on the app.
  `WebAssembly.Instance.exports` is frozen — you can't wrap exports from CDP.
  Pixels: 2D `getImageData`, or `canvas._wlPresenter.readback()` (GL too).
- Usual loop: implement → verify → update STATUS in plan.md → commit → note
  durable findings in `.agents/gotchas.md` / this file.

## E2E / CDP pitfalls

- Run run-poc redirected to a file (`tools/run-poc.sh > /tmp/poc.log 2>&1`);
  `| grep | head` from a background shell hangs on the pipe.
- run-poc uses its own port 8901 + socket `wayland-poc` + CDP 9222/9223, so
  it can run beside a human demo (8080/`wayland-0`). Two run-pocs at once
  need their own `PORT`, `WAYLAND_DISPLAY` and `CDP` (the chromium profile
  and its cleanup are keyed by `PORT`), e.g.
  `PORT=8911 CDP=9232 WAYLAND_DISPLAY=wayland-fx tools/run-poc.sh foot`. Any other live tab on its port reconnects and
  takes over the session mid-test ("browser takeover: kicking previous tab" in
  the log, apps "Lost connection") — close stray tabs or change `PORT`.
- "page did not come online" / `wlandStatus` undefined everywhere looks like a
  compositor regression but usually means the page failed to load: run-poc
  bundles `test/browser/` afresh each run (`bun tools/browser-e2e.ts build
  DIR`), so check that step's output first.
- **Headless key-event tests exercise no pointer paths.** The CDP mouse sweep
  (browser-e2e `sweep`, in run-poc's `foot` group; also asserts motion
  coalescing) covers them after input changes.
- CDP mouse coords are viewport-relative and silently hit nothing off-screen.
  run-poc uses `--window-size=1600,1100`; scrollIntoView and check the rect.
- A CDP drag's `mouseMoved` must say `button: "left"` (with `buttons: 1`):
  with the default `button: "none"` Chromium drops the pointer capture the
  press took (the implicit grab) and targets whatever is under the pointer.
- Headless chromium grants the Fullscreen API to a CDP key or press
  (trusted input); the fullscreen element then measures 800×544 there,
  whatever `--window-size` says. `document.exitFullscreen()` from
  Runtime.evaluate stands in for the user's Esc (CDP's never reaches the
  browser's handler). The `states` phase reloads the page with
  `?browserfs=1` and back.
- Headless chromium grants Pointer Lock to a CDP press (trusted input, the
  page focused), and movementX/Y under it are the deltas of the CDP
  coordinates. CDP's Escape key does NOT exit the lock there (the browser's
  Esc handler never sees it): `document.exitPointerLock()` from
  Runtime.evaluate is the user's exit as input.ts sees it.
  `unadjustedMovement` is refused (Linux: NotSupportedError).
- Awaiting each CDP mouse event's ack in a burst paces slower than rAF; big
  raw-move counts can't be asserted (Chromium coalesces pointermove ~1/frame).
- In-page timers are throttled to 1 Hz headless; keep run-poc's
  `--disable-background-timer-throttling` etc. if driving loops in-page.
- `--virtual-time-budget --dump-dom` doesn't wait for WebSocket I/O, so
  headless chromium is driven via CDP.
- Headless chromium is launched with `env -u WAYLAND_DISPLAY` so it can't see
  our socket. A killed
  chromium leaves stale `Singleton*` files in its profile and the next launch
  never attaches — run-poc wipes both profiles first.
- CDP `Emulation` overrides (dpr) persist across reloads while the CDP socket
  lives; an app must connect AFTER the page that should own it (the `retina`
  phase spawns foot itself).
- Real-app geometry is fuzzy: foot resizes snap to the cell grid, GTK buffers
  include shadow margins (outside the window box: the box is the window
  geometry, so canvas rects and box rects differ by the margin), GTK may pick
  its own unmaximize size — thresholds and positions hold up, exact sizes
  don't. GTK's top ~24 px is a resize band (a "headerbar drag" there
  resizes). foot's titlebar is inside the window box, its CSD border just
  outside; GTK's border is just inside.
- nautilus restores a maximized window from the GSettings keyfile
  (`~/.config/glib-2.0/settings/keyfile`); run-poc wipes it before the nautilus
  phase because the tests' click offsets assume a floating start.
- The WebGL present path is not exercised in E2E (GPU-less container).
  browser-e2e `webgl` forces it on software GL at dpr 1 only (`?webgl=always`);
  real-GPU verification is a human item.
- Kill leaked processes by name (`wlandr`, `wland-fixture`, `wland-chromium-profile`, app
  names). `pkill -f`/`pgrep -f` match their own shell when the pattern appears
  anywhere in the command line (exit 144) — bracket-escape every occurrence
  (`pkill -f "wland-chromium-[p]rofile"`) and run cleanup as its own command.
  `pgrep` also matches defunct zombies; filter them for liveness checks.
- wl-copy (and `wland-fixture copy` without `--foreground`) forks a server
  for the selection; the fixture detaches it from the caller's stdio so a
  test waiting for the process to close doesn't wait on the child.
- The `files` fixture's click positions are nautilus's (default floating
  layout, 24 px shadow): `test/fixture/files.zig` lists them. `paste` maps a
  1×1 window first: the core sends selections to the keyboard-focused
  client only (real wl-paste does the same).
- Not in run-poc: `tools/dnd-test.sh` (real nautilus dnd, own port/socket;
  coordinates are layout-dependent — re-screenshot with
  `bun tools/browser-e2e.ts shot 9224 x.png` if it misses) and
  browser-e2e `webgl`. `WLAND_E2E_RELAY="qemu-aarch64 DIR/bin/wlandr"`
  runs relay-e2e against the guest build (`zig build -Dtarget=aarch64-linux-musl
  -Dcpu=generic -Dhttp=false -Doptimize=ReleaseSmall -p DIR`).
