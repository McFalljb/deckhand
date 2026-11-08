package main

// Timings for the report (run with -o:speed; see docs): opening a 50k-line
// C file and typing into it. Logs the numbers; asserts only loose bounds so a
// slow CI machine does not fail it.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
editor_perf_50k :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	// the parse budget is wall time: on a busy machine (a CI runner, other builds, the other test
	// processes) this file's full parse can pass the 500 ms budget and drop to plain text (by
	// design), so the budget is looser here; the bounds below are CPU time
	old_budget := syntax_budget
	defer syntax_budget = old_budget
	syntax_budget = 3 * time.Second
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	path := fmt.tprintf("%s/deckhand-perf-%d.c", strings.trim_right(tmp, "/"), time.now()._nsec)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 50_000 do fmt.sbprintf(&b, "int f%d(int x) {{ return x; }} // %d\n", i, i)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
	defer os.remove(path)

	// open: read, detect format, index lines, parse; then the first screen's colours
	t0 := thread_cpu_now()
	e := new(Editor)
	editor_load(e, path)
	scratch: [dynamic]u8
	defer delete(scratch)
	syntax_tokens(&e.sx, &e.buf, tb_line_start(&e.buf, 25_000), tb_line_start(&e.buf, 25_060), &scratch)
	open_ms := time.duration_milliseconds(thread_cpu_since(t0))

	// typing in the middle: per key, the edit + incremental reparse + the screen's colours
	ed_set_cursor(e, tb_line_start(&e.buf, 25_010) + 4, false)
	worst, total: f64
	N :: 300
	for i in 0 ..< N {
		k := thread_cpu_now()
		if i % 10 == 9 do ed_backspace(e)
		else do ed_insert(e, "a")
		syntax_tokens(&e.sx, &e.buf, tb_line_start(&e.buf, 25_000), tb_line_start(&e.buf, 25_060), &scratch)
		d := time.duration_milliseconds(thread_cpu_since(k))
		total += d
		worst = max(worst, d)
	}
	// the reparse once typing pauses (this file: ~100k top-level items, the slow case)
	time.sleep(SYNTAX_IDLE)
	k := time.tick_now()
	toks := syntax_tokens(&e.sx, &e.buf, tb_line_start(&e.buf, 25_000), tb_line_start(&e.buf, 25_060), &scratch)
	pause_ms := time.duration_milliseconds(time.tick_since(k))
	testing.expect(t, !e.sx.stale && len(toks) > 0)
	log.infof("PERF reparse after a typing pause: %.1f ms", pause_ms)
	log.infof("PERF (CPU time) open 50k-line C file: %.1f ms; typing: %.2f ms per key on average, %.2f ms worst (%d keys)", open_ms, total / N, worst, N)
	// what a user waits on: a tighter gate (3x) than the quadratic-change ones
	perf_expect(t, "editor_perf_50k: open a 50k-line C file", time.Duration(open_ms * f64(time.Millisecond)), 2 * time.Second, PERF_GATE_USER)
	perf_expect(t, "editor_perf_50k: typing, per key on average", time.Duration(total / N * f64(time.Millisecond)), 50 * time.Millisecond, PERF_GATE_USER)
	editor_free(e) // frees e too
}
