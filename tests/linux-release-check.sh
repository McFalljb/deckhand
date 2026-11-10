#!/bin/sh
# The Linux release tarball as M6-E's install will use it (docs/DEVELOPING.md "Releases"), in CI
# after scripts/pack-linux.sh: its listing (one top folder, no absolute path, no "..", no link,
# owner 0:0), then extracted into a new folder, `deckhand-core-serve install --data` a temp data
# dir (not the default one: no systemd unit) puts everything in core/X.Y.Z-<sha12>/, and the
# installed core's `check` carries the version and the build id (the pair's sha12).
# Usage: tests/linux-release-check.sh TARBALL X.Y.Z
set -eu
[ $# = 2 ] || { echo "usage: tests/linux-release-check.sh TARBALL X.Y.Z" >&2; exit 2; }
TARBALL=$1 VERSION=$2
NAME=$(basename "$TARBALL")
TOP=${NAME%.tar.gz}
W=$(mktemp -d "${TMPDIR:-/tmp}/deckhand-release-check.XXXXXX")
trap 'rm -rf "$W"' EXIT
fail() { echo "linux-release-check: $*" >&2; exit 1; }

tar -tzf "$TARBALL" > "$W/names"
while IFS= read -r n; do
  case "$n" in "$TOP"/*|"$TOP") ;; *) fail "a member outside $TOP/: $n" ;; esac
  case "/$n/" in */../*) fail "a member with ..: $n" ;; esac
done < "$W/names"
# GNU tar -tv: the type is the mode's first character, owner/group numeric
tar -tvzf "$TARBALL" --numeric-owner > "$W/long"
awk '{ t = substr($1, 1, 1); if ((t != "-" && t != "d") || $2 != "0/0") { print; bad = 1 } } END { exit bad }' "$W/long" ||
  fail "a member that is not a file or folder owned by 0/0 (above)"
for m in deckhand-core-serve deckhand-core deckhand pi/extensions.json claude-code/.claude-plugin/plugin.json LICENSE; do
  grep -qxF "$TOP/$m" "$W/names" || fail "no $TOP/$m"
done
echo "ok: the listing ($(wc -l < "$W/names") members)"

mkdir "$W/x"
tar -xzf "$TARBALL" -C "$W/x"
X=$W/x/$TOP
"$X/deckhand-core-serve" install --data "$W/data" > "$W/installed" 2> "$W/install.err" || { cat "$W/install.err" >&2; fail "install failed"; }
KEY=$(readlink "$W/data/core/current")
case "$KEY" in "$VERSION"-????????????) ;; *) fail "core/current is '$KEY', not $VERSION-<sha12>" ;; esac
I=$W/data/core/$KEY
[ "$(cat "$W/installed")" = "$I/deckhand-core-serve" ] || fail "install printed $(cat "$W/installed")"
for m in deckhand-core-serve deckhand-core deckhand pi/extensions.json claude-code/.claude-plugin/plugin.json; do
  [ -f "$I/$m" ] || fail "the install has no $m"
done
[ -x "$I/deckhand" ] || fail "the installed CLI is not executable"
echo "ok: installed as core/$KEY with the holder, the CLI and the integrations"
for c in "$X/deckhand-core-serve" "$I/deckhand-core-serve"; do
  line=$("$c" check)
  v=$(printf %s "$line" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  b=$(printf %s "$line" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p')
  [ "$v" = "$VERSION" ] || fail "$c check: version '$v'"
  [ "$b" = "${KEY#"$VERSION"-}" ] || fail "$c check: build '$b', not the key's ${KEY#"$VERSION"-}"
done
echo "ok: check says version $VERSION and build ${KEY#"$VERSION"-}, from the tarball and from the install"
