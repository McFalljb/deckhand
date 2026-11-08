#!/bin/sh
# A stand-in for fish as a login shell ($SHELL), for tests/scripts/fish-shell.sh: `fish -l -c CMD`
# rejects POSIX sh syntax that fish does not have, as fish does ("fish: Unsupported use of '='",
# "fish: Expected a command, but found …", exit 127), and runs what fish would also run (here with
# /bin/sh: the commands Deckhand sends that fish accepts mean the same in both). Without -c it is an
# interactive shell (/bin/sh). Never installs or needs the real fish.
cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) shift; cmd="$1"; shift; break ;;
    -l|-i|--login|--interactive) shift ;;
    *) break ;;
  esac
done
[ -n "$FAKE_FISH_LOG" ] && printf '%s\n' "fish -c: ${cmd:-(interactive)}" >> "$FAKE_FISH_LOG"
# interactive: say so on the tab's screen (fish-shell.txt waits for it), then a shell
if [ -z "$cmd" ]; then echo "FAKE FISH INTERACTIVE"; exec /bin/sh "$@"; fi
# what fish refuses: $(…) is fish 3.4+ but ${…}, `for … ; do`, `case … in`, `[ … ] && {`, VAR=x,
# "$@" and "$*" (fish has $argv) are not fish
for bad in '${' '; do ' 'case ' '"$@"' '$*' '; then ' 'export PATH' '=$' ; do
  case "$cmd" in
    *"$bad"*) printf "fish: Unsupported use of '%s'. In fish, please use fish syntax.\n" "$bad" >&2; exit 127 ;;
  esac
done
exec /bin/sh -c "$cmd" fish "$@"
