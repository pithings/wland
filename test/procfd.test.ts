// test/support/handles-procfd.ts against a real fd held by another process: open
// /proc/<pid>/fd/<fd>, read ranges at an offset, keep reading after the
// holder exits (the source holds its own fd), refuse other kinds. Linux only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { closeSync, mkdtempSync, openSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createProcfdSource } from './support/handles-procfd.ts';

test('procfd source reads a range of a file another process holds open', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'wland-procfd-'));
  const path = join(dir, 'pool');
  const data = new Uint8Array(20000).map((_, i) => (i * 7) & 0xff);
  writeFileSync(path, data);
  // the "relay": a child holding the file as its fd 3, as wlandr holds a pool fd
  const fd = openSync(path, 'r');
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)'], { stdio: ['ignore', 'ignore', 'ignore', fd] });
  closeSync(fd);
  rmSync(path); // only the child's fd keeps the file alive, like a memfd
  await new Promise((r) => child.once('spawn', r));
  try {
    const source = createProcfdSource();
    const offset = 4096;
    const token = source.open({ kind: 'procfd', pid: child.pid!, fd: 3, offset, size: 8000 });
    const dst = new Uint8Array(1000);
    source.read(token, 123, dst);
    assert.deepEqual(dst, data.subarray(offset + 123, offset + 1123));

    // the relay goes away: our own fd still reads
    child.kill();
    await new Promise((r) => child.once('exit', r));
    source.read(token, 0, dst);
    assert.deepEqual(dst, data.subarray(offset, offset + 1000));
    // past the end of the file: an error, which the engine turns into an
    // unpresented, ACKed commit
    assert.throws(() => source.read(token, 20000, new Uint8Array(8)), /end of file/);
    source.close(token);
    source.close(token); // never throws
  } finally {
    child.kill();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('procfd source refuses other handle kinds and missing fds', () => {
  const source = createProcfdSource();
  assert.throws(() => source.open({ kind: 'kwshm', id: 1, size: 4096 }), /kwshm/);
  assert.throws(() => source.open({ kind: 'procfd', pid: process.pid, fd: 99999, offset: 0, size: 1 }));
});
