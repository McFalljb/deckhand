package main

// Piece table tests: edits against a plain string model, the line index,
// CRLF line ends, and a large file.

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
buffer_of :: proc(s: string) -> Text_Buffer {
	b: Text_Buffer
	tb_init(&b, transmute([]u8)strings.clone(s))
	return b
}

// Every line start/end and line_of agrees with a scan of the plain text.
@(private = "file")
check_lines :: proc(t: ^testing.T, b: ^Text_Buffer, model: string, loc := #caller_location) -> bool {
	if !testing.expect_value(t, tb_len(b), len(model), loc) do return false
	if !testing.expect(t, tb_equal(b, model), "text differs", loc = loc) do return false
	starts := make([dynamic]int, context.temp_allocator)
	append(&starts, 0)
	for c, i in transmute([]u8)model do if c == '\n' do append(&starts, i + 1)
	if !testing.expect_value(t, tb_line_count(b), len(starts), loc) do return false
	for s, line in starts {
		if !testing.expect_value(t, tb_line_start(b, line), s, loc) do return false
		e := line + 1 < len(starts) ? starts[line + 1] - 1 : len(model)
		if line + 1 < len(starts) && e > s && model[e - 1] == '\r' do e -= 1
		if !testing.expect_value(t, tb_line_end(b, line), e, loc) do return false
	}
	for off in 0 ..= len(model) {
		want := 0
		for s, line in starts do if s <= off do want = line
		if !testing.expect_value(t, tb_line_of(b, off), want, loc) do return false
	}
	return true
}

@(test)
buffer_insert_delete_lines :: proc(t: ^testing.T) {
	b := buffer_of("one\ntwo\nthree")
	defer tb_destroy(&b)
	check_lines(t, &b, "one\ntwo\nthree")
	tb_insert(&b, 3, " 1")
	check_lines(t, &b, "one 1\ntwo\nthree")
	tb_insert(&b, 5, "!") // typing extends the add piece
	testing.expect_value(t, len(b.pieces), 3)
	check_lines(t, &b, "one 1!\ntwo\nthree")
	tb_insert(&b, 0, "zero\n")
	check_lines(t, &b, "zero\none 1!\ntwo\nthree")
	tb_delete(&b, 4, 8) // "\none 1!\n" -> joins lines
	check_lines(t, &b, "zerotwo\nthree")
	tb_insert(&b, tb_len(&b), "\n")
	check_lines(t, &b, "zerotwo\nthree\n")
	tb_delete(&b, 0, tb_len(&b))
	check_lines(t, &b, "")
	tb_insert(&b, 0, "a\n\nb")
	check_lines(t, &b, "a\n\nb")
	scratch: [dynamic]u8
	defer delete(scratch)
	testing.expect_value(t, tb_line(&b, 2, &scratch), "b")
	testing.expect_value(t, tb_find(&b, "\nb", 0, &scratch), 2)
}

@(test)
buffer_crlf_line_ends :: proc(t: ^testing.T) {
	b := buffer_of("a\r\nbb\r\n\r\nc")
	defer tb_destroy(&b)
	check_lines(t, &b, "a\r\nbb\r\n\r\nc")
	testing.expect_value(t, tb_line_end(&b, 0), 1)
	testing.expect_value(t, tb_line_end(&b, 2), 7)
	scratch: [dynamic]u8
	defer delete(scratch)
	testing.expect_value(t, tb_line(&b, 1, &scratch), "bb")
	// a lone \r is text, not a line end
	tb_insert(&b, 1, "\rx")
	check_lines(t, &b, "a\rx\r\nbb\r\n\r\nc")
}

// Random edits against a string model.
@(test)
buffer_random_edits :: proc(t: ^testing.T) {
	rand.reset(42)
	model := strings.builder_make()
	defer strings.builder_destroy(&model)
	strings.write_string(&model, "first line\nsecond\r\nthird\n")
	b := buffer_of(strings.to_string(model))
	defer tb_destroy(&b)
	words := [?]string{"x", "\n", "abc", "\r\n", "é", "日本", "\n\n", "tail"}
	for step in 0 ..< 400 {
		cur := strings.to_string(model)
		if rand.int_max(3) > 0 || len(cur) == 0 {
			at := rand.int_max(len(cur) + 1)
			w := words[rand.int_max(len(words))]
			tb_insert(&b, at, w)
			s := strings.concatenate({cur[:at], w, cur[at:]}, context.temp_allocator)
			strings.builder_reset(&model)
			strings.write_string(&model, s)
		} else {
			at := rand.int_max(len(cur))
			n := rand.int_max(min(12, len(cur) - at) + 1)
			tb_delete(&b, at, n)
			s := strings.concatenate({cur[:at], cur[at + n:]}, context.temp_allocator)
			strings.builder_reset(&model)
			strings.write_string(&model, s)
		}
		if step % 40 == 0 && !check_lines(t, &b, strings.to_string(model)) do return
	}
	check_lines(t, &b, strings.to_string(model))
}

// 200k lines: building the index and lookups stay fast.
@(test)
buffer_large_file :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	for i in 0 ..< 200_000 do fmt.sbprintf(&sb, "line %d: some text that is long enough to look like code;\n", i)
	data := sb.buf[:]
	t0 := core.thread_cpu_now() // CPU time: a busy machine slows it less than wall time
	b: Text_Buffer
	tb_init(&b, data[:]) // takes ownership
	defer tb_destroy(&b)
	load := core.thread_cpu_since(t0)
	testing.expect_value(t, tb_line_count(&b), 200_001)
	t1 := core.thread_cpu_now()
	for i in 0 ..< 1000 do tb_insert(&b, tb_line_start(&b, (i * 197) % 200_000), "x")
	edits := core.thread_cpu_since(t1)
	scratch: [dynamic]u8
	defer delete(scratch)
	testing.expect_value(t, tb_line(&b, 100_000 - 0, &scratch)[:6], "line 1")
	core.perf_expect(t, "buffer_large_file: index 200k lines", load, 200 * time.Millisecond)
	core.perf_expect(t, "buffer_large_file: 1000 scattered inserts", edits, 500 * time.Millisecond)
	fmt.printf("buffer: %d MB, 200k lines indexed in %v, 1000 scattered inserts in %v\n", tb_len(&b) / (1 << 20), load, edits)
}
