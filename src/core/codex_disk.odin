package core

// Codex conversations started outside Deckhand, as rows (docs/CODEX.md §2b): what the found-row
// scan (claude_disk_scan, claude_disk.odin) reads of Codex's sessions folders. Read only, never
// written.
//
//   - Where: each Codex account's <home>/sessions/YYYY/MM/DD folders, newest first; at most
//     CODEX_DISK_DAYS_MAX day folders and CODEX_DISK_FILES_MAX files a home; regular files named
//     rollout-<time>-<uuid>.jsonl only, the id from the name (codex_disk_files).
//   - What: the first line only (session_meta: its id, cwd and source), at most
//     CODEX_DISK_LINE_MAX, through the Claude scan's cache, budget and worker (codex_first_line).
//   - The scan picks a harness's lister and first-line reader by an exhaustive switch on Harness
//     (disk_files, disk_first_line): a new harness's found rows add a case to each.

import "core:encoding/json"
import jg "../jsonguard"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

CODEX_DISK_DAYS_MAX :: 60 // day folders looked at, newest first
CODEX_DISK_FILES_MAX :: 400 // rollouts looked at, newest first
CODEX_DISK_LINE_MAX :: 64 * 1024 // a rollout's first line (session_meta, ~25 KB); longer: skipped
CODEX_CWD_MAX :: 1024 // a rollout's cwd; longer (or with a NUL): skipped, never walked

// A harness's conversation file found on disk: its id (from its name), path, dates and the home
// (account folder) it is in. Temp.
Disk_File :: struct {
	id, path, account: string,
	size:              i64,
	modified, created: time.Time,
}

// ---- per harness ----

// The newest conversation files of every account of harness h, as its lister finds them. Claude
// Code's are listed per project by claude_disk_scan itself (its folder names); pi's are its own
// (sessions.odin). Temp.
disk_files :: proc(h: Harness) -> []Disk_File {
	switch h {
	case .Codex:
		return codex_disk_files()
	case .Pi, .Claude:
		return nil
	}
	return nil
}

// What the scan reads of one of harness h's files (from disk_files): the cwd it ran in, or skip
// (not a conversation to list). Any thread.
disk_first_line :: proc(h: Harness, path: string) -> (cwd: string, skip: bool) {
	switch h {
	case .Codex:
		return codex_first_line(path)
	case .Pi, .Claude:
		return "", true
	}
	return "", true
}

// ---- Codex's conversations (~/.codex/sessions; codex.odin) ----

// A rollout's session_meta (its first line, at most CODEX_DISK_LINE_MAX, never more of the file):
// the cwd it ran in. skip: not a conversation to list (no session_meta, an id that is not the
// file's, a subagent's or another non-string source). Never written to; nothing in it reaches a
// shell or the screen (the cwd is only compared with the project's folder). Any thread.
codex_first_line :: proc(path: string) -> (cwd: string, skip: bool) {
	skip = true
	// never a FIFO or a link swapped in since the listing (open would block, or go elsewhere)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .NOFOLLOW, .CLOEXEC})
	if fd < 0 do return
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) do return
	buf := make([]u8, CODEX_DISK_LINE_MAX, context.temp_allocator)
	got := int(posix.pread(fd, raw_data(buf), len(buf), 0))
	sync.atomic_add(&claude_disk_bytes_read, i64(max(got, 0)))
	nl := strings.index_byte(string(buf[:max(got, 0)]), '\n')
	if nl < 2 do return
	line := string(buf[:nl])
	if line[0] != '{' || !json_depth_ok(line) do return
	v, perr := jg.parse(transmute([]u8)line, .JSON, false, context.temp_allocator)
	if perr != nil do return
	o, _ := v.(json.Object)
	if t, _ := o["type"].(json.String); t != "session_meta" do return
	pl, _ := o["payload"].(json.Object)
	id, _ := pl["id"].(json.String)
	c, _ := pl["cwd"].(json.String)
	if _, src_ok := pl["source"].(json.String); !src_ok do return // a subagent's ({"subagent": …})
	name := strings.trim_suffix(filepath.base(path), ".jsonl")
	if !codex_id_ok(string(id)) || !strings.has_suffix(name, string(id)) || !filepath.is_abs(string(c)) do return
	if len(c) > CODEX_CWD_MAX || strings.index_byte(string(c), 0) >= 0 do return
	return string(c), false
}

// A Codex home's sessions folder ("" = none; in tests and test mode never the developer's own
// ~/.codex: the default only when they set CODEX_HOME, ~/.codex of the real home never).
@(private = "file")
codex_sessions_dir :: proc(home: string) -> string {
	when TEST_HOOKS {
		if ODIN_TEST || test_mode() {
			if _, ok := env_lookup(child_base_env(), "CODEX_HOME"); !ok && home == codex_home() do return ""
			if real := account_home(); real != "" && home == strings.concatenate({strings.trim_right(real, "/"), "/.codex"}, context.temp_allocator) do return ""
		}
	}
	return home == "" ? "" : strings.concatenate({home, "/sessions"}, context.temp_allocator)
}

// The newest rollouts of each Codex account's home, by their folders' and names' dates
// (sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl): at most CODEX_DISK_DAYS_MAX day folders and
// CODEX_DISK_FILES_MAX files a home; regular files only. Temp.
@(private = "file")
codex_disk_files :: proc() -> []Disk_File {
	out := make([dynamic]Disk_File, context.temp_allocator)
	for a in claude_accounts(codex = true) do codex_disk_files_of(&out, a.dir)
	return out[:]
}

@(private = "file")
codex_disk_files_of :: proc(all: ^[dynamic]Disk_File, home: string) {
	out := make([dynamic]Disk_File, context.temp_allocator)
	defer append(all, ..out[:])
	root := codex_sessions_dir(home)
	if root == "" do return
	// the numbered folders under dir, newest (largest) first
	numbered :: proc(dir: string) -> []os.File_Info {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return nil
		list := make([dynamic]os.File_Info, context.temp_allocator)
		for e in entries {
			if e.type != .Directory || e.name == "" do continue
			digits := true
			for ch in transmute([]u8)e.name do if ch < '0' || ch > '9' do digits = false
			if digits do append(&list, e)
		}
		slice.sort_by(list[:], proc(a, b: os.File_Info) -> bool {return a.name > b.name})
		return list[:]
	}
	days := 0
	for y in numbered(root) {
		for m in numbered(y.fullpath) {
			for d in numbered(m.fullpath) {
				if days >= CODEX_DISK_DAYS_MAX || len(out) >= CODEX_DISK_FILES_MAX do return
				days += 1
				entries, err := os.read_all_directory_by_path(d.fullpath, context.temp_allocator)
				if err != nil do continue
				slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name > b.name})
				for e in entries {
					if len(out) >= CODEX_DISK_FILES_MAX do break
					if e.type != .Regular || !strings.has_prefix(e.name, "rollout-") || !strings.has_suffix(e.name, ".jsonl") do continue
					name := strings.trim_suffix(e.name, ".jsonl")
					if len(name) < 37 || name[len(name) - 37] != '-' do continue
					id := name[len(name) - 36:]
					if !codex_id_ok(id) do continue
					created := e.creation_time != {} ? e.creation_time : e.modification_time
					append(&out, Disk_File{id = id, path = e.fullpath, account = home, size = e.size, modified = e.modification_time, created = created})
				}
			}
		}
	}
}
