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
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	path := fmt.tprintf("%s/pi-desk-perf-%d.c", strings.trim_right(tmp, "/"), time.now()._nsec)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 50_000 do fmt.sbprintf(&b, "int f%d(int x) {{ return x; }} // %d\n", i, i)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
	defer os.remove(path)

	// open: read, detect format, index lines, parse; then the first screen's colours
	t0 := time.tick_now()
	e := new(Editor)
	editor_load(e, path)
	scratch: [dynamic]u8
	defer delete(scratch)
	syntax_tokens(&e.sx, &e.buf, tb_line_start(&e.buf, 25_000), tb_line_start(&e.buf, 25_060), &scratch)
	open_ms := time.duration_milliseconds(time.tick_since(t0))

	// typing in the middle: per key, the edit + incremental reparse + the screen's colours
	ed_set_cursor(e, tb_line_start(&e.buf, 25_010) + 4, false)
	worst, total: f64
	N :: 300
	for i in 0 ..< N {
		k := time.tick_now()
		if i % 10 == 9 do ed_backspace(e)
		else do ed_insert(e, "a")
		syntax_tokens(&e.sx, &e.buf, tb_line_start(&e.buf, 25_000), tb_line_start(&e.buf, 25_060), &scratch)
		d := time.duration_milliseconds(time.tick_since(k))
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
	log.infof("PERF open 50k-line C file: %.1f ms; typing: %.2f ms per key on average, %.2f ms worst (%d keys)", open_ms, total / N, worst, N)
	testing.expect(t, open_ms < 2000)
	testing.expect(t, total / N < 50)
	editor_free(e) // frees e too
}
