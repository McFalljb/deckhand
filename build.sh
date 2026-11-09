#!/bin/sh
# Build Deckhand. macOS only for now.
#   ./build.sh          release build -> build/deckhand
#   ./build.sh debug    debug build
#   ./build.sh run      release build, then run
#   ./build.sh test     binding tests (tests/), command-layer tests (src/core/*_test.odin) and the
#                       window's (src/*_test.odin), the core boundary (scripts/check-core-boundary.sh),
#                       the holder's, wires' and trust rules' tests (src/holder, src/holderwire, src/corewire,
#                       src/trust),
#                       and the fake app for app tabs (build/fake-app, tests/fake-app/)
#   ./build.sh scenes [ARGS]   build, then the test-mode scenes (tests/scenes.py ARGS; e.g.
#                       --changed, --all, NAME...): docs/TESTING.md
# With CEF (default on macOS arm64): build/Deckhand.app (the framework and the five
# helper apps, signed with DECKHAND_SIGN_IDENTITY: scripts/sign.sh) and build/deckhand, a wrapper that execs the app's
# binary, so `build/deckhand ARGS` works as before (build/pi-desk is the same wrapper,
# for older scripts). DECKHAND_NO_CEF=1: the bare binary at build/deckhand (and a
# build/pi-desk link to it), no browser (docs/BROWSER.md §1.5).
# DECKHAND_RELEASE=1 (scripts/release.sh): the release or debug build without the test hooks
# (-define:DECKHAND_TEST_HOOKS=false, src/test_hooks.odin): no test mode, no DECKHAND_* overrides,
# no --print-token. Scenes need the hooks: build again without it before running them.
# Needs: odin, clang (Xcode command line tools). Does NOT need Zig: libghostty-vt
# comes prebuilt from vendor/libghostty-vt/ (see scripts/build-ghostty.sh).
set -eu
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
# code signing (DECKHAND_SIGN_IDENTITY, default the self-signed "Deckhand Self-Signed"; ad hoc with a
# warning when it is not in the keychain): scripts/sign.sh, docs/DEVELOPING.md "Code signing"
. scripts/sign.sh
MODE=${1:-release}
# the scenes: tests/scenes.py builds (./build.sh, ./build.sh fake-app) and runs them
if [ "$MODE" = scenes ]; then shift; exec python3 tests/scenes.py "$@"; fi
# minimum macOS: 14 (libghostty-vt and the CEF framework target 13; current Chromium needs 12).
# check_link_minos below fails the build on any linked object or bundled file newer than this.
MACOS_MIN=14.0
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  GHOSTTY_TARGET=aarch64-macos; SOKOL_ARCH=arm64 ;;
  Darwin-x86_64) GHOSTTY_TARGET=x86_64-macos;  SOKOL_ARCH=x64 ;;
  *) echo "Deckhand: only macOS is wired up so far"; exit 1 ;;
esac

GHOSTTY_LIB="vendor/libghostty-vt/$GHOSTTY_TARGET/lib/libghostty-vt.a"
if [ ! -f "$GHOSTTY_LIB" ]; then
  echo "missing $GHOSTTY_LIB: run scripts/build-ghostty.sh $GHOSTTY_TARGET (needs toolchain/ Zig)"
  exit 1
fi

if [ ! -f vendor/sokol-odin/sokol/app/app.odin ]; then
  git submodule update --init vendor/sokol-odin vendor/clay
fi

mkdir -p build

# sokol C libraries (only the modules we use), built once into the sokol-odin tree
# where its Odin bindings expect them.
SDIR=vendor/sokol-odin/sokol
for m in log:sokol_log gfx:sokol_gfx app:sokol_app glue:sokol_glue gl:sokol_gl time:sokol_time; do
  dir=${m%%:*}; src=${m##*:}
  out="$SDIR/$dir/${src}_macos_${SOKOL_ARCH}_metal_release.a"
  if [ ! -f "$out" ]; then
    echo "building $out"
    arch=$SOKOL_ARCH; [ "$arch" = x64 ] && arch=x86_64
    clang -c -O2 -x objective-c -arch "$arch" -DNDEBUG -DIMPL -DSOKOL_METAL \
      "$SDIR/c/$src.c" -o "build/$src.o"
    ar rcs "$out" "build/$src.o"
  fi
done

# clay (the layout library): built from the pinned vendor/clay/clay.h for MACOS_MIN into
# build/clay-odin/, next to a copy of the submodule's Odin bindings whose macOS foreign
# import points at it (the submodule's prebuilt macOS clay.a targets macOS 15). src/ imports
# build/clay-odin; the other OSes' paths point back into the submodule's prebuilt libraries.
CLAY=vendor/clay
CLAY_BIND=$CLAY/bindings/odin/clay-odin
if [ ! -f build/clay-odin/clay.a ] || [ $CLAY/clay.h -nt build/clay-odin/clay.a ] || [ build.sh -nt build/clay-odin/clay.a ]; then
  echo "building build/clay-odin/clay.a"
  mkdir -p build/clay-odin
  arch=$SOKOL_ARCH; [ "$arch" = x64 ] && arch=x86_64
  clang -c -x c -O3 -fPIC -arch "$arch" -mmacosx-version-min=$MACOS_MIN -DCLAY_IMPLEMENTATION $CLAY/clay.h -o build/clay-odin/clay.o
  rm -f build/clay-odin/clay.a
  ar rcs build/clay-odin/clay.a build/clay-odin/clay.o
fi
if [ ! -f build/clay-odin/clay.odin ] || [ $CLAY_BIND/clay.odin -nt build/clay-odin/clay.odin ] || [ build.sh -nt build/clay-odin/clay.odin ]; then
  sed -e 's|foreign import Clay "macos-arm64/clay.a"|foreign import Clay "clay.a"|' \
      -e 's|foreign import Clay "macos/clay.a"|foreign import Clay "clay.a"|' \
      -e 's|foreign import Clay "\([a-z]*/clay\.[a-z]*\)"|foreign import Clay "../../'"$CLAY_BIND"'/\1"|' \
      $CLAY_BIND/clay.odin > build/clay-odin/clay.odin.tmp
  # the bindings' import block changed upstream: update the rewrite above
  if [ "$(grep -c '^[[:space:]]*foreign import Clay "clay.a"$' build/clay-odin/clay.odin.tmp)" != 2 ] ||
     [ "$(grep -c '^[[:space:]]*foreign import Clay ' build/clay-odin/clay.odin.tmp)" != 5 ]; then
    echo "build.sh: $CLAY_BIND/clay.odin's foreign imports are not the expected five; update the clay step"
    exit 1
  fi
  mv build/clay-odin/clay.odin.tmp build/clay-odin/clay.odin
fi

# text backend (macOS: CoreText + CoreGraphics), rebuilt when its source changes
if [ ! -f build/dh_text.a ] || [ src/native/text_coretext.c -nt build/dh_text.a ]; then
  clang -c -O2 -Wall src/native/text_coretext.c -o build/dh_text.o
  ar rcs build/dh_text.a build/dh_text.o
fi

# window pieces sokol lacks (macOS: title bar, input methods, window drag, the menu bar)
if [ ! -f build/dh_platform.a ] || [ src/native/platform_macos.m -nt build/dh_platform.a ] || [ src/native/menubar_macos.m -nt build/dh_platform.a ]; then
  clang -c -O2 -Wall -fobjc-arc src/native/platform_macos.m -o build/dh_platform.o
  clang -c -O2 -Wall -fobjc-arc src/native/menubar_macos.m -o build/dh_menubar.o
  rm -f build/dh_platform.a
  ar rcs build/dh_platform.a build/dh_platform.o build/dh_menubar.o
fi

# editor and file-system model: FSEvents watcher, Trash, Finder (macOS)
if [ ! -f build/dh_editor.a ] || [ src/native/editor_macos.m -nt build/dh_editor.a ]; then
  clang -c -O2 -Wall -fobjc-arc src/native/editor_macos.m -o build/dh_editor.o
  ar rcs build/dh_editor.a build/dh_editor.o
fi

# app tabs' frame channel (Mach + IOSurface + Metal; docs/ENGINE-BRIDGE.md §2)
if [ ! -f build/dh_frames.a ] || [ src/native/frames_macos.m -nt build/dh_frames.a ]; then
  clang -c -O2 -Wall -fobjc-arc src/native/frames_macos.m -o build/dh_frames.o
  ar rcs build/dh_frames.a build/dh_frames.o
fi

# tree-sitter and the editor's grammars (vendor/tree-sitter, src/editor_syntax.odin):
# compiled in parallel into build/ts.a, again only when a vendored source changes
TS=vendor/tree-sitter
if [ ! -f build/ts.a ] || [ -n "$(find "$TS" -newer build/ts.a \( -name '*.c' -o -name '*.h' \) | head -1)" ]; then
  echo "building build/ts.a (tree-sitter + grammars)"
  rm -rf build/ts && mkdir -p build/ts
  ts_cc() { clang -c -O2 -w "$@" || touch build/ts/FAILED; }
  ts_cc -I"$TS/lib/include" -I"$TS/lib/src" "$TS/lib/src/lib.c" -o build/ts/lib.o &
  for g in "$TS"/grammars/*/; do
    n=$(basename "$g"); [ "$n" = common ] && continue
    ts_cc -I"$g/src" "$g/src/parser.c" -o "build/ts/$n-parser.o" &
    if [ -f "$g/src/scanner.c" ]; then ts_cc -I"$g/src" "$g/src/scanner.c" -o "build/ts/$n-scanner.o" & fi
  done
  wait
  if [ -f build/ts/FAILED ]; then echo "tree-sitter build failed"; exit 1; fi
  ar rcs build/ts.a build/ts/*.o
fi

# stb_truetype (the text backend on other OSes; src/text_stb.odin), into build/
if [ ! -f build/stb_truetype.a ]; then
  clang -c -O2 "$(odin root)/vendor/stb/src/stb_truetype.c" -o build/stb_truetype.o
  ar rcs build/stb_truetype.a build/stb_truetype.o
fi

# CEF (docs/BROWSER.md §1.5, §1.6): the pinned distribution (scripts/fetch-cef.sh),
# the shim (src/native/cef_macos.m) and the helper (src/native/cef_helper.c),
# against CEF's C API headers only: no C++ wrapper, no CMake.
CEF_API_VERSION=15600 # the C API version the shim and helper are written against
WITH_CEF=0
if [ "${DECKHAND_NO_CEF:-0}" != 1 ] && [ "$MODE" != test ] && [ "$MODE" != fake-app ]; then
  case "$(uname -m)" in
    arm64) WITH_CEF=1 ;;
    *) echo "Deckhand: CEF is wired up for arm64 only so far; building without it" ;;
  esac
fi
OUT=build/deckhand
DEFINES=""
if [ "${DECKHAND_RELEASE:-0}" = 1 ]; then
  [ "$MODE" = test ] || [ "$MODE" = fake-app ] && { echo "build.sh: DECKHAND_RELEASE=1 is for release builds, not $MODE"; exit 1; }
  DEFINES="-define:DECKHAND_TEST_HOOKS=false"
fi
if [ $WITH_CEF = 1 ]; then
  CEF=$(scripts/fetch-cef.sh)
  CEF_CFLAGS="-O2 -Wall -DCEF_API_VERSION=$CEF_API_VERSION"
  # a release shim has no DECKHAND_CEF_SPARE or DECKHAND_CEF_NETLOG (src/test_hooks.odin);
  # build/dh_cef.mode says which one build/dh_cef.a is
  CEF_MODE=dev CEF_SHIM_FLAGS=$CEF_CFLAGS
  if [ "${DECKHAND_RELEASE:-0}" = 1 ]; then CEF_MODE=release CEF_SHIM_FLAGS="$CEF_CFLAGS -DDH_RELEASE=1"; fi
  if [ ! -f build/dh_cef.a ] || [ "$(cat build/dh_cef.mode 2>/dev/null)" != $CEF_MODE ] || [ src/native/cef_macos.m -nt build/dh_cef.a ] || [ src/native/cef_polish.inc -nt build/dh_cef.a ] || [ src/native/cef_polish_pure.h -nt build/dh_cef.a ] || [ vendor/cef/VERSION -nt build/dh_cef.a ]; then
    clang -c $CEF_SHIM_FLAGS -I"$CEF" -fobjc-arc src/native/cef_macos.m -o build/dh_cef.o
    rm -f build/dh_cef.a
    ar rcs build/dh_cef.a build/dh_cef.o
    echo $CEF_MODE > build/dh_cef.mode
  fi
  if [ ! -f build/cef_helper ] || [ src/native/cef_helper.c -nt build/cef_helper ] || [ vendor/cef/VERSION -nt build/cef_helper ]; then
    clang $CEF_CFLAGS -I"$CEF" src/native/cef_helper.c -o build/cef_helper
  fi
  OUT=build/Deckhand.app/Contents/MacOS/Deckhand
  DEFINES="$DEFINES -define:DECKHAND_CEF=true"
  mkdir -p build/Deckhand.app/Contents/MacOS
  # build/deckhand (the wrapper, or a bare binary from a DECKHAND_NO_CEF build) stays until
  # bundle-app.sh rewrites it: a failed compile leaves the last working command in place
fi
# the fake app for app-tab scenes (tests/fake-app/): test builds only
build_fake_app() {
  if [ ! -f build/fake_render.a ] || [ tests/fake-app/render_macos.m -nt build/fake_render.a ]; then
    clang -c -O2 -Wall -fobjc-arc tests/fake-app/render_macos.m -o build/fake_render.o
    ar rcs build/fake_render.a build/fake_render.o
  fi
  odin build tests/fake-app -out:build/fake-app -minimum-os-version:$MACOS_MIN
}

# every native object linked into a build (the foreign imports, as Odin passes them to
# the linker) must target MACOS_MIN or older: scripts/check-minos.sh lists the ones that
# don't. Checked before linking, so a failure leaves the last good binary. Odin's own
# objects are built for MACOS_MIN (-minimum-os-version).
check_link_minos() { # odin build args (package and defines)
  # a package that doesn't compile is left to the build itself to report
  flags=$(odin build "$@" -out:build/.minos-probe -minimum-os-version:$MACOS_MIN -print-linker-flags 2>/dev/null) || return 0
  set --
  for f in $(printf '%s\n' "$flags" | grep -oE '"[^"]+\.(a|o|dylib)"' | tr -d '"'); do
    if [ -e "$f" ]; then set -- "$@" "$f"; fi # Odin's own objects are not written yet
  done
  if [ $# = 0 ]; then echo "check-minos: found no link inputs"; exit 1; fi
  scripts/check-minos.sh $MACOS_MIN "$@"
}
# Claude Code tabs (src/claude.odin, docs/CLAUDE.md): the deckhand CLI the plugin's bin/deckhand
# (and its alias bin/pi-desk) runs (tools/deckhand-cli; from src/ only src/jsonguard, which imports only core), and the plugin itself next to the binary
# (build/claude-code; bundle-app.sh copies both into the app)
build_claude() {
  odin build tools/deckhand-cli -out:build/deckhand-cli -o:speed -minimum-os-version:$MACOS_MIN
  rm -rf build/claude-code
  cp -R integrations/claude-code build/claude-code
  build_pi
}
# pi tabs (src/pi_integration.odin, docs/HARNESSES.md): Deckhand's pi integration, loaded per tab
# with `pi -e`, next to the binary (build/pi; bundle-app.sh copies it into the app). Its tests stay
# behind: only what pi loads ships.
build_pi() {
  rm -rf build/pi
  mkdir -p build/pi
  cp -R integrations/pi/extensions integrations/pi/lib integrations/pi/skills build/pi/
  cp integrations/pi/extensions.json integrations/pi/package.json integrations/pi/README.md build/pi/
}

# the session holder (src/holder, docs/plans/background-core.md §3): build/deckhand-core, signed
# (scripts/sign.sh) with its own identifier (bundle-app.sh copies it into the app). Links libSystem, and
# Security and CoreFoundation (an upgrade checks the new image's code: src/trust/code_darwin.odin).
# Built and signed beside it, then renamed in: a holder running build/deckhand-core (a scene's)
# keeps its file (a signed binary changed in place is killed at its next page-in).
build_core() {
  rm -f build/.deckhand-core.new
  odin build src/holder -out:build/.deckhand-core.new -o:speed -minimum-os-version:$MACOS_MIN
  sign_resolve
  sign_code -i dev.deckhand.core build/.deckhand-core.new
  mv -f build/.deckhand-core.new build/deckhand-core
}
# test builds only: the holder with its test hooks (src/holder/keeper.odin) for the re-exec tests,
# and the same binary signed with another identifier (the swapped binary they must refuse); ad hoc,
# so CI and every Mac test the same thing (the checks look at the identifier, not the signer)
build_core_hooks() {
  rm -f build/.deckhand-core-hooks.new build/.deckhand-core-swapped.new
  odin build src/holder -out:build/.deckhand-core-hooks.new -define:DECKHAND_TEST_HOOKS=true -minimum-os-version:$MACOS_MIN
  codesign -f -s - -i dev.deckhand.core build/.deckhand-core-hooks.new 2>/dev/null
  cp build/.deckhand-core-hooks.new build/.deckhand-core-swapped.new
  codesign -f -s - -i dev.deckhand.swapped build/.deckhand-core-swapped.new 2>/dev/null
  mv -f build/.deckhand-core-hooks.new build/deckhand-core-hooks
  mv -f build/.deckhand-core-swapped.new build/deckhand-core-swapped
}

case "$MODE" in
  test)     check_link_minos src; check_link_minos tests/fake-app ;;
  fake-app) check_link_minos tests/fake-app ;;
  *)        check_link_minos src $DEFINES ;;
esac

case "$MODE" in
  debug)   odin build src -out:$OUT -debug -define:SOKOL_DEBUG=false -minimum-os-version:$MACOS_MIN $DEFINES; build_claude; build_core ;;
  test)
    build_core
    clang -Ivendor/libghostty-vt/include tests/abi_sizes.c -o build/abi_sizes
    build/abi_sizes > build/abi_sizes.txt
    # the CEF shim's popup slot matcher (pure C, no CEF needed)
    clang -Wall tests/cef_popup_slots_test.c -o build/cef_popup_slots_test
    build/cef_popup_slots_test
    clang -Wall tests/cef_polish_pure_test.c -o build/cef_polish_pure_test
    build/cef_polish_pure_test
    # the agents' isolated-world script: the focus check and the sensitive-field rule (fake DOM)
    if command -v node >/dev/null; then node tests/browser_act_js_test.mjs; else echo "browser_act_js_test: skipped (no node)"; fi
    # the pi integration's unit tests (integrations/pi; Node 22.18+ strips the types; never runs pi)
    if command -v node >/dev/null; then (cd integrations/pi && node --test test/unit.test.ts test/deckhand.test.ts test/kit.test.ts test/optional.test.ts test/conflicts.test.ts test/mode.test.ts) >build/pi-integration-tests.log 2>&1 || { tail -40 build/pi-integration-tests.log; echo "integrations/pi tests failed (build/pi-integration-tests.log)"; exit 1; }; grep -E '^# (pass|fail)|^ℹ (pass|fail)' build/pi-integration-tests.log; else echo "integrations/pi tests: skipped (no node)"; fi
    # the page reader's walk (text, outline): frames, boxless containers, shadow slots (fake DOM)
    if command -v node >/dev/null; then node tests/browser_read_js_test.mjs; else echo "browser_read_js_test: skipped (no node)"; fi
    odin test tests -out:build/deckhand-tests
    # the holder wire codec (src/holderwire): golden vectors, the released schema, a fuzz pass
    odin test src/holderwire -out:build/holderwire-tests
    # the window/core framed wire (src/corewire): golden vectors, a fuzz pass, the in-memory transport
    odin test src/corewire -out:build/corewire-tests
    # who may talk to the holder, its launcher and the app (src/trust): pure table tests
    odin test src/trust -out:build/trust-tests
    # the session holder (src/holder): an in-process holder and a fake core over a socketpair,
    # /bin/sh children; its half of the launcher's ready handshake; and UPGRADE with real
    # processes (build/deckhand-core-hooks: 5 re-execs under load, refusals, the keeper adopting)
    build_core_hooks
    odin test src/holder -out:build/holder-tests
    # the core and the holder link no window code (docs/plans/background-core.md §10.2): the check,
    # then its test (each forbidden import planted in a temporary tree)
    scripts/check-core-boundary.sh
    sh tests/check-core-boundary-test.sh
    # the core (src/core/*_test.odin, package core: no sokol, Clay or CEF) and the window
    # (src/*_test.odin); tests share the global State: one thread per process,
    # several processes at once (tests/unit.py; UNIT_JOBS=1 for one at a time)
    python3 tests/unit.py
    # the scenes runner's --changed selection (no app, no git)
    python3 -B tests/scenes_test.py -q
    # every environment read names a known variable (test knobs go through hook_env)
    python3 -I scripts/check-env-reads.py
    # the Deckhand CLI for Claude tabs (its tests share a fake environment: one thread)
    odin test tools/deckhand-cli -out:build/deckhand-cli-tests -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
    build_claude
    build_fake_app ;;
  fake-app) build_fake_app ;;
  release|run) odin build src -out:$OUT -o:speed -minimum-os-version:$MACOS_MIN $DEFINES; build_claude; build_core ;;
  *) echo "usage: ./build.sh [release|debug|run|test|fake-app|scenes ARGS]"; exit 1 ;;
esac

if [ $WITH_CEF = 1 ]; then
  scripts/bundle-app.sh "$CEF" "$MACOS_MIN"
  # what the app ships: the CEF framework (prebuilt) and the helpers
  scripts/check-minos.sh $MACOS_MIN build/Deckhand.app
elif [ "$MODE" != test ] && [ "$MODE" != fake-app ]; then
  # a bare binary (DECKHAND_NO_CEF): build/pi-desk runs it too, for older scripts
  rm -f build/pi-desk && ln -s deckhand build/pi-desk
fi

[ "$MODE" = run ] && exec build/deckhand
exit 0
