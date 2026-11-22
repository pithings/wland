// test/support/apps.ts: every real app an E2E starts runs in a throwaway
// home — no shell history or readline bindings of the developer's (an
// inputrc binding PgUp to history search once rewrote a typed line from the
// previous run's saved one, and each run appended to ~/.bash_history), no
// dotfile read or written.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';

const specs = (env: Record<string, string>): Promise<{ specs: { role: string; env: Record<string, string> }[]; home: string }> =>
  new Promise((resolve, reject) => {
    const code = `import('./test/support/apps.ts').then((m) => {
      const roles = ['info', 'shm', 'presentation', 'copy', 'paste', 'cursor', 'constraints', 'relative', 'term', 'files', 'fullscreen', 'dmabuf'];
      const specs = roles.map((r) => m.app(r));
      console.log(JSON.stringify({ specs, home: m.realApps ? m.appHome().HOME : '' }));
    })`;
    execFile(process.execPath, ['-e', code], { cwd: new URL('..', import.meta.url), env: { ...process.env, ...env } }, (err, out) => {
      if (err) reject(err); else resolve(JSON.parse(out));
    });
  });

test('real apps get a home of their own: HOME and the XDG dirs in a temp dir (removed at exit), no history file, no inputrc', async () => {
  const { specs: real, home } = await specs({ WLAND_E2E_APPS: 'real' });
  assert.ok(home && home !== homedir() && !home.startsWith(homedir() + '/'), home);
  assert.ok(!existsSync(home), 'removed when the process exited');
  for (const s of real) {
    assert.equal(s.env.HOME, home, s.role);
    for (const k of ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME']) assert.ok(s.env[k].startsWith(`${home}/`), `${s.role} ${k}`);
    assert.equal(s.env.HISTFILE, '/dev/null', s.role);
    assert.equal(s.env.INPUTRC, '/dev/null', s.role);
    // not the developer's session bus or dconf (a driver's own bus overrides it)
    assert.equal(s.env.GSETTINGS_BACKEND, 'keyfile', s.role);
    assert.equal(s.env.DBUS_SESSION_BUS_ADDRESS, `unix:path=${home}/no-session-bus`, s.role);
  }
  // WLAND_E2E_HOME (run-poc's, shared with its bun driver) is used as is, and left
  const given = mkdtempSync(join(tmpdir(), 'wland-apps-test-'));
  try {
    const { specs: shared } = await specs({ WLAND_E2E_APPS: 'real', WLAND_E2E_HOME: given });
    assert.equal(shared.find((s) => s.role === 'term')!.env.HOME, given);
    assert.ok(existsSync(`${given}/.config`), 'left for its owner');
  } finally { rmSync(given, { recursive: true, force: true }); }
  // fixtures read nothing: no home made
  const { specs: fixtures } = await specs({ WLAND_E2E_APPS: '' });
  assert.ok(fixtures.every((s) => !s.env.HOME));
});

test('the throwaway home is removed when the driver is stopped by SIGINT or SIGTERM too (and it still dies of the signal)', async () => {
  for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    const code = `import('./test/support/apps.ts').then((m) => { console.log(m.appHome().HOME); setInterval(() => {}, 1000); })`;
    const p = spawn(process.execPath, ['-e', code], { cwd: new URL('..', import.meta.url), env: { ...process.env, WLAND_E2E_APPS: 'real' }, stdio: ['ignore', 'pipe', 'inherit'] });
    const home = await new Promise<string>((resolve) => p.stdout!.once('data', (d) => resolve(String(d).trim())));
    assert.ok(existsSync(home), home);
    const exited = new Promise<string | null>((resolve) => p.once('exit', (_code, signal) => resolve(signal)));
    p.kill(sig);
    assert.equal(await exited, sig, 'killed by the signal, as without the handler');
    assert.ok(!existsSync(home), `${sig}: removed`);
  }
});
