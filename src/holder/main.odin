// deckhand-core: the session holder (docs/plans/background-core.md §3, §5.7, §6). It owns the
// PTY masters and every session process as its child, so pi, Claude Code and shells keep
// running while Deckhand is closed; the app (the "core" in M1) attaches over holder-<rand8>.sock
// and speaks the holder wire (src/holderwire). No ghostty, sokol or Clay: it never parses what
// the programs print.
//
//   deckhand-core hold --run DIR --data DIR [--ready PATH]   serve (holder.odin)
//   deckhand-core __detach                    launchd job entry: fork, setsid, exec hold (detach.odin)
package holder

import "core:fmt"
import "core:os"

USAGE :: "usage: deckhand-core hold --run DIR --data DIR [--ready PATH] | __detach"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	switch os.args[1] {
	case "hold":
		os.exit(hold_main(os.args[2:]))
	case "__detach":
		os.exit(detach_main(os.args[2:]))
	}
	fmt.eprintln(USAGE)
	os.exit(2)
}
