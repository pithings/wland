#!/usr/bin/env node
// wland CLI:
//   wland [serve] [--port N] [--host ADDR] [--display NAME] [--runtime-dir DIR] [--xwayland MODE] [--web-root DIR]
//   wland run [--display NAME] <app> [args...]   launch a wayland app against the server
import { existsSync } from 'node:fs';
import { connect } from 'node:net';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { startServer, runApp, xDisplayOf, type ServerInfo } from './index.ts';

const HELP = `wland — a Wayland compositor that renders in your browser

usage:
  wland [serve] [options]     start the server, then open the printed URL
  wland run [--display NAME] <app> [args...]
                              launch a wayland app against the server
                              (e.g. wland run foot)

options (serve):
  --port N           HTTP port for the compositor page (default 8080)
  --host ADDR        address the page listens on (default 127.0.0.1). There is
                     no authentication: whoever reaches it gets the desktop
  --display NAME     wayland socket name; fails if another compositor has it
                     (default: the first free wayland-N, usually wayland-0)
  --runtime-dir DIR  socket directory (default $XDG_RUNTIME_DIR or /tmp/wland-run)
  --xwayland MODE    X11 apps through xwayland-satellite: auto (the default:
                     if it is installed), off, or the binary's path
  --web-root DIR     serve a different client build (advanced)

wland run finds the server like any wayland app does: $XDG_RUNTIME_DIR and
$WAYLAND_DISPLAY (default wayland-0), or --display.

The newest browser tab to open the page becomes the compositor; apps keep
running across a takeover only if they tolerate it (most do not — treat it
as one tab at a time).`;

const argv = process.argv.slice(2);
const cmd = argv[0] && !argv[0].startsWith('-') ? argv.shift() : 'serve';

if (cmd === 'serve') serve();
else if (cmd === 'run') run();
else if (cmd === 'help') console.log(HELP);
else {
  console.error(`wland: unknown command "${cmd}"\n\n${HELP}`);
  process.exit(2);
}

async function serve() {
  const { values } = parseArgs({
    args: argv,
    options: {
      port: { type: 'string' },
      host: { type: 'string' },
      display: { type: 'string' },
      'runtime-dir': { type: 'string' },
      'web-root': { type: 'string' },
      xwayland: { type: 'string' },
      help: { type: 'boolean', short: 'h' },
    },
  });
  if (values.help) return console.log(HELP);

  let info: ServerInfo;
  try {
    info = await startServer({
      port: values.port !== undefined ? Number(values.port) : undefined,
      host: values.host,
      display: values.display,
      runtimeDir: values['runtime-dir'],
      webRoot: values['web-root'],
      xwayland: values.xwayland === undefined || values.xwayland === 'auto' ? undefined : values.xwayland === 'off' ? false : values.xwayland,
    });
  } catch (err) {
    console.error(`wland: ${(err as Error).message}`);
    process.exit(1);
  }
  // apps find wayland-0 on their own, unless this shell points them elsewhere
  const plain = info.display === 'wayland-0' && !process.env.WAYLAND_DISPLAY &&
    info.runtimeDir === process.env.XDG_RUNTIME_DIR;
  const prefix = plain ? '' : `${info.runtimeDir === process.env.XDG_RUNTIME_DIR ? '' : `XDG_RUNTIME_DIR=${info.runtimeDir} `}WAYLAND_DISPLAY=${info.display} `;
  console.log(`
  compositor page:  ${info.url}   ← open this in a browser
  wayland socket:   ${info.socketPath}
  launch apps:      ${prefix}wland run foot     (any wayland app works${plain ? '; plain `foot` too' : ''})
${info.xDisplay ? `  X11 apps:         ${prefix}wland run xterm    (DISPLAY=${info.xDisplay}, via xwayland-satellite)\n` : ''}
  Ctrl-C stops the server.
`);
  // the child keeps the event loop alive; its exit is ours
  let stopping = false;
  const stop = (sig: NodeJS.Signals) => { stopping = true; info.process.kill(sig); };
  process.on('SIGINT', () => stop('SIGINT'));
  process.on('SIGTERM', () => stop('SIGTERM'));
  info.process.on('exit', (code) => process.exit(stopping ? 0 : code ?? 1));
}

async function run() {
  let display = process.env.WAYLAND_DISPLAY || 'wayland-0';
  if (argv[0] === '--display' && argv[1]) {
    display = argv[1];
    argv.splice(0, 2);
  }
  if (argv.length === 0 || argv[0] === '--help' || argv[0] === '-h') {
    console.log(HELP);
    process.exit(argv.length === 0 ? 2 : 0);
  }
  const runtimeDir = process.env.XDG_RUNTIME_DIR ?? '/tmp/wland-run';
  const socketPath = join(runtimeDir, display);

  // fail fast with a useful message instead of GTK's cryptic "Failed to open
  // display" (stale socket files linger after server exits — check liveness)
  const live = existsSync(socketPath) && await new Promise<boolean>((res) => {
    const c = connect(socketPath);
    c.once('connect', () => { c.destroy(); res(true); });
    c.once('error', () => res(false));
  });
  if (!live) {
    console.error(`wland run: no compositor listening at ${socketPath}`);
    console.error('  start one with: wland   (then open the printed URL in a browser)');
    process.exit(1);
  }

  const child = runApp({ runtimeDir, display, xDisplay: xDisplayOf(socketPath) }, argv, { stdio: 'inherit' });
  child.on('error', (err) => {
    console.error(`wland run: ${err.message}`);
    process.exit(1);
  });
  child.on('exit', (code, signal) => process.exit(signal ? 1 : code ?? 0));
}
