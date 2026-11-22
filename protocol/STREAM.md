# wland STREAM framing (v2)

One link between the relay (wlandr) and the engine (the
core compositor; in the demo, the browser client). All integers are
**little-endian**. The link carries **messages** in both directions; each
message contains **one or more complete frames**, packed back to back — frames
are self-delimiting (every frame's length is computable from its own header;
BUFFER's pixel length derives from its rect dims), senders batch bursts into one
message, receivers loop until the message is drained. First byte of each frame
is the type; payload layout depends on type. Frames are packed unaligned: read
every field byte-wise (`core/src/stream.zig` is the reference codec, shared by
the relay and the wasm engine).

How a message is delimited depends on the transport:

- **WebSocket** (the browser, `/ws`): one binary WS message = one message. Text
  messages are ignored. Browsers fragment large messages; the relay reassembles
  continuation frames.
- **Byte stream** (`--link fd:N|unix:PATH|vsock:CID:PORT`): see
  [Stream transport](#stream-transport).

Batching conventions (senders MAY, receivers MUST cope either way):
- The server packs all frames produced by one app-socket read burst into one
  message; consecutive forwarded requests merge into a single WIRE frame.
- The engine packs all frames produced by one wasm entry (input event, rAF
  tick, incoming message, commit ack) the same way.
- Frame order within a message is significant and equals message order, and
  receivers process frames strictly in order. In particular a commit's pixel
  frame (BUFFER, BUFFER_LZ or COMMIT) is emitted AFTER that commit's own WIRE
  frame, never before it: the engine latches the commit's double-buffered state
  (wp_viewport destination → the surface-local/CSS size) when it processes the
  commit, and must have done so before it presents the buffer — otherwise the
  canvas backing store resizes but its CSS box keeps the stale pre-commit size
  (e.g. a maximize whose pixels land at 1600×917 but whose window stays 940×600).

The relay is transport dumb: it never interprets wayland semantics beyond the
fd/buffer interception listed in .agents/plan.md. The engine is the compositor.
Below, "server" means the relay and "browser" the engine, whatever the link.

## Buffer modes

How committed pixels reach the engine is the relay's **buffer backend**,
fixed when the relay starts (one per relay run):

| Backend | Pixels travel as | `wl_buffer.release` |
| --- | --- | --- |
| `copy` (the native server) | BUFFER / BUFFER_LZ: swizzled RGBA in the stream | at commit time, by the relay |
| `kwshm` (unkernel guest), `procfd` (debug/tests) | nothing: HANDLE_OPEN + COMMIT name shared memory the engine reads in place | when the engine ACKs the COMMIT |

linux-dmabuf buffers (`zwp_linux_buffer_params_v1`, only when the relay was
started with a dmabuf backend, see FEATURE) go through the relay's **dmabuf
backend**, also fixed at startup:

| Backend | A dmabuf commit travels as | `wl_buffer.release` |
| --- | --- | --- |
| `readback` (needs the `copy` buffer mode) | a LINEAR dmabuf mapped and shipped exactly like a wl_shm buffer — BUFFER/BUFFER_LZ; the engine cannot tell the two apart | at commit time, by the relay |
| `virtgpu` (any buffer mode; unkernel: with `kwshm`) | nothing: a COMMIT of buffer kind 2 names the virtio-gpu resource behind the dmabuf, which the embedder's renderer holds | when the engine ACKs the COMMIT |

Only an engine that can draw those resources offers linux-dmabuf in front
of a `virtgpu` relay: the relay says how its dmabuf commits travel (FEATURE
`dmabuf_kind`), and an engine with no GPU source leaves the global off, so
GPU clients render in software over wl_shm instead of into buffers nothing
would show.

COMMITs of both kinds may share one conn (a client with wl_shm and dmabuf
buffers, on any buffer mode — with `copy` the conn's shm commits are
BUFFER frames and its dmabuf ones COMMITs); they share its serial space
and its ACKs.

There is **no negotiation and no version frame**: relay and engine ship
together, and the engine learns the mode from the frames that arrive. (A
FEATURE frame announces something the relay can do — today linux-dmabuf,
and how its dmabuf commits travel — but nothing answers it: it is one-way,
like the buffer mode; what the engine does with it is its own business.) An
engine MUST accept every relay→engine frame type on any link and present
whichever pixel frames arrive (a relay MAY even mix them on one link). An
engine that has no buffer source (the embedder supplied none) and receives a
HANDLE_OPEN **fails loudly**: it reports an error to its embedder for that
handle, and ACKs every COMMIT naming it without presenting — the apps keep
running, nothing is shown, and the cause is visible.

Frame types are append-only. A receiver that meets an unknown type cannot
find the next frame (lengths are per type), so it drops the rest of that
message and logs; a sender must therefore only send types its peer knows —
which holds because both ends come from one package version.

## Stream transport

A byte stream has no message boundaries, so each message travels as a record:

```
u32 len              ← byte length of the message, 1 ≤ len ≤ 256 MiB
u8  message[len]     ← exactly what one WS message would carry
```

Frames are self-delimiting, so the prefix is not strictly needed to split
frames, but it is kept deliberately: a receiver can reassemble messages without
knowing any frame type (new frame types never touch the reassembler), a bad
length fails the link fast instead of desyncing it, and batch boundaries — the
unit the WS transport already has — survive, so both transports hand the same
messages to the same handlers. A record header outside the bounds is a fatal
link error. Records arrive split and coalesced arbitrarily by the stream; a
receiver buffers until it holds a whole record. Writers never interleave two
records, and honour the bound: a sender whose batch would exceed 256 MiB (a
burst of large incompressible copy-mode commits) splits it into several
messages at frame boundaries, in order. A single frame over the bound (a
copy-mode buffer of more than 64 Mpx, damaged whole and incompressible)
cannot cross a stream link: the relay drops that app's connection instead
of sending it.

Behavioural differences from the WS transport:

- **Frame callbacks** are fired by the engine (the relay forwards
  `wl_surface.frame` as WIRE; core's `compositor.tick` answers it when the
  engine presents). Over WS the relay intercepts them instead — see
  [Frame callbacks](#frame-callbacks).
- One stream link at a time, like WS; a `unix:` or `vsock:` link that
  closes is reconnected (apps that connect meanwhile wait), an `fd:` link
  that closes ends the relay. Either way the closed link's app connections
  are dropped (see Rules). With `wlandr --link-on-demand` a `unix:`/`vsock:`
  link is instead dialed only while an app waits for an engine — first at
  the first app, after a close at the next app — and a dial that fails
  closes the apps waiting for it rather than retrying. Nothing changes on
  the link itself: an engine sees the same connections, just later. The engine side treats every new connection as a
  new link: a fresh compositor, no apps (the reference engine ends the old
  link's conns itself when it closes, as if each had a CONN_CLOSE).

## Frame types

| Type | Name | Direction | Mode |
| --- | --- | --- | --- |
| 0x01 | WIRE | both | all |
| 0x02 | BUFFER | relay→engine | copy |
| 0x03 | CONN_OPEN | relay→engine | all |
| 0x04 | CONN_CLOSE | both | all |
| 0x05 | FDMSG | both | all |
| 0x06 | SRVOBJ | engine→relay | all |
| 0x07 | BUFFER_LZ | relay→engine | copy |
| 0x08 | HANDLE_OPEN | relay→engine | handle |
| 0x09 | HANDLE_CLOSE | relay→engine | handle |
| 0x0a | COMMIT | relay→engine | handle, GPU resources |
| 0x0b | ACK | engine→relay | handle, GPU resources |
| 0x0c | FEATURE | relay→engine | all |
| 0x0d | DMABUF_CREATED | engine→relay | all (dmabuf) |
| 0x0e | PRESENTED | engine→relay | all |

### 0x01 WIRE — wayland wire bytes (either direction)

```
u8  type = 0x01
u32 conn_id
u32 byte_len
u8  bytes[byte_len]   ← raw wayland wire messages
```

`bytes` MUST contain only **whole** wayland messages (one or more; senders
batch, receivers loop until byte_len is consumed). A message never spans two
frames — the receiver keeps no reassembly state. Consecutive same-conn wire
traffic within one WS message coalesces into a single WIRE frame.

- server→browser: requests read from app `conn_id`, message-aligned.
- browser→server: events for app `conn_id`; server writes them verbatim to the
  app socket.

Messages whose signature contains an fd never travel as WIRE — see FDMSG.

### 0x02 BUFFER — shm pixel data, server→browser only (copy backend)

```
u8  type = 0x02
u32 conn_id
u32 surface_id
u32 width, height     ← buffer dims in buffer px
u32 n_rects           ← always ≥ 1
{ i32 x, i32 y, i32 w, i32 h }[n_rects]
u8  rgba[]            ← rect pixel rows concatenated, in rect order; each rect
                        row-major, rows tightly packed (w*4 bytes per row)
```

Sent at `wl_surface.commit` time for the damaged regions of the attached
buffer (M7.1+: accumulated `wl_surface.damage`/`damage_buffer` rects, clamped
to buffer bounds — `wl_surface.damage` is scaled by the buffer scale, and
counts as the whole buffer on a surface with a viewport or a buffer
transform; rects past the server's cap merge into bounding boxes;
first ship, a dim change, or the first pixels after the surface showed a
GPU resource (COMMIT kind virtgpu) degrade to one full-buffer rect — see
COMMIT's "Damage").
Pixels are **canvas-ready RGBA**: the server swizzles wl_shm xrgb8888/argb8888
(little-endian BGRX/BGRA bytes) at ship time, forcing alpha 0xff for xrgb and
passing argb's (premultiplied) alpha through unchanged —
the browser paints them straight into a 2D canvas with no per-pixel work.
Rects never overlap the buffer edge; coords are buffer-local. Commits with no
effective damage ship **nothing** (no 0-rect frames).

`wl_buffer.release` never travels over the stream: in copy mode the server
releases the buffer to the app itself, immediately after copying the damaged
pixels out of the pool at commit time — the client can reuse its buffer
without waiting a browser round trip. See [Buffer release](#buffer-release)
for the rule both modes share. A commit whose buffer geometry lies outside its
pool is not presented but still releases. So is one whose bytes lie past the
end of the pool's FILE: the size a client gives `create_pool`/`resize` is a
claim, and a client may truncate its file under a live buffer at any time.
The relay reads the pool under a SIGBUS guard (a read past the end turns into
zero pages and an unshown commit, never a crash of the relay).

### 0x03 CONN_OPEN — app connected (server→browser)

```
u8  type = 0x03
u32 conn_id
```

conn_id is never 0: 0 names no app — it is the browser's own clipboard
selection wherever a conn is reported (the reference compositor's
selection owner, the engine's 'selection' event) — and the reference
compositor refuses a CONN_OPEN of 0 (logged, no conn), as it does one for a
conn that is already open. wlandr numbers conns from 1.

### 0x04 CONN_CLOSE — app disconnected (either direction)

```
u8  type = 0x04
u32 conn_id
```

server→browser: the app hung up; browser drops all state for conn_id,
including closing every handle of that conn (no HANDLE_CLOSE is sent for
them). browser→server: compositor wants the app gone (fatal protocol error);
server closes the unix socket.

### 0x05 FDMSG — fd-carrying wire message (M3+)

```
u8  type = 0x05
u32 conn_id
u32 fd_kind           ← 1 = shm_pool (the server took the pool fd)
                        2 = memfd   (browser ships the bytes; server makes a memfd:
                                     wl_keyboard.keymap, dmabuf feedback format_table)
                        3 = pipe    (clipboard receive/send; aux = u32 fd token)
                        4 = dmabuf  (the server took a zwp_linux_buffer_params_v1.add plane fd)
                        5 = pipe_read (the browser reads the clipboard selection; the
                                       server makes the pipe and reads it. Browser→
                                       server only to a server that sent FEATURE
                                       selection_cache)
                        6 = own_pipe (browser→server, only to a server that sent
                                      FEATURE selection_cache: a receive of the
                                      browser's own selection, from the server's copy)
u32 byte_len
u8  wire_bytes[byte_len]  ← the original wire message, fd arg carries no bytes
u32 aux_len
u8  aux[aux_len]      ← kind-specific: shm_pool, dmabuf: none (every mode);
                        memfd: the file's bytes; pipe: 4-byte LE fd token (browser→
                        server with no wire message: + the bytes to write);
                        pipe_read, own_pipe: see below
```

server→browser (fd_kind=shm_pool): `wl_shm.create_pool` arrived; the server
stole the fd via SCM_RIGHTS (the copy backend mmaps it; a handle backend
exports byte ranges of it later, see HANDLE_OPEN). Browser tracks the pool
object. The aux is empty in every mode: handles are not pools (a handle may
cover one buffer, outlive `wl_shm_pool.destroy`, or be replaced on resize), so
they travel in their own frames.
browser→server (fd_kind=memfd): an event whose fd is a file of bytes the
browser has — `wl_keyboard.keymap` (aux = the keymap text) or
`zwp_linux_dmabuf_feedback_v1.format_table` (aux = the format table). The
server creates a memfd holding `aux` plus one NUL byte (xkb's convention; the
size the event names is the browser's and leaves it out for the table) and
sends the wire message with that fd attached.

server→browser (fd_kind=dmabuf): `zwp_linux_buffer_params_v1.add` arrived;
the server kept the plane's fd (it belongs to the wl_buffer the params turn
into, STREAM-invisible). The browser tracks the plane for its protocol errors
(plane index, plane set twice, modifiers). aux is empty. A server without a
dmabuf backend never sends it: an `add` there closes the fd and drops the
conn (the global was never advertised).

fd_kind=pipe travels BOTH directions (M7.2 clipboard). The pipe write-end fd
only ever exists server-side; the token names it across the hop:
- server→browser: a `receive(mime, fd)` request arrived from the receiving app
  on a server-allocated offer. The server stashes the fd in a token-keyed table
  and forwards the wire message plus token. **The fd must be a pipe** (an
  anonymous pipe or a FIFO — what wl-paste, GTK, Qt, foot and the rest
  pass): wlandr closes any other fd at once and sends nothing, so that
  receiver reads EOF. The server writes and closes these fds on threads
  every app shares, and only a pipe's write and close never wait — a FUSE
  or hung-NFS file's, a tty's block whatever O_NONBLOCK says. **Object-typing rule:** the browser
  compositor allocates server-side ids (≥ 0xff000000) for two interfaces —
  `wl_data_offer` (clipboard + dnd) and `zwp_primary_selection_offer_v1`
  (primary selection) — from ONE contiguous counter. The ids cannot be
  partitioned by value: libwayland's client-side object map treats a server id
  as a dense array index (id − 0xff000000), so a sparse/high-bit scheme makes
  clients reject the id ("not a valid new object id"). Instead the browser
  announces each primary offer's type with a **SRVOBJ** frame (below); the
  server watches primary_offer.receive (opcode 0) on flagged ids and
  data_offer.receive (opcode 1) on everything else. Both are intercepted
  identically here.
- browser→server: the compositor routed the request to the selection source:
  wire_bytes = a `wl_data_source.send(mime, fd)` (clipboard/dnd) or
  `zwp_primary_selection_source_v1.send(mime, fd)` (primary) event for conn_id
  (the SOURCE app), aux = the echoed token. The server attaches the stashed fd
  via SCM_RIGHTS, then closes its copy — it never inspects the wire message, so
  either source event carries unchanged. Unknown/stale tokens are dropped;
  pending fds are closed when the browser detaches.
- browser→server, `byte_len` = 0: the receive has no source to go to (the
  offer's source was destroyed, its conn is gone, the offer is unknown). The
  server closes the fd parked under the token and sends nothing: the receiver
  reads EOF. Every token the server hands out is answered one way or the
  other.
- browser→server, `byte_len` = 0 and aux longer than the token: the offer is
  the browser's own selection (the embedder's, e.g. the page clipboard: the
  compositor holds the bytes), from a browser that does not use own_pipe.
  aux = token ++ the bytes, on every receive; the server writes them into
  the fd parked under the token, then closes it, exactly like an
  own_pipe's (below: one writer, capped, 5 s). The server never parses the
  bytes. wlandr accepts it; the reference browser never sends it (it uses
  own_pipe, and offers apps a selection of its own only on a link whose
  server sent FEATURE selection_cache — a server without it, wlandr 0.1.0,
  rejects this form, "pipe fdmsg with bad aux len", and keeps the fd
  parked: the receiving app would block in `read`).

fd_kind=pipe_read (5) lets the browser read the clipboard selection itself
(the page clipboard bridge), both directions, never a wire message the app
sent. The browser sends it only to a server that sent FEATURE
selection_cache (wlandr 0.1.0 predates it: "unsupported fdmsg kind 5", no
answer ever comes):
- browser→server: wire_bytes = a `wl_data_source.send(mime, fd)` event for
  conn_id (the source app), aux = u32 read_id ++ u32 max_bytes. The server
  makes a pipe, sends the event with the write end attached (closing its
  copy), and reads the read end until EOF, more than max_bytes (it caps
  that at 64 MiB), 5 s, or the link detaching.
- server→browser: the answer, exactly one per read while the link stays
  attached: conn_id = the source app, byte_len = 0, aux = u32 read_id ++
  u32 status ++ the bytes. status 0 = all of it (the pipe reached EOF:
  every holder of the write end closed it), 1 = over max_bytes (no bytes),
  2 = timed out (no bytes), 3 = failed: the send could not be delivered
  (the source's conn was gone) or the pipe failed (no bytes).
  EOF is 0 whether or not the source is still connected by then: it is
  the only completion signal any Wayland receiver gets, and sources hang
  up before it in normal use (`wl-copy --paste-once` hands the write to a
  child and exits). A source killed mid-write reads as 0 with what it
  wrote — the same truncation every other receiver of it would see.
  read_id is the browser's; the server only echoes it.

fd_kind=own_pipe (6), browser→server only, and only to a server that sent
FEATURE selection_cache: a `receive` on an offer of the browser's own
selection, answered from the server's copy of the payload, so each payload
crosses the link once per link rather than once per receive. conn_id = the
receiving app, byte_len = 0, aux:

```
u32 token        ← the parked receive (0: none)
u32 gen          ← the own selection's generation (0: it is gone — drop the copy)
u32 blob         ← which of its payloads, < 32 (mime types may share one)
u32 flags        ← bit 0: the payload's bytes follow
u8  bytes[]      ← (flags bit 0) the payload
```

With bytes, the server keeps them as (gen, blob), first dropping whatever
it kept of another generation; the reference browser sends them with the
first receive of each payload on a link. Then the receive under `token` is
served from the kept (gen, blob): the server writes it into the parked fd
and closes it; with none kept (never sent, another generation, dropped) it
just closes it (the receiver reads EOF). gen = 0 (token 0, conn_id 0, no
bytes): the browser's own selection was replaced or cleared — the server
frees its copy (transfers already going finish from the bytes they began
with). The copy also goes when the link detaches.

wlandr writes every own-selection receive (own_pipe or pipe with bytes) on
one writer thread: non-blocking writes between polls (RWF_NOWAIT per
write, so a receiver clearing O_NONBLOCK on its shared end changes
nothing), none under a lock the link or app threads take, at most 4
transfers in flight per receiving conn and 32 in all — past a cap the fd is
closed at once (EOF), as it is for a conn that closed meanwhile, even one
closing as the frame is handled — each given 5 s, ended at EPIPE, when its
conn closes, or when the link detaches. A receiver that never reads costs
a slot for 5 s, never a thread or a copy.

### 0x06 SRVOBJ — server-object type registration, browser→server only (M13)

```
u8  type = 0x06
u32 conn_id
u32 object_id      ← a server-allocated id (≥ 0xff000000)
u32 kind           ← 1 = zwp_primary_selection_offer_v1
```

The browser allocates server-side offer ids from one contiguous counter shared
by `wl_data_offer` and `zwp_primary_selection_offer_v1` (libwayland requires
dense server ids, so the type can't live in the id value). This frame tells the
server the type of an id so its `receive` interception (FDMSG kind 3, above)
watches the right opcode. Only primary offers are announced — an unregistered
server id defaults to `wl_data_offer`, keeping the clipboard/dnd path byte-for-
byte unchanged. The browser emits it in the same burst as (just before) the
`data_offer` event that introduces the offer, so the server records the type
before the app can send `receive`. The server drops a registration when the
app destroys that offer, a conn's registrations when the conn closes, and
ignores one for a conn that is already gone.

### 0x07 BUFFER_LZ — LZ4-compressed shm pixel data, server→browser only (copy backend)

```
u8  type = 0x07
u32 conn_id
u32 surface_id
u32 width, height     ← buffer dims in buffer px
u32 n_rects           ← always ≥ 1
{ i32 x, i32 y, i32 w, i32 h }[n_rects]
u32 raw_len           ← uncompressed pixel byte count (= Σ w*h*4 over rects)
u32 comp_len          ← compressed byte count
u8  comp[comp_len]    ← LZ4-block-compressed pixel section
```

Identical to BUFFER (0x02) through the rects, then a compressed pixel section
instead of a raw one. The header + rects are byte-for-byte a BUFFER frame apart
from the type tag, so the browser reconstitutes a 0x02 frame by copying them and
flipping the type byte. `comp` is the **LZ4 block format** (see core/src/lz4.zig)
of exactly the bytes a 0x02 frame would have carried — the swizzled, canvas-ready
RGBA rect rows concatenated in rect order (`raw_len` bytes). `raw_len` is
derivable from the rects but shipped explicitly so the decoder can size its
output in one step.

The server ships 0x07 **instead of** 0x02 only when the pixel section is at least
a few KB (below that the codec can't beat the framing overhead) **and** the
compressed result is smaller than the raw pixels; incompressible or tiny payloads
ship as plain 0x02. Compression folds into the same commit-time swizzle/snapshot
pass as trimming, so pixels are touched once and the copy-at-COMMIT-time invariant
holds. The browser decompresses **inside wasm** (wland_decode_buffer): the raw
0x02 fast path keeps pixels out of wasm memory, but a compressed frame is copied
in, inflated back to a 0x02 frame in wasm memory, and presented from there —
synchronously, so its order relative to the surrounding WIRE frames is preserved
(same invariant as 0x02). `wl_buffer.release` is still the server's job and does
not travel; presenting has no protocol side effects.

### 0x08 HANDLE_OPEN — a buffer handle, server→browser only (handle backends)

```
u8  type = 0x08
u32 conn_id
u32 handle_id         ← ≥ 1, chosen by the relay, never reused within a relay run
u32 kind              ← 1 = kwshm, 2 = procfd (0 is never valid)
u32 len
u8  bytes[len]        ← kind-specific, see Handle kinds
```

A handle names `size` bytes of shared memory (handle bytes 0 … size−1) that
the engine reads in place through its **buffer source** (supplied by the
embedder; `lib/engine.ts` `HandleSource`). It belongs to `conn_id`. The
engine opens it while processing this frame, before it processes any later
frame (a COMMIT naming it may follow in the same message); a buffer source
that answers asynchronously holds up the engine's frame processing until it
does. If it cannot — unknown kind, bytes of the
wrong length, no buffer source, the source refuses — it reports an error and
remembers the handle as broken; COMMITs naming a broken or unknown handle are
ACKed without presenting. Lifetimes: see [Buffer handles](#buffer-handles).

#### Handle kinds

**1 = kwshm** (unkernel: the relay is a guest program, the engine runs on the
kernel's thread in the host page or worker). 12 bytes:

```
u32 id                ← the export id KWSHM_IOC_EXPORT returned (> 0)
u64 size              ← bytes exported (struct kwshm_export.size, out)
```

Relay side: `open("/dev/kwshm", O_RDWR)` once, kept open for the relay's
life (closing it releases every export it made); per handle
`ioctl(kwshm_fd, KWSHM_IOC_EXPORT, &e)` with
`struct kwshm_export { s32 fd; u32 flags; u64 offset; u64 length; u64 size; u32 id; u32 pages; }`
(40 bytes; in: `fd` = the pool fd, `flags` = `KWSHM_EXPORT_RDONLY` (1),
`offset` = page-aligned start in the file, `length` = bytes from there (must
lie within the file's current size); out: `size`, `id`, `pages`) and, when
the backing's life ends, `ioctl(kwshm_fd, KWSHM_IOC_RELEASE, &id)` (a `u32`).
`KWSHM_IOC_EXPORT = _IOWR(0xBB, 0x00, struct kwshm_export) = 0xC028BB00`,
`KWSHM_IOC_RELEASE = _IOW(0xBB, 0x01, __u32) = 0x4004BB01` (asm-generic
`_IOC` encoding, which aarch64 uses; from unkernel's
`include/uapi/linux/kwshm.h`). Export failures (`ENOSPC`: 4096 exports;
`ENOMEM`: the half-of-RAM pin limit; `EINVAL`: range outside the file — a
pool larger than its file lands here) leave
the buffer without a handle: it is treated as unreadable (no COMMIT, released
at commit time). An export pins its pages: a client truncating the file
afterwards leaves the host reading the old (pinned) pages, never a fault. Host side: kwshm announces a guest export's page list to the
host before the ioctl returns, so the id is always resolvable by the time
this frame arrives. A host binding must stay bound to *that* export: once the
guest releases it, reads must fail, never resolve the id afresh (ids are
cyclic, so reuse is remote but possible). Note `F_SEAL_WRITE` fails with
`EBUSY` on a file while it is exported.

**2 = procfd** (debug/tests: relay and engine on one Linux machine, same
user). 24 bytes:

```
u32 pid               ← the relay's pid
u32 fd                ← an fd the relay keeps open for the handle's backing life
u64 offset            ← file offset of handle byte 0
u64 size
```

Handle byte `i` is file byte `offset + i`. The engine opens
`/proc/<pid>/fd/<fd>` when it processes this frame and keeps its own fd until
the handle closes (so the relay closing or reusing the fd number later cannot
redirect it); a Node engine reads with `fs.readSync(fd, dst, 0, n, offset +
i)`, the native Zig harness may `mmap` its fd. The relay never checks the file's
size: bytes past its end (a pool larger than its file, a truncation) read
short — the reference source then fails the read, so that COMMIT is ACKed
without presenting. No isolation of any kind: never ship it.

### 0x09 HANDLE_CLOSE — server→browser only (handle backends)

```
u8  type = 0x09
u32 conn_id
u32 handle_id
```

No COMMIT names this handle any more: every COMMIT that named it has been
ACKed. The engine closes it in its buffer source and forgets it. A close of an
unknown or broken handle is ignored.

### 0x0a COMMIT — commit notice, server→browser only (handle backends, GPU resources)

```
u8  type = 0x0a
u32 conn_id
u32 surface_id
u32 serial            ← per conn: 1, 2, 3, … (+1 per COMMIT; never 0)
u32 n_rects
u32 kind              ← buffer kind: 1 = shm, 2 = virtgpu (0 is never valid)
u32 ref_len
u8  ref[ref_len]      ← kind-specific buffer reference
{ i32 x, i32 y, i32 w, i32 h }[n_rects]   ← damage, buffer px
```

Frame length = 25 + ref_len + 16 · n_rects. `ref_len` makes the frame
self-delimiting whatever its kind, so a new buffer kind is a new `kind`
value with its own ref layout — not a new frame type — and an engine that
does not know the kind still frames it and ACKs it.

Buffer kind **1 = shm**, ref (24 bytes):

```
u32 handle_id         ← an open handle of this conn (HANDLE_OPEN earlier on the link)
u32 offset            ← handle byte of pixel (0, 0)
u32 width, height     ← buffer px
u32 stride            ← bytes per row
u32 format            ← wl_shm format: 0 = ARGB8888, 1 = XRGB8888 (nothing else)
```

Pixel (x, y) is the 4 bytes at handle byte `offset + y·stride + x·4`, the
little-endian word 0xAARRGGBB (ARGB8888, premultiplied alpha) or 0xXXRRGGBB
(XRGB8888, X undefined) — i.e. bytes B, G, R, A|X, exactly as the client wrote
them. Those are the only formats the compositor advertises (`wl_shm.format`
0 and 1).

**When it is sent.** For a `wl_surface.commit` whose surface has a current
buffer (attached by this commit or an earlier one) with non-empty effective
damage — the same condition under which the copy backend ships BUFFER. Not
for: commits with no effective damage, `attach(null)`, untracked buffers,
buffers that do not fit their pool (zero dims, stride < width·4, offset +
stride·height > pool size), formats other than 0/1, or buffers the relay could
not open a handle for. Those commits present nothing; whether they owe a
release is decided as for any commit (below).

**Damage.** Accumulated `wl_surface.damage` (scaled by the buffer scale) and
`damage_buffer` since the previous commit, clamped to the buffer, empties
dropped; at least one rect. The first COMMIT for a surface, one whose buffer
dims differ from the previous pixel frame's, and one whose buffer **kind**
differs from the previous pixel frame's (pixels — BUFFER, BUFFER_LZ or
COMMIT kind shm — versus COMMIT kind virtgpu) carries exactly one full-buffer
rect: the engine's copy of the surface is gone (resized, or made by another
path: the reference GL presenter starts a blank texture when shm pixels
follow a GPU image). So does the first one after a commit that showed
nothing (the engine missed changes). Otherwise damage is relative to the
previous commit's content, whichever buffer held it — the next of a
swapchain's resources included: each buffer holds the whole surface
(`wl_surface.attach`), so an engine may copy just the damaged rects onto
what it shows, or the whole image. The relay caps rects (64 today, merging
past the cap) but receivers accept any count. No shadow trimming: the relay
never reads the pixels. (In copy mode the relay's shadow of what the engine
shows is dropped when a GPU image replaces it, so the full rect after it
ships whole, untrimmed.)

The relay counts every COMMIT it sent as shown; it can't see one the
engine ACKed without showing anything new — kind virtgpu with no image
resolved (no resolver, null, a throw or a rejection), a failed read or a
broken handle for kind shm, an invalid notice. The engine makes up for it:
the surface's next COMMIT is presented whole, its damage replaced by one
full-buffer rect (the reference engine does so before asking the buffer
source or the resolver, so both see the full rect too, as does the commit
event), else a presenter copying only the damaged rects would paint them
over stale content.

**Ordering.** Same rule as BUFFER: after the WIRE frame carrying its
`wl_surface.commit`, in the same message; its HANDLE_OPEN anywhere earlier on
the link.

**Validity** (`CommitFrame.shm()` in stream.zig, then the engine): kind 1,
ref_len 24, format 0 or 1, width and height ≥ 1, stride ≥ width·4,
n_rects ≥ 1, every rect non-empty and inside the buffer, a known open
(not broken) handle of the same conn_id, and `offset + stride·height ≤ size`
of that handle. A COMMIT failing any of
these, or of an unknown kind, is ACKed without presenting (and logged).

**Engine side (reference engine, `lib/engine.ts`).** The engine reads the
damaged bytes through its buffer source while processing the COMMIT (one read
per damage span, merged when close, or all spans in one batched read, or the
source's memory viewed in place; an asynchronous source holds up later
frames, in order, until the read settles), hands the presenter a commit event
(`format` `'bgra'` for ARGB8888, `'bgrx'` for XRGB8888, plus `stride` — or,
for a view that presents with 2D only, packed `'rgba'` converted by the core's
`wland_swizzle`), and ACKs once that event's synchronous dispatch has
returned. Alpha policy matches the copy backend: XRGB alpha becomes 0xff,
ARGB alpha passes through unchanged (`wland_swizzle`, or the 2D presenter's
JS swizzle for 2D surfaces beside GL ones; the GL presenter swaps channels and
forces alpha in its shader).

Buffer kind **2 = virtgpu**: a GPU resource the embedder's renderer holds,
named instead of shipped. wlandr emits it with `--dmabuf virtgpu` (below,
"wlandr's emitter"); the JS test relay, `test/support/relay.js` with
`gpu: true`, does too, for the engine's tests. Ref (≥ 36 bytes):

```
u32 resource          ← resource id (≥ 1): whatever the embedder's renderer and its guest side agree on (e.g. a virgl resource id)
u32 width, height     ← the wl_buffer's size, buffer px
u32 format            ← DRM fourcc (drm_fourcc.h)
u32 flags             ← zwp_linux_buffer_params_v1 flags: 1 y_invert, 2 interlaced, 4 bottom_first
u32 offset, stride    ← plane 0's, as the client gave them (informational)
u64 modifier          ← plane 0's; 0x00ffffffffffffff = DRM_FORMAT_MOD_INVALID (implicit)
```

Versioning: fields are only ever appended; a receiver reads the first 36
bytes and ignores the rest of `ref_len`. The resource alone names the
pixels; the rest lets the embedder check what it resolves (and present
y_invert right).

When it is sent: as for kind shm (a current buffer, non-empty effective
damage; damage and the full-buffer rule — first, resized, kind changed —
likewise). There is no fence in STREAM.

**The contract with the embedder** (the reference engine's side of it is
`lib/engine.ts` `GpuSource`; none of it has run against a real renderer):

- *Ordering.* When the engine processes the COMMIT, the embedder's
  renderer must already have executed every command submitted for the
  resource before the COMMIT was sent. That is the emitter's obligation
  (STREAM carries no fence); a renderer that may lag the link makes its
  resolver wait (a resolver may return a promise).
- *Copy on commit.* The engine reads the resource only while processing
  the COMMIT (the resolver's image is drawn during the commit's dispatch);
  the ACK means "the page is done with this resource for this commit", and
  the emitter then releases the wl_buffer — the client may draw into it
  right away.
- *Ids.* A COMMIT's id stays valid until its ACK: the emitter keeps the
  resource alive until then, also past `wl_buffer.destroy`.
- *The image.* The resolver returns something its consumers draw: for the
  view a CanvasImageSource (ImageBitmap, OffscreenCanvas, canvas,
  VideoFrame), for wland/headless an RgbaImage. Its row 0 is the buffer's
  top row (honouring y_invert); X-format alpha comes out opaque; it is
  drawn as the browser treats the image (an ImageBitmap's alpha is
  straight to a 2D canvas).

Validity (`CommitFrame.virtgpu()`): kind 2, ref_len ≥ 36, resource ≥ 1,
width and height ≥ 1, n_rects ≥ 1, every rect non-empty and inside the
buffer. Format and modifier are not checked here (the resolver's business).
An invalid one is ACKed without presenting.

Engine side for kind 2: the core decodes it (`wland_commit_notice`), the
engine asks its embedder's resolver (`EngineOptions.gpu`) for the resource's
content, dispatches the commit event (format `'gpu'`, `gpu` = the ref,
`image` = what the resolver returned), lets the resolver release the image,
and ACKs. An engine without a resolver reports an error once, still
dispatches each commit with no image (the surface is laid out and keeps its
last content) and ACKs it — though in front of wlandr such an engine
offers no linux-dmabuf in the first place (FEATURE dmabuf_kind), so only a
relay that names wl_shm buffers as resources (the JS test relay) gets
there. A commit with no image makes the surface's next one whole (Damage,
above).

**wlandr's emitter (`--dmabuf virtgpu[:NODE]`, `server/src/virtgpu.zig`).**
The resource is the virtio-gpu one behind the client's dmabuf. At
`create`/`create_immed` the relay imports plane 0's fd on the render node
(`DRM_IOCTL_PRIME_FD_TO_HANDLE` → a GEM handle,
`DRM_IOCTL_VIRTGPU_RESOURCE_INFO` → `res_handle`, the ref's `resource`); the
other ref fields are the client's (size, fourcc, flags, plane 0's offset,
stride and modifier). It offers ARGB8888, XRGB8888, ABGR8888 and XBGR8888,
each with `DRM_FORMAT_MOD_INVALID` (first: virgl allocates with the
implicit layout) and LINEAR, one plane. A buffer it cannot name — more
planes, interlaced flags, a failed import (a dmabuf of another device, a
resource id of 0), or a claimed layout the resource cannot hold — is
accepted but never shown (no COMMIT; released per commit like an unfit
wl_shm buffer). The layout check: stride ≥ width·4, neither side over 16384
px (a GL texture's usual limit), and `offset + stride·(height−1) + width·4 ≤
RESOURCE_INFO.size` — the GEM object's size: the guest backing Mesa asked
for, page-rounded by the kernel; so a one-page resource can't make the page
size a canvas from a 16384×16384 claim. That backing is the layout's total
size (256-aligned, so at least `stride·height`) only for resources created
`PIPE_BIND_SHARED` — which GBM and EGL-Wayland buffers always are, so a GPU
client's buffers pass. Mesa's `virgl_resource_create_front` asks for 1 byte
for a texture that can use staging transfers and 0 (one page) for MSAA: such
a non-shared texture exported as a dmabuf is refused here though it is valid
on the host (the relay cannot learn the host's size; refusing is the safe
side), logged as having no guest backing of the claimed size. The first refusal of
each kind is logged with its reason, as is the first buffer of each
(format, modifier, flags) it does name; refusals have their own bounded
table, so no client can use up the accepted-buffer lines, and the
fence-timeout note below is per conn.
Lifetime: the GEM handle keeps the resource alive; the relay counts its
holders — each wl_buffer made from it plus each un-ACKed COMMIT naming it
(one handle per object per DRM file: two wl_buffers over one dmabuf share
it) — and closes it (`DRM_IOCTL_GEM_CLOSE`) when the last goes, so a
COMMIT's resource outlives `wl_buffer.destroy` until its ACK; a conn or
link ending drops its holds at once. Release: the shared ledger (Buffer
release), so after the ACK. Nothing here has run on a real virtio-gpu node.

*The relay's own renderer context.* On a device without
`VIRTIO_GPU_F_CONTEXT_INIT` (unkernel's offers only VIRGL) the guest kernel
creates a host virgl context for a DRM file at its first PRIME import
(`virtio_gpu_gem_object_open` → CTX_CREATE, then CTX_ATTACH_RESOURCE per
import, CTX_DETACH_RESOURCE at GEM_CLOSE) and destroys it only when the
file closes. So the relay's imports cost the page one more renderer
context, and the relay keeps the node open only while it holds a handle:
opened at the first import, closed when the last handle goes, opened again
(a new context) at the next. With no GPU buffer alive the page hosts no
context of the relay's (unkernel refuses snapshots while any exists).
At startup the node is opened once to check it — DRM_IOCTL_VERSION must
name `virtio_gpu`, since DRM dispatches driver ioctls by number and
RESOURCE_INFO on another driver's node would run that driver's ioctl — and
closed again; every later open checks the same.

*Ordering, as wlandr provides it.* The relay forwards a client's requests in
the order it reads them and adds no reordering: a COMMIT is built while the
relay handles that client's `wl_surface.commit` — right after appending that
request's WIRE, in the same link message, before any later request of the
client — and nothing is queued or deferred. A GPU client submits its
rendering (Mesa: execbuffer, at `eglSwapBuffers`) before it sends the commit
request, so the submission precedes the COMMIT on its way to the host.
On top of that the relay waits, before building the COMMIT, for the
dmabuf's implicit write fences: `poll(POLLIN)` on plane 0's fd returns once
the fences the kernel attached to the buffer (virtio-gpu attaches its
execbuffer fence to every buffer the batch names) have signalled. A
signalled fence means the device answered the fenced SUBMIT_3D — nothing
more: in unkernel that is right after its renderer ran the commands in its
WebGL context (not GPU completion), which is exactly what a resolver
reading the texture in that same context needs; QEMU in strict mode
answers at host GPU completion. The wait is bounded (100 ms): past it the
COMMIT goes out anyway and the first such timeout of each conn is logged
(at info: a slow first frame, compiling its shaders, can take that long);
it holds up only that client's thread (other clients and the link go
on). `wlandr --no-fence-wait` skips the wait: for a device that delivers
the client's GPU work to the page before the link's later bytes on its
own (unkernel: GPU requests and vsock packets share one channel), where
the wait adds nothing but a round trip per frame; emission order is then
the whole guarantee. Explicit sync
(`linux-drm-syncobj-v1`) is not advertised (FD RULE), so no client attaches
a sync file and the ref carries no fence.

### 0x0c FEATURE — a relay capability, server→browser only

```
u8  type = 0x0c
u32 feature           ← 1 = linux_dmabuf, 2 = dmabuf_kind, 3 = selection_cache
                        (0 is never valid)
u32 len
u8  bytes[len]        ← feature-specific
```

Sent first on a link, before any CONN_OPEN, one per feature the relay has
(none: no frame); wlandr sends them all in the link's first message. It
tells the compositor what it may offer apps; the browser applies it before
it processes the next frame. A browser that does not know a feature skips
the frame (it is self-delimiting), and a feature's bytes are its own: one
whose length is implied by `len` (linux_dmabuf's table) can't grow, so new
facts are new feature kinds.

**1 = linux_dmabuf**: the relay takes dmabufs (`--dmabuf`), so the compositor
advertises `zwp_linux_dmabuf_v1` (version 4; without this frame it is never
advertised and a bind of it is a protocol error). The table is the
backend's (readback: ARGB8888 and XRGB8888, LINEAR; virtgpu: ARGB8888,
XRGB8888, ABGR8888, XBGR8888 with `DRM_FORMAT_MOD_INVALID`, then the same
with LINEAR). Bytes:

```
u64 main_device       ← dev_t clients allocate on (glibc makedev encoding)
{ u32 format, u32 0, u64 modifier }[n]   ← 1 ≤ n ≤ 256, the format table
```

The entries are exactly the format table the compositor ships to clients
(`zwp_linux_dmabuf_feedback_v1.format_table`, a memfd via FDMSG kind 2); the
feedback is one tranche on `main_device` holding every entry, flags 0, and
`create`/`create_immed` with a (format, modifier) pair outside it is
`invalid_format`. v3 binders get one `modifier` event per entry, v1/v2
binders one `format` event per format the table offers with
`DRM_FORMAT_MOD_INVALID` (their `format` promises the implicit modifier;
readback's LINEAR-only table gives them none).

**2 = dmabuf_kind**: how the relay's dmabuf commits reach the engine — as
COMMITs of one buffer kind. Sent just before linux_dmabuf (same message)
by a relay whose dmabuf backend sends COMMITs (wlandr: `virtgpu`, kind 2);
absent (readback), dmabuf commits travel as pixels — BUFFER/BUFFER_LZ, which
every engine shows. Bytes (≥ 4; fields are only ever appended, a receiver
reads the first 4 and ignores the rest):

```
u32 buffer_kind       ← the COMMIT buffer kind every dmabuf commit carries (2 = virtgpu)
```

An engine that cannot show that kind does not advertise
`zwp_linux_dmabuf_v1`, whatever linux_dmabuf says — so a GPU client finds
no dmabuf path and renders in software over wl_shm (Mesa's EGL falls back
to swrast; a dmabuf-only client like weston-simple-dmabuf-egl exits)
instead of rendering into buffers that would show blank. The reference
compositor (`Compositor.applyFeature`): kind shm is showable, kind virtgpu
only when the embedder has a GPU source (`wland_set_gpu_source`; the
reference engine sets it from `EngineOptions.gpu` at every link open; 1 when
never set), anything else (unknown, or bytes under 4) not; a refusal is
logged once per link and also holds if linux_dmabuf came first. The JS test
relay with `gpu: true` sends it too (kind virtgpu, no linux_dmabuf after
it: its "GPU" buffers are wl_shm ones).

**3 = selection_cache**: the server bridges the clipboard for the browser:
it reads selections for it (FDMSG pipe_read) and keeps a copy of each
payload of the browser's own clipboard selection it is sent, serving
receives from it (FDMSG own_pipe, above), so each payload's bytes cross
once per link. Bytes: none (any are ignored). wlandr sends it on every
link, after the dmabuf frames. Without it (a server that predates it:
wlandr 0.1.0) the browser sends neither pipe_read nor own_pipe nor a pipe
with bytes, and offers apps no selection of its own — an app could not
paste it (the server would park its pipe and never write it). The
reference browser: `Engine.selectionBridged()` false, `readSelection`
rejects at once, `setSelection` sets nothing, the page bridge is inert on
that link (one log line; copy/paste chords are plain keys). Apps' own
selections travel between apps as ever (FDMSG pipe with a wire message).
Which it is is known at the link's first frame that is not a FEATURE
(every app starts with CONN_OPEN), and decided again on every link.

### 0x0d DMABUF_CREATED — a server-made dmabuf wl_buffer, browser→server only

```
u8  type = 0x0d
u32 conn_id
u32 params_id         ← the zwp_linux_buffer_params_v1 the client sent `create` on
u32 buffer_id         ← the wl_buffer the compositor made (a server id ≥ 0xff000000)
```

`create` (not `create_immed`) makes the wl_buffer on the compositor's side,
from the same dense server-id counter as the offers (see FDMSG's
object-typing rule), and announces it with `created(buffer_id)`. The server
needs that id to tie the params' plane fds to the buffer, so the browser sends
this frame just before (same burst) the WIRE frame holding `created`. The
server records it before writing `created` to the app, so the buffer is
tracked by the time the app can name it. `create_immed` needs nothing: the
client names the id. A `create` the compositor refuses gets no frame: the
refusals are protocol errors (fatal to the client; the reference compositor
never sends `failed`), and the server drops what it took from the params
with the conn. (wlandr's virtgpu import refuses each of those buffers on
its own checks before naming it, so no GEM handle waits for that.)

### 0x0e PRESENTED — a presentation timestamp to stamp, browser→server only

```
u8  type = 0x0e
u32 conn_id
u32 age_us            ← how long before the browser sent this its frame began, µs (0 = just now)
u32 byte_len
u8  bytes[byte_len]   ← exactly one wayland message: wp_presentation_feedback.presented
```

The compositor owns presentation feedback (see [Presentation
feedback](#presentation-feedback)) but not the clock it must be dated on:
`wp_presentation.clock_id` is CLOCK_MONOTONIC, which an app reads on its
own machine — the server's — while the browser's clock is
`performance.now()`, on another clock and possibly another machine. So
the `presented` event travels in this frame instead of WIRE, and the
server overwrites its first three args (`tv_sec_hi`, `tv_sec_lo`,
`tv_nsec`: bytes 8…19 of the message) with its CLOCK_MONOTONIC at the
moment it handles the frame, less `age_us`, then writes the message to
the app like WIRE. Everything else in the event (refresh, seq, flags,
the browser's own time as a placeholder in the timestamp) is the
browser's. A message under 20 bytes is dropped (and logged).

Order: the frame sits among the conn's WIRE frames in event order (its
`sync_output` events precede it in WIRE, its `delete_id` follows); the
server handles frames strictly in order, so the app sees them so.

Accuracy: the stamp is the moment the frame began (the browser's rAF
timestamp; `age_us` is measured on the browser's clock alone, so the two
clocks never need relating) plus the link's one-way latency, which the
server cannot see — sub-millisecond on loopback, the network's latency
on a remote browser. Always late, never early, of that moment; when the
pixels actually turned to light (the browser's compositor pipeline, a
frame or two after the rAF that follows the commit) is not observable
from a page.

### 0x0b ACK — commit acknowledgement, browser→server only (handle backends, GPU resources)

```
u8  type = 0x0b
u32 conn_id
u32 serial            ← a COMMIT's serial on conn_id
```

The engine has **consumed** that COMMIT: it will not read the COMMIT's bytes
from the handle again (it copied or uploaded the damaged pixels, or decided not
to present) — for kind 2: it will not read the resource for this COMMIT
again (the resolved image was drawn, or nothing was). The engine sends
exactly one ACK per COMMIT it received — also
for invalid, unknown-kind, broken-handle and closed-conn COMMITs — in any
order across serials. It SHOULD send it no later than the end of processing
the link message that carried the COMMIT (the client's buffer reuse waits on
it); the reference engine sends it right after the commit event's dispatch.
The relay ignores an ACK for an unknown serial or a closed conn.

## Buffer handles

What a handle covers is the relay backend's choice; the engine only ever
reads the bytes a COMMIT names. The relay keeps a handle's **backing** (the
kwshm export, the procfd fd) alive from before its HANDLE_OPEN until the first
of:

1. it sends HANDLE_CLOSE, which it does when the handle's references reach
   zero. References: the wl_buffer (or pool) the handle was made for, while
   that object lives, plus one per COMMIT naming the handle that is not yet
   ACKed;
2. the conn ends (app hung up, or engine CONN_CLOSE) — no HANDLE_CLOSE; the
   engine closes the conn's handles on CONN_CLOSE;
3. the link drops — no frames; the engine closes all its handles when its link
   closes (and the relay drops every conn, see Rules).

So a handle never closes under an un-ACKed COMMIT except when its conn or link
is ending; a read failure there is expected (ACK, skip). The ACK wait is what
makes this safe for kwshm: the host's view of an export disappears the moment
the guest releases it, while frames naming it may still be in flight on the
link.

**Resize.** `wl_shm_pool.resize` never changes an open handle: a handle's size
is fixed at HANDLE_OPEN, and engines never refresh. (kwshm: "a resized file
needs a refresh", and refresh is a host-initiated asynchronous round trip
through the kernel — unusable on this path. A guest re-export, by contrast, is
synchronous.) A relay whose handles cover whole pools opens a new handle for
the grown pool and lets the old one close by the rule above; with per-buffer
handles a resize needs nothing, since pools only grow and a buffer's bytes
never move.

**Recommended granularity, both kinds: one handle per wl_buffer**, opened
lazily just before the buffer's first COMMIT, covering
`[page_floor(buffer.offset), buffer.offset + stride·height)` of the pool fd
(COMMIT `offset` = `buffer.offset − page_floor(buffer.offset)`), closed when
the wl_buffer is destroyed and its COMMITs are ACKed. Why not whole pools:
kwshm pins and allocates every page it exports, holes included, and caps
pinned memory at half of guest RAM — a sparse pool such as foot's
(scroll-optimised, up to 512 MiB of address space by default) would be
allocated whole or fail; foot also punches holes in its pool as it scrolls,
which leaves a whole-pool export looking at stale pages. A per-buffer export
covers only bytes a live buffer uses. One export per live committed buffer
stays far below kwshm's 4096.

## Buffer release

`wl_buffer.release` has one sender, the relay (`finishCommit` and the ACK
path). The engine never releases. The same ledger serves wl_shm and
linux-dmabuf buffers. The relay keeps, per wl_buffer:

- `owed` — an attach-latching commit of this buffer has not been released;
- `busy` — COMMITs naming this buffer not yet ACKed (a count: the same buffer
  may be committed again, with or without a new attach, before an earlier
  ACK arrives).

| Event | Effect |
| --- | --- |
| commit that latches `attach(B)` | `owed(B) = true` |
| COMMIT sent for B | `busy(B) += 1` |
| after any commit, whether or not a COMMIT was sent | if `owed(B) && busy(B) == 0`: release B, `owed(B) = false` |
| ACK of a COMMIT naming B | `busy(B) -= 1`; then the same check |
| `wl_buffer.destroy(B)` | B is forgotten: no release, ever (the engine's `delete_id` frees the id for reuse, and a late release would hit the new object). Its un-ACKed COMMITs still hold their handle (kind 2: their resource) |
| `wl_surface.destroy` | nothing (buffers are independent of surfaces) |
| conn closes / link drops | everything dropped, no releases |

For a buffer shipped as pixels (copy mode, readback) `busy` is always 0, so
this is v1's behaviour: release right after the commit-time copy. The invariant is **one release per busy period,
never a release without an attach**: GTK commits WITHOUT attach for empty
frames, and a duplicate release makes GDK destroy the cairo surface it is
painting into (nautilus SIGSEGV). A client that waits for the release before
re-attaching a buffer — every real client, and always in copy mode — gets
exactly one release per attach-latching commit. A client that re-attaches B
while an earlier COMMIT of B is still un-ACKed gets one release for both,
when B goes idle: `wl_buffer.release` means "no longer used", and releasing
after the first ACK would hand B back while the engine has yet to read the
second commit.

## Frame callbacks

Where `wl_callback.done` for `wl_surface.frame` fires is a property of the link
(`Link.frame_callbacks` in server/src/link.zig), never both sides, and is
independent of the buffer backend:

- **relay** (WebSocket): the server intercepts `wl_surface.frame` (the browser
  never sees it) and, when the surface commits, fires `done` + `delete_id`
  itself once that burst's message has been written to the link, at most
  once per ~16 ms per conn. A surface destroyed before committing still gets
  its callbacks fired. This removes the browser round trip from the app's
  render loop.
- **engine** (byte stream): the request is forwarded as WIRE. The compositor
  treats it as double-buffered surface state: latched by that surface's next
  `wl_surface.commit`, fired (`done(time)` + `delete_id`) at the first
  `compositor.tick` after that commit — the engine calls tick from its
  presentation clock (requestAnimationFrame). A callback whose surface is
  destroyed first is dropped with `delete_id` and no `done` (as weston and
  wlroots do). A minimized window's callbacks are held until it is restored
  (its client's render loop stops, as on any compositor); the relay side
  has no such state and keeps firing them for a minimized window.

## Presentation feedback

`wp_presentation` (advertised on every link) is the compositor's alone:
nothing in it carries an fd and the server intercepts none of it, on
either link type. A `feedback` is double-buffered surface state, latched
by the surface's next `wl_surface.commit` (a synchronized subsurface's at
its own commit, like all its state). The browser's frame clock (its
tick, from requestAnimationFrame) is the moment of presentation: at the
first tick after the commit the content is on screen (the browser draws a
commit when it arrives, and that frame composites it), so every latched
feedback ends there — `sync_output` for each `wl_output` the client bound,
then `presented` (in a PRESENTED frame) and `delete_id` — or with
`discarded` + `delete_id` when the surface isn't shown then (no buffer,
no role, an unmapped parent). A second commit before that tick discards
the first's feedbacks at once (superseded: its pixels were drawn over
before any frame showed them), and a destroyed surface discards its
feedbacks, latched or not. While a buffer source's promise is pending the
browser doesn't tick (nothing new is drawn), so feedback waits like the
frame callbacks.

What `presented` says beyond the time: `refresh` = the display's frame
interval as the browser measured it from rAF timestamps (0 until known,
and always 0 for a browser whose clock drives no display: wland/headless's
timer); `seq` = 0 (a page has no vblank counter); flags = `vsync` for a
display frame (the browser composites without tearing, and the time is
its frame's), nothing for headless — never `hw_clock`, `hw_completion`
or `zero_copy` (a software clock, a guessed completion, copied pixels),
and neither v3 rate flag (the page can't tell a fixed-rate display from
a variable one).

## Rules

- The server serves one engine link at a time. A new link (a second browser
  tab, or a new stream connection) takes over: the old one is kicked (a WS tab
  gets close code 4000 "takeover") and its app connections are dropped —
  their compositor state lived in that engine.
- App connections made while no engine is attached wait (kernel-buffered)
  until one attaches; the server then sends CONN_OPEN and starts relaying.
  (wlandr `--link-on-demand`: they wait for the dial they start, and are
  closed if it fails.)
- conn_ids and handle_ids are never reused within a server run.
- FEATURE frames come first on a link (dmabuf_kind before linux_dmabuf);
  the rest of a link never changes what the relay can do.
- Version skew: a browser meets a server that lacks a FEATURE as one that
  can't do that thing (above: linux_dmabuf, selection_cache) and never
  sends it the frames that need it, so a newer page in front of wlandr
  0.1.0 works with the page clipboard bridge off. An older browser skips
  the FEATURE kinds it doesn't know.
- No heartbeats. ACK (for COMMIT) is the only acknowledgement. Copy-mode pixel
  payloads above a size threshold are LZ4-compressed (BUFFER_LZ, 0x07);
  everything else ships uncompressed.

## Profiles: passthrough and session

A link runs in one of two profiles, fixed for the link's life.

- **passthrough** (the default; everything above): the relay forwards
  Wayland to the engine, whose compositor (the wasm core) holds every app's
  state. A link that closes takes its apps with it.
- **session** (`wlandr --profile session`): the compositor runs inside the
  relay (the same core, hosted natively) and outlives links. The engine on
  the other end is a *viewer*: it is sent the scene and sends input. A
  viewer that goes away (a page reload) changes nothing for the apps; the
  next one is sent the scene as it is now. One viewer at a time, the newest
  takes over (the old one gets the takeover close, as in passthrough).

The relay announces session with **FEATURE 4 = session**, the first frame
of the link's first message; bytes: exactly 8, `u64 session_id`
little-endian (random per relay run — a viewer keys state it keeps across
reloads, window positions, by it; shown as 16 lowercase hex digits). A
viewer honours it only among the link's leading FEATURE frames (one after
any other frame is ignored: the link stays passthrough). No such frame:
passthrough. An engine that does not know the feature must not be pointed
at a session relay (it would meet frame types it cannot parse).

On a session link:

- **Never sent**: WIRE, FDMSG, SRVOBJ, DMABUF_CREATED, PRESENTED (they are
  between the relay and its own compositor).
- **Unchanged**: CONN_OPEN, CONN_CLOSE (relay→viewer only), BUFFER,
  BUFFER_LZ, HANDLE_OPEN, HANDLE_CLOSE, COMMIT, ACK.
- **New**: CALL (viewer→relay), EVENT and SURFACE (relay→viewer), below.
  They mirror the core's embedder ABI (`core/src/wasm.zig`): a CALL is one
  `wland_*` export call, an EVENT one `js_*` import call, SURFACE carries
  what the synchronous `wland_surface_*` getters return.

Initial version limits: the copy buffer backend only (`--buffers copy`,
`--dmabuf` none or `readback`), so pixels are BUFFER / BUFFER_LZ and no
COMMIT/ACK/HANDLE frame occurs; wlandr refuses other combinations with
`--profile session`.

### Argument encoding (CALL, EVENT)

Arguments follow in the listed order, little-endian, unpadded: `u32`/`i32`
4 bytes, `f64` 8 bytes, `bytes` = `u32 len` + `len` bytes. Fixed-point
values (`*_fixed`, wl_fixed) and everything else mean what the wasm export
or import of the same name means. A receiver skips an op it does not know
(the frame is self-delimiting) and ignores bytes past the arguments it
knows. Ops are only ever added, never renumbered, so a peer that predates
one just goes without it: a relay before CALL 29 ignores close (the app is
not asked), a viewer before EVENTs 14–15 has no app ids or size hints. An
op's arguments may grow at the end the same way: init's `decorations` is
ignored by a relay that predates it (toplevels stay client-side), and a
viewer that predates it sends none (read as 0); a relay before CALL 30 /
EVENT 16 keeps the output's size as the bounds and tells no decoration; a
relay before CALL 31 renders for windows the viewer hides. `cause` (the
last word of CALLs 19, 20, 23 and 32) is the viewer's token for the call:
every EVENT configure the call makes carries it back, so a viewer learns
the serial its own call produced without a reply (absent: 0); a relay
before EVENTs 17–18 tells neither configures nor acks; a relay before
CALL 33 places popups without constraint adjustment.

### 0x0f CALL — an embedder call, viewer→relay only (session)

```
u8  type = 0x0f
u16 op
u32 len
u8  args[len]
```

| op | call | args |
| --- | --- | --- |
| 1 | init | i32 scale, i32 scale_120, u32 decorations (1 = the viewer draws window frames: EngineOptions.decorations 'server'; 0 or absent = client-side) |
| 2 | set_gpu_source | u32 has |
| 3 | set_dpr | i32 scale, i32 scale_120 |
| 4 | desktop_size | i32 w, i32 h |
| 5 | set_suspended | u32 suspended |
| 6 | pointer_enter | u32 conn, u32 surface, i32 x_fixed, i32 y_fixed |
| 7 | pointer_leave | u32 conn |
| 8 | pointer_motion | u32 conn, u32 time_ms, i32 x_fixed, i32 y_fixed, i32 dx, i32 dy, i32 dxu, i32 dyu, f64 utime |
| 9 | pointer_lock_granted | u32 conn, u32 surface |
| 10 | pointer_lock_lost | u32 conn |
| 11 | pointer_button | u32 conn, u32 time_ms, u32 button, u32 pressed |
| 12 | pointer_axis | u32 conn, u32 time_ms, u32 axis, i32 value_fixed, i32 value120 |
| 13 | keyboard_enter | u32 conn, u32 surface |
| 14 | keyboard_leave | u32 conn |
| 15 | key | u32 conn, u32 time_ms, u32 evdev_key, u32 pressed |
| 16 | keyboard_locks | u32 locks |
| 17 | text_input_preedit | u32 conn, bytes text, i32 cursor_begin, i32 cursor_end |
| 18 | text_input_commit_string | u32 conn, bytes text |
| 19 | set_maximized | u32 conn, u32 surface, u32 on, u32 cause |
| 20 | set_fullscreen | u32 conn, u32 surface, u32 on, u32 cause |
| 21 | set_minimized | u32 conn, u32 surface, u32 on |
| 22 | popup_dismiss | u32 conn, u32 surface |
| 23 | request_resize | u32 conn, u32 surface, i32 w, i32 h, u32 cause |
| 24 | drag_motion | u32 conn, u32 surface, u32 time_ms, i32 x_fixed, i32 y_fixed |
| 25 | drag_drop | — |
| 26 | drag_cancel | — |
| 27 | set_selection | bytes packed (as wland_set_selection takes it; len 0 clears) |
| 28 | read_selection | bytes mime, u32 read_id, u32 max_bytes |
| 29 | close | u32 conn, u32 surface (xdg_toplevel.close to that toplevel) |
| 30 | set_bounds | i32 w, i32 h, i32 decorated_w, i32 decorated_h (the work area: configure_bounds and the maximized size; 0×0 = the desktop's size, decorated 0×0 = w×h) |
| 31 | set_visible | u32 conn, u32 surface, u32 visible (0: the viewer hides the toplevel's window — frame callbacks held, feedback discarded, v6 `suspended`, nothing else changed; 1: shown) |
| 32 | set_tiled | u32 conn, u32 surface, u32 edges, i32 w, i32 h, u32 cause (the tiled_* states from now on: edges 1 top, 2 bottom, 4 left, 8 right, 0 none; w×h > 0 rides the same configure, clamped like request_resize) |
| 33 | set_window_position | u32 conn, u32 surface, i32 x, i32 y (where the toplevel's window-geometry origin sits in the output, logical px: its popups are constrained to the output from then on) |

**init is the attach.** A viewer sends it once, first, when it has seen
FEATURE session (followed by its set_gpu_source / desktop_size /
set_suspended / keyboard_locks as it would call them on a fresh core). It
does not reset the compositor: the relay applies the scale like set_dpr,
sets the decorations mode (apps outlive viewers: running toplevels whose
mode it changes are answered again — their decoration configure, a
configure — before the replay, which then carries the new state), drops
the bounds a previous viewer set (the viewer sends its own set_bounds after
init when it has any) and the per-window state it set (windows it hid with
set_visible are shown, those it tiled untiled, the window positions it
told forgotten: the new viewer sets its own) and answers with the **scene replay** — for every app conn a CONN_OPEN, for
every surface its SURFACE and the EVENTs that describe it now
(surface_event with its role, set_title, set_app_id, input_region,
size_limits unless all 0, decoration when decorated, acked with the
configure the toplevel last committed, the interactive state
kinds 2/6/8 that are set),
parents before what hangs from them, then
for every surface with content one BUFFER (or BUFFER_LZ) holding its whole
current image as one damage rect, then the current cursor, text_input,
pointer_lock, selection and keyboard_locks_state EVENTs, then EVENT
`synced`. Nothing but the FEATURE frame(s) is sent to a viewer before its
init; CALLs before init are ignored. Every init starts the SURFACE diffing
afresh: the relay forgets the records it sent before (they were another
viewer's, or an earlier init's), so the replay carries a SURFACE for every
live surface — all of them, parents first, ahead of the replay's EVENTs —
and later SURFACEs are relative to those. The replay is one consistent
snapshot (taken in one step of the compositor); CALLs the viewer sends
while it is still arriving (its window manager focusing toplevels as they
map) are applied after it, in order.

There is no tick: the relay runs the frame clock itself (frame callbacks
and presentation feedback at its ~60 Hz pace while a viewer is attached,
slowly while none is). There is no note_buffer_size: the relay notes the
dims of every pixel frame itself, before the SURFACE that precedes it.

set_selection and read_selection have no synchronous result: the outcome
is the `selection` EVENT, respectively a `selection_data` EVENT (status 3
when there was nothing to ask). A set_selection that changes nothing
(refused: malformed, too large; or an empty one while an app owns the
selection) is still answered with a `selection` EVENT naming the selection
as it is.

**When a viewer goes** (link closed or taken over) the relay ends what
only it was holding up: the pointer leaves, the keyboard leaves (held keys
and buttons are released), a pointer lock is lost, a drag is cancelled,
pending selection reads are dropped, and the apps are told they are
suspended until the next init.

### 0x10 EVENT — an embedder event, relay→viewer only (session)

```
u8  type = 0x10
u16 op
u32 len
u8  args[len]
```

| op | event | args |
| --- | --- | --- |
| 1 | log | bytes line |
| 2 | set_title | u32 conn, u32 surface, bytes title |
| 3 | surface_event | u32 conn, u32 surface, u32 value |
| 4 | interactive | u32 conn, u32 surface, u32 kind, u32 value |
| 5 | cursor_shape | u32 conn, u32 shape |
| 6 | cursor_surface | u32 conn, u32 surface, i32 hx, i32 hy |
| 7 | text_input | u32 conn, u32 active, i32 x, i32 y, i32 w, i32 h |
| 8 | input_region | u32 conn, u32 surface, u32 infinite, u32 n, n × { i32 x, y, w, h } |
| 9 | pointer_lock | u32 conn, u32 surface |
| 10 | selection | u32 conn, bytes mimes (NUL-separated) |
| 11 | selection_data | u32 read_id, u32 status, bytes data |
| 12 | keyboard_locks_state | u32 locks (what wland_keyboard_locks_state returns; sent when it changes) |
| 13 | synced | — (the scene replay that answered init is complete) |
| 14 | set_app_id | u32 conn, u32 surface, bytes app_id |
| 15 | size_limits | u32 conn, u32 surface, i32 min_w, i32 min_h, i32 max_w, i32 max_h (a toplevel's committed set_min_size / set_max_size, window geometry px, 0 = unset; all 0 when its xdg_toplevel goes) |
| 16 | decoration | u32 conn, u32 surface, u32 decorated (1: the toplevel was configured server_side, the viewer draws its frame; 0: client-side again) |
| 17 | configure | u32 conn, u32 surface, u32 serial, i32 w, i32 h, u32 states, u32 cause (every xdg_toplevel configure the compositor sends: its xdg_surface serial, the size asked — 0 = the client decides —, the states as the app was told them: 1 maximized, 2 fullscreen, 4 activated, 8 suspended, the tiled edges << 4 (1 top, 2 bottom, 4 left, 8 right); cause = the token of the CALL that made it, 0 = none) |
| 18 | acked | u32 conn, u32 surface, u32 serial, i32 w, i32 h (a commit applied the configure `serial` the app acked since its last commit; w×h is what it asked; before that commit's pixel frames) |

EVENTs keep the order the compositor made them in, relative to each other
and to the pixel frames, CONN_OPEN/CONN_CLOSE and SURFACE frames around
them. conn_close has no EVENT: CONN_CLOSE (0x04) is it.

### 0x11 SURFACE — a surface's synchronous state, relay→viewer only (session)

```
u8  type = 0x11
u32 conn_id
u32 surface_id
u32 role            ← wland_surface_role
i32 scale           ← wland_surface_scale
i32 view_w, view_h  ← wland_surface_view_w / _h
u32 toplevel_state  ← wland_toplevel_state (of this surface)
u32 root            ← wland_surface_root
u32 parent          ← wland_surface_parent
i32 abs_x, abs_y    ← wland_surface_abs_x / _y
i32 z               ← wland_surface_z
i32 geom_x, geom_y, geom_w, geom_h   ← wland_window_geometry (of this surface)
```

65 bytes. The viewer keeps the last one per (conn, surface) and answers the
getters from it. The relay sends one whenever any field differs from what
it last sent for that surface, and always **before** the EVENT or pixel
frame that the viewer reads it for: after every step that can change
compositor state it compares every live surface and sends the changed ones,
ahead of that step's EVENTs and of the next pixel frame. A surface's
record ends with its `surface_event` destroyed value or its conn's
CONN_CLOSE. A SURFACE whose abs_x, abs_y or z differ from the previous one
is what `wland_take_positions_dirty` reports.
