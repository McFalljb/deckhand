#!/bin/sh
# The browser tab spike in quiet test mode (docs/BROWSER.md §6 step 1): a
# CEF page (tests/web/browser.html, a file URL: no network) renders into a
# tab; a click, typing and the wheel reach it. A fake HOME, a fake pi, a
# temp data dir (its browser/profile is the test's own Chromium profile).
# Needs a CEF build (./build.sh without PI_DESK_NO_CEF). Writes build/browser/
# (NAME.log per script; CEF's log in data/browser/cef.log) and build/shots/browser/.
# Step 2 (navigation): browser-nav, browser-popup, browser-tabkeys, browser-pages (pages from
# tests/web through pidesk-test://web/), and browser-restore: two runs on one
# data dir, the second restoring the first's tabs.
# Usage: tests/scripts/browser.sh [NAME...]   (default: every scene)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/browser"
rm -rf "$W" build/shots/browser
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"wwww-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_wwww-1.jsonl"
if [ ! -x build/pi-desk.app/Contents/MacOS/pi-desk ]; then echo "browser scene: no CEF build (run ./build.sh)"; exit 1; fi
fail=0
tree() { for c in $(pgrep -P "$1"); do tree "$c"; done; echo "$1"; }
# the main scene, then one script per review fix (focus, keys, slots, window.close, release),
# comment mode (browser-annotate: docs/BROWSER.md §3), agents reading pages (browser-agent: §4)
# and acting on them (browser-act: step 8)
# and the frame ring on both paint paths (browser-ring-cpu: browser-ring.txt with
# PI_DESK_CEF_SHARED_TEXTURE=0, OnPaint), with a slow GPU (browser-ring-lag) and
# under a fast drag (browser-drag); while each runs, every socket of its
# processes is listed: none may leave the machine
ALL="browser browser-polish browser-polish-allow browser-polish-zoom browser-polish-guard browser-focus browser-keys browser-slots browser-close browser-release browser-ring browser-ring-cpu browser-ring-lag browser-drag browser-annotate browser-agent browser-act browser-nav browser-popup browser-tabkeys browser-pages browser-restore"
NAMES=${*:-$ALL}
# two sessions of the fake pi in the project (browser-restore opens them by id)
STORE_DIR="$FAKE_HOME/.pi/agent/sessions/--proj--" # beside wwww-1 (its project's store)
for n in 1 2; do
  printf '{"type":"session","version":3,"id":"rrrr-%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Restore %s"}}\n' $n "$PROJ" $n \
    > "$STORE_DIR/2026-10-30T10-00-0${n}-000Z_rrrr-$n.jsonl"
done
for name in $NAMES; do
  if [ $name = browser-restore ]; then
    # run 1 saves two sessions' browser tabs, run 2 restores them (no DIR: no new chat)
    rm -rf "$W/data" && mkdir -p "$W/data"
    for n in 1 2; do
      HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/browser-restore-$n.txt PI_DESK_DATA_DIR="$W/data" \
        PI_DESK_CMD='exec sleep 600' build/pi-desk > "$W/browser-restore-$n.log" 2>&1 || true
      grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/browser-restore-$n.log" | sed "s/^/browser-restore-$n: /" || true
      if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/browser-restore-$n.log" || ! grep -q "done:" "$W/browser-restore-$n.log"; then
        echo "browser-restore-$n: FAILED (log: $W/browser-restore-$n.log)"; fail=1
      fi
    done
    continue
  fi
  rm -rf "$W/data" && mkdir -p "$W/data"
  # the files an agent uploads (browser-act): two small files beside the data
  if [ $name = browser-act ]; then mkdir -p "$FAKE_HOME/up" && printf 'alpha\n\n' > "$FAKE_HOME/up/a.txt" && printf 'b\n' > "$FAKE_HOME/up/b.txt"; fi
  script=$name; shared=1; lag=0
  if [ $name = browser-ring-cpu ]; then script=browser-ring; shared=0; fi
  # a slow GPU (each frame's completion work held back 150 ms): a release that
  # did not wait for the GPU would hand CEF a slot still sampled (inflight_writes)
  if [ $name = browser-ring-lag ]; then script=browser-ring; lag=150; fi
  HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/$script.txt PI_DESK_DATA_DIR="$W/data" \
    PI_DESK_CEF_SHARED_TEXTURE=$shared PI_DESK_TEST_GPU_LAG_MS=$lag PI_DESK_CMD='echo "ARGS: $*"; exec sleep 600' build/pi-desk "$PROJ" > "$W/$name.log" 2>&1 &
  pid=$!
  : > "$W/$name.sockets"
  while kill -0 $pid 2>/dev/null; do
    pids=$(tree $pid | tr '\n' ',' | sed 's/,$//')
    lsof -nP -a -i -p "$pids" 2>/dev/null | awk 'NR > 1' >> "$W/$name.sockets"
    sleep 0.5
  done
  wait $pid || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/$name.log" | sed "s/^/$name: /" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/$name.log" || ! grep -q "done:" "$W/$name.log"; then
    echo "$name: FAILED (log: $W/$name.log)"; fail=1
  fi
  # downloads are marked as downloaded (Gatekeeper checks them when opened)
  if [ $name = browser-polish ]; then
    for f in "$W/data/downloads/hidden_ report.txt" "$W/data/downloads/hidden_ report (1).txt"; do
      xattr -p com.apple.quarantine "$f" >/dev/null 2>&1 || { echo "$name: FAILED: $f has no com.apple.quarantine"; fail=1; }
    done
  fi
  # the ring scenes took the paint path they were run for
  case $name in
    browser-ring) want="paint path OnAcceleratedPaint" ;;
    browser-ring-cpu) want="paint path OnPaint" ;;
    *) want="" ;;
  esac
  if [ -n "$want" ] && ! grep -q "$want" "$W/$name.log"; then echo "$name: FAILED: no \"$want\" in its stats"; fail=1; fi
  # loopback only (127.0.0.1, ::1); anything else is a socket off the machine
  outside=$(grep -vE '127\.0\.0\.1|\[::1\]|localhost' "$W/$name.sockets" | sort -u)
  if [ -n "$outside" ]; then echo "$name: FAILED: non-loopback sockets:"; echo "$outside" | sed 's/^/  /'; fail=1; fi
  # the profile is the user's only (cookies are protected by file permissions alone)
  if [ -d "$W/data/browser" ]; then
    for d in "$W/data/browser" "$W/data/browser/profile"; do
      m=$(stat -f %Lp "$d")
      [ "$m" = 700 ] || { echo "$name: FAILED: $d is mode $m, want 700"; fail=1; }
    done
  fi
done
for n in browser browser-ring browser-ring-cpu browser-ring-lag browser-drag; do [ -f "$W/$n.log" ] || continue; grep -h "\[browser\] stats" "$W/$n.log" | tail -1 | sed "s/^/$n: /"; done || true
if [ $fail = 1 ]; then echo "browser scene failed"; exit 1; fi
echo "browser scene ok"
