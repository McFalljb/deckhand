#!/bin/sh
# A fake pi for tests/scripts/panels.sh: prints a pi-like screen, then plays
# the pi integration's bridge over Deckhand's socket with `deckhand --ctl` (the tab's
# DECKHAND_SOCKET and single-use DECKHAND_TOKEN, which --ctl reads as DECKHAND_*): pi.session, pi.status and, for a new chat,
# panel.set in pi-kit's row format. The status depends on which session pi
# was started for (sessions aaaa-1, bbbb-2, cccc-3 of the fake store).
# Stays connected, like a bridge: panels are dropped when it hangs up.
DECKHAND=${DECKHAND_BIN:?}
[ -n "${DECKHAND_FAKE_MAX:-}" ] && exec python3 "$(dirname "$0")/fake-bridge-max.py"
case "$*" in
  *aaaa-1*) id=aaaa-1; st='"agent":"working","waiting":true,"blockers":[]' ;;
  *bbbb-2*) id=bbbb-2; st='"agent":"idle","waiting":false,"question":true,"blockers":[]' ;;
  *cccc-3*) id=cccc-3; st='"agent":"error","waiting":false,"blockers":[]' ;;
  *) id=new-1; st='"agent":"working","waiting":false,"blockers":["shell sh1: npm test"]' ;;
esac
printf '\033[2J\033[H\033[1mpi\033[0m  fake bridge · session %s\n\n> Run the tests in the background and track the todo list.\n\n  Started npm test as sh1; working through the todos.\n' "$id"
set -- "{\"id\":\"s\",\"v\":1,\"type\":\"pi.session\",\"pi_session_id\":\"$id\",\"session_file\":\"\",\"cwd\":\"$PWD\"}" \
  "{\"id\":\"t\",\"v\":1,\"type\":\"pi.status\",$st}"
if [ "$id" = new-1 ]; then
  set -- "$@" \
    '{"id":"p1","v":1,"type":"panel.set","panel":"subagents","title":"Subagents","rows":[{"text":"Subagents · 2 running","head":true},{"text":"● kit.worker 1m12s · bash","tone":"accent"},{"text":"  Add panel.set to the socket and State","tone":"muted"},{"text":"● kit.reviewer 34s · read","tone":"accent"},{"text":"  Review the right column layout","tone":"muted"},{"text":"✓ kit.worker 3m02s","tone":"success"},{"text":"  Fix the flaky resume smoke test","tone":"muted"}]}' \
    '{"id":"p2","v":1,"type":"panel.set","panel":"shells","title":"Shells","rows":[{"text":"Shells","head":true},{"text":"sh1 running 2m","tone":"accent"},{"text":"  npm test -- --watch=false","tone":"muted"},{"text":"wk1 every 5m","tone":"warning"},{"text":"  check CI on PR #8","tone":"muted"}]}' \
    '{"id":"p3","v":1,"type":"panel.set","panel":"todos","title":"Todos","rows":[{"text":"Todos 2/5","head":true},{"text":"✓ Read PROTOCOL.md §5","tone":"dim"},{"text":"✓ panel.set in the command layer","tone":"dim"},{"text":"▸ Drawing the right column","tone":"accent"},{"text":"○ Status dots from pi.status"},{"text":"○ A very long todo that has to be cut by pixel width so it never wraps or overflows the column"}]}'
fi
DECKHAND_SOCKET=${DECKHAND_SOCKET:-} DECKHAND_TOKEN=${DECKHAND_TOKEN:-} exec "$DECKHAND" --ctl --wait 600000 "$@" > /dev/null 2>&1
