# wland — Wayland compositor in the browser

A library that shows unmodified Wayland apps (foot, nautilus) in a web page:
**core** (`core/`, Zig compositor → wasm), **relay** (`server/`, Zig; owns the
Wayland socket, intercepts fd-carrying messages) and **client** (`lib/`,
TypeScript; npm subpaths `wland/client` (engine + view · input · wm modules
composed, all re-exported) · `wland/engine` · `wland/headless`, the last a
DOM-free scene for Node scripts and tests).
Relay ⇄ engine speak STREAM v2 over a WebSocket or a byte stream; pixels travel in the
stream (copy) or stay in shared memory by handle (procfd/kwshm — the
unkernel path); GPU clients' dmabufs are copied like shm (`--dmabuf
readback`).

## Docs — read when relevant, not upfront

| When | Read |
| --- | --- |
| Starting work / picking a task | `.agents/plan.md` — architecture, open items, what was tried and why, current limits |
| Touching relay, core, engine or STREAM code | `.agents/gotchas.md` — the section for that area |
| Writing or debugging tests, E2E, CDP; fresh container | `.agents/testing.md` |
| Finding where something lives | `.agents/layout.md` |
| Link framing, buffer release, ACKs | `protocol/STREAM.md` |
| Why something was done a certain way | `git log -S` / `git log -- <file>` (history lives in commits) |

## Commands

```sh
zig build                     # wlandr + wland-fixture + wasm (ReleaseFast; wasm → lib/, committed: rebuild after core/ changes)
zig build release             # wlandr for linux x64 + arm64, static → zig-out/release/ (what the package ships)
zig build -Doptimize=Debug    # symbols + safety; use when chasing UB
zig build test                # native unit tests; also run with -Doptimize=Debug and -Dhttp=false
npm test                      # zig test + smoke + typecheck + node --test test/*.test.ts (needs zig build)
npm run typecheck             # tsc (TypeScript 7) over lib/ and test/
npm run build                 # obuild: zig builds, then lib/ → dist/ (+ the wasm, the release wlandr binaries brotli'd); dist/ is wlandr's default web root (lib/index.html)
tools/smoke.sh                # fast: build + tests + static serving
tools/run-poc.sh > /tmp/poc.log 2>&1   # browser E2E: chromium + app fixtures (redirect to a file; a pipe makes it hang)
tools/run-poc.sh foot gtk     # ...only some groups; all CDP checks live in tools/browser-e2e.ts (pages: test/browser)
tools/run-poc.sh --demo       # human demo on :8080; then `tools/wland-run foot`
node tools/relay-e2e-test.ts  # real relay over --link unix: ⇄ Node engine, app fixtures
node tools/headless-e2e-test.ts  # app fixtures ⇄ wland/headless over the relay's WS, no browser
WLAND_E2E_APPS=real node tools/headless-e2e-test.ts  # ...with the real apps (foot, nautilus, weston…; any E2E)
(cd web && bun run build)     # the demo page (fully in-page, not in the package; no test uses it)
python3 tools/gen_protocol.py # after touching protocol/*.xml
```

## How the current design holds together (why + the rest: `.agents/gotchas.md`)

These are facts about today's code, listed so they don't get broken by
accident. They are not design constraints: a deliberate redesign can change
any of them (update this list when it does).

- `lib/` and `test/` are TypeScript that Node runs unbuilt (type stripping):
  erasable syntax only (no enums/namespaces/parameter properties), `.ts`
  import extensions, `import type` for types; exported functions spell out
  their types (isolatedDeclarations: obuild emits `dist/*.d.mts` per file).
  The package exports `dist/`; tests and the web page import `lib/` source.
- Zig 0.16 std is reworked; `~/.zvm/0.16.0/lib/std/` has the actual API.
- App socket reads go through `shm.recvWithFds` (plain reads drop SCM_RIGHTS fds).
- FD RULE: a global is advertised only if the relay handles its fd args — at
  every version bumped through, per the XML.
- `wl_buffer.release`: once per busy period and only after an attach — decided
  in `relay.zig` `settleRelease`, on the app thread; the engine doesn't release.
- Pool reads go between `shm.beginAccess`/`endAccess` (pool size is a client
  claim; SIGBUS).
- Input is role-gated (keyboard → toplevels only, pointer not to cursor
  surfaces) and focus-gated; a leave for a destroyed surface kills the client.
- Pointer constraints: the core owns the state (when a lock/confinement
  applies); the embedder only asks the browser for Pointer Lock when told
  ('pointer-lock') and reports grant/loss — `locked` goes out on the
  browser's grant, never before. The implicit grab is pointer capture.
- WIRE frames hold whole messages; frame order within a link message matters.
- Server-allocated ids are one dense space; primary offers are typed via SRVOBJ,
  dmabuf `create` wl_buffers named to the relay by DMABUF_CREATED.
- linux-dmabuf is opt-in (`wlandr --dmabuf`): the relay's FEATURE frame, first
  on a link, is what makes the core advertise it; plane fds stay in the relay.
- Frame callbacks fire on exactly one side per link (WS: relay; stream: engine).
- Window states (maximized, fullscreen, minimized) are core state: the embedder
  asks (`setMaximized/setFullscreen/setMinimized`) and reacts to the events;
  restoring a minimized window is only ever the embedder's.
- `activated` follows keyboard focus (keyboardEnter/Leave reconfigure the
  toplevel); a 'surface' event with role none means unmapped — the role
  object went, or attach(NULL) was committed.
- Presentation feedback is the core's on every link (latched by commit,
  presented/discarded at the next tick); `presented` crosses as a PRESENTED
  frame whose time the relay overwrites with its CLOCK_MONOTONIC — no
  engine clock ever reaches an app as a presentation time.
- Wasm exports that can emit events call `flushOut()`; every `extern "env"` must
  exist in engine.ts imports (LinkError otherwise); wasm `u32` args arrive in JS as `i32` (`>>> 0`).
- A commit's `pixels` is valid only during dispatch and dies at the first engine
  call; a GPU commit's `image` (what `EngineOptions.gpu` resolved) is drawn
  during dispatch, then released and ACKed — nothing reads the resource later.
- `#desktop` is owned by the lib; React doesn't render into it.
- wlandr's socket: `--display NAME` or the first free `wayland-N`, held by
  flock on `<name>.lock` (`server/src/socket.zig`); it never reads
  `$WAYLAND_DISPLAY` and never replaces a live socket.
- X11 apps: wlandr claims an X display and starts `xwayland-satellite` (not
  shipped) for the first X client, handing it only the listeners
  (`server/src/xwayland.zig`); `x11 display: :N` is logged before the ready
  line and left in `<socket>.x11`.
- Headless chromium: `env -u WAYLAND_DISPLAY` (our socket is often the
  default `wayland-0`).
- E2E apps are `wland-fixture` modes (`test/fixture/`, Zig on core's wire
  codec, no libwayland), one per real app they stand in for, mirroring what
  the tests read off it (output format, `WAYLAND_DEBUG` log, layout and
  click positions); `test/support/apps.ts` maps roles to fixture or real
  (`WLAND_E2E_APPS=real`). A test that needs a new app behaviour grows the
  fixture, not a dependency.

## Workflow

- Protocol logic is quickest to debug with native unit tests (core TestSink,
  relay harness). Input changes: run-poc's `foot` group (its `sweep` phase)
  covers the pointer paths key-event tests miss.
- STATUS in `.agents/plan.md` tracks what's open.
- Browser E2E (run-poc) is not the default check: run it only when the
  browser surface changed (`lib/view`, `present`, `input`, `wm`, `client`),
  and then only the groups concerned. App-level behaviour is checked without
  a browser (`tools/headless-e2e-test.ts`). `.agents/testing.md` "What to
  run" maps changes to checks.
- Tests never import from or build `web/`: shared helpers live in
  `test/support/`, the browser E2E's pages in `test/browser/`.
- Durable findings go where they apply — `.agents/gotchas.md` for code,
  `.agents/testing.md` for test/env traps.
- Kill leaked processes by bracket-escaped name: `pkill -f "[w]landr"`.
