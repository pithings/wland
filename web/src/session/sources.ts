// Where a session's Wayland clients live. A source hands the engine its
// link (and, for the handle path, a buffer source); createSession() does not
// care which kind it gets. The shape is `Source` below.
//
// Two kinds: everything in this tab (createInPageSource), and — in dev only —
// real host apps behind the repo's wlandr, which vite runs next to the page
// (createHostSource, ../../vite-wlandr.ts).
import { createStreamLink, createWsLink } from 'wland/engine';
import type { HandleSource, Link } from 'wland/engine';
import type { AppModule } from '../wayland/app-types.ts';
import { createShm, createHandleSource } from '../wayland/kwshm.ts';
import type { DemoHandleSource } from '../wayland/kwshm.ts';
import { memoryLinks, streamPair } from '../wayland/links.ts';
import { createRelay } from '../wayland/relay.ts';
import type { Relay } from '../wayland/relay.ts';
import { launch } from '../wayland/toolkit.ts';
import type { Client, LaunchEnv } from '../wayland/toolkit.ts';

export interface Source {
  kind: string;                                // shown in the UI
  link: Link;                                  // wland/engine Link
  buffers?: HandleSource;                      // when COMMITs name handles
  spawn?(app: AppModule, env: LaunchEnv): Client; // sources that can run apps in-page
  stats?(): SourceStats;                       // counters for the inspector
  check?(): void;
}

/** The inspector's counters (createInPageSource's). */
export interface SourceStats {
  commits: number;
  acks: number;
  releases: number;
  handles: number;
  tokens: number;
  exports: number;
  reads: number;
  bytesRead: number;
}

export interface InPageSource extends Source {
  buffers: DemoHandleSource;
  relay: Relay;
  spawn(app: AppModule, env: LaunchEnv): Client;
  stats(): SourceStats;
  check(): void;
}

export interface InPageOptions {
  link?: 'stream' | 'memory';
  async?: boolean;
  onViolation?(what: string): void;
}

/** Apps, relay and shared memory all in this tab:
 *    apps (toolkit.ts) ⇄ relay.ts ⇄ link (stream|memory) ⇄ engine
 *    └ shm pools → kwshm exports ← HandleSource ┘ */
export function createInPageSource(
  { link = 'stream', async = false, onViolation = () => {} }: InPageOptions = {},
): InPageSource {
  const shm = createShm();
  const buffers = createHandleSource(shm, { async, violation: onViolation });
  let relayLink: Link, engineLink: Link;
  if (link === 'memory') ({ relay: relayLink, engine: engineLink } = memoryLinks());
  else {
    const pair = streamPair();
    relayLink = createStreamLink(pair.relay);
    engineLink = createStreamLink(pair.engine);
  }
  const relay = createRelay({ link: relayLink, shm, violation: onViolation });
  return {
    kind: link === 'memory' ? 'in-tab · direct link' : 'in-tab · byte-stream link',
    link: engineLink,
    buffers,
    relay,
    spawn: (app, env) => launch(app, relay, env),
    stats: () => ({
      commits: relay.stats.commits,
      acks: relay.stats.acks,
      releases: relay.stats.releases,
      handles: relay.stats.handles,
      tokens: buffers.stats.open,
      exports: shm.live,
      reads: buffers.stats.reads,
      bytesRead: buffers.stats.bytes,
    }),
    check: () => relay.check(),
  };
}

// --- host apps (dev only) ----------------------------------------------------

/** What vite-wlandr.ts reports at GET /__wlandr. */
export interface HostInfo {
  ok: boolean;
  error: string;
  socket: string;
  runtimeDir: string;
  display: string;
  /** Known apps found on the host's PATH. */
  apps: string[];
}

/** The dev server's wlandr, or null when there is none (a built page, or a
 *  vite without the plugin). */
export async function hostInfo(): Promise<HostInfo | null> {
  if (!import.meta.env.DEV) return null;
  try {
    const r = await fetch('/__wlandr');
    return r.ok && r.headers.get('content-type')?.includes('json') ? await r.json() as HostInfo : null;
  } catch {
    return null;
  }
}

/** Start a host app (argv split on spaces) against the dev wlandr. */
export async function runHostApp(cmd: string): Promise<void> {
  const r = await fetch('/__wlandr/run', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ cmd }),
  });
  if (!r.ok) throw new Error((await r.json().catch(() => null))?.error || `HTTP ${r.status}`);
}

/** Real apps on the host: unix socket ⇄ wlandr ⇄ WebSocket (copy buffers) ⇄
 *  engine. wlandr serves one engine: another tab connecting takes over, and
 *  a restart drops the apps' connections (most apps exit then). */
export function createHostSource(): Source {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  return { kind: 'host · wlandr over WebSocket', link: createWsLink(`${proto}://${location.host}/__wlandr/ws`) };
}
