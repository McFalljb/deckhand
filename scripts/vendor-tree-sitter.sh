#!/bin/sh
# Vendors tree-sitter (the C library) and the editor's grammars at pinned
# commits into vendor/tree-sitter/: only what the build needs (sources,
# highlight queries, licences). Run it to bump a pin, then commit the result.
# build.sh compiles the vendored sources (no network at build time).
#
#   scripts/vendor-tree-sitter.sh
#
# Each line: name repo commit tag [subdir]   (subdir: the grammar inside a
# multi-grammar repo). Pins are tag commits; VERSIONS records them.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/vendor/tree-sitter"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PINS='
lib        tree-sitter/tree-sitter                  10eb5ac119eec9cb4267a8e035066473983f5f3a v0.27.1
c          tree-sitter/tree-sitter-c                c9ff62c7ef293ccd6129318f638327dfd6ade7df v0.24.2
javascript tree-sitter/tree-sitter-javascript       f76aea6aa47322ea5c208c9c2e67f4a350d554f3 v0.25.0
typescript tree-sitter/tree-sitter-typescript       f975a621f4e7f532fe322e13c4f79495e0a7b2e7 v0.23.2 typescript
tsx        tree-sitter/tree-sitter-typescript       f975a621f4e7f532fe322e13c4f79495e0a7b2e7 v0.23.2 tsx
json       tree-sitter/tree-sitter-json             ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24 v0.24.8
markdown   tree-sitter-grammars/tree-sitter-markdown 41ff24a6c775492c543b09228aeb98d1cd2b3a0f v0.5.4 tree-sitter-markdown
python     tree-sitter/tree-sitter-python           d326e4cad262cf681656e130960e49dfc04c03ea v0.25.0
go         tree-sitter/tree-sitter-go               6048bfc6e5238eaf062c2221bd934489c39fbb61 v0.25.0
rust       tree-sitter/tree-sitter-rust             77a3747266f4d621d0757825e6b11edcbf991ca5 v0.24.2
bash       tree-sitter/tree-sitter-bash             a06c2e4415e9bc0346c6b86d401879ffb44058f7 v0.25.1
yaml       tree-sitter-grammars/tree-sitter-yaml    7708026449bed86239b1cd5bce6e3c34dbca6415 v0.7.2
toml       tree-sitter-grammars/tree-sitter-toml    64b56832c2cffe41758f28e05c756a3a98d16f41 v0.7.0
odin       tree-sitter-grammars/tree-sitter-odin    e8adc739b78409a99f8c31313f0bb54cc538cf73 v1.3.0
'

rm -rf "$OUT"
mkdir -p "$OUT/grammars"
printf '# name repo commit tag (written by scripts/vendor-tree-sitter.sh)\n' > "$OUT/VERSIONS"

echo "$PINS" | while read -r name repo commit tag sub; do
  [ -z "$name" ] && continue
  dir="$TMP/$(echo "$repo" | tr / _)-$commit"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    curl -fsSL "https://github.com/$repo/archive/$commit.tar.gz" | tar -xz -C "$dir" --strip-components=1
  fi
  printf '%s %s %s %s\n' "$name" "$repo" "$commit" "$tag" >> "$OUT/VERSIONS"
  if [ "$name" = lib ]; then
    mkdir -p "$OUT/lib"
    cp -R "$dir/lib/src" "$dir/lib/include" "$OUT/lib/"
    cp "$dir/LICENSE" "$OUT/lib/LICENSE"
    continue
  fi
  src="$dir${sub:+/$sub}"
  g="$OUT/grammars/$name"
  mkdir -p "$g/src/tree_sitter" "$g/queries"
  # parser.c, scanner.c and what the scanner includes (yaml: schema.*.c); build.sh
  # compiles only parser.c and scanner.c
  cp "$src"/src/*.c "$g/src/"
  if ls "$src"/src/*.h >/dev/null 2>&1; then cp "$src"/src/*.h "$g/src/"; fi
  cp "$src"/src/tree_sitter/*.h "$g/src/tree_sitter/"
  # typescript/tsx include the shared scanner from ../common
  if ls "$dir"/common/*.h >/dev/null 2>&1; then mkdir -p "$OUT/grammars/common"; cp "$dir"/common/*.h "$OUT/grammars/common/"; fi
  for q in highlights.scm highlights-jsx.scm; do
    [ -f "$src/queries/$q" ] && cp "$src/queries/$q" "$g/queries/"
    [ -z "$sub" ] || [ ! -f "$dir/queries/$q" ] || cp "$dir/queries/$q" "$g/queries/"
  done
  lic=$(ls "$dir"/LICENSE* 2>/dev/null | head -1)
  cp "$lic" "$g/LICENSE"
done
du -sh "$OUT"
