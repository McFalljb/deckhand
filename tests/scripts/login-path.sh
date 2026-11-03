#!/bin/sh
# pi-desk started from the Dock or Finder: launchd's bare PATH
# (/usr/bin:/bin:/usr/sbin:/sbin), with pi on a folder only the user's
# interactive shell setup adds (Homebrew's `brew shellenv` in ~/.zshrc).
# Each run starts pi-desk with `env -i` and a fake HOME, opens a past session
# from the sidebar and checks which pi its tabs ran (the project argument
# opens a new session too). The pis are tiny shell scripts: never a real pi.
#   1. SHELL=/bin/zsh, ~/.zshrc puts ~/brew/bin first: the pi tabs find the
#      fake pi there (src/login_env.odin takes `zsh -i -l -c`'s environment).
#   2. a shell whose interactive start fails: the fallback folders
#      (PI_DESK_PATH_DIRS stands in for /opt/homebrew/bin and the rest)
#   3. no pi anywhere: the tab says so and names the profile to fix
# Screenshots: build/shots/login-path/. Usage: tests/scripts/login-path.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/login-path"
rm -rf "$W" build/shots/login-path
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/code/demo"
STORE="$FAKE_HOME/.pi/agent/sessions/--code-demo--"
BARE=/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p "$PROJ" "$STORE" "$FAKE_HOME/brew/bin" "$W/fallback/bin" "$W/empty" "$W/data-1" "$W/data-2" "$W/data-3"
printf '{"type":"session","version":3,"id":"past-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Fix the demo build"}}\n' "$PROJ" \
  > "$STORE/2026-10-30T10-00-00-000Z_past-1.jsonl"
# fake pi NAME DIR: prints which one ran and its arguments, then waits
fake_pi() {
  printf '#!/bin/sh\necho "FAKE PI %s ARGS: $*"\nprintf "%%s\\n" "%s" >> "$HOME/pi-ran.txt"\nexec sleep 600\n' "$1" "$1" > "$2/pi"
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
# PATH (pi-desk takes that environment), and a login shell that resets PATH
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
# run N SHELL DIRS: pi-desk with launchd's environment and nothing else
run() {
  : > "$FAKE_HOME/pi-ran.txt"
  env -i HOME="$FAKE_HOME" PATH=$BARE SHELL="$2" PI_DESK_PATH_DIRS="$3" TMPDIR="${TMPDIR:-/tmp}" \
    PI_DESK_SCRIPT="tests/scripts/login-path-$1.txt" PI_DESK_DATA_DIR="$W/data-$1" \
    build/pi-desk "$PROJ" > "$W/run-$1.log" 2>&1 || true
  cp "$FAKE_HOME/pi-ran.txt" "$W/ran-$1.txt"
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-$1.log" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-$1.log" || ! grep -q "done:" "$W/run-$1.log"; then
    echo "FAILED: run $1 (log: $W/run-$1.log)"; fail=1
  fi
}
run 1 /bin/zsh "$W/empty"
chk "run 1 ran the pi from ~/.zshrc's PATH" '[ "$(sort -u "$W/ran-1.txt")" = brew ]'
run 2 "$W/fakesh" "$W/empty:$W/fallback/bin"
chk "run 2 ran the fallback folder's pi" '[ "$(sort -u "$W/ran-2.txt")" = fallback ]'
run 3 "$W/fakesh" "$W/empty"
chk "run 3 ran no pi" '[ ! -s "$W/ran-3.txt" ]'
if [ $fail = 1 ]; then echo "login-path scene failed (logs: $W/run-*.log)"; exit 1; fi
echo "login-path scene ok"
