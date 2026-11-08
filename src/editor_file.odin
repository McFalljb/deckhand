package main

// Editor files: loading (refusing binary and huge files), the format a file
// keeps (line endings, indentation), atomic saves that keep permissions,
// and following the file on disk. Agents edit files all the time, so the
// rules are strict: a clean buffer follows the disk silently (cursor and
// scroll stay, the reload is one undo step); a dirty buffer is never
// touched: the "Changed on disk" banner offers Reload, Keep mine and
// Compare. Our own saves are recognised by content hash, not by time.
//
// Change notices come from the platform watcher (FSEvents on macOS,
// editor_watch.odin) and, as a fallback, a cheap stat of every open file
// every EDITOR_POLL.

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

EDITOR_MAX_BYTES :: 20 * 1024 * 1024
EDITOR_POLL :: 2 * time.Second

Disk_Stamp :: struct {
	size:  i64,
	mtime: i64, // ns
	inode: u64,
	dev:   u64,
	mode:  u32, // permission bits
}

Path_Kind :: enum {
	Missing,
	File, // regular
	Dir,
	Other, // FIFO, device, socket
}

// stat(2) (symlinks followed) without opening anything: core:os's stat
// opens the path, which blocks on a FIFO.
path_stat :: proc(path: string) -> (kind: Path_Kind, st: Disk_Stamp) {
	sb: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &sb) != .OK do return .Missing, {}
	switch {
	case posix.S_ISREG(sb.st_mode): kind = .File
	case posix.S_ISDIR(sb.st_mode): kind = .Dir
	case: kind = .Other
	}
	return kind, stamp_of_stat(&sb)
}

path_kind :: proc(path: string) -> Path_Kind {k, _ := path_stat(path); return k}

@(private = "file")
stamp_of_stat :: proc(sb: ^posix.stat_t) -> Disk_Stamp {
	return {size = i64(sb.st_size), mtime = i64(sb.st_mtim.tv_sec) * 1e9 + i64(sb.st_mtim.tv_nsec), inode = u64(sb.st_ino), dev = u64(sb.st_dev), mode = u32(transmute(posix._mode_t)sb.st_mode) & 0o7777}
}

text_hash :: proc(data: []u8) -> u64 {return hash.fnv64a(data)}

buffer_hash :: proc(b: ^Text_Buffer) -> u64 {
	h: u64 = 0xcbf29ce484222325
	at := 0
	for at < tb_len(b) {
		c := tb_chunk(b, at)
		h = hash.fnv64a(c, h)
		at += len(c)
	}
	return h
}

// Binary: a NUL byte in the first 8 KB, or mostly bytes that are neither
// UTF-8 nor text controls.
looks_binary :: proc(data: []u8) -> bool {
	head := data[:min(len(data), 8192)]
	bad := 0
	i := 0
	for i < len(head) {
		c := head[i]
		if c == 0 do return true
		if c < 0x20 && c != '\n' && c != '\r' && c != '\t' && c != 0x1b && c != 0x0c && c != 0x08 do bad += 1
		if c < 0x80 {
			i += 1
			continue
		}
		r, n := utf8.decode_rune(head[i:])
		if r == utf8.RUNE_ERROR && n <= 1 {
			// a sequence cut by the 8 KB window is fine
			if len(head) - i < 4 && len(head) < len(data) do break
			bad += 1
			n = 1
		}
		i += n
	}
	return bad * 10 > len(head) // more than 10%
}

// Line endings and indentation, from the first lines of the text.
detect_format :: proc(e: ^Editor) {
	data := tb_chunk(&e.buf, 0) // the original file is one piece
	head := data[:min(len(data), 1 << 20)]
	crlf, lf := 0, 0
	for c, i in head do if c == '\n' {
		if i > 0 && head[i - 1] == '\r' do crlf += 1
		else do lf += 1
	}
	e.eol = crlf > lf ? "\r\n" : "\n"
	tabs, spaces := 0, 0
	steps: [9]int // indentation increases of 1..8 spaces
	prev := 0
	lines := 0
	hs := string(head)
	for line in strings.split_lines_iterator(&hs) {
		lines += 1
		if lines > 2000 do break
		if strings.trim_space(line) == "" do continue
		if line[0] == '\t' {
			tabs += 1
			continue
		}
		n := 0
		for n < len(line) && line[n] == ' ' do n += 1
		if n > 0 do spaces += 1
		if d := n - prev; d >= 2 && d <= 8 do steps[d] += 1
		prev = n
	}
	e.indent_w = 4
	switch {
	case tabs > spaces:
		e.indent_tabs = true
	case spaces > 0:
		e.indent_tabs = false
		best := 0
		for w in ([]int{2, 4, 8}) do if steps[w] > best {
			best = steps[w]
			e.indent_w = w
		}
	case:
		// nothing indented yet: the language's custom
		name := e.sx.lang != nil ? e.sx.lang.name : ""
		e.indent_tabs = name == "go" || name == "odin" || filepath.base(e.path) == "Makefile"
		if name == "yaml" || name == "json" || name == "markdown" || name == "tsx" || name == "typescript" || name == "javascript" do e.indent_w = 2
	}
	if e.indent_tabs do e.indent_w = EDITOR_TAB_WIDTH
}

disk_stamp :: proc(path: string) -> (st: Disk_Stamp, ok: bool) {
	k, s := path_stat(path)
	return s, k != .Missing
}

// The stamp of an open file (fstat: never opens the path again).
@(private = "file")
fd_stamp :: proc(f: ^os.File) -> (st: Disk_Stamp, ok: bool) {
	sb: posix.stat_t
	if posix.fstat(posix.FD(os.fd(f)), &sb) != .OK do return {}, false
	return stamp_of_stat(&sb), posix.S_ISREG(sb.st_mode)
}

CREDENTIALS_NOT_OPENED :: "Credentials file: managed by pi (/login), not opened"

// Reads a file the editor may show: a regular file (symlinks followed), at
// most EDITOR_MAX_BYTES, not binary. Otherwise refused says why (data nil).
// Opened non-blocking and checked again on the open file, so a FIFO or a
// device (even one swapped in after the stat) never blocks or streams.
disk_read :: proc(path: string, allocator := context.allocator) -> (data: []u8, st: Disk_Stamp, refused: string) {
	// sign-ins and .env files are never read, by any name (settings_files.odin)
	if settings_credential(path) do return nil, {}, CREDENTIALS_NOT_OPENED
	kind, pre := path_stat(path)
	switch kind {
	case .Missing: return nil, {}, "Cannot open: no such file"
	case .Dir:     return nil, {}, "This is a folder"
	case .Other:   return nil, {}, "Not a regular file (a pipe, device or socket): not opened"
	case .File:
	}
	if pre.size > EDITOR_MAX_BYTES do return nil, {}, too_large(pre.size)
	f, oerr := os.open(path, {.Read, .Non_Blocking})
	if oerr != nil do return nil, {}, fmt.tprintf("Cannot read: %v", oerr)
	defer os.close(f)
	ff, fok := fd_stamp(f)
	if !fok do return nil, {}, "Not a regular file (a pipe, device or socket): not opened"
	if credential_inode(ff.dev, ff.inode) do return nil, {}, CREDENTIALS_NOT_OPENED // swapped in after the check
	if ff.size > EDITOR_MAX_BYTES do return nil, {}, too_large(ff.size)
	buf := make([dynamic]u8, 0, int(ff.size), allocator)
	chunk: [64 * 1024]u8
	for {
		n, rerr := disk_read_chunk(f, chunk[:])
		if n > 0 do append(&buf, ..chunk[:n])
		if len(buf) > EDITOR_MAX_BYTES {
			delete(buf)
			return nil, {}, too_large(i64(len(buf)))
		}
		if rerr == .EOF || (rerr == nil && n == 0) do break
		if rerr != nil {
			// never a short file: a truncated buffer would be saved over the real one
			delete(buf)
			return nil, {}, fmt.tprintf("Cannot read: %v", rerr)
		}
	}
	if looks_binary(buf[:]) {
		delete(buf)
		return nil, {}, "Binary file: not shown"
	}
	return buf[:], ff, ""
}

// One read for disk_read (tests swap in a failing one).
disk_read_chunk: proc(f: ^os.File, p: []u8) -> (int, os.Error) = proc(f: ^os.File, p: []u8) -> (int, os.Error) {return os.read(f, p)}

@(private = "file")
too_large :: proc(size: i64) -> string {
	return fmt.tprintf("Too large to open (%.1f MB; the editor opens files up to %d MB)", f64(size) / (1 << 20), EDITOR_MAX_BYTES >> 20)
}

// Whether path is a regular file, or not there at all (restored tabs).
regular_or_missing :: proc(path: string) -> bool {
	k := path_kind(path)
	return k == .Missing || k == .File
}

// Reads path into e (a fresh editor). False with e.refused set when the
// file cannot be shown; the tab still opens and says why.
editor_load :: proc(e: ^Editor, path: string) -> bool {
	e.goal_col = -1
	e.eol = "\n"
	e.indent_w = 4
	e.path = strings.clone(path)
	data, st, refused := disk_read(path)
	if refused != "" {
		e.refused = strings.clone(refused)
		tb_init(&e.buf, nil)
		e.readonly = true
		return false
	}
	e.disk_hash = text_hash(data)
	tb_init(&e.buf, data)
	e.disk = st
	// big files are plain text (highlighting them costs more than it helps)
	syntax_open(&e.sx, len(data) <= SYNTAX_MAX_BYTES ? language_for_path(path) : nil, &e.buf)
	detect_format(e)
	// Atlas's copy of the user guide (agent.odin) is rewritten at startup: never edited
	if editor_guide_copy(path) do e.readonly = true
	return true
}

editor_guide_copy :: proc(path: string) -> bool {
	g := agent_guide_path()
	return g != "" && path == g
}

// Writes the buffer to its file atomically: a temporary file next to it,
// synced, given the file's permissions, then renamed over it. A symlink
// stays a symlink (its target is written). Returns an error message.
editor_save :: proc(e: ^Editor) -> string {
	if e.view != .File do return "this view is read-only"
	if e.refused != "" do return e.refused
	if e.readonly do return "a read-only copy: not saved"
	target := e.path
	if real := posix.realpath(strings.clone_to_cstring(e.path, context.temp_allocator), nil); real != nil {
		target = strings.clone(string(real), context.temp_allocator)
		posix.free(real)
	}
	mode := os.Permissions_Default_File
	if st, ok := disk_stamp(target); ok {
		mode = os.perm_number(int(st.mode))
		// the rename below would replace it anyway: say so instead
		if posix.access(strings.clone_to_cstring(target, context.temp_allocator), {.W_OK}) != .OK do return fmt.tprintf("%s is read-only (no write permission): not saved", filepath.base(target))
	}
	dir, base := filepath.split(target)
	tmp := fmt.tprintf("%s/.%s.deckhand-%d.tmp", dir, base, time.now()._nsec)
	f, err := os.open(tmp, {.Write, .Create, .Excl}, mode)
	if err != nil do return fmt.tprintf("cannot write %s: %v", dir, err)
	ok := true
	at := 0
	for at < tb_len(&e.buf) && ok {
		c := tb_chunk(&e.buf, at)
		n, werr := os.write(f, c)
		ok = werr == nil && n == len(c)
		at += len(c)
	}
	ok = ok && os.sync(f) == nil
	ok = ok && os.change_mode(tmp, mode) == nil // the umask may have narrowed it
	// our file's stamp, taken before the rename: a write that lands right
	// after it is someone else's (the next check sees a different stamp)
	saved, sok := fd_stamp(f)
	os.close(f)
	ok = ok && sok
	if !ok || os.rename(tmp, target) != nil {
		os.remove(tmp)
		return fmt.tprintf("could not save %s", e.path)
	}
	e.disk = saved
	e.disk_hash = buffer_hash(&e.buf)
	e.saved_group = len(e.undo) > 0 ? e.undo[len(e.undo) - 1].id : 0
	e.break_group = true
	e.missing = false
	editor_drop_disk_text(e)
	e.git.stale = true
	app.redraw = true
	return ""
}

editor_drop_disk_text :: proc(e: ^Editor) {
	delete(e.disk_text)
	e.disk_text = ""
	delete(e.disk_refused)
	e.disk_refused = ""
	e.disk_changed = false
}

// Loads the file again from scratch (it can no longer be shown, or the
// user reloads it): history, highlighting and the buffer start over; a
// file that cannot be shown leaves a read-only tab that says why.
editor_reopen :: proc(e: ^Editor) {
	path := strings.clone(e.path, context.temp_allocator)
	tb_destroy(&e.buf)
	syntax_close(&e.sx)
	ed_clear_history(e)
	editor_drop_disk_text(e)
	delete(e.path)
	delete(e.refused)
	e.path, e.refused = "", ""
	e.readonly = e.always_readonly
	e.cursor, e.anchor, e.top, e.top_sub, e.frac, e.scroll_x = 0, 0, 0, 0, 0, 0
	e.saved_group = 0
	e.gen += 1
	e.git.stale = true
	editor_load(e, path)
	app.redraw = true
}

// Looks at the file on disk: a clean buffer reloads, a dirty one gets the
// banner. Cheap when nothing changed (one stat).
editor_check_disk :: proc(e: ^Editor) {
	if e.view != .File || e.refused != "" do return
	st, ok := disk_stamp(e.path)
	if !ok {
		if !e.missing {
			e.missing = true
			app.redraw = true
		}
		return
	}
	was_missing := e.missing
	e.missing = false
	if !was_missing && st == e.disk do return
	e.disk = st
	data, _, refused := disk_read(e.path)
	if refused != "" {
		// became something we cannot show (binary, huge, not a file): keep
		// the buffer and ask; Reload then shows why instead of the bytes
		set_disk_text(e, "")
		delete(e.disk_refused)
		e.disk_refused = strings.clone(refused)
		e.disk_hash = 0
		return
	}
	defer delete(data)
	h := text_hash(data)
	if h == e.disk_hash && !was_missing {
		app.redraw = true
		return // touched, or our own save
	}
	if !editor_dirty(e) && !e.disk_changed {
		editor_reload_text(e, string(data))
		e.disk_hash = h
		return
	}
	set_disk_text(e, string(data))
	e.disk_hash = h
}

@(private = "file")
set_disk_text :: proc(e: ^Editor, text: string) {
	delete(e.disk_text)
	e.disk_text = strings.clone(text)
	e.disk_changed = true
	app.redraw = true
}

// Replaces the buffer's text with `text` as one undoable step that leaves it
// clean: only the changed middle is replaced, so the cursor, the selection
// and the scroll stay on the same text.
editor_reload_text :: proc(e: ^Editor, text: string) {
	old_len := tb_len(&e.buf)
	p := 0 // common prefix
	for p < old_len && p < len(text) {
		c := tb_chunk(&e.buf, p)
		k := min(len(c), len(text) - p)
		j := 0
		for j < k && c[j] == text[p + j] do j += 1
		p += j
		if j < k do break
	}
	s := 0 // common suffix, not overlapping the prefix
	for s < old_len - p && s < len(text) - p && tb_byte(&e.buf, old_len - 1 - s) == text[len(text) - 1 - s] do s += 1
	lo, hi := p, old_len - s
	ins := text[p:len(text) - s]
	if lo == hi && ins == "" do return
	map_pos :: proc(pos, lo, hi, n: int) -> int {
		if pos <= lo do return pos
		if pos >= hi do return pos + n - (hi - lo)
		return min(pos, lo + n)
	}
	a, c := map_pos(e.anchor, lo, hi, len(ins)), map_pos(e.cursor, lo, hi, len(ins))
	top, sub, frac := e.top, e.top_sub, e.frac
	was_readonly := e.readonly
	e.readonly = false
	e.break_group = true
	ed_replace(e, lo, hi, ins, .Other)
	e.readonly = was_readonly
	e.break_group = true
	e.anchor, e.cursor = a, c
	e.top, e.top_sub, e.frac = min(top, tb_line_count(&e.buf) - 1), sub, frac
	e.follow = false
	e.saved_group = len(e.undo) > 0 ? e.undo[len(e.undo) - 1].id : 0
	// a huge change is not worth keeping as history
	if hi - lo + len(ins) > 8 << 20 do ed_clear_history(e)
}

// The banner's Reload: the disk version replaces the buffer (undoable).
editor_take_disk :: proc(e: ^Editor) {
	if !e.disk_changed do return
	if e.disk_refused != "" {
		editor_reopen(e) // not showable now: the tab says why
		return
	}
	if e.disk_text != "" || tb_len(&e.buf) > 0 do editor_reload_text(e, e.disk_text)
	e.disk_hash = text_hash(transmute([]u8)e.disk_text)
	editor_drop_disk_text(e)
}

// The banner's Keep mine: the buffer stays (dirty); saving overwrites the file.
editor_keep_mine :: proc(e: ^Editor) {
	editor_drop_disk_text(e)
	e.saved_group = max(u64) // dirty until saved, even after undoing back
	app.redraw = true
}
