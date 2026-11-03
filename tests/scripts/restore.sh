#!/bin/sh
# Workspace save/restore end to end, in test mode with a fake HOME, a fake pi
# that prints its arguments and a temp data dir (never the user's):
#   1. open two sessions and shells, quit through the confirm flow (saves)
#   2. relaunch with the same data dir: state restored, the current session's
#      pi resumed with --session <file>, the other not started until focused
#   3. a big workspace (10 projects, 20 sessions): launch time, one session started
# Usage: tests/scripts/restore.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/restore"
rm -rf "$W"
mkdir -p "$W/home" "$W/data" "$W/alpha" "$W/beta"
store() { # cwd id n
  d="$W/home/.pi/agent/sessions/--$(printf '%s' "${1#/}" | tr / -)--"
  mkdir -p "$d"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$2" "$1" > "$d/2026-10-30T10-00-$3-000Z_$2.jsonl"
}
store "$W/alpha" aaaa-1 01
store "$W/beta" bbbb-2 02
run() { # script data-dir [args]
  s=$1 d=$2; shift 2
  HOME="$W/home" SHELL=/bin/sh PI_DESK_SCRIPT="$s" PI_DESK_DATA_DIR="$d" \
    PI_DESK_CMD='echo "ARGS: $*"; exec sleep 600' build/pi-desk "$@"
}

echo "== run 1: open, quit (confirm flow)"
run tests/scripts/restore-1.txt "$W/data" > "$W/run1.log" 2>&1 || { cat "$W/run1.log"; exit 1; }
grep -E "ASSERT|done:" "$W/run1.log" || true
test -f "$W/data/workspace.json" || { echo "no workspace.json"; exit 1; }
mode=$(stat -f %Lp "$W/data/workspace.json")
[ "$mode" = 600 ] || { echo "workspace.json mode $mode"; exit 1; }
cat "$W/data/workspace.json"

echo "== run 2: relaunch, restore"
run tests/scripts/restore-2.txt "$W/data" > "$W/run2.log" 2>&1 || { cat "$W/run2.log"; exit 1; }
grep -E "ASSERT|done:|pi-desk:|found|TIMEOUT" "$W/run2.log"
! grep -q TIMEOUT "$W/run2.log" || { echo "a waitfor timed out"; exit 1; }
grep -c '"command":{"type":"restore_session"' "$W/data/commands.log" | sed 's/^/restore_session events in the log: /'
grep -q "ARGS: --session $W/home/.pi/agent/sessions/.*_aaaa-1.jsonl" "$W/run2.log" || grep -q "found ARGS: --session" "$W/run2.log" || { echo "pi not resumed"; exit 1; }

echo "== run 3: big workspace (10 projects, 20 sessions)"
mkdir -p "$W/big"
{
  printf '{"v":1,"projects":[],"open_sessions":['
  i=0
  while [ $i -lt 20 ]; do
    p=$((i / 2)); mkdir -p "$W/big/p$p"
    store "$W/big/p$p" "big-$i" $(printf '%02d' $((i % 60)))
    [ $i -gt 0 ] && printf ','
    printf '{"pi_session_id":"big-%d","cwd":"%s","session_dir":"","project":"%s","tabs":[{"kind":"pi"},{"kind":"shell","title":"shell 1","cwd":"%s"}],"active_tab":0}' $i "$W/big/p$p" "$W/big/p$p" "$W/big/p$p"
    i=$((i + 1))
  done
  printf '],"current_session":7,"layout":{"left_width":300,"right_width":320,"right_open":true,"panels":[],"collapsed":[]},"settings":{}}\n'
} > "$W/data/workspace.json"
for n in 1 2 3; do
  run tests/scripts/restore-big.txt "$W/data" > "$W/run3-$n.log" 2>&1 || { cat "$W/run3-$n.log"; exit 1; }
  grep -E "ASSERT|pi-desk:" "$W/run3-$n.log"
  cp "$W/data/workspace.json" "$W/big-$n.json"
done
echo "== baseline: same HOME, --fresh"
for n in 1 2 3; do
  run tests/scripts/restore-fresh.txt "$W/data-fresh" --fresh > "$W/fresh-$n.log" 2>&1 || { cat "$W/fresh-$n.log"; exit 1; }
  grep -E "ASSERT|pi-desk:" "$W/fresh-$n.log" || true
done
echo "restore.sh: ok"
