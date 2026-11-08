#!/bin/sh
# Deckhand started from the Dock by someone whose pi is on a folder only the login shell adds
# (nvm, fnm, mise or pnpm in ~/.zprofile), with an interactive shell that never answers (a slow
# or stuck ~/.zshrc): the environment probe times out, no stat finds pi, and pi is still not
# "not installed" (src/harness.odin asks `$SHELL -l -c 'command -v pi'`). New session then starts
# pi, from the login shell's PATH; with no pi there either, pi is not installed (the control).
# The pi is a tiny shell script: never a real pi.
# Screenshots: build/shots/pi-login-lookup/. Usage: tests/scripts/pi-login-lookup.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/pi-login-lookup"
rm -rf "$W" build/shots/pi-login-lookup
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/code/demo"
BARE=/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p "$PROJ" "$FAKE_HOME/lpi/bin" "$W/empty" "$W/data"
printf '#!/bin/sh\necho "FAKE PI login ARGS: $*"\nexec sleep 600\n' > "$FAKE_HOME/lpi/bin/pi"
chmod 755 "$FAKE_HOME/lpi/bin/pi"
# interactive: hangs (Deckhand's probe gives up); login only: adds ~/lpi/bin, as a .zprofile would
cat > "$W/fakesh" <<'SH'
#!/bin/sh
for a in "$@"; do [ "$a" = -i ] && exec sleep 30; done
while [ "$1" = -l ]; do shift; done
PATH="$HOME/lpi/bin:$PATH"; export PATH
exec /bin/sh "$@"
SH
chmod 755 "$W/fakesh"
# never a real pi: the login shell's pi is the fake one
got=$(env -i HOME="$FAKE_HOME" PATH=$BARE "$W/fakesh" -l -c 'command -v pi' </dev/null 2>/dev/null || true)
if [ "$got" != "$FAKE_HOME/lpi/bin/pi" ]; then echo "pi-login-lookup: unsafe, the login shell's pi would be '$got'"; exit 1; fi

fail=0
# run N HOME SCRIPT: Deckhand with launchd's environment and nothing else
run() {
  mkdir -p "$W/data-$1"
  env -i HOME="$2" PATH="$BARE" SHELL="$W/fakesh" DECKHAND_PATH_DIRS="$W/empty" TMPDIR="${TMPDIR:-/tmp}" \
    DECKHAND_GUI_LAUNCH=1 DECKHAND_REAL_PI=1 \
    DECKHAND_SCRIPT="tests/scripts/$3" DECKHAND_DATA_DIR="$W/data-$1" \
    build/deckhand > "$W/run-$1.log" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-$1.log" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-$1.log" || ! grep -q "done:" "$W/run-$1.log"; then
    echo "FAILED: run $1 (log: $W/run-$1.log)"; fail=1
  fi
}
# 1. pi on the login shell's PATH only: found, and New session starts it
run 1 "$FAKE_HOME" pi-login-lookup.txt
# 2. the control: no pi there either: the login shell's answer is no, and pi is not installed
mkdir -p "$W/home2/code/demo"
run 2 "$W/home2" pi-login-lookup-none.txt
if grep -q "not installed" "$W/run-1.log"; then echo "FAILED: run 1 said pi is not installed"; fail=1; fi
[ "$fail" = 0 ] && echo "pi-login-lookup: ok"
exit "$fail"
