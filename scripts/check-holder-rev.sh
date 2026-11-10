#!/bin/sh
# Fails when the session holder's code changed without a holder_rev bump (docs/plans/
# background-core.md §7.3: a core upgrades a holder whose holder_rev is older than its own, so a
# change that keeps the number would never reach running holders).
#
#   scripts/check-holder-rev.sh [BASE]   compare HEAD with its merge base with BASE (default
#                                        origin/main; CI passes the PR's base, or the push's before)
#
# The holder's code: what links into deckhand-core, src/holder, src/holderwire and src/trust,
# tests (*_test.odin) aside. Also checks the app's copy of the number (src/core/holder_install.odin)
# is the same as the holder's (src/holder/holder.odin).
set -eu
cd "$(dirname "$0")/.."

rev_of() { sed -n 's/^HOLDER_REV :: \([0-9][0-9]*\).*/\1/p' | head -1; }

new=$(rev_of < src/holder/holder.odin)
app=$(rev_of < src/core/holder_install.odin)
if [ -z "$new" ] || [ -z "$app" ]; then
  echo "check-holder-rev: no HOLDER_REV :: N in src/holder/holder.odin or src/core/holder_install.odin"; exit 1
fi
if [ "$new" != "$app" ]; then
  echo "check-holder-rev: src/holder/holder.odin has HOLDER_REV $new, src/core/holder_install.odin has $app"; exit 1
fi

base=${1:-origin/main}
if ! git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || [ "$base" = 0000000000000000000000000000000000000000 ]; then
  base=HEAD~1 # a new branch's first push
fi
mb=$(git merge-base "$base" HEAD 2>/dev/null || true)
if [ -z "$mb" ]; then echo "check-holder-rev: no merge base with $base"; exit 1; fi

# A file counts only if a line other than a comment or a blank changed: a comment edit (a moved
# file's path, say) builds the same holder, and a bump would re-exec every running one for nothing.
# The holder runs on macOS and Linux (M6-L3): a change for either OS counts.
changed=
for f in $(git diff --name-only "$mb" HEAD -- src/holder src/holderwire src/trust | grep -v '_test\.odin$' || true); do
  if git diff -U0 "$mb" HEAD -- "$f" | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' |
    grep -qvE '^[-+][[:space:]]*(//.*)?$'; then
    changed="$changed$f
"
  fi
done
changed=$(printf '%s' "$changed")
if [ -z "$changed" ]; then echo "check-holder-rev: holder code unchanged since $mb (holder_rev $new)"; exit 0; fi

old=$(git show "$mb:src/holder/holder.odin" 2>/dev/null | rev_of || true)
if [ -z "$old" ]; then echo "check-holder-rev: no holder at $mb: holder_rev $new is the first"; exit 0; fi
if [ "$new" -le "$old" ]; then
  echo "check-holder-rev: the holder's code changed since $mb but HOLDER_REV is still $new (was $old). Bump it in"
  echo "src/holder/holder.odin and src/core/holder_install.odin. Changed:"
  echo "$changed" | sed 's/^/  /'
  exit 1
fi
echo "check-holder-rev: holder_rev $old -> $new ($(echo "$changed" | wc -l | tr -d ' ') holder files changed)"
