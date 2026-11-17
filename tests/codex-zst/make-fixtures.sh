#!/bin/sh
# How the Codex compressed-rollout fixtures here were made (zstd CLI 1.5.7), for the tests in
# src/core/codex_zstd_test.odin. Run once when they were written; the tests read the committed
# files and never need the zstd CLI. Random text: running it again makes different (equivalent) files.
# Usage: tests/codex-zst/make-fixtures.sh [OUTDIR] [ZSTD]   (default: this folder, /opt/homebrew/bin/zstd)
set -eu
O=${1:-$(cd "$(dirname "$0")" && pwd)}; Z=${2:-/opt/homebrew/bin/zstd}
ID=01a1d0d6-5353-7ff3-9308-ff91070ad540
W=$(mktemp -d)
pad() { head -c "$1" /dev/urandom | base64 | tr -d "\n=+/" | head -c "$1"; }
# good: a ~40 KB first line (base_instructions, like Codex's), then ~120 KB more lines
{ printf '{"timestamp":"2026-11-12T10:00:00Z","type":"session_meta","payload":{"id":"%s","cwd":"/tmp/deckhand-zst-project","source":"cli","originator":"codex_cli_rs","base_instructions":{"text":"' "$ID"; pad 40000; printf '"}}}\n'
  i=0; while [ $i -lt 60 ]; do printf '{"type":"response_item","payload":{"text":"'; pad 2000; printf '"}}\n'; i=$((i+1)); done; } > "$W/good.jsonl"
$Z -q -3 -c "$W/good.jsonl" > "$O/good.jsonl.zst"
# truncated: the good file cut inside its first line
head -c 600 "$O/good.jsonl.zst" > "$O/truncated.jsonl.zst"
# garbage: random bytes, and zstd's magic followed by random bytes
head -c 4096 /dev/urandom > "$O/garbage.jsonl.zst"
{ printf '\050\265\057\375'; head -c 4096 /dev/urandom; } > "$O/garbage-magic.jsonl.zst"
# a huge window: 2^27 (from stdin, so the frame keeps it; the reader allows 2^23)
head -2 "$W/good.jsonl" | $Z -q -3 --zstd=wlog=27 -c > "$O/huge-window.jsonl.zst"
# the largest window allowed (2^23): decoded
head -2 "$W/good.jsonl" | $Z -q -3 --zstd=wlog=23 -c > "$O/window-8m.jsonl.zst"
# a first line over the decode cap (300 KB, no newline before it), and one over the line cap (100 KB)
{ printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/tmp/x","source":"cli","t":"' "$ID"; head -c 300000 /dev/zero | tr '\0' a; printf '"}}\n'; } | $Z -q -19 -c > "$O/long-line.jsonl.zst"
{ printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/tmp/x","source":"cli","t":"' "$ID"; head -c 100000 /dev/zero | tr '\0' a; printf '"}}\n'; } | $Z -q -19 -c > "$O/line-over-64k.jsonl.zst"
rm -rf "$W"
# a 270 KB skippable frame before the good one: past the compressed-prefix cap before any output
{ printf '\120\052\115\030\260\036\004\000'; head -c 270000 /dev/zero; cat "$O/good.jsonl.zst"; } > "$O/skippable-prefix.jsonl.zst"
