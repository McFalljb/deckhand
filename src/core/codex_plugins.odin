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
// digits and - _ . + @, not starting with '.', at most NAME_MAX) that does not look like a token
// (token_like); others are left out. Whether a plugin is turned on lives in config.toml (which
// may hold tokens): not read here.
//
// Bounded: a folder is read only up to CODEX_PLUGINS_SCAN entries (unsorted, as the system gives
// them; the ones kept are sorted). Walked again at most every CODEX_PLUGINS_EVERY per home, and
// then only when a folder it walked changed (their stamps, by lstat: a marketplace, plugin or
// version added or removed changes its parent's), on the caller's thread.

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

CODEX_PLUGINS_EVERY :: 2 * time.Second
CODEX_PLUGINS_SCAN :: 256 // entries read from one folder, at most
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

// A folder walked, as it was then (path heap).
@(private = "file")
Walked :: struct {
	path:  string,
	stamp: Disk_Stamp,
	kind:  Path_Kind,
}

@(private = "file")
Home_Plugins :: struct {
	home:    string,
	at:      time.Tick,
	walked:  [dynamic]Walked,
	entries: [dynamic]Codex_Plugin_Entry,
}

@(private = "file")
cp: [dynamic]Home_Plugins // heap

// How many walks, and entries read (the tests' look at the cap and the stamps).
codex_plugins_walks: int
codex_plugins_entries_read: int

// A folder name as listed: a plain word that does not look like a token ("" = not one).
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
	if token_like(s) do return ""
	return s
}

// A name that may be a secret rather than a name: a known token prefix (GitHub, OpenAI and
// Anthropic, Slack, GitLab, AWS), or a run of 32 or more letters and digits (base62 keys, 32+ hex).
@(private = "file")
token_like :: proc(s: string) -> bool {
	low := strings.to_lower(s, context.temp_allocator)
	for p in ([]string{"ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "sk-", "xox", "glpat-", "akia"}) do if strings.contains(low, p) do return true
	run := 0
	for ch in transmute([]u8)s {
		if ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' {
			run += 1
			if run >= 32 do return true
		} else do run = 0
	}
	return false
}

// path's stamp, by lstat (a symlink is not a folder).
@(private = "file")
stamp_of :: proc(path: string) -> (Disk_Stamp, Path_Kind) {
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil do return {}, .Missing
	kind: Path_Kind = fi.type == .Directory ? .Dir : .Other // a symlink, a file: not a folder here
	return {size = fi.size, mtime = time.to_unix_nanoseconds(fi.modification_time), inode = u64(fi.inode), dev = fi.device}, kind
}

// The plain-named real folders in dir, sorted, at most n, from at most CODEX_PLUGINS_SCAN of its
// entries (temp). Only names: nothing is opened. dir is noted as walked.
@(private = "file")
sub_dirs :: proc(h: ^Home_Plugins, dir: string, n: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	st, kind := stamp_of(dir)
	append(&h.walked, Walked{path = strings.clone(dir, runtime.heap_allocator()), stamp = st, kind = kind})
	if kind != .Dir do return out[:]
	entries, err := os.read_directory_by_path(dir, CODEX_PLUGINS_SCAN, context.temp_allocator)
	if err != nil do return out[:]
	codex_plugins_entries_read += len(entries)
	for e in entries {
		name := plain_name(e.name)
		if name == "" do continue
		if _, k := stamp_of(strings.concatenate({dir, "/", e.name}, context.temp_allocator)); k != .Dir do continue
		append(&out, name)
	}
	slice.sort(out[:])
	if len(out) > n do return out[:n]
	return out[:]
}

@(private = "file")
home_clear :: proc(h: ^Home_Plugins) {
	heap := runtime.heap_allocator()
	for e in h.entries {
		delete(e.name, heap)
		for v in e.versions do delete(v, heap)
		delete(e.versions, heap)
	}
	clear(&h.entries)
	for w in h.walked do delete(w.path, heap)
	clear(&h.walked)
}

// Whether a folder h walked changed since (its stamp or kind), or nothing was walked yet.
@(private = "file")
changed :: proc(h: ^Home_Plugins) -> bool {
	if len(h.walked) == 0 do return true
	for w in h.walked {
		st, kind := stamp_of(w.path)
		if st != w.stamp || kind != w.kind do return true
	}
	return false
}

// The plugins installed in Codex home `home` (its folder names only; see the top). The slice and
// its strings are the cache's: valid until the next call.
codex_plugins_of :: proc(home: string) -> []Codex_Plugin_Entry {
	heap := runtime.heap_allocator()
	if cp == nil do cp = make([dynamic]Home_Plugins, heap)
	h: ^Home_Plugins
	for &x in cp do if x.home == home do h = &x
	if h == nil {
		append(&cp, Home_Plugins{home = strings.clone(home, heap), walked = make([dynamic]Walked, heap), entries = make([dynamic]Codex_Plugin_Entry, heap)})
		h = &cp[len(cp) - 1]
	} else if h.at != {} && time.tick_since(h.at) < CODEX_PLUGINS_EVERY {
		return h.entries[:]
	}
	h.at = time.tick_now()
	if !changed(h) do return h.entries[:]
	home_clear(h)
	codex_plugins_walks += 1
	// plugins/ itself first: a symlink there and nothing under it is looked at
	plugins := strings.concatenate({home, "/plugins"}, context.temp_allocator)
	st, kind := stamp_of(plugins)
	append(&h.walked, Walked{path = strings.clone(plugins, heap), stamp = st, kind = kind})
	if kind != .Dir do return h.entries[:]
	cache := strings.concatenate({plugins, "/cache"}, context.temp_allocator)
	for mk in sub_dirs(h, cache, MARKETPLACES_MAX) {
		if len(h.entries) >= LIST_MAX do break
		mdir := strings.concatenate({cache, "/", mk}, context.temp_allocator)
		for pl in sub_dirs(h, mdir, LIST_MAX - len(h.entries)) {
			vs := sub_dirs(h, strings.concatenate({mdir, "/", pl}, context.temp_allocator), VERSIONS_MAX)
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
		home_clear(&h)
		delete(h.entries)
		delete(h.walked)
		delete(h.home, runtime.heap_allocator())
	}
	clear(&cp)
}

when TEST_HOOKS {
	// The throttle passed (tests): the next call looks at the stamps.
	codex_plugins_expire :: proc() {
		for &h in cp do h.at = {}
	}
}

// A plugin row's detail: its versions ("version 1.2.0", "versions 1.0, 1.1"; none: "installed").
codex_plugin_detail :: proc(e: Codex_Plugin_Entry) -> string {
	switch len(e.versions) {
	case 0: return "installed"
	case 1: return strings.concatenate({"version ", e.versions[0]}, context.temp_allocator)
	}
	return strings.concatenate({"versions ", strings.join(e.versions, ", ", context.temp_allocator)}, context.temp_allocator)
}
