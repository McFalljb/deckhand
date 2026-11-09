#!/bin/sh
# scripts/install.sh's checks before any download, without the network: its options, the
# macOS and Apple silicon checks (Rosetta counts as arm64), and that a running Deckhand stops it.
# uname, sysctl, pgrep and curl are fakes on PATH (curl fails the test if it is ever called).
# Usage: tests/scripts/install-test.sh (a second; also run by ./build.sh test)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/uname" <<'SH'
#!/bin/sh
case "$1" in -s) echo "${FAKE_S:-Darwin}" ;; -m) echo "${FAKE_M:-arm64}" ;; esac
SH
cat > "$T/bin/sysctl" <<'SH'
#!/bin/sh
echo "${FAKE_ARM64:-1}"
SH
cat > "$T/bin/pgrep" <<'SH'
#!/bin/sh
[ "${FAKE_RUNNING:-0}" = 1 ]
SH
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
echo "CURL CALLED" >&2; exit 99
SH
chmod +x "$T/bin/"*
fail=0
# check NAME WANT 'VAR=VALUE ...' [install.sh options]: install.sh fails, says WANT, never calls curl
check() {
  name=$1 want=$2 vars=$3; shift 3
  # shellcheck disable=SC2086 # vars: the fakes' settings, split on purpose
  out=$(env PATH="$T/bin:$PATH" DECKHAND_VERSION= $vars sh "$ROOT/scripts/install.sh" "$@" 2>&1 </dev/null); code=$?
  if [ $code = 0 ] || ! printf '%s' "$out" | grep -qF -- "$want" || printf '%s' "$out" | grep -q "CURL CALLED"; then
    echo "$name: FAILED (exit $code): $out"; fail=1
  else echo "$name: ok"; fi
}
check "unknown option" "unknown option: --bogus" "" --bogus
check "--version without a value" "--version needs a value" "" --version
check "--dir without a value" "--dir needs a path" "" --dir
check "a bad --version" "not a version: 1.2" "" --version 1.2
check "a bad DECKHAND_VERSION" "not a version: latest" "DECKHAND_VERSION=latest"
check "not macOS" "macOS only" "FAKE_S=Linux" --dir "$T/apps"
check "Intel" "Apple silicon" "FAKE_M=x86_64 FAKE_ARM64=0" --dir "$T/apps"
check "Rosetta shell: passes, then a running Deckhand" "Deckhand is running" "FAKE_M=x86_64 FAKE_ARM64=1 FAKE_RUNNING=1" --dir "$T/apps"
check "a running Deckhand" "Quit Deckhand and Stop All Sessions" "FAKE_RUNNING=1" --dir "$T/apps" --version 0.1.6
[ ! -e "$T/apps" ] || { echo "the install folder was made before the checks passed"; fail=1; }
if [ $fail = 0 ]; then echo "install test ok"; else echo "install test failed"; exit 1; fi
