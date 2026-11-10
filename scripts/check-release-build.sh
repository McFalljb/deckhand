#!/bin/sh
# A release build has no test hooks (docs/plans/background-core.md §5.3, "A genuine binary under
# attacker config"; src/core/test_hooks.odin): fails if any binary given holds the name of a hook's
# environment variable (src/core/test_hooks.odin's HOOK_ENV), `--print-token`, the updater's test
# key, or any other `DECKHAND_…` or `PI_DESK_…` (the old names, 0.2.0's rename) name not in ALLOWED
# below (a knob added outside HOOK_ENV, such as a getenv in the CEF shim, is caught too). scripts/release.sh runs it on the app's executables;
# tests/scripts/release-checks.sh tests it.
# Usage: scripts/check-release-build.sh BINARY...   (run from anywhere; reads src/ next to it)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { echo "usage: scripts/check-release-build.sh BINARY..." >&2; exit 2; }
NAMES=$(sed -n 's/^[[:space:]]*\.[A-Za-z_]*[[:space:]]*= "\(DECKHAND_[A-Z_]*\)",*$/\1/p' "$ROOT/src/core/test_hooks.odin")
# the list itself must be there: an empty one would pass anything
n=$(printf '%s\n' "$NAMES" | grep -c DECKHAND_ || true)
[ "$n" -ge 20 ] || { echo "check-release-build: found only $n hook names in src/core/test_hooks.odin (HOOK_ENV moved?)" >&2; exit 1; }
TEST_PUB=$(sed -n 's/^.*UPDATE_TEST_PUBLIC_KEY :: "\(.*\)"$/\1/p' "$ROOT/src/core/update_key.odin")
# the source side: every environment read names a known variable, a literal (no "DECKHAND_%s"
# built at run time could pass the allowlist below unseen); test knobs go through hook_env
python3 -I "$ROOT/scripts/check-env-reads.py" >/dev/null || { echo "check-release-build: scripts/check-env-reads.py failed (above)" >&2; exit 1; }
# the holder's own test hooks (src/holder/keeper.odin, DECKHAND_TEST_HOOKS): never in a release holder
NAMES="$NAMES
DECKHAND_HOLDER_HOOKS"

# The only DECKHAND_ and PI_DESK_ names a release binary may hold. None is read to steer what
# Deckhand trusts, where its data lives or what it runs; each is one of (under both names: the
# rename, src/core/env_names.odin, sets and reads the old PI_DESK_ twins until 0.2.0):
#   the bare prefixes: src/core/env_names.odin builds the PI_DESK_ twins and the scrubs drop the
#     names it lists (login_env.odin, app_tab.odin, term.odin), and the embedded guide names
#     `DECKHAND_*` (GUIDE.md, "Release builds")
#   what Deckhand gives its tabs and the CLIs read back as their transport, never read by the app
#     to change itself: SOCKET, TOKEN, CONTROL_TOKEN (pi and control; `deckhand --ctl` reads
#     SOCKET and TOKEN, as Settings › Copy a control token gives them), CLAUDE_TOKEN, CLAUDE_TAB,
#     CLAUDE_READONLY, CLAUDE_ACCOUNT (read by the tab's own launch shell), CLI, SHOTS_DIR
#     (deckhand-cli reads SOCKET, CLAUDE_TOKEN and SHOTS_DIR: docs/CLAUDE.md)
#   set for an app tab (APP) and a job run (JOB, RUN, RUN_DIR, SCHEDULED_AT: docs/ATLAS.md)
#   the user's documented workarounds, read by the app: GUI_LAUNCH (=0 turns off the login-shell
#     environment import, docs/DEVELOPING.md) and CEF_SHARED_TEXTURE (=0 the slower CPU paint
#     path, docs/BROWSER.md); src/core/test_hooks.odin says why they stay
#   the holder's own re-exec marker, _DECKHAND_RESPONSIBLE (src/holder/spawn.odin: it sets it with
#     its pid before re-execing itself to disclaim TCC responsibility, and reads it back; it
#     steers nothing else); seen as DECKHAND_RESPONSIBLE now that DECKHAND_ names are scanned
#   DECKHAND_SUCCESSOR_SECRET: the key of the ready handshake's entry that carries a handover's
#     successor secret to a new core (src/holder/detach.odin); taken out, never an environment read
ALLOWED_SUFFIXES="SOCKET TOKEN CONTROL_TOKEN CLAUDE_TOKEN CLAUDE_TAB CLAUDE_READONLY CLAUDE_ACCOUNT CLI SHOTS_DIR APP JOB RUN RUN_DIR SCHEDULED_AT GUI_LAUNCH CEF_SHARED_TEXTURE"
ALLOWED="DECKHAND_
PI_DESK_
DECKHAND_RESPONSIBLE
DECKHAND_SUCCESSOR_SECRET"
for x in $ALLOWED_SUFFIXES; do ALLOWED="$ALLOWED
DECKHAND_$x
PI_DESK_$x"; done
# a hook name may never be allowed (a slip here would hide one)
for s in $NAMES; do
  if printf '%s\n' "$ALLOWED" | grep -qxF -- "$s"; then
    echo "check-release-build: $s is both a hook (src/core/test_hooks.odin) and allowed here" >&2
    exit 1
  fi
done

# An optimised build keeps some strings it compares against as 16-byte pieces at 16-byte aligned
# offsets (__literal16), run on into the next piece. Only these pieces, of allowed names, pass:
#   DECKHAND_SUCCESS  DECKHAND_SUCCESSOR_SECRET
#   PI_DESK_CEF_SHAR  PI_DESK_CEF_SHARED_TEXTURE
#   DECKHAND_CEF_SHA  DECKHAND_CEF_SHARED_TEXTURE
# A new one fails the release: check it is a piece of an allowed name, never a hook's, then add it.
PIECES="DECKHAND_SUCCESS PI_DESK_CEF_SHAR DECKHAND_CEF_SHA"
piece16() { # OFFSET MATCH: a run of listed pieces, ending in non-name bytes or an allowed name
  o=$1 p=$2
  while [ $((o % 16)) = 0 ]; do
    c=$(printf '%s' "$p" | cut -c1-16)
    case " $PIECES " in *" $c "*) ;; *) return 1 ;; esac
    p=${p#"$c"} o=$((o + 16))
    case $p in DECKHAND_*|PI_DESK_*) ;; *) return 0 ;; esac
    printf '%s\n' "$ALLOWED" | grep -qxF -- "$p" && return 0
  done
  return 1
}

# An x86-64 build (the Linux tarball) can load an 8-byte string it compares against as the
# immediate of `movabs r64, imm64` (REX.W 48/49, then B8-BF), followed by the next instruction's
# bytes, which may look like a name's tail (PI_DESK_ then `48 39` = "H9"). That match passes only
# when its first 8 bytes are themselves an allowed name (only PI_DESK_ is that short) and the rest
# is the start of an instruction, not a name: a REX prefix (H-O) and at most 2 bytes more.
imm64() { # OFFSET MATCH BINARY
  [ "$1" -ge 2 ] || return 1
  case "$(printf '%s' "$2" | cut -c9-)" in [H-O]|[H-O]?|[H-O]??) ;; *) return 1 ;; esac
  op=$(dd if="$3" bs=1 skip=$(($1 - 2)) count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$op" in 48b[89a-f]|49b[89a-f]) ;; *) return 1 ;; esac
  printf '%s\n' "$ALLOWED" | grep -qxF -- "$(printf '%s' "$2" | cut -c1-8)"
}

fail=0
for bin in "$@"; do
  [ -f "$bin" ] || { echo "check-release-build: no file $bin" >&2; fail=1; continue; }
  for s in $NAMES --print-token $TEST_PUB; do
    if LC_ALL=C grep -aqF -- "$s" "$bin"; then
      echo "check-release-build: $bin holds \"$s\": a test hook in a release build (build it with DECKHAND_RELEASE=1 ./build.sh)" >&2
      fail=1
    fi
  done
  # the catch-all: every DECKHAND_ and PI_DESK_ name in it (lower case too: no knob slips past as
  # DECKHAND_x)
  for m in $(LC_ALL=C grep -aobE '(DECKHAND|PI_DESK)_[A-Za-z0-9_]*' "$bin" | LC_ALL=C sort -u); do
    off=${m%%:*} s=${m#*:}
    printf '%s\n' "$ALLOWED" | grep -qxF -- "$s" && continue
    piece16 "$off" "$s" && continue
    imm64 "$off" "$s" "$bin" && continue
    printf '%s\n' "$NAMES" | grep -qxF -- "$s" && continue # reported above
    echo "check-release-build: $bin holds \"$s\": not a hook in src/core/test_hooks.odin, nor allowed in scripts/check-release-build.sh (a test or development knob? compile it out of release builds)" >&2
    fail=1
  done
done
[ $fail = 0 ] || exit 1
echo "check-release-build: no test hooks in $# binar$( [ $# = 1 ] && echo y || echo ies)"
