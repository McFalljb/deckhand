#!/bin/sh
# Fail if any Mach-O object linked into (or shipped with) pi-desk targets a newer
# macOS than MIN. Reads LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX with otool -l,
# per archive member and per architecture.
# Usage: scripts/check-minos.sh [-v] MIN PATH...
#   PATH: a static library, object, executable or dylib; or a directory (a
#   bundle or framework), searched for Mach-O files. -v lists every object.
# Exit 1 if any object is newer than MIN, or a PATH is missing or not Mach-O.
# Objects with no version load command are listed as "none" and do not fail.
set -eu
VERBOSE=0
[ "${1:-}" = -v ] && { VERBOSE=1; shift; }
[ $# -ge 2 ] || { echo "usage: $0 [-v] MIN PATH..." >&2; exit 2; }
MIN=$1; shift

machos() { # PATH: the Mach-O files at PATH (itself, or the ones under a directory)
  if [ -d "$1" ]; then
    find "$1" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.a' -o -name '*.o' \) -print |
      while IFS= read -r f; do
        case "$(file -b "$f")" in *Mach-O*|*"ar archive"*) printf '%s\n' "$f" ;; esac
      done
  else
    printf '%s\n' "$1"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
status=0
for p in "$@"; do
  if [ ! -e "$p" ]; then echo "check-minos: missing $p" >&2; status=1; continue; fi
  files=$(machos "$p")
  [ -n "$files" ] || { echo "check-minos: no Mach-O files in $p" >&2; status=1; continue; }
  printf '%s\n' "$files" | { rc=0; while IFS= read -r f; do
    # otool -l prints a header per file, archive member and architecture
    # ("lib.a(x.o):", "bin (architecture arm64):"), then the load commands
    # otool reads "a(b)" as member b of archive a: name such files by a symlink
    case "$f" in *'('*) ln -sf "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" "$TMP/obj"; g=$TMP/obj ;; *) g=$f ;; esac
    out=$(otool -l -arch all "$g" 2>&1) || { echo "check-minos: otool failed on $f" >&2; rc=1; continue; }
    [ "$g" = "$f" ] || out=$(printf '%s\n' "$out" | sed "s|^$TMP/obj|$f|")
    printf '%s\n' "$out" | awk -v min="$MIN" -v verbose=$VERBOSE -v path="$f" '
      function ver(s,  a, n) { n = split(s, a, "."); return a[1] * 1000000 + (n > 1 ? a[2] : 0) * 1000 + (n > 2 ? a[3] : 0) }
      function flush() {
        if (obj == "") return
        if (v == "") { if (verbose) printf "  none   %s\n", obj; }
        else if (ver(v) > ver(min)) { printf "  %-6s %s  <- newer than %s\n", v, obj, min; bad = 1 }
        else if (verbose) printf "  %-6s %s\n", v, obj
        obj = ""; v = ""
      }
      /^[^ \t].*:$/ && !/^Load command/ { flush(); obj = substr($0, 1, length($0) - 1); next }
      /^Archive : / { next }
      /cmd LC_BUILD_VERSION/ { want = "minos" }
      /cmd LC_VERSION_MIN_MACOSX/ { want = "version" }
      /cmd LC_/ && !/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/ { want = "" }
      want == "minos" && $1 == "minos" { v = $2; want = "" }
      want == "version" && $1 == "version" { v = $2; want = "" }
      END { flush(); exit bad }
    ' || rc=1
  done; exit $rc; } || status=1
done
[ $status = 0 ] || echo "check-minos: objects above macOS $MIN (see above)" >&2
exit $status
