#!/bin/sh
# Atlas's jobs, step 1 (docs/ATLAS.md §9), end to end in test mode with a
# fake `pi --mode json` (tests/scripts/fake-pi-json.py, setting pi_path), a
# fake HOME, a fake notes folder and a temp data dir: never the user's vault,
# ~/.pi or real jobs. Covers Run now → run folder, meta.json and run line;
# an overlapping tick → skipped (previous run still going); a late tick past
# the grace window → one skipped line; an `at` job disables itself; a
# per-run limit → over_limit; a daily limit reached mid-run → the run
# finishes, the next tick is skipped; 5 identical tool calls → looping;
# silence → stalled; 3 failures → paused + a nudge; a missing folder →
# folder_missing, paused, history kept; "Needs user approval" → needs_you
# with the stored action; PI_DESK_SCHEDULED_AT set (and no pi-desk socket or
# tokens); no approvals: a prompt edited in the file runs as edited, a job
# from control (an agent's job_create) runs on its schedule, and pi-desk has
# no Keychain code (no Security framework, no SecItem symbols);
# ATLAS.md copied into the notes folder; redaction; the Jobs tab's buttons;
# idle CPU. Screenshots: build/shots/jobs/ (dark and light).
# Usage: tests/scripts/jobs.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/jobs"
rm -rf "$W" build/shots/jobs build/test-trash
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
NOTES="$FAKE_HOME/notes"
mkdir -p "$PROJ" "$W/data/atlas" "$NOTES/jobs" "$FAKE_HOME/bin" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"jjjj-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_jjjj-1.jsonl"
cp tests/scripts/fake-pi-json.py "$FAKE_HOME/bin/pi"
chmod 755 "$FAKE_HOME/bin/pi"
# Atlas's prompt as the user customised it, in the data folder (§8 moves a copy)
printf '# Atlas\n\nCustom prompt text from the data folder.\n' > "$W/data/atlas/ATLAS.md"

note() { # note FILE ID SCHEDULE PROMPT [extra frontmatter lines]
  f="$NOTES/jobs/$1.md"; id=$2; sched=$3; prompt=$4; shift 4
  { printf -- '---\ntype: job\nproject: atlas\ndate: 2026-11-01\nstatus: active\nsummary: %s\ntags: [job]\nupdated_by: claude\nid: %s\nenabled: false\nschedule: "%s"\nnotify: always\n' "$id" "$id" "$sched"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n# Job %s\n\n## Prompt\n%s\n' "$id" "$prompt"; } > "$f"
}
AT=$(date -v+1H "+%Y-%m-%d %H:%M")
note blocked blk1 manual BLOCKED
note atfile at2 manual "@OK" "access: full"
note costly cost1 manual COSTLY "max_cost: 0.50"
note dash dash1 manual "-OK"
note fail fail1 manual FAIL "folder: ~/proj"
note gone gone1 manual OK "folder: $W/no-such-folder"
note late late1 "every 10m" OK
note loop loop1 manual LOOP
note ok ok1 manual OK "folder: ~/proj" "access: read"
note once at1 "at $AT" OK
note overlap ovl1 "* * * * *" "SLOW 6"
note secret sec1 manual SECRET
note silent sil1 manual SILENT
note spend spend1 "* * * * *" SPEND "access: full"

HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/jobs.txt PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_CMD='echo "ARGS: $*"; exec sleep 600' build/pi-desk "$PROJ" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|TIMEOUT|done:|no element|CPU|unknown command" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
chk() { if ! eval "$2"; then echo "FAILED: $1"; fail=1; fi; }
D="$W/data/jobs"
# Run now → run folder, meta.json, summary.md, the note's run line
chk "ok1 run folder" 'ls "$D"/ok1/runs/*/meta.json >/dev/null 2>&1'
chk "ok1 meta status" 'grep -q "\"status\":\"ok\"" "$D"/ok1/runs/*/meta.json'
chk "ok1 events.jsonl" 'grep -q agent_settled "$D"/ok1/runs/*/events.jsonl'
chk "ok1 summary" 'grep -q "All good, scheduled" "$D"/ok1/runs/*/summary.md'
chk "ok1 run line" 'grep -q "✅ ok" "$NOTES/jobs/ok.md"'
chk "ok1 preamble" 'grep -q "running unattended" "$D"/ok1/runs/*/preamble.md'
# the environment: an allowlist; no pi-desk socket or tokens; the scheduled time; read-only
chk "PI_DESK_SCHEDULED_AT" 'grep -q "^PI_DESK_SCHEDULED_AT=20" "$FAKE_HOME/pi-env-ok1.txt"'
chk "PI_KIT_READONLY" 'grep -q "^PI_KIT_READONLY=1" "$FAKE_HOME/pi-env-ok1.txt"'
chk "PI_KIT_NOTES_DIR" 'grep -q "^PI_KIT_NOTES_DIR=$NOTES" "$FAKE_HOME/pi-env-ok1.txt"'
chk "no socket/tokens" '! grep -qE "^PI_DESK_(SOCKET|TOKEN|CONTROL_TOKEN)=" "$FAKE_HOME"/pi-env-*.txt'
chk "full access: not read-only" '! grep -q "^PI_KIT_READONLY" "$FAKE_HOME/pi-env-spend1.txt"'
chk "argv" 'grep -q "ARGS: --mode json --session-dir $D/ok1/sessions --session-id" "$FAKE_HOME/pi-env-ok1.txt"'
chk "read: pi's read tools only, no MCP" 'grep -q -- "--tools read,grep,find,ls --no-mcp" "$FAKE_HOME/pi-env-ok1.txt"'
chk "full: pi's own tools" '! grep -q -- "--tools" "$FAKE_HOME/pi-env-spend1.txt"'
chk "a prompt starting with - or @ runs as a prompt" 'grep -q "\"status\":\"ok\"" "$D"/dash1/runs/*/meta.json && grep -q "\"status\":\"ok\"" "$D"/at2/runs/*/meta.json'
chk "the prompt after --" 'grep -q -- " -- -OK" "$FAKE_HOME/pi-env-dash1.txt"'
chk "stalled while minimised" '[ "$(ls "$D"/sil1/runs | wc -l | tr -d " ")" = 2 ] && [ "$(grep -l "\"status\":\"stalled\"" "$D"/sil1/runs/*/meta.json | wc -l | tr -d " ")" = 2 ]'
chk "argv: Atlas prompt from the notes folder" 'grep -q -- "--append-system-prompt $NOTES/atlas/ATLAS.md" "$FAKE_HOME/pi-env-ok1.txt"'
chk "run dirs 0700" '[ "$(stat -f %Lp "$(ls -d "$D"/ok1/runs/* | head -1)")" = 700 ]'
# overlap, late tick, at
chk "overlap skipped" 'grep -q "skipped (previous run still going)" "$NOTES/jobs/overlap.md"'
chk "late: one skipped line" '[ "$(grep -c "skipped" "$NOTES/jobs/late.md")" = 1 ] && grep -q "skipped (asleep)" "$NOTES/jobs/late.md"'
chk "at: ran" 'grep -q "✅ ok" "$NOTES/jobs/once.md"'
chk "at: disabled itself" 'grep -q "^enabled: false" "$NOTES/jobs/once.md"'
# limits and safety stops
chk "over_limit" 'grep -q "\"status\":\"over_limit\"" "$D"/cost1/runs/*/meta.json'
chk "daily limit: the run finished" 'grep -q "\"status\":\"ok\"" "$D"/spend1/runs/*/meta.json'
chk "daily limit: next tick skipped" 'grep -q "skipped (limit reached)" "$NOTES/jobs/spend.md"'
chk "looping" 'grep -q "\"status\":\"looping\"" "$D"/loop1/runs/*/meta.json'
chk "stalled" 'grep -q "\"status\":\"stalled\"" "$D"/sil1/runs/*/meta.json'
chk "3 failures" '[ "$(grep -c "❌ failed" "$NOTES/jobs/fail.md")" = 3 ]'
chk "auto-pause in state.json" 'grep -q "\"paused\":true" "$D/fail1/state.json" && grep -q "3 failures in a row" "$D/fail1/state.json"'
chk "nudge notification" 'grep -q "notify: Job fail1 is paused" "$W/run.log"'
chk "no notification in front" '[ "$(sed -n "/window_active on/,/window_active off/p" "$W/run.log" | grep -c "notify:")" = 0 ]'
chk "the bell has the runs" 'grep -q "\"job_id\":\"blk1\"" "$W/bell.json" && grep -q "\"status\":\"needs_you\"" "$W/bell.json"'
chk "idle: no frames" 'grep "CPU jobs idle" "$W/run.log" | grep -qE " 0 frames drawn"'
chk "folder_missing" 'grep -q "\"status\":\"folder_missing\"" "$D"/gone1/runs/*/meta.json && grep -q "folder_missing" "$NOTES/jobs/gone.md"'
chk "folder_missing: note kept" '[ -f "$NOTES/jobs/gone.md" ]'
chk "needs_you + stored action" 'grep -q "\"status\":\"needs_you\"" "$D"/blk1/runs/*/meta.json && grep -q "\"command\":\"git push --force\"" "$D"/blk1/runs/*/meta.json && grep -q "\"sha256\":\"[0-9a-f]\{64\}\"" "$D"/blk1/runs/*/meta.json'
# redaction: never in the note, the summary, the meta, the log or the state
# the fake key (fake-pi-json.py's SECRET answer), put together so no file holds it whole
FAKE_KEY="sk-""ant-api03-ABCDEFGHIJKLMNOPQRSTUVWX"
chk "redacted" '! grep -rq "$FAKE_KEY" "$NOTES" "$D"/sec1/runs/*/summary.md "$D"/sec1/runs/*/meta.json "$D/sec1/state.json" "$W/data/commands.log"'
chk "redacted marker" 'grep -q "\[REDACTED\]" "$D"/sec1/runs/*/summary.md'
# the job.finished event (the notification centre's), and no Atlas notice
chk "job.finished event" 'grep -q "\"event\":\"job.finished\",\"job\":\"ok1\"" "$W/data/commands.log"'
# ATLAS.md moved as a copy (§8); the data folder's stays
chk "ATLAS.md copied" 'grep -q "Custom prompt text" "$NOTES/atlas/ATLAS.md" && grep -q "^type: atlas" "$NOTES/atlas/ATLAS.md"'
chk "ATLAS.md fallback kept" 'grep -q "Custom prompt text" "$W/data/atlas/ATLAS.md"'
# Delete → the Trash (test mode: build/test-trash); history kept
chk "deleted to the trash" '[ ! -f "$NOTES/jobs/zz-draft.md" ] && ls build/test-trash | grep -q zz-draft'
chk "scheduler.log" 'grep -q "skipped (asleep)" "$D/scheduler.log"'
# no approvals: the edited prompt ran as written (the agent's job: jobs.txt waits for its run)
chk "edited prompt ran" 'grep -q -- " -- OK as edited" "$FAKE_HOME/pi-env-ok1.txt"'
chk "no approval key file" '[ ! -e "$D/approval.key" ]'
chk "no approval record in state.json" '! grep -lq "approved" "$D"/*/state.json'
# no Keychain code path: the binary neither links the Security framework nor calls SecItem*
BIN=build/pi-desk
[ -f build/pi-desk.app/Contents/MacOS/pi-desk ] && BIN=build/pi-desk.app/Contents/MacOS/pi-desk
chk "no SecItem/SecKeychain symbols" '! nm -u "$BIN" | grep -qE "_Sec(Item|Keychain)"'
chk "no Security framework" '! otool -L "$BIN" | grep -q Security.framework'
# nothing outside the fake places: no notes written to the real vault
if [ $fail = 1 ]; then echo "jobs scene failed (log: $W/run.log)"; exit 1; fi
echo "jobs scene ok"
