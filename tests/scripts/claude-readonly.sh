#!/bin/sh
# Read-only Claude chats in quiet test mode (docs/CLAUDE.md §1a): never a real claude. A fake
# claude (tests/scripts/fake-claude.py) runs the plugin's hooks and the --settings hooks pi-desk
# passes (the read-only guard, build/pi-desk-cli). claude-stub.sh makes Claude Code "installed".
#   1. claude-readonly-1.txt: Chats: read-only on, + New chat (Claude Code picked): the profile, the guard's
#      denials and passes, pi-desk's refusal of an act verb from the tab's token
#   2. claude-readonly-2.txt: read-only off, relaunch: the chat resumes with its profile
#   3. claude-readonly-3.txt: a claude that ignores --settings: no ack, pi-desk stops the tab
# Then the fake's log: the argv (profile last, PI_DESK_CLAUDE_READONLY), the guard's deny JSON.
# Writes build/claude-readonly/ and build/shots/claude-readonly/. Needs ./build.sh.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. tests/scripts/claude-stub.sh
W="$ROOT/build/claude-readonly"
rm -rf "$W" build/shots/claude-readonly
FAKE_HOME="$W/home"
mkdir -p "$W/data" "$FAKE_HOME"
[ -x build/deckhand ] && [ -x build/pi-desk-cli ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand, build/pi-desk-cli or build/claude-code missing: ./build.sh"; exit 1; }
claude_stub "$FAKE_HOME"
LOG="$W/claude.log"
fail=0
for n in 1 2 3; do
  IGNORE=0; [ $n = 3 ] && IGNORE=1
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdro.XXXXXX") # a short runtime dir: the socket path must fit sun_path
  HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/claude-readonly-$n.txt \
    PI_DESK_DATA_DIR="$W/data" PI_DESK_RUNTIME_DIR="$RUN" PI_DESK_CMD='exec sleep 600' \
    PI_DESK_CLAUDE_CMD="printf '%s\n' \"\${PI_DESK_CLAUDE_READONLY:-unset}\" >> '$W/env'; exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\"" \
    FAKE_CLAUDE_IGNORE_SETTINGS=$IGNORE FAKE_CLAUDE_LOG="$LOG" FAKE_CLAUDE_SESSION=7e5d0000-1111-4222-8333-444455556666 FAKE_CLAUDE_TURN_MS=200 \
    build/deckhand > "$W/run$n.log" 2>&1 || true
  rm -rf "$RUN"
  grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run$n.log" | sed "s/^/run $n: /" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run$n.log" || ! grep -q 'ui_command {"type":"quit"' "$W/run$n.log"; then
    echo "run $n: FAILED (log: $W/run$n.log)"; fail=1
  fi
done
python3 -I - "$LOG" "$W/env" <<'PY' || fail=1
import json, sys
log, envf = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(log)]
starts = [r["start"] for r in rows if "start" in r]
ok = True
def check(cond, what):
    global ok
    print(("ok: " if cond else "FAILED: ") + what)
    ok = ok and cond
check(len(starts) == 3, f"claude started three times (new, restored, restored without the ack): {len(starts)}")
for i, a in enumerate(starts):
    j = a.index("--permission-mode") if "--permission-mode" in a else -1
    check(j > 0 and a[j + 1] == "plan", f"start {i + 1}: plan mode")
    check("--settings" in a and a.index("--settings") > j and a[a.index("--setting-sources") + 1] == "user", f"start {i + 1}: pi-desk's settings, user sources only")
    d = a.index("--disallowedTools")
    tail = a[d + 1:]
    check(all(not t.startswith("-") for t in tail) and {"Edit", "Write", "mcp__*", "Agent"} <= set(tail) and "Bash" not in tail, f"start {i + 1}: the denied tools last, Bash not among them")
    s = json.loads(a[a.index("--settings") + 1])
    h = s["hooks"]["PreToolUse"][0]["hooks"][0]
    ack = s["hooks"]["SessionStart"][0]["hooks"][0]["command"]
    check(" hook readonly-ack " in ack and len(ack.split()[-1]) == 32, f"start {i + 1}: the SessionStart ack with a nonce")
    check(h["onFailure"] == "block" and h["command"].endswith(" hook readonly || exit 2") and "pi-desk-cli" in h["command"], f"start {i + 1}: the guard fails closed")
check(starts[1][starts[1].index("--resume") + 1].startswith("7e5d0000"), "the restore resumes it")
envs = open(envf).read().split()
check(envs == ["1", "1", "1"], f"PI_DESK_CLAUDE_READONLY=1 at every start: {envs}")
denies = [r for r in rows if r.get("hook") == "PreToolUse" and r.get("exit") == 2]
check(len(denies) == 4, f"four denials (git commit, Edit, pi-desk click, rm -rf): {len(denies)}")
for r in denies:
    o = json.loads(r["out"])["hookSpecificOutput"]
    check(o["hookEventName"] == "PreToolUse" and o["permissionDecision"] == "deny" and o["permissionDecisionReason"].startswith("Read-only chat (Deckhand): "), f"deny JSON for {r['tool']} {r.get('input')}")
cmds = [((r.get("input") or {}).get("command") or r["tool"]) for r in rows if r.get("hook") == "PreToolUse" and r.get("exit") == 0 and r.get("out") == ""]
check("echo x >/dev/null 2>&1" in cmds and "Read" in cmds, f"reads run, silently: {cmds}")
cli = [r for r in rows if r.get("cli", [None])[:1] == ["click"]]
check(len(cli) == 1 and cli[0]["exit"] == 1 and "read-only" in cli[0]["out"], f"pi-desk refuses the act verb: {cli[0]['out'][:200] if cli else None}")
sys.exit(0 if ok else 1)
PY
if [ $fail = 1 ]; then echo "claude-readonly scene failed (logs: $W)"; exit 1; fi
echo "claude-readonly scene ok"
