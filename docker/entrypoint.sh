#!/bin/sh
# wland demo container: start wlandr, then keep each app running on it.
#   wland-entrypoint [APP...]    one command line per argument (default: chromium pcmanfm)
#
# Apps don't survive the engine going away: a page reload or a new tab
# taking over disconnects every app, and most exit (chromium does). So each
# engine detach (the relay logs it) relaunches the apps that are not running
# — the ones it just killed and the ones the user closed earlier. An app the
# user closes stays closed until then. An app started while no tab is open
# waits in the relay ("app connected, waiting for an engine...") and shows
# up when one connects.
set -eu

[ $# -gt 0 ] || set -- chromium pcmanfm

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
mkdir -p -m 0700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY=wayland-0
unset DISPLAY
# chromium dumps a ~400M core every time its display goes away (each reload)
ulimit -c 0

# 0.0.0.0: a published port has to reach it. There is no authentication:
# on an untrusted network, publish it on the host's loopback only
# (-p 127.0.0.1:8080:8080).
# WLAND_PORT: another port, for --network host where 8080 is taken.
# The relay's log goes through a fifo (so $! stays the relay): passed on as
# is, and each "engine detached" bumps the generation the app loops watch.
gen="$XDG_RUNTIME_DIR/wland-entrypoint.gen"
log="$XDG_RUNTIME_DIR/wland-entrypoint.log"
echo 0 > "$gen"
rm -f "$log"; mkfifo "$log"
n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >&2
  case $line in *"engine detached"*) n=$((n + 1)); echo "$n" > "$gen.new"; mv "$gen.new" "$gen" ;; esac
done < "$log" &
wlandr --host 0.0.0.0 --port "${WLAND_PORT:-8080}" --display "$WAYLAND_DISPLAY" --xwayland off \
  --web-root /usr/local/share/wland/web 2> "$log" &
relay=$!
pids=$relay

stop() {
  trap - TERM INT HUP
  # the relay first: apps lose their display and exit on their own; whatever
  # is left goes when this process (PID 1) exits
  kill -TERM $pids 2>/dev/null || true
  exit "${1:-0}"
}
trap 'stop 0' TERM INT HUP

i=0
until [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; do
  kill -0 "$relay" 2>/dev/null || { wait "$relay" || exit $?; exit 1; }
  i=$((i + 1))
  [ "$i" -lt 100 ] || { echo "wland: no wayland socket after 10s" >&2; stop 1; }
  sleep 0.1
done

# Run an app, then wait for the next engine detach before running it again:
# one that happened while it ran (what killed it; its log line may land a
# moment after the exit) or a later one (the user closed it, or it failed to
# start — no spinning either way).
keep() {
  while :; do
    seen=$(cat "$gen")
    # shellcheck disable=SC2086  # one argument = one command line, split on spaces
    wland-run $1 && status=0 || status=$?
    echo "wland: '$1' exited ($status), back at the next page (re)load" >&2
    while [ "$(cat "$gen")" = "$seen" ]; do sleep 0.5; done
    sleep 0.5 # let the relay finish dropping the old connections
  done
}
for app in "$@"; do
  keep "$app" &
  pids="$pids $!"
done

# the relay's exit is the container's
wait "$relay" && status=0 || status=$?
stop "$status"
