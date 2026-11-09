#!/bin/sh
# Deckhand started from the Dock or Finder: launchd's bare PATH
# (/usr/bin:/bin:/usr/sbin:/sbin), with pi on a folder only the user's
# interactive shell setup adds (Homebrew's `brew shellenv` in ~/.zshrc).
# Each run starts Deckhand with `env -i` and a fake HOME, opens a past session
# from the sidebar and checks which pi its tabs ran (the project argument
# opens a new session too). The pis are tiny shell scripts: never a real pi.
#   1. SHELL=/bin/zsh, ~/.zshrc puts ~/brew/bin first: the pi tabs find the
#      fake pi there (src/core/login_env.odin takes `zsh -i -l -c`'s environment).
#   2. a shell whose interactive start fails: the fallback folders
#      (DECKHAND_PATH_DIRS stands in for /opt/homebrew/bin and the rest)
#   3. no pi anywhere: the tab says so and names the profile to fix
#   4. issue #2: launchd's PATH is NOT bare (Nix-like folders) and
#      DECKHAND_GUI_LAUNCH=1 stands in for launchd as the parent: the shell's
#      environment is still merged in (a fake Homebrew folder, a marker
#      variable), pi is found in its managed install ~/.pi/agent/bin only,
#      and the gear's "Refresh shell environment" gives NEW shell tabs the
#      shell's new answer while the open one keeps the old.
#   5. as run 1, but started from a shell inside a Claude Code session (`open`
#      from Claude's Bash tool): that session's markers and its
#      CLAUDE_CONFIG_DIR and CLAUDE_EFFORT are inherited; the login shell sets
#      neither. The pi tab gets no marker and not the parent's config folder.
# Screenshots: build/shots/login-path/. Usage: tests/scripts/login-path.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/login-path"
rm -rf "$W" build/shots/login-path
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/code/demo"
STORE="$FAKE_HOME/.pi/agent/sessions/--code-demo--"
BARE=/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p "$PROJ" "$STORE" "$FAKE_HOME/brew/bin" "$W/fallback/bin" "$W/empty" "$W/data-1" "$W/data-2" "$W/data-3" "$W/data-4" "$W/data-5"
printf '{"type":"session","version":3,"id":"past-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Fix the demo build"}}\n' "$PROJ" \
  > "$STORE/2026-10-30T10-00-00-000Z_past-1.jsonl"
# fake pi NAME DIR: prints which one ran and its arguments, then waits
fake_pi() {
  printf '#!/bin/sh\n/usr/bin/env > "$HOME/pi-env.txt"\necho "FAKE PI %s ARGS: $*"\nprintf "%%s\\n" "%s" >> "$HOME/pi-ran.txt"\nexec sleep 600\n' "$1" "$1" > "$2/pi"
  chmod 755 "$2/pi"
}
fake_pi brew "$FAKE_HOME/brew/bin"
fake_pi fallback "$W/fallback/bin"
# interactive shells only (as `eval "$(brew shellenv)"` in ~/.zshrc)
printf 'echo "zshrc noise before"\nexport PATH="$HOME/brew/bin:$PATH"\necho "zshrc noise after"\n' > "$FAKE_HOME/.zshrc"
# a shell whose interactive start fails (a broken rc file); otherwise plain sh -c
cat > "$W/fakesh" <<'SH'
#!/bin/sh
for a in "$@"; do [ "$a" = -i ] && exit 1; done
while [ "$1" = -l ]; do shift; done
exec /bin/sh "$@"
SH
chmod 755 "$W/fakesh"

# never a real pi. Run 1: the fake pi comes first on the interactive shell's
# PATH (Deckhand takes that environment), and a login shell that resets PATH
# (nix-darwin's /etc/zshenv without the flag it exports) finds none. The others: none.
p1=$(env -i HOME="$FAKE_HOME" PATH=$BARE /bin/zsh -i -l -c 'printf "%s" "$PATH"' </dev/null 2>/dev/null | tail -1)
got=$(env -i PATH="$p1" /bin/sh -c 'command -v pi' || true)
if [ "$got" != "$FAKE_HOME/brew/bin/pi" ]; then echo "login-path: unsafe, run 1's pi would be '$got'"; exit 1; fi
got=$(env -i HOME="$FAKE_HOME" PATH=$BARE /bin/zsh -l -c 'command -v pi' </dev/null 2>/dev/null || true)
if [ -n "$got" ]; then echo "login-path: unsafe, a bare login shell finds '$got'"; exit 1; fi
for d in "$W/fallback/bin" "$W/empty"; do
  got=$(env -i HOME="$FAKE_HOME" PATH="$BARE:$d" "$W/fakesh" -l -c 'command -v pi' </dev/null 2>/dev/null || true)
  case "$got" in ""|"$W/fallback/bin/pi") ;; *) echo "login-path: unsafe, a fallback run's pi would be '$got'"; exit 1 ;; esac
done

fail=0
chk() { if ! eval "$2"; then echo "FAILED: $1"; fail=1; fi; }
# run N SHELL DIRS [PATH [GUI [SCRIPT]]]: Deckhand with launchd's environment and nothing else
# (and $EXTRA_ENV: K=V words). SCRIPT: another run's script (default: N's).
# Test mode never asks the shell unless DECKHAND_GUI_LAUNCH=1 (GUI=1) stands in
# for launchd as the parent, so every run here passes it.
run() {
  : > "$FAKE_HOME/pi-ran.txt"
  : > "$FAKE_HOME/pi-env.txt"
  env -i HOME="$FAKE_HOME" PATH="${4:-$BARE}" SHELL="$2" DECKHAND_PATH_DIRS="$3" TMPDIR="${TMPDIR:-/tmp}" \
    DECKHAND_GUI_LAUNCH="${5:-}" DECKHAND_REAL_PI=1 ${EXTRA_ENV:-} \
    DECKHAND_SCRIPT="tests/scripts/login-path-${6:-$1}.txt" DECKHAND_DATA_DIR="$W/data-$1" \
    build/deckhand "$PROJ" > "$W/run-$1.log" 2>&1 || true
  cp "$FAKE_HOME/pi-ran.txt" "$W/ran-$1.txt"
  cp "$FAKE_HOME/pi-env.txt" "$W/env-$1.txt"
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-$1.log" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-$1.log" || ! grep -q "done:" "$W/run-$1.log"; then
    echo "FAILED: run $1 (log: $W/run-$1.log)"; fail=1
  fi
}
run 1 /bin/zsh "$W/empty" "$BARE" 1
chk "run 1 ran the pi from ~/.zshrc's PATH" '[ "$(sort -u "$W/ran-1.txt")" = brew ]'
run 2 "$W/fakesh" "$W/empty:$W/fallback/bin" "$BARE" 1
chk "run 2 ran the fallback folder's pi" '[ "$(sort -u "$W/ran-2.txt")" = fallback ]'
run 3 "$W/fakesh" "$W/empty" "$BARE" 1
chk "run 3 ran no pi" '[ ! -s "$W/ran-3.txt" ]'

# Run 4 (issue #2): a non-bare launchd PATH; pi only in its managed install;
# Homebrew and a marker variable only from the interactive shell, whose
# answer changes each time it is asked (probe-1, probe-2: the refresh).
NIXISH="$W/nix/profile/bin:$W/nix/system/sw/bin:$BARE"
mkdir -p "$W/nix/profile/bin" "$W/nix/system/sw/bin" "$FAKE_HOME/brew4/bin" "$FAKE_HOME/.pi/agent/bin"
fake_pi managed "$FAKE_HOME/.pi/agent/bin"
printf '#!/bin/sh\necho "LE TOOL OK"\n' > "$FAKE_HOME/brew4/bin/le-tool"
chmod 755 "$FAKE_HOME/brew4/bin/le-tool"
cat > "$W/fakesh4" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = -i ]; then
    n=$(( $(cat "$HOME/probe-count" 2>/dev/null || echo 0) + 1 )); echo $n > "$HOME/probe-count"
    LE_SCENE_MARK="probe-$n"; PATH="$HOME/brew4/bin:$PATH"; export LE_SCENE_MARK PATH
  fi
done
while [ "$1" = -l ] || [ "$1" = -i ]; do shift; done
exec /bin/sh "$@"
SH
chmod 755 "$W/fakesh4"
rm -f "$FAKE_HOME/probe-count"
got=$(env -i PATH="$NIXISH" /bin/sh -c 'command -v pi; command -v le-tool' || true)
if [ -n "$got" ]; then echo "login-path: unsafe, run 4's PATH finds '$got'"; exit 1; fi
run 4 "$W/fakesh4" "$W/empty" "$NIXISH" 1
chk "run 4 ran the managed pi" '[ "$(sort -u "$W/ran-4.txt")" = managed ]'
chk "run 4 asked the shell twice (startup, refresh)" '[ "$(cat "$FAKE_HOME/probe-count")" = 2 ]'
chk "run 4 said the refresh worked" 'grep -q "toast: *Shell environment refreshed" "$W/run-4.log"'
chk "run 4 logged no marker value" '! grep -q "probe-[0-9]" "$W/data-4/commands.log" 2>/dev/null'

# Run 5: from inside a Claude Code session (its markers, CLAUDE_CONFIG_DIR and CLAUDE_EFFORT
# inherited; ~/.zshrc sets none of them). Run 1's script.
EXTRA_ENV="CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=parent-session CLAUDE_PID=4242 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CONFIG_DIR=$W/parent-claude CLAUDE_EFFORT=max"
run 5 /bin/zsh "$W/empty" "$BARE" 1 1
EXTRA_ENV=
chk "run 5 ran the pi from ~/.zshrc's PATH" '[ "$(sort -u "$W/ran-5.txt")" = brew ]'
chk "run 5's pi got no Claude Code session marker" '[ -s "$W/env-5.txt" ] && ! grep -qE "^(CLAUDECODE|CLAUDE_CODE_CHILD_SESSION|CLAUDE_CODE_SESSION_ID|CLAUDE_PID|CLAUDE_CODE_ENTRYPOINT)=" "$W/env-5.txt"'
chk "run 5's pi got neither the parent's CLAUDE_CONFIG_DIR nor its CLAUDE_EFFORT" '! grep -qE "^(CLAUDE_CONFIG_DIR|CLAUDE_EFFORT)=" "$W/env-5.txt"'

if [ $fail = 1 ]; then echo "login-path scene failed (logs: $W/run-*.log)"; exit 1; fi
echo "login-path scene ok"
