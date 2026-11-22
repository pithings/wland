// startServer (lib/index.ts) with the real wlandr: the HTTP port and the
// wayland socket are both claimed exclusively, and given back at exit.
// Needs `zig build`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { serverBinary, startRelay, startServer } from '../lib/index.ts';
import type { ServerInfo } from '../lib/index.ts';

const stop = (info: ServerInfo) => new Promise<unknown>((done) => {
  info.process.once('exit', done);
  info.process.kill('SIGTERM');
});

test('startServer: port 0, exclusive port and socket, nothing left after SIGTERM', async () => {
  const runtimeDir = mkdtempSync('/tmp/wl-srv-');
  const quiet = { runtimeDir, onLog() {} };
  try {
    const a = await startServer({ ...quiet, port: 0 });
    try {
      assert.ok(a.port > 0, 'port 0 reports the port the kernel picked');
      assert.equal(a.url, `http://localhost:${a.port}`);
      assert.equal(a.display, 'wayland-0');
      assert.ok(existsSync(a.socketPath) && existsSync(`${a.socketPath}.lock`));
      assert.equal((await fetch(`${a.url}/`)).status < 500, true, 'it serves HTTP');

      // the same port: refused, not shared (no SO_REUSEPORT)
      await assert.rejects(startServer({ ...quiet, port: a.port }), /exited/);
      // the same socket name: refused, not stolen
      await assert.rejects(startServer({ ...quiet, port: 0, display: 'wayland-0' }), /exited/);
      // neither failed start left files of its own behind
      assert.deepEqual(readdirSync(runtimeDir).sort(), ['wayland-0', 'wayland-0.lock']);
    } finally {
      await stop(a);
    }
    assert.deepEqual(readdirSync(runtimeDir), [], 'socket and lock file removed at exit');
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
  }
});

test('startServer: host widens the listener; the URL stays one this machine can open', async () => {
  const runtimeDir = mkdtempSync('/tmp/wl-srv-');
  try {
    const a = await startServer({ runtimeDir, onLog() {}, port: 0, host: '0.0.0.0' });
    try {
      assert.ok(a.port > 0, 'the port is read off the log line whatever the address');
      assert.equal(a.url, `http://localhost:${a.port}`);
      assert.equal((await fetch(`http://127.0.0.1:${a.port}/`)).status < 500, true, 'reachable on loopback too');
    } finally {
      await stop(a);
    }
    // not an address of this machine (TEST-NET-1): the start fails
    await assert.rejects(startServer({ runtimeDir, onLog() {}, port: 0, host: '192.0.2.1' }), /exited/);
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
  }
});

test('startServer: the next free wayland-N while one is taken', async () => {
  const runtimeDir = mkdtempSync('/tmp/wl-srv-');
  const quiet = { runtimeDir, onLog() {}, port: 0 };
  try {
    const a = await startServer(quiet);
    const b = await startServer(quiet);
    try {
      assert.equal(a.display, 'wayland-0');
      assert.equal(b.display, 'wayland-1');
      assert.equal(b.socketPath, join(runtimeDir, 'wayland-1'));
      assert.notEqual(a.port, b.port);
    } finally {
      await Promise.all([stop(a), stop(b)]);
    }
    assert.deepEqual(readdirSync(runtimeDir), []);
  } finally {
    rmSync(runtimeDir, { recursive: true, force: true });
  }
});

test('the package installs on any platform; asking for the relay off Linux fails at run time, clearly', async () => {
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(pkg.os, undefined, 'no install-time "os" restriction (the browser side runs anywhere)');
  for (const [platform, arch] of [['darwin', 'arm64'], ['win32', 'x64'], ['freebsd', 'x64']]) {
    assert.throws(() => serverBinary(platform, arch), (e: Error) =>
      e.message.includes('Linux only') && e.message.includes(`${platform}-${arch}`) && e.message.includes('wland/client'));
  }
  assert.throws(() => serverBinary('linux', 'riscv64'), /no wlandr binary for linux-riscv64/);
  assert.ok(existsSync(serverBinary()), 'here (Linux, a checkout): the zig build output');
  // startServer / startRelay reject (not throw) with that message
  const real = Object.getOwnPropertyDescriptor(process, 'platform')!;
  Object.defineProperty(process, 'platform', { ...real, value: 'darwin' });
  try {
    const started = startServer({ port: 0, onLog() {} });
    const relay = startRelay({ onLog() {} });
    await assert.rejects(started, /Linux only/);
    await assert.rejects(relay, /Linux only/);
  } finally {
    Object.defineProperty(process, 'platform', real);
  }
});
