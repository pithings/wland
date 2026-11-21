#!/usr/bin/env bash
# Smoke test: build, unit tests, the server serves a web root (a page and
# the wasm with its content type). The root is a throwaway, not dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8080}"

# GET a URL with node (no curl): the body on stdout, or with a second
# argument "type" its content type; exit 1 on an error or a non-2xx answer
get() {
  node -e 'fetch(process.argv[1]).then(async (r) => { if (!r.ok) process.exit(1); process.stdout.write(process.argv[2] === "type" ? r.headers.get("content-type") ?? "" : await r.text()); }, () => process.exit(1))' "$@"
}

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "${WEB_ROOT:-}" ]] && rm -rf "$WEB_ROOT" || true
}
trap cleanup EXIT

echo "== zig build test =="
zig build test

echo "== zig build =="
zig build

WEB_ROOT="$(mktemp -d /tmp/wland-smoke-root.XXXXXX)"
echo "<!DOCTYPE html><title>wland smoke</title>" > "$WEB_ROOT/index.html"
cp lib/wland.wasm "$WEB_ROOT/"

echo "== start server on :$PORT =="
./zig-out/bin/wlandr --port "$PORT" --web-root "$WEB_ROOT" &
SERVER_PID=$!

for i in $(seq 1 50); do
  get "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "server died"; exit 1; }
  sleep 0.1
done

echo "== GET index.html =="
get "http://127.0.0.1:$PORT/" | grep -q "<title>wland smoke</title>"
echo "index.html ok"

echo "== GET wasm =="
[[ "$(get "http://127.0.0.1:$PORT/wland.wasm" type)" == "application/wasm" ]]
echo "wasm served ok"

echo "SMOKE PASS (build + tests + static serving; browser E2E lives in run-poc.sh)"
