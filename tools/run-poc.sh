#!/usr/bin/env bash
# Orchestrates the full wland stack: build → server → headless chromium →
# real apps, checked over CDP by tools/browser-e2e.ts (one phase per check).
# The page is the tests' own (test/browser, bundled into a temp web root);
# only --demo serves the page `npx wland` serves (lib/index.html, from dist/).
#
#   tools/run-poc.sh > /tmp/poc.log 2>&1   everything
#   tools/run-poc.sh foot gtk              only these groups
#   tools/run-poc.sh --demo                leave it running for a human
#
# This is the BROWSER regression check: run it (or the groups concerned)
# when lib/view, present, input, wm or client changed — which group covers
# what is in .agents/testing.md "What to run". What apps do through the
# compositor (rendering, clipboard, resize storms, globals) is checked
# without a browser by tools/headless-e2e-test.ts.
#
# The apps are wland-fixture modes (test/fixture, built with wlandr), so
# this needs only chromium and bun besides the build; WLAND_E2E_APPS=real
# runs the real apps named below instead (test/support/apps.ts). Groups:
#   foot         typing, pointer sweep + implicit grab, CSD layout, border resize,
#                a click through an input region's hole (fixture: term)
#   gtk          nautilus: popup, navigation, CSD move/maximize, resize
#                (fixture: files, which also checks drag and drop)
#   cursor       weston-flower: a cursor surface as the pointer image (fixture: cursor)
#   constraints  weston-constraints: confine, Pointer Lock, relative motion
#                (fixture: constraints)
#   states       foot: fullscreen (+ the browser's), minimize/restore (fixture: term)
#   retina       dpr 2
#   takeover     a second tab takes the session
#   handle-demo  the handle path in one page (2D + software WebGL)
#   relay        tools/relay-e2e-test.ts (no browser; runs alone too)
set -euo pipefail
cd "$(dirname "$0")/.."

ALL_GROUPS=(foot gtk cursor constraints states retina takeover handle-demo relay)
DEMO=0
ONLY=()
for arg in "$@"; do
  if [[ "$arg" == "--demo" ]]; then DEMO=1
  elif [[ " ${ALL_GROUPS[*]} " == *" $arg "* ]]; then ONLY+=("$arg")
  else echo "unknown group '$arg' (groups: ${ALL_GROUPS[*]})" >&2; exit 2
  fi
done
[[ ${#ONLY[@]} -eq 0 ]] && ONLY=("${ALL_GROUPS[@]}")
want() { [[ " ${ONLY[*]} " == *" $1 "* ]]; }
# GET a URL with node (no curl): the body on stdout; exit 1 on an error
get() {
  node -e 'fetch(process.argv[1]).then(async (r) => { if (!r.ok) process.exit(1); process.stdout.write(await r.text()); }, () => process.exit(1))' "$@"
}
E2E="bun tools/browser-e2e.ts"
# demo stays on the well-known 8080; headless E2E gets its own port so a
# lingering human demo tab (auto-reconnecting every 3s) can't TAKE OVER the
# test session mid-run — newest tab wins, apps drop, phases fail flakily
if [[ $DEMO == 1 ]]; then PORT="${PORT:-8080}"; else PORT="${PORT:-8901}"; fi
# chromium's CDP ports and profiles are per run too (CDP, CDP+1), so two runs
# with different PORT/WAYLAND_DISPLAY/CDP don't kill each other's browser
CDP="${CDP:-9222}"
CDP2=$((CDP + 1))
PROFILE="/tmp/wland-chromium-profile-$PORT"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/wland-run}"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
# wlandr takes the name by --display (it ignores the env; it fails instead of
# stealing a live socket); exported so clients can't disagree. Headless E2E gets its own socket name for the same isolation reason as the
# port: a concurrently running human demo must not share the test's session.
if [[ $DEMO == 1 ]]; then
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
else
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-poc}"
fi

# the apps (test/support/apps.ts has the same table for the Node/bun drivers)
FIXTURE=zig-out/bin/wland-fixture
if [[ "${WLAND_E2E_APPS:-fixture}" == "real" ]]; then
  REAL=1
  TERM_APP=(foot)
  FILES_APP=(tools/wland-run nautilus)   # + a session bus and GTK's cairo renderer
  CURSOR_APP=(weston-flower)
else
  REAL=0
  TERM_APP=("$FIXTURE" term)
  FILES_APP=("$FIXTURE" files)
  CURSOR_APP=("$FIXTURE" cursor)
fi

# real nautilus by name, then wait for its dbus-run-session ($NAUTILUS_PID):
# only when its child exits does dbus-run-session take its bus down, and with
# it the services the bus activated (gvfsd, portals, localsearch, at-spi). A
# signal to dbus-run-session itself leaves all of them running.
stop_nautilus() {
  [[ $REAL == 1 ]] && { pkill -x nautilus 2>/dev/null || true; }
  if [[ -n "${NAUTILUS_PID:-}" ]]; then
    if [[ $REAL == 1 ]]; then
      timeout 5 tail --pid="$NAUTILUS_PID" -f /dev/null 2>/dev/null || kill "$NAUTILUS_PID" 2>/dev/null || true
    else
      kill "$NAUTILUS_PID" 2>/dev/null || true
    fi
  fi
  NAUTILUS_PID=""
}

cleanup() {
  [[ -n "${FOOT_PID:-}" ]] && kill "$FOOT_PID" 2>/dev/null || true
  stop_nautilus
  [[ -n "${FLOWER_PID:-}" ]] && kill "$FLOWER_PID" 2>/dev/null || true
  [[ -n "${CHROMIUM_PID:-}" ]] && kill "$CHROMIUM_PID" 2>/dev/null || true
  [[ -n "${CHROMIUM2_PID:-}" ]] && kill "$CHROMIUM2_PID" 2>/dev/null || true
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  pkill -f "wland-chromium-[p]rofile-$PORT" 2>/dev/null || true
  [[ -n "${WEB_ROOT:-}" ]] && rm -rf "$WEB_ROOT" || true
}
[[ $DEMO == 0 ]] && trap cleanup EXIT

echo "== build =="
# WLAND_BUILD_OPTS: extra zig build flags, e.g. -Doptimize=Debug to E2E a
# dev build. Default follows build.zig's default (production/ReleaseFast).
zig build ${WLAND_BUILD_OPTS:-}

if [[ $DEMO == 0 && "${ONLY[*]}" == "relay" ]]; then
  echo "== relay e2e: wlandr --link ⇄ Node engine (link v2) =="
  node tools/relay-e2e-test.ts
  echo "RUN-POC PASS (relay)"
  exit 0
fi

if [[ $DEMO == 1 ]]; then
  echo "== npm run build (dist/: lib/index.html + the modules it imports, served by the server) =="
  npm run --silent build
  # no headless chromium in demo mode — the human's tab is the compositor.
  # exec: the server IS the foreground process; Ctrl-C stops it directly.
  cat <<EOF
Starting wland in the foreground (Ctrl-C to stop).

  1. Open http://localhost:$PORT in your browser — YOUR tab is the compositor.
     (Opening it in another tab/browser takes the session over; the apps drop
     and must be relaunched.)
  2. Launch apps into it:
       tools/wland-run foot        # sets WAYLAND_DISPLAY etc. for you
       tools/wland-run nautilus    # + dbus session and GTK cairo renderer
     From a shell where XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR, plain \`foot\` also
     works — the socket uses the default name wayland-0.

If you close/reload the tab, apps get dropped — relaunch them after the page
reconnects.

EOF
  exec ./zig-out/bin/wlandr --port "$PORT" --display "$WAYLAND_DISPLAY"
fi

echo "== test pages (test/browser → a temp web root) =="
WEB_ROOT="$(mktemp -d /tmp/wland-e2e-root.XXXXXX)"
bun tools/browser-e2e.ts build "$WEB_ROOT"

echo "== start server =="
./zig-out/bin/wlandr --port "$PORT" --web-root "$WEB_ROOT" --display "$WAYLAND_DISPLAY" &
SERVER_PID=$!
for i in $(seq 1 50); do
  get "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "server died"; exit 1; }
  sleep 0.1
done

echo "== start headless chromium (browser compositor) =="
# the page's #desktop fills this window: mouse-event tests use viewport
# coordinates and silently miss anything below the fold. Timer throttling
# must be off or in-page loops run at 1 Hz.
# env -u WAYLAND_DISPLAY: our socket is the default wayland-0 now — chromium
# would otherwise discover it and connect as a wayland CLIENT, deadlocking
# (it waits for the compositor that its own page is supposed to become).
# Fresh profile every run: a killed chromium leaves stale Singleton* files,
# and the next launch silently never attaches to the page (flaky hang at
# "app connected, waiting for browser").
rm -rf "$PROFILE" "$PROFILE-2"
env -u WAYLAND_DISPLAY chromium-browser --headless=new --no-sandbox --disable-gpu \
  --ozone-platform=headless \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port=$CDP --window-size=1600,1100 \
  --disable-background-timer-throttling --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows \
  "http://127.0.0.1:$PORT/" >/dev/null 2>&1 &
CHROMIUM_PID=$!
# actively wait for the page target: a cold chromium start (fresh profile)
# sometimes exceeds a blind sleep and the whole run dies at wayland-info's
# timeout with "app connected, waiting for browser..."
for i in $(seq 1 300); do
  get "http://127.0.0.1:$CDP/json/list" 2>/dev/null | grep -q "127.0.0.1:$PORT" && break
  sleep 0.2
done
sleep 1 # wasm load + WS attach

if want foot; then
echo "== foot terminal + typing (M4): ${TERM_APP[*]} =="
"${TERM_APP[@]}" &
FOOT_PID=$!
$E2E terminal $CDP

echo "== mouse sweep + motion coalescing (M7.4) =="
$E2E sweep $CDP

echo "== foot CSD layout (M5) =="
$E2E layout $CDP

echo "== foot resize via CSD border drag (M7.3) =="
$E2E resize $CDP

echo "== input region hole: a click through it reaches the window behind =="
$E2E hole $CDP
kill "$FOOT_PID" 2>/dev/null || true
FOOT_PID=""
fi

if want gtk; then
echo "== nautilus: render, menu popup, navigation (M6): ${FILES_APP[*]} =="
# nautilus persists window state (maximized!) via the GSettings KEYFILE
# backend (no dconf service under dbus-run-session); a maximized start
# breaks the fixed click offsets in the gtk phase. Fresh state every run.
[[ $REAL == 1 ]] && rm -f "$HOME/.config/glib-2.0/settings/keyfile" 2>/dev/null || true
# the gtk phase double-clicks the FIRST icon and expects a folder; $HOME's
# first entry can be a file (nautilus does not sort folders first by
# default), so open a fixture directory whose only entry is a folder.
NAUTILUS_FIXTURE="$(mktemp -d /tmp/wland-nautilus.XXXXXX)"
mkdir -p "$NAUTILUS_FIXTURE/folder"
"${FILES_APP[@]}" "$NAUTILUS_FIXTURE" &
NAUTILUS_PID=$!
# the fixture also drags its file onto its folder (before gtk: that
# phase opens the folder)
[[ $REAL == 0 ]] && $E2E dnd $CDP
$E2E gtk $CDP

echo "== nautilus CSD: headerbar move + maximize/restore buttons =="
$E2E csd $CDP

echo "== nautilus resize via CSD border survives (M7.3) =="
$E2E resize $CDP

stop_nautilus
rm -rf "$NAUTILUS_FIXTURE"
fi

if want cursor; then
echo "== cursor surface: weston-flower's set_cursor image is the pointer: ${CURSOR_APP[*]} =="
"${CURSOR_APP[@]}" &
FLOWER_PID=$!
$E2E cursor $CDP
kill "$FLOWER_PID" 2>/dev/null || true
FLOWER_PID=""
fi

if want constraints; then
echo "== pointer constraints: weston-constraints confined + locked through Pointer Lock =="
$E2E constraints $CDP          # spawns the app itself (it reads its WAYLAND_DEBUG)
fi

if want states; then
echo "== window states: fullscreen (+ the browser's), minimize, restore =="
$E2E states $CDP               # reloads the page with ?browserfs=1, spawns foot itself
fi

if want retina; then
echo "== retina: dpr=2 → wl_output scale 2, 2x buffers at logical size =="
$E2E retina $CDP
fi

# NOTE: the WebGL present path is NOT exercised here. This
# chromium is headless/GPU-less, so WebGL is SwiftShader (software) — the client
# probe-gates GL to real hardware and stays on the 2d present path, and forcing
# software GL intermittently hangs headless compositing. Verify the GL path on
# real-GPU hardware with `bun tools/browser-e2e.ts webgl` (forces GL) or by
# watching the `webgl probe` line in window.wlandLog on a real browser
# (.agents/plan.md). (The handle-demo group forces software GL for its two
# small windows: the bgra/bgrx upload + shader swizzle path.)

if want takeover; then
echo "== browser takeover: second tab kicks the first, newest wins =="
env -u WAYLAND_DISPLAY chromium-browser --headless=new --no-sandbox --disable-gpu \
  --ozone-platform=headless \
  --user-data-dir="$PROFILE-2" \
  --remote-debugging-port=$CDP2 --window-size=1600,1100 \
  --disable-background-timer-throttling --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows \
  "http://127.0.0.1:$PORT/" >/dev/null 2>&1 &
CHROMIUM2_PID=$!
$E2E takeover $CDP                     # old tab: kicked notice, no reload fight
"${TERM_APP[@]}" &                     # new tab is now the compositor
FOOT_PID=$!
$E2E terminal $CDP2                     # ...and fully functional
kill "$FOOT_PID" 2>/dev/null || true
FOOT_PID=""
fi

# The handle demo opens no /ws session, so it can't take the session over —
# it runs in the first tab (retired by the takeover group, when that ran).
# Covers 2D and (software) WebGL presenters at small sizes, sync + async
# HandleSource, stream + memory links.
if want handle-demo; then
echo "== handle demo: link v2 handle path in one page =="
$E2E handle-demo $CDP "http://127.0.0.1:$PORT"
fi

# The other half of the handle path: the real relay (--link unix: with
# procfd, then copy buffers) against the engine in Node, no browser. Own
# XDG_RUNTIME_DIR and display name, so nothing above can interfere.
if want relay; then
echo "== relay e2e: wlandr --link ⇄ Node engine (link v2) =="
node tools/relay-e2e-test.ts
fi

echo "RUN-POC PASS (${ONLY[*]})"
