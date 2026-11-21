// Just enough DOM for lib/view.ts, input.ts, wm.ts and client.ts to run in
// Node: elements with listeners and a 2D context that records puts and
// draws (toDataURL names the paints; CSS.supports says yes), focus that fires focusin/blur,
// pointer capture and Pointer Lock (requests recorded; the test grants
// with lock()), the Fullscreen API (requests recorded, granted at once
// unless fullscreenResult says otherwise; exitFullscreen()), navigator.userActivation, rAF, ResizeObserver and matchMedia —
// with counters of what is still registered, so tests can check that
// dispose() leaves nothing behind. Not a test file itself (node --test runs *.test.ts).
//
// Loosely typed on purpose: it stands in for DOM types it only partly
// implements, so what it hands tests is `any`.

type Listener = (ev: any) => void;
type ListenerOpts = boolean | { capture?: boolean; once?: boolean } | undefined;

class Target {
  listeners: Map<string, Map<Listener, { capture: boolean; once: boolean }>>;
  constructor() { this.listeners = new Map(); }
  addEventListener(type: string, fn: Listener, opts?: ListenerOpts) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Map());
    this.listeners.get(type)!.set(fn, { capture: !!(opts === true || (opts && typeof opts === 'object' && opts.capture)), once: !!(opts && typeof opts === 'object' && opts.once) });
  }
  removeEventListener(type: string, fn: Listener, opts?: ListenerOpts) {
    const m = this.listeners.get(type);
    const capture = !!(opts === true || (opts && typeof opts === 'object' && opts.capture));
    if (m && m.has(fn) && m.get(fn)!.capture === capture) m.delete(fn);
  }
  dispatch(type: string, ev: Record<string, unknown> = {}) {
    const e = { type, target: this, preventDefault() {}, stopPropagation() {}, ...ev };
    for (const [fn, o] of [...(this.listeners.get(type) || [])]) {
      if (o.once) this.listeners.get(type)!.delete(fn);
      fn(e);
    }
  }
  get listenerCount(): number {
    let n = 0;
    for (const m of this.listeners.values()) n += m.size;
    return n;
  }
}

class FakeDocument extends Target {
  body!: Element;
  activeElement!: Element;
  hidden = false;
  pointerLockElement: Element | null = null;
  /** exitPointerLock() calls. */
  exits = 0;
  /** What the next requestPointerLock() returns (default: a resolved promise). */
  lockResult: (() => unknown) | null = null;
  fullscreenElement: Element | null = null;
  /** What the next requestFullscreen() does (default: grant it at once). */
  fullscreenResult: ((el: Element) => Promise<void>) | null = null;
  /** exitFullscreen() calls. */
  fullscreenExits = 0;
  exitFullscreen() {
    this.fullscreenExits++;
    if (this.fullscreenElement) {
      this.fullscreenElement = null;
      this.dispatch('fullscreenchange');
    }
    return Promise.resolve();
  }
  exitPointerLock() {
    this.exits++;
    if (!this.pointerLockElement) return;
    this.pointerLockElement = null;
    this.dispatch('pointerlockchange');
  }
  createElement(tag: string): Element { return new Element(this, tag); }
  elementFromPoint(): Element | null { return null; }
}

type Put = [{ data: Uint8ClampedArray; width: number; height: number }, number, number];

class Element extends Target {
  doc: FakeDocument;
  tagName: string;
  style: Record<string, string>;
  dataset: Record<string, string>;
  children: Element[];
  parentElement: Element | null;
  attributes: Record<string, string>;
  textContent: string;
  width: number;
  height: number;
  clientWidth: number;
  clientHeight: number;
  puts: Put[];
  draws: unknown[][];
  constructor(doc: FakeDocument, tag: string) {
    super();
    this.doc = doc;
    this.tagName = tag.toUpperCase();
    this.style = {};
    this.dataset = {};
    this.children = [];
    this.parentElement = null;
    this.attributes = {};
    this.textContent = '';
    this.width = 300;
    this.height = 150;
    this.clientWidth = 0;
    this.clientHeight = 0;
    this.puts = []; // 2D putImageData calls: [ImageData, x, y]
    this.draws = []; // 2D clearRect / drawImage calls: ['clear' | 'draw', ...args]
  }
  get isConnected(): boolean {
    let e: Element = this;
    while (e.parentElement) e = e.parentElement;
    return e === this.doc.body;
  }
  get offsetLeft() { return 0; }
  get offsetTop() { return 0; }
  get offsetWidth() { return 0; }
  get offsetHeight() { return 0; }
  setAttribute(k: string, v: string) { this.attributes[k] = v; }
  appendChild(c: Element) {
    c.remove();
    c.parentElement = this;
    this.children.push(c);
    return c;
  }
  remove() {
    const p = this.parentElement;
    if (!p) return;
    p.children.splice(p.children.indexOf(this), 1);
    this.parentElement = null;
    if (this.doc.activeElement === this) this.doc.activeElement = this.doc.body;
  }
  get previousSibling(): Element | null {
    const p = this.parentElement;
    const i = p ? p.children.indexOf(this) : -1;
    return i > 0 ? p!.children[i - 1] : null;
  }
  after(n: Element) {
    const p = this.parentElement;
    if (!p) return;
    n.remove();
    n.parentElement = p;
    p.children.splice(p.children.indexOf(this) + 1, 0, n);
  }
  replaceWith(n: Element) {
    const p = this.parentElement;
    if (!p) return;
    p.children[p.children.indexOf(this)] = n;
    n.parentElement = p;
    this.parentElement = null;
  }
  cloneNode() {
    const c = new Element(this.doc, this.tagName);
    Object.assign(c.style, this.style);
    Object.assign(c.dataset, this.dataset);
    return c;
  }
  focus() {
    const prev = this.doc.activeElement;
    if (prev === this) return;
    this.doc.activeElement = this;
    if (prev) prev.dispatch('blur');
    this.doc.dispatch('focusin', { target: this });
  }
  getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 }; }
  /** A stand-in PNG URL naming the size and how many paints it has seen. */
  toDataURL() { return `data:image/png;base64,${this.width}x${this.height}n${this.puts.length + this.draws.length}`; }
  /** The options of each requestPointerLock() call. */
  lockRequests: unknown[] = [];
  requestPointerLock(opts?: unknown) {
    this.lockRequests.push(opts);
    return this.doc.lockResult ? this.doc.lockResult() : Promise.resolve();
  }
  /** requestFullscreen() calls. */
  fullscreenRequests = 0;
  requestFullscreen() {
    this.fullscreenRequests++;
    if (this.doc.fullscreenResult) return this.doc.fullscreenResult(this);
    this.doc.fullscreenElement = this;
    this.doc.dispatch('fullscreenchange');
    return Promise.resolve();
  }
  contains(n: unknown): boolean {
    for (let e = n as Element | null; e; e = e.parentElement) if (e === this) return true;
    return false;
  }
  /** The pointer id setPointerCapture took (null: none). */
  captured: number | null = null;
  setPointerCapture(id: number) { this.captured = id; }
  releasePointerCapture(id: number) { if (this.captured === id) this.captured = null; }
  hasPointerCapture(id: number) { return this.captured === id; }
  getContext(kind: string) {
    if (kind !== '2d') return null;
    const el = this;
    return {
      putImageData(img: FakeImageData, x: number, y: number) { el.puts.push([{ data: img.data.slice(), width: img.width, height: img.height }, x, y]); },
      clearRect(...args: number[]) { el.draws.push(['clear', ...args]); },
      drawImage(image: unknown, ...args: number[]) { el.draws.push(['draw', image, ...args]); },
      getImageData(x: number, y: number, w: number, h: number) { return { data: new Uint8ClampedArray(w * h * 4) }; },
    };
  }
}

class FakeImageData {
  data: Uint8ClampedArray;
  width: number;
  height: number;
  constructor(data: Uint8ClampedArray, width: number, height: number) { this.data = data; this.width = width; this.height = height; }
}

export interface FakeDom {
  document: any;
  /** navigator.userActivation (isActive: transient activation). */
  activation: { isActive: boolean };
  /** The browser (un)locks the pointer to `el`: pointerlockchange. */
  lock(el: any): void;
  /** Run the pending animation frames once. */
  frame(t?: number): void;
  /** What is still registered outside the container. */
  leftovers(): { documentListeners: number; observers: number; mediaListeners: number; frames: number };
  /** An 800×600 container attached to the body (a fake HTMLElement). */
  container(): any;
  uninstall(): void;
}

export function installFakeDom(): FakeDom {
  const doc = new FakeDocument();
  doc.body = new Element(doc, 'body');
  doc.activeElement = doc.body;

  const live = { observers: new Set<object>(), media: new Set<Target>(), frames: new Map<number, (t: number) => void>() };
  let nextFrame = 1;
  const g = globalThis as any;
  g.document = doc;
  g.window = { devicePixelRatio: 1 };
  g.location = { protocol: 'http:', host: 'localhost:8080' };
  g.ImageData = FakeImageData;
  g.CSS = { supports: () => true };
  g.ResizeObserver = class ResizeObserver {
    cb: unknown;
    constructor(cb: unknown) { this.cb = cb; }
    observe() { live.observers.add(this); }
    disconnect() { live.observers.delete(this); }
  };
  g.matchMedia = (query: string) => {
    const mq = new Target() as Target & { media?: string };
    mq.media = query;
    live.media.add(mq);
    return mq;
  };
  g.requestAnimationFrame = (fn: (t: number) => void) => {
    const id = nextFrame++;
    live.frames.set(id, fn);
    return id;
  };
  g.cancelAnimationFrame = (id: number) => { live.frames.delete(id); };
  const activation = { isActive: true };
  Object.defineProperty(g.navigator, 'userActivation', { value: activation, configurable: true });

  return {
    document: doc,
    activation,
    lock(el) {
      doc.pointerLockElement = el;
      doc.dispatch('pointerlockchange');
    },
    frame(t = 16) {
      const due = [...live.frames];
      live.frames.clear();
      for (const [, fn] of due) fn(t);
    },
    leftovers() {
      let media = 0;
      for (const mq of live.media) media += mq.listenerCount;
      return {
        documentListeners: doc.listenerCount,
        observers: live.observers.size,
        mediaListeners: media,
        frames: live.frames.size,
      };
    },
    container() {
      const c = doc.createElement('div');
      c.clientWidth = 800;
      c.clientHeight = 600;
      doc.body.appendChild(c);
      return c;
    },
    uninstall() {
      for (const k of ['document', 'window', 'location', 'ImageData', 'CSS', 'ResizeObserver', 'matchMedia', 'requestAnimationFrame', 'cancelAnimationFrame']) delete g[k];
      delete g.navigator.userActivation;
    },
  };
}
