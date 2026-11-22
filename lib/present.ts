// Presenters: paint commit events into a canvas. Internal to view.ts.
//
// A presenter is chosen ONCE per canvas (a canvas that got a 2d context can't
// later get webgl, and vice versa):
//   - GL (toplevels): one canvas-sized texture, one texSubImage2D per damage
//     rect, one textured-quad draw. The full-commit copy moves to the GPU.
//   - 2D (everything else, and the fallback): putImageData per damage rect.
// GL is scoped to toplevels so the live context count stays tiny (one per
// window, well under the browser's ~16 cap), and used only when WebGL is
// hardware-accelerated (probeWebGL): software GL is no faster than
// putImageData and can hang headless compositing at large sizes.
//
// Input formats (engine.ts PixelFormat):
//   - 'rgba': `pixels` packed per damage rect (each rect's rows tight, rects
//     concatenated in order). That is exactly WebGL RGBA/UNSIGNED_BYTE and a
//     2D canvas's ImageData: both paint it as is.
//   - 'bgra'/'bgrx': `pixels` holds buffer rows `stride` bytes apart, as the
//     wl_shm client wrote them. GL uploads the rects straight from those rows
//     (WebGL2 UNPACK_ROW_LENGTH; a repack on WebGL1 or a stride that is not a
//     whole number of pixels) as RGBA and swaps channels in the shader,
//     forcing alpha to 1 for bgrx. 2D swizzles in JS (swizzleRect): that path
//     serves 2D surfaces next to GL toplevels (popups, subsurfaces) and
//     toplevels after a GL context loss; a 2D-only view asks the engine for
//     'rgba' instead (EngineOptions.rgba, the core's wland_swizzle).
//   - 'gpu': no pixels; `image` is what the embedder's GpuSource resolved
//     the GPU buffer to (a CanvasImageSource, row 0 at the top), drawn
//     during the commit's dispatch and never kept (the engine ACKs right
//     after). 2D: clearRect + drawImage per damage rect (the whole image
//     scaled to the buffer if its size differs). GL: the whole image
//     uploaded as the texture (texImage2D from the source, no CPU copy).
//     null: nothing drawn, the canvas keeps its content (the engine then
//     makes the surface's next commit's damage the whole buffer, so 2D
//     never paints a few rects over that stale content).
// Alpha policy is the copy path's everywhere: bgrx/xrgb opaque, bgra's
// premultiplied alpha passed through unchanged (premultipliedAlpha:false, like
// a 2D canvas's straight alpha — the approximation the copy path always made).
// GL: the texture holds row 0 = top, the quad's UVs flip V so row 0 lands at
// the top, NEAREST + a 1:1 viewport give texel-exact output.
//
// Presenting has no protocol side effects (wl_buffer.release is the relay's).

import type { CommitEvent } from './engine.ts';

export interface Pixels { data: Uint8Array | Uint8ClampedArray; width: number; height: number }

export interface Presenter {
  kind: '2d' | 'webgl' | 'webgl2';
  present(commit: CommitEvent): void;
  /** The canvas's current pixels (GL rows bottom-up); empty before any. */
  readback(): Pixels;
  dispose(): void;
}

type Log = (line: string) => void;

const GL_VS = 'attribute vec2 a_pos;varying vec2 v_uv;' +
  'void main(){v_uv=vec2((a_pos.x+1.0)*0.5,(1.0-a_pos.y)*0.5);gl_Position=vec4(a_pos,0.0,1.0);}';
// u_fmt.x: swap B and R (texels are bgra bytes); u_fmt.y: force alpha to 1
const GL_FS = 'precision highp float;varying vec2 v_uv;uniform sampler2D u_tex;uniform vec2 u_fmt;' +
  'void main(){vec4 c=texture2D(u_tex,v_uv);if(u_fmt.x>0.5)c=c.bgra;if(u_fmt.y>0.5)c.a=1.0;gl_FragColor=c;}';

const EMPTY = (): Pixels => ({ data: new Uint8Array(0), width: 0, height: 0 });

/** A CanvasImageSource's pixel size (VideoFrame, video, img, then the
 *  canvases and ImageBitmap). */
export function imageSize(image: CanvasImageSource): { width: number; height: number } {
  const i = image as { displayWidth?: number; displayHeight?: number; videoWidth?: number; videoHeight?: number;
    naturalWidth?: number; naturalHeight?: number; width?: unknown; height?: unknown };
  const num = (v: unknown) => (typeof v === 'number' ? v : 0);
  return {
    width: i.displayWidth ?? i.videoWidth ?? i.naturalWidth ?? num(i.width),
    height: i.displayHeight ?? i.videoHeight ?? i.naturalHeight ?? num(i.height),
  };
}

// A 'gpu' commit on a 2D context: the damaged rects of the image replace
// the canvas's (clearRect first: drawImage blends), or the whole image
// scaled to the buffer when its size differs.
function drawImage2D(ctx: CanvasRenderingContext2D, commit: CommitEvent) {
  const image = commit.image as CanvasImageSource | null | undefined;
  if (!image) return;
  const { width, height, damage } = commit;
  const size = imageSize(image);
  if (size.width !== width || size.height !== height) {
    ctx.clearRect(0, 0, width, height);
    ctx.drawImage(image, 0, 0, width, height);
    return;
  }
  for (let i = 0; i < damage.length; i += 4) {
    const x = damage[i], y = damage[i + 1], w = damage[i + 2], h = damage[i + 3];
    ctx.clearRect(x, y, w, h);
    ctx.drawImage(image, x, y, w, h, x, y, w, h);
  }
}

// iterate a commit's damage rects with the byte offset of each rect's first
// pixel in `pixels`: packed ('rgba') or at (x, y) of the buffer rows
function eachRect(commit: CommitEvent, fn: (x: number, y: number, w: number, h: number, off: number) => void) {
  const { damage, format, stride } = commit;
  let off = 0;
  for (let i = 0; i < damage.length; i += 4) {
    const x = damage[i], y = damage[i + 1], w = damage[i + 2], h = damage[i + 3];
    if (format === 'rgba') {
      fn(x, y, w, h, off);
      off += w * h * 4;
    } else {
      fn(x, y, w, h, y * stride + x * 4);
    }
  }
}

/** A w×h rect of BGRA/BGRX rows (`stride` bytes apart, first pixel at
 *  src[off]) → tight RGBA in dst. `opaque` (bgrx) forces alpha to 255. */
export function swizzleRect(src: ArrayLike<number>, off: number, stride: number, w: number, h: number,
  opaque: boolean, dst: { [i: number]: number }): void {
  let d = 0;
  for (let r = 0; r < h; r++) {
    for (let s = off + r * stride, end = s + w * 4; s < end; s += 4, d += 4) {
      dst[d] = src[s + 2];
      dst[d + 1] = src[s + 1];
      dst[d + 2] = src[s];
      dst[d + 3] = opaque ? 255 : src[s + 3];
    }
  }
}

export function make2DPresenter(canvas: HTMLCanvasElement): Presenter {
  // desynchronized lowers present latency; ignored by some (e.g. headless)
  // backends, harmlessly
  const ctx = canvas.getContext('2d', { desynchronized: true });
  let tmp = new Uint8ClampedArray(0); // swizzle target for bgra/bgrx, reused
  return {
    kind: '2d',
    present(commit) {
      if (!ctx) return;
      if (commit.format === 'gpu') return drawImage2D(ctx, commit);
      const { pixels, format, stride } = commit;
      eachRect(commit, (x, y, w, h, off) => {
        const n = w * h * 4;
        let view: Uint8ClampedArray<ArrayBuffer>;
        if (format === 'rgba') {
          view = new Uint8ClampedArray(pixels.buffer as ArrayBuffer, pixels.byteOffset + off, n);
        } else {
          if (tmp.length < n) tmp = new Uint8ClampedArray(n);
          view = tmp.subarray(0, n);
          swizzleRect(pixels, off, stride, w, h, format === 'bgrx', view);
        }
        ctx.putImageData(new ImageData(view, w, h), x, y);
      });
    },
    readback() {
      if (!ctx) return EMPTY();
      const { width, height } = canvas;
      return { data: ctx.getImageData(0, 0, width, height).data, width, height };
    },
    dispose() {},
  };
}

function compileShader(gl: WebGLRenderingContext, type: GLenum, src: string, log: Log): WebGLShader | null {
  const sh = gl.createShader(type);
  if (!sh) return null;
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    log(`gl shader: ${gl.getShaderInfoLog(sh)}`);
    gl.deleteShader(sh);
    return null;
  }
  return sh;
}

/** A GL presenter, or null if WebGL can't be set up on this canvas. */
export function makeGLPresenter(canvas: HTMLCanvasElement, log: Log, onLost: () => void): Presenter | null {
  const attrs: WebGLContextAttributes = { alpha: true, premultipliedAlpha: false, antialias: false,
                  depth: false, stencil: false, preserveDrawingBuffer: false };
  let ctx: WebGLRenderingContext | WebGL2RenderingContext | null = null;
  try { ctx = canvas.getContext('webgl2', attrs) || canvas.getContext('webgl', attrs); } catch { ctx = null; }
  if (!ctx) return null;
  const gl = ctx;
  const vs = compileShader(gl, gl.VERTEX_SHADER, GL_VS, log);
  const fs = compileShader(gl, gl.FRAGMENT_SHADER, GL_FS, log);
  if (!vs || !fs) return null;
  const prog = gl.createProgram()!;
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    log(`gl link: ${gl.getProgramInfoLog(prog)}`);
    gl.deleteProgram(prog);
    return null;
  }
  const quad = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const aPos = gl.getAttribLocation(prog, 'a_pos');
  const uTex = gl.getUniformLocation(prog, 'u_tex');
  const uFmt = gl.getUniformLocation(prog, 'u_fmt');
  const gl2 = typeof WebGL2RenderingContext !== 'undefined' && gl instanceof WebGL2RenderingContext;
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);

  let texW = 0, texH = 0, lost = false;
  let texBgr = false, opaque = false; // what the texels hold: byte order, alpha policy
  let texImage = false; // the texture was last defined from a 'gpu' image (its own size)
  let repack: Uint8Array = new Uint8Array(0); // strided rows → tight, when ROW_LENGTH can't
  const draw = () => {
    gl.viewport(0, 0, texW, texH);
    gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.uniform1i(uTex, 0);
    gl.uniform2f(uFmt, texBgr ? 1 : 0, opaque ? 1 : 0);
    gl.disable(gl.BLEND);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  };
  const dead = () => lost || gl.isContextLost();

  const p: Presenter = {
    kind: gl2 ? 'webgl2' : 'webgl',
    present(commit) {
      if (dead()) return;
      const { width, height, pixels, format, stride } = commit;
      gl.bindTexture(gl.TEXTURE_2D, tex);
      if (format === 'gpu') {
        // the whole image becomes the texture, straight from the source (the
        // browser's GPU-side copy); damage doesn't matter at that cost. Drawn
        // now, inside the dispatch, which is all the image's lifetime allows.
        const image = commit.image as TexImageSource | null | undefined;
        if (!image) return; // nothing resolved: keep what is shown
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
        texW = width;
        texH = height;
        texBgr = false;
        opaque = false;
        texImage = true;
        draw();
        return;
      }
      const bgr = format !== 'rgba';
      // a new size, or texels of the other byte order (a relay mixing copy
      // and handle commits on one surface), or a texture an image defined:
      // start from a blank texture rather than show the old texels with
      // swapped channels
      if (texW !== width || texH !== height || texBgr !== bgr || texImage) {
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        texW = width;
        texH = height;
        texBgr = bgr;
        texImage = false;
      }
      opaque = format === 'bgrx';
      // strided rows upload in place when the stride is whole pixels
      const rowLength = bgr && gl2 && stride % 4 === 0 ? stride / 4 : 0;
      if (rowLength) gl.pixelStorei((gl as WebGL2RenderingContext).UNPACK_ROW_LENGTH, rowLength);
      eachRect(commit, (x, y, w, h, off) => {
        // the relay clamps rects to the buffer; guard anyway so a stray rect
        // can't raise INVALID_VALUE. texSubImage2D reads the view
        // synchronously, which is all its lifetime allows.
        if (!(x >= 0 && y >= 0 && x + w <= width && y + h <= height)) return;
        let src: Uint8Array;
        if (!bgr) {
          src = pixels.subarray(off, off + w * h * 4);
        } else if (rowLength) {
          src = pixels.subarray(off, off + (h - 1) * stride + w * 4);
        } else {
          const n = w * h * 4;
          if (repack.length < n) repack = new Uint8Array(n);
          for (let r = 0; r < h; r++) repack.set(pixels.subarray(off + r * stride, off + r * stride + w * 4), r * w * 4);
          src = repack.subarray(0, n);
        }
        try {
          gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RGBA, gl.UNSIGNED_BYTE, src);
        } catch (e) {
          // pixels in a SharedArrayBuffer (HandleSource.view) where this
          // browser's WebGL won't take shared views: upload a copy
          if (!(src.buffer instanceof ArrayBuffer) && e instanceof TypeError) {
            gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RGBA, gl.UNSIGNED_BYTE, src.slice());
          } else throw e;
        }
      });
      if (rowLength) gl.pixelStorei((gl as WebGL2RenderingContext).UNPACK_ROW_LENGTH, 0);
      draw();
    },
    readback() {
      if (dead() || !texW) return EMPTY();
      // draw + readPixels in one synchronous call: the drawing buffer is
      // valid here regardless of preserveDrawingBuffer. Rows come back
      // bottom-up (GL origin).
      draw();
      const data = new Uint8Array(texW * texH * 4);
      gl.readPixels(0, 0, texW, texH, gl.RGBA, gl.UNSIGNED_BYTE, data);
      return { data, width: texW, height: texH };
    },
    dispose() {
      try {
        gl.deleteTexture(tex);
        gl.deleteProgram(prog);
        gl.deleteBuffer(quad);
        const ext = gl.getExtension('WEBGL_lose_context');
        if (ext) ext.loseContext();
      } catch { /* context already gone */ }
    },
  };

  // context loss must never throw mid-present or blank a window forever:
  // preventDefault keeps it non-fatal, the view swaps in a 2d canvas
  canvas.addEventListener('webglcontextlost', (e) => {
    e.preventDefault();
    lost = true;
    onLost();
  }, false);
  return p;
}

// Whether WebGL here is HARDWARE-accelerated, probed once per tab on a
// throwaway off-DOM context (so the verdict never taints a surface canvas).
// Headless browsers skip the probe: they are GPU-less here, and creating a
// software GL context in headless Chromium intermittently hangs its
// compositor. The verdict is cached in sessionStorage so reloads never make a
// second probe context (tearing one down during a reload has crashed headless
// SwiftShader). Requires a POSITIVE hardware signal: a false "software" only
// forgoes a GPU upload, a false "hardware" can freeze the page.
export function probeWebGL(log: Log): boolean {
  if (typeof navigator !== 'undefined' && /headless/i.test(navigator.userAgent || '')) {
    log('headless browser → GL probe skipped, 2d present');
    return false;
  }
  try {
    const cached = sessionStorage.getItem('wland.glhw');
    if (cached === '1' || cached === '0') return cached === '1';
  } catch { /* sessionStorage unavailable */ }
  let ok = false;
  try {
    const probe = document.createElement('canvas');
    const gl = probe.getContext('webgl2') || probe.getContext('webgl');
    if (gl) {
      const dbg = gl.getExtension('WEBGL_debug_renderer_info');
      const renderer = dbg ? String(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) || '') : '';
      const software = /swiftshader|software|llvmpipe|basic render|microsoft basic|paravirtual|mesa offscreen/i.test(renderer);
      const hardware = /nvidia|geforce|amd|radeon|intel|iris|apple|mali|adreno|powervr|vivante|angle metal|angle \(apple|angle \(nvidia|angle \(amd|angle \(intel|direct3d|opengl \(/i.test(renderer);
      ok = !software && hardware;
      log(`webgl probe: "${renderer || '(renderer hidden)'}" → ${ok ? 'hardware, GL present ON' : 'no hardware signal, 2d present'}`);
      const ext = gl.getExtension('WEBGL_lose_context');
      if (ext) ext.loseContext();
    } else {
      log('webgl probe: no context → 2d present');
    }
  } catch (e) { log(`webgl probe failed: ${(e as Error).message} → 2d present`); }
  try { sessionStorage.setItem('wland.glhw', ok ? '1' : '0'); } catch { /* */ }
  return ok;
}
