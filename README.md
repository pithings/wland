# 🪟 wland

**Wayland apps, composited in the browser.**

![How wland works: unmodified Wayland apps talk to the wlandr relay over a unix socket on a Linux host, VM guest or container; the relay keeps the file descriptors and streams the rest over a WebSocket, vsock or any byte stream to a compositor running as wasm in a browser tab](.github/how-it-works.svg)

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

A page reload disconnects every app, so the apps are started again after
one. An app you close stays closed until the next reload.

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

Each window also has `minimize()`, `restore()`, `setMaximized(on)` and
`setFullscreen(on)`.

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
  scale: 2,                   // pin the scale (default: follows devicePixelRatio)
  webgl: 'never',             // 'auto' | 'always' | 'never'
  browserFullscreen: true,    // fullscreen windows also go browser-fullscreen
  shortcuts: false,           // turn off Alt+F9/F10/F11
});
```

See [`lib/client.ts`](lib/client.ts) for every option.

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
`press('ControlLeft', 'KeyC')`, `scroll()` and more. See
[`lib/headless.ts`](lib/headless.ts).

### Build your own composition

`createWland` is four small modules glued together. You can use them one by
one, for example to draw your own window frames.

- **engine** — the compositor itself. Plain data in, plain data out. No DOM.
- **view** — turns events into canvases and window elements.
- **input** — turns DOM pointer and keyboard events into engine calls.
- **wm** — the window manager: move, resize, maximize, popups, drag and drop.

```js
import {
  createEngine, createWsLink, createView, watchOutput, createInput, createWindowManager,
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
const frame = (t) => { engine.tick(t); requestAnimationFrame(frame); };
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

The default wm expects the default mount. With your own frames, handle the
`move`, `resize`, `maximize`, `fullscreen` and `minimize` events yourself.

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

`open` and `read` may return promises, but sync is faster. The demo page in
`web/` runs this whole path in one tab. A small Node example lives in
[`test/support/handles-procfd.ts`](test/support/handles-procfd.ts).

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
of about 600K, with no dependencies. It runs on Linux only. The npm package
ships it for linux-x64 and linux-arm64.

It runs in two shapes:

```sh
# HTTP + WebSocket: serves a page and /ws on 127.0.0.1
wlandr [--port 8080] [--host ADDR] [--web-root DIR] [--dmabuf MODE]

# Stream: connects to one engine, no HTTP
wlandr --link SPEC [--buffers MODE] [--dmabuf MODE]
```

`--link` can be:

- `fd:N` — an inherited, connected socket. The relay exits when it closes.
- `unix:PATH` — a unix socket. Reconnects when it drops.
- `vsock:CID:PORT` — AF_VSOCK, e.g. from a VM guest to its host. Reconnects.

`--buffers` can be `copy` (default), `procfd` (same machine, for debugging)
or `kwshm` (VM guest ⇄ host page).

`--dmabuf readback[:NODE]` lets GPU apps in: their buffers are copied like
shared memory. It is off by default, and experimental.

A relay for a VM guest, with no HTTP:

```sh
zig build -Dtarget=aarch64-linux-musl -Dcpu=generic -Dhttp=false -Doptimize=ReleaseSmall -p out
out/bin/wlandr --link vsock:2:PORT --buffers kwshm
```

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
  on an outside click. Clicks on transparent parts fall through.
- **Input** — keyboard, pointer, wheel, cursor shapes and app-drawn cursors.
- **Pointer lock** — for games and 3D apps.
- **Text input** — dead keys, CJK and the emoji picker.
- **Clipboard** — `wl-copy`, `wl-paste`, copy/paste between apps, and
  middle-click paste.
- **HiDPI** — integer and fractional scaling, tracked live.
- **Frame timing** — presentation feedback with the real refresh rate.
- **Performance** — up to 120 FPS on a Retina MacBook. Only changed
  rectangles are sent and drawn; an idle desktop costs nothing.

## 🚧 Known limits

- Tested in Chromium only so far. Firefox and Safari are untested.
- Apps don't survive a reload or a dropped connection.
- The keyboard layout is fixed to US. Composed text still works.
- GPU apps only with `wlandr --dmabuf readback` (experimental). Otherwise GL
  apps render in software.
- X11 apps need xwayland-satellite and Xwayland installed. They can't be
  maximized.
- Drag and drop works between wland apps, not with the host page.
- Pointer lock needs a click to start. Esc or switching tabs ends it.
- No server-side decorations. Apps without their own titlebar can be moved
  with Alt+drag, but not resized.
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
