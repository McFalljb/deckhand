package main

// "Open file…" (⌘P): the command palette in file mode, over the current
// project's files (fs_project_files: git's list, gitignore respected).
// Ranked with the palette's fuzzy match on the file name first, then the
// path; the ranking is cached until the query or the file list changes.

import "core:path/filepath"
import "core:slice"
import "core:strings"

@(private = "file")
Finder :: struct {
	root:   string, // owned
	query:  string, // owned
	list:   rawptr, // the file list the ranking is for (data pointer)
	n:      int,
	ranked: [dynamic]Ranked,
}

@(private = "file")
Ranked :: struct {
	index:   int,
	score:   int,
	matched: u64,
}

@(private = "file")
finder: Finder

// ⌘P: opens the palette on the current project's files (or closes it).
palette_open_files :: proc() {
	if palette_is_open() && palette.files {
		ui_do(Set_Focus{""})
		return
	}
	if fs_base_dir() == "" do return
	palette_reset()
	palette.files = true
	palette.was_open = true
	ui_do(Set_Focus{"palette"})
}

file_finder_results :: proc(query: string) -> []Palette_Item {
	base := fs_base_dir()
	if base == "" do return nil
	root := fs_real(base)
	files := fs_project_files(root)
	if root != finder.root || query != finder.query || raw_data(files) != finder.list || len(files) != finder.n {
		delete(finder.root)
		delete(finder.query)
		finder.root = strings.clone(root)
		finder.query = strings.clone(query)
		finder.list, finder.n = raw_data(files), len(files)
		rank(files, query)
	}
	out := make([]Palette_Item, min(len(finder.ranked), PALETTE_RESULTS_MAX), context.temp_allocator)
	for &it, i in out {
		r := finder.ranked[i]
		rel := files[r.index]
		dir := filepath.dir(rel)
		if dir == "." do dir = ""
		abs, _ := filepath.join({root, rel}, context.temp_allocator)
		it = Palette_Item{kind = .File, key = strings.concatenate({"file:", rel}, context.temp_allocator), title = filepath.base(rel), detail = dir, path = abs, matched = r.matched, order = i}
	}
	return out
}

@(private = "file")
rank :: proc(files: []string, query: string) {
	clear(&finder.ranked)
	words := strings.fields(query, context.temp_allocator)
	for f, i in files {
		total := 0
		matched: u64
		ok := true
		name := filepath.base(f)
		for w in words {
			if s, m, hit := fuzzy_score(w, name); hit {
				total += 2 * s
				matched |= m
				continue
			}
			s, _, hit := fuzzy_score(w, f)
			if !hit {
				ok = false
				break
			}
			total += s
		}
		if !ok do continue
		append(&finder.ranked, Ranked{index = i, score = total, matched = matched})
	}
	slice.sort_by(finder.ranked[:], proc(a, b: Ranked) -> bool {
		if a.score != b.score do return a.score > b.score
		return a.index < b.index // the list is sorted by path: shallower and alphabetical first
	})
	if len(finder.ranked) > PALETTE_RESULTS_MAX do resize(&finder.ranked, PALETTE_RESULTS_MAX)
}
