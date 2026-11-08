package main

// Terminal snapshots (snapshot.odin, design §5.5 and §7.2).

import "core:c"
import "core:testing"
import gh "ghostty"

// Every terminal tracks its unfinished escape from creation, so it can be
// snapshotted at any byte offset: one from term_init and one from term_start.
@(test)
term_tracks_continuation :: proc(t: ^testing.T) {
	app_context = context
	check :: proc(t: ^testing.T, gt: gh.Terminal, what: string) {
		limit: c.size_t
		gh.terminal_get(gt, .Continuation_Max_Bytes, &limit)
		testing.expectf(t, limit == TERM_CONTINUATION_MAX, "%s: continuation limit %d", what, limit)
		s := "abc\x1b[38;2;10;20"
		gh.terminal_vt_write(gt, raw_data(s), len(s))
		p: [^]u8
		n: c.size_t
		r := gh.snapshot_encode_alloc(gt, nil, &p, &n)
		testing.expectf(t, r == .Success, "%s: snapshot mid-escape: %v", what, r)
		if r == .Success do gh.free(nil, p, n)
	}
	term := new(Term)
	defer free(term)
	testing.expect(t, term_init(term, 40, 5))
	check(t, term.gt, "term_init")
	term_start(term, {"/bin/sh", "-c", "exit 0"}, "/tmp")
	check(t, term.gt, "term_start")
	term_free(term)
}
