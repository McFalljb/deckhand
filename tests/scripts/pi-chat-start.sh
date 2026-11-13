#!/bin/sh
# Every start of a chat's pi (new, an agent's new, restart, resume, restore) is full pi (no tool
# allowlist, no PI_KIT_READONLY: what a chat may do is the chats folder's AGENTS.md) with Deckhand's
# pi integration (-e per extension, first) and DECKHAND_* bridge variables, never pi-kit's
# PI_DESK_* ones. Never a real pi: the fake (DECKHAND_CMD) logs its argv and environment, then
# waits for "exit" typed into its tab.
#   1. pi-chat-start-1.txt: the user's new chat, a script's (an agent's) new chat, its restart
#      after pi exited, a resumed chat (open_session); quit
#   2. pi-chat-start-2.txt: the workspace restores (the chat on screen starts again), another
#      restored chat starts when shown
# Writes build/pi-chat-start/. Needs ./build.sh.
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/pi-chat-start"
rm -rf "$W"
FAKE_HOME="$W/home"
CHATS="$FAKE_HOME/Chats"
STORE="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "$CHATS" | sed 's|^/||; s|/|-|g')--"
mkdir -p "$W/data" "$CHATS" "$STORE"
# a chat from before, to resume
printf '{"type":"session","version":3,"id":"c0de0000-1111-4222-8333-444455556666","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"an old chat"}}\n' \
  "$CHATS" > "$STORE/2026-11-01T10-00-00-000Z_c0de0000-1111-4222-8333-444455556666.jsonl"
LOG="$W/argv.log"
# the fake pi: logs its argv and PI_KIT_READONLY; a new chat (--session-id) writes its session
# file as pi would, so the workspace keeps it; "exit" typed into its tab ends it
cat > "$W/fake-pi.sh" <<FAKE
{ printf 'START %s\n' "\${PI_KIT_READONLY:-unset}"; for k in PI_DESK_SOCKET PI_DESK_TOKEN PI_DESK_CONTROL_TOKEN PI_DESK_SHOTS_DIR DECKHAND_SOCKET DECKHAND_TOKEN DECKHAND_CONTROL_TOKEN DECKHAND_SHOTS_DIR; do eval "v=\\\${\$k:-}"; [ -n "\$v" ] && printf 'ENV %s\n' "\$k"; done; for a in "\$@"; do printf 'ARG %s\n' "\$a"; done; } >> '$LOG'
prev=
for a in "\$@"; do
  [ "\$prev" = --session-id ] && printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "\$a" "\$PWD" > '$STORE'/2026-11-02T10-00-0\$(ls '$STORE' | wc -l | tr -d ' ')-000Z_"\$a".jsonl
  prev=\$a
done
echo "FAKE PI ARGS: \$*"
while read -r l; do [ "\$l" = exit ] && exit 0; done
exec sleep 600
FAKE
CMD=". '$W/fake-pi.sh'"
fail=0
for n in 1 2; do
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdcr.XXXXXX") # a short runtime dir: the socket path must fit sun_path
  env -u PI_KIT_READONLY HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh \
    DECKHAND_SCRIPT=tests/scripts/pi-chat-start-$n.txt DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
    DECKHAND_CMD="$CMD" build/deckhand > "$W/run$n.log" 2>&1 || true
  rm -rf "$RUN"
  grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run$n.log" | sed "s/^/run $n: /" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run$n.log" || ! grep -q 'quit' "$W/run$n.log"; then
    echo "run $n: FAILED (log: $W/run$n.log)"; fail=1
  fi
done
python3 -I - "$LOG" "$ROOT" <<'PY' || fail=1
import json, os, sys
starts = []
for line in open(sys.argv[1]).read().splitlines():
    kind, _, val = line.partition(" ")
    if kind == "START": starts.append({"env": val, "argv": [], "bridge": []})
    elif kind == "ENV": starts[-1]["bridge"].append(val)
    elif kind == "ARG": starts[-1]["argv"].append(val)
ok = True
def check(cond, what):
    global ok
    print(("ok: " if cond else "FAILED: ") + what)
    ok = ok and cond
names = ["the user's new chat", "a script's new chat", "its restart", "a resumed chat", "the restored chat", "another restored chat"]
check(len(starts) == len(names), f"pi started {len(names)} times: {len(starts)}")
for name, st in zip(names, starts):
    a = st["argv"]
    check("--tools" not in a and "--exclude-tools" not in a and "--no-mcp" not in a, f"{name}: full pi, no allowlist: {a}")
    check(st["env"] == "unset", f"{name}: no PI_KIT_READONLY")
# Deckhand's pi integration on every start: -e per required extension, first, from the app's
# Resources/pi (a separate core, the default: Deckhand Core.app's own copy); the bridge variables are DECKHAND_*,
# never pi-kit's PI_DESK_* (it stays inert)
root = sys.argv[2]
manifest = json.load(open(os.path.join(root, "integrations/pi/extensions.json")))
res = "build/Deckhand.app/Contents/Helpers/Deckhand Core.app/Contents/Resources/integrations/pi" if os.environ.get("DECKHAND_SEPARATE_CORE", "1") != "0" else "build/Deckhand.app/Contents/Resources/pi"
bundled = os.path.realpath(os.path.join(root, res))
want = [x for e in manifest["extensions"] if e["required"] for x in ("-e", os.path.join(bundled, "extensions", e["name"]))]
for name, st in zip(names, starts):
    a = st["argv"]
    got = [x if x == "-e" else os.path.realpath(x) for x in a[:len(want)]]
    check(got == want, f"{name}: -e per extension of the bundled integration first: {a[:len(want)]}")
    check(all(os.path.isfile(os.path.join(p, "index.ts")) for p in want[1::2]), f"{name}: each -e folder has its index.ts")
    check(st["bridge"] == ["DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_SHOTS_DIR"], f"{name}: bridge variables DECKHAND_* only: {st['bridge']}")
if len(starts) == len(names):
    check("--session-id" in starts[0]["argv"] and "--session-id" in starts[1]["argv"], "the new chats start with --session-id")
    check(any(x.endswith("_c0de0000-1111-4222-8333-444455556666.jsonl") for x in starts[3]["argv"]), "the resumed chat resumes its file")
sys.exit(0 if ok else 1)
PY
if [ $fail = 1 ]; then echo "pi-chat-start scene failed (logs: $W)"; exit 1; fi
echo "pi-chat-start scene ok"
