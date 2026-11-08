package main

// Session titles, as pi's own session list (`pi --resume`) names a session
// (core/session-manager.js buildSessionInfo + session-selector.js):
//   1. the latest `session_info` entry's name (trimmed; an empty one clears
//      an earlier name), set by /name at any time, anywhere in the file;
//   2. else the first `message` entry with role "user" that has text: its
//      content string, or its "text" blocks joined with " ";
//   3. (pi-desk only) else the objective of the first pi-goal (`custom`
//      entry, customType "pi-goal", data.goal.objective): a session started
//      by /goal before any typed prompt;
//   4. else "" (shown as "Untitled session · <created>", sidebar.odin).
// Control characters become spaces (pi does the same before it truncates).
//
// The latest name can be anywhere, so every byte of a file is read once:
// streamed in chunks, only lines whose head looks like one of those entries
// are kept and parsed. Each file's result and the offset read so far are
// cached (path, size, mtime); a file that grew is read from that offset
// only. Small amounts are read on the main thread; bigger ones (a first
// pass over a long session) on a worker, which marks the lists for a
// refresh (titles_tick). The cache is saved in the data dir
// (session-titles.tsv) so a launch reads only what is new.

import "base:runtime"
import "core:bytes"
import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

TITLE_MAX :: 200 // bytes kept of a title (the rows clip far shorter)
TITLE_INLINE :: 1 << 20 // at most this much new data in one file is read on the main thread...
TITLE_INLINE_BUDGET :: 8 << 20 // ...and this much per listing; the rest goes to the worker
@(private = "file")
SCAN_BUF :: 1 << 20
@(private = "file")
LINE_HEAD :: 1024 // bytes of a line looked at to decide whether to keep it
@(private = "file")
LINE_MAX :: 64 << 20 // a kept line longer than this is skipped
@(private = "file")
TITLES_FILE :: "session-titles.tsv"
@(private = "file")
TITLES_VERSION :: "pi-desk session titles 2"
@(private = "file")
HEAD_CHECK :: 4096

// What a file's lines say so far, and the offset (a line start) read up to.
Title_Scan :: struct {
	offset:     i64,
	head_len:   i64, // the first bytes read (up to HEAD_CHECK) and their hash:
	head_hash:  u64, // a rewritten file no longer has them, and is read again
	name:       string, // latest session_info name ("" = none or cleared)
	first_user: string, // first user message text
	goal:       string, // first pi-goal objective
}

@(private = "file")
Title_Entry :: struct {
	size:  i64,
	mtime: i64, // ns
	scan:  Title_Scan,
}

@(private = "file")
titles: struct {
	mu:        sync.Mutex,
	entries:   map[string]Title_Entry, // keys and strings: heap
	queue:     [dynamic]string, // paths for the worker (heap)
	queued:    map[string]bool, // in queue or being read by the worker
	running:   bool, // a worker thread is up
	changed:   bool, // the worker stored something since titles_tick looked
	dirty:     bool, // differs from the saved file
	path:      string, // the saved file ("" = not saved)
	saved_at:  time.Tick,
}

// Bytes read by title scans (tests and the measurement).
title_bytes_read: i64

@(private = "file")
title_of_scan :: proc(sc: Title_Scan) -> string {
	if sc.name != "" do return sc.name
	if sc.first_user != "" do return sc.first_user
	return sc.goal
}

@(private = "file")
scan_free :: proc(sc: ^Title_Scan) {
	heap := runtime.heap_allocator()
	delete(sc.name, heap)
	delete(sc.first_user, heap)
	delete(sc.goal, heap)
	sc^ = {}
}

@(private = "file")
scan_clone :: proc(sc: Title_Scan) -> Title_Scan {
	heap := runtime.heap_allocator()
	return {offset = sc.offset, head_len = sc.head_len, head_hash = sc.head_hash, name = strings.clone(sc.name, heap), first_user = strings.clone(sc.first_user, heap), goal = strings.clone(sc.goal, heap)}
}

// The title of the session file at `path` (size and mtime as listed),
// allocated with context.allocator. Main thread. Up to TITLE_INLINE new
// bytes (and what is left of *budget) are read now; more is read by the
// worker, and until then the last known title ("" if none) is returned.
title_of :: proc(path: string, size: i64, mtime: time.Time, budget: ^i64 = nil, allocator := context.allocator) -> string {
	context.allocator = allocator
	sync.lock(&titles.mu)
	e, known := titles.entries[path]
	if known && e.size == size && e.mtime == mtime._nsec {
		t := strings.clone(title_of_scan(e.scan))
		sync.unlock(&titles.mu)
		return t
	}
	busy := titles.queued[path]
	sc: Title_Scan
	if known do sc = scan_clone(e.scan)
	sync.unlock(&titles.mu)

	pending := size - sc.offset
	if pending < 0 do pending = size // shorter than what was read: read again from the start
	room := budget != nil ? budget^ : i64(TITLE_INLINE)
	if busy || pending > TITLE_INLINE || pending > room {
		t := strings.clone(title_of_scan(sc))
		scan_free(&sc)
		if !busy do titles_enqueue(path)
		return t
	}
	if budget != nil do budget^ -= pending
	title_scan_file(path, &sc, size)
	t := strings.clone(title_of_scan(sc))
	// as far as it read (a line start): a read that stopped short, or a
	// line pi is still writing, is read on from there next time
	titles_store(path, sc.offset, mtime._nsec, sc)
	return t
}

// The cached title of `path`, without reading it ("" = none yet).
title_cached :: proc(path: string, allocator := context.allocator) -> string {
	sync.lock(&titles.mu)
	defer sync.unlock(&titles.mu)
	if e, ok := titles.entries[path]; ok do return strings.clone(title_of_scan(e.scan), allocator)
	return ""
}

// Takes ownership of sc's strings.
@(private = "file")
titles_store :: proc(path: string, size, mtime: i64, sc: Title_Scan) {
	heap := runtime.heap_allocator()
	sync.lock(&titles.mu)
	defer sync.unlock(&titles.mu)
	if titles.entries.allocator.procedure == nil do titles.entries = make(map[string]Title_Entry, heap)
	if e, ok := &titles.entries[path]; ok {
		scan_free(&e.scan)
		e^ = {size = size, mtime = mtime, scan = sc}
	} else do titles.entries[strings.clone(path, heap)] = {size = size, mtime = mtime, scan = sc}
	titles.dirty = true
}

@(private = "file")
titles_enqueue :: proc(path: string) {
	heap := runtime.heap_allocator()
	sync.lock(&titles.mu)
	defer sync.unlock(&titles.mu)
	if titles.queued.allocator.procedure == nil do titles.queued = make(map[string]bool, heap)
	if titles.queue.allocator.procedure == nil do titles.queue = make([dynamic]string, heap)
	if titles.queued[path] do return
	p := strings.clone(path, heap)
	titles.queued[p] = true
	append(&titles.queue, p)
	if !titles.running {
		titles.running = true
		context.allocator = heap // the thread frees itself with it
		thread.create_and_start(titles_worker, runtime.default_context(), self_cleanup = true)
	}
}

// Reads queued files in order (the listing's: newest first), one at a time.
@(private = "file")
titles_worker :: proc() {
	heap := runtime.heap_allocator()
	for {
		sync.lock(&titles.mu)
		if len(titles.queue) == 0 {
			titles.running = false
			sync.unlock(&titles.mu)
			return
		}
		path := pop_front(&titles.queue)
		sc: Title_Scan
		if e, ok := titles.entries[path]; ok do sc = scan_clone(e.scan)
		sync.unlock(&titles.mu)

		if fi, err := os.stat(path, context.temp_allocator); err == nil {
			title_scan_file(path, &sc, fi.size)
			titles_store(path, sc.offset, fi.modification_time._nsec, sc)
		} else do scan_free(&sc)
		sync.lock(&titles.mu)
		delete_key(&titles.queued, path)
		titles.changed = true
		sync.unlock(&titles.mu)
		delete(path, heap)
		free_all(context.temp_allocator)
		if platform.wake != nil do platform.wake()
	}
}

// Whether the worker has files left (tests wait on it).
titles_busy :: proc() -> bool {
	sync.lock(&titles.mu)
	defer sync.unlock(&titles.mu)
	return titles.running || len(titles.queue) > 0
}

// Main thread, every frame: once the worker stored titles, the listed and
// open sessions take them; the cache is saved now and then.
titles_tick :: proc() {
	sync.lock(&titles.mu)
	changed := titles.changed
	titles.changed = false
	save := titles.dirty && titles.path != "" && !titles.running && (titles.saved_at == {} || time.tick_since(titles.saved_at) > 30 * time.Second)
	sync.unlock(&titles.mu)
	if changed {
		refresh_listed_titles()
		for &s in state.open_sessions {
			s.title_size = -1
			s.checked = {}
		}
		app.redraw = true
	}
	if save do titles_save()
	claude_disk_tick() // Claude transcripts read on its worker (claude_disk.odin)
}

// ---- reading a file ----

// Reads `path` from sc.offset up to `size` (complete lines only) into sc.
// A file that is shorter than what was read, whose first bytes changed, or
// whose bytes before sc.offset no longer end a line (rewritten), is read
// from the start.
title_scan_file :: proc(path: string, sc: ^Title_Scan, size: i64) {
	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	if sc.offset > size do scan_free(sc)
	if sc.offset > 0 {
		b: [1]u8
		if n, _ := os.read_at(f, b[:], sc.offset - 1); n != 1 || b[0] != '\n' do scan_free(sc)
	}
	if sc.offset > 0 {
		if h, ok := head_hash(f, sc.head_len); !ok || h != sc.head_hash do scan_free(sc)
	}
	heap := runtime.heap_allocator()
	buf := make([]u8, SCAN_BUF, heap)
	defer delete(buf, heap)
	line := make([dynamic]u8, heap)
	defer delete(line)
	Mode :: enum {
		Head, // deciding (first LINE_HEAD bytes)
		Keep, // wanted: collect to the end
		Skip, // not wanted: drop to the end
	}
	mode := Mode.Head
	pos := sc.offset
	line_start := pos
	for pos < size {
		n, _ := os.read_at(f, buf[:min(i64(SCAN_BUF), size - pos)], pos)
		if n <= 0 do break
		sync.atomic_add(&title_bytes_read, i64(n))
		chunk := buf[:n]
		i := 0
		for i < n {
			nl := bytes.index_byte(chunk[i:], '\n')
			seg := nl < 0 ? chunk[i:] : chunk[i:i + nl]
			if mode != .Skip {
				append(&line, ..seg)
				if mode == .Head && (len(line) >= LINE_HEAD || nl >= 0) {
					mode = line_wanted(string(line[:min(len(line), LINE_HEAD)]), sc^) ? .Keep : .Skip
				}
				if mode == .Keep && len(line) > LINE_MAX do mode = .Skip
				if mode == .Skip do clear(&line)
			}
			if nl < 0 do break
			if mode == .Keep do title_line(line[:], sc)
			clear(&line)
			mode = .Head
			i += nl + 1
			line_start = pos + i64(i)
		}
		pos += i64(n)
	}
	sc.offset = line_start
	if sc.head_len < min(sc.offset, HEAD_CHECK) {
		sc.head_len = min(sc.offset, HEAD_CHECK)
		sc.head_hash, _ = head_hash(f, sc.head_len)
	}
}

// FNV-1a of the first n bytes of f.
@(private = "file")
head_hash :: proc(f: ^os.File, n: i64) -> (u64, bool) {
	buf: [HEAD_CHECK]u8
	got, _ := os.read_at(f, buf[:n], 0)
	if i64(got) != n do return 0, false
	return hash.fnv64a(buf[:n]), true
}

// Whether a line (its head) can change the title, given what sc has.
@(private = "file")
line_wanted :: proc(head: string, sc: Title_Scan) -> bool {
	if strings.contains(head, `"type":"session_info"`) do return true
	if sc.first_user != "" do return false
	if strings.contains(head, `"type":"message"`) && strings.contains(head, `"role":"user"`) do return true
	return sc.goal == "" && strings.contains(head, `"customType":"pi-goal"`)
}

@(private = "file")
title_line :: proc(line: []u8, sc: ^Title_Scan) {
	heap := runtime.heap_allocator()
	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	a := runtime.arena_allocator(&arena)
	v, err := jg.parse(line, .JSON, allocator = a, max_depth = jg.MAX_DEPTH_TRANSCRIPT, fix_utf8 = true) // a title is worth reading lossily
	if err != nil do return // not JSON (cut off, garbage): skipped, as pi does
	obj, _ := v.(json.Object)
	typ, _ := obj["type"].(json.String)
	switch typ {
	case "session_info":
		name, _ := obj["name"].(json.String)
		delete(sc.name, heap)
		sc.name = clean_title(name, heap)
	case "message":
		if sc.first_user != "" do return
		msg, _ := obj["message"].(json.Object)
		if role, _ := msg["role"].(json.String); role != "user" do return
		text: string
		#partial switch c in msg["content"] {
		case json.String:
			text = c
		case json.Array:
			b := strings.builder_make(a)
			for part in c {
				po, _ := part.(json.Object)
				if pt, _ := po["type"].(json.String); pt != "text" do continue
				t, _ := po["text"].(json.String)
				if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
				strings.write_string(&b, t)
			}
			text = strings.to_string(b)
		}
		sc.first_user = clean_title(text, heap)
	case "custom":
		if sc.goal != "" do return
		if ct, _ := obj["customType"].(json.String); ct != "pi-goal" do return
		data, _ := obj["data"].(json.Object)
		goal, _ := data["goal"].(json.Object)
		objective, _ := goal["objective"].(json.String)
		sc.goal = clean_title(objective, heap)
	}
}

// s as one short line: control characters and invalid UTF-8 become spaces
// and "?", trimmed, at most TITLE_MAX bytes (whole characters).
clean_title :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		switch {
		case r == utf8.RUNE_ERROR && w <= 1:
			r = '?'
		case r < 0x20 || r == 0x7f:
			r = ' '
		}
		if strings.builder_len(b) + utf8.rune_size(r) > TITLE_MAX do break
		strings.write_rune(&b, r)
		i += max(w, 1)
	}
	return strings.clone(strings.trim_space(strings.to_string(b)), allocator)
}

// ---- saved cache ----
// One line per file: size, mtime (ns), offset, head length, head hash,
// path, name, first user text, goal, tab-separated (titles never hold
// tabs: clean_title).

// Loads the saved cache from `dir` (the data dir) and saves there from now
// on. Entries whose file is gone are dropped.
titles_load :: proc(dir: string) {
	heap := runtime.heap_allocator()
	path, _ := filepath.join({dir, TITLES_FILE}, heap)
	sync.lock(&titles.mu)
	titles.path = path
	sync.unlock(&titles.mu)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	text := string(data)
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first {
			first = false
			if line != TITLES_VERSION do return
			continue
		}
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 9 do continue
		size, ok1 := strconv.parse_i64(f[0])
		mtime, ok2 := strconv.parse_i64(f[1])
		offset, ok3 := strconv.parse_i64(f[2])
		hlen, ok4 := strconv.parse_i64(f[3])
		hh, ok5 := strconv.parse_u64(f[4])
		if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || hlen < 0 || hlen > HEAD_CHECK || !os.exists(f[5]) do continue
		titles_store(f[5], size, mtime, {offset = offset, head_len = hlen, head_hash = hh, name = strings.clone(f[6], heap), first_user = strings.clone(f[7], heap), goal = strings.clone(f[8], heap)})
	}
	sync.lock(&titles.mu)
	titles.dirty = false
	sync.unlock(&titles.mu)
}

// Writes the cache (when it changed). Main thread.
titles_save :: proc() {
	sync.lock(&titles.mu)
	if !titles.dirty || titles.path == "" {
		sync.unlock(&titles.mu)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, TITLES_VERSION)
	strings.write_byte(&b, '\n')
	for p, e in titles.entries {
		if strings.contains_any(p, "\t\n\r") do continue
		fmt.sbprintf(&b, "%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n", e.size, e.mtime, e.scan.offset, e.scan.head_len, e.scan.head_hash, p, e.scan.name, e.scan.first_user, e.scan.goal)
	}
	titles.dirty = false
	titles.saved_at = time.tick_now()
	path := titles.path
	sync.unlock(&titles.mu)
	if err := write_atomic(path, strings.to_string(b)); err != "" do fmt.eprintln("Deckhand: could not save session titles:", err)
}

// Forgets everything (tests).
titles_clear :: proc() {
	for titles_busy() do time.sleep(time.Millisecond)
	heap := runtime.heap_allocator()
	sync.lock(&titles.mu)
	defer sync.unlock(&titles.mu)
	for k, &e in titles.entries {
		scan_free(&e.scan)
		delete(k, heap)
	}
	clear(&titles.entries)
	titles.changed = false
	titles.dirty = false
	delete(titles.path, heap)
	titles.path = ""
	titles.saved_at = {}
}
