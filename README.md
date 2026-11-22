# 🪟 wland

**Wayland apps, composited in the browser.**

![How wland works: unmodified Wayland apps talk to the wlandr relay over a unix socket on a Linux host, VM guest or container; the relay keeps the file descriptors and streams the rest over a WebSocket, vsock or any byte stream to a compositor running as wasm in a browser tab; with --profile session the compositor runs in the relay instead and the tab is a viewer, so apps outlive a reload](.github/how-it-works.svg)

wland is a Wayland compositor compiled to WebAssembly, ~65 kB gzipped in
total. Real apps like `foot` and `nautilus` speak the real wire protocol,
unmodified, and show up as windows in a web page. Typing, menus, clipboard,
drag and drop, HiDPI and window controls all work. ⚡ It's fast too: up to
120 FPS on a Retina MacBook.

👉 **[See it in action](https://wland.vercel.app/)**

[Quick start](#-quick-start) · [CLI](#-cli) · [Docker](#-docker) · [SDK](#-sdk) · [How it works](#-how-it-works) · [Relay](#-the-relay-wlandr) · [Security](#-security) · [What works](#-what-works) · [Limits](#-known-limits) · [Building](#-building-from-source)

## 🚀 Quick start

Run the demo image. It works anywhere Docker does:

```sh
docker run -it --rm -p 8080:8080 ghcr.io/pithings/wland
```

Open http://localhost:8080. Chromium and the PCManFM file manager are
running inside the container, and show up as windows in the page. Open the
`README.txt` in the file manager for things to try.

In the page:

- Drag a titlebar to move a window, or **Alt+drag** anywhere.
- Drag an edge to resize.
- Use the top bar to switch windows.
- **Alt+F9** minimizes, **Alt+F10** maximizes, **Alt+F11** goes fullscreen.

Only one tab is the desktop at a time. A newly opened tab takes over.

More on the image under [Docker](#-docker).

## 💻 CLI

To show the apps of your own machine, run the server directly. This needs
Linux (unix sockets with fd passing):

```sh
npx wland
```

Open the printed URL in your browser. Then launch apps from any shell:

```sh
npx wland run foot        # terminal
npx wland run nautilus    # GTK file manager
npx wland run xterm       # X11 apps work too (needs xwayland-satellite)
wl-copy hello             # the clipboard is shared between apps
```

The commands:

```sh
wland [serve] [options]                     # start the server
wland run [--display NAME] <app> [args...]  # launch an app against it
```

Server options:

- `--port N` — HTTP port (default `8080`).
- `--host ADDR` — address to listen on (default `127.0.0.1`). See
  [Security](#-security) before widening it.
- `--display NAME` — Wayland socket name. Default: the first free `wayland-N`.
- `--runtime-dir DIR` — socket folder. Default: `$XDG_RUNTIME_DIR`.
- `--xwayland auto|off|PATH` — X11 apps through
  [xwayland-satellite](https://github.com/Supreeeme/xwayland-satellite).
  `auto` uses it when installed.
- `--web-root DIR` — serve your own page instead of the bundled one.

`wland run` sets everything an app needs: `WAYLAND_DISPLAY`, `DISPLAY` for
X11, software rendering for GTK, and a session dbus if none is running.

You can also run apps directly. If the server got `wayland-0`, plain `foot`
just works. Inside a desktop session it picks `wayland-1` instead, and prints
what to set. It never takes over a socket that is in use.

## 🐳 Docker

The demo image holds the server, its page, Chromium, PCManFM and a small
text editor (l3afpad), for linux/amd64 and linux/arm64.

Pass the apps to run, one command line per argument (the default is
`chromium pcmanfm`):

```sh
docker run -it --rm -p 8080:8080 ghcr.io/pithings/wland "chromium https://example.org"
```

The apps keep running across a page reload or a closed tab: the image
runs the server with `--profile session`, where the compositor lives in the
server and the page shows it. An app you close stays closed until the next
page load. `-e WLAND_PROFILE=passthrough` puts the compositor in the page
instead; a reload then disconnects every app and they are started again.

There is no authentication, and `-p 8080:8080` publishes the desktop on
every address of your machine. On a network you don't trust, publish it on
loopback only: `-p 127.0.0.1:8080:8080`.

To build the image yourself:

```sh
docker build -f docker/Dockerfile -t wland .
```

## 📦 SDK

The bundled page is just one way to use wland. You can embed the compositor
in your own page, or drive apps from a Node script.

```sh
npm install wland
```

The package has four entry points:

- `wland/client` — the compositor for a web page.
- `wland/engine` — the compositor without any DOM (Worker, Node).
- `wland/headless` — a DOM-free desktop for scripts and tests.
- `wland` — Node helpers to start the server and launch apps.

### Embed in a page

```js
import { createWland } from 'wland/client';

const wl = await createWland({
  container: document.getElementById('desktop'),
});
```

The container is the desktop. Give it a position and a fixed size: apps see
its size as the screen. Wland owns its children, so put your own UI next to
it, not inside.

By default it connects to `/ws` on the same host, which is what the server
provides.

### Build a taskbar

```js
const wl = await createWland({
  container,
  onWindowsChange() {
    taskbar.replaceChildren(...wl.windows().map((w) => {
      const b = document.createElement('button');
      b.textContent = w.title;
      b.classList.toggle('active', w.focused);
      b.onclick = () => w.raise();   // focus, or restore if minimized
      return b;
    }));
  },
});
```

Each window also has `appId` (the app's `set_app_id`, e.g. for its icon),
`minimize()`, `restore()`, `setMaximized(on)`, `setFullscreen(on)` and
`close()` (asks the app to close the window; the app decides, and may ask
about unsaved work first).

### Show connection status

```js
const wl = await createWland({
  container,
  onEvent(ev) {
    if (ev.type === 'open') status.textContent = 'connected';
    if (ev.type === 'close') {
      status.textContent = ev.takenOver ? 'moved to another tab' : 'disconnected';
    }
  },
});
```

To reconnect, call `wl.dispose()` and then `createWland()` again. Dispose
removes everything wland added, with no page reload.

### More options

```js
import { createWland, createWsLink } from 'wland/client';

await createWland({
  container,
  link: createWsLink('wss://example.com/ws'),  // a different relay
  scale: 2,                   // pin the scale, 1.5 works too (default: follows devicePixelRatio)
  webgl: 'never',             // 'auto' | 'always' | 'never'
  browserFullscreen: true,    // fullscreen windows also go browser-fullscreen
  shortcuts: false,           // turn off Alt+F9/F10/F11 ({ keys, drag }: the keys and Alt+drag apart)
  clipboard: false,           // keep the Wayland clipboard inside the desktop
});
```

See [`lib/client.ts`](lib/client.ts) for every option.

### Clipboard

By default the Wayland clipboard and the page's clipboard are bridged, for
plain text, both ways:

- **Paste into an app.** Ctrl+V, Ctrl+Shift+V or Shift+Insert in the desktop
  makes the browser fire its `paste` event. wland makes that text the
  clipboard of the focused app before the key reaches it, so the app's own
  paste reads it. (The key waits for the event: Chromium sends it at once,
  Firefox a moment later.) The keys themselves reach the app unchanged: in a
  terminal Ctrl+C is still an interrupt and Ctrl+V literal-next (terminals
  paste with Ctrl+Shift+V). Ctrl+C in the desktop never copies what the
  page has selected.
- **Copy out of an app.** When an app copies, wland reads the text and
  writes it to the page's clipboard while the browser allows that: right
  away if you pressed a key or clicked in the desktop within the last 5
  seconds (Chromium, Firefox), otherwise at your next key or click in the
  desktop, or your next Ctrl+C there (Safari needs one of those).
- **macOS, iOS** (not yet tried on a Mac or an iPad: see Current limits).
  Cmd+C, Cmd+X and Cmd+V are the chords there (Ctrl+V is no paste in a Mac
  browser: it goes to the app as a plain key). They reach the app as
  Ctrl+C, Ctrl+X and Ctrl+V, the chords Linux apps know, each sent whole
  when the chord is pressed (macOS browsers drop the key's release while
  Cmd is held); so in a terminal Cmd+V is literal-next and Cmd+C an
  interrupt — paste there with Cmd+Shift+V (Ctrl+Shift+V) where the browser
  makes it a paste, or Cmd+V once into any other app and then the
  terminal's Ctrl+Shift+V.

Which side is newer is decided by where you were. You are elsewhere once
the desktop loses the keyboard focus (another tab or window, page UI, a
click on plain page text) or you click outside it. An app that copies
while you are elsewhere (a script's `wl-copy`, a background app) never
writes the page clipboard while you are away; apps in the desktop paste
its text. The first look wland gets at the page clipboard after you are
back decides — your next paste in the desktop, or coming back itself if
the browser has already granted `clipboard-read`: if the page clipboard is
what wland last saw there, the app's text is newer — it is written to the
page (and pasted); if it changed (you copied something meanwhile, text or
not), yours stays and is pasted. An app clearing the clipboard (a password
manager's timeout, `wl-copy --clear`) clears the page clipboard too while
it still holds that app's text — when you are away, at that first look. An
app that merely exits (or a dropped connection) leaves the page clipboard
alone, as a clipboard manager would, and its text still pastes into the
other apps from there.

It never reads the page's clipboard on its own, with one exception: if the
browser has already granted `clipboard-read` to the page, focusing the
desktop reads it, so an app's Paste menu sees what you copied elsewhere. An
app sees the page's text only while it has keyboard focus. Text copied
inside the desktop and pasted back in stays the app's (no round trip), and
a page clipboard that is older than an app's copy never replaces it. Text
over 4 MiB is not bridged. Other types (HTML, images) are not bridged yet;
the engine API below carries any type. The bridge needs a relay that
speaks it, and checks on every connection: in front of an older relay
(`wlandr` 0.1.0) it switches itself off for that connection with one log
line, and the copy and paste keys go to the apps as plain keys, as with
`clipboard: false`; apps still copy and paste among themselves.

From code (both `wland/engine` and `wland/headless`):

```js
import { readSelectionText, setSelectionText } from 'wland/engine';

await readSelectionText(engine);       // the app's clipboard as text, or null
setSelectionText(engine, 'hello');     // offer text to the focused app
engine.readSelection('image/png');     // any type, as bytes (Promise)
engine.setSelection({ 'text/html': '<b>hi</b>', 'text/plain': 'hi' });
// 'selection' events tell you when it changes: { conn, mimes }
// (an app's conn with no mimes: it cleared it; conn 0 with none: its owner went)
engine.selectionBridged();             // false on a relay too old for this:
// reads then reject (NO_SELECTION_BRIDGE) and setSelection returns false
```

### Output size and scale

The output apps see follows the container's size (a ResizeObserver: if
your layout resizes the container, apps get the new size) and the device
pixel ratio, live. A hidden container (`display: none`) keeps the last
size. To decide yourself after start, pin either one:

```js
wl.output.setSize({ width: 1920, height: 1080 }); // apps see this, whatever the container
wl.output.setScale(1.5);                          // integer or fractional
wl.output.setSize(null);                          // follow the container again
wl.output.setScale(null);                         // follow devicePixelRatio again
wl.output.state();                                // { width, height, scale, sizePinned, scalePinned }
```

A size is rounded to whole px and each side must round to at least 1; a
scale must be a finite number above 0. Anything else throws a RangeError
and changes nothing (an invalid `scale` option rejects `createWland`,
leaving nothing behind). After `dispose()` these calls do nothing.

### Start the server from Node

```js
import { startServer } from 'wland';

const server = await startServer({ port: 8080 });
console.log(server.url);      // open this in a browser
// server.process.kill() stops it
```

Pass `webRoot` to serve your own page that uses `wland/client`.

### Launch apps from Node

```js
import { startServer, runApp } from 'wland';

const server = await startServer();
runApp(server, ['foot']);
```

`runApp` is what `wland run` uses. It sets the environment and starts a
session dbus when needed.

### Script apps without a browser 🤖

`wland/headless` is a full desktop in Node. It has no DOM. It can type,
click and take screenshots, which makes it great for tests and bots.

```js
import { spawn } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { startRelay } from 'wland';
import { createHeadless, encodePNG } from 'wland/headless';

const relay = await startRelay();
const hl = await createHeadless({ link: relay.link });

spawn('foot', { env: { ...process.env, ...relay.env } });

// ...once the window is up:
hl.type('ls\n');
hl.click(200, 100);
await writeFile('shot.png', await encodePNG(hl.screenshot()));

hl.dispose();
await relay.close();
```

The headless desktop also has `windows()`, `focus()`, `move()`, `resize()`,
`press('ControlLeft', 'KeyC')`, `scroll()`, `readClipboard()` /
`writeClipboard(text)` and more. See
[`lib/headless.ts`](lib/headless.ts).

### Build your own composition

`createWland` is four small modules glued together. You can use them one by
one, for example to draw your own window frames.

- **engine** — the compositor itself. Plain data in, plain data out. No DOM.
- **view** — turns events into canvases and window elements.
- **input** — turns DOM pointer and keyboard events into engine calls.
- **wm** — the window manager: move, resize, maximize, popups, drag and drop.
- **clipboard** — the page clipboard bridge (`createClipboardBridge`; pass
  its `hooks` to `createInput({ clipboard })` and feed it every event).

```js
import {
  createEngine, createWsLink, createView, watchOutput, createInput, createWindowManager, frameInterval,
} from 'wland/client';

const view = createView({ container });
let input, wm;

const engine = await createEngine({
  link: createWsLink(`ws://${location.host}/ws`),
  rgba: !view.webgl,
  onEvent(ev) {
    view.handle(ev);   // the view goes first
    input.handle(ev);
    wm.handle(ev);
  },
});
input = createInput({ engine, view, container });
wm = createWindowManager({ engine, view, input, container });

watchOutput(engine, container);   // size, pixel ratio, tab visibility
const interval = frameInterval();  // the display's refresh, from rAF
const frame = (t) => { engine.tick(t, interval(t)); requestAnimationFrame(frame); };
requestAnimationFrame(frame);

engine.start();
```

Your own window frames: the view hands you each window's element.

```js
const view = createView({
  container,
  mount(win) { myFrames.create(win.key, win.title).body.append(win.element); },
  unmount(win) { myFrames.remove(win.key); },
});
```

`createWland` takes the same `mount` and `unmount` options (and
`onFocusChange`, separate from `onWindowsChange`). Each `ViewWindow` also
carries the app's `appId` and size hints (`minW`, `minH`, `maxW`, `maxH`;
0 = no limit), so your frames need not offer a size the app refuses.

Server-side decorations: with `decorations: 'server'` (on `createWland`,
`createEngine` or `createHeadless`) apps that let the compositor draw
their frame (SDL games, foot, Qt) are told so, and their window is marked
`decorated`: they draw none, your frame goes around it. Apps that draw
their own anyway (GTK) stay `decorated: false`. It can change while the
window is up (`onWindowsChange`); an app that asks before its first commit
is marked by the time `mount` runs. Wland draws no frame itself, so use
`'server'` only with a `mount` that does. Then tell apps the room they
have, your workspace less your frame:

```js
const wl = await createWland({ container, decorations: 'server', mount, unmount });
wl.engine.setBounds(width, height, width - 2 * border, height - titleBar - 2 * border);
```

`setBounds(w, h, decoratedW, decoratedH)` is what apps are told to stay
within (`configure_bounds`) and the size a maximized window gets; 0×0 goes
back to the output's size.

Showing and hiding windows can be yours too. With `manageDisplay: false`
the view never sets a window element's `display` (by default it hides
minimized windows), so a minimize effect can animate the element away.
Tell wland when your window manager hides a window for its own reasons
(a compact mode, another workspace): a hidden window's app stops
rendering as if minimized (no frame callbacks, `suspended`), but it is not
minimized and keeps focus; shown again, it draws from where it was.

```js
const wl = await createWland({ container, mount, unmount, manageDisplay: false });
wl.engine.setVisible(conn, surface, false);   // or entry.setVisible(false) on wl.windows()
```

Menus near the edge: apps place popups relative to their window, and only
the compositor can keep them on screen (flip a menu to the other side of
its button, slide it back, shrink it), which needs to know where the window
is. The default window manager tells it; with your own frames, tell it
where each window's box (`ViewWindow.element`, the window geometry) sits
in the container whenever you place or move it:

```js
wl.engine.setWindowPosition(conn, surface, x, y);   // the box's top-left, container px
```

Snapping windows to halves and quarters: `setTiled` tells the app which
edges it is tiled against (it drops its shadows and rounded corners
there, as when maximized), and can ask for the tile's size in the same
configure. Apps may answer with a different size (foot rounds to whole
cells). To know which request an answer belongs to, every configure is a
`configure` event carrying the token your call returned, and every commit
that applies one the app acked is preceded by an `acked` event (also
`ViewWindow.acked`). An app acks only the latest configure it has seen, so
your request is answered once an acked serial reaches the serial of the
configure your token came back with:

```js
const token = wl.engine.setTiled(conn, surface, EDGE_LEFT | EDGE_TOP | EDGE_BOTTOM, width / 2, height);
// onEvent:
if (ev.type === 'configure' && ev.cause === token) asked = ev.serial;
if (ev.type === 'acked' && asked && ev.serial >= asked) {
  // the commit events that follow are the app's answer: place its size
}
```

The default wm expects the default mount. With your own frames, your window
manager can take what it owns and leave the rest (popups, drag and drop, the
key bindings) to wland's:

```js
const wl = await createWland({
  container,
  mount, unmount,
  // an app's move/resize request (its title bar, its border) or Alt+drag,
  // with the press it came from: return true and drag your own window
  interactive(ev, press) {   // ev.type: 'move' | 'resize' (ev.edges) | 'alt-drag'
    const grab = wl.input.grab(press.pointerId);   // the apps lose the pointer…
    myFrames.drag(ev, press, () => grab.active);    // …until that press ends, whatever happens
    return true;
  },
  autoFocus: false,   // focus is yours too: wland focuses nothing by itself
});
// on a press in your frame (inside the pointerdown, so a phone's keyboard can open):
wl.input.focus(conn, surface);
wl.input.blur();      // the keyboard goes to none of them
```

A grab ends at its pointer's release, cancel or lost capture, when the
browser window loses focus, or with `grab.end()`, and the app under the
pointer gets it back; a press already released gets none. With `autoFocus:
false` a press goes to the app without focusing it, a new window takes no
focus, and when the focused one closes or is minimized none has it until
you say. The `maximize`, `fullscreen` and `minimize` events are there for
your frames to follow.

The container is wland's: the view sets `touch-action: none` on it (touch
drags are window moves and app input, not page pans — without it the
browser cancels them), turns off text selection and the touch callout, and
makes it its own stacking context (`isolation: isolate`: window z-indexes
stay inside it). Dispose puts the old values back. Its size, position and
`overflow` are yours.

### Use the engine alone

The engine runs anywhere: a page, a Worker, or Node.

```js
import { createEngine, createStreamLink } from 'wland/engine';

const engine = await createEngine({
  link: createStreamLink(stream),
  onEvent(ev) { /* surface, commit, title, move, ... */ },
});
engine.setOutput(1280, 720);
setInterval(() => engine.tick(performance.now()), 16);
engine.start();
```

A few things to know:

- **Pixels are short-lived.** A `commit` event's `pixels` is valid only during
  the event, until you call the engine again. Draw or copy it right away.
- **Everything is plain data.** So the engine can live in a Worker behind
  `postMessage`.
- **Focus new windows.** Call `keyboardEnter` for new toplevels. Some apps
  wait for focus (`wl-copy` does). The input module does this for you.
- **Lock keys.** NumLock starts on and Caps Lock off; their key presses
  toggle them. Call `keyboardLocks(capsLock, numLock)` with the browser's
  state (`getModifierState`) before keys that depend on it, as the input
  module does (on macOS, which has no NumLock, it infers NumLock from what
  the keypad typed). The state, toggles included, carries over when the
  link reconnects.

All events and calls are typed in [`lib/engine.ts`](lib/engine.ts).

### Links

A link is how the engine talks to the relay.

- `createWsLink(url)` — a WebSocket. The default.
- `createStreamLink(source)` — any byte stream (web streams). Pass an async
  iterable of streams and the engine starts fresh on each reconnect.

You can write your own: a link is just `start`, `send`, `bufferedAmount` and
`close`. It must deliver messages asynchronously.

### Shared-memory buffers

When the relay and the page share memory (for example, a VM guest and its
host page), pixels don't need to travel at all. Start the relay with
`--buffers kwshm` or `procfd`, and give the engine a way to read memory:

```js
import { createWland, createStreamLink } from 'wland/client';

const wl = await createWland({
  container,
  link: createStreamLink(streams),
  buffers: {
    open: (handle) => openMemory(handle),           // returns your token
    read: (token, offset, dst) => copyInto(token, offset, dst),
    close: (token) => release(token),
  },
});
```

`open` and `read` may return promises, but sync is faster: while one is
pending, later frames wait. Two optional methods cut the cost:

- `readv(token, reads)` gets every damaged span of a commit in one call
  (`reads` is `[{ offset, dst }]`), so memory behind a round trip (a
  worker) costs one round trip per commit and copies only what changed.
  It may return one promise.
- `view(token, offset, length)` returns the memory itself, synchronously:
  one `Uint8Array` (no copy at all: it becomes the commit's pixels) or an
  array of them for scattered pages. A SharedArrayBuffer is fine (checked
  in Chromium, 2D and WebGL, and Firefox, 2D, on a cross-origin-isolated
  page). Return `null` to fall back to `readv`/`read` for that commit.

The engine uses `view`, then `readv`, then `read`. Whatever it is handed is
only read while the commit is processed. The demo page in
`web/` runs this whole path in one tab. A small Node example lives in
[`test/support/handles-procfd.ts`](test/support/handles-procfd.ts); the
`HandleSource` doc comment in [`lib/engine.ts`](lib/engine.ts) is the full
contract.

## 🧩 How it works

A Wayland app talks to a compositor over a unix socket. wland splits that
compositor in two:

```
┌─────────────┐ unix socket ┌───────────────┐   link    ┌────────────────────────┐
│ Wayland app │ ──────────► │     relay     │ ────────► │  compositor (client)   │
│ foot, GTK…  │   Wayland   │  small native │  STREAM   │  Zig → wasm, in a page │
│ unmodified  │ ◄────────── │    program    │ ◄──────── │  a <canvas> per surface│
└─────────────┘             └───────────────┘           └────────────────────────┘
```

- **The page is the compositor.** It handles windows, popups, focus, input
  and the clipboard, and paints each surface into a canvas. It is about
  65 kB gzipped.
- **The relay is a thin pipe.** Apps pass file descriptors (buffers,
  keymaps, clipboard pipes), and those can't leave the machine. The relay
  handles them and forwards everything else as is.
- **The link** between them is a small framing called STREAM. It runs over a
  WebSocket or any byte stream (unix socket, vsock, an inherited fd).

Pixels reach the page in one of two ways:

- **Copy** — the relay sends only the changed rectangles, compressed. This
  is what `npx wland` uses.
- **Handle** — the page reads the app's buffer memory in place. Nothing is
  sent. For setups where both sides share memory.

An idle desktop sends no bytes and draws no frames.

Some rules follow from the split:

- One engine at a time. A new tab takes the session over.
- Apps live as long as their link. A reload or a dropped connection closes
  them.
- Apps that start before a tab connects wait for it.

The full wire format is in [`protocol/STREAM.md`](protocol/STREAM.md).

## 📡 The relay (`wlandr`)

`wlandr` is the server binary behind `npx wland`. It is one static Zig binary
of about 700K, with no dependencies. It runs on Linux only. The npm package
ships it for linux-x64 and linux-arm64, and installs on any platform (the
browser side runs anywhere); `startServer`, `startRelay` and `npx wland`
fail with a clear error when asked to run the relay elsewhere.

It runs in two shapes:

```sh
# HTTP + WebSocket: serves a page and /ws on 127.0.0.1
wlandr [--port 8080] [--host ADDR] [--web-root DIR] [--dmabuf MODE]

# Stream: connects to one engine, no HTTP
wlandr --link SPEC [--buffers MODE] [--dmabuf MODE] [--link-on-demand [--link-timeout MS]]

# Version and features, on stdout (exit 0)
wlandr --version
```

`--link` can be:

- `fd:N` — an inherited, connected socket. The relay exits when it closes.
- `unix:PATH` — a unix socket. Reconnects when it drops.
- `vsock:CID:PORT` — AF_VSOCK, e.g. from a VM guest to its host. Reconnects.

`--link-on-demand` (with `unix:` or `vsock:`; refused otherwise) makes the
relay dial its link only when an app needs it, so it can start at boot,
before anything listens on the other end. At startup it binds the Wayland
socket and logs its usual `wayland socket:` line, but dials nothing. The
first app to connect starts a dial; apps connecting meanwhile wait for that
dial too, and are served once it connects, as usual. If the dial fails
(nothing listens, no vsock transport) or hasn't connected within
`--link-timeout` milliseconds (default 5000), every app waiting for it is
closed at once — its first round trip fails, as with a compositor that
hangs up — and the relay logs one line per app:

```
wayland client refused: no engine on link vsock:2:1023 (ConnectionRefused)
```

That line's text up to the link is stable, for an embedder to match; the
reason in parentheses is the dial's error (`ConnectionRefused`,
`NoVsockTransport`, `ConnectionTimedOut`, `FileNotFound` for a missing unix
socket, …). The relay stays up, and the next app dials again. A link that
connected stays up while apps come and go: the other end decides when it
ends (a page that wants to unload its compositor closes the link). When it
closes — a reload, a suspend, a vsock reset — its apps are closed as usual,
and the relay dials again only when an app connects (at once if one
already waits). With `--dmabuf`, a render node that doesn't exist yet at
startup is not fatal in this mode (a warning): it is looked up again before
each dial, and links dialed once it is found offer GPU buffers.

`--buffers` can be `copy` (default), `procfd` (same machine, for debugging)
or `kwshm` (VM guest ⇄ host page).

`--dmabuf readback[:NODE]` lets GPU apps in: their buffers are copied like
shared memory. `--dmabuf virtgpu[:NODE]` (a virtio-gpu guest, e.g. with
`--buffers kwshm`) names each buffer by its GPU resource instead, for a page
whose renderer holds it (the `gpu` option of `createWland`); NODE must be a
virtio_gpu render node, held open only while a GPU buffer exists. A page
without a `gpu` option doesn't offer GPU buffers to apps on such a relay,
so they render in software instead of showing blank windows. Both are off
by default, and experimental. Before each virtgpu frame the relay waits (up
to 100 ms) for the GPU to finish writing the buffer; `--no-fence-wait` skips
that wait, for a device that already delivers the GPU work to the page
before the frame (unkernel). It is refused without `--dmabuf virtgpu`.

`wlandr --version` prints two lines:

```
wlandr 0.1.0
features: http link:fd link:unix link:vsock buffers:copy buffers:procfd buffers:kwshm dmabuf:readback dmabuf:virtgpu no-fence-wait selection_cache xwayland link-on-demand
```

The first is the package version the binary was built from. The second
has one space-separated token per thing this build supports: `http` (the
HTTP server; absent from the `--link`-only build), each `--link` kind,
each `--buffers` and `--dmabuf` mode, `no-fence-wait`, `selection_cache`
(the page clipboard bridge), `xwayland` and `link-on-demand`. A token keeps its spelling once
listed and new ones are only added, so a script can test for a whole
token, e.g. `case " $(wlandr --version | sed -n 's/^features: //p') " in
*" dmabuf:virtgpu "*)`. Releases up to v0.1.0-261122-f36330a have no
`--version`: they print the usage and exit with status 1.

A relay for a VM guest, with no HTTP: each
[GitHub release](https://github.com/pithings/wland/releases) after
v0.1.0-261121-6b1a8a2 has
`wlandr-link-linux-arm64.tar.gz` and `wlandr-link-linux-x64.tar.gz`, a
`--link`-only build (about 300K, built with `-Dhttp=false` and
ReleaseSmall). Each holds one executable `wlandr`, static, with no libc,
built for the baseline CPU (ARMv8.0 or x86-64 v1). The full binaries
(`wlandr-linux-<arch>.tar.gz`, the ones the npm package ships) take the
same `--link` flags too, but they are twice the size.

```sh
tar -xzf wlandr-link-linux-arm64.tar.gz      # → ./wlandr
./wlandr --link vsock:2:PORT --buffers kwshm                   # shm apps, by handle
./wlandr --link vsock:2:PORT --buffers kwshm --dmabuf virtgpu  # + GPU apps, by resource
./wlandr --link vsock:2:PORT --buffers kwshm --link-on-demand   # started at boot: dials for the first app
```

`zig build release` builds all four into `zig-out/release/`.

## 🔒 Security

The server listens on `127.0.0.1` unless `--host` says otherwise. Whoever
holds the `/ws` session holds the desktop: they see every keystroke and the
clipboard. Only widen it (`--host 0.0.0.0` in a container) where something
else limits who can connect, such as a port published on loopback or a
trusted network.

Browser connections are accepted only from pages the server served itself
(the `Origin` must match the `Host`). If you put a proxy in front, forward
both headers as is.

Not covered: DNS rebinding, and other users on the same machine. There is no
authentication.

## ✅ What works

- **Apps** — foot, weston-terminal, nautilus (menus, popups, file drag and
  drop), and X11 apps like xterm through xwayland-satellite.
- **Windows** — move, resize, maximize, minimize and fullscreen. Popups close
  on an outside click and stay on screen near its edges (flipped, slid or
  shrunk as the app allows). Clicks on transparent parts fall through.
- **Input** — keyboard, pointer, wheel, cursor shapes and app-drawn cursors.
- **Pointer lock** — for games and 3D apps.
- **Text input** — dead keys, CJK and the emoji picker.
- **Clipboard** — `wl-copy`, `wl-paste`, copy/paste between apps,
  middle-click paste, and copy/paste with the page's clipboard (plain text;
  checked in headless Chromium and Firefox).
- **HiDPI** — integer and fractional scaling, tracked live.
- **Frame timing** — presentation feedback with the real refresh rate.
- **Performance** — up to 120 FPS on a Retina MacBook. Only changed
  rectangles are sent and drawn; an idle desktop costs nothing.

## 🚧 Known limits

- Browsers: Chromium is what the full browser E2E runs. Firefox 160 passes
  a smoke test here, headless (`node tools/firefox-smoke.ts`: windows paint,
  clicks and keys reach the app, shared-memory and GPU-resource paths);
  WebKit (Playwright's 27.2 build on Linux) passed the same checks by hand,
  WebGL presenter included. Safari itself has not run. Not seen in either:
  Pointer Lock, the browser's fullscreen, IME, cursor images at hi-dpi,
  and WebGL in Firefox (none headless here). WebKit reports every GPU as
  "Apple GPU", so the WebGL presenter is always picked there.
- Apps don't survive a reload or a dropped connection.
- The keyboard layout is fixed to US. Composed text still works.
- GPU apps only with `wlandr --dmabuf readback` or `virtgpu` (experimental;
  neither has run on real GPU hardware yet). Otherwise GL apps render in
  software.
- X11 apps need xwayland-satellite and Xwayland installed. They can't be
  maximized.
- Drag and drop works between wland apps, not with the host page.
- The page clipboard bridge carries plain text only, not the middle-click
  (primary) selection, and has not run in Safari. The macOS/iOS keyboard
  handling (Cmd+C/X/V as Ctrl chords, keys released when Cmd goes up) has
  not run on a Mac or an iPad in any browser: it follows the browsers'
  documented key events.
- Pointer lock needs a click to start. Esc or switching tabs ends it.
- Wland draws no window frames. Apps without their own titlebar can be
  moved with Alt+drag, but not resized, unless the page draws frames for
  them (`decorations: 'server'`).
- `wp_viewport` cropping is not supported yet.

## 🔧 Building from source

You need [Zig 0.16](https://ziglang.org/download/), [bun](https://bun.sh) and
Node ≥ 22.18.

```sh
zig build                                  # server, wasm core, test fixture
npm run build                              # everything the npm package ships
node lib/cli.ts                            # same as npx wland (serves dist/)
```

Tests:

```sh
zig build test                             # native unit tests
npm test                                   # zig + smoke + typecheck + Node tests
node tools/headless-e2e-test.ts            # apps through the relay, no browser
tools/run-poc.sh > /tmp/poc.log 2>&1       # browser E2E with Chromium
node tools/firefox-smoke.ts                # a smoke test in headless Firefox
```

The E2E tests use a small fixture app (`test/fixture/`) that stands in for
the real ones, so nothing else needs installing. Set `WLAND_E2E_APPS=real` to
test against real foot, nautilus and friends.

For live development, run `cd web && bun run dev`. It serves the demo page
with hot reload on `:5173` and starts the server for its Host source.

Where things live:

- `core/` — the compositor in Zig. Builds native (tests) and to wasm.
- `server/` — the relay.
- `lib/` — the npm package: client, engine, headless, Node API and CLI,
  and `index.html`, the page `npx wland` serves.
- `web/` — the demo page, fully in-page (not in the npm package).
- `protocol/` — Wayland XMLs and the STREAM spec.
- `tools/`, `test/` — test harness and fixtures.

## 📄 License

Built with ❤️ by [pi0](https://github.com/pi0). Published under [MPL-2.0 and MIT](LICENSE).
