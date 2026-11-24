// wland drag-and-drop bridge, inbound: an HTML drag from the host page,
// another tab or the OS, over the desktop, is a Wayland drag the app under
// the pointer receives as any other (wl_data_device enter / motion / leave /
// drop, wl_data_offer.receive). createWland wires it in unless `dnd: false`;
// an embedder composing the parts itself creates it with its engine, view
// and input and feeds `handle` every engine event. wland/headless drives the
// same engine calls from a script (Headless.dragIn / drop).
//
// What crosses: text/plain (as the UTF-8 types the clipboard bridge offers,
// TEXT_MIMES), text/html and text/uri-list (a dragged link), and dropped
// files (DropPlan):
// - with the embedder's `files` hook: offered as text/uri-list (from the
//   drag's start: its items say there are files); at the drop the hook gets
//   the File objects, puts them where the apps can read them (an upload, a
//   shared mount, a guest's filesystem — not wland's business) and returns
//   their file:// URIs (or absolute paths); those are the uri-list. A drag
//   carrying a text/uri-list of its own (an image dragged from a web page:
//   its URL) keeps that one, and the hook is not called.
// - without one: each file type the drag shows (DataTransferItem.type) is
//   offered as itself, its content the first dropped file of that type
//   within the size cap (sizes are known only at the drop). Files with no
//   type, or none that fits, give nothing; a drop with nothing at all to
//   hand over is cancelled. No text/uri-list is made up (no path exists).
// Files' bytes (File.arrayBuffer) and the hook's answer come after the drop
// event, so such a drop is made at once and its data follows
// (dragDrop(true), then dragData): the app's read waits for it, bounded by
// `filesTimeout` (then it reads what is there, the files part empty); a
// hook that rejects or returns null gives no uri-list (the read ends empty).
// File drags offer copy only (a move would have the source delete them).
//
// The browser shows a drag's types from its dragenter on, its data only at
// the drop. So the drag begins (Engine.dragBegin) with the types, the app
// under the pointer is told it hovers (dragMotion per dragover; its
// accept/set_actions become dragAction(): the dropEffect the dragover
// answers), and at the drop the data is read, handed over (dragData) and
// the drop made (dragDrop) — an app that read early waits for it in the
// core, never past the drag. While a drag is over the desktop it holds a
// pointerless input grab (the app under the pointer gets its leave, no
// pointer input is forwarded), ended at the drop — the pointer entered
// where it fell — or a cancel: the drag leaving the desktop (dragleave to
// outside it, or out of the window), the window's blur, the page's own
// dragend, a pointer press (the browser's drag is over), 2 s with no
// dragover (browsers send one at least every 350 ms while hovering), the
// link closing.
//
// It needs a relay that writes the embedder's bytes into an app's pipe
// (Engine.selectionBridged(): its FEATURE selection_cache): without one no
// drag starts (one log line), as with `dnd: false`; drops on the desktop
// are refused either way, so the page never navigates to a dropped link.

import { DND_COPY, DND_MOVE, TEXT_MIMES, type Engine, type Event as WlandEvent } from './engine.ts';
import type { Input, PointerGrab } from './input.ts';
import type { View } from './view.ts';

/** The embedder's way to drop files into apps (DndBridgeOptions.files):
 *  called at the drop with the dropped files; put them where the apps can
 *  read them and return their `file://` URIs (or absolute paths), offered
 *  to the app as text/uri-list — null, [] or a rejection: no files are
 *  dropped (the app reads an empty list). It may take its time (an
 *  upload): the app waits up to `filesTimeout`. */
export type DropFilesHook = (files: File[]) => Promise<readonly string[] | null> | readonly string[] | null;

export interface DndBridgeOptions {
  engine: Engine;
  view: View;
  input: Input;
  /** The desktop: drags over it are the apps'. */
  container: HTMLElement;
  /** Largest value of one type, in bytes (a larger text is not handed
   *  over: that type reads empty; a larger file is not offered as its
   *  content). Default 4 MiB. */
  maxBytes?: number;
  /** Dropped files: see DropFilesHook. Without it, a dropped file within
   *  `maxBytes` is offered as its content under its own type (the first
   *  one of each type). */
  files?: DropFilesHook;
  /** How long an app's read of a drop's files waits for them (the hook,
   *  the file reads), in ms. Default 30000. */
  filesTimeout?: number;
  log?(line: string): void;
}

export interface DndBridge {
  /** Feed every engine event. */
  handle(event: WlandEvent): void;
  /** A drag of the page's is over the desktop now. */
  active(): boolean;
  /** Remove its listeners; a drag in progress is cancelled. */
  dispose(): void;
}

/** The browser types a drop can carry to the apps, each with the Wayland
 *  types it is offered as: `wayland` in the browser's order (text/plain
 *  expanded to TEXT_MIMES), `web` the browser types they come from. Files
 *  ('Files') and other types are left out. */
export function dropTypes(types: readonly string[]): { web: string[]; wayland: string[] } {
  const web: string[] = [], wayland: string[] = [];
  for (const t of types) {
    const type = t.toLowerCase();
    if (web.includes(type)) continue;
    if (type === 'text/plain') wayland.push(...TEXT_MIMES);
    else if (type === 'text/html' || type === 'text/uri-list') wayland.push(type);
    else continue;
    web.push(type);
  }
  return { web, wayland };
}

/** A drop's data for Engine.dragData: each browser type of `web` read with
 *  `get` (DataTransfer.getData) under the Wayland types it is offered as
 *  (dropTypes). text/uri-list lines end in CRLF (RFC 2483). A value over
 *  `maxBytes` UTF-8 bytes, or empty, is left out (those types read empty). */
export function dropData(get: (type: string) => string, web: readonly string[], maxBytes: number = 4 * 1024 * 1024): Record<string, string> {
  const out: Record<string, string> = {};
  const enc = new TextEncoder();
  for (const type of web) {
    let v = get(type) || '';
    if (!v) continue;
    if (type === 'text/uri-list') v = v.split(/\r?\n/).filter((l) => l !== '').map((l) => `${l}\r\n`).join('');
    // (a cheap bound first: UTF-8 is at most 3 bytes per UTF-16 unit)
    if (v.length * 3 > maxBytes && enc.encode(v).length > maxBytes) continue;
    if (type === 'text/plain') for (const m of TEXT_MIMES) out[m] = v;
    else out[type] = v;
  }
  return out;
}

/** The dnd actions a drag's DataTransfer.effectAllowed lets the apps take
 *  (link counts as copy: Wayland has no link). */
export function dropActions(effectAllowed: string | undefined): number {
  switch (effectAllowed) {
    case 'none': return 0;
    case 'copy': case 'link': case 'copyLink': return DND_COPY;
    case 'move': return DND_MOVE;
    default: return DND_COPY | DND_MOVE; // copyMove, linkMove, all, uninitialized
  }
}

/** The dropEffect that shows `action` (Engine.dragAction) to a drag
 *  allowing `effectAllowed`. */
export function dropEffect(action: number, effectAllowed: string | undefined): 'copy' | 'move' | 'link' | 'none' {
  if (action === DND_MOVE) return 'move';
  if (action === DND_COPY) return effectAllowed === 'link' || effectAllowed === 'linkMove' ? 'link' : 'copy';
  return 'none';
}

/** What a drag offers the apps, decided from what the browser shows of it
 *  before its drop (its types, its file items' types): `web`/`wayland` as
 *  dropTypes plus the files part — 'uris' (the hook's: text/uri-list),
 *  'content' (no hook: each of `fileTypes`, a file's bytes under its own
 *  type) or 'none' (no files; or the drag's own text/uri-list, which wins
 *  over the hook; or no usable file type without one). */
export interface DropPlan {
  web: string[];
  wayland: string[];
  files: 'none' | 'uris' | 'content';
  fileTypes: string[];
}

/** The DropPlan for a drag showing `types` (DataTransfer.types: 'Files'
 *  among them for files) and `fileTypes` (the types of its file items,
 *  DataTransferItem.type: '' unknown), with or without a files hook. */
export function dropPlan(types: readonly string[], fileTypes: readonly string[], hook: boolean): DropPlan {
  const { web, wayland } = dropTypes(types);
  const plan: DropPlan = { web, wayland, files: 'none', fileTypes: [] };
  if (!fileTypes.length && !types.includes('Files')) return plan;
  if (hook) {
    if (!web.includes('text/uri-list')) {
      plan.files = 'uris';
      wayland.push('text/uri-list');
    }
    return plan;
  }
  for (const t of fileTypes) {
    const type = t.toLowerCase();
    if (!type || wayland.includes(type) || plan.fileTypes.includes(type)) continue;
    plan.fileTypes.push(type);
  }
  if (plan.fileTypes.length) {
    plan.files = 'content';
    wayland.push(...plan.fileTypes);
  }
  return plan;
}

/** A text/uri-list of `entries`: URIs as they are, absolute paths as
 *  `file://` URIs (each segment percent-encoded), CRLF after each. */
export function uriList(entries: readonly string[]): string {
  return entries.map((e) => e.trim()).filter((e) => e !== '')
    .map((e) => `${e.startsWith('/') ? `file://${e.split('/').map(encodeURIComponent).join('/')}` : e}\r\n`).join('');
}

/** The files part of a drop's data (DropPlan.files), or null when there is
 *  none to wait for: 'uris' — the hook's answer as a text/uri-list (none
 *  when it rejects, returns null or nothing); 'content' — for each of
 *  `fileTypes` the first of `files` of that type within `maxBytes`, read.
 *  Only types that got bytes are in the result. */
export function dropFileData(plan: DropPlan, files: readonly File[], hook: DropFilesHook | undefined, maxBytes: number = 4 * 1024 * 1024): Promise<Record<string, string | Uint8Array>> | null {
  if (!files.length) return null;
  if (plan.files === 'uris') {
    if (!hook) return null;
    return Promise.resolve().then(() => hook([...files])).then((list): Record<string, string | Uint8Array> => {
      const text = list ? uriList(list) : '';
      return text ? { 'text/uri-list': text } : {};
    });
  }
  if (plan.files !== 'content') return null;
  const chosen: [string, File][] = [];
  for (const type of plan.fileTypes) {
    const f = files.find((f) => f.type.toLowerCase() === type && f.size <= maxBytes);
    if (f) chosen.push([type, f]);
  }
  if (!chosen.length) return null;
  return Promise.all(chosen.map(async ([type, f]) => [type, new Uint8Array(await f.arrayBuffer())] as const))
    .then((pairs) => Object.fromEntries(pairs.filter(([, b]) => b.length <= maxBytes)));
}

/** Make the drop of an embedder drag (Engine.dragBegin) the app under it
 *  takes: the text data (`get`: DataTransfer.getData, per `plan.web`)
 *  handed over and the drop made at once — or, with files to read or the
 *  hook to ask, the drop made at once and the data handed over when it is
 *  ready (dragDrop(true), dragData later; after `timeoutMs` with what is
 *  there). Nothing at all to hand over: cancelled. `stale()` true: another
 *  drag began meanwhile — the late data goes nowhere (that drag's is not
 *  this one's). Resolves true once the data was handed over, false when
 *  cancelled. Shared by the page bridge and wland/headless. */
export function finishDrop(engine: Engine, plan: DropPlan, get: (type: string) => string, files: readonly File[],
  options: { hook?: DropFilesHook; maxBytes?: number; timeoutMs?: number; stale?: () => boolean; log?: (line: string) => void } = {}): Promise<boolean> {
  const maxBytes = options.maxBytes ?? 4 * 1024 * 1024;
  const log = options.log || (() => {});
  const sync: Record<string, string | Uint8Array> = dropData(get, plan.web, maxBytes);
  let later: Promise<Record<string, string | Uint8Array>> | null;
  try { later = dropFileData(plan, files, options.hook, maxBytes); } catch (e) { later = Promise.reject(e); }
  if (!later && !Object.keys(sync).length) {
    engine.dragCancel();
    log('dnd: nothing to drop (no file within the size cap, no text): cancelled');
    return Promise.resolve(false);
  }
  if (!later) {
    engine.dragData(sync);
    engine.dragDrop();
    return Promise.resolve(true);
  }
  engine.dragDrop(true); // the app reads when the files are in
  return new Promise((resolve) => {
    let done = false;
    const give = (extra: Record<string, string | Uint8Array>) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      const data = { ...sync, ...extra };
      if (!options.stale?.()) engine.dragData(Object.keys(data).length ? data : null);
      resolve(true);
    };
    const timer = setTimeout(() => {
      log(`dnd: the dropped files were not ready within ${options.timeoutMs ?? 30000} ms; dropped without them`);
      give({});
    }, options.timeoutMs ?? 30000);
    later!.then(give, (e) => {
      log(`dnd: the dropped files could not be read or placed (${e}); dropped without them`);
      give({});
    });
  });
}

/** How long a drag over the desktop may go without a dragover before it
 *  counts as gone (a dragleave the page never saw). */
const STALE_MS = 2000;

export function createDndBridge(options: DndBridgeOptions): DndBridge {
  const { engine, view, input, container } = options;
  const maxBytes = options.maxBytes ?? 4 * 1024 * 1024;
  const log = options.log || (() => {});
  const now = () => Math.round(performance.now()) >>> 0;
  let disposed = false;
  let inertLogged = false;

  interface Drag {
    plan: DropPlan;
    effectAllowed: string;
    grab: PointerGrab;
    at: { x: number; y: number };
    target: string; // `${conn}:${surface}:${x}:${y}` last sent
    stale: ReturnType<typeof setTimeout> | undefined;
  }
  let drag: Drag | null = null;
  let begun = 0; // drags begun so far (a drop's late data checks it)
  // the latest dragenter: on the desktop, and still within the task that
  // fired it — a dragenter precedes the dragleave of the element left, in
  // one task, so a dragleave right after one on the desktop is a move
  // within it (relatedTarget is null in some browsers)
  let enteredInside = false;
  let enteredFresh = false;

  const inside = (t: EventTarget | null) => !!t && container.contains(t as Node);
  // listeners on the document: the desktop's children come and go
  const listening: [string, EventListener, boolean][] = [];
  function on<K extends keyof DocumentEventMap>(type: K, fn: (ev: DocumentEventMap[K]) => void, capture = true) {
    document.addEventListener(type, fn as EventListener, capture);
    listening.push([type, fn as EventListener, capture]);
  }

  function begin(ev: DragEvent): boolean {
    const dt = ev.dataTransfer;
    if (!dt) return false;
    const fileTypes: string[] = [];
    if (dt.items) for (let i = 0; i < dt.items.length; i++) if (dt.items[i].kind === 'file') fileTypes.push(dt.items[i].type);
    const plan = dropPlan([...dt.types], fileTypes, !!options.files);
    // files are copied, never moved (the source would delete them)
    const actions = dropActions(dt.effectAllowed) & (plan.files === 'none' ? DND_COPY | DND_MOVE : DND_COPY);
    if (!plan.wayland.length || !actions) return false; // nothing the apps can take
    if (engine.selectionBridged() !== true) {
      if (engine.selectionBridged() === false && !inertLogged) {
        inertLogged = true;
        log('dnd: the relay can\'t write the page\'s bytes to apps (no FEATURE selection_cache); drags from the page are not bridged on this link');
      }
      return false;
    }
    if (!engine.dragBegin(plan.wayland, actions)) return false;
    begun++;
    const d: Drag = { plan, effectAllowed: dt.effectAllowed, at: { x: ev.clientX, y: ev.clientY }, target: '', stale: undefined,
      // the pointer is the drag's: the app under it gets its leave
      grab: input.grab(-1, { onEnd: (reason) => { if (reason !== 'end' && drag === d) cancel(); } }) };
    drag = d;
    log(`dnd: a page drag of ${[...plan.web, ...(plan.files === 'uris' ? ['files (as text/uri-list)'] : plan.fileTypes.map((t) => `a ${t} file`))].join(', ')} over the desktop`);
    return true;
  }

  function motion(d: Drag, ev: DragEvent) {
    d.at = { x: ev.clientX, y: ev.clientY };
    clearTimeout(d.stale);
    d.stale = setTimeout(() => { if (drag === d) cancel(); }, STALE_MS);
    const t = view.surfaceAt(ev.clientX, ev.clientY) || { conn: 0, surface: 0, x: 0, y: 0 }; // 0,0 = over nothing
    const key = `${t.conn}:${t.surface}:${t.x}:${t.y}`;
    if (key === d.target) return;
    d.target = key;
    engine.dragMotion(t.conn, t.surface, now(), t.x, t.y);
  }

  function end(d: Drag) {
    clearTimeout(d.stale);
    if (drag === d) drag = null;
    d.grab.end(d.at);
  }
  function cancel() {
    const d = drag;
    if (!d) return;
    drag = null;
    engine.dragCancel();
    end(d);
  }

  on('dragenter', (ev) => {
    enteredInside = inside(ev.target);
    enteredFresh = true;
    setTimeout(() => { enteredFresh = false; }, 0);
    if (!enteredInside) return;
    ev.preventDefault();
    if (!drag && !begin(ev)) return;
    if (drag) motion(drag, ev);
  });

  on('dragover', (ev) => {
    if (!inside(ev.target)) return;
    // the desktop takes every drop the browser would act on itself (a
    // link or a file would replace the page)
    ev.preventDefault();
    const dt = ev.dataTransfer;
    if (!drag) {
      if (dt) dt.dropEffect = 'none';
      return;
    }
    motion(drag, ev);
    if (dt) dt.dropEffect = dropEffect(engine.dragAction(), drag.effectAllowed);
  });

  on('dragleave', (ev) => {
    if (!drag || !inside(ev.target)) return;
    const to = ev.relatedTarget;
    const stays = to ? inside(to) : enteredFresh && enteredInside;
    if (!stays) cancel();
  });

  on('drop', (ev) => {
    if (!inside(ev.target)) return;
    ev.preventDefault();
    const d = drag;
    if (!d) return;
    const dt = ev.dataTransfer;
    motion(d, ev); // where it fell
    drag = null;
    if (!engine.dragAction() || !dt) {
      engine.dragCancel(); // (dragDrop would cancel too: nothing takes it there)
      end(d);
      return;
    }
    // the strings and the File objects now: the DataTransfer is dead once
    // this handler returns (Files stay readable)
    const files = d.plan.files === 'none' ? [] : [...(dt.files ?? [])];
    const seq = begun;
    void finishDrop(engine, d.plan, (t) => dt.getData(t), files, {
      hook: options.files, maxBytes, timeoutMs: options.filesTimeout, stale: () => begun !== seq, log,
    }).then((dropped) => { if (dropped) log(`dnd: dropped (${d.plan.web.length ? d.plan.web.join(', ') : ''}${files.length ? ` ${files.length} file(s)` : ''})`); });
    end(d);
  });

  // the page's own drag ended (one that started in the page), or a press:
  // the browser's drag is over whatever the page saw of it
  on('dragend', () => cancel());
  on('pointerdown', () => cancel());

  return {
    handle(ev) {
      if (disposed) return;
      // a fresh compositor (or none): the core's drag is gone with the old
      if ((ev.type === 'close' || ev.type === 'open') && drag) {
        const d = drag;
        drag = null;
        end(d);
      }
    },
    active: () => drag !== null,
    dispose() {
      if (disposed) return;
      disposed = true;
      cancel();
      for (const [type, fn, capture] of listening.splice(0)) document.removeEventListener(type, fn, capture);
    },
  };
}
