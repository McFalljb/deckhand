package main

// Git gutter: lines added, changed or removed against HEAD. The HEAD version
// comes from `git cat-file blob HEAD:<path>` (raw: no textconv or filters),
// read on a worker thread once per open (and again after a save or a change
// under .git) and handed back through the inbox (Git_Head_Done); the diff is
// computed here, in process, a moment after typing pauses
// (EDITOR_DIFF_DELAY). Also the line diff behind the read-only diff views
// (Diff with HEAD, Compare with disk).
//
// Every git call runs with a timeout (GIT_TIMEOUT), without optional locks,
// with core.fsmonitor off and no hooks (GIT_FLAGS: a repository's hooks are
// programs we would otherwise start).

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:sync"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"

GIT_TIMEOUT :: 5 * time.Second

Git_Mark :: enum u8 {
	None,
	Added,
	Modified,
}

Git_Gutter :: struct {
	loaded:  bool, // HEAD was looked up
	loading: bool, // a worker is reading HEAD now
	load_gen: u64, // the newest load; an older result is dropped
	tracked: bool, // the file is in HEAD
	in_repo: bool,
	head:    string, // HEAD's text (owned)
	marks:   [dynamic]Git_Mark, // per buffer line
	removed: [dynamic]bool, // per buffer line: lines were removed just above it (len = lines + 1)
	stale:   bool, // the buffer changed since the marks
	head_stale: bool, // HEAD may have moved (a change under .git)
	counts:  [3]int, // added, modified, removed lines (editor_state)
}

git_gutter_free :: proc(g: ^Git_Gutter) {
	delete(g.head)
	delete(g.marks)
	delete(g.removed)
	g^ = {}
}

// Every git run: no optional locks, no fsmonitor program, no hooks (a
// repository's hooks are programs we would otherwise start, e.g.
// reference-transaction on git branch -d).
GIT_FLAGS :: [?]string{"git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"}

// Runs git in dir (bounded; see the top); stdout on success (temp allocator).
git_run :: proc(dir: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	flags := GIT_FLAGS
	append(&cmd, ..flags[:])
	append(&cmd, "-C", dir)
	append(&cmd, ..args)
	return run_bounded("", cmd[:], GIT_TIMEOUT)
}

@(private = "file")
run_seq: int // unique output file names (atomic)

// Git with input on stdin (git_run otherwise).
git_run_input :: proc(dir, input: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	flags := GIT_FLAGS
	append(&cmd, ..flags[:])
	append(&cmd, "-C", dir)
	append(&cmd, ..args)
	return run_bounded("", cmd[:], GIT_TIMEOUT, input)
}

// Runs cmd in dir (""= ours); stdout on exit 0 (temp allocator). Killed at
// the timeout (then not ok). Output (and input, if any) goes through
// temporary files, so a large one never blocks the child on a full pipe.
run_bounded :: proc(dir: string, cmd: []string, timeout: time.Duration, input := "") -> (out: string, ok: bool) {
	tmpdir := os.get_env("TMPDIR", context.temp_allocator)
	if tmpdir == "" do tmpdir = "/tmp"
	path := fmt.tprintf("%s/pi-desk-run-%d-%d.out", strings.trim_right(tmpdir, "/"), os.get_pid(), sync.atomic_add(&run_seq, 1))
	f, ferr := os.open(path, {.Read, .Write, .Create, .Excl}, os.perm_number(0o600))
	if ferr != nil do return "", false
	defer {
		os.close(f)
		os.remove(path)
	}
	stdin: ^os.File
	defer if stdin != nil do os.close(stdin)
	if input != "" {
		ipath := fmt.tprintf("%s.in", path)
		ierr: os.Error
		stdin, ierr = os.open(ipath, {.Read, .Write, .Create, .Excl}, os.perm_number(0o600))
		if ierr != nil do return "", false
		os.remove(ipath) // the open handle keeps it until closed
		if _, werr := os.write_string(stdin, input); werr != nil do return "", false
		if _, serr := os.seek(stdin, 0, .Start); serr != nil do return "", false
	}
	p, perr := os.process_start({command = cmd, working_dir = dir, stdout = f, stdin = stdin})
	if perr != nil do return "", false
	st, werr := os.process_wait(p, timeout)
	if werr != nil || !st.exited {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		return "", false
	}
	if st.exit_code != 0 do return "", false
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return "", false
	return string(data), true
}

// The repository root holding path ("" = not in a repository).
git_toplevel :: proc(path: string) -> string {
	out, ok := git_run(filepath.dir(path), "rev-parse", "--show-toplevel")
	if !ok do return ""
	return strings.trim_space(out)
}

// The file's HEAD version (any thread; temp allocator).
git_head_read :: proc(path: string) -> (in_repo, tracked: bool, head: string) {
	top := git_toplevel(path)
	if top == "" do return
	in_repo = true
	rel, rerr := filepath.rel(fs_real(top), fs_real(path), context.temp_allocator)
	if rerr != .None do return
	out, ok := git_run(top, "cat-file", "blob", strings.concatenate({"HEAD:", rel}, context.temp_allocator))
	if !ok do return
	return true, true, out
}

// Internal only: a worker read a file's HEAD version (Git_Head_Done) or a
// repository's status (Git_Status_Done).
Git_Head_Done :: struct {
	tab_id:  u64,
	gen:     u64, // Git_Gutter.load_gen when it started
	path:    string,
	in_repo: bool,
	tracked: bool,
	head:    string,
}
Git_Status_Done :: struct {
	root: string,
	gen:  u64, // Git_Status.gen when it started
	ok:   bool,
	out:  string, // git status --porcelain=v1 -z
}

// Starts reading the file's HEAD version on a worker thread (the result
// comes back as Git_Head_Done). sync: read it now (an explicit request,
// bounded by GIT_TIMEOUT).
git_load_head :: proc(e: ^Editor, sync_now := false) {
	g := &e.git
	if e.view != .File || e.refused != "" {
		g.loaded, g.loading, g.head_stale = true, false, false
		return
	}
	g.load_gen += 1 // any result still on its way is older now
	g.head_stale = false // a .git change from here on asks again
	if sync_now {
		g.loading = false
		in_repo, tracked, head := git_head_read(e.path)
		git_head_set(e, in_repo, tracked, head)
		return
	}
	g.loading = true
	Job :: struct {
		tab_id: u64,
		gen:    u64,
		path:   string,
	}
	job := new(Job, runtime.heap_allocator())
	job^ = {e.tab_id, g.load_gen, strings.clone(e.path, runtime.heap_allocator())}
	thread.run_with_poly_data(job, proc(job: ^Job) {
		in_repo, tracked, head := git_head_read(job.path)
		inbox_submit(Git_Head_Done{tab_id = job.tab_id, gen = job.gen, path = job.path, in_repo = in_repo, tracked = tracked, head = head}, {kind = .Internal})
		delete(job.path, runtime.heap_allocator())
		free(job, runtime.heap_allocator())
		free_all(context.temp_allocator)
	})
}

git_head_set :: proc(e: ^Editor, in_repo, tracked: bool, head: string) {
	g := &e.git
	delete(g.head)
	g.head = strings.clone(head)
	g.loaded, g.loading = true, false // head_stale stays: a .git change during the load asks again
	g.in_repo, g.tracked = in_repo, tracked
	g.stale = true
	app.redraw = true
}

// Recomputes the marks if the buffer changed and typing paused (or now).
git_gutter_update :: proc(e: ^Editor, force := false) {
	g := &e.git
	if (!g.loaded || g.head_stale) && !g.loading do git_load_head(e) // one load at a time; stale again after it: the next
	if !g.loaded do return // HEAD is on its way
	if !g.stale do return
	if !force && time.tick_since(e.last_edit) < EDITOR_DIFF_DELAY do return
	g.stale = false
	n := tb_line_count(&e.buf)
	resize(&g.marks, n)
	resize(&g.removed, n + 1)
	slice.fill(g.marks[:], Git_Mark.None)
	slice.fill(g.removed[:], false)
	g.counts = {}
	if !g.in_repo do return
	if !g.tracked {
		// untracked: no bars (every line would be "added"); counts say so
		g.counts[0] = n
		app.redraw = true
		return
	}
	a := line_hashes_of_string(g.head)
	b := line_hashes_of_buffer(e)
	for h in line_diff(a, b) {
		switch {
		case h.a_lo == h.a_hi:
			for i in h.b_lo ..< h.b_hi do g.marks[i] = .Added
			g.counts[0] += h.b_hi - h.b_lo
		case h.b_lo == h.b_hi:
			g.removed[h.b_lo] = true
			g.counts[2] += h.a_hi - h.a_lo
		case:
			for i in h.b_lo ..< h.b_hi do g.marks[i] = .Modified
			g.counts[1] += h.b_hi - h.b_lo
		}
	}
	app.redraw = true
}

// One hash per line (without its ending), temp allocator.
line_hashes_of_string :: proc(s: string) -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	rest := s
	for len(rest) > 0 {
		i := strings.index_byte(rest, '\n')
		line := i < 0 ? rest : rest[:i]
		append(&out, hash.fnv64a(transmute([]u8)strings.trim_suffix(line, "\r")))
		if i < 0 {
			rest = ""
			break
		}
		rest = rest[i + 1:]
	}
	if len(s) == 0 || s[len(s) - 1] == '\n' do append(&out, hash.fnv64a(nil)) // the empty last line
	return out[:]
}

line_hashes_of_buffer :: proc(e: ^Editor) -> []u64 {
	n := tb_line_count(&e.buf)
	out := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n do out[i] = hash.fnv64a(transmute([]u8)tb_line(&e.buf, i, &e.scratch))
	return out
}

// A changed region: lines [a_lo, a_hi) of a became [b_lo, b_hi) of b.
Diff_Hunk :: struct {
	a_lo, a_hi, b_lo, b_hi: int,
}

DIFF_MAX_D :: 1000 // edit distance past which the rest is one changed block (bounds the trace's memory)

// Myers' O(ND) line diff with the common head and tail trimmed first
// (temp allocator).
line_diff :: proc(a, b: []u64) -> []Diff_Hunk {
	out := make([dynamic]Diff_Hunk, context.temp_allocator)
	pre := 0
	for pre < len(a) && pre < len(b) && a[pre] == b[pre] do pre += 1
	suf := 0
	for suf < len(a) - pre && suf < len(b) - pre && a[len(a) - 1 - suf] == b[len(b) - 1 - suf] do suf += 1
	A := a[pre:len(a) - suf]
	B := b[pre:len(b) - suf]
	N, M := len(A), len(B)
	if N == 0 && M == 0 do return out[:]
	if N == 0 || M == 0 {
		append(&out, Diff_Hunk{pre, pre + N, pre, pre + M})
		return out[:]
	}
	MAX := min(N + M, DIFF_MAX_D)
	off := MAX + 1
	v := make([]int, 2 * MAX + 3, context.temp_allocator)
	// trace[d]: v on diagonals -(d-1), -(d-1)+2 .. d-1 as they were when
	// step d began (only those are read walking back): d values, so the
	// memory is about DIFF_MAX_D² / 2 i32s (≤ 2 MB), not D × (2·MAX).
	trace := make([dynamic][]i32, context.temp_allocator)
	found := -1
	outer: for d in 0 ..= MAX {
		snap := make([]i32, d, context.temp_allocator)
		for i in 0 ..< d do snap[i] = i32(v[off - (d - 1) + 2 * i])
		append(&trace, snap)
		for k := -d; k <= d; k += 2 {
			x: int
			if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) do x = v[off + k + 1]
			else do x = v[off + k - 1] + 1
			y := x - k
			for x < N && y < M && A[x] == B[y] {
				x += 1
				y += 1
			}
			v[off + k] = x
			if x >= N && y >= M {
				found = d
				break outer
			}
		}
	}
	if found < 0 {
		append(&out, Diff_Hunk{pre, pre + N, pre, pre + M})
		return out[:]
	}
	// walk back: each step is one insertion or deletion; group them into hunks
	Step :: struct {
		del:  bool,
		x, y: int, // position before the step
	}
	at :: proc(snap: []i32, d, k: int) -> int {return int(snap[(k + d - 1) / 2])}
	steps := make([dynamic]Step, context.temp_allocator)
	x, y := N, M
	for d := found; d > 0; d -= 1 {
		vv := trace[d]
		k := x - y
		prev_k: int
		if k == -d || (k != d && at(vv, d, k - 1) < at(vv, d, k + 1)) do prev_k = k + 1
		else do prev_k = k - 1
		px := at(vv, d, prev_k)
		py := px - prev_k
		for x > px && y > py {
			x -= 1
			y -= 1
		}
		if prev_k == k + 1 do append(&steps, Step{del = false, x = x, y = y - 1}) // insertion of B[y-1]
		else do append(&steps, Step{del = true, x = x - 1, y = y}) // deletion of A[x-1]
		x, y = px, py
	}
	slice.reverse(steps[:])
	i := 0
	for i < len(steps) {
		h := Diff_Hunk{steps[i].x, steps[i].x, steps[i].y, steps[i].y}
		for i < len(steps) {
			s := steps[i]
			if s.del && s.x == h.a_hi && s.y == h.b_hi {
				h.a_hi += 1
			} else if !s.del && s.y == h.b_hi && s.x == h.a_hi {
				h.b_hi += 1
			} else do break
			i += 1
		}
		append(&out, Diff_Hunk{h.a_lo + pre, h.a_hi + pre, h.b_lo + pre, h.b_hi + pre})
	}
	return out[:]
}

// A unified diff of two texts (the read-only diff views), with 3 lines of
// context. Temp allocator.
unified_diff :: proc(a, b: string, a_name, b_name: string) -> string {
	al := strings.split_lines(a, context.temp_allocator)
	bl := strings.split_lines(b, context.temp_allocator)
	hunks := line_diff(line_hashes_of_string(a), line_hashes_of_string(b))
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "--- ")
	strings.write_string(&sb, a_name)
	strings.write_string(&sb, "\n+++ ")
	strings.write_string(&sb, b_name)
	strings.write_byte(&sb, '\n')
	if len(hunks) == 0 {
		strings.write_string(&sb, "(no differences)\n")
		return strings.to_string(sb)
	}
	CTX :: 3
	i := 0
	for i < len(hunks) {
		// merge hunks whose context overlaps
		j := i
		for j + 1 < len(hunks) && hunks[j + 1].a_lo - hunks[j].a_hi <= 2 * CTX do j += 1
		a0 := max(hunks[i].a_lo - CTX, 0)
		b0 := max(hunks[i].b_lo - CTX, 0)
		a1 := min(hunks[j].a_hi + CTX, len(al))
		b1 := min(hunks[j].b_hi + CTX, len(bl))
		strings.write_string(&sb, "@@ -")
		strings.write_int(&sb, a0 + 1)
		strings.write_byte(&sb, ',')
		strings.write_int(&sb, a1 - a0)
		strings.write_string(&sb, " +")
		strings.write_int(&sb, b0 + 1)
		strings.write_byte(&sb, ',')
		strings.write_int(&sb, b1 - b0)
		strings.write_string(&sb, " @@\n")
		at := a0
		for k in i ..= j {
			h := hunks[k]
			for ; at < h.a_lo; at += 1 do line_out(&sb, ' ', al[at])
			for x in h.a_lo ..< h.a_hi do if x < len(al) do line_out(&sb, '-', al[x])
			for y in h.b_lo ..< h.b_hi do if y < len(bl) do line_out(&sb, '+', bl[y])
			at = h.a_hi
		}
		for ; at < a1; at += 1 do line_out(&sb, ' ', al[at])
		i = j + 1
	}
	return strings.to_string(sb)
}

@(private = "file")
line_out :: proc(sb: ^strings.Builder, c: u8, line: string) {
	strings.write_byte(sb, c)
	strings.write_string(sb, strings.trim_suffix(line, "\r"))
	strings.write_byte(sb, '\n')
}
