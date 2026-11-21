// startRelay (lib/index.ts) with the real wlandr and apps: the relay on an
// inherited fd, wland/headless on the other end. Needs `zig build` (wlandr
// and wland-fixture: the apps are test/support/apps.ts's — fixtures, or with
// WLAND_E2E_APPS=real wayland-info / weston-simple-shm, skipped if missing).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHeadless } from '../lib/headless.ts';
import { startRelay, xDisplayOf } from '../lib/index.ts';
import { app, available } from './support/apps.ts';

async function until(cond: () => unknown, ms: number, what: string) {
  for (const end = Date.now() + ms; !cond();) {
    if (Date.now() > end) assert.fail(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}

test('startRelay: a private socket, a headless client on its link, gone on close', async () => {
  const relay = await startRelay({ onLog() {} });
  let hl;
  try {
    assert.ok(existsSync(relay.socketPath), 'the wayland socket is bound when it resolves');
    assert.ok(relay.socketPath.length <= 107);
    assert.equal(relay.env.XDG_RUNTIME_DIR, relay.runtimeDir);
    let opened = false;
    const errors: string[] = [];
    hl = await createHeadless({
      link: relay.link,
      onEvent(ev) {
        if (ev.type === 'open') opened = true;
        if (ev.type === 'error') errors.push(ev.detail);
      },
    });
    await until(() => opened, 5000, 'the link to open');
    const env = { ...process.env, ...relay.env };
    delete env.DISPLAY;

    const info = app('info'), shm = app('shm');
    if (available(info)) {
      // (async: the compositor serving the app is this event loop)
      const out = await new Promise<string>((ok, no) =>
        execFile(info.cmd, info.args, { env, timeout: 15000 }, (err, stdout) => (err ? no(err) : ok(stdout))));
      assert.match(out, /wl_compositor/);
      assert.match(out, /xdg_wm_base/);
    }
    if (available(shm)) {
      const app = spawn(shm.cmd, shm.args, { env, stdio: 'ignore' });
      try {
        await until(() => hl!.windows().length === 1, 10000, 'the app window');
        const shot = hl.screenshot();
        assert.ok(new Set(shot.data.subarray(0, 400000)).size > 4, 'the screenshot is not blank');
      } finally {
        app.kill();
      }
    }
    assert.deepEqual(errors, []);
  } finally {
    if (hl) hl.dispose();
    await relay.close();
  }
  assert.ok(relay.process.exitCode !== null || relay.process.signalCode !== null, 'the relay exited with the link');
  assert.ok(!existsSync(relay.runtimeDir), 'its runtime directory is removed');
});

test('startRelay: keeps a runtime directory it was given', async () => {
  const { mkdtempSync, rmSync } = await import('node:fs');
  const dir = mkdtempSync('/tmp/wl-rt-');
  try {
    const relay = await startRelay({ runtimeDir: dir, display: 'wl-own', onLog() {} });
    assert.equal(relay.socketPath, `${dir}/wl-own`);
    await relay.close();
    assert.ok(existsSync(dir));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('startRelay xwayland: an X display is claimed, satellite starts with the first X client', async () => {
  // a stand-in for xwayland-satellite: it records how it was started, then
  // lives until the relay goes (exec: the relay's death signal reaches sleep)
  const dir = mkdtempSync(join(tmpdir(), 'wland-fakesat-'));
  const out = join(dir, 'started');
  const fake = join(dir, 'xwayland-satellite');
  writeFileSync(fake, `#!/bin/sh
{
  echo "$@"
  echo "$WAYLAND_DISPLAY \${DISPLAY-unset}"
} > ${out}.tmp
[ -S /proc/$$/fd/3 ] && [ -S /proc/$$/fd/4 ] && echo sockets >> ${out}.tmp
ls /proc/$$/fd >> ${out}.tmp
mv ${out}.tmp ${out}
exec sleep 60
`);
  chmodSync(fake, 0o755);

  const relay = await startRelay({ xwayland: fake, onLog() {} });
  const x = relay.xDisplay!;
  const n = x?.slice(1);
  try {
    assert.match(x, /^:\d+$/, 'the X display is known when startRelay resolves');
    assert.equal(relay.env.DISPLAY, x);
    assert.equal(xDisplayOf(relay.socketPath), x, 'and left in <socket>.x11 for `wland run`');
    assert.ok(existsSync(`/tmp/.X${n}-lock`) && existsSync(`/tmp/.X11-unix/X${n}`));
    assert.ok(!existsSync(out), 'nothing runs before an X client connects');

    const client = connect(`/tmp/.X11-unix/X${n}`);
    client.on('error', () => {});
    await until(() => existsSync(out), 5000, 'satellite to start');
    const [args, env, socks, ...fds] = readFileSync(out, 'utf8').trim().split('\n');
    assert.equal(args, `${x} -listenfd 3 -listenfd 4`);
    assert.equal(env, `${relay.display} unset`, 'it is a client of this relay, with no X display of its own');
    assert.equal(socks, 'sockets', 'fds 3 and 4 are the listeners');
    // (the shell keeps its script open at 10 or 255)
    assert.deepEqual(fds.filter((fd) => Number(fd) < 10), ['0', '1', '2', '3', '4'], 'and it inherits nothing else');
    client.destroy();
  } finally {
    await relay.close();
    rmSync(dir, { recursive: true, force: true });
  }
  assert.ok(!existsSync(`/tmp/.X${n}-lock`) && !existsSync(`/tmp/.X11-unix/X${n}`), 'the X display is given back');
});

test('startRelay: no X display unless asked', async () => {
  const relay = await startRelay({ onLog() {} });
  try {
    assert.equal(relay.xDisplay, undefined);
    assert.equal(relay.env.DISPLAY, undefined);
    assert.equal(xDisplayOf(relay.socketPath), undefined);
  } finally {
    await relay.close();
  }
});
