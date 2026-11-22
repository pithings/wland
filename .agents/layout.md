# Code map

Where things live and which file owns what. Details are in the code.

## `core/src/` — shared Zig, native (tests) AND wasm32-freestanding

- `compositor.zig` — **the compositor**: transport-agnostic, callback-based,
  never sees an fd or a pixel. All advertised globals live here.
- `wasm.zig` — the core's public ABI (exports + `js_*` imports).
- `stream.zig` — STREAM v2 codec shared by relay and wasm (frames, handle bytes,
  `CommitFrame.shm()` validation).
- `wire.zig` wire codec · `protocol_gen.zig` GENERATED (`tools/gen_protocol.py`)
  · `objects.zig` id→interface · `pixels.zig` BGRA→RGBA · `us.xkb` canned keymap.

## `server/src/` — the relay

- `main.zig` CLI (`--port/--host/--web-root` = HTTP+WS; `--link fd:|unix:|vsock:`;
  `--buffers copy|procfd|kwshm`; `--dmabuf readback|virtgpu[:NODE]`; `--no-fence-wait`;
  `--link-on-demand [--link-timeout MS]` (the dial loop `serveStreamLink`, bounded `dialWithin`;
  its state is relay.zig `OnDemand`);
  `--version` (version from package.json via `build.zig`, + a features line);
  `-Dhttp=false` = a --link-only build).
- `relay.zig` — app sockets, fd interception, pools, attach/commit tracking,
  the release ledger (`settleRelease`), ACK hand-over, frame-callback
  interception, pipe tokens, SRVOBJ, presentation timestamps (PRESENTED),
  the kept copy of the engine's own selection (own_pipe);
  `serveLink`/`serveApp`. `pipe_writer.zig` — the one thread writing the
  own selection into receivers' pipes (capped, refcounted payloads).
- `link.zig` Link interface · `ws_link.zig` browser WS · `stream_link.zig`
  u32-length records.
- `buffers.zig` backend interface · `copy_backend.zig` snapshot/swizzle/trim/LZ4 ·
  `handle_backend.zig` one handle per wl_buffer + procfd/kwshm exporter ·
  `kwshm.zig` /dev/kwshm UAPI (+ `kwshm.fake` in tests) · `dmabuf.zig`
  linux-dmabuf relay side: params planes, dmabuf buffers, the dmabuf backends
  (readback: map + copy path; virtgpu: name the resource → COMMIT kind 2),
  FEATURE bytes · `virtgpu.zig` virtio-gpu DRM UAPI (PRIME import,
  RESOURCE_INFO, GEM_CLOSE), the relay-wide GEM-handle refcounts, and
  `Fake`, the test-only stand-in device.
- `socket.zig` claiming the wayland socket name (flock'd `<name>.lock`,
  first free `wayland-N`, never a live socket; libwayland's scheme) and
  removing both files at exit, signals included.
- `xwayland.zig` X11 through xwayland-satellite: claims an X display
  (`/tmp/.X<n>-lock` + the two sockets) and a thread that fork/execs
  satellite with the listeners when the first X client connects.
- `shm.zig` recvmsg/SCM_RIGHTS/memfd/Pool/SIGBUS guard · `server.zig` HTTP +
  `/ws` · `harness.zig` + `relay_test.zig` native E2E.

## `lib/` — the npm package source (TypeScript, ESM, subpath exports)

Runs as-is on Node's type stripping (erasable syntax, `.ts` import
extensions); each module's exported types are its contract. The package ships
`dist/` (gitignored): `npm run build` = obuild (`build.config.ts`), whose start
hook runs the zig builds first, then transforms lib/ file by file into
`.mjs` + `.d.mts` (`index.html` passes through); its end hook adds the wasm
and the brotli'd wlandr binaries. Tests, tools and the web page (a vite alias)
import lib/ source, never dist/.

- `engine.ts` (`wland/engine`) — no DOM: wasm, link, buffer source, gpu source, events,
  input calls, motion coalescing. `link-ws.ts`, `link-stream.ts`.
- `view.ts` canvases/windows/stacking, input-region hit elements, pointer
  images (CSS cursors; an oversized cursor surface, or any while the
  pointer is locked, follows the pointer) (+ `present.ts` 2D/WebGL) ·
  `input.ts` DOM → evdev, IME sink, the implicit grab (pointer capture),
  Pointer Lock for pointer-constraints locks, relative motion ·
  `wm.ts` move/resize grabs, maximize/fullscreen placement, minimize/restore,
  Alt+F9/F10/F11, the browser's Fullscreen API (browserFullscreen),
  popups, dnd ·
  `clipboard.ts` the page clipboard bridge (text both ways, on input's
  paste-chord hooks; engine selection API: `readSelection`/`setSelection`,
  `readSelectionText`/`setSelectionText` in engine.ts) ·
  `client.ts` (`wland/client`) `createWland()` composes them and re-exports
  all of them (view/input/wm/clipboard/present have no subpath of their own).
- `headless.ts` (`wland/headless`) `createHeadless()` — the engine plus a
  DOM-free scene (RGBA buffers, positions/z, hit-testing, scripted input,
  screenshots, `encodePNG`, the current pointer image, a scripted pointer
  lock: grantLock/breakLock, relative moves, window states:
  setFullscreen/setMaximized/minimize/restore); mirrors view/input/wm policy
  on plain numbers.
- `index.ts` (`wland`) Node API: `startServer` (wlandr's HTTP shape),
  `startRelay` (wlandr `--link fd:3`, the link handed back as a ByteStream:
  the headless shape), `serverBinary`, `appEnv` · `cli.ts` the `wland`
  bin · `index.html` the page `npx wland` serves: startServer's and
  wlandr's default web root is `dist/` itself, so its inline module imports
  `./client.mjs` unbundled (a window list, a status line; not the demo, not
  the tests' page). `wland.wasm` lands here from `zig build` (committed, so the web page
  builds without zig).

## Elsewhere

- `web/` — the demo page (React + Tailwind), fully in-page, no server:
  `src/wayland/` the guest side in TS (`toolkit.ts` canvas-backed Wayland
  clients, `app-types.ts` its app-facing API; `relay.ts` `kwshm.ts`
  `links.ts` `proto.ts` the relay, shared memory, links, wire/STREAM
  codecs); `src/apps/` the imaginary apps
  (Browse carries the introduction, Code the SDK snippet `wland.ts`);
  `src/session/` `sources.ts` (where clients live: the in-page source, and
  the dev-only Host source — real apps behind the repo's wlandr, which
  `vite-wlandr.ts` starts with the SDK's `startServer` (one per vite
  process) and proxies at `/__wlandr/ws`, with `POST /__wlandr/run`
  launching apps via `runApp`) + `session.ts`
  (the createWland singleton/store);
  `src/components/` + `App.tsx` the full-screen page (top bar, desktop
  with a dock over it, inspector, status line). Its own `npm run typecheck`
  (not part of the root one: it needs web/'s deps).
- `test/` — Node tests of the engine and client. `tools/` — run-poc, smoke,
  wland-run, `browser-e2e.ts` (every CDP check, one phase each),
  `headless-e2e-test.ts` (apps ⇄ wland/headless over WS),
  `relay-e2e-test.ts` (stream link, handle backends), `dnd-test.sh` (real
  nautilus only), `firefox-smoke.ts` (headless Firefox over WebDriver BiDi:
  the handle demo + wlandr with the term fixture).
  `test/fixture/` — `wland-fixture` (Zig, built by `zig build`): the E2Es'
  stand-in apps, one mode each (`main.zig` lists them): `wl.zig` the client
  (socket + fds, strict decoding, WAYLAND_DEBUG log), `app.zig` seat and
  toplevels, `simple.zig` shm + presentation, `clip.zig`, `pointer.zig`
  cursor/constraints/relative, `term.zig` (foot), `files.zig` (nautilus),
  `browser.zig` (Firefox's seat shape: wl_seat bound twice),
  `dmabuf.zig` (a linux-dmabuf GPU client over memfds).
  `test/support/apps.ts` maps E2E roles to a fixture or the real app.
  `test/support/` — plain-JS Wayland helpers for tests (STREAM encoder, JS
  relay, synthetic clients, kwshm fake), `handles-procfd.ts` (a Node procfd
  `HandleSource`, not in the package), `presentation-shm.ts` (reads
  weston-presentation-shm's output for both E2Es) and `isolated.ts` (a
  COOP/COEP mirror of a web root, for the handle demo's SharedArrayBuffer
  modes);
  `test/browser/` — the browser E2E's pages. Nothing under `test/` or `tools/` imports from `web/`.
- `protocol/` — Wayland XMLs + `STREAM.md`.
- `docker/` — the demo image (`Dockerfile`: a node+zig builder runs
  `npm run build`; debian:trixie-slim with chromium + pcmanfm + l3afpad, dpkg
  path-excludes for what they never load) and `entrypoint.sh` (wlandr
  `--host 0.0.0.0`, apps run via `tools/wland-run`, the ones not running
  relaunched at each engine detach). Context: the repo root, `.dockerignore`.
