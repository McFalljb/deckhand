#!/bin/sh
# The terminal streams' cost (docs/plans/background-core.md §10.2, M3-H's gate): a shown tab's
# output is parsed twice (the core's terminal and the window's copy), a hidden tab's once. A shell
# tab cats 95 MB of styled text shown, then 95 MB while another tab shows; CPU% and the flood's
# wall time from the log's "CPU" lines. Compare a build before M3-H with one after:
#   tests/scripts/term-bench.sh [BINARY]     (default build/deckhand; run alone: numbers)
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN=${1:-build/deckhand}
[ "$BIN" = build/deckhand ] && . tests/scripts/fresh-build.sh
FAKE_HOME="$ROOT/build/bench-home"
PROJ="$ROOT/build/bench-proj"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$PROJ" "$FAKE_HOME/.pi/agent/sessions/--bench--"
printf '{"type":"session","version":3,"id":"bbbb-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--bench--/2026-10-30T10-00-00-000Z_bbbb-1.jsonl"
[ -s build/bench-flood.txt ] || python3 -I -c '
import sys
out = []
for i in range(400000):
    out.append("\x1b[3%dm%06d\x1b[0m \x1b[1mbold\x1b[22m text %s \x1b[38;5;%dmcolour\x1b[0m\r\n" % (i % 8, i, "w" * (i % 40), i % 256))
sys.stdout.write("".join(out))' > build/bench-flood.txt
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$ROOT/tests/scripts/term-bench.txt" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' \
  "$BIN" "$PROJ"
