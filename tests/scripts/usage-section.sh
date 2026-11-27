#!/bin/sh
# The USAGE section's rows from a saved workspace (docs/GUIDE.md "Usage"; src/ui_usage.odin):
# a fresh read, one two hours old (faded) whose 5h window reset since, and a signed-out account.
# It starts folded (one line per account, no read while folded); unfolded while the app is hidden
# (still no read); shown again: the accounts due are read, not the fresh one (each read fails
# here: the fake app-server answers an error, so the last good numbers stay and say why). A narrow column, light and dark.
# Never a real codex: tests/scripts/fake-codex.py's app-server mode. Writes build/usage-section/
# and build/shots/usage-section/. Usage: tests/scripts/usage-section.sh
set -eu
unset CLAUDE_CONFIG_DIR CODEX_HOME
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/usage-section"
rm -rf "$W" build/shots/usage-section
FAKE_HOME="$W/home"
mkdir -p "$W/data" "$FAKE_HOME/.pi/agent/sessions"
[ -x build/deckhand ] || { echo "usage-section scene: build/deckhand missing (./build.sh)"; exit 1; }
pkg="$W/npm/lib/node_modules/@openai/codex"
mkdir -p "$pkg/bin" "$W/npm/bin"
printf '{"name":"@openai/codex","version":"0.167.2"}\n' > "$pkg/package.json"
printf '#!/bin/sh\nexit 1\n' > "$pkg/bin/codex.js"
chmod 755 "$pkg/bin/codex.js"
ln -sf "$pkg/bin/codex.js" "$W/npm/bin/codex"
D="$FAKE_HOME/.codex" WK="$FAKE_HOME/codex-work" OUT="$FAKE_HOME/codex-out"
mkdir -p "$D" "$WK" "$OUT"
mkfifo "$D/auth.json" "$WK/auth.json"
printf '{"mode":"error"}\n' > "$D/fake-usage.json"
printf '{"mode":"error"}\n' > "$WK/fake-usage.json"
NOW=$(date +%s)
RESET=$((NOW - 1800)) # Work's 5h window reset half an hour ago, after its read
python3 -I - "$W/data/workspace.json" "$NOW" "$D" "$WK" "$OUT" <<'PY'
import json, sys
path, now, d, wk, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
def win(p, mins, at): return {"name": "", "used_percent": p, "window_mins": mins, "resets_at": at}
ws = {
    "v": 1,
    "settings": {"setup_seen": True, "codex_accounts": [{"dir": wk, "label": "Work", "added": True}, {"dir": out, "label": "Out", "added": True}]},
    "sidebar": {"folded": {"usage": True}},
    "usage": [
        {"key": "codex:" + d, "source": "codex", "home": d, "label": "Codex", "plan": "plus", "status": "ok", "credits": "none", "limit_hit": False, "read_at": now - 240, "account_hash": "", "windows": [win(42, 300, now + 3 * 3600), win(18, 10080, now + 4 * 86400)]},
        {"key": "codex:" + wk, "source": "codex", "home": wk, "label": "Work", "plan": "pro", "status": "ok", "credits": "", "limit_hit": False, "read_at": now - 2 * 3600, "account_hash": "", "windows": [win(91, 300, now - 1800), win(30, 10080, now + 86400)]},
        {"key": "codex:" + out, "source": "codex", "home": out, "label": "Out", "plan": "", "status": "signed_out", "credits": "", "limit_hit": False, "read_at": now - 3 * 3600, "account_hash": "", "windows": []},
    ],
}
json.dump(ws, open(path, "w"))
PY
CLOCK=$(date -r "$RESET" '+%-H:%M')
sed "s/@RESET@/$CLOCK/g" tests/scripts/usage-section.txt > "$W/script.txt"
LOG="$W/usage.log"
PY=$(python3 -c 'import sys; print(sys.executable)')
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdv.XXXXXX")
env HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$W/script.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD='exec sleep 600' \
  DECKHAND_CODEX_BIN="$W/npm/bin/codex" \
  DECKHAND_CODEX_CMD="exec '$PY' -I '$ROOT/tests/scripts/fake-codex.py' \"\$@\"" \
  FAKE_CODEX_USAGE_LOG="$LOG" \
  build/deckhand > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
fail=0
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q 'done:' "$W/run.log"; then
  echo "FAILED (log: $W/run.log)"; fail=1
fi
python3 -I - "$LOG" <<'PY' || fail=1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
bad = [r for r in rows if r["bad"] or r["methods"] != ["initialize", "initialized", "account/rateLimits/read"]]
homes = sorted(r["home"].rsplit("/", 1)[1] for r in rows)
if homes != ["codex-out", "codex-work"] or bad:
    print(f"FAILED: reads of {homes} (want Work's and Out's, once shown; Codex's not due), bad: {bad}")
    sys.exit(1)
print("ok: Work and Out read, each initialize then account/rateLimits/read")
PY
[ $fail = 0 ] && echo "usage-section scene ok" || { echo "usage-section scene failed"; exit 1; }
