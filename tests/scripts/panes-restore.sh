#!/bin/sh
# Split panes saved and restored (persist.odin, panes_restore.odin; docs/PERSISTENCE.md "Panes"):
# run 1 splits a session into three panes and quits; run 2 relaunches with the same data dir
# and finds the same tree, ratios, tabs per pane, shown tab per pane and focused pane, every
# shell sized to its pane. A fake HOME, a fake pi, a temp data dir (never the user's).
# Usage: tests/scripts/panes-restore.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/panes-restore"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$W/proj" # outside HOME, as restore.sh's projects
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
printf '{"type":"session","version":3,"id":"pppp-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--/2026-10-30T10-00-00-000Z_pppp-1.jsonl"
run() { # n
  HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="tests/scripts/panes-restore-$1.txt" DECKHAND_DATA_DIR="$W/data" \
    DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$W/run$1.log" 2>&1 || true
  # a separate core (DECKHAND_SEPARATE_CORE=1) makes the final save in its own log: read with the run's
  if [ -f "$W/data/run/core.log" ]; then cat "$W/data/run/core.log" >> "$W/run$1.log"; : > "$W/data/run/core.log"; fi
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run$1.log" | sed "s/^/run $1: /" || true
  # run 1 ends at its quit (no "done:"): its last line is the final save
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run$1.log" || ! grep -qE "done:|workspace save checks" "$W/run$1.log"; then
    echo "panes-restore run $1 failed (log: $W/run$1.log)"; exit 1
  fi
}
run 1
grep -q '"panes":{"tree":{"split":"right","ratio":0.347' "$W/data/workspace.json" || { echo "no panes saved"; cat "$W/data/workspace.json"; exit 1; }
run 2
# the same layout: per pane in leaf order its tabs' titles and shown tab, the ratios, the focused pane
python3 - "$ROOT/build/panes-restore-before.json" "$ROOT/build/panes-restore-after.json" <<'PY'
import json, sys
def layout(path):
    s = json.load(open(path))["open_sessions"][0]
    title = {t["id"]: t["title"] for t in s["tabs"]}
    panes = [([title[i] for i in p["tabs"]], title[p["active_tab"]]) for p in s["panes"]]
    focused = [p["slot"] for p in s["panes"] if p["id"] == s["focused_pane"]]
    def tree(n):
        if "pane" in n:
            return "pane"
        return [n["dir"], round(n["ratio"], 3), tree(n["a"]), tree(n["b"])]
    return panes, focused, tree(s["layout"]), [t["title"] for t in s["tabs"]][0]
before, after = layout(sys.argv[1]), layout(sys.argv[2])
print("before:", before)
print("after: ", after)
sys.exit(0 if before == after else "the restored layout differs")
PY
echo "panes-restore scene ok"
