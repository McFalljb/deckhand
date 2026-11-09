#!/bin/sh
# The coding agents checklist (the setup sheet's first step and the Settings tab's Coding agents
# group; harness_manifest.odin, harness_install.odin, ui_harness.odin) in quiet test mode, against
# fake HOMEs with fake install layouts (stat and package.json only: nothing is ever run but the
# stand-in tests/scripts/fake-install.sh, checked by its argv). Never the user's ~/.pi or ~/.claude.
#   1. installed: pi (its installer's layout, 1.5.0, both recommended packages) and Claude Code
#      (native, 2.1.300): everything ticked, no action; the Settings group.
#   2. missing: neither installed; both collapsed with Install and the official command; Claude
#      Code's Install runs the stand-in (Esc is held while it runs), then pi's, then pi-subagents':
#      each found afterwards and never offered again; sudo inside each run hits Deckhand's refusing shim.
#   3. too old: pi 1.3.0 (npm) and Claude Code 2.1.100 (native): Update, pi's integration not loaded;
#      without DECKHAND_INSTALL_CMD test mode refuses the run (exit 127).
#   4. nix and mise: pi 1.3.0 in a nix store, Claude Code 2.1.100 under mise: shown only, Copy.
# Screenshots: build/shots/harness-setup/. Needs ./build.sh.
# Usage: tests/scripts/harness-setup.sh
set -eu
unset CLAUDE_CONFIG_DIR PI_CODING_AGENT_DIR # never the user's own folders
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/harness-setup"
rm -rf "$W" build/shots/harness-setup
mkdir -p "$W"
fail=0
chk() { if ! eval "$2"; then echo "FAILED: $1"; fail=1; fi; }
# pi in a package folder: bin/pi in its installer's folder links to its dist/cli.js
fake_pi() { # HOME PKGDIR VERSION
  mkdir -p "$2/dist" "$1/.pi/agent/bin"
  printf '{"name":"@earendil-works/pi-coding-agent","version":"%s"}\n' "$3" > "$2/package.json"
  printf '#!/bin/sh\necho "stand-in pi (tests): never run" >&2\nexit 1\n' > "$2/dist/cli.js"
  chmod 755 "$2/dist/cli.js"
  ln -sf "$2/dist/cli.js" "$1/.pi/agent/bin/pi"
}
fake_claude() { # HOME TARGET
  mkdir -p "$(dirname "$2")" "$1/.local/bin"
  printf '#!/bin/sh\necho "stand-in claude (tests): never run" >&2\nexit 1\n' > "$2"
  chmod 755 "$2"
  ln -sf "$2" "$1/.local/bin/claude"
}
run() { # NAME HOME [VAR=VALUE...]
  name=$1 home=$2
  shift 2
  mkdir -p "$W/data-$name"
  rt=$(mktemp -d "${TMPDIR:-/tmp}/dkhs.XXXXXX") # a short runtime dir: a socket path in it must fit sun_path
  env -u PI_KIT_NOTES_DIR -u DECKHAND_CMD -u DECKHAND_INSTALL_CMD HOME="$home" CFFIXED_USER_HOME="$home" SHELL=/bin/sh \
    DECKHAND_SCRIPT="tests/scripts/harness-setup-$name.txt" DECKHAND_DATA_DIR="$W/data-$name" DECKHAND_RUNTIME_DIR="$rt" DECKHAND_FIRST_RUN=1 \
    "$@" build/deckhand > "$W/run-$name.log" 2>&1 || true
  # a separate core (DECKHAND_SEPARATE_CORE=1) logs in its own file: read with the run's
  cat "$rt/core.log" >> "$W/run-$name.log" 2>/dev/null || true
  rm -rf "$rt"
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-$name.log" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-$name.log" || ! grep -q "done:" "$W/run-$name.log"; then echo "FAILED: run $name ($W/run-$name.log)"; fail=1; fi
}

# 1. installed
H1="$W/home-installed"
fake_pi "$H1" "$H1/.pi/agent/lib/node_modules/@earendil-works/pi-coding-agent" 1.5.0
printf '{"packages":[{"source":"npm:pi-subagents@0.84.0"},"npm:@juicesharp/rpiv-todo@2.15.0"]}\n' > "$H1/.pi/agent/settings.json"
fake_claude "$H1" "$H1/.local/share/claude/versions/2.1.300"
cp "$H1/.pi/agent/settings.json" "$W/settings-before.json"
run installed "$H1"
chk "pi's settings.json only read" 'cmp -s "$H1/.pi/agent/settings.json" "$W/settings-before.json"'
chk "nothing ran" '[ ! -e "$H1/install-argv.txt" ]'

# 2. missing: the stand-in installs
H2="$W/home-missing"
mkdir -p "$H2"
run missing "$H2" DECKHAND_INSTALL_CMD="$ROOT/tests/scripts/fake-install.sh" FAKE_INSTALL_SLOW=4
P="curl --proto '=https' --proto-redir '=https' -fsSL"
printf 'claude\t%s https://claude.ai/install.sh | bash\npi\t%s https://pi.dev/install.sh | sh\npi-subagents\t%s install npm:pi-subagents@0.84.0\n' "$P" "$P" "$H2/.pi/agent/bin/pi" > "$W/install-argv-want.txt"
chk "the stand-in got each item's id and its exact command, once each" 'cmp -s "$H2/install-argv.txt" "$W/install-argv-want.txt"'
chk "sudo refused inside each run (the stand-in tried it)" '[ "$(grep -c "run this yourself:" "$H2/sudo.txt")" = 3 ] && [ "$(grep -c "^sudo exit 1 askpass /usr/bin/false$" "$H2/sudo.txt")" = 3 ]'

# 3. too old, no stand-in: refused
H3="$W/home-old"
fake_pi "$H3" "$H3/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent" 1.3.0
mkdir -p "$H3/.npm-global/bin" # the npm next to that prefix (a stand-in, never run: test mode refuses)
printf '#!/bin/sh\nexit 1\n' > "$H3/.npm-global/bin/npm"
chmod 755 "$H3/.npm-global/bin/npm"
fake_claude "$H3" "$H3/.local/share/claude/versions/2.1.100"
run old "$H3"
# (a separate core says it in its own log, read with the run's)
chk "test mode refused the real update" 'grep -qs "test mode: refusing to run the real install command" "$W/run-old.log"'
chk "nothing ran" '[ ! -e "$H3/install-argv.txt" ]'

# 4. nix and mise: shown only
H4="$W/home-nix"
fake_pi "$H4" "$H4/fake/nix/store/0abc-pi-coding-agent-1.3.0/lib/node_modules/@earendil-works/pi-coding-agent" 1.3.0
fake_claude "$H4" "$H4/.local/share/mise/installs/claude-code/2.1.100/bin/claude"
run nix "$H4" DECKHAND_INSTALL_CMD="$ROOT/tests/scripts/fake-install.sh"
chk "nothing ran" '[ ! -e "$H4/install-argv.txt" ]'

if [ $fail = 1 ]; then echo "harness-setup scene failed (logs: $W/run-*.log)"; exit 1; fi
echo "harness-setup scene ok"
