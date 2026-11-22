// wlandr --link unix:… --link-on-demand: the real relay, dialing its link
// only when an app connects, ⇄ wland/headless on a unix listener here (the
// page side, as unkernel's vsock listener is). Needs `zig build` (wlandr and
// wland-fixture; the app is test/support/apps.ts's `info`: the fixture, or
// wayland-info with WLAND_E2E_APPS=real, skipped if missing).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawn, type ChildProcessByStdio } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer, type Server, type Socket } from 'node:net';
import { Duplex, type Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { createHeadless } from '../lib/headless.ts';
import type { ByteStream } from '../lib/engine.ts';
import { app, available } from './support/apps.ts';

// WLAND_E2E_RELAY overrides the relay command (split on spaces), as in
// tools/relay-e2e-test.ts: e.g. the aarch64 guest build under qemu-user
const RELAY = (process.env.WLAND_E2E_RELAY || fileURLToPath(new URL('../zig-out/bin/wlandr', import.meta.url))).split(' ');
const REFUSED = 'wayland client refused: no engine on link '; // documented: README, usage text

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until(cond: () => unknown, ms: number, what: string) {
  for (const end = Date.now() + ms; !cond();) {
    if (Date.now() > end) assert.fail(`timed out waiting for ${what}`);
    await sleep(20);
  }
}

const info = app('info');

test('--link-on-demand: no dial before an app; a failed dial refuses the app at once; the link is kept, and redialed after a drop only for the next app', { skip: !available(info) && `${info.name} is not installed` }, async () => {
  const dir = mkdtempSync('/tmp/wl-od-');
  const linkPath = `${dir}/link`;
  const env: NodeJS.ProcessEnv = { ...process.env, XDG_RUNTIME_DIR: dir, WAYLAND_DISPLAY: 'wl-od' };
  delete env.DISPLAY;

  // the page side: every connection the relay makes, whichever listener took it
  const accepted: Socket[] = [];
  const waiting: ((s: Socket) => void)[] = [];
  let dials = 0;
  let current: Socket | null = null;
  const listen = () => new Promise<Server>((ok, no) => {
    const srv = createServer((sock) => {
      dials++;
      current = sock;
      const w = waiting.shift();
      if (w) w(sock); else accepted.push(sock);
    });
    srv.listen(linkPath, () => ok(srv)).once('error', no);
  });
  async function* connections(): AsyncGenerator<ByteStream> {
    for (;;) {
      const sock = accepted.shift() ?? await new Promise<Socket>((r) => waiting.push(r));
      yield { ...(Duplex.toWeb(sock) as unknown as ByteStream), close: () => sock.destroy() };
    }
  }
  const runInfo = () => new Promise<{ ok: boolean; stdout: string; stderr: string; ms: number }>((resolve) => {
    const t0 = Date.now();
    execFile(info.cmd, info.args, { env: { ...env, ...info.env }, timeout: 15000 }, (err, stdout, stderr) =>
      resolve({ ok: !err, stdout, stderr, ms: Date.now() - t0 }));
  });

  let srv = await listen();
  const log: string[] = [];
  const relay: ChildProcessByStdio<null, null, Readable> = spawn(RELAY[0],
    [...RELAY.slice(1), '--link', `unix:${linkPath}`, '--link-on-demand', '--link-timeout', '1500', '--display', 'wl-od'],
    { env, stdio: ['ignore', 'ignore', 'pipe'] });
  let partial = '';
  relay.stderr.on('data', (c: Buffer) => {
    const lines = (partial + c).split('\n');
    partial = lines.pop()!;
    log.push(...lines);
  });
  const since = (mark: number) => log.slice(mark).join('\n');
  let hl: Awaited<ReturnType<typeof createHeadless>> | undefined;
  try {
    await until(() => log.some((l) => l.includes('wayland socket:')), 5000, 'the relay ready line');
    assert.ok(log.some((l) => l.includes(`link unix:${linkPath}: on demand`)), 'it says it dials on demand');
    await sleep(500);
    assert.equal(dials, 0, 'no dial before an app connects');

    let opens = 0, closes = 0;
    const errors: string[] = [];
    hl = await createHeadless({
      link: connections(),
      onEvent(ev) {
        if (ev.type === 'open') opens++;
        if (ev.type === 'close') closes++;
        if (ev.type === 'error') errors.push(ev.detail);
      },
    });

    // the first app dials; it is served once the engine is there
    const first = await runInfo();
    assert.ok(first.ok, `the first app is served (${first.stderr.trim()})`);
    assert.match(first.stdout, /'wl_compositor'/);
    assert.equal(dials, 1);
    assert.equal(opens, 1);

    // the link stays up between apps: no new dial
    const second = await runInfo();
    assert.ok(second.ok && /'xdg_wm_base'/.test(second.stdout), 'the next app uses the same link');
    assert.equal(dials, 1, 'no dial while the link is up');

    // the page drops the link with no app connected: the relay idles
    let mark = log.length;
    current!.destroy();
    await until(() => closes === 1, 3000, 'the engine to see the link close');
    await until(() => since(mark).includes('closed; dialing again for the next app'), 3000, 'the relay to log the drop');
    await sleep(800);
    assert.equal(dials, 1, 'no redial after a drop while no app waits');
    const third = await runInfo();
    assert.ok(third.ok, `the next app redials and is served (${third.stderr.trim()})`);
    assert.equal(dials, 2);
    assert.equal(opens, 2);

    // nothing listens: the app is closed at once, the relay says why and stays up
    current!.destroy();
    await until(() => closes === 2, 3000, 'the engine to see the link close');
    await new Promise<void>((r) => srv.close(() => r())); // (removes the socket file)
    mark = log.length;
    const refused = await runInfo();
    assert.ok(!refused.ok, 'the app fails');
    assert.ok(refused.ms < 1500, `promptly, not after the dial timeout (${refused.ms} ms)`);
    assert.ok(since(mark).includes(`${REFUSED}unix:${linkPath} (FileNotFound)`), `the refusal line is logged:\n${since(mark)}`);
    assert.equal(relay.exitCode, null, 'the relay is still running');
    assert.equal(relay.signalCode, null);
    // ...and again: each app gets its own try
    mark = log.length;
    assert.ok(!(await runInfo()).ok);
    assert.equal(since(mark).split(REFUSED).length - 1, 1, 'one refusal line per refused app');

    // a listener again: the next app gets through
    srv = await listen();
    const back = await runInfo();
    assert.ok(back.ok && /'wl_compositor'/.test(back.stdout), `served once a listener exists (${back.stderr.trim()})`);
    assert.equal(dials, 3);
    assert.equal(opens, 3);
    assert.ok(errors.every((e) => /aborted|reset/i.test(e)), `only the drops' own errors (${errors.join('; ')})`);
  } finally {
    hl?.dispose();
    relay.kill();
    srv.close();
    for (const s of accepted) s.destroy();
    rmSync(dir, { recursive: true, force: true });
  }
});
