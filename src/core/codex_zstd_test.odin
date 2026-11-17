package core

// Codex's compressed rollouts (rollout-<time>-<uuid>.jsonl.zst, codex_disk.odin): the lister takes
// them (the plain file when both are there) and the first-line reader decodes just their start.
// They are not Deckhand's files: a truncated, garbage, huge-window or over-long one is skipped,
// never decoded past its caps. Fixtures: tests/codex-zst/ (made by its make-fixtures.sh with the
// zstd CLI; the tests need no CLI). Temp dirs only, never ~/.codex.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
ZST_GOOD :: #load("../../tests/codex-zst/good.jsonl.zst")
@(private = "file")
ZST_WINDOW_8M :: #load("../../tests/codex-zst/window-8m.jsonl.zst")
@(private = "file")
ZST_TRUNCATED :: #load("../../tests/codex-zst/truncated.jsonl.zst")
@(private = "file")
ZST_GARBAGE :: #load("../../tests/codex-zst/garbage.jsonl.zst")
@(private = "file")
ZST_GARBAGE_MAGIC :: #load("../../tests/codex-zst/garbage-magic.jsonl.zst")
@(private = "file")
ZST_HUGE_WINDOW :: #load("../../tests/codex-zst/huge-window.jsonl.zst")
@(private = "file")
ZST_LONG_LINE :: #load("../../tests/codex-zst/long-line.jsonl.zst")
@(private = "file")
ZST_LINE_OVER_64K :: #load("../../tests/codex-zst/line-over-64k.jsonl.zst")
@(private = "file")
ZST_SKIPPABLE_PREFIX :: #load("../../tests/codex-zst/skippable-prefix.jsonl.zst")

// the fixtures' session id (tests/codex-zst/make-fixtures.sh)
@(private = "file")
ZST_ID :: "01a1d0d6-5353-7ff3-9308-ff91070ad540"

@(private = "file")
zst_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/deckhand-zst-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return d
}

// data written as a rollout of ZST_ID named with ext (".jsonl.zst" or ".jsonl") in dir
@(private = "file")
zst_rollout :: proc(dir: string, data: []u8, ext := ".jsonl.zst", id := ZST_ID) -> string {
	path := fmt.tprintf("%s/rollout-2026-11-12T10-00-00-%s%s", dir, id, ext)
	_ = os.write_entire_file(path, data)
	return path
}

// A good compressed rollout reads as its plain twin does: its first line (~40 KB, past the first
// compressed read) gives the cwd; a frame with the largest window allowed (2^23) decodes too.
@(test)
codex_zst_first_line_good :: proc(t: ^testing.T) {
	dir := zst_dir("good")
	for data, i in ([][]u8{ZST_GOOD, ZST_WINDOW_8M}) {
		cwd, _, skip, _ := codex_first_line(zst_rollout(dir, data))
		testing.expectf(t, !skip, "fixture %d skipped", i)
		testing.expect_value(t, cwd, "/tmp/deckhand-zst-project")
	}
	// its id is checked against the name as for a plain one
	_, _, skip, _ := codex_first_line(zst_rollout(dir, ZST_GOOD, id = "01a1d0d6-5353-7ff3-9308-ff91070ad541"))
	testing.expect(t, skip, "an id that is not its file's")
}

// Untrusted compressed rollouts are skipped, never decoded past the caps: cut inside the first
// line, garbage (with and without zstd's magic), a 2^27 window, a first line over the decode cap
// (300 KB) or over the line cap (100 KB), a skippable frame larger than the compressed-prefix cap
// before the good one (read no further than the cap), an empty file.
@(test)
codex_zst_first_line_untrusted :: proc(t: ^testing.T) {
	dir := zst_dir("bad")
	Case :: struct {
		name: string,
		data: []u8,
	}
	cases := []Case {
		{"truncated", ZST_TRUNCATED},
		{"garbage", ZST_GARBAGE},
		{"garbage-magic", ZST_GARBAGE_MAGIC},
		{"huge-window", ZST_HUGE_WINDOW},
		{"long-line", ZST_LONG_LINE},
		{"line-over-64k", ZST_LINE_OVER_64K},
		{"skippable-prefix", ZST_SKIPPABLE_PREFIX},
		{"empty", nil},
	}
	for c in cases {
		before := sync.atomic_load(&claude_disk_bytes_read)
		_, _, skip, _ := codex_first_line(zst_rollout(dir, c.data))
		read := sync.atomic_load(&claude_disk_bytes_read) - before
		testing.expectf(t, skip, "%s: not skipped", c.name)
		testing.expectf(t, read <= CODEX_ZST_IN_MAX, "%s: read %d bytes", c.name, read)
	}
	// the decoded output is capped too: a frame whose first line is 300 KB (139 bytes compressed)
	// decodes no more than the caps
	fd := posix.open(strings.clone_to_cstring(zst_rollout(dir, ZST_LONG_LINE), context.temp_allocator), {.CLOEXEC})
	defer posix.close(fd)
	line, decoded, ok, _ := codex_zst_first_line(fd)
	testing.expect(t, !ok && line == "", "no line")
	testing.expectf(t, decoded > 0 && decoded <= min(CODEX_ZST_OUT_MAX, CODEX_DISK_LINE_MAX), "decoded %d", decoded)
}

// The lister takes rollout-<time>-<uuid>.jsonl.zst as it takes .jsonl (the same id rule); with both
// for one id it keeps the plain one, whichever it meets first, and counts it once.
@(test)
codex_zst_listed :: proc(t: ^testing.T) {
	home := zst_dir("home")
	day := fmt.tprintf("%s/sessions/2026/11/12", home)
	os.make_directory_all(day)
	a :: "01a1d0d6-5353-7ff3-9308-ff91070ad550"
	b :: "01a1d0d6-5353-7ff3-9308-ff91070ad551"
	c :: "01a1d0d6-5353-7ff3-9308-ff91070ad552"
	zst_rollout(day, ZST_GOOD, ".jsonl", a)
	zst_rollout(day, ZST_GOOD, ".jsonl.zst", a) // compressed beside its plain twin
	zst_rollout(day, ZST_GOOD, ".jsonl.zst", b) // compressed only
	zst_rollout(day, ZST_GOOD, ".jsonl.gz", c) // not a rollout name
	zst_rollout(day, ZST_GOOD, ".zst", c)
	zst_rollout(day, ZST_GOOD, ".jsonl.zst.tmp", c)
	out := make([dynamic]Disk_File, context.temp_allocator)
	codex_disk_files_in(&out, home, fmt.tprintf("%s/sessions", home))
	got := map[string]string{}
	defer delete(got)
	for f in out {
		testing.expectf(t, f.id not_in got, "%s listed twice", f.id)
		got[f.id] = f.path
	}
	testing.expect_value(t, len(out), 2)
	testing.expectf(t, strings.has_suffix(got[a], a + ".jsonl"), "the plain one kept: %q", got[a])
	testing.expectf(t, strings.has_suffix(got[b], b + ".jsonl.zst"), "%q", got[b])
}
