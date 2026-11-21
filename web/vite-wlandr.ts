// Dev only (`vite` serve): run the repo's wlandr next to the page so it can
// show real host apps (foot, nautilus, …) instead of the in-page ones.
//
//   /__wlandr/ws    proxied to wlandr's /ws (the page's "Host" source)
//   GET  /__wlandr  { ok, socket, display, runtimeDir, apps, error }
//   POST /__wlandr/run  { cmd: "foot -e htop" } → runApp (argv split on spaces)
//
// The server is the SDK's startServer (lib/index.ts): wlandr takes the first
// free $XDG_RUNTIME_DIR/wayland-N, so with wayland-0 a plain `foot` from any
// shell on the box finds it. One wlandr serves the whole vite process
// (globalThis), so a config reload keeps the socket name and the apps (vite
// builds the new server before closing the old one: a fresh wlandr would see
// the old one's socket and move to wayland-1).
//
// /run executes commands: it answers only requests whose Origin is the page
// itself (no CSRF from other sites), and only from loopback unless
// WLANDR_RUN_REMOTE=1 (for `vite --host` on a remote dev box: then anyone who
// can reach the dev server can run commands — as they can already type into
// a host terminal through the proxied /ws).
//
// Env: WLANDR_PORT, WLANDR_RUNTIME_DIR ($XDG_RUNTIME_DIR, else
// /tmp/wland-run), WLANDR_DISPLAY (first free wayland-N), WLANDR_RUN_REMOTE.
import type { ChildProcess } from 'node:child_process';
import { accessSync, constants } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { delimiter, join, resolve } from 'node:path';
import type { Logger, Plugin } from 'vite';
import { runApp, serverBinary, startServer } from '../lib/index.ts';
import type { ServerInfo } from '../lib/index.ts';

const repoRoot = resolve(import.meta.dirname, '..');
const RUN_REMOTE = process.env.WLANDR_RUN_REMOTE === '1';

// offered as one-click launchers when found on PATH (weston-flower: a
// client-drawn cursor surface; weston-constraints: pointer lock and
// confinement; weston-presentation-shm: presentation-time feedback;
// weston-fullscreen: set_fullscreen, its 'f' key)
const KNOWN_APPS = [
  'foot', 'weston-terminal', 'alacritty', 'kitty', 'nautilus', 'gnome-text-editor', 'gedit',
  'gnome-calculator', 'gtk4-demo', 'gtk3-demo', 'weston-flower', 'weston-simple-shm',
  'weston-constraints', 'weston-presentation-shm', 'weston-fullscreen', 'chromium',
];

function onPath(name: string): boolean {
  for (const dir of (process.env.PATH || '').split(delimiter)) {
    try { accessSync(join(dir, name), constants.X_OK); return true; } catch { /* next */ }
  }
  return false;
}

function prefixed(tag: string): (text: string) => void {
  let rest = '';
  return (text) => {
    const lines = (rest + text).split('\n');
    rest = lines.pop()!;
    for (const l of lines) process.stderr.write(`[${tag}] ${l}\n`);
  };
}

/** The request comes from the page itself (and this machine, by default). */
function trusted(req: IncomingMessage): boolean {
  const peer = req.socket.remoteAddress || '';
  if (!RUN_REMOTE && !['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(peer)) return false;
  const origin = req.headers.origin;
  if (!origin) return false;
  try { return new URL(origin).host === req.headers.host; } catch { return false; }
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.statusCode = status;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(body));
}

/** The vite process's one wlandr (see the top of the file). */
interface Relay {
  info?: ServerInfo;
  starting?: Promise<void>;
  error: string;
  /** The "host apps on …" hint went out for this `info`. */
  announced?: ServerInfo;
  apps: Set<ChildProcess>;
  /** The current dev server's logger (a reload brings a new one). */
  logger?: Logger;
}

const g = globalThis as { __wlandrServer?: Relay };

async function start(r: Relay): Promise<void> {
  try {
    serverBinary(); // throws with the `zig build` hint
    const info = await startServer({
      port: Number(process.env.WLANDR_PORT) || 0, // 0: the kernel picks
      webRoot: join(repoRoot, 'web/dist'),
      runtimeDir: process.env.WLANDR_RUNTIME_DIR,
      display: process.env.WLANDR_DISPLAY,
      onLog: prefixed('wlandr'),
    });
    r.info = info;
    r.error = '';
    info.process.once('exit', (code, signal) => {
      if (r.info !== info) return;
      r.info = undefined;
      r.error = `wlandr exited (${signal ?? `code ${code}`})`;
      r.logger?.warn(`[wlandr] ${r.error}`);
    });
    announce(r);
  } catch (e) {
    r.error = (e as Error).message;
    r.logger?.warn(`[wlandr] ${r.error}; the Host source is off`);
  }
}

/** Say where host apps go, once per wlandr, as soon as there's a logger
 *  (the first start finishes in config(), before configureServer). */
function announce(r: Relay) {
  const info = r.info;
  if (!info || !r.logger || r.announced === info) return;
  r.announced = info;
  const plain = info.display === 'wayland-0' && info.runtimeDir === process.env.XDG_RUNTIME_DIR && !process.env.WAYLAND_DISPLAY;
  r.logger.info(
    `[wlandr] host apps on ${info.socketPath}: pick "Host" in the page, or from a shell\n` +
    (plain ? '         foot   (GTK apps: node lib/cli.ts run nautilus — cairo renderer + session bus)'
      : `         XDG_RUNTIME_DIR=${info.runtimeDir} WAYLAND_DISPLAY=${info.display} foot`),
  );
}

export function wlandr(): Plugin {
  let r: Relay;
  return {
    name: 'wland:wlandr',
    apply: 'serve',
    async config() {
      if (!g.__wlandrServer) {
        const relay: Relay = { error: 'starting', apps: new Set() };
        g.__wlandrServer = relay;
        // vite exits through process.exit (SIGTERM, `q`); Ctrl-C reaches
        // wlandr and the apps directly (same process group)
        process.once('exit', () => {
          for (const a of relay.apps) a.kill();
          relay.info?.process.kill();
        });
      }
      r = g.__wlandrServer;
      // first run, or a crashed wlandr: (re)start it — a reload (`r` in the
      // vite CLI) brings it back
      if (!r.info && !r.starting) r.starting = start(r).finally(() => { r.starting = undefined; });
      // the proxy needs the port; with port 0 that's known once it's bound
      await r.starting;
      if (!r.info) return;
      return {
        server: {
          proxy: {
            // Host and Origin pass through unchanged: wlandr's same-origin
            // check on /ws (server.zig originAllowed) accepts them
            '/__wlandr/ws': { target: `http://127.0.0.1:${r.info.port}`, ws: true, rewrite: () => '/ws' },
          },
        },
      };
    },
    configureServer(server) {
      r.logger = server.config.logger;
      announce(r);
      server.middlewares.use('/__wlandr', (req, res, next) => {
        const url = req.url || '/';
        const info = r.info;
        if (req.method === 'GET' && (url === '/' || url === '')) {
          return json(res, 200, {
            ok: !!info,
            error: r.error,
            socket: info?.socketPath ?? '',
            runtimeDir: info?.runtimeDir ?? '',
            display: info?.display ?? '',
            apps: KNOWN_APPS.filter(onPath),
          });
        }
        if (req.method === 'POST' && url === '/run') {
          if (!trusted(req)) {
            return json(res, 403, { error: `refused: not a same-origin${RUN_REMOTE ? '' : ' loopback'} request${RUN_REMOTE ? '' : ' (remote: WLANDR_RUN_REMOTE=1)'}` });
          }
          if (!info) return json(res, 503, { error: r.error || 'wlandr is not up' });
          let body = '';
          req.on('data', (c: Buffer) => { body += c; });
          req.on('end', () => {
            let argv: string[];
            try { argv = String(JSON.parse(body).cmd ?? '').trim().split(/\s+/).filter(Boolean); } catch { argv = []; }
            if (!argv.length) return json(res, 400, { error: 'no command' });
            const tag = argv[0].split('/').pop()!;
            const child = runApp(info, argv, { cwd: process.env.HOME || repoRoot, stdio: ['ignore', 'pipe', 'pipe'] });
            r.apps.add(child);
            const log = prefixed(tag);
            child.stdout?.on('data', (c: Buffer) => log(String(c)));
            child.stderr?.on('data', (c: Buffer) => log(String(c)));
            child.once('error', (e) => r.logger?.warn(`[${tag}] ${e.message}`));
            child.once('exit', (code, signal) => {
              r.apps.delete(child);
              r.logger?.info(`[${tag}] exited (${signal ?? `code ${code}`})`);
            });
            json(res, 200, { pid: child.pid });
          });
          return;
        }
        next();
      });
    },
  };
}
