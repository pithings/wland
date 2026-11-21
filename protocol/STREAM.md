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
backend**, also fixed at startup. The one there is, `readback` (needs the
`copy` buffer mode), maps a LINEAR dmabuf and ships it exactly like a wl_shm
buffer — BUFFER/BUFFER_LZ, released at commit time — so the engine cannot
tell the two apart.

A GPU buffer can instead be named, not shipped: a COMMIT of buffer kind 2
names a resource the embedder's renderer holds, released when the engine
ACKs it (see COMMIT). The engine side exists; no relay in this repo emits
it yet (only the JS test relay does). COMMITs of both kinds may share one
conn; they share its serial space and its ACKs.

There is **no negotiation and no version frame**: relay and engine ship
together, and the engine learns the mode from the frames that arrive. (A
FEATURE frame announces something the relay can do — today linux-dmabuf —
but nothing answers it: it is one-way, like the buffer mode.) An
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
  are dropped (see Rules). The engine side treats every new connection as a
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
first ship or dim change degrade to one full-buffer rect).
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
u32 byte_len
u8  wire_bytes[byte_len]  ← the original wire message, fd arg carries no bytes
u32 aux_len
u8  aux[aux_len]      ← kind-specific: shm_pool, dmabuf: none (every mode);
                        memfd: the file's bytes; pipe: 4-byte LE fd token
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
  and forwards the wire message plus token. **Object-typing rule:** the browser
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
dropped; at least one rect. The first COMMIT for a surface, or one whose buffer
dims differ from the previous COMMIT's, carries exactly one full-buffer rect
(the engine's copy of the surface is gone). The relay caps rects (64 today,
merging past the cap) but receivers accept any count. No shadow trimming: the
relay never reads the pixels.

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
per damage span, merged when close; an asynchronous source holds up later
frames, in order, until the read settles), hands the presenter a commit event
(`format` `'bgra'` for ARGB8888, `'bgrx'` for XRGB8888, plus `stride` — or,
for a view that presents with 2D only, packed `'rgba'` converted by the core's
`wland_swizzle`), and ACKs once that event's synchronous dispatch has
returned. Alpha policy matches the copy backend: XRGB alpha becomes 0xff,
ARGB alpha passes through unchanged (`wland_swizzle`, or the 2D presenter's
JS swizzle for 2D surfaces beside GL ones; the GL presenter swaps channels and
forces alpha in its shader).

Buffer kind **2 = virtgpu**: a GPU resource the embedder's renderer holds,
named instead of shipped. No relay in this repo emits it yet (the JS test
relay, `test/support/relay.js` with `gpu: true`, does, for the engine's
tests). Ref (≥ 36 bytes):

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
damage; damage and the full-buffer first/resized rule likewise). There is
no fence in STREAM.

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
last content) and ACKs it.

### 0x0c FEATURE — a relay capability, server→browser only

```
u8  type = 0x0c
u32 feature           ← 1 = linux_dmabuf (0 is never valid)
u32 len
u8  bytes[len]        ← feature-specific
```

Sent first on a link, before any CONN_OPEN, one per feature the relay has
(none: no frame). It tells the compositor what it may offer apps; the
browser applies it before it processes the next frame. A browser that does
not know a feature skips the frame (it is self-delimiting).

**1 = linux_dmabuf**: the relay takes dmabufs (`--dmabuf`), so the compositor
advertises `zwp_linux_dmabuf_v1` (version 4; without this frame it is never
advertised and a bind of it is a protocol error). The table is the
backend's (readback: ARGB8888 and XRGB8888, LINEAR). Bytes:

```
u64 main_device       ← dev_t clients allocate on (glibc makedev encoding)
{ u32 format, u32 0, u64 modifier }[n]   ← 1 ≤ n ≤ 256, the format table
```

The entries are exactly the format table the compositor ships to clients
(`zwp_linux_dmabuf_feedback_v1.format_table`, a memfd via FDMSG kind 2); the
feedback is one tranche on `main_device` holding every entry, flags 0, and
`create`/`create_immed` with a (format, modifier) pair outside it is
`invalid_format`. v3 binders get one `modifier` event per entry, v1/v2
binders no formats (their `format` event would promise implicit modifiers).

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
client names the id.

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

In copy mode `busy` is always 0, so this is v1's behaviour: release right
after the commit-time copy. The invariant is **one release per busy period,
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
- conn_ids and handle_ids are never reused within a server run.
- FEATURE frames come first on a link; the rest of a link never changes
  what the relay can do.
- No heartbeats. ACK (for COMMIT) is the only acknowledgement. Copy-mode pixel
  payloads above a size threshold are LZ4-compressed (BUFFER_LZ, 0x07);
  everything else ships uncompressed.
