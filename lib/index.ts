import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { Duplex } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { brotliDecompressSync } from 'node:zlib';
import type { ByteStream } from './link-stream.ts';

const pkgRoot = fileURLToPath(new URL('..', import.meta.url));

/**
 * Path of the wlandr binary: a checkout's own `zig build` output first, then
 * the static build the npm package ships for this platform/arch. The package
 * carries it brotli-compressed next to this module
 * (`wlandr-<platform>-<arch>.br`); the first call unpacks it into the user's
 * cache directory, later calls (and later processes) reuse that file.
 */
export function serverBinary(): string {
  const local = join(pkgRoot, 'zig-out/bin/wlandr');
  if (existsSync(local)) return local;
  const packed = fileURLToPath(new URL(`./wlandr-${process.platform}-${process.arch}.br`, import.meta.url));
  if (existsSync(packed)) return unpack(packed);
  throw new Error(
    `no wlandr binary for ${process.platform}-${process.arch} (the server is ` +
    'Linux-only — it relays SCM_RIGHTS fds over unix sockets). In a checkout, run `zig build`.',
  );
}

let unpacked: string | undefined;

/** Unpack a shipped binary to `<cache>/wland/wlandr-<content hash>`. The name
 *  is keyed by content, so package upgrades never run a stale binary. */
function unpack(packed: string): string {
  if (unpacked) return unpacked;
  const data = readFileSync(packed);
  const name = `wlandr-${createHash('sha256').update(data).digest('hex').slice(0, 16)}`;
  const write = (dir: string): string => {
    const bin = join(dir, name);
    if (existsSync(bin)) return bin;
    // write + rename: a concurrent process never execs a half-written file
    const tmp = `${bin}.${process.pid}.tmp`;
    writeFileSync(tmp, brotliDecompressSync(data), { mode: 0o755 });
    chmodSync(tmp, 0o755); // the mode above is subject to umask
    renameSync(tmp, bin);
    return bin;
  };
  try {
    const dir = join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'wland');
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    return (unpacked = write(dir));
  } catch {
    // no writable cache (read-only home, sandbox): a private directory for
    // this process — never a fixed /tmp path another user could pre-fill
    return (unpacked = write(mkdtempSync(join(tmpdir(), 'wland-'))));
  }
}

export interface ServerOptions {
  /** HTTP port (default 8080; 0 = any free one, reported in ServerInfo.port).
   *  A port another process listens on fails the start. */
  port?: number;
  /** Address the HTTP server listens on (IPv4 or IPv6; default `127.0.0.1`).
   *  The session has no authentication — whoever reaches the port holds the
   *  desktop — so only widen it (`0.0.0.0` in a container) behind something
   *  that limits who can connect, like a port published on loopback. */
  host?: string;
  /** Directory served over HTTP; defaults to the compositor page bundled
   *  with this package. */
  webRoot?: string;
  /** Socket directory (default $XDG_RUNTIME_DIR ?? /tmp/wland-run). */
  runtimeDir?: string;
  /** Wayland socket name; the server fails rather than take one another
   *  compositor holds. Default: the first free `wayland-N` (usually
   *  wayland-0, where apps look with no WAYLAND_DISPLAY). The inherited
   *  $WAYLAND_DISPLAY is not used: in a desktop session it names the
   *  desktop's own socket. */
  display?: string;
  /** X11 apps through xwayland-satellite, which the server starts with the
   *  first X client: `true` if `xwayland-satellite` is on $PATH, `false`
   *  never, a string that binary. Default: `true`. */
  xwayland?: boolean | string;
  /** The server's log (its stderr), in chunks. Default: written to this
   *  process's stderr. */
  onLog?(text: string): void;
}

export interface ServerInfo {
  port: number;
  url: string;
  socketPath: string;
  runtimeDir: string;
  /** The socket name the server took (see ServerOptions.display). */
  display: string;
  /** The X display for X11 apps (`:0`), when the server claimed one (see
   *  the `xwayland` option): what DISPLAY should say. */
  xDisplay?: string;
  process: ChildProcess;
}

/** The host part of the page's URL: localhost for loopback or a wildcard
 *  address (reachable from here as localhost), else the address itself. */
function urlHost(host: string | undefined): string {
  if (!host || host === '0.0.0.0' || host === '::' || host === '::1' || host.startsWith('127.')) return 'localhost';
  return host.includes(':') ? `[${host}]` : host;
}

/** wlandr's ready line — `info: wayland socket: <path>`, logged once
 *  everything is bound — and the socket path it names. */
function readySocket(log: string): string | undefined {
  return /wayland socket: (\S+)\n/.exec(log)?.[1];
}

/** wlandr's `info: x11 display: :N` line, logged before the ready line. */
function loggedXDisplay(log: string): string | undefined {
  return /x11 display: (:\d+)/.exec(log)?.[1];
}

/** `--xwayland` for an `xwayland` option; nothing for wlandr's own default. */
function xwaylandArgs(option: boolean | string | undefined): string[] {
  if (option === undefined) return [];
  return ['--xwayland', option === true ? 'auto' : option === false ? 'off' : option];
}

/**
 * The X display of the server at `socketPath`, if it runs X11 apps: wlandr
 * leaves it in `<socket>.x11` (how `wland run`, a separate process, finds
 * DISPLAY). Only meaningful while that server is up.
 */
export function xDisplayOf(socketPath: string): string | undefined {
  try {
    return /^:\d+$/.exec(readFileSync(`${socketPath}.x11`, 'utf8').trim())?.[0];
  } catch {
    return undefined;
  }
}

/** wlandr's environment: XDG_RUNTIME_DIR set, and no inherited
 *  WAYLAND_DISPLAY (wlandr ignores it; this keeps the log honest). */
function relayEnv(runtimeDir: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env, XDG_RUNTIME_DIR: runtimeDir };
  delete env.WAYLAND_DISPLAY;
  return env;
}

/**
 * Start wlandr as a child process: an HTTP server on `port` serving the
 * browser compositor page (+ its /ws relay endpoint), and a wayland unix
 * socket at `<runtimeDir>/<display>` that unmodified wayland apps connect to.
 * The server's log goes to this process's stderr.
 *
 * Resolves once both sockets are bound; rejects if the server exits first
 * (port taken, bad socket dir). Stop it with `info.process.kill()`.
 */
export function startServer(options: ServerOptions = {}): Promise<ServerInfo> {
  const port = options.port ?? 8080;
  const webRoot = options.webRoot ?? join(pkgRoot, 'dist');
  const runtimeDir = options.runtimeDir ?? process.env.XDG_RUNTIME_DIR ?? '/tmp/wland-run';
  const onLog = options.onLog ?? ((text: string) => { process.stderr.write(text); });
  const bin = serverBinary();
  mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
  const args = ['--port', String(port), '--web-root', webRoot];
  if (options.host) args.push('--host', options.host);
  if (options.display) args.push('--display', options.display);
  args.push(...xwaylandArgs(options.xwayland));

  return new Promise<ServerInfo>((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ['ignore', 'inherit', 'pipe'], env: relayEnv(runtimeDir) });
    // logged only after both listeners are bound
    let ready = false;
    let seen = '';
    child.stderr.on('data', (chunk: Buffer) => {
      onLog(String(chunk));
      if (ready) return;
      seen = (seen + chunk).slice(-4096);
      const socketPath = readySocket(seen);
      if (!socketPath) return;
      ready = true;
      // the port it bound (asked for 0: the kernel's pick), logged before
      const bound = Number(/listening on http:\/\/\S+:(\d+)\n/.exec(seen)?.[1]) || port;
      resolve({
        port: bound,
        url: `http://${urlHost(options.host)}:${bound}`,
        socketPath,
        runtimeDir,
        display: basename(socketPath),
        xDisplay: loggedXDisplay(seen),
        process: child,
      });
    });
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (!ready) reject(new Error(`wlandr exited (${signal ?? `code ${code}`}) before listening`));
    });
  });
}

export interface RelayOptions {
  /** Socket directory. Default: a new private directory under the system
   *  temp dir, removed by `close()` — a relay of your own never touches a
   *  desktop session's (or another relay's) `wayland-0`. */
  runtimeDir?: string;
  /** Wayland socket name (default: the first free `wayland-N` — wayland-0
   *  in a directory of its own). */
  display?: string;
  /** X11 apps through xwayland-satellite, which the server starts with the
   *  first X client: `true` if `xwayland-satellite` is on $PATH, `false`
   *  never, a string that binary. Default: `false`. */
  xwayland?: boolean | string;
  /** The relay's log (its stderr), in chunks. Default: written to this
   *  process's stderr; pass `() => {}` to drop it. */
  onLog?(text: string): void;
}

export interface RelayInfo {
  /** The relay's end of the link, connected: pass it as `link` to
   *  createHeadless (`wland/headless`), or wrap it in createStreamLink
   *  (`wland/engine`) for an engine of your own. One engine only. */
  link: ByteStream;
  /** Environment for the apps: `spawn('foot', { env: { ...process.env, ...relay.env } })`. */
  env: Record<string, string>;
  socketPath: string;
  runtimeDir: string;
  display: string;
  /** The X display for X11 apps (`:0`), when the server claimed one (see
   *  the `xwayland` option): what DISPLAY should say. */
  xDisplay?: string;
  process: ChildProcess;
  /** Close the link — the relay exits with it, and its apps lose their
   *  compositor — and remove a runtime directory startRelay created.
   *  Resolves once the relay has exited. */
  close(): Promise<void>;
}

// AF_UNIX paths are at most 108 bytes with the NUL (sun_path)
const SOCKET_PATH_MAX = 107;

/**
 * Start wlandr as a child process with no HTTP server and no port: a wayland
 * unix socket at `<runtimeDir>/<display>` for unmodified apps, relayed over a
 * stream this process holds (the relay's `--link fd:3`, a socketpair) — the
 * shape for Node scripts and tests:
 *
 *     const relay = await startRelay();
 *     const hl = await createHeadless({ link: relay.link });
 *     spawn('foot', { env: { ...process.env, ...relay.env } });
 *     // ...
 *     hl.dispose(); await relay.close();
 *
 * Pixels travel in the stream (the copy backend). The relay lives exactly as
 * long as the link: it exits when the link closes, including when this
 * process dies. Resolves once the wayland socket is bound; rejects if the
 * relay exits first.
 */
export function startRelay(options: RelayOptions = {}): Promise<RelayInfo> {
  const onLog = options.onLog ?? ((text: string) => { process.stderr.write(text); });
  const bin = serverBinary();
  let ownDir: string | undefined;
  if (options.runtimeDir === undefined) {
    // $TMPDIR can be deep; the socket path cannot
    const fits = Buffer.byteLength(join(tmpdir(), 'wland-XXXXXX', options.display ?? 'wayland-NN.lock')) <= SOCKET_PATH_MAX;
    ownDir = mkdtempSync(join(fits ? tmpdir() : '/tmp', 'wland-'));
  } else mkdirSync(options.runtimeDir, { recursive: true, mode: 0o700 });
  const runtimeDir = ownDir ?? options.runtimeDir!;
  const removeDir = () => { if (ownDir) rmSync(ownDir, { recursive: true, force: true }); };
  const args = ['--link', 'fd:3'];
  if (options.display) args.push('--display', options.display);
  args.push(...xwaylandArgs(options.xwayland));

  return new Promise<RelayInfo>((resolve, reject) => {
    // fd 3: a 'pipe' is a connected unix stream socketpair, which is what
    // `--link fd:N` takes
    const child = spawn(bin, args, { stdio: ['ignore', 'inherit', 'pipe', 'pipe'], env: relayEnv(runtimeDir) });
    const sock = child.stdio[3] as Duplex;
    sock.on('error', () => { /* the relay went away; the stream reports it */ });
    const exited = new Promise<void>((done) => {
      child.once('exit', () => done());
      child.once('error', () => done());
    });
    // a script that exits without close() still leaves no directory behind
    process.once('exit', removeDir);
    void exited.then(() => {
      process.removeListener('exit', removeDir);
      removeDir();
    });

    // logged once the socket is bound
    let ready = false;
    let seen = '';
    child.stderr!.on('data', (chunk: Buffer) => {
      onLog(String(chunk));
      if (ready) return;
      seen = (seen + chunk).slice(-4096);
      const socketPath = readySocket(seen);
      if (!socketPath) return;
      ready = true;
      const display = basename(socketPath);
      const xDisplay = loggedXDisplay(seen);
      const { readable, writable } = Duplex.toWeb(sock);
      resolve({
        link: {
          readable: readable as ReadableStream<Uint8Array>,
          writable: writable as WritableStream<Uint8Array>,
          close: () => { sock.destroy(); },
        },
        env: appEnv({ runtimeDir, display, xDisplay }),
        socketPath,
        runtimeDir,
        display,
        xDisplay,
        process: child,
        close() {
          sock.destroy();
          return exited;
        },
      });
    });
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (!ready) reject(new Error(`wlandr exited (${signal ?? `code ${code}`}) before listening`));
    });
  });
}

/**
 * Environment for launching a wayland app against a running wland server or
 * relay (startRelay's `env` is this) —
 * merge over process.env. GTK apps additionally want a session dbus
 * (`wland run` wraps them in dbus-run-session when none is up).
 */
export function appEnv({ runtimeDir, display, xDisplay }: Pick<ServerInfo, 'runtimeDir' | 'display' | 'xDisplay'>): Record<string, string> {
  return {
    // X11 apps reach the server's xwayland-satellite; GTK stays on wayland
    ...(xDisplay ? { DISPLAY: xDisplay } : {}),
    XDG_RUNTIME_DIR: runtimeDir,
    WAYLAND_DISPLAY: display,
    // wland has no GPU client path: pin GTK to wayland + the cairo software
    // renderer; XDG_SESSION_TYPE quiets a nonfatal GTK complaint in containers
    GDK_BACKEND: 'wayland',
    GSK_RENDERER: 'cairo',
    XDG_SESSION_TYPE: 'wayland',
  };
}

export interface RunAppOptions extends Omit<SpawnOptions, 'env'> {
  /** Extra environment, over process.env and appEnv(). */
  env?: Record<string, string>;
}

/**
 * Launch a wayland app against a running server or relay (anything with
 * `runtimeDir` + `display`: ServerInfo, RelayInfo): appEnv() over
 * process.env, a session bus via dbus-run-session when none is up (GTK apps
 * refuse to start without one), and chromium's container flags. `wland run`
 * is this. `argv` is the command, not a shell line.
 */
export function runApp(
  target: Pick<ServerInfo, 'runtimeDir' | 'display' | 'xDisplay'>,
  argv: string[],
  options: RunAppOptions = {},
): ChildProcess {
  if (!argv.length) throw new Error('runApp: no command');
  let cmd = argv;
  if (/^(chromium|chrome|google-chrome)/.test(basename(argv[0]))) {
    // container traps that crash chromium: setuid sandbox helper, no DRM
    // render nodes, 64M default /dev/shm
    // (duplicated flags are harmless)
    cmd = [...cmd, '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'];
  }
  if (!process.env.DBUS_SESSION_BUS_ADDRESS && !options.env?.DBUS_SESSION_BUS_ADDRESS) {
    cmd = ['dbus-run-session', '--', ...cmd];
  }
  // an inherited DISPLAY is some other X server: apps reach X11 through this
  // server's display or not at all
  const { DISPLAY: _inherited, ...base } = process.env;
  const env: NodeJS.ProcessEnv = { ...base, ...appEnv(target), ...options.env };
  return spawn(cmd[0], cmd.slice(1), { ...options, env });
}
