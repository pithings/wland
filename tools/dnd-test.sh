#!/usr/bin/env bash
# dnd E2E: real nautilus drags a file onto a folder through the compositor's
# wl_data_device.start_drag path; PASS = the file physically moved on disk.
# Self-contained and isolated (own port/socket/profile — safe alongside a
# human demo on 8080 or run-poc on 8901). Not wired into run-poc: the icon
# coordinates assume the fresh-profile nautilus grid layout at
# --window-size=1600,1100, which held deterministic in this container.
# The dnd path without nautilus: run-poc's gtk group (browser-e2e `dnd`,
# the `files` fixture) and tools/headless-e2e-test.ts.
# Usage: tools/dnd-test.sh   (needs a prior `zig build`)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8905
CDP=9224
PROFILE=/tmp/wland-dnd-profile
HOME_DIR=/tmp/wland-dnd-home
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export WAYLAND_DISPLAY=wayland-dnd

cleanup() {
  [[ -n "${NAUTILUS_PID:-}" ]] && kill "$NAUTILUS_PID" 2>/dev/null || true
  pkill -x nautilus 2>/dev/null || true
  [[ -n "${CHROMIUM_PID:-}" ]] && kill "$CHROMIUM_PID" 2>/dev/null || true
  pkill -f "wland-dnd-profile" 2>/dev/null || true
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "${WEB_ROOT:-}" ]] && rm -rf "$WEB_ROOT" || true
}
trap cleanup EXIT

rm -rf "$HOME_DIR" "$PROFILE"
mkdir -p "$HOME_DIR/dest-folder"
echo "payload" > "$HOME_DIR/drag-me.txt"

WEB_ROOT="$(mktemp -d /tmp/wland-dnd-root.XXXXXX)"
bun tools/browser-e2e.ts build "$WEB_ROOT"
./zig-out/bin/wlandr --port $PORT --web-root "$WEB_ROOT" --display "$WAYLAND_DISPLAY" &
SERVER_PID=$!
for i in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "server died"; exit 1; }
  sleep 0.1
done

env -u WAYLAND_DISPLAY chromium-browser --headless=new --no-sandbox --disable-gpu \
  --ozone-platform=headless \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port=$CDP --window-size=1600,1100 \
  --disable-background-timer-throttling --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows \
  "http://127.0.0.1:$PORT/" >/dev/null 2>&1 &
CHROMIUM_PID=$!
for i in $(seq 1 300); do
  curl -sf "http://127.0.0.1:$CDP/json/list" 2>/dev/null | grep -q "127.0.0.1:$PORT" && break
  sleep 0.2
done
sleep 2

tools/wland-run nautilus "$HOME_DIR" >/dev/null 2>&1 &
NAUTILUS_PID=$!

# fresh-profile grid layout: dirs sort first — dest-folder at ~(305,145),
# drag-me.txt at ~(475,143), canvas-relative (verified by screenshot)
bun tools/browser-e2e.ts drag $CDP 475 143 305 145

for i in $(seq 1 20); do
  [[ -f "$HOME_DIR/dest-folder/drag-me.txt" && ! -f "$HOME_DIR/drag-me.txt" ]] && {
    echo "dnd test ok: drag-me.txt moved into dest-folder (GTK move action)"
    exit 0
  }
  sleep 0.5
done
echo "dnd test FAIL: file did not move ($(ls "$HOME_DIR"))"
exit 1
