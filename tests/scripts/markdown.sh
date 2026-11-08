#!/bin/sh
# The Markdown tab end to end in test mode: a fake HOME with a project and two
# Markdown files, a fake pi, a temp data dir (never the user's). Opens a file
# as a document, toggles preview and source (button and ⇧⌘V), finds, follows
# a change on disk, an external link (logged, never opened), a relative .md
# link with an anchor, an anchor in the page, the mermaid placeholder, the
# user guide from the Help menu; idle CPU; shots at four widths, light and
# dark, into build/shots/markdown/. Usage: tests/scripts/markdown.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/markdown"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ/docs" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"mmmm-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_mmmm-1.jsonl"
cat > "$PROJ/README.md" <<'MD'
# Recipe box

Version one of the *recipe* box, with **strong** words, `code`, ~~old~~ text
and a needle in a haystack. Another needle here.

See the [example site](https://example.com/) or the [other page](docs/other.md#far-section).

## Tasks

- [x] import recipes
- [ ] scale portions
  1. nested ordered
  2. second

> A quote with a [link inside](#tasks).

| Name | Minutes | Notes |
|:-----|--------:|:-----:|
| Soup | 30 | *hot* |
| Salad | 5 | `cold` |

```go
func main() {
	fmt.Println("hello")
}
```

```mermaid
graph TD
  A --> B
```

![a photo of soup](soup.png)

---

The end.
MD
i=0; while [ $i -lt 40 ]; do printf '\nMore text %d, so the page scrolls.\n' $i >> "$PROJ/README.md"; i=$((i+1)); done
{
  printf '# Other page\n\n[jump down](#far-section)\n\n'
  i=0; while [ $i -lt 60 ]; do printf 'Filler paragraph %d with enough words to wrap at narrow widths.\n\n' $i; i=$((i+1)); done
  printf '## Far section\n\nFar text. [to the top](#other-page)\n'
  i=0; while [ $i -lt 40 ]; do printf '\nTail paragraph %d.\n' $i; i=$((i+1)); done
} > "$PROJ/docs/other.md"
run() { # script log
  s=$1; l=$2
  HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$s" DECKHAND_DATA_DIR="$W/data" \
    DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$l" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|no preview text|CPU" "$l" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|no preview text" "$l" || ! grep -q "done:" "$l"; then
    echo "markdown scene failed (log: $l)"; exit 1
  fi
}
echo "== open, toggle, find, reload, links, mermaid, guide"
run tests/scripts/markdown.txt "$W/run.log"
