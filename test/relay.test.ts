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
import { app, available, realApps } from './support/apps.ts';

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

test('startRelay lodpi: apps on <display>-lodpi are shown scale 1 on a scale-2 page, the others scale 2', async () => {
  const relay = await startRelay({ lodpi: true, onLog() {} });
  let hl;
  try {
    assert.equal(relay.lodpiDisplay, `${relay.display}-lodpi`);
    assert.ok(existsSync(join(relay.runtimeDir, relay.lodpiDisplay!)), 'bound when startRelay resolves');
    let opened = false;
    const h = hl = await createHeadless({ link: relay.link, scale: 2, onEvent(ev) { if (ev.type === 'open') opened = true; } });
    await until(() => opened, 5000, 'the link to open');
    // the fixture draws at its preferred_buffer_scale (real weston-fullscreen
    // doesn't follow it)
    const full = app('fullscreen');
    if (realApps || !available(full)) return;
    const env = { ...process.env, ...relay.env, ...full.env };
    delete env.DISPLAY;
    const crisp = spawn(full.cmd, full.args, { env, stdio: 'ignore' });
    const soft = spawn(full.cmd, full.args, { env: { ...env, WAYLAND_DISPLAY: relay.lodpiDisplay! }, stdio: 'ignore' });
    try {
      const tops = () => h.windows().map((w) => h.surfaces().find((s) => s.conn === w.conn && s.surface === w.surface)!).filter((s) => s?.width > 0);
      await until(() => tops().length === 2, 10000, 'both windows');
      const [a, b] = tops().sort((x, y) => y.width - x.width);
      // same logical size; the lodpi one's buffer is 1:1, the page upscales it
      assert.deepEqual([a.width, a.height, a.logicalWidth, a.logicalHeight], [800, 600, 400, 300]);
      assert.deepEqual([b.width, b.height, b.logicalWidth, b.logicalHeight], [400, 300, 400, 300]);
    } finally {
      crisp.kill();
      soft.kill();
    }
  } finally {
    if (hl) hl.dispose();
    await relay.close();
  }
  assert.ok(!existsSync(relay.runtimeDir));
});

test('startRelay xwayland + lodpi: satellite connects to the lodpi socket; one that dies at startup refuses its X client and starts again for the next', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'wland-fakesat-'));
  const out = join(dir, 'started');
  const fake = join(dir, 'xwayland-satellite');
  // no Xwayland: it records how it was run, then exits 127 at once
  writeFileSync(fake, `#!/bin/sh\necho "$WAYLAND_DISPLAY" >> ${out}\nexit 127\n`);
  chmodSync(fake, 0o755);
  let log = '';
  const relay = await startRelay({ xwayland: fake, lodpi: true, onLog(t) { log += t; } });
  const n = relay.xDisplay!.slice(1);
  const starts = () => (existsSync(out) ? readFileSync(out, 'utf8').trim().split('\n') : []);
  // an X client: resolves when the relay refuses it (EOF)
  const refused = () => new Promise<void>((done) => {
    const c = connect(`/tmp/.X11-unix/X${n}`);
    c.on('error', () => done());
    c.on('close', () => done());
    c.resume();
  });
  try {
    await refused();
    assert.deepEqual(starts(), [relay.lodpiDisplay], 'started once, on the lodpi socket');
    await until(() => /refused 1 waiting X client/.test(log), 5000, 'the refusal to be logged');
    assert.match(log, /exited at startup \(code 127\): is Xwayland installed\?/);
    await refused();
    await refused();
    await until(() => starts().length === 3, 5000, 'a start per client');
    assert.ok(existsSync(`/tmp/.X11-unix/X${n}`), 'X stays on');
  } finally {
    await relay.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('startRelay xwaylandDisplay: exactly that X display; taken by a live server, no X at all (no other number)', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'wland-fakesat-'));
  const fake = join(dir, 'xwayland-satellite');
  writeFileSync(fake, '#!/bin/sh\nexec sleep 60\n');
  chmodSync(fake, 0o755);
  const free = (n: number) => !existsSync(`/tmp/.X${n}-lock`) && !existsSync(`/tmp/.X11-unix/X${n}`);
  let n = 40;
  while (!free(n)) n++;
  let log = '';
  const a = await startRelay({ xwayland: fake, xwaylandDisplay: n, onLog() {} });
  try {
    assert.equal(a.xDisplay, `:${n}`);
    assert.equal(xDisplayOf(a.socketPath), `:${n}`);
    const b = await startRelay({ xwayland: fake, xwaylandDisplay: n, onLog(t) { log += t; } });
    try {
      assert.equal(b.xDisplay, undefined, 'no fallback to another display');
      assert.equal(xDisplayOf(b.socketPath), undefined);
      assert.match(log, new RegExp(`display :${n} belongs to a live X server`));
    } finally {
      await b.close();
    }
    assert.ok(existsSync(`/tmp/.X11-unix/X${n}`), "the second relay left the first's display alone");
  } finally {
    await a.close();
    rmSync(dir, { recursive: true, force: true });
  }
  assert.ok(free(n), 'given back');
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
