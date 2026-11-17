package core

// What Settings lists of Codex's installed plugins (Settings → Coding agents → Codex: Plugins;
// docs/CODEX.md §6), read-only, by folder names only.
//
// Codex keeps them in its home's plugins/cache/<marketplace>/<plugin>/<version>/ (Codex fills
// plugins/ itself: it stays Codex's, never listed in the file tree, opened or written: codex.odin).
// Deckhand reads only the names of the folders on those three levels: never a file under plugins/
// (no plugin.json, no .mcp.json, nothing that could hold a token), never anything under a
// version's folder, and never a symlink (each level is lstat'ed: a link is skipped, so nothing
// outside the Codex home is looked at). A name is listed only when it is a plain word (letters,
// digits and - _ . + @, not starting with '.', at most NAME_MAX); others are left out. Whether
// a plugin is turned on lives in config.toml (which may hold tokens): not read here.
//
// Rebuilt at most every CODEX_PLUGINS_EVERY per home on the caller's thread (a few short folder
// reads); the rows come from the cache.

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

CODEX_PLUGINS_EVERY :: 2 * time.Second
@(private = "file")
NAME_MAX :: 100
@(private = "file")
MARKETPLACES_MAX :: 32 // marketplaces looked at per home
@(private = "file")
LIST_MAX :: 200 // plugins listed per home
@(private = "file")
VERSIONS_MAX :: 8 // versions named per plugin

Codex_Plugin_Entry :: struct {
	name:     string, // "<plugin>@<marketplace>", as Codex names it
	versions: []string, // its version folders' names, sorted (none: an empty folder)
}

@(private = "file")
Home_Plugins :: struct {
	home:    string,
	at:      time.Tick,
	entries: [dynamic]Codex_Plugin_Entry,
}

@(private = "file")
cp: [dynamic]Home_Plugins // heap

// A folder name as listed: a plain word ("" = not one).
@(private = "file")
plain_name :: proc(s: string) -> string {
	if len(s) == 0 || len(s) > NAME_MAX || s[0] == '.' do return ""
	for ch in transmute([]u8)s {
		ok := ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9'
		switch ch {
		case '-', '_', '.', '+', '@': ok = true
		}
		if !ok do return ""
	}
	return s
}

// Whether path is a folder itself (lstat: a symlink is not one).
@(private = "file")
real_dir :: proc(path: string) -> bool {
	fi, err := os.lstat(path, context.temp_allocator)
	return err == nil && fi.type == .Directory
}

// The plain-named real folders in dir, sorted, at most n (temp). Only names: nothing is opened.
@(private = "file")
sub_dirs :: proc(dir: string, n: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if !real_dir(dir) do return out[:]
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return out[:]
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for e in entries {
		if len(out) >= n do break
		name := plain_name(e.name)
		if name == "" do continue
		if !real_dir(strings.concatenate({dir, "/", e.name}, context.temp_allocator)) do continue
		append(&out, name)
	}
	return out[:]
}

@(private = "file")
entries_free :: proc(list: ^[dynamic]Codex_Plugin_Entry) {
	heap := runtime.heap_allocator()
	for e in list {
		delete(e.name, heap)
		for v in e.versions do delete(v, heap)
		delete(e.versions, heap)
	}
	clear(list)
}

// The plugins installed in Codex home `home` (its folder names only; see the top). The slice and
// its strings are the cache's: valid until the next call.
codex_plugins_of :: proc(home: string) -> []Codex_Plugin_Entry {
	heap := runtime.heap_allocator()
	if cp == nil do cp = make([dynamic]Home_Plugins, heap)
	h: ^Home_Plugins
	for &x in cp do if x.home == home do h = &x
	if h == nil {
		append(&cp, Home_Plugins{home = strings.clone(home, heap), entries = make([dynamic]Codex_Plugin_Entry, heap)})
		h = &cp[len(cp) - 1]
	} else if h.at != {} && time.tick_since(h.at) < CODEX_PLUGINS_EVERY {
		return h.entries[:]
	}
	h.at = time.tick_now()
	entries_free(&h.entries)
	cache := strings.concatenate({home, "/plugins/cache"}, context.temp_allocator)
	if !real_dir(strings.concatenate({home, "/plugins"}, context.temp_allocator)) do return h.entries[:]
	for mk in sub_dirs(cache, MARKETPLACES_MAX) {
		mdir := strings.concatenate({cache, "/", mk}, context.temp_allocator)
		for pl in sub_dirs(mdir, LIST_MAX) {
			if len(h.entries) >= LIST_MAX do break
			vs := sub_dirs(strings.concatenate({mdir, "/", pl}, context.temp_allocator), VERSIONS_MAX)
			versions := make([]string, len(vs), heap)
			for v, i in vs do versions[i] = strings.clone(v, heap)
			append(&h.entries, Codex_Plugin_Entry{name = strings.concatenate({pl, "@", mk}, heap), versions = versions})
		}
	}
	slice.sort_by(h.entries[:], proc(a, b: Codex_Plugin_Entry) -> bool {return a.name < b.name})
	return h.entries[:]
}

// Drops the cache (tests; a home removed).
codex_plugins_forget :: proc() {
	for &h in cp {
		entries_free(&h.entries)
		delete(h.entries)
		delete(h.home, runtime.heap_allocator())
	}
	clear(&cp)
}

// A plugin row's detail: its versions ("version 1.2.0", "versions 1.0, 1.1"; none: "installed").
codex_plugin_detail :: proc(e: Codex_Plugin_Entry) -> string {
	switch len(e.versions) {
	case 0: return "installed"
	case 1: return strings.concatenate({"version ", e.versions[0]}, context.temp_allocator)
	}
	return strings.concatenate({"versions ", strings.join(e.versions, ", ", context.temp_allocator)}, context.temp_allocator)
}
