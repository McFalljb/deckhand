#!/bin/sh
# Builds the browser client (web/, docs/PROTOCOL.md §5b) into web/dist/, which the core embeds
# (src/core/web_assets.odin). Needs Node 22.18 or later. Without it the build goes on and the core
# embeds a placeholder page, said here; DECKHAND_WEB_REQUIRED=1 (release builds: scripts/release.sh,
# scripts/pack-linux.sh) fails instead. npm ci runs only when web/package-lock.json changed.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/web"
need=${DECKHAND_WEB_REQUIRED:-0}
skip() {
  if [ "$need" = 1 ]; then
    echo "build-web: $1: a release build must embed the web client" >&2
    exit 1
  fi
  if [ -f dist/index.html ]; then
    echo "build-web: skipped ($1): the core embeds the web/dist/ already there, which may be stale"
  else
    echo "build-web: skipped ($1): the core embeds a placeholder page instead of the web client"
  fi
  exit 0
}
command -v node >/dev/null 2>&1 || skip "no node"
node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=18)?0:1)' ||
  skip "node $(node --version) is older than 22.18"
command -v npm >/dev/null 2>&1 || skip "no npm"
if [ ! -f node_modules/.package-lock.json ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
  npm ci --no-audit --no-fund --loglevel=error
fi
npm run --silent build
[ -f dist/index.html ] || { echo "build-web: no web/dist/index.html after the build" >&2; exit 1; }
