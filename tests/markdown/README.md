# Markdown spec examples

The Markdown parser's tests (`src/markdown_test.odin`: md4c, `vendor/md4c/`, and the tree
`src/markdown.odin` builds from it) render these examples to HTML and compare them with the
expected output.

| File | Source | Licence |
|---|---|---|
| `commonmark-examples.txt` | 174 of the 652 examples in the [CommonMark spec 0.31.2](https://github.com/commonmark/commonmark-spec/blob/0.31.2/spec.txt), spread over every section (every block and inline construct) | CC-BY-SA 4.0, Copyright (C) 2014-16 John MacFarlane |
| `gfm-examples.txt` | every example of the extensions we support (tables, task list items, strikethrough, autolinks) from the [GFM spec](https://github.com/github/cmark-gfm/blob/master/test/spec.txt) (0.29-gfm), and our own cases numbered 9001+ | CC-BY-SA 4.0 (GitHub, after John MacFarlane); ours: the repository's |

Both files keep the spec's format: an example is the line
````````````````````````````````` example N Section`, the Markdown, a line with a single `.`,
the HTML, and a closing line of 32 backticks; `→` stands for a tab.

GFM examples 203 and 9006 are skipped (`MD4C_GFM_DIFFERS` in `src/markdown_test.odin`): md4c's
table rules differ there (a delimiter row with fewer cells than the header still makes a table; a
table cannot start right after a paragraph line). `corpus/` pins those and md4c's other
differences from the parser before it (`corpus/md4c.md`), and the tree of a few documents
(`src/markdown_corpus_test.odin`; `DECKHAND_MD_GOLDEN=write` rewrites the `.golden` files).

Left out on purpose: CommonMark examples 606, 608, 611 and 612 (bare URLs and e-mail
addresses that GFM's autolink extension links, which we follow), and the GFM spec's copies of
the core examples (that file carries CommonMark 0.29, whose emphasis rules 0.31.2 changed).

## The whole spec

To check every example, not just the vendored ones (nothing here fails on a mismatch; it
prints a pass count per section and the failing numbers):

```sh
curl -sSfL -o /tmp/spec.txt https://raw.githubusercontent.com/commonmark/commonmark-spec/0.31.2/spec.txt
# keep the format above: each example's header line followed by its section name
python3 - /tmp/spec.txt /tmp/examples.txt <<'PY'
import re, sys
F = '`' * 32; sec = ''; n = 0; out = open(sys.argv[2], 'w')
lines = open(sys.argv[1]).read().split('\n'); i = 0
while i < len(lines):
    l = lines[i]
    if l.startswith(F + ' example'):
        n += 1; out.write(f'{F} example {n} {sec}\n'); i += 1
        while lines[i] != F: out.write(lines[i] + '\n'); i += 1
        out.write(F + '\n\n')
    elif re.match(r'^#{1,6} ', l): sec = re.sub(r'^#+ ', '', l).strip()
    i += 1
PY
DECKHAND_MD_SPEC=/tmp/examples.txt odin test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.markdown_spec_report
# (after a ./build.sh: src links build/md4c.a)
```

Last run (2026-11-26, md4c 0.6.0): CommonMark 0.31.2: 648/652 (the four above); GFM spec
extension sections: as with the parser before it, but for table example 203.
