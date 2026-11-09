package core

// Session titles (titles.odin) on synthetic session files: pi's naming rule,
// incremental reads, the worker, the saved cache.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

@(private = "file")
tt_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/pd-titles-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return d
}

@(private = "file")
HEADER :: `{"type":"session","version":3,"id":"t","cwd":"/tmp"}` + "\n"

@(private = "file")
tt_user :: proc(text: string) -> string {
	return fmt.tprintf(`{{"type":"message","id":"u","message":{{"role":"user","content":[{{"type":"text","text":"%s"}}]}}}}`+"\n", text)
}

@(private = "file")
tt_name :: proc(name: string) -> string {
	return fmt.tprintf(`{{"type":"session_info","id":"n","name":"%s"}}`+"\n", name)
}

// One assistant tool-output line of about n bytes.
@(private = "file")
tt_noise :: proc(n: int) -> string {
	return fmt.tprintf(`{{"type":"message","id":"a","message":{{"role":"toolResult","content":[{{"type":"text","text":"%s"}}]}}}}`+"\n", strings.repeat("x", n, context.temp_allocator))
}

// noise lines up to about n bytes in all
@(private = "file")
tt_noise_total :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for strings.builder_len(b) < n do strings.write_string(&b, tt_noise(8000))
	return strings.to_string(b)
}

@(private = "file")
tt_write :: proc(dir, name: string, parts: ..string) -> string {
	path := fmt.tprintf("%s/%s", dir, name)
	_ = os.write_entire_file(path, transmute([]u8)strings.concatenate(parts, context.temp_allocator))
	return path
}

@(private = "file")
tt_wait :: proc() {
	deadline := time.tick_now()
	for titles_busy() && time.tick_since(deadline) < 10 * time.Second do time.sleep(time.Millisecond)
}

@(private = "file")
tt_append :: proc(path, text: string) {
	f, err := os.open(path, {.Write, .Append})
	if err != nil do return
	os.write_string(f, text)
	os.close(f)
}

@(private = "file")
tt_title :: proc(path: string) -> string {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil do return "<no file>"
	return title_of(path, fi.size, fi.modification_time, allocator = context.temp_allocator)
}

@(test)
title_rules :: proc(t: ^testing.T) {
	titles_clear()
	dir := tt_dir("rules")
	// a name early in a long file (beyond any head or tail window)
	p := tt_write(dir, "early.jsonl", HEADER, tt_user("first prompt"), tt_name("Early name"), tt_noise_total(600_000))
	testing.expect_value(t, tt_title(p), "Early name")
	// renamed: the latest wins; an empty name clears it (the first prompt shows)
	p = tt_write(dir, "renamed.jsonl", HEADER, tt_name("Old"), tt_user("the prompt"), tt_noise_total(100_000), tt_name("New"))
	testing.expect_value(t, tt_title(p), "New")
	p = tt_write(dir, "cleared.jsonl", HEADER, tt_name("Old"), tt_user("the prompt"), tt_name(""))
	testing.expect_value(t, tt_title(p), "the prompt")
	// the first user message after 200 KB of tool output
	p = tt_write(dir, "late.jsonl", HEADER, tt_noise_total(200_000), tt_user("late prompt"), tt_user("second"))
	testing.expect_value(t, tt_title(p), "late prompt")
	// text blocks are joined with spaces; control characters become spaces
	p = tt_write(dir, "blocks.jsonl", HEADER, `{"type":"message","message":{"role":"user","content":[{"type":"image","data":"AAAA"},{"type":"text","text":"one\nline"},{"type":"text","text":"two"}]}}` + "\n")
	testing.expect_value(t, tt_title(p), "one line two")
	// a user message with only an image does not count; the next one does
	p = tt_write(dir, "image.jsonl", HEADER, `{"type":"message","message":{"role":"user","content":[{"type":"image","data":"AAAA"}]}}` + "\n", tt_user("after the image"))
	testing.expect_value(t, tt_title(p), "after the image")
	// a session started by /goal: its objective, until a typed prompt exists
	goal := `{"type":"custom","customType":"pi-goal","data":{"goal":{"id":"g","objective":"Ship the parser\nwith tests","status":"active"},"statusBarEnabled":true}}` + "\n"
	cleared_goal := `{"type":"custom","customType":"pi-goal","data":{"goal":null,"statusBarEnabled":true}}` + "\n"
	p = tt_write(dir, "goal.jsonl", HEADER, cleared_goal, goal, tt_noise_total(20_000))
	testing.expect_value(t, tt_title(p), "Ship the parser with tests")
	p = tt_write(dir, "goal-user.jsonl", HEADER, goal, tt_user("typed later"))
	testing.expect_value(t, tt_title(p), "typed later")
	// nothing: ""
	p = tt_write(dir, "empty.jsonl", HEADER)
	testing.expect_value(t, tt_title(p), "")
	// long titles are cut at TITLE_MAX bytes, on a character boundary
	p = tt_write(dir, "long.jsonl", HEADER, tt_user(strings.repeat("é", 300, context.temp_allocator)))
	long := tt_title(p)
	testing.expect(t, len(long) <= TITLE_MAX && len(long) >= TITLE_MAX - 1 && utf8.valid_string(long), long)
	// a huge first prompt (longer than a read chunk)
	p = tt_write(dir, "huge.jsonl", HEADER, tt_user(strings.repeat("y", 1_500_000, context.temp_allocator)))
	testing.expect_value(t, tt_title(p), "") // over TITLE_INLINE: the worker reads it
	tt_wait()
	testing.expect_value(t, tt_title(p), strings.repeat("y", TITLE_MAX, context.temp_allocator))
}

@(test)
title_bad_bytes :: proc(t: ^testing.T) {
	titles_clear()
	dir := tt_dir("bytes")
	bad := "bad\xff\xfe utf"
	// a garbage line, then a prompt holding invalid UTF-8
	p := tt_write(dir, "bad.jsonl", HEADER, "\xff\xfe not json\n", tt_user(bad))
	got := tt_title(p)
	testing.expect(t, utf8.valid_string(got), "valid UTF-8")
	testing.expect(t, strings.has_prefix(got, "bad") && strings.has_suffix(got, "utf"), got)
}

// An appended name is picked up by reading only the new bytes; a cut-off
// last line is not used until it is complete.
@(test)
title_incremental :: proc(t: ^testing.T) {
	titles_clear()
	dir := tt_dir("incr")
	p := tt_write(dir, "s.jsonl", HEADER, tt_user("the prompt"), tt_noise_total(300_000))
	testing.expect_value(t, tt_title(p), "the prompt")
	before := sync.atomic_load(&title_bytes_read)
	testing.expect_value(t, tt_title(p), "the prompt") // unchanged: nothing read
	testing.expect_value(t, sync.atomic_load(&title_bytes_read), before)

	line := tt_name("Named later")
	tt_append(p, line[:len(line) - 10]) // pi is writing it
	testing.expect_value(t, tt_title(p), "the prompt")
	tt_append(p, line[len(line) - 10:])
	before = sync.atomic_load(&title_bytes_read)
	testing.expect_value(t, tt_title(p), "Named later")
	testing.expect_value(t, sync.atomic_load(&title_bytes_read) - before, i64(len(line))) // the cut line again, nothing else

	// rewritten (not appended): read from the start
	p2 := tt_write(dir, "s.jsonl", HEADER, tt_user("other prompt"), tt_noise_total(400_000))
	testing.expect_value(t, tt_title(p2), "other prompt")
	// shorter than what was read: from the start too
	p2 = tt_write(dir, "s.jsonl", HEADER, tt_user("short"))
	testing.expect_value(t, tt_title(p2), "short")
}

// Big first passes run on the worker; the lists take the titles when it is done.
@(test)
title_worker :: proc(t: ^testing.T) {
	context.allocator = reset_for_titles()
	titles_clear()
	home := tt_dir("worker-home")
	os.set_env("HOME", home)
	store := fmt.tprintf("%s/.pi/agent/sessions/--w--", home)
	os.make_directory_all(store)
	hdr := fmt.tprintf(`{{"type":"session","version":3,"id":"w-1","cwd":"%s"}}`+"\n", home)
	big := tt_write(store, "2026-10-30T10-00-00-000Z_w-1.jsonl", hdr, tt_user("prompt"), tt_noise_total(3 << 20), tt_name("Named at the end"))
	small := tt_write(store, "2026-10-30T10-05-00-000Z_w-2.jsonl", hdr)
	rescan_now()
	testing.expect_value(t, len(state.sessions), 2)
	if len(state.sessions) != 2 do return
	// newest first: the empty one, then the big one (being read)
	testing.expect_value(t, session_label(state.sessions[0]), "Untitled session · 2026-10-30 10:05")
	testing.expect_value(t, state.sessions[1].title, "")
	tt_wait()
	titles_tick()
	testing.expect_value(t, state.sessions[1].title, "Named at the end")
	// cached under the listed path (HOME's real path): nothing read again
	before := sync.atomic_load(&title_bytes_read)
	testing.expect_value(t, tt_title(state.sessions[1].path), "Named at the end")
	testing.expect_value(t, sync.atomic_load(&title_bytes_read), before)
	_, _ = big, small
}

// The cache is saved and loaded: a relaunch reads nothing that did not change.
@(test)
title_cache_saved :: proc(t: ^testing.T) {
	titles_clear()
	dir := tt_dir("saved")
	data := tt_dir("saved-data")
	titles_load(data)
	a := tt_write(dir, "a.jsonl", HEADER, tt_user("prompt a"), tt_name("Name a"))
	b := tt_write(dir, "b.jsonl", HEADER, tt_user("prompt b"))
	gone := tt_write(dir, "gone.jsonl", HEADER, tt_user("gone"))
	testing.expect_value(t, tt_title(a), "Name a")
	testing.expect_value(t, tt_title(b), "prompt b")
	testing.expect_value(t, tt_title(gone), "gone")
	titles_save()
	os.remove(gone)

	titles_clear()
	titles_load(data)
	before := sync.atomic_load(&title_bytes_read)
	testing.expect_value(t, tt_title(a), "Name a")
	testing.expect_value(t, tt_title(b), "prompt b")
	testing.expect_value(t, sync.atomic_load(&title_bytes_read), before)
	testing.expect_value(t, title_cached(gone), "")
	tt_append(b, tt_name("Name b"))
	testing.expect_value(t, tt_title(b), "Name b")
	testing.expect(t, sync.atomic_load(&title_bytes_read) - before < 100, "only the new line")
	titles_clear()
}

@(private = "file")
reset_for_titles :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, x in terms {
		term_free(x)
		free(x)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	home_root = ""
	persist = {}
	platform = {quit = proc() {}}
	return runtime.heap_allocator()
}

// Review 1: a file rewritten (not appended) at the same or a larger size,
// with a line end where the old read stopped, is read again from the start.
@(test)
title_rewrite_detected :: proc(t: ^testing.T) {
	titles_clear()
	dir := tt_dir("rewrite")
	p := tt_write(dir, "same.jsonl", HEADER, tt_user("aaaa"), tt_name("Old"))
	testing.expect_value(t, tt_title(p), "Old")
	tt_write(dir, "same.jsonl", HEADER, tt_user("bbbb"), tt_name("New"))
	later := time.time_add(time.now(), time.Hour)
	os.change_times(p, later, later)
	testing.expect_value(t, tt_title(p), "New")

	p = tt_write(dir, "larger.jsonl", HEADER, tt_user("aaaa"))
	testing.expect_value(t, tt_title(p), "aaaa")
	tt_write(dir, "larger.jsonl", HEADER, tt_user("bbbb"), tt_user("cccc"))
	testing.expect_value(t, tt_title(p), "bbbb")
}

// Review 2: a read that stopped short (an error, or a file shorter than
// listed) is cached as read up to where it stopped, not as the listed size.
@(test)
title_short_read_continues :: proc(t: ^testing.T) {
	titles_clear()
	dir := tt_dir("short")
	p := tt_write(dir, "s.jsonl", HEADER, tt_user("first"))
	fi, _ := os.stat(p, context.temp_allocator)
	name := tt_name("Named")
	listed := fi.size + i64(len(name))
	when_ := time.time_add(time.now(), -time.Hour)
	testing.expect_value(t, title_of(p, listed, when_, allocator = context.temp_allocator), "first") // reads stop at fi.size
	tt_append(p, name)
	os.change_times(p, when_, when_)
	testing.expect_value(t, title_of(p, listed, when_, allocator = context.temp_allocator), "Named")
}

// Review 3: refreshing the lists keeps titles that did not change (no copy).
@(test)
title_refresh_keeps_unchanged :: proc(t: ^testing.T) {
	context.allocator = reset_for_titles()
	titles_clear()
	home := tt_dir("refresh-home")
	os.set_env("HOME", home)
	store := fmt.tprintf("%s/.pi/agent/sessions/--r--", home)
	os.make_directory_all(store)
	tt_write(store, "2026-10-30T10-00-00-000Z_r-1.jsonl", fmt.tprintf(`{{"type":"session","version":3,"id":"r-1","cwd":"%s"}}`+"\n", home), tt_user("kept"))
	rescan_now()
	if !testing.expect_value(t, len(state.sessions), 1) do return
	before := raw_data(state.sessions[0].title)
	refresh_listed_titles()
	testing.expect_value(t, state.sessions[0].title, "kept")
	testing.expect(t, raw_data(state.sessions[0].title) == before, "not copied again")
}

// Review 4: one main-thread budget for a whole rescan (sessions and chats).
@(test)
title_budget_per_rescan :: proc(t: ^testing.T) {
	context.allocator = reset_for_titles()
	titles_clear()
	home := tt_dir("budget-home")
	os.set_env("HOME", home)
	home_root = tt_dir("budget-data")
	proj := fmt.tprintf("%s/code/p", home)
	chats := fmt.tprintf("%s/Chats", home)
	os.make_directory_all(proj)
	os.make_directory_all(chats)
	big := tt_noise_total(900_000) // under TITLE_INLINE each
	for cwd in ([]string{proj, chats}) {
		store := pi_store_dir(real_path(cwd))
		os.make_directory_all(store)
		for i in 0 ..< 7 do tt_write(store, fmt.tprintf("2026-10-30T10-%02d-00-000Z_x%d.jsonl", i, i), fmt.tprintf(`{{"type":"session","version":3,"id":"x%d","cwd":"%s"}}`+"\n", i, cwd), tt_user("prompt"), big)
	}
	rescan_now()
	testing.expect_value(t, len(state.sessions), 7)
	testing.expect_value(t, len(state.chats), 7)
	waiting := 0
	for s in state.sessions do if s.title == "" do waiting += 1
	for s in state.chats do if s.title == "" do waiting += 1
	testing.expect(t, waiting >= 14 - 9, "at most 8 MB read on the main thread for the whole rescan")
	tt_wait()
	titles_tick()
	for s in state.chats do testing.expect_value(t, s.title, "prompt")
	home_root = ""
}

// The data dir is private: created 0700, tightened if it was looser.
@(test)
data_dir_private :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // the log's path stays
	dir := fmt.tprintf("%s/new", tt_dir("private"))
	event_log_open(dir)
	event_log_close()
	fi, err := os.stat(dir, context.temp_allocator)
	testing.expect(t, err == nil && fi.mode & {.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other} == {}, "created 0700")
	loose := tt_dir("loose")
	os.chmod(loose, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	event_log_open(loose)
	event_log_close()
	fi, err = os.stat(loose, context.temp_allocator)
	testing.expect(t, err == nil && fi.mode & {.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other} == {}, "tightened to 0700")
}
