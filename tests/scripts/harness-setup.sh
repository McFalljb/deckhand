#!/bin/sh
# The coding agents checklist (the setup sheet's first step and the Settings page's Coding agents
# group; harness_manifest.odin, harness_install.odin, ui_harness.odin) in quiet test mode, against
# fake HOMEs with fake install layouts (stat and package.json only: nothing is ever run but the
# stand-in tests/scripts/fake-install.sh, checked by its argv). Never the user's ~/.pi or ~/.claude.
#   1. installed: pi (its installer's layout, 1.5.0, all five recommended packages) and Claude Code
#      (native, 2.1.300): everything ticked, no action; the Settings group.
#   2. missing: neither installed; both collapsed with Install and the official command; Claude
#      Code's Install runs the stand-in (Esc is held while it runs), then pi's, then pi-subagents':
#      each found afterwards and never offered again; sudo inside each run hits Deckhand's refusing shim.
#   3. too old: pi 1.3.0 (npm) and Claude Code 2.1.100 (native): Update, pi's integration not loaded;
#      without DECKHAND_INSTALL_CMD test mode refuses the run (exit 127).
#   4. nix and mise: pi 1.3.0 in a nix store, Claude Code 2.1.100 under mise: shown only, Copy.
#   5. agy refused: pi installed, no agy; Settings' Install agy… from a fixture release (file:,
#      DECKHAND_TEST_AGY_RELEASE) into a fake ~/.local/bin (DECKHAND_TEST_AGY_BIN_DIR): the real
#      codesign refuses the fixture; nothing is installed, no private folder is left.
#   6. agy: the same with DECKHAND_TEST_AGY_SIGNED=1 (the fixture is not Google's): installed, its
#      agy-seen.json written as the extension writes it; never run (a script that would say so).
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
printf '{"packages":[{"source":"npm:pi-subagents@0.84.0"},"npm:@juicesharp/rpiv-todo@2.15.0","npm:pi-ask-user@0.17.0","npm:pi-web-access@0.47.0","npm:@juicesharp/rpiv-btw@2.15.0"]}\n' > "$H1/.pi/agent/settings.json"
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

# 5 and 6. Install agy… from a fixture release: a tarball with the one member `antigravity`, and
# the manifest naming it with its real SHA-512 (the platform's names as agy_platform's)
case "$(uname -m)" in
  arm64) AP=darwin_arm64 AF=darwin-arm AT=cli_mac_arm64.tar.gz ;;
  *) AP=darwin_amd64 AF=darwin-x64 AT=cli_mac_x64.tar.gz ;;
esac
AR="$W/agy-release"
mkdir -p "$AR/src" "$AR/manifests" "$AR/antigravity-cli/1.5.18-123/$AF"
printf '#!/bin/sh\necho "fixture agy (tests): never run" >&2\nexit 1\n' > "$AR/src/antigravity"
chmod 755 "$AR/src/antigravity"
COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --no-xattrs -czf "$AR/antigravity-cli/1.5.18-123/$AF/$AT" -C "$AR/src" antigravity
SUM=$(/usr/bin/shasum -a 512 "$AR/antigravity-cli/1.5.18-123/$AF/$AT" | cut -d' ' -f1)
printf '{"version":"1.5.18","url":"file://%s/antigravity-cli/1.5.18-123/%s/%s","sha512":"%s"}\n' "$AR" "$AF" "$AT" "$SUM" > "$AR/manifests/$AP.json"
for name in agy-refused agy; do
  H="$W/home-$name"
  fake_pi "$H" "$H/.pi/agent/lib/node_modules/@earendil-works/pi-coding-agent" 1.5.0
  mkdir -p "$W/data-$name/antigravity"
  printf '{"agyPath":"%s","accounts":[]}\n' "$H/.local/bin/agy" > "$W/data-$name/antigravity/accounts.json"
done
H5="$W/home-agy-refused"
run agy-refused "$H5" DECKHAND_TEST_AGY_RELEASE="file://$AR/" DECKHAND_TEST_AGY_BIN_DIR="$H5/.local/bin"
chk "agy refused: nothing at ~/.local/bin/agy" '[ ! -e "$H5/.local/bin/agy" ]'
chk "agy refused: no private folder left" '[ -z "$(ls -A "$H5/.local/bin" 2>/dev/null)" ]'
chk "agy refused: no agy-seen.json" '[ ! -e "$W/data-agy-refused/antigravity/agy-seen.json" ]'
H6="$W/home-agy"
run agy "$H6" DECKHAND_TEST_AGY_RELEASE="file://$AR/" DECKHAND_TEST_AGY_BIN_DIR="$H6/.local/bin" DECKHAND_TEST_AGY_SIGNED=1
chk "agy: installed, the fixture's bytes, 0755" 'cmp -s "$H6/.local/bin/agy" "$AR/src/antigravity" && [ -x "$H6/.local/bin/agy" ] && [ "$(stat -f %Lp "$H6/.local/bin/agy")" = 755 ]'
chk "agy: nothing else in ~/.local/bin (no private folder left)" '[ "$(ls -A "$H6/.local/bin")" = agy ]'
chk "agy: agy-seen.json as the extension writes it" 'grep -qF "{\"path\":\"$H6/.local/bin/agy\",\"size\":$(stat -f %z "$H6/.local/bin/agy"),\"mtime\":$(stat -f %m "$H6/.local/bin/agy"),\"version\":\"1.5.18\"}" "$W/data-agy/antigravity/agy-seen.json" && [ "$(stat -f %Lp "$W/data-agy/antigravity/agy-seen.json")" = 600 ]'
chk "agy: accounts.json untouched" 'grep -qF "\"agyPath\":\"$H6/.local/bin/agy\"" "$W/data-agy/antigravity/accounts.json"'
chk "agy: never run" '! grep -qs "fixture agy (tests): never run" "$W/run-agy.log" "$W/run-agy-refused.log"'

if [ $fail = 1 ]; then echo "harness-setup scene failed (logs: $W/run-*.log)"; exit 1; fi
echo "harness-setup scene ok"
