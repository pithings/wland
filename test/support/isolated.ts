// A cross-origin-isolated mirror of a web root's origin, for browser checks
// that need SharedArrayBuffer (handle-demo `sab=1`): every GET is fetched
// from `origin` and served with COOP: same-origin + COEP: require-corp, so
// the page's `crossOriginIsolated` is true (127.0.0.1 is a secure context).
// wlandr's own server sends neither header; pages served by it cannot make
// a SharedArrayBuffer. Used by tools/browser-e2e.ts and tools/firefox-smoke.ts.
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';

export interface IsolatedMirror {
  /** http://127.0.0.1:PORT */
  origin: string;
  close(): Promise<void>;
}

export async function isolatedMirror(origin: string, port = 0): Promise<IsolatedMirror> {
  const server = createServer(async (req, res) => {
    try {
      const up = await fetch(new URL(req.url || '/', origin), { method: req.method === 'HEAD' ? 'HEAD' : 'GET' });
      const body = req.method === 'HEAD' ? null : Buffer.from(await up.arrayBuffer());
      res.writeHead(up.status, {
        'content-type': up.headers.get('content-type') || 'application/octet-stream',
        'cache-control': 'no-store',
        'cross-origin-opener-policy': 'same-origin',
        'cross-origin-embedder-policy': 'require-corp',
      });
      res.end(body);
    } catch (e) {
      res.writeHead(502, { 'content-type': 'text/plain' });
      res.end(`isolated mirror: ${e}`);
    }
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve());
  });
  return {
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    close: () => new Promise<void>((resolve) => { server.closeAllConnections?.(); server.close(() => resolve()); }),
  };
}
