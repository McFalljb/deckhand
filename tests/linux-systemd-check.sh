#!/usr/bin/env bash
# The Linux core's systemd user unit (docs/plans/background-core.md §8.4, §10.4 M6-L2; CI's linux
# job). Part 1, anywhere: `install` under a fake HOME writes the binary into core/<key>/, points
# core/current at it, and writes ~/.config/systemd/user/deckhand-core.service (0644, KillMode=process,
# ExecStart = core/current's binary), which `systemd-analyze verify` accepts; `linger` answers.
#
# Part 2, --real (CI only: it uses the runner's real HOME, and sudo to turn linger on for the
# runner's own user, which Deckhand itself never does): the user manager comes up, `install`
# reloads it, `connect` starts the core through the unit, a restart and a stop are clean, and
# KillMode is process. The core's session holder runs in a scope of its own and outlives the stop.
#
# Usage: tests/linux-systemd-check.sh [--real] [build/deckhand-core-serve]
set -euo pipefail

REAL=0
if [ "${1:-}" = "--real" ]; then REAL=1; shift; fi
BIN=$(realpath "${1:-build/deckhand-core-serve}")
fail() { echo "linux-systemd-check: FAIL: $*" >&2; exit 1; }

# ---- part 1: a fake HOME ----
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
data="$home/.local/share/deckhand"
serve=$(HOME="$home" "$BIN" install --data "$data")
case "$serve" in "$data/core/dev-"*"/deckhand-core-serve") ;; *) fail "install printed $serve" ;; esac
[ -x "$serve" ] || fail "$serve is not executable"
cmp -s "$serve" "$BIN" || fail "$serve differs from $BIN"
# the session holder beside it goes with it (M6-L3)
if [ -f "$(dirname "$BIN")/deckhand-core" ]; then
	cmp -s "$(dirname "$serve")/deckhand-core" "$(dirname "$BIN")/deckhand-core" || fail "the session holder was not installed beside $serve"
fi
[ "$(readlink "$data/core/current")" = "$(basename "$(dirname "$serve")")" ] || fail "core/current does not point at the install"
unit="$home/.config/systemd/user/deckhand-core.service"
[ -f "$unit" ] || fail "no unit at $unit"
mode=$(stat -c %a "$unit")
[ "$mode" = 644 ] || fail "the unit's mode is $mode"
[ "$(stat -c %u "$unit")" = "$(id -u)" ] || fail "the unit is not ours"
grep -qx 'KillMode=process' "$unit" || fail "no KillMode=process"
grep -qx "ExecStart=\"$data/core/current/deckhand-core-serve\" serve --run \"$home/.local/state/deckhand/run\" --data \"$data\"" "$unit" || fail "ExecStart: $(grep ExecStart "$unit")"
# again: the same build, nothing new (the unit rewritten in place)
[ "$(HOME="$home" "$BIN" install --data "$data")" = "$serve" ] || fail "a second install moved"
[ "$(ls "$data/core" | grep -c '^dev-')" = 1 ] || fail "a second install made a second copy"
if command -v systemd-analyze >/dev/null; then
	# system mode: the runner has no user manager unless --real turns linger on
	systemd-analyze verify "$unit" || fail "systemd-analyze verify"
	echo "linux-systemd-check: systemd-analyze verify ok"
else
	echo "linux-systemd-check: no systemd-analyze: verify skipped"
fi
l=$("$BIN" linger) || true
case "$l" in on|off|unknown) echo "linux-systemd-check: linger $l" ;; *) fail "linger printed $l" ;; esac
echo "linux-systemd-check: part 1 ok"
[ "$REAL" = 1 ] || exit 0

# ---- part 2: the runner's own user manager ----
[ "${CI:-}" = true ] || fail "--real uses the real HOME and sudo: CI only"
sudo loginctl enable-linger "$(id -un)"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 0.2; done
[ -S "$XDG_RUNTIME_DIR/bus" ] || fail "no user bus at $XDG_RUNTIME_DIR/bus"
[ "$("$BIN" linger)" = on ] || fail "linger does not read on"
"$BIN" install --data "$HOME/.local/share/deckhand" 2>&1 | tee /dev/stderr | grep -q 'no systemd user manager' && fail "install did not reach the user manager"
systemctl --user cat deckhand-core.service >/dev/null || fail "the user manager does not see the unit"
[ "$(systemctl --user show -p KillMode --value deckhand-core.service)" = process ] || fail "KillMode"
# connect, from core/current as another machine's ssh runs it: no core answers, so it starts the
# unit (only core/current's binary does); the hub hello is refused (the door is closed by default)
# and stdin is empty: either way it ends
"$HOME/.local/share/deckhand/core/current/deckhand-core-serve" connect </dev/null >/dev/null 2>"$home/connect.err" || true
cat "$home/connect.err" >&2
systemctl --user is-active --quiet deckhand-core.service || fail "connect did not start the unit"
pid=$(systemctl --user show -p MainPID --value deckhand-core.service)
[ "$(readlink "/proc/$pid/exe")" = "$(realpath "$HOME/.local/share/deckhand/core/current/deckhand-core-serve")" ] || fail "the unit runs $(readlink "/proc/$pid/exe")"
# M6-L3: keep_sessions is on by default, so the core started its session holder, from
# core/current's dir and in a transient scope of its own, never in the core's unit
run="$HOME/.local/state/deckhand/run"
hpid=
for _ in $(seq 50); do hpid=$(pgrep -f "deckhand-core hold --run $run" | head -1 || true); [ -n "$hpid" ] && break; sleep 0.2; done
[ -n "$hpid" ] || fail "the core started no session holder: $(journalctl --user -u deckhand-core --no-pager | tail -20)"
[ "$(readlink "/proc/$hpid/exe")" = "$(dirname "$(realpath "$HOME/.local/share/deckhand/core/current/deckhand-core-serve")")/deckhand-core" ] || fail "the holder runs $(readlink "/proc/$hpid/exe")"
grep -qE 'deckhand-holder-[0-9a-f]{8}\.scope' "/proc/$hpid/cgroup" || fail "the holder is not in a scope of its own: $(cat "/proc/$hpid/cgroup")"
systemctl --user restart deckhand-core.service
systemctl --user is-active --quiet deckhand-core.service || fail "not active after a restart"
systemctl --user stop deckhand-core.service
[ "$(systemctl --user show -p Result --value deckhand-core.service)" = success ] || fail "the stop was not clean: $(journalctl --user -u deckhand-core --no-pager | tail -20)"
kill -0 "$hpid" 2>/dev/null || fail "stopping the core's unit stopped the session holder"
scope=$(grep -oE 'deckhand-holder-[0-9a-f]{8}\.scope' "/proc/$hpid/cgroup")
systemctl --user stop "$scope" # clean up: the holder and its sessions
echo "linux-systemd-check: part 2 ok (the unit starts on demand, restarts and stops cleanly; the holder in $scope outlives it)"
