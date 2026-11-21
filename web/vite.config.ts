import { resolve } from 'node:path';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';
import { wlandr } from './vite-wlandr.ts';

const repoRoot = resolve(import.meta.dirname, '..');

// The demo runs entirely in the page: its Wayland clients, the relay and the
// shared memory are JS in this tab (src/session/sources.ts). No server, no
// /ws, no /api — except in dev, where wlandr() runs the repo's relay so the
// page can show real host apps (the "Host" source; vite-wlandr.ts).
export default defineConfig({
  plugins: [react(), tailwindcss(), wlandr()],
  // the page imports the lib as the `wland` package, straight from its
  // TypeScript source (lib/), not the obuild output: HMR in dev, and the page
  // build needs no `obuild` first
  resolve: {
    alias: [{ find: /^wland\/(client|engine|view|input|wm)$/, replacement: `${repoRoot}/lib/$1.ts` }],
  },
  server: {
    // the lib (the `wland` alias above) lives outside web/
    fs: { allow: [repoRoot] },
  },
});
