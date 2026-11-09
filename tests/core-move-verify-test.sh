#!/bin/sh
# scripts/core-move-verify.py refuses what the move must not do (docs/plans/background-core.md
# §10.2): in a temporary repository with a tiny BASE and a correct move it says ok, and each
# planted change makes it fail. No odin; a few seconds; run by ./build.sh test.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/moveverify.XXXXXX")
OUT=$(mktemp "${TMPDIR:-/tmp}/moveverify-out.XXXXXX")
trap 'rm -rf "$T" "$OUT"' EXIT
mkdir -p "$T/scripts" "$T/src"
cp "$ROOT/scripts/core-move-verify.py" "$ROOT/scripts/core-move.py" "$ROOT/scripts/odin_src.py" "$T/scripts/"
g() { git -C "$T" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
g init -q
VERIFY="python3 -B $T/scripts/core-move-verify.py"

# BASE: the window's State by value, a window file with one declaration that moves and one in a
# `when` block that stays
cat > "$T/src/state.odin" <<'ODIN'
package main

State :: struct {
	x: int,
}

state: State
ODIN
cat > "$T/src/win.odin" <<'ODIN'
package main

snapshot :: proc() -> int {
	old_s := state
	return old_s.x + state.x
}

state_ptr :: proc() -> ^State {
	return &state
}
ODIN
cat > "$T/src/split.odin" <<'ODIN'
package main

helper :: proc() -> int {
	return 1
}

when ODIN_OS == .Darwin {
	nested :: proc() -> int {
		return 2
	}
}

user :: proc() -> int {
	return helper() + nested()
}
ODIN
g add -A
g commit -qm base
BASE=$(g rev-parse HEAD)

# the move, as the script would make it
mkdir -p "$T/src/core"
g mv src/state.odin src/core/state.odin
sed -i.bak 's/^package main/package core/' "$T/src/core/state.odin" && rm "$T/src/core/state.odin.bak"
python3 -I -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("cm", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
open(sys.argv[2], "w").write(m.STATE_VIEW_TEXT)' "$T/scripts/core-move.py" "$T/src/state_view.odin"
cat > "$T/src/win.odin" <<'ODIN'
package main

import "core"

snapshot :: proc() -> int {
	old_s := state^
	return old_s.x + state.x
}

state_ptr :: proc() -> ^core.State {
	return state
}
ODIN
cat > "$T/src/core/split_core.odin" <<'ODIN'
package core

helper :: proc() -> int {
	return 1
}
ODIN
cat > "$T/src/split.odin" <<'ODIN'
package main

import "core"

when ODIN_OS == .Darwin {
	nested :: proc() -> int {
		return 2
	}
}

user :: proc() -> int {
	return core.helper() + nested()
}
ODIN
g add -A
g commit -qm move
$VERIFY --base "$BASE" >"$OUT" 2>&1 || { echo "core-move-verify-test: the correct move failed"; cat "$OUT"; exit 1; }

fails=0 planted=0
plant() { # what, a shell script that edits the move's tree ($1); the worktree is put back after
  planted=$((planted + 1))
  sh -c "$2" sh "$T"
  if $VERIFY --base "$BASE" --worktree >"$OUT" 2>&1; then
    echo "core-move-verify-test: FAILED: $1 passed"
    fails=$((fails + 1))
  fi
  g checkout -q -- . && g clean -qfd src
}
# a window line that copied State now copies the pointer (it still builds)
plant "a value copy that lost its ^" 'sed -i.bak "s/old_s := state^/old_s := state/" "$1/src/win.odin" && rm "$1/src/win.odin.bak"'
# the address of the pointer instead of the pointer
plant "a pointer to the pointer" 'sed -i.bak "s/return state$/return \&state/" "$1/src/win.odin" && rm "$1/src/win.odin.bak"'
# a declaration in a `when` block moved out of it (now on every platform)
plant "a declaration moved out of its when block" 'printf "\tnested :: proc() -> int {\n\t\treturn 2\n\t}\n" >> "$1/src/core/split_core.odin"
cat > "$1/src/split.odin" <<ODIN
package main

import "core"

when ODIN_OS == .Darwin {
}

user :: proc() -> int {
	return core.helper() + core.nested()
}
ODIN'
if [ $fails != 0 ]; then exit 1; fi
echo "core-move-verify-test: ok (the move verified, $planted planted changes refused)"
