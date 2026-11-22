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

import type { ClosableLink, LinkCallbacks } from './engine.ts';

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

/** Reconnect delays (ms): the first retry, the cap (doubling between). */
const RETRY_FIRST = 500, RETRY_MAX = 10_000;

/** `link`, started again after it closes while `wanted()` says so (it is
 *  asked at each close) — never after a takeover close (another tab has
 *  the session) nor after close(). Retries back off from 0.5 s, doubling
 *  to 10 s, and start over at 0.5 s once a link opens. For links whose
 *  start() may be called again after a close (createWsLink: a new
 *  WebSocket each time). createWland wraps its default link in it so a
 *  session link (Engine.session(): the apps live on in the relay) is
 *  dialled again after a drop — the relay restarting, a network blip —
 *  and is sent the scene again. */
export function reconnecting(link: ClosableLink, wanted: () => boolean): ClosableLink {
  let cb: LinkCallbacks | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let delay = 0;
  let closed = false;
  const relay: LinkCallbacks = {
    onOpen() { delay = 0; cb!.onOpen(); },
    onMessage: (data) => cb!.onMessage(data),
    onError: (detail) => cb!.onError(detail),
    onClose(info) {
      cb!.onClose(info);
      if (closed || info.takenOver || !wanted()) return;
      delay = Math.min(delay ? delay * 2 : RETRY_FIRST, RETRY_MAX);
      timer = setTimeout(() => {
        timer = undefined;
        if (!closed) link.start(relay);
      }, delay);
    },
  };
  return {
    start(callbacks) {
      if (closed) return;
      cb = callbacks;
      link.start(relay);
    },
    send: (bytes) => link.send(bytes),
    get bufferedAmount() { return link.bufferedAmount; },
    close() {
      closed = true;
      clearTimeout(timer);
      link.close();
    },
  };
}
