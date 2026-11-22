# Hard-won gotchas

Every item here cost a debug cycle. CLAUDE.md carries one-line versions of the
most critical; this file has the why, by area. Items describe what breaks in
the current design and why — if a redesign removes the cause, the item goes
with it. New findings go in the matching section.

## Zig 0.16 std

`~/.zvm/0.16.0/lib/std/` has the actual API. Known moves:

- Networking is `std.Io.net` (needs an `Io`); main is
  `pub fn main(init: std.process.Init)` (gives `gpa`, `io`, `minimal.args`,
  `environ_map`). An `Io` outside main: a global `Io.Threaded.init(gpa, .{})`
  (`.io()` needs a stable pointer).
- `std.Thread.Mutex/Condition` → `Io.Mutex/Io.Condition` (`lockUncancelable`,
  `waitUncancelable`). `std.Thread.sleep` → `io.sleep(.{ .nanoseconds = n },
  .awake)`. `std.time` has no clocks: `std.Io.Clock.now(.awake, io)`.
- Gone: `std.posix.close` (`std.os.linux.close`), `std.meta.intToEnum` (switch
  on the int), `std.posix.getsockopt` (`std.os.linux.getsockopt`, check
  `std.os.linux.errno(rc)`).
- `Io.net.Socket.createPair` hardcodes AF_INET — use `std.os.linux.socketpair`.
- A `union(enum)`'s bare tag literal (`U.tag`) is the TAG type, not the union
  (`{f}` fails with "no member format in tag_type"); write `@as(U, .tag)`.
- **The test runner fails a test on any `std.log.err`.** Expected error paths
  log at warn or below and lower `std.testing.log_level` in that test. Run
  `zig build test -Doptimize=Debug` too: ReleaseFast hid UB in core's TestSink.
- **SIGPIPE is not ignored** and the relay installs no handlers: a relay whose
  stderr is a pipe that closes dies on its next log line (link/app writes use
  MSG_NOSIGNAL). Redirect a guest relay's log to a file.
- AF_UNIX paths are limited to 108 bytes (`--runtime-dir` too long →
  `NameTooLong`; the CLI shows "exited before listening").

## Build & packaging

- The default build is ReleaseFast via a plain `b.option` (`standardOptimizeOption`
  can't default to a release mode). `strip = false` on the wasm module takes
  it from 140K to ~770K (name section).
- The wasm lands in the SOURCE tree (`lib/wland.wasm`) whatever `-p`
  says. It is committed so the web page builds without zig (Vercel):
  commit it with any `core/` change, or the page ships a stale core.
  `npm run build` (obuild; its start hook in `build.config.ts` runs the
  zig builds) ships `zig build release`: wlandr for linux x64 + arm64 with an
  explicit target and `.cpu_model = .baseline` (the native default targets
  the host CPU's features — not portable; baseline is aarch64 `generic` =
  ARMv8.0+NEON, atomics as LL/SC, no LSE/CRC/crypto — and x86-64 v1; no libc
  is linked, so they are static whatever the ABI), which its end hook
  brotli-compresses into `dist/wlandr-linux-<arch>.br`. The same step builds
  `wlandr-link-linux-<arch>` (`-Dhttp=false -Dsession=false` ReleaseSmall, the
  guest build: --link only, passthrough only — the session host and its
  compositor are ~40% of it otherwise):
  release.yml attaches it to the GitHub release, the npm package leaves it
  out (nothing in it runs a --link-only relay). To check the baseline:
  `llvm-objdump -d --mattr=-all,+v8a,+neon,+fp-armv8` on the arm64 binaries
  must print no `<unknown>`.
  `serverBinary()` unpacks the one it needs into `~/.cache/wland/`, named by
  content hash (a checkout's `zig-out/bin/wlandr` wins over it).
- `startRelay()` hands wlandr its link as fd 3 with a plain `'pipe'` stdio
  entry: Node's stdio pipes are AF_UNIX socketpairs, which is the connected
  stream socket `--link fd:N` wants. The relay exits when that fd closes
  (close() or the parent dying), so nothing has to kill it. Its default
  runtime dir is a mkdtemp under the temp dir, or `/tmp` when `$TMPDIR` is
  too deep for a socket path (sun_path: 108 bytes; wlandr fails with
  `NameTooLong`).
- `lib/` `startServer()`/`startRelay()` resolve on the server's `info: wayland
  socket: <path>` line, logged only after both listeners bind, and take the
  display name from that path (wlandr may pick it); the CLI depends on it too.
- web consumes the repo root via a postinstall `ln -sfn ../.. node_modules/wland`
  — bun's `link:`/`file:` don't work for this.

## Relay (`server/`)

- **Plain reads on the app unix socket silently drop SCM_RIGHTS fds**; app
  reads go through `shm.recvWithFds`.
- **Two writers on an app socket** (app thread: releases, frame done; link
  thread: events, fds) — every write goes through the conn's `AppLink` (write
  mutex + `closed` tombstone), or an 8-byte release lands mid-batch.
- **Browsers fragment WebSocket messages** (Chrome, ~70K sends, inconsistently).
  std's `readSmallMessage` can't take that; `WsLink.readMessage` does RFC6455
  reassembly. Desync symptom: garbage "header" bytes with rsv bits set.
- **shm pool storage outlives `wl_shm_pool.destroy`** while buffers reference
  it (weston-simple-shm destroys the pool right after create_buffer; pool ids
  get reused). Hence refcounted `*shm.Pool`s rather than zombies keyed by id.
- **A pool's size is a client CLAIM**; its file can be shorter or be truncated
  under a live buffer at any moment. A mapped read past EOF is SIGBUS — one bad
  client used to kill the relay and every app. Every read of `pool.data` goes
  between `shm.beginAccess`/`endAccess` (the SIGBUS handler maps zero pages over
  the pool; the commit goes unshown, as libwayland-server does). An fstat check
  wouldn't cover it: truncation can land between check and read.
- **The copy backend's swizzle copies at COMMIT time, not at burst flush** — the
  pool can be remapped (resize) and the buffer redrawn (already released)
  before the send. Lives in `copy_backend.zig`.
- **Copy-path pixel shipping**: per surface the relay keeps an RGBA shadow of
  what the engine shows and trims each damaged rect to what actually changed
  (clients over-damage: whole cursor rows, INT32_MAX rects); payloads ≥ 4 KB
  that shrink go out LZ4'd as BUFFER_LZ. The engine inflates them in wasm,
  **synchronously** — an async decoder (DecompressionStream) would reorder
  presents against WIRE frames. Raw BUFFER stays zero-copy (never enters wasm).
- TCP_NODELAY is set on accepted WS sockets: without it, small input/event writes + delayed
  ACKs = ~40 ms stalls over real links (loopback hides it).
- **A commit's BUFFER/COMMIT frame is emitted AFTER the commit's WIRE is
  forwarded**: the engine latches commit state (viewport destination) before
  presenting; the other order leaves a maximized window at its floating CSS size.
- **Damage**: clamp every rect to the buffer (clients send negative/INT32_MAX
  rects). `wl_surface.damage` is surface-local: scale it by the buffer scale
  with a SATURATING multiply (`*|`; nautilus's INT32_MAX × 2 overflows); with a
  viewport/transform it becomes full-buffer.
- **`wl_buffer.release`: one per busy period, and only after an attach.** GTK
  commits without attach (empty frames) and, on release, caches ONE cairo
  surface and destroys any other; a duplicate release destroys the surface GTK
  is painting into → nautilus SIGSEGV in end_frame under constant resize (two
  human core dumps; headless never reproduced it — releases return too fast).
  Decided in one place, `relay.zig`'s `settleRelease`, on the conn's app thread
  after every commit (`finishCommit`) and ACK (`ackCommit`): release when
  `owed && busy == 0`. `pending_attach` makes a release owed; backends return a
  `Settle` and the engine doesn't release, so there is a single ledger. `wl_buffer.destroy`
  forgets the buffer (pending COMMITs get buffer_id 0) and clears it from every
  surface naming it — else a commit without attach presents/releases whatever
  object reuses the id. Spec: STREAM.md "Buffer release".
- **ACKs arrive on the link thread; buffer/handle state is app-thread-only.**
  The link thread only queues the serial (AppLink `acks` + eventfd) and leaves
  AppConn state alone. A release written while holding a lock the app thread
  waits on deadlocks both when the app is stuck (why there is no shared
  per-conn mutex). App-thread releases are what keep them
  ahead of the engine's `delete_id` for a destroyed buffer.
- **A buffer handle closes only after every COMMIT naming it is ACKed** (or its
  conn/link ends): kwshm drops the host's view the instant the guest releases
  an export. Handle sizes never change: resize = new handle, never a refresh.
  One handle per wl_buffer, not per pool: kwshm pins every exported page (holes
  too, half-of-RAM cap, ≤ 4096 exports) and foot's scroll pool is sparse, up to
  512 MiB.
- **Relay-fired frame callbacks keep a 16 ms per-conn floor.** Without the
  browser round trip, loopback drains instantly and apps spin unbounded
  (~470 frames for one menu dismiss), which tripped a nautilus GMenu
  double-free. The sleep runs on the app's own thread (it waits for `done`).
- **A link dropping is `info`, not `err`.** Stream links are re-awaited
  (page suspend/resume, vsock reset at snapshot restore): `serveLink` logs
  `LinkGone` as "engine link dropped" at info, and peer-gone errnos /
  mid-record EOF are not errors; what really is (a bad record length, a WS
  protocol violation) is logged as `err` where it is detected.
- **`serveLink` returns only when `link.users == 0`.** Anything calling into a
  link from another thread (a takeover kick) holds a `users` ref under
  `relay.mutex`.
- **`WsLink.kick` doesn't block**: an app thread stuck in send holds
  `write_mutex` until the socket is shut down. Close frame is best effort
  (tryLock + MSG_DONTWAIT), shutdown always.
- **`/ws` is Origin-checked** (`server.zig` `sameOrigin`): an upgrade with an
  `Origin` must name the request's `Host`; no Origin (non-browser tools) is
  allowed. A proxy must forward both unchanged (vite's does) or rewrite both.
- **Two wlandr never share an endpoint.** HTTP binds with SO_REUSEADDR only
  (`server.zig` `listen`; std's `reuse_address` adds SO_REUSEPORT,
  which let a second relay take half the connections): a taken port fails
  with AddressInUse; `--port 0` lets the kernel pick (logged, and what
  startServer reports). Wayland names are flock'd (`<name>.lock`) and a
  socket that answers is never replaced — an explicit `--display` that's
  taken fails, auto-pick moves to the next `wayland-N`. Old wlandr builds
  held no lock; the connect probe covers them.

- **linux-dmabuf fds live in the relay, objects in the core.** A plane fd
  waits in the conn's `dmabuf_params` until create/create_immed moves it
  into a heap `dmabuf.Buffer` in the buffer table (same `Tracked` ledger as
  shm: `settleRelease` unchanged). `create_immed` names its wl_buffer;
  `create`'s is a server id the ENGINE allocates, so the core sends
  DMABUF_CREATED just before `created`, the link thread queues it on the
  AppLink, and the app thread adopts it before its next request (also
  putting the id in `conn.objects`, or `wl_buffer.destroy` on a server id
  wouldn't decode). An `add` on a relay without `--dmabuf` closes the fd
  and drops the conn: the core refuses the bind, but the fd is already in
  the socket.
- **readback maps the dmabuf as a shm Pool** (size from lseek SEEK_END,
  read-only, whole), so the copy backend reads it unchanged under the
  SIGBUS guard — a memfd stand-in can be truncated like a pool. Around the
  read: poll(POLLIN) ≤ 500 ms for implicit write fences, then
  DMA_BUF_IOCTL_SYNC START/END|READ; ENOTTY (memfd) is remembered and the
  ioctl skipped after. It needs the copy buffer backend: a handle backend
  would export the dmabuf fd as procfd/kwshm memory, which a dmabuf isn't
  (main.zig refuses the combination).
- **virtgpu: GEM handles are per object, not per import.**
  `DRM_IOCTL_PRIME_FD_TO_HANDLE` on one DRM fd returns the SAME handle for
  the same dmabuf object, however often (two wl_buffers over one dmabuf, or
  two apps), and the kernel doesn't count imports: one GEM_CLOSE kills it
  for every holder. So `virtgpu.Importer` counts holders per handle
  relay-wide (each buffer + each un-ACKed COMMIT), with the ioctls inside
  its mutex — an import racing the last unref would otherwise get a handle
  that is being closed. The COMMIT's own reference (Pending `.gem`) is what
  keeps the resource past `wl_buffer.destroy` until the ACK; the
  dmabuf.Buffer (and its plane fds) goes at destroy as before. A conn
  ending drops its Pending references in `AppConn.deinit`.
- **virtgpu COMMITs need the ACK path whatever `--buffers` says.** The
  conn's eventfd (`AppLink.ack_fd`) used to exist only for handle
  backends; with copy buffers an ACK for a virtgpu COMMIT was dropped as
  "never sent" and the buffer never released. `serveApp` creates it when
  the dmabuf backend `sendsCommits()` too. The serial counter moved from
  the handle backend to `AppConn.next_serial` (one space per conn, STREAM.md):
  backends get `Commit.serial` and the relay advances it on `.busy`.
- **A surface's full-buffer rect follows its content KIND, not just its
  size.** `SurfaceState` remembers dims and kind (pixels / resource) of
  what the engine last showed; a change of either forces one full rect. A
  GTK3 window moving between cairo/shm and GL at one size otherwise kept
  the GPU image (copy mode: the shadow trimmed the next shm commit to
  nothing) or showed black outside the damage (handle modes: the GL
  presenter blanks its texture when pixels follow an image). The copy
  backend's shadow is dropped when a resource COMMIT goes out — not at the
  switch back, since an unshown commit in between forgets the kind.
  Swapchain resources alternating are ONE kind: damage is relative to the
  previous commit's content, and each buffer holds the whole surface.
- **virtgpu: the render node is open only while a GEM handle is held.**
  Without VIRTIO_GPU_F_CONTEXT_INIT (unkernel offers only VIRGL) the guest
  creates a host virgl context for a DRM file at its first PRIME import
  (`virtio_gpu_gem_object_open`) and destroys it only at file close — one
  more renderer context in the page, and unkernel refuses snapshots while
  any exists. So `Importer` opens the node at the first import and closes
  it when `refs` empties (both under its mutex; handles are per file, so
  that is exactly when closing loses nothing), reopening at the next.
  Startup only validates it (open, DRM_IOCTL_VERSION == "virtio_gpu",
  close; `main_device` from stat). Device-open logs are `warn`: the test
  runner fails a test on any `err` line, and startup prints the fatal one.
- **virtgpu: a client's width/height/stride are a CLAIM.** Checked
  against RESOURCE_INFO.size (the GEM size, page-rounded — 0 only becomes
  PAGE_SIZE, never "unknown") plus a 16384 px side cap
  (`dmabuf.virtgpuBounds`); refused buffers drop their handle. That size
  is the layout's total only for PIPE_BIND_SHARED resources (GBM, EGL-
  Wayland: always): Mesa's virgl_resource_create_front asks for 1 byte
  (staging-capable textures) or 0 (MSAA) otherwise, so a non-shared
  texture exported as a dmabuf is refused though valid on the host — kept
  (the safe side); its log line says so (`refusalText`, one page).
- **virtgpu once-logs are per class**: refusals (a client can mint kinds
  at will) can't crowd out the accepted-buffer lines (≤ 16 kinds exist);
  the fence-timeout line (info) is a per-conn flag. A device that won't open
  is no buffer's property and repeats at every import (a resize storm):
  `Device.open` logs nothing, the importer logs it at most once a minute
  with the count since (`open_log_interval_ms`; reason + errno carried in
  `Failure`), startup's `check` logs its own.
- **virtgpu ordering is the emitter's** (STREAM.md "wlandr's emitter"):
  the page's renderer must have executed the client's GPU work when the
  COMMIT is processed, and STREAM carries no fence. What wlandr guarantees:
  the COMMIT is built while handling the client's `wl_surface.commit`, after
  its WIRE, never queued or deferred (Mesa submitted before it sent the
  request), plus a bounded poll on the dmabuf for its implicit write fences
  (100 ms, then sent anyway, logged once per conn at info: slow first frames
  — shader compiles — hit it legitimately). `--no-fence-wait`
  (`dmabuf.Config.fence_wait`) skips the poll, for unkernel: GPU requests and
  vsock packets share one channel to the page, so ordering never depended
  on it and each poll costs a worker⇄page round trip per frame. Don't move
  COMMIT emission off the commit path (batching across bursts, a sender
  thread) without re-deriving this — with the wait off, emission order is
  the whole guarantee.
- **virtgpu's ioctl seam** is `virtgpu.Device.fake` (a runtime pointer, not
  kwshm's comptime swap) so the shipped binary can run the stand-in:
  `--dmabuf virtgpu:@fake` is TEST-ONLY and kept out of the usage text —
  the E2Es' only way to drive the backend with no /dev/dri. Its "dmabufs"
  are memfds (any regular file); nothing real can allocate on it. Unit
  tests can set `Fake.accept_pipes` to import an empty pipe: a dmabuf whose
  write fence never signals (how the fence-wait test sees the 100 ms).
- **`--link-on-demand`: apps start the dial; a failed dial refuses them.**
  State is `Relay.on_demand` under `relay.mutex`: an app finding no link
  counts itself in `waiting` and signals `demand` (the dial loop in main.zig
  `serveStreamLink` sleeps in `awaitDemand`); `dialFailed` zeroes `waiting`,
  bumps `failures` and broadcasts `link_attached`, and a waiter that sees
  `failures` move is refused (closed, `refused_line` logged — its text is
  documented for unkernel: change it only with the docs). Waiters have no
  timeout of their own (Io.Condition has no timed wait): the DIAL is
  bounded (`dialWithin`: non-blocking connect + poll/EAGAIN retry up to
  `--link-timeout`, then the fd made blocking for StreamLink), so every
  wave ends in an attach or a failure. Apps arriving mid-dial wait on that
  dial; a waiter counted out by a failure but taken on by a later link
  doesn't decrement. After serveLink returns the loop dials at once only
  if `waiting > 0` (every app of the closed link was dropped with it). An
  app that hangs up while waiting still counts (its conn opens and closes
  on the link) — the waiter doesn't poll its socket.
- **`relay.dmabuf` can be set late, on demand only.** A `--dmabuf` node
  that won't resolve at startup is retried before each dial (warn, not
  err); the dial loop sets `relay.dmabuf` under the mutex while no link is
  attached. So serveApp reads it (the `commits` → eventfd decision) only
  after its link is attached — reading it before the wait raced the set
  and left a conn without `ack_fd` (virtgpu ACKs dropped, no release).
  FEATURE still goes first on each link from what is set then: a link
  dialed before the node appears never offers linux-dmabuf.
- **`wlandr --version`** prints `build_options.version` (package.json's,
  read by `build.zig`; `-Dversion=` overrides) and a `features:` line built
  at comptime in `main.zig` — buffers/dmabuf tokens straight from their
  enums, so a new mode shows up by itself (and must keep `@fake` out: it is
  a NODE, not a mode). Tokens are append-only: guest scripts test them.
- **FEATURE goes out before the link is attached** (serveLink, before
  `relay.link = link`), so it precedes every CONN_OPEN and the core never
  answers a registry without knowing about dmabuf. One message
  (`dmabuf.Config.featureFrames`): with virtgpu, dmabuf_kind (virtgpu)
  first, then linux_dmabuf — the core decides at linux_dmabuf whether to
  offer it, so a GPU-less page never advertises a global whose commits it
  can't show. linux_dmabuf's bytes can't grow (the table's length is the
  frame's), so a new fact is a new feature kind, not appended bytes.

- **X11 = xwayland-satellite, launched by wlandr** (`xwayland.zig`). The
  display is claimed like an X server does (pid in `/tmp/.X<n>-lock`, written
  `%10d\n`; `/tmp/.X11-unix/X<n>` + the abstract socket) so DISPLAY is known
  before anything X runs; satellite gets the listeners as fds 3/4
  (`-listenfd`, which makes Xwayland skip its own lock) on the first
  connection. The child must inherit NOTHING else — `close_range` after the
  dup2s: a `--link fd:N` held by satellite keeps the link open after wlandr
  dies, and the Node side never sees it close. Between fork and exec only raw
  syscalls (the relay is multi-threaded); argv/envp are built at startup.
  `PR_SET_PDEATHSIG` is tied to the launcher THREAD, which therefore never
  returns while a child lives. `x11 display: :N` is logged BEFORE the
  `wayland socket:` ready line (lib/index.ts reads both from the same
  chunk window); `<socket>.x11` is unlinked at every startup so a
  SIGKILLed predecessor's note never names a display that isn't ours.
  A link drop disconnects satellite like any app (it exits, X apps with it);
  the launcher then waits for the next X client.

## Protocol & STREAM framing

- **The FD rule**: a global is advertised only if the relay explicitly handles
  its fd-carrying messages — unknown messages pass through opaquely and a
  missed fd desyncs the SCM_RIGHTS queue (why dmabuf isn't advertised). That
  covers `type="fd"` args at every version bumped through, not just the target.
- The checked-in XMLs are verbatim upstream copies and run ahead of what we
  advertise (wayland.xml has wl_seat 11 and wl_compositor 7, xdg-shell has
  xdg_wm_base 7, cursor-shape and text-input-v3 are v2): a bump may need no
  regen. `protocol_gen.zig` carries message signatures only — no enums and no
  `since` — so nothing is derived from the XML's enum entries: validation
  ranges are hand-written in `compositor.zig` and must match the ADVERTISED
  version (cursor-shape is advertised at v1 → shapes 1..34, though the XML
  lists 35 and 36). Raising an advertised version means revisiting them.
- Refreshing the XMLs: wayland.xml from `wayland` main (`protocol/`), the rest
  from `wayland-protocols` main (`stable/`, `staging/`, `unstable/`); then
  `tools/gen_protocol.py`, `zig build test`. Open bumps are listed in
  `.agents/plan.md` STATUS.
- Clients gate behaviour on the bound version, so an advertised version needs
  all its features emitted (e.g. seat v5+ axis_source, v8 value120).
- **WIRE frames contain whole messages only** (receivers keep no reassembly
  state). A link message packs multiple self-delimiting frames; their order is
  significant.
- **Server-allocated ids (≥ 0xff000000) are one contiguous space, counting up**,
  shared by wl_data_offer (clipboard + dnd) and zwp_primary_selection_offer_v1.
  libwayland uses `id − 0xff000000` as a dense array index ("not a valid new
  object id"), so the type can't be encoded in the id (a partition was built
  and failed). The engine sends a SRVOBJ frame (0x06) per primary offer, in the
  same burst before the `data_offer` event; the relay intercepts
  primary_offer.receive (opcode 0) on flagged ids, data_offer.receive (opcode 1)
  on the rest. A third server-allocated type needs a SRVOBJ kind too —
  unless it has no fd-carrying request: the dmabuf `create` wl_buffer (a
  third type, same counter) only needs the relay to know its id, which
  DMABUF_CREATED carries.
- **Every pipe token is answered**: a `receive` the core can't route (the
  offer's source was destroyed — `orphanOffers` zeroes it, since the client may
  reuse the id — or its conn is gone) goes back as an FDMSG pipe with no wire
  message, and the relay closes the parked fd so the receiver reads EOF.
  The embedder's own selection (setSelection; `Selection.conn == 0`,
  `source` = its generation) answers with its bytes instead — as FDMSG
  own_pipe, each payload's bytes only the first time on the link (the
  relay keeps them, `Relay.own_cache`, until a newer generation's arrive,
  the core's gen-0 drop, or detach). **Own selections and pipe_read exist
  only on a link whose relay sent FEATURE selection_cache**
  (`Compositor.selection_bridge`; wasm `wland_selection_bridged`, JS
  `Engine.selectionBridged()`): wlandr 0.1.0 rejects pipe_read ("unsupported
  fdmsg kind 5": the read never answers) and the pipe-with-bytes form
  ("bad aux len": the receiver's pipe stays parked and its paste blocks
  in read). So without the FEATURE setOwnSelection is error.Unsupported
  and readSelection false — never "offer it and hope". A missing FEATURE
  is only known at the link's first non-FEATURE frame (wasm.zig
  `features_settled`; the engine caches the answer after each run of
  frames, so `selectionBridged()` never calls into the core — the clipboard
  bridge asks it while a commit's pixels are being read). The relay writes them on ONE writer
  thread (`pipe_writer.zig`: poll + non-blocking writes, 5 s, EPIPE ends
  it — SIGPIPE is ignored by Io.Threaded) with 4 transfers per conn and 32
  in all; past a cap the fd closes at once (EOF). A detached thread per
  receive, each with its own copy, let one client pin 64 threads × the
  selection and every receive re-crossed the link. Only the writer thread
  closes its fds (number reuse under its poll); conn close and link
  detach mark transfers cancelled, and dropConn leaves a tombstone (a
  ring of recent conn ids) so a receive the link thread found live just
  before its conn closed is still closed at once. A stale own offer (an
  older generation) reads EOF like an orphaned one.
- **A receive's fd must be a pipe** (`interceptPipeReceive`, checked with
  F_GETPIPE_SZ — it never calls into a filesystem, fstat on FUSE can).
  O_NONBLOCK doesn't make every write()/close() return: a FUSE file whose
  server never answers blocks both (close sends FLUSH), so does a hung
  NFS file or a draining tty. Parked fds are closed on the link thread
  (even under relay.mutex at detach) or written by the writer, so a
  non-pipe parked there froze every app; refused on the receiver's own
  app thread instead, it can only stall that conn. The writer also never
  holds its mutex across a write or close (it copies fd/blob/offset out;
  only it removes transfers, so indices stay put) and writes with
  RWF_NOWAIT, since O_NONBLOCK is on the description the receiver shares
  and can clear. Its start() refuses non-pipes too (a backstop). Still
  open: an app thread stuck in such a syscall (a stray FUSE fd closed at
  conn teardown, a FUSE-backed shm pool faulting) keeps its `link.users`
  reference, so that link's serveLink never returns — a stream link then
  never reconnects.
- **The engine reads a selection through FDMSG pipe_read (kind 5)**, not
  through an offer: the relay makes the pipe, hands the source app the
  write end with the core's `send` event, and its reader thread holds a
  `link.users` reference until it answers (polling in 100 ms slices so a
  detach never waits the 5 s deadline out). No answer is owed to a link that
  detached; the engine resolves its pending reads null at close. EOF is
  `ok` whatever became of the source's conn: it is every receiver's only
  completion signal, and `wl-copy --paste-once` hands the write to a
  child and exits before it (a "source gone at EOF → failed" rule lost
  every such paste; a source killed mid-write is a truncation any
  receiver would see too).
  Dropping the token instead leaves the reader blocked until the link detaches
  (xwayland-satellite blocks its whole X display on that read).
- **Frame callbacks fire on exactly one side, chosen per link:** WS = relay
  intercepts `wl_surface.frame` (never forwarded); stream = engine
  (`compositor.tick`). A new link type picks one; both firing gives apps a
  fatal double `done` (it is a destructor event). Engine side, frame is pending state latched
  by commit, fired at the NEXT tick; a destroyed surface's callbacks get
  `delete_id` only.
- **Presentation time is stamped by the relay, decided by the core.**
  `wp_presentation.clock_id` must be a clock the CLIENT reads with
  clock_gettime; the core runs on the page's `performance.now()` — another
  clock, maybe another machine. Mapping it with an estimated offset (an
  NTP-ish exchange) would be neither simple nor exact; instead the core
  keeps the protocol (latch, supersede, discard, sync_output order) and
  sends `presented` as a PRESENTED frame (0x0e) with `age_us` = how long
  ago the frame began, a duration measured on the page's clock alone; the
  relay writes its CLOCK_MONOTONIC minus the age into the event as it
  passes (`stream.stampPresented`). The error is the link's one-way
  latency, always late. A relay that forwarded PRESENTED's bytes as WIRE
  would hand apps page-clock times: every relay (wlandr, the JS relays in
  test/support and web/) must stamp. The JS test relay stamps with
  `process.hrtime` (CLOCK_MONOTONIC on Linux), or `performance.now()` in
  a browser, where its synthetic clients compare with the same.
- **STREAM length checks sum in u64** (`stream.zig` `have()`): `9 + u32_len`
  wraps a 32-bit usize on wasm32.
- **In handle mode one `loop.roundtrip` does not order releases** (ACK and the
  sync's `done` share a link message; release is written later by the app
  thread). Assert after `loop.settle` or `until`.

## Compositor (`core/`)

- **Input is role-gated**: keyboard focus only to toplevels, pointer never to
  cursor or dnd-icon surfaces, cursor canvases never shown in place (foot
  SIGSEGVs if its cursor surface gets focus). **And focus-gated**: motion/button/axis dropped
  unless a surface holds pointer focus — `wheel` can fire with no preceding
  pointerenter, and foot SIGSEGVs on axis-after-leave.
- **Seat events go to every object of the client, never to "its" one**
  (`Conn.pointers/keyboards/data_devices/primary_devices/
  relative_pointers`, a `SeatObjects` each). Firefox binds wl_seat twice —
  GTK's at v5, then its own at v8 — and GTK's wl_pointer/wl_keyboard are
  the ones its input handling listens on: one id per conn, overwritten by
  the latest get_pointer, left Firefox deaf to all input. Each event goes
  to every object with ONE serial (set_cursor/set_shape from any pointer
  name the same enter serial); version gates are per object (the
  binding's version: a v5 pointer gets axis_discrete, a v8 one
  axis_value120 in the same scroll). Each data/primary device gets an
  offer of its own (new server ids, dense; a SRVOBJ per primary offer),
  drag enters too (one serial, wlroots-style; accept on any of them).
  Focus is the conn's whether or not it has objects: an object made while
  focused gets the enter it missed (the focus's serial, weston-style), a
  data device the selection. Over `max_seat_objects` (8) per kind an
  object is ignored — it exists, gets nothing. Releases leave the set. Not
  fanned out: zwp_text_input_v3 (one per conn, a second replaces it);
  touch has no capability, so nothing to track.
- **Roles arrive late and go away**: GTK commits its cursor buffer BEFORE
  `set_cursor`, and reuses popover wl_surfaces (dismiss destroys only the
  xdg_popup/xdg_surface). Role changes flow to JS (`js_surface_event`) so the
  view re-gates; role-object destruction unmaps, a new role re-maps.
  `wl_subsurface.destroy` counts too: Chromium's omnibox dropdown is a
  subsurface whose wl_surface it keeps (attach(NULL) + commit, then the
  destroy). attach(NULL) + commit on a mapped toplevel, popup or subsurface
  is told the same way — a 'surface' event with role none, the core keeping
  the role (no commit event carries a NULL buffer); the next commit with
  content names the role again. A toplevel unmapped that way starts over
  (states gone, initial configure at its next commit). A destroyed parent
  unmaps its subsurfaces for good.
- **`activated` is keyboard focus** (`toplevelStates`, in every toplevel
  configure): keyboardEnter/Leave send a configure repeating the size.
  Chromium reads "is this window active" from it, not from wl_keyboard. The
  repeated size is the window's geometry unless a floating size we sent is
  still on its way (`size_serial`: cleared by the commit after its ack) —
  then it is the size sent, so a focus change mid-resize or right after
  unmaximize doesn't snap the window back.
- **The on-screen keyboard needs a focus made inside a user gesture**: an
  app that enables text input in answer to a tap (Chromium) does so after
  the press, so `input.ts` refocuses the sink again at the tap's release
  (`keyboardOwed`). Not checked on a real phone.
- **Focus dies SILENTLY with its surface** — keyboard, pointer, text-input and
  drag focus alike. A leave for a destroyed surface is a client-killing
  protocol error (wl-copy's hidden surface dies, the clipboard
  silently empties).
- **Every wasm export that can make the compositor send events calls
  `flushOut()` before returning**, or those events stall until the next tick.
- **Client-sized strings meet fixed encode buffers.** `wire.encode` refuses
  a message over its buffer (ReleaseFast — the wasm — checks no slice
  bounds: a 1500-byte mime once overran sendEvent's 1024 B into linear
  memory); `encodeMessage` is for fixed args and panics instead. The
  backstop is not the cap: strings echoed in events are capped where they
  enter — mime types at `max_mime_len` (256; a longer source `offer` is
  ignored, a `receive` or dnd `accept` naming one reads EOF / revokes),
  composition text by `clampUtf8` (800 B).
- **Client coordinates saturate.** Positions, window geometry, positioner
  rects/offsets/sizes are any i32: the placement chain (`Positioner.place`,
  `surfaceAbs`, `windowGeometry`) sums with `+|`/`-|` (INT32_MAX geometry
  + a −10 popup overflowed: a Debug panic, UB in wasm).
- **Selection requests need focus or a fresh serial** (`maySetSelection`):
  set_selection (clipboard and primary, clears too) is honoured from the
  keyboard-focused client, or one naming one of its last 8 input serials
  (key, button, keyboard/pointer enter) while no other client had a key,
  button or keyboard focus since (`last_input_conn`) — a slow client's
  Ctrl+C after a focus change. Else ignored: a background client could
  replace the clipboard at will, and the page bridge mirrors it to the
  host. wl-copy (no data-control protocol here) maps a 1×1 toplevel and
  sets the selection at its keyboard enter — the headless embedder and
  the wm focus new toplevels; the `copy` fixture does the same.
  start_drag needs a held press of the client's (`pressHeld`).
- `xdg_surface.get_popup`'s parent is nullable — id 0 must not match a surface.
- **Mesa's Wayland EGL/Vulkan find their GPU through linux-dmabuf v4
  feedback** (`main_device` → drmGetDeviceFromDevId); Mesa 26 has no wl_drm
  client code. A device it can't open (no /dev/dri, or a non-DRM dev_t)
  makes it fall back to swrast over wl_shm — harmless, which is how a
  container without a GPU still runs EGL apps with dmabuf advertised.
  The reverse is not harmless: dmabuf advertised in front of a virtgpu
  relay to a page with no GPU source = Mesa renders on the GPU and every
  window is blank. So `Compositor.applyFeature` leaves linux-dmabuf off
  when FEATURE dmabuf_kind names a kind it can't show (virtgpu without
  `gpu_source`, set by `wland_set_gpu_source`, which outlives wland_init;
  default true for embedders that never say). Without the global Mesa
  falls back to wl_shm. FEATUREs go through `applyFeature` in wasm.zig and
  the native harness alike.
- Things GTK/foot require: wl_data_device_manager v3 (foot exits below it); dnd
  v3 action negotiation (`set_actions`/`source_actions`/`action`) — accept alone
  never completes a GTK drop; configure_bounds + wm_capabilities ride the
  initial configure, before the first `xdg_surface.configure`.
- text-input-v3: an enter resets all state (client re-sends enable + commit);
  enable/disable/cursor rect are pending until `commit`; `done` echoes the
  commit count, not `conn.serial`.
- Protocol errors are raised only where the spec demands (invalid cursor shape,
  viewport errors); stale serials are ignored, not errors.
- attach dx/dy and `wl_surface.offset` are pending state latched by commit
  (a 0,0 attach doesn't undo an offset), not applied to placement; only the
  current cursor surface uses them: its hotspot moves against them.
- **The pointer image is per enter**: `set_cursor` and `set_shape` apply
  only with the latest enter's serial and while the client holds the
  pointer (stale = ignored); the last one wins; `conn.cursor_surface` is
  cleared on enter and leave (leave also resets to the default). The core
  tells the embedder the cursor surface + hotspot only while that surface
  has content (`on_output`): no buffer yet, attach(NULL) or destroyed reads
  as hidden (surface 0), and a later buffer re-sends it. New pixels are just
  the surface's commits (frame callbacks fire as for any surface). The role
  is set even by a stale set_cursor.
- **The embedder picks, so the embedder applies input regions.** The core
  keeps `wl_region`s per conn and copies one into the surface's pending
  state at `set_input_region` (the client may change or destroy it right
  after); commit latches it and, if it changed, `input_region_fn` →
  `js_input_region` → an `input-region` event. It is NOT part of the commit
  event: a region can change on a commit with no buffer, and arrives before
  a surface's first commit. The core never checks pointer coordinates
  against it (pointerEnter trusts the embedder's pick).
- **A window's box is its window geometry**, not its toplevel surface
  (`windowGeometry`): what `set_window_geometry` named (GTK: the frame inside
  its shadow; foot: grid + titlebar, borders outside), else the bounds of the
  toplevel and its subsurfaces with content (xwayland-satellite sets none and
  hangs a titlebar subsurface at y = −25). `xdg_toplevel.configure` sizes,
  `requestResize` and the unmaximize restore size (`last_w/h`, taken at
  `set_maximized`) are the box's. The core learns surface sizes only from
  the embedder (`noteBufferSize`, every presented buffer), so the geometry
  is read after it, per commit event.
- **A popup's x/y is its configure's: from the parent's window geometry to
  its own** (xdg-shell; the anchor rect counts from the parent's geometry
  too). Where that puts the surface is `surfaceAbs`'s: + parent geometry
  offset − own (`popupGeomOffset`), so the commit's `x`/`y`, the view's
  canvas and hit-testing all follow. GTK3/4 CSD windows AND menus hang
  shadows outside their geometry: placing from surface origins put
  l3afpad's menus ~20 px up-left. Only a SET geometry counts there: a
  default one (bounds with subsurfaces) is the surface origin, for
  xwayland-satellite (plan.md, the satellite entry). No constraint
  adjustment (flip/slide/resize): window positions are the embedder's.
- **Interactive move/resize needs a press still held on the window**
  (`inImplicitGrab`): its serial must be one of the current implicit
  grab's presses (first…latest, buttons tracked per conn in
  `pointerButton`), the first of them on the toplevel or a subsurface of
  it; a release of the last button, an enter or a leave ends the grab. A
  slow client's request that arrives after a quick click's release is
  IGNORED: honouring it started an embedder grab that followed a pointer
  with no button down until the next click (foot's border). The wm gates
  it again on the DOM's own button state (engine behind a link or worker).
- **Window states are the core's; the embedder only reacts and asks.**
  maximized, fullscreen, minimized are `Surface` flags (reset when the
  xdg_toplevel goes) changed by the app's requests or the embedder's
  `setMaximized/setFullscreen/setMinimized`, one path each
  (`applyMaximized/…`), every change told as an interactive kind (2/3,
  6/7, 8/9 → 'maximize'/'fullscreen'/'minimize') and carried on every
  commit (`wland_toplevel_state` of the root). maximized and fullscreen
  coexist (both in the states array, mutter-style): fullscreen wins the
  size, unset_fullscreen lands on maximized if still set. The floating
  size (`last_w/h`) is read only while the window floats
  (`refreshFloatingSize`): right after leaving fullscreen/maximized the
  geometry is still the big one, so `sendCurrentConfigure` never re-reads
  it. A state request before the initial commit only sets the flag: the
  initial configure carries it — a configure before it would precede
  wm_capabilities (set_maximized used to send one). Minimizing sends the
  leaves itself (pointer: constraint first, via pointerLeave; keyboard)
  and popup_done to the window's popups, and from then on drops enters
  aimed at its tree; focus handoff stays the embedder's.
- **Pointer constraints: the core is the state machine, the embedder only
  reports the browser** (`Constraint` in compositor.zig). A constraint
  applies while its surface holds pointer focus and starts only with the
  pointer inside region ∩ input region ∩ the surface's bounds — which is
  why the core keeps the pointer position (`Conn.pointer_x/y`, from enter
  and motion; the implicit grab sends motion outside the surface). A
  confinement goes active at once (`confined`) and clamps the motion the
  client sees; a lock goes `wanted` and the core tells the embedder
  (`pointer_lock_fn` → 'pointer-lock' event, desire changes only); `locked`
  goes out on `pointerLockGranted` alone — the browser grants Pointer Lock
  asynchronously or not at all, so an optimistic `locked` would lie.
  `pointerLockLost` (Esc, blur) → `unlocked`; a persistent lock is wanted
  again at once with no new event (the embedder keeps its want and retries
  at the next press). Deactivation precedes the leave; a defunct
  (oneshot-ended, or surface-destroyed) constraint stays an inert object
  and does not count for `already_constrained`. While locked the core
  ignores the motion's x,y (frozen) and sends no `wl_pointer.motion`, only
  `relative_motion` + frame; a lock-time motion with no movement sends
  nothing (no empty frame).
- **Presentation feedback: "presented" = the first tick after the commit**
  (`Feedback`, `tick`): the view draws a commit as it arrives, so the next
  rAF frame composites the last one drawn — an earlier commit of the same
  surface since the last tick was drawn over unseen, hence discarded at
  the later commit, not at the tick. The tick presents only surfaces on
  screen (`surfaceShown`: content plus a shown role, a subsurface only
  under a shown parent, a cursor surface only while it is the pointer
  image); the rest are discarded. Every feedback ends exactly once with
  presented or discarded + delete_id (surface destroy included; conn
  close sends nothing). sync_output goes to `output_ids`, i.e. wl_output
  objects bound at v2+ (the ones tracked for live mode).
- **`wl_surface.enter`/`leave` follow content, not roles**: the core sees
  `attach` on the wire (only null vs not) and a surface is on the one output
  from the commit that latches a buffer until attach(NULL) + commit or its
  xdg role object's destruction; one event per wl_output the client bound
  (v2+; a late bind gets the enters it missed). No leave for a destroyed
  surface. Clients hang per-output state on it — xwayland-satellite ignores a
  surface's fractional `preferred_scale` for its global scale until the
  surface has entered.

## Engine / client (`lib/`)

- **Every `extern "env"` in the wasm must exist in engine.ts's imports**, or
  instantiation dies with a LinkError (whole client, every test). Same commit.
- **wasm `u32` import args arrive in JS as signed `i32`.** Compare sentinels and
  conn ids with `>>> 0` (`0xffffffff` arrived as −1: the destroy path was dead
  code since day one).
- **Events raised inside a wasm call are queued and dispatched after it
  returns**, so handlers don't re-enter the core.
- **The engine/view boundary is message-passable**: events are plain data and
  nothing returns values (the engine may live in a worker). Geometry the view
  needs is snapshotted into each `commit`.
- **The window element / HeadlessWindow is the geometry's box**; the
  toplevel surface's origin is inside it at minus the geometry's position
  (view: an origin child element holding the canvases; headless:
  `originX/originY`). Commit `x`/`y` and surface-local offsets count from
  the surface origin, window positions and sizes from the box — a test that
  clicks at "window + offset into the buffer" wants the origin. Any commit
  in a window can move the origin (a subsurface mapping above the toplevel):
  the box stays where it was placed, the content shifts.
- **Another surface's commit moves subsurfaces and popups**: a popup's
  root-local position includes its parent's window-geometry offset (a CSD
  window maximizing drops its 24 px shadow under an open menu), a
  subsurface's its parent popup's position. The engine keeps every
  subsurface/popup's last x/y/z (`placed`) and re-reads them after a link
  message that may have moved one: a change is a 'position' event (view
  and headless move or restack it). "May have" is the core's
  `positions_dirty` (`wland_take_positions_dirty`, read-and-clear), raised
  wherever an offset, a window-geometry offset, a stack, a role or a
  parent changes or a placed surface goes — a new site that moves one
  must raise it, or its 'position' never comes (the core test "positions
  dirty" lists them). Re-reading on every message was O(placed) wasm
  calls per message (345 µs at 200 subsurfaces), and gating on commits
  is wrong: set_position and a popup's reposition apply with no commit
  of their own. Stacking inside a window is `stackOrder` (engine.ts) over
  CommitEvent.parent (`wland_surface_parent`) and CommitEvent.z
  (`wland_surface_z`): a surface's subsurfaces with z < 0 under it (each
  with its own subtree), then it, then z > 0, then its popups (by seq) —
  the view as canvas z-indexes (hit elements copy them; the toplevel's
  canvas gets one only when something is placed under it), headless as
  `layers()`.
- **Subsurface z-order is the parent's double-buffered state.** The core
  keeps an ordering key per subsurface (`Surface.z`, parent = 0, gaps
  allowed) and a pending one: place_above/below shift the pending keys on
  the side the surface lands, the PARENT's commit latches them
  (`stack_pending` on the parent, `latchStack`) — a child's own commit
  doesn't, so a 'position' with the new z follows the parent's commit.
  A new subsurface goes on top of both stacks at get_subsurface. The
  export is a dense rank (±1, ±2, … from the parent), so an unrelated
  key shift never reads as a restack; it is cached (`Surface.z_rank`),
  recomputed for the conn in one sort after `restacked` marks it stale. set_position is still applied at
  once, not at the parent's commit (the scripted tests position a
  subsurface and paint it with no parent commit).
- **The relay thinks every COMMIT was shown.** One the engine ACKs
  without showing anything new (a GPU commit with no image, a failed or
  refused read, a broken handle, an invalid notice) leaves consumers'
  content stale while the relay's next damage is relative to it: the
  engine marks the surface (`stale` in engine.ts) and presents its next
  COMMIT whole — damage replaced before the source/resolver is asked, so
  reads, resolver and the commit event all see one full rect. Copy-mode
  BUFFER frames can't be widened (their pixels are packed per rect); they
  are always shown anyway. First commit and resize need nothing: the
  relay sends a full rect for those.
- **A GPU commit's `image` lives for its dispatch**: the engine resolves
  (`EngineOptions.gpu`), dispatches the 'gpu' commit, calls release(image),
  then ACKs — the emitter then releases the wl_buffer and the guest may
  render into the resource again, so a consumer that kept the image (or
  drew it later) would show a frame the client is overwriting. The view's
  2D path clears before drawImage (drawImage blends; putImageData didn't);
  its GL path defines the texture from the image (texImage2D: the image's
  own size), so the next pixel commit re-creates the texture (`texImage`).
  The wasm commit notice is 14 words (kind-specific words 5–13): wasm.zig
  and engine.ts `NOTICE_WORDS` change together.
- **A commit's `pixels` is valid only during dispatch, and dies at the first
  engine call** when it views wasm memory (BUFFER_LZ, `rgba` source commits):
  the call may grow memory and detach it (`memory.grow` never moves data, but
  re-read `memory.buffer` after any call). The view presents BEFORE focusing a
  new window; a new consumer reads pixels before calling the engine.
- **A HandleSource read can't write into wasm memory it was handed earlier**:
  a pending async read can outlive a `memory.grow`. Hence the engine stages
  reads in a JS buffer.
- **HandleSource shapes, per COMMIT: view → readv → read.** `view()` is
  synchronous; ONE view goes out as the commit's `pixels` uncopied (so
  `pixels` may be a SharedArrayBuffer), several are gathered (damaged spans
  only) into the staging buffer; null falls back. `readv()` gets the
  merged spans in one call (one promise; the pending-read/close-wait
  machinery is shared, `pendingRead`). A shared `pixels` is fine for the
  view's presenters: 2D swizzles bgra/bgrx into its own buffer (ImageData
  refuses shared views in every browser; 'rgba' never comes from a view:
  the core swizzles out of it into wasm memory), GL's texSubImage2D takes
  the shared view as is; `slice()` (a Worker adapter's copy) is ordinary
  memory. Browser-checked by handle-demo `sab=1` (SharedArrayBuffer pools)
  through `test/support/isolated.ts`, a COOP/COEP mirror (wlandr sends
  neither header, so its pages can't make one): Chromium 2D + software
  WebGL (run-poc handle-demo), Firefox 2D (firefox-smoke; headless Gecko
  has no WebGL). present.ts's retry-with-a-copy on a TypeError is
  defensive: no tested browser has thrown there.
- **A link reset during a pending buffer-source or gpu promise**: the
  promise's commit belongs to the dead link (`gen` check: never presented,
  never ACKed on the next one), its read keeps writing into the staging
  buffer it was given (so halt() hands the next link a fresh one), its
  settle removes only its own record from `reading` (a Set: the next link's
  read may be pending too, and its token must not be closed under it), and
  a gpu image resolved late is still released.
- **watchOutput ignores a container with no size** (display: none, not
  attached): the core clamps a 0 desk to 1×1 and would configure every
  maximized/fullscreen window to it. `setSize`/`setScale` pin (the
  ResizeObserver / the resolution query then do nothing; null resumes and
  re-sends what the page says now); embedders must not call
  engine.setOutput/setScale beside it. Invalid sizes (rounding below 1 px,
  NaN, Infinity) and scales throw before anything changes; a stopped watch
  (createWland disposed) ignores both. createWland checks `scale` before
  creating anything and tears down whatever exists if construction throws.
- **The evdev key table lives twice** (`input.ts` and `headless.ts`
  `EVDEV`): the keypad and the rest of a full keyboard are in both, all
  keys the canned keymap (`core/src/us.xkb`, xkb = evdev + 8) has.
- **Keypad digits need NumLock in `locked`** (Mod2, 1 << 4: us.xkb's
  `modifier_map Mod2 { <NMLK> }`; KEYPAD type: digits only with NumLock and
  no Shift). The core's lock state is seat-wide (`Compositor.mods_locked`),
  NumLock on from the start, toggled by keys 58/69, set by
  `wland_keyboard_locks` (engine.keyboardLocks). Across a link reopen the
  engine carries the CORE's state (read with `wland_keyboard_locks_state`
  as the link closes — the keys' toggles included; a keyboardLocks while
  closed overrides it), not the embedder's last call: the toggles happen
  in the core only (and only for a conn with a keyboard), so JS can't
  mirror them.
  input.ts syncs it from `getModifierState` before every key and before a
  keyboard enter, except on the lock keys' own events (the core toggles;
  browsers differ on pre/post state there, and macOS Caps Lock sends only
  keydown when it goes on, keyup when off). macOS has no NumLock
  (getModifierState false, keypad types digits): a false NumLock is never
  believed except from a keypad key whose `key` shows navigation.
- **In-memory links deliver asynchronously**: the engine sends from inside a
  core call (`js_send` during `flushOut`); a synchronous answer re-enters the
  core (the demo page's `web/src/wayland/links.ts` uses microtasks).
- **A link close ends every app conn in the engine**: onClose feeds the core
  a synthetic CONN_CLOSE per conn (consumers drop per-conn state on
  `disconnect`) before `close`; a reopened link gets a fresh compositor. Without
  it only a page reload recovers — impossible in unkernel.
- **`chunk.slice(...).buffer` of a chunk you didn't make** is the whole shared
  pool on a Node Buffer — onMessage gets a copy (`new Uint8Array(subarray)`).
- **The page clipboard bridge (`lib/clipboard.ts`) lives on input's
  hooks**: a paste chord's keydown must NOT be prevented (no paste event
  otherwise), and from its press every key event queues until the paste
  event ran (`InputOptions.clipboard`) — the app must see the new selection
  before the V. Chromium fires paste inside the keydown's task; Firefox
  later (its parent process runs the shortcut), usually after the keyup,
  and targets the body (an empty contenteditable holds no caret), so the
  copy/paste listeners are on the document, gated on the sink having
  focus. No paste in 300 ms (refused): the keys go anyway. Writes to the
  page clipboard need a gesture: writeText right after a key or click in
  the desktop (5 s), else at the next one (Safari wants the call inside the
  handler) or the next copy event (`setData`). `document.hasFocus()` is
  false throughout in headless Firefox: don't gate on it — "inside" is
  tracked from focusin, the window's focus/blur and visibilitychange, and
  any key/button press in the desktop. Leaving for nothing focusable (a
  click on plain page text, an embedder's `blur()` — unkernel's
  setDesktopShown(false) on touch) fires no focusin and no window blur:
  a focusout whose focus did not land back in the desktop (checked in a
  microtask: input's sink blur-and-refocus is no leave) is a leave, and so
  is a press outside the container that is not on a surface (input's
  `outside` hook: a toolbar button that keeps the focus). Without it, in
  Safari an app's owed text overwrote what the user copied on the page
  meanwhile. Newer-side rules (clipboard.ts's
  table, one test per row in clipboard.test.ts): only a selection set
  while inside is owed to the page; one set while away, or owed when the
  user leaves, becomes `verify` — written at the next look at the page
  (paste event, granted read) only if the page still holds `pageKnown`,
  else the page's text wins. Writing at the next plain key instead
  clobbered what the user copied elsewhere and dropped their paste. An app
  clearing its selection reaches the bridge as its conn with no types (the
  core's `setSelection(_, 0)` names the client; the owner going — source
  destroyed, conn closed, link closed — is conn 0 with none): the page is
  cleared ('' written) only if it holds that app's text as the bridge
  wrote it; the owner going leaves the page alone (and an owed write
  still happens) — and a paste of that unchanged page text then makes it
  the selection again (`wlEmpty`: the Wayland side holds nothing; also
  after an app's clear over the bridge's own, and after every link
  reconnect, which empties the selection — unkernel), never over an app's
  newer non-text selection. A paste event with no text but other types
  (an image copied elsewhere: `clipboardData.types`) is a changed page
  clipboard: `pageKnown` = null, nothing written over it. With
  clipboard-read already granted, coming back into the desktop is a look
  too and writes an away copy if the page is unchanged (README says so):
  the read proves nothing the user copied is lost, so it is kept rather
  than waiting for a paste. Copy chords in the desktop are prevented unless
  the bridge owes text (`wantsCopy`), and every copy/cut event while the
  sink has the focus is cancelled: Firefox keeps a page text selection
  across the (preventDefault'ed) press into the desktop, and a Ctrl+C
  there (a terminal's interrupt) copied it over the user's clipboard. A
  cancelled copy event with nothing set leaves the clipboard as it was
  (Chromium: run-poc `clipboard` phase; Gecko: firefox-smoke step 4).
  Everything keyboard-side queues behind a paste chord in order: keys,
  repeats, releases, lock-state syncs, IME text.
- **Keys the app has down are input.ts's `pressed`**: a release goes out
  only for a pressed key, and all of them are released (to the conn they
  went to) before a keyboard leave of that conn, on the window's blur (DOM
  focus stays on the sink, but Alt+Tab's Alt release goes to another
  window) and, on Apple, at the last Cmd's keyup for keys pressed under
  Cmd (`cmdKeys`; macOS browsers fire no keyup for a key released while
  Cmd is held). The core's `mods_depressed` is per conn and survives a
  leave: a lost release left Ctrl/Super depressed in the app's next
  enter. Apple's clipboard chords Cmd+C/X/V (Ctrl+V fires no paste there)
  reach the app as a whole Ctrl chord at the press — Super up (if the app
  has it), Ctrl down, key down, key up, Ctrl up, Super down while Cmd is
  held (`metaHeld`) — never waiting for the key's release (none may come).
  Written from the browsers' documented behaviour; never run on a Mac.
- **An engine embedder focuses new toplevels**: wl-copy waits for keyboard
  focus before setting the selection (the input module does; a headless embedder
  calls `keyboardEnter` itself) or wl-copy hangs.
- **Focus policy is the embedder's, and it hands focus on**: when the focused
  toplevel closes, unmaps or its app hangs up, `input.ts` / `headless.ts`
  focus the topmost window left (the view's z-index; the scene's `z`). A
  toplevel that only lost its role (xdg_toplevel destroyed, wl_surface
  alive — how apps close: role objects first) gets a `keyboardLeave` first;
  a destroyed surface or conn never does. The core keeps no focus policy.
  Minimized windows are skipped (`ViewWindow.minimized`, the scene's
  `shown`), and `input.focus` refuses one: the core would drop its enter
  and input.ts would think it focused.
- **A fullscreen window is the view's layout, its position the wm's.** The
  view makes the element `100%` × `100%`, black, `overflow: hidden`, and
  centres the geometry with `calc(50% - …px)` on the origin element (no
  layout read per commit); `data-wland-fullscreen` lets page CSS drop its
  window dressing (the demo's drop-shadow filter would otherwise ring the
  desktop). The wm snaps maximized/fullscreen windows to 0,0 and restores
  the floating position when neither is left (one `restore` entry for
  both), raises and focuses a window going fullscreen (not before it is
  mapped: input.focus on an unmapped toplevel would send an enter), and
  owns the browser's Fullscreen API (browserFullscreen): `ours` is set only
  by a fullscreenchange to the container that answers a request of its own
  (`requested`), so a page's own fullscreen of the container is never
  ended by it, nor does its exit end the windows'.
- **An unanswered `drag-start` wedges the seat**: while `Compositor.drag` is
  set the core drops every pointer enter/motion/button/axis and ignores further
  `start_drag`; only dragDrop/dragCancel (or the source dying) end it. An
  embedder that can't drive the drag must `dragCancel()` (wland/headless does
  when no scripted button is held).
- **Node's `fetch` can't load `file:` URLs**: createEngine's default wasm
  (`new URL('wland.wasm', import.meta.url)`) is one in Node, so
  `instantiate()` reads `file:` URLs with node:fs, got through
  `process.getBuiltinModule` (an `import('node:fs/promises')` makes vite
  warn in every browser build). Keep that URL a literal in `createEngine`:
  bundlers detect it to emit the asset.
- **Keyboard focus lives on one hidden contenteditable IME sink**, not on
  canvases (they can't compose). One keydown listener: keys with
  `isComposing || keyCode === 229` go to composition, all others to evdev.
  `beforeinput` is not wired (it double-delivered). The sink's blur is
  a real keyboard leave only if focus didn't land on one of our canvases —
  resolved in a microtask after the redirect churn.
- Programmatic `focus()` scrolls the page unless given `{ preventScroll: true }`.
- **Input regions are hit elements, not canvases**: the DOM does the
  picking, and a surface with a region gets its canvas `pointer-events:
  none` plus a transparent sibling right after it with the canvas's box and
  stacking, `clip-path: path(...)` of the region (clip-path clips
  hit-testing, so outside it events fall through natively — to a window
  below, page UI, the cursor below). Clipping the canvas itself would hide
  the shadow. So an event target may be a canvas OR a hit element: compare
  surfaces via `view.surfaceOf(target)`, never `target === canvas` (the
  popup dismiss did). Surfaces without a region keep the canvas as target.
- **The window element is `pointer-events: none`**; canvases and hit
  elements set `auto` and inert canvases `none` explicitly (`applyRegion`;
  the property is inherited, so `''` would mean none). Otherwise the box,
  which covers the whole geometry, caught a press in a hole of a region
  INSIDE the geometry (a frame's middle, a round window's corners), and no
  surface resolved: dropped instead of reaching the window behind. A
  nautilus-style shadow lies outside the box, so that case never showed it.
  While fullscreen the element is `auto` again: its black backdrop stops
  presses to the windows below. Event paths still run through the box, so
  capture listeners on it (the default mount's raise) still fire, and a
  pointer capture on it (Alt+drag) still works.
- Microtasks run between listeners: to swallow a grab/drag's pointerup, the WM
  calls `stopPropagation`, not a deferred flag.
- **The implicit grab is pointer capture** (`input.ts` `captured`): the
  pointerdown's target (canvas or hit element) captures the pointer, so
  motion and the release go to the pressed surface even outside it (its
  local px, negative too) and no pointerout fires until the last button is
  up — then the browser sends the boundary events (lostpointercapture,
  pointerout, pointerover) that are the leave/enter. `suppress(true)`
  releases it: a wm grab/dnd must see the browser's own hover tracking, or
  the boundary events after the grab's pointerup would leave/enter again
  behind the wm's re-enter. A popup of the pressed client mapping releases
  it too (a popup grab: GTK's press-drag-release menus). A captured element
  removed from the DOM gets no lostpointercapture (the document does): the
  next press checks `isConnected`.
- **Touch needs `touch-action: none` on the container, set by the lib**
  (view.ts `CONTAINER_STYLE`, restored on dispose): without it the browser
  claims a touch drag as a pan and fires pointercancel, which ends wm
  grabs — touch drags worked only on web/, whose CSS had it. Same for
  user-select / the touch callout (long-press) and `isolation: isolate`
  (window z-indexes grow without bound). The IME sink says `user-select:
  text` itself: WebKit takes no typing in an editable under `none`.
- The IME sink keeps `inputmode="none"` (a focused contenteditable pops the
  on-screen keyboard on touch) and switches to `text` only while the focused
  conn's zwp_text_input_v3 is enabled; browsers re-read inputmode on focus,
  so a change refocuses the sink. A client without text-input gets hardware
  keys only — on touch devices no keyboard at all.
- **A wm grab or drag needs a button down, and ends with it**: `held`
  (pointerIds from pointerdown to pointerup/pointercancel) gates the
  'move'/'resize' events (ignored) and 'drag-start' (dragCancel: an
  unanswered drag wedges the seat); a grab ends at the pointerup, a
  pointercancel, a pointermove with `buttons === 0` (a release the page
  never saw: drag → dragCancel) or the window's blur — of ITS pointer
  only (`grab.pointer` / `dnd.pointer`: the last one pressed): a hovering
  pen or a mouse moving beside a touch drag used to end it. Not on
  lostpointercapture: suppress(true) releases input's capture of that very
  pointer as the grab starts. Alt+drag (pointer
  capture on the box) ends on pointerup, pointercancel,
  lostpointercapture or a buttonless move — it used to go on moving the
  window on hover after a lost capture.
- A move/resize grab starts at the WM's `lastPointer`, which `pointerdown`
  must update too: touch has no hover moves, so `pointermove` alone leaves it
  where the previous touch ended (the window jumps, then drags relatively).
- Cursor-shape reset clears the windows' `style.cursor = ''` (not
  `'default'`), so a grab's body cursor shows through.
- **A cursor surface is CSS, not an element**: `image-set(url("data:…png")
  Nx) hx hy` on the client's window elements (N = buffer px per logical px,
  the hotspot in logical = CSS px — Chromium scales it by N; `toDataURL`
  once per presented frame). Chromium skips a list entry whose image isn't
  decoded yet, so the previous frame stays in the list as the fallback
  (no arrow flicker between animated frames), and skips an image not
  wholly inside the visual viewport (page edges: the arrow). Over 128 CSS
  px a side browsers ignore it: then the cursor canvas itself goes into the
  container, fixed, `pointer-events: none`, moved by the view's
  document listeners (pointermove/pointerdown), with `cursor: none` on the windows. The
  'cursor' event can precede the surface's first commit (and with an async
  buffer source, its pixels): shown at the commit.
- **WebGL is used only on real hardware**: a GL context in a headless browser
  deadlocks headless compositing at retina sizes (software GL), and even a
  probe racing a reload hangs it. Real browsers probe once (sessionStorage)
  and need a non-software renderer name. WebKit masks it as "Apple GPU"
  everywhere (WebKitGTK on llvmpipe too): GL is picked there regardless
  (it works, software included); Firefox's sanitized names still match. Context loss → swap in a fresh 2D
  canvas (a GL canvas can't get a 2D context).
- **The 2D presenter accepts bgra/bgrx** (`swizzleRect`): in GL mode popups
  and subsurfaces are 2D, and after a GL context loss toplevels too.
- **Relative motion rides the pointer motion** (`pointerMotion(…, relative)`
  → one `wland_pointer_motion` with both parts, so the app gets motion +
  `relative_motion` in one frame). The engine's coalescing keeps the newest
  position but SUMS the relative parts — replacing them, like positions,
  would drop movement (a locked pointer has nothing else). µs timestamps
  cross as an f64.
- **Pointer Lock is requested on the surface's hit target**
  (`view.hitTarget`: the input region's hit element, else the canvas — a
  `pointer-events: none` canvas is the wrong element), at once only while
  `navigator.userActivation.isActive` (the press that made the app ask:
  the round trip to the app is ms, activation lasts seconds), else at the
  next pointerdown on that surface. `unadjustedMovement` first; Linux
  Chromium refuses it with NotSupportedError (and a pointerlockerror), and
  the same request without it still has the gesture's activation. Under
  the lock pointer events target the locked element, clientX/Y freeze and
  no boundary events fire (input.ts ignores pointerover/out while locked
  anyway); `releaseLock` clears `locked` before exitPointerLock so the
  pointerlockchange it causes isn't reported as a loss, and a grant that
  arrives after the core withdrew is exited on sight. The browser hides the
  pointer under a lock whatever CSS says: the view draws the locked conn's
  cursor surface as the element (frozen with clientX/Y).
- **`tick(time, refresh)` is what presentation feedback reports**: with
  `refresh` given, `time` must be a display frame's timestamp on
  `performance.now()`'s clock (rAF's) — the engine sends
  `performance.now() − time` as PRESENTED's age (ignored outside 0…1 s)
  and the core says vsync; createWland's frame loop measures `refresh`
  from rAF deltas (median of the last 15; 0 until 5). Without it (the
  headless timer, tests' fixed times) there is no age, no refresh, no
  vsync. While a buffer-source promise stalls the engine nothing is
  ticked: feedback, like frame callbacks, waits for the pixels.
- **Everything client-side is disposable** (`dispose()` on createWland, engine,
  view, input, wm; `close()` on links). Document listeners go through the
  file's `on()` helper; any new observer/timer/rAF needs teardown there.

## Demo page (`web/`)

- **`#desktop` belongs to the lib** (canvases, windows, the IME sink); React
  renders nothing into it. The view sets what the lib relies on itself
  (touch-action none, user-select none, isolation: isolate; restored on
  dispose): the page's CSS only sizes and dresses it. Its clientWidth/Height IS the wl_output size: the
  page sizes it in `index.css` (absolute, inset 0), since an unlayered rule
  there beats Tailwind classes on the element (a `relative` rule gave it 0
  height and the apps negative buffer sizes).
- `wl.windows()` entries carry no `conn`; zip them with `wl.view.windows()`
  (same order). Raising a window is `view.raise` + `input.focus`.
- `session.boot()` is idempotent (StrictMode mounts twice). Renderer/link
  changes restart in place: bump `generation` BEFORE `dispose()` — the old
  link reports its shutdown as an error, which must not count as a violation.
- The wire trace is a ring buffer rendered imperatively (rAF-batched), never
  React state: a pointer sweep is hundreds of messages.
- Toolkit apps: focus comes from `wl_keyboard.enter/leave`, NOT the
  `activated` state (the core puts it in every toplevel configure). A buffer
  copies its accumulated `missed` rects plus the frame's damage (buffer age);
  painting the whole canvas but copying only damage is what keeps that right.
- The toolkit queues events that arrive while it is writing (the JS relay
  answers some requests synchronously, e.g. a release): never interleave.
- vite dev/preview bind `localhost` = `::1` only: probe `localhost`, not `127.0.0.1`.

## Environment

- **Our socket is usually the default `wayland-0`** (first free `wayland-N`)
  — anything wayland-capable in the container finds it. Headless chromium connects as a client and deadlocks the
  E2E: launch it with `env -u WAYLAND_DISPLAY --ozone-platform=headless`.
- Server and apps must agree on `XDG_RUNTIME_DIR` (`/run/user/1000`; server
  falls back to `/tmp/wland-run`) or apps see "no compositor running".
- wlandr ignores `$WAYLAND_DISPLAY` (tools pass `--display`); apps still read
  it. At exit (return, SIGINT/TERM/HUP) it unlinks its socket and lock file;
  after SIGKILL or a crash they stay — harmless, the next claim replaces them.
- `verbose-cmd | grep -q` under `set -o pipefail`: grep exits early, the
  writer SIGPIPEs, the pipeline "fails" on a match (`wland-run` hit this).
- Chromium as a wland *client* needs `--no-sandbox --disable-gpu
  --disable-dev-shm-usage` (setuid sandbox bit missing; 64M /dev/shm kills it
  after ~30–60 s) and dumps a ~400M core on every compositor loss; `wland-run`
  handles all of it.
- Normal, nonfatal nautilus noise: "Unsupported or missing session type",
  Tracker3, Mutter ServiceChannel, GVFS UDisks2. GTK's "Failed to open display"
  means no socket/listener.
