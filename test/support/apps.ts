// The apps the E2E tests run, by role. By default each role is a mode of
// wland-fixture (test/fixture, built by `zig build` next to wlandr): small
// Wayland clients with no dependencies beyond the build. WLAND_E2E_APPS=real
// swaps in the real apps they stand in for — the compatibility check that
// needs them installed (.agents/testing.md "Setup"); a phase whose real app
// is missing is skipped.
//
// Every fixture mode mirrors what the tests read off its real app: the
// output format (wayland-info, weston-presentation-shm, wl-paste, SDL's
// MOTION lines), the protocol log under WAYLAND_DEBUG, the window layout and
// click positions (nautilus's default floating layout for `files`). So one
// phase drives either.
//
// Real apps run in a throwaway home (appHome): no E2E reads or writes the
// developer's dotfiles, and no dotfile changes what a test sees; nor do they
// reach the developer's session bus (their running apps, dconf).

import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const FIXTURE: string = fileURLToPath(new URL('../../zig-out/bin/wland-fixture', import.meta.url));

export type AppSet = 'fixture' | 'real';
export const appSet: AppSet = process.env.WLAND_E2E_APPS === 'real' ? 'real' : 'fixture';
export const realApps: boolean = appSet === 'real';

export type AppRole =
  | 'info' | 'shm' | 'presentation' | 'copy' | 'paste'
  | 'cursor' | 'constraints' | 'relative' | 'term' | 'files' | 'fullscreen'
  // Firefox's seat shape (wl_seat bound twice: GTK's, then its own)
  | 'browser'
  // a GPU client (linux-dmabuf); the fixture's buffers are memfds, which
  // only the relay's test-only `--dmabuf virtgpu:@fake` takes
  | 'dmabuf'
  // an SDL2 game: xdg-decoration made before its first commit, no frame of
  // its own (neverball)
  | 'game'
  // wl_touch, read off WAYLAND_DEBUG (weston-simple-touch; the fixture's
  // title strip also moves its window by a finger, the real one's doesn't)
  | 'touch';

export interface AppSpec {
  role: AppRole;
  cmd: string;
  args: string[];
  env: Record<string, string>;
  /** a real GTK app: it wants a session bus (DBUS_SESSION_BUS_ADDRESS) */
  bus?: boolean;
  /** what it is, for log lines */
  name: string;
}

/** An SDL3 app through python3 ctypes: a window; the first left press turns
 *  on relative mouse mode (on Wayland: lock_pointer + a relative pointer);
 *  every motion printed as `MOTION x y xrel yrel rel=0|1`. argv[1]: seconds. */
const SDL_RELATIVE = `
import ctypes, struct, sys, time
sdl = ctypes.CDLL('libSDL3.so.0')
sdl.SDL_Init.restype = ctypes.c_bool
sdl.SDL_Init.argtypes = [ctypes.c_uint32]
sdl.SDL_CreateWindow.restype = ctypes.c_void_p
sdl.SDL_CreateWindow.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_uint64]
sdl.SDL_CreateRenderer.restype = ctypes.c_void_p
sdl.SDL_CreateRenderer.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
sdl.SDL_SetRenderDrawColor.argtypes = [ctypes.c_void_p] + [ctypes.c_uint8] * 4
sdl.SDL_RenderClear.argtypes = [ctypes.c_void_p]
sdl.SDL_RenderPresent.argtypes = [ctypes.c_void_p]
sdl.SDL_PollEvent.restype = ctypes.c_bool
sdl.SDL_PollEvent.argtypes = [ctypes.c_void_p]
sdl.SDL_SetWindowRelativeMouseMode.restype = ctypes.c_bool
sdl.SDL_SetWindowRelativeMouseMode.argtypes = [ctypes.c_void_p, ctypes.c_bool]
sdl.SDL_GetError.restype = ctypes.c_char_p
if not sdl.SDL_Init(0x20):  # SDL_INIT_VIDEO
    print('SDL_Init failed', sdl.SDL_GetError(), flush=True)
    sys.exit(1)
win = sdl.SDL_CreateWindow(b'sdl-relative', 320, 240, 0)
ren = sdl.SDL_CreateRenderer(win, None)
ev = ctypes.create_string_buffer(128)
rel = False
end = time.time() + float(sys.argv[1])
while time.time() < end:
    while sdl.SDL_PollEvent(ev):
        t = struct.unpack_from('<I', ev.raw, 0)[0]
        if t == 0x100:  # SDL_EVENT_QUIT
            sys.exit(0)
        if t == 0x400:  # SDL_EVENT_MOUSE_MOTION: x, y, xrel, yrel at 28
            x, y, xr, yr = struct.unpack_from('<ffff', ev.raw, 28)
            print(f'MOTION {x:.2f} {y:.2f} {xr:.2f} {yr:.2f} rel={int(rel)}', flush=True)
        if t == 0x401 and not rel:  # SDL_EVENT_MOUSE_BUTTON_DOWN
            rel = bool(sdl.SDL_SetWindowRelativeMouseMode(win, True))
            print(f'RELATIVE {int(rel)}', flush=True)
    sdl.SDL_SetRenderDrawColor(ren, 40, 120 if rel else 40, 200, 255)
    sdl.SDL_RenderClear(ren)
    sdl.SDL_RenderPresent(ren)
    time.sleep(0.01)
`;

let home: Record<string, string> | null = null;
/** The environment every real app runs in: a throwaway HOME and XDG base
 *  dirs (foot.ini, GSettings keyfile, GTK recents and bookmarks, tracker,
 *  font and shader caches all land there), no shell history (HISTFILE) and
 *  no readline bindings (INPUTRC: this container's /etc/inputrc binds
 *  PgUp/PgDn — the keypad's 9/3 with NumLock off — to history search, which
 *  rewrote a typed line from the previous run's saved one). GSettings is a
 *  keyfile there (GSETTINGS_BACKEND), never dconf, and the session bus is
 *  one nobody listens on (DBUS_SESSION_BUS_ADDRESS: a path in that home):
 *  no app talks to the developer's running apps or their dconf-service. A
 *  driver running a session bus for a real app (`bus`) overrides it with
 *  its own, and gives the bus this environment too: the services it
 *  activates (the settings portal, tracker) read it. Made on first use and
 *  removed at exit, SIGINT or SIGTERM; `WLAND_E2E_HOME` names one to use
 *  instead (run-poc makes it, for the apps it starts and its bun
 *  driver's). */
export function appHome(): Record<string, string> {
  if (home) return home;
  let dir = process.env.WLAND_E2E_HOME;
  if (!dir) {
    const made = mkdtempSync(join(tmpdir(), 'wland-e2e-home-'));
    const remove = () => { try { rmSync(made, { recursive: true, force: true }); } catch { /* busy: left in /tmp */ } };
    process.on('exit', remove);
    // a signal's default action skips 'exit': remove it, then die of the
    // signal as before (unless the driver handles it itself)
    for (const sig of ['SIGINT', 'SIGTERM'] as const) {
      process.once(sig, () => {
        remove();
        if (process.listenerCount(sig) === 0) process.kill(process.pid, sig);
      });
    }
    dir = made;
  }
  home = {
    HOME: dir, XDG_CONFIG_HOME: `${dir}/.config`, XDG_DATA_HOME: `${dir}/.local/share`,
    XDG_CACHE_HOME: `${dir}/.cache`, XDG_STATE_HOME: `${dir}/.local/state`,
    HISTFILE: '/dev/null', INPUTRC: '/dev/null',
    GSETTINGS_BACKEND: 'keyfile', DBUS_SESSION_BUS_ADDRESS: `unix:path=${dir}/no-session-bus`,
  };
  for (const k of ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME']) mkdirSync(home[k], { recursive: true });
  return home;
}

function real(role: AppRole, args: string[]): AppSpec {
  const spec = (cmd: string, a: string[], env: Record<string, string> = {}, bus = false): AppSpec =>
    ({ role, cmd, args: a, env: { ...appHome(), ...env }, bus, name: cmd });
  switch (role) {
    case 'info': return spec('wayland-info', args);
    case 'shm': return spec('weston-simple-shm', args);
    case 'presentation': return spec('weston-presentation-shm', args);
    case 'copy': return spec('wl-copy', args);
    case 'paste': return spec('wl-paste', args);
    case 'cursor': return spec('weston-flower', args);
    case 'constraints': return spec('weston-constraints', args);
    case 'fullscreen': return spec('weston-fullscreen', args);
    // (the headless E2E's phase is fixture-only: Firefox aborts in this
    // container at GTK's first icon, testing.md "Setup")
    case 'browser': return spec('firefox', ['--no-remote', '--new-instance', ...args]);
    case 'dmabuf': return spec('weston-simple-dmabuf-egl', args);
    case 'touch': return spec('weston-simple-touch', args);
    // SDL2 (sdl2-compat here); no libdecor (its GTK plugin aborts in this
    // container), no audio device needed
    case 'game': return spec('neverball', args, { SDL_VIDEO_DRIVER: 'wayland', SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR: '0', SDL_AUDIODRIVER: 'dummy' });
    // no libdecor: its GTK plugin aborts in this container (testing.md)
    case 'relative': return { ...spec('python3', ['-c', SDL_RELATIVE, '60'], { SDL_VIDEO_DRIVER: 'wayland', SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR: '0' }), name: 'SDL3 (python3)' };
    // a plain shell: no rc files that retitle the window on every prompt
    case 'term': return spec('foot', ['bash', '--norc', '--noprofile', ...args]);
    case 'files': return spec('nautilus', args, { GDK_BACKEND: 'wayland', GSK_RENDERER: 'cairo' }, true);
  }
}

/** The command for `role` in the current app set; `args` are the real
 *  app's (the fixture takes the same where it matters). */
export function app(role: AppRole, args: string[] = []): AppSpec {
  if (realApps) return real(role, args);
  return { role, cmd: FIXTURE, args: [role, ...args], env: {}, name: `wland-fixture ${role}` };
}

const found = new Map<string, boolean>();
/** Whether the app can run here (fixtures: always, once built). */
export function available(spec: AppSpec): boolean {
  if (spec.cmd === FIXTURE) return true;
  if (!found.has(spec.cmd)) found.set(spec.cmd, spawnSync('sh', ['-c', `command -v ${spec.cmd}`]).status === 0);
  if (!found.get(spec.cmd)) return false;
  if (spec.role === 'relative') return spawnSync('python3', ['-c', 'import ctypes; ctypes.CDLL("libSDL3.so.0")']).status === 0;
  return true;
}
