import { execFileSync } from 'node:child_process';
import { copyFile, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { brotliCompressSync } from 'node:zlib';
import { defineBuildConfig } from 'obuild/config';

// `obuild` (npm run build) builds the whole package:
//  1. start: the zig builds — the native wlandr and the core wasm (which
//     lands in lib/), plus `zig build release`: the static linux x64/arm64
//     wlandr binaries (zig-out/release/). The package ships the full ones
//     (wlandr-linux-<arch>); the --link-only guest build next to them
//     (wlandr-link-linux-<arch>) goes to the GitHub release only: nothing
//     in the package runs it (`npx wland` needs HTTP; `startRelay` runs
//     the full one with --link fd:3), and a guest image fetches
//     its tarball.
//  2. lib/ → dist/ file by file (oxc transform + isolated declarations), so
//     dist/engine.mjs finds wland.wasm next to itself via
//     import.meta.url exactly as lib/engine.ts does.
//  3. end: the wasm and the release binaries go into dist/, the binaries
//     brotli-compressed (wlandr-linux-<arch>.br, ~135K each instead of
//     ~500K); lib/index.ts `serverBinary()` unpacks the one it needs.
//
// lib/index.html (the page `npx wland` serves) passes through to dist/ as
// is: wlandr's web root is dist/ itself, the page imports ./client.mjs.
// web/ (the demo) is not part of the package.
//
// The wasm is copied by hand: transform mode passes other files through as
// UTF-8 text (obuild 0.4.45), which mangles binaries.
const WASM = 'wland.wasm';
const BINARIES = ['wlandr-linux-x64', 'wlandr-linux-arm64'];

const sh = (cwd: string, cmd: string, ...args: string[]) => {
  console.log(`$ ${[cmd, ...args].join(' ')}`);
  execFileSync(cmd, args, { cwd, stdio: 'inherit' });
};

export default defineBuildConfig({
  entries: [{ type: 'transform', input: './lib', outDir: './dist', filter: (path) => path !== WASM }],
  hooks: {
    start(ctx) {
      const root = ctx.pkgDir;
      sh(root, 'zig', 'build');
      sh(root, 'zig', 'build', 'release');
    },
    async end(ctx) {
      const dist = join(ctx.pkgDir, 'dist');
      await copyFile(join(ctx.pkgDir, 'lib', WASM), join(dist, WASM));
      for (const name of BINARIES) {
        const bin = await readFile(join(ctx.pkgDir, 'zig-out/release', name));
        await writeFile(join(dist, `${name}.br`), brotliCompressSync(bin));
      }
    },
  },
});
