// The WebSocket link: the engine's other end is a wlandr relaying for
// real unix-socket wayland clients (foot, nautilus, weston-*). Frames on the
// wire are protocol/STREAM.md.
//
// A link is these things (engine.ts `Link`):
//   start({onOpen, onMessage, onClose, onError})  begin; drive the callbacks
//   send(Uint8Array)                              engine → relay (an owned copy)
//   bufferedAmount                                bytes queued, for backpressure
//   close()                                       end for good (engine.dispose)
//
// onMessage receives an ArrayBuffer of one or more packed STREAM frames.
// WebSocket exists on pages, in Workers and in Node ≥ 22, so this module has
// no DOM dependency either.

import type { ClosableLink } from './engine.ts';

/** A Link over a WebSocket to a wlandr's /ws. Close code 4000 means
 *  another tab took the session over. close() closes the socket. */
export function createWsLink(url: string | URL): ClosableLink {
  let ws: WebSocket | undefined;
  let closed = false;
  return {
    start({ onOpen, onMessage, onClose, onError }) {
      if (closed) return;
      ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      ws.onopen = () => onOpen();
      ws.onerror = () => onError('connection error');
      // close code 4000 = kicked by a takeover: another tab claimed the session
      ws.onclose = (ev) => onClose({ takenOver: ev.code === 4000 });
      ws.onmessage = (ev: MessageEvent<ArrayBuffer>) => onMessage(ev.data);
    },
    send(bytes) {
      ws!.send(bytes);
    },
    // for good, and silently: no callback after this
    close() {
      closed = true;
      if (!ws) return;
      ws.onopen = ws.onmessage = ws.onerror = ws.onclose = null;
      ws.close();
    },
    get bufferedAmount() {
      return ws ? ws.bufferedAmount : 0;
    },
  };
}
