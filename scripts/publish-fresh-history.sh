#!/bin/sh
# Make the public repository's first commit: the tracked tree of COMMIT in a NEW repository
# with no history, its submodules re-added at the same pinned commits, one commit by the
# public author. Stops before any remote or push and prints the commands for those.
#
# Usage: scripts/publish-fresh-history.sh COMMIT DEST [MESSAGE]
#   COMMIT   the commit to publish (e.g. main)
#   DEST     a directory that does not exist yet (the new repository)
#   MESSAGE  the commit message (default: "Deckhand: first public version")
#
# git archive leaves submodules out (a gitlink is not a file), so each one is cloned from
# its .gitmodules URL with `git submodule add` and checked out at the commit COMMIT pins.
# At the end the new tree must be byte for byte the tree of COMMIT (same tree hash).
set -eu
AUTHOR_NAME="McFalljb"
AUTHOR_EMAIL="27719482+McFalljb@users.noreply.github.com"
REPO="McFalljb/deckhand"

[ $# -ge 2 ] || { sed -n '2,13p' "$0"; exit 2; }
SRC=$(cd "$(dirname "$0")/.." && pwd)
COMMIT=$(git -C "$SRC" rev-parse --verify "$1^{commit}")
DEST=$2
MESSAGE=${3:-"Deckhand: first public version"}
[ ! -e "$DEST" ] || { echo "publish: $DEST exists; give a new directory" >&2; exit 1; }
TREE=$(git -C "$SRC" rev-parse "$COMMIT^{tree}")
echo "publish: $COMMIT (tree $TREE) -> $DEST"

mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
git -C "$SRC" archive --format=tar "$COMMIT" | tar -x -C "$DEST"

# nothing that looks like a local secret or a build product
bad=$(cd "$DEST" && find . \( -name '.env' -o -name '.env.*' -o -name '*.p12' -o -name '*.pem' -o -name 'id_rsa*' -o -path './build' -o -path './dist' -o -path './toolchain' \) -print | head -5)
[ -z "$bad" ] || { echo "publish: refusing, the tree has: $bad" >&2; exit 1; }

cd "$DEST"
git init -q -b main
git config user.name "$AUTHOR_NAME"
git config user.email "$AUTHOR_EMAIL"

# submodules: path and pinned commit from COMMIT's tree, name and URL from its .gitmodules
GITMODULES="$DEST/.gitmodules"
TAB=$(printf '\t')
if [ -f "$GITMODULES" ]; then
  cp "$GITMODULES" "$DEST/.git/gitmodules.orig"
  rm "$GITMODULES"
  # -z: paths come unquoted, so spaces and quotes are safe. A path git would still quote
  # (a newline, a tab or another control character) is refused instead of misread.
  if git -C "$SRC" -c core.quotepath=false ls-tree -r --name-only "$COMMIT" | grep -q '^"'; then
    echo "publish: $COMMIT has a path with a control character; rename it first" >&2; exit 1
  fi
  git -C "$SRC" ls-tree -r -z "$COMMIT" | tr '\0' '\n' | while IFS= read -r entry; do
    meta=${entry%%"$TAB"*}   # "<mode> <type> <object>"
    path=${entry#*"$TAB"}
    set -- $meta
    [ "$2" = commit ] || continue
    sha=$3
    name=""
    for key in $(git config -f "$DEST/.git/gitmodules.orig" --name-only --get-regexp '^submodule\..*\.path$'); do
      if [ "$(git config -f "$DEST/.git/gitmodules.orig" --get "$key")" = "$path" ]; then
        name=${key#submodule.}; name=${name%.path}
      fi
    done
    [ -n "$name" ] || { echo "publish: $path has no .gitmodules entry" >&2; exit 1; }
    url=$(git config -f "$DEST/.git/gitmodules.orig" "submodule.$name.url")
    echo "publish: submodule $path at $sha ($url)"
    rmdir "$path" 2>/dev/null || true # git archive may leave the gitlink as an empty folder
    git submodule add -q --name "$name" "$url" "$path"
    if ! git -C "$path" checkout -q "$sha" 2>/dev/null; then
      git -C "$path" fetch -q origin "$sha"
      git -C "$path" checkout -q "$sha"
    fi
    git add "$path"
  done
  # the original .gitmodules (it carries settings such as ignore = untracked)
  cp "$DEST/.git/gitmodules.orig" "$GITMODULES"
fi

git add -A
NEW_TREE=$(git write-tree)
if [ "$NEW_TREE" != "$TREE" ]; then
  echo "publish: the new tree $NEW_TREE differs from $COMMIT's tree $TREE:" >&2
  git -C "$SRC" ls-tree -r "$TREE" > "$DEST/.git/tree.want"
  git ls-tree -r "$NEW_TREE" > "$DEST/.git/tree.got"
  diff "$DEST/.git/tree.want" "$DEST/.git/tree.got" | head -20 >&2 || true
  exit 1
fi
# the commit itself: commit-tree runs no hooks, so nothing can change the tree or message;
# dates in UTC so the commit carries no local time zone
NOW="$(date -u +%s) +0000"
NEW_COMMIT=$(printf '%s\n' "$MESSAGE" |
  GIT_AUTHOR_NAME=$AUTHOR_NAME GIT_AUTHOR_EMAIL=$AUTHOR_EMAIL GIT_AUTHOR_DATE=$NOW \
  GIT_COMMITTER_NAME=$AUTHOR_NAME GIT_COMMITTER_EMAIL=$AUTHOR_EMAIL GIT_COMMITTER_DATE=$NOW \
  git commit-tree "$NEW_TREE")
git update-ref refs/heads/main "$NEW_COMMIT"
[ "$(git rev-parse HEAD^{tree})" = "$TREE" ] || { echo "publish: HEAD's tree is not $TREE" >&2; exit 1; }
echo
git log --format='publish: %H %an <%ae> %ad%n         %s' --date=iso-strict -1
git submodule status
echo "publish: tree $NEW_TREE matches $COMMIT; no remote added, nothing pushed."
echo
echo "Next (the coordinator, after the user approves):"
echo "  gh repo create $REPO --public --description 'A native macOS desktop app for the pi coding agent' --disable-wiki"
echo "  git -C '$DEST' remote add origin https://github.com/$REPO.git"
echo "  git -C '$DEST' push -u origin main"
