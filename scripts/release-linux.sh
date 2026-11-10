#!/bin/sh
# The Linux core's tarball for a release (docs/DEVELOPING.md "Releases"), run by scripts/release.sh
# on the release signer's Mac: CI built it (.github/workflows/release-linux.yml, on the tag's push);
# this finds that run, downloads its artifact, checks it against the sha256 the run printed, checks
# its listing and binaries, and signs it here with the update key (which never goes to CI).
#   --preflight   only find the run (before release.sh's long build): missing or failed refuses,
#                 still running is fine
#   otherwise     the run must have passed; writes OUT/NAME, OUT/NAME.sha256 and OUT/NAME.sig
#                 (NAME: deckhand-core-X.Y.Z-linux-x86_64.tar.gz)
# Usage: scripts/release-linux.sh [--preflight] --version X.Y.Z --commit SHA --repo OWNER/NAME
#                                 [--key KEYFILE --pub PUBKEY --out DIR]
# Every gh, tar and update-sign call is argv: nothing read from GitHub is run or put in a command.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
WORKFLOW=release-linux.yml
PREFLIGHT=0 VERSION="" COMMIT="" REPO="" KEY="" PUB="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight) PREFLIGHT=1; shift ;;
    --version) VERSION=${2:?}; shift 2 ;;
    --commit) COMMIT=${2:?}; shift 2 ;;
    --repo) REPO=${2:?}; shift 2 ;;
    --key) KEY=${2:?}; shift 2 ;;
    --pub) PUB=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    *) echo "release-linux: unknown argument $1" >&2; exit 2 ;;
  esac
done
fail() { echo "release-linux: $*" >&2; exit 1; }
printf %s "$VERSION" | grep -Eq '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$' || fail "--version X.Y.Z is needed"
printf %s "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || fail "--commit must be the tag's full commit id"
case "$REPO" in */*) ;; *) fail "--repo OWNER/NAME is needed" ;; esac
[ $PREFLIGHT = 1 ] || { [ -n "$KEY" ] && [ -n "$PUB" ] && [ -n "$OUT" ]; } || fail "--key, --pub and --out are needed"
TAG=v$VERSION
PREFIX=$(sed -n 's/^LINUX_TAR_PREFIX :: "\(.*\)"$/\1/p' src/updatesig/updatesig.odin)
SUFFIX=$(sed -n 's/^LINUX_TAR_SUFFIX :: "\(.*\)"$/\1/p' src/updatesig/updatesig.odin)
case "$PREFIX$SUFFIX" in *-linux-x86_64.tar.gz) ;; *) fail "no LINUX_TAR_PREFIX/SUFFIX in src/updatesig/updatesig.odin" ;; esac
NAME=$PREFIX$VERSION$SUFFIX
case "$NAME" in *[!A-Za-z0-9._-]*) fail "LINUX_TAR_PREFIX/SUFFIX in src/updatesig/updatesig.odin: letters, digits, ., _ and - only" ;; esac
TOP=${NAME%.tar.gz}
WAIT="the \"Linux release tarball\" workflow (.github/workflows/$WORKFLOW) for $TAG"
command -v gh >/dev/null || fail "gh (GitHub CLI) is needed to fetch $NAME from $WAIT"

# --- the run: this workflow, pushed for exactly this tag at exactly this commit ---------------
# newest first; each row: id, event, headBranch (the tag), headSha, status, conclusion
ROWS=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --event push --limit 50 \
  --json databaseId,event,headBranch,headSha,status,conclusion \
  --jq '.[] | [.databaseId, .event, .headBranch, .headSha, .status, .conclusion] | @tsv') ||
  fail "gh run list failed for $WAIT"
RUN="" STATUS="" CONCLUSION=""
TABS=$(printf '\t')
while IFS="$TABS" read -r id ev br sha st co; do
  [ "$ev" = push ] && [ "$br" = "$TAG" ] && [ "$sha" = "$COMMIT" ] || continue
  RUN=$id STATUS=$st CONCLUSION=$co
  break
done <<EOF
$ROWS
EOF
[ -n "$RUN" ] || fail "no run of $WAIT at $COMMIT: push the tag (git push origin $TAG), wait for that workflow to pass, then run again"
printf %s "$RUN" | grep -Eq '^[0-9]+$' || fail "gh gave a run id that is not a number"
if [ "$STATUS" = completed ] && [ "$CONCLUSION" != success ]; then
  fail "run $RUN of $WAIT ended $CONCLUSION: fix it, then tag again"
fi
if [ $PREFLIGHT = 1 ]; then
  echo "release-linux: run $RUN of $WAIT is $STATUS${CONCLUSION:+ ($CONCLUSION)}"
  exit 0
fi
[ "$STATUS" = completed ] || fail "run $RUN of $WAIT is $STATUS: wait for it (gh run watch $RUN --repo $REPO), then run again"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/deckhand-release-linux.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT TERM

# --- the artifact, against the sha256 the run printed ------------------------------------------
mkdir "$TMP/dl"
gh run download "$RUN" --repo "$REPO" --name "$NAME" --dir "$TMP/dl" >/dev/null 2>&1 ||
  fail "run $RUN of $WAIT has no artifact $NAME (expired, or the run is not the release one): run that workflow again for $TAG"
[ "$(ls -A "$TMP/dl")" = "$NAME" ] && [ -f "$TMP/dl/$NAME" ] && [ ! -L "$TMP/dl/$NAME" ] ||
  fail "the artifact of run $RUN is not exactly $NAME"
gh run view "$RUN" --repo "$REPO" --log > "$TMP/log" 2>/dev/null || fail "cannot read run $RUN's log"
# "tarball-sha256 HEX NAME" (scripts/pack-linux.sh and the workflow's last step): one value
NAME_RE=$(printf %s "$NAME" | sed 's/[.]/[.]/g') # the name is letters, digits, - and . only
LOG_SUM=$(tr -d '\r' < "$TMP/log" | sed -n "s/.*tarball-sha256 \([0-9a-f]\{64\}\) $NAME_RE\$/\1/p" | LC_ALL=C sort -u)
[ -n "$LOG_SUM" ] || fail "run $RUN's log has no \"tarball-sha256 HEX $NAME\" line"
[ "$(printf '%s\n' "$LOG_SUM" | wc -l | tr -d ' ')" = 1 ] || fail "run $RUN's log gives more than one sha256 for $NAME"
SUM=$(shasum -a 256 "$TMP/dl/$NAME" | cut -d' ' -f1)
[ "$SUM" = "$LOG_SUM" ] || fail "the downloaded $NAME's sha256 ($SUM) is not the one run $RUN printed ($LOG_SUM)"

# --- what it holds: one folder, files and folders only, the binaries without test hooks ------
tar -tzf "$TMP/dl/$NAME" > "$TMP/names" || fail "$NAME is not a gzip tar"
[ -s "$TMP/names" ] || fail "$NAME is empty"
while IFS= read -r n; do
  case "$n" in "$TOP"|"$TOP"/*) ;; *) fail "$NAME has a member outside $TOP/: $n" ;; esac
  case "/$n/" in */../*) fail "$NAME has a member with ..: $n" ;; esac
done < "$TMP/names"
# the type is the first character of each -tv line: - (file) or d (folder); links, devices: refused
tar -tvzf "$TMP/dl/$NAME" > "$TMP/long"
BAD=$(cut -c1 "$TMP/long" | grep -v '^[-d]$' || true)
[ -z "$BAD" ] || fail "$NAME has a member that is not a file or a folder (a link?)"
for m in deckhand-core-serve deckhand-core deckhand pi/extensions.json claude-code/.claude-plugin/plugin.json; do
  grep -qxF "$TOP/$m" "$TMP/names" || fail "$NAME has no $TOP/$m"
done
mkdir "$TMP/x"
tar -xzf "$TMP/dl/$NAME" -C "$TMP/x"
scripts/check-release-build.sh "$TMP/x/$TOP/deckhand-core-serve" "$TMP/x/$TOP/deckhand-core" "$TMP/x/$TOP/deckhand" ||
  fail "$NAME's binaries have test hooks in them"

# --- signed here: v3, cdhash none (src/updatesig) --------------------------------------------
mkdir -p "$OUT"
rm -f "$OUT/$NAME" "$OUT/$NAME.sha256" "$OUT/$NAME.sig"
cp "$TMP/dl/$NAME" "$OUT/$NAME"
printf '%s  %s\n' "$LOG_SUM" "$NAME" > "$OUT/$NAME.sha256"
(cd "$OUT" && shasum -a 256 -c "$NAME.sha256") >/dev/null || fail "$OUT/$NAME changed after it was checked"
build/update-sign sign --v3 "$KEY" "$VERSION" "$OUT/$NAME" none "$OUT/$NAME.sig"
build/update-sign verify "$PUB" "$VERSION" "$OUT/$NAME" "$OUT/$NAME.sig"
echo "release-linux: $OUT/$NAME ($(du -h "$OUT/$NAME" | cut -f1)) from run $RUN, sha256 $SUM, signed"
