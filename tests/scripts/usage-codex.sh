#!/bin/sh
# The USAGE section against a fake Codex app-server (docs/GUIDE.md "Usage"; src/core/usage*.odin):
# never a real codex. tests/scripts/fake-codex.py's app-server mode answers initialize and
# account/rateLimits/read for each Codex home as Codex would: the default home and "Work" signed in
# (Work near its limits), "Twin" signed in to the default's account (merged into its row), "Key"
# with an API key (no plan limits), "Out" signed out. Each home's auth.json is a FIFO: the fake
# fails a run that finds a reader holding it open, and this script checks at the end that none
# does (Deckhand never reads auth.json; nothing under a home is written).
# Run 1 (usage-codex-1.txt): the accounts, their reads (one at a time), the rows, the hover, a
# narrow column, Refresh usage, folded. Run 2 (usage-codex-2.txt): after a restart the rows come
# back from the saved workspace with their age, folded (no read while folded), then unfolded.
# Then the fake's log is checked. Writes build/usage-codex/ and build/shots/usage-codex/.
# Usage: tests/scripts/usage-codex.sh
set -eu
unset CLAUDE_CONFIG_DIR CODEX_HOME
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/usage-codex"
rm -rf "$W" build/shots/usage-codex
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"uuuu-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_uuuu-1.jsonl"
[ -x build/deckhand ] || { echo "usage-codex scene: build/deckhand missing (./build.sh)"; exit 1; }
# Codex "installed" by npm (a stand-in package, never run: reads run the fake)
pkg="$W/npm/lib/node_modules/@openai/codex"
mkdir -p "$pkg/bin" "$W/npm/bin"
printf '{"name":"@openai/codex","version":"0.167.2"}\n' > "$pkg/package.json"
printf '#!/bin/sh\necho "stand-in codex (tests): never run" >&2\nexit 1\n' > "$pkg/bin/codex.js"
chmod 755 "$pkg/bin/codex.js"
ln -sf "$pkg/bin/codex.js" "$W/npm/bin/codex"
# the homes: a FIFO for each sign-in; fake-usage.json is what this fake Codex answers
NOW=$(date +%s)
home() { # DIR SIGNED-IN(1/0) [FAKE-USAGE-JSON]
  mkdir -p "$1"
  [ "$2" = 1 ] && mkfifo "$1/auth.json"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$1/fake-usage.json"
  return 0
}
lim() { # 5H% WK% ACCOUNT [REACHED]
  printf '{"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":%s,"windowDurationMins":300,"resetsAt":%d},"secondary":{"usedPercent":%s,"windowDurationMins":10080,"resetsAt":%d},"credits":{"hasCredits":false,"unlimited":false,"balance":null},"rateLimitReachedType":%s},"rateLimitsByLimitId":null,"accountId":"%s"}}' \
    "$1" $((NOW + 3 * 3600)) "$2" $((NOW + 4 * 86400)) "${4:-null}" "$3"
}
home "$FAKE_HOME/.codex" 1 "$(lim 42 18 acct-main)"
home "$FAKE_HOME/codex-work" 1 "$(lim 85 97 acct-work)"
home "$FAKE_HOME/codex-twin" 1 "$(lim 42 18 acct-main)" # the same account: the same numbers
home "$FAKE_HOME/codex-key" 1 '{"mode":"apikey"}'
home "$FAKE_HOME/codex-out" 0
LOG="$W/usage.log"
# the fake needs tomllib (Python 3.11+): the first python3 that has it, else Homebrew's (a PATH
# with /usr/bin first, as the build wants, finds macOS's 3.9); as tests/scripts/codex.sh
PY=
for c in python3 python3.14 python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  PY=$("$c" -I -c 'import sys, tomllib; print(sys.executable)' 2>/dev/null) && break
  PY=
done
[ -n "$PY" ] || { echo "$(basename "$0" .sh) scene: no python3 with tomllib (Python 3.11+ needed)"; exit 1; }
fail=0
for n in 1 2; do
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdu.XXXXXX")
  env HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/usage-codex-$n.txt \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD='exec sleep 600' \
    DECKHAND_CODEX_BIN="$W/npm/bin/codex" \
    DECKHAND_CODEX_CMD="exec '$PY' -I '$ROOT/tests/scripts/fake-codex.py' \"\$@\"" \
    FAKE_CODEX_USAGE_LOG="$LOG" \
    build/deckhand > "$W/run$n.log" 2>&1 || true
  rm -rf "$RUN"
  grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run$n.log" | sed "s/^/run $n: /" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run$n.log" || ! grep -q 'done:' "$W/run$n.log"; then
    echo "run $n: FAILED (log: $W/run$n.log)"; fail=1
  fi
  if [ $n = 1 ]; then
    cp "$LOG" "$W/usage-run1.log" 2>/dev/null || true
    # ten minutes pass before the restart: every read due again (but folded: none until unfolded)
    python3 -I - "$W/data/workspace.json" <<'PY'
import json, sys, time
p = sys.argv[1]
w = json.load(open(p))
for u in w.get("usage", []):
    u["read_at"] = int(time.time()) - 600
json.dump(w, open(p, "w"))
PY
  fi
done
# what the fake app-server saw
python3 -I - "$LOG" "$W/usage-run1.log" "$FAKE_HOME" <<'PY' || fail=1
import json, sys
log, run1, home = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(l) for l in open(log) if l.strip()]
first = [json.loads(l) for l in open(run1) if l.strip()]
ok = True
def bad(m):
    global ok
    ok = False
    print("FAILED:", m)
for r in rows:
    if r["bad"]:
        bad(f"{r['home']}: {r['bad']}")
    if r["methods"] != ["initialize", "initialized", "account/rateLimits/read"]:
        bad(f"{r['home']}: methods {r['methods']}")
    if r["client"] != "deckhand":
        bad(f"client {r['client']}")
homes = {r["home"] for r in first}
want = {f"{home}/.codex", f"{home}/codex-work", f"{home}/codex-twin", f"{home}/codex-key", f"{home}/codex-out"}
if homes != want:
    bad(f"run 1 read {sorted(homes)}, want {sorted(want)}")
# Refresh usage read every home again
if len(first) < 2 * len(want):
    bad(f"run 1: {len(first)} reads (want at least {2 * len(want)}: the first reads, then Refresh usage)")
# one read at a time
spans = sorted((r["start"], r["end"]) for r in rows)
for a, b in zip(spans, spans[1:]):
    if b[0] < a[1] - 0.05:
        bad(f"two reads at once: {a} and {b}")
# run 2 read only after it was unfolded: one more round, not two
if len(rows) - len(first) < len(want):
    bad(f"run 2: {len(rows) - len(first)} reads (want {len(want)} once unfolded)")
print("ok: the fake app-server's log" if ok else "the fake app-server's log: FAILED")
sys.exit(0 if ok else 1)
PY
# nobody holds a sign-in open, and nothing new under a home (the fake writes nothing either)
for h in "$FAKE_HOME/.codex" "$FAKE_HOME/codex-work" "$FAKE_HOME/codex-twin" "$FAKE_HOME/codex-key"; do
  if ! python3 -I -c 'import os,sys,errno
try:
    os.close(os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)); sys.exit(1)
except OSError as e:
    sys.exit(0 if e.errno == errno.ENXIO else 1)' "$h/auth.json"; then echo "FAILED: $h/auth.json is open for reading"; fail=1; fi
  extra=$(ls -A "$h" | grep -vxE 'auth.json|fake-usage.json' || true)
  [ -n "$extra" ] && { echo "FAILED: something wrote $h: $extra"; fail=1; }
done
[ -z "$(ls -A "$FAKE_HOME/codex-out" | grep -vx fake-usage.json || true)" ] || { echo "FAILED: something wrote $FAKE_HOME/codex-out"; fail=1; }
# the saved workspace keeps numbers and labels, never an account id
if grep -qE 'acct-(main|work)' "$W/data/workspace.json"; then echo "FAILED: an account id in workspace.json"; fail=1; fi
grep -q '"usage":' "$W/data/workspace.json" || { echo "FAILED: no usage in workspace.json"; fail=1; }
[ $fail = 0 ] && echo "usage-codex scene ok" || { echo "usage-codex scene failed"; exit 1; }
