package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "core"

// window.log: stamped lines, redacted as job notes are, rotated past its cap into window.log.1.
@(test)
window_log_redacts_and_rotates :: proc(t: ^testing.T) {
	dir := test_dir("wlog-rot")
	saved := window_log
	window_log = {}
	defer {
		core.log_file_close(&window_log)
		window_log = saved
	}
	path := fmt.tprintf("%s/window.log", dir)
	testing.expect(t, core.log_file_open(&window_log, path, cap = 600))
	wlog("the background core refused this window: api_key=sk-ant-abcdefghijklmnopqrstuvwxyz0123")
	b, _ := os.read_entire_file(path, context.temp_allocator)
	text := string(b)
	testing.expectf(t, strings.has_prefix(text, "20") && strings.contains(text, "Z Deckhand: the background core refused"), "stamped: %q", text)
	testing.expectf(t, !strings.contains(text, "abcdefghijklmnopqrstuvwxyz0123"), "redacted: %q", text)
	for i in 0 ..< 40 do wlog("reconnect attempt", i, "failed: Deckhand's background core sent no state")
	testing.expect(t, os.exists(fmt.tprintf("%s.1", path)), "rotated")
	testing.expect(t, !os.exists(fmt.tprintf("%s.2", path)), "two files at most")
	st, err := os.stat(path, context.temp_allocator)
	testing.expect(t, err == nil && st.size <= 600, "capped")
	when ODIN_OS == .Darwin {
		mode := st.mode & {.Read_Group, .Write_Group, .Read_Other, .Write_Other}
		testing.expectf(t, mode == {}, "private: %v", st.mode)
	}
}

// A fresh temp folder for these tests (TMPDIR is the test process's own: tmpdir_test.odin).
test_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/dh-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return d
}
