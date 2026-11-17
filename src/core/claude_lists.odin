package core

// What Settings lists of Claude Code's plugins and user MCP servers, by name only (Settings →
// Coding agents → Claude Code: Plugins, MCP servers (user); docs/CLAUDE.md §1c).
//
// Both live where Settings shows no file: plugins are turned on and off in the account's
// settings.json (`enabledPlugins`, the plugin id → true or false; the plugins themselves are in
// <config>/plugins/, which is Claude Code's state and never listed), and the user-scope MCP
// servers in Claude Code's account file (`mcpServers` of ~/.claude.json, or <config>/.claude.json
// for an account whose folder is CLAUDE_CONFIG_DIR), which also holds its account state: it stays
// a credential file (claude_credential), never listed, opened, watched or given to an agent.
//
// From that file Deckhand keeps only the server names under its top-level `mcpServers` and each
// one's `type` (a short word: stdio, http, sse…; none: stdio when it has a command). Never a
// value: no command, args, env, headers or URL, and no other key of the file (projects' servers,
// the account, history). Nothing read is logged or stored on disk.
//
// Read on a worker (claude_lists_want: at most every CLAUDE_LISTS_EVERY while the rows are
// built), and only again once a file's stamp (time, size, inode) changed; the rows come from the
// cache. claude_lists_tick (settings_poll) tells the page when the worker found something new.

import "base:runtime"
import "core:encoding/json"
import jg "../jsonguard"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

CLAUDE_LISTS_EVERY :: 2 * time.Second
@(private = "file")
SETTINGS_MAX :: 4 << 20 // a settings.json larger than this is not looked into
@(private = "file")
ACCOUNT_FILE_MAX :: 64 << 20 // nor an account file larger than this
@(private = "file")
NAME_MAX :: 100 // a plugin id or server name, as shown
@(private = "file")
LIST_MAX :: 200 // entries listed per account and kind

Claude_Plugin_Entry :: struct {
	id:      string,
	enabled: bool,
}

Claude_Mcp_Entry :: struct {
	name, transport: string, // transport: "" = not said
}

// One account's lists (heap, under cl.mu).
@(private = "file")
Lists :: struct {
	dir:           string,
	settings:      Disk_Stamp,
	settings_kind: Path_Kind,
	settings_seen: bool,
	plugins:       [dynamic]Claude_Plugin_Entry,
	account:       Disk_Stamp,
	account_kind:  Path_Kind,
	account_seen:  bool,
	mcp:           [dynamic]Claude_Mcp_Entry,
}

@(private = "file")
cl: struct {
	mu:      sync.Mutex, // lists, changed
	run_mu:  sync.Mutex, // one refresh at a time
	lists:   [dynamic]Lists,
	changed: bool, // the worker changed a list since the last tick
	running: bool, // atomic: a worker is out
	last:    time.Tick,
}

// The account file of the Claude Code config folder dir: ~/.claude.json for ~/.claude (Claude
// Code runs it without CLAUDE_CONFIG_DIR), else <dir>/.claude.json. Temp.
claude_account_file :: proc(dir: string) -> string {
	if dir == claude_home_config() {
		h := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
		if h == "" do return ""
		return strings.concatenate({h, "/.claude.json"}, context.temp_allocator)
	}
	return strings.concatenate({dir, "/.claude.json"}, context.temp_allocator)
}

// Asks the worker to look again (at most every CLAUDE_LISTS_EVERY; never while one is out). The
// accounts' folders are named here, on the caller's thread.
claude_lists_want :: proc() {
	if sync.atomic_load(&cl.running) do return
	if cl.last != {} && time.tick_since(cl.last) < CLAUDE_LISTS_EVERY do return
	dirs := claude_lists_dirs()
	if len(dirs) == 0 do return
	cl.last = time.tick_now()
	sync.atomic_store(&cl.running, true)
	heap := runtime.heap_allocator()
	jobs := make([]Lists_Job, len(dirs), heap)
	for d, i in dirs do jobs[i] = {dir = strings.clone(d, heap), account = strings.clone(claude_account_file(d), heap)}
	thread.create_and_start_with_poly_data(jobs, proc(jobs: []Lists_Job) {
		lists_refresh(jobs)
		lists_jobs_free(jobs)
		sync.atomic_store(&cl.running, false)
		if platform.wake != nil do platform.wake()
	}, runtime.default_context(), self_cleanup = true)
}

// The same, now, on this thread (tests; a page that must show the lists at once).
claude_lists_refresh_now :: proc() {
	dirs := claude_lists_dirs()
	heap := runtime.heap_allocator()
	jobs := make([]Lists_Job, len(dirs), heap)
	for d, i in dirs do jobs[i] = {dir = strings.clone(d, heap), account = strings.clone(claude_account_file(d), heap)}
	lists_refresh(jobs)
	lists_jobs_free(jobs)
	cl.last = time.tick_now()
}

// Main thread (settings_poll): true once when the worker changed a list since the last call.
claude_lists_tick :: proc() -> bool {
	sync.lock(&cl.mu)
	defer sync.unlock(&cl.mu)
	c := cl.changed
	cl.changed = false
	return c
}

// An account's lists now (temp copies; ok false: not read yet).
claude_lists_of :: proc(dir: string) -> (plugins: []Claude_Plugin_Entry, mcp: []Claude_Mcp_Entry, ok: bool) {
	sync.lock(&cl.mu)
	defer sync.unlock(&cl.mu)
	for &l in cl.lists do if l.dir == dir {
		p := make([]Claude_Plugin_Entry, len(l.plugins), context.temp_allocator)
		for x, i in l.plugins do p[i] = {strings.clone(x.id, context.temp_allocator), x.enabled}
		m := make([]Claude_Mcp_Entry, len(l.mcp), context.temp_allocator)
		for x, i in l.mcp do m[i] = {strings.clone(x.name, context.temp_allocator), strings.clone(x.transport, context.temp_allocator)}
		return p, m, l.settings_seen || l.account_seen
	}
	return nil, nil, false
}

// Forgets every list (tests).
claude_lists_reset :: proc() {
	sync.lock(&cl.run_mu)
	defer sync.unlock(&cl.run_mu)
	sync.lock(&cl.mu)
	defer sync.unlock(&cl.mu)
	for &l in cl.lists do lists_free(&l)
	delete(cl.lists)
	cl.lists = {}
	cl.changed = false
	cl.last = {}
}

// The accounts' folders that are there (temp).
@(private = "file")
claude_lists_dirs :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for a in claude_accounts() do if os.is_dir(a.dir) do append(&out, a.dir)
	return out[:]
}

@(private = "file")
Lists_Job :: struct {
	dir, account: string, // heap
}

@(private = "file")
lists_jobs_free :: proc(jobs: []Lists_Job) {
	heap := runtime.heap_allocator()
	for j in jobs {
		delete(j.dir, heap)
		delete(j.account, heap)
	}
	delete(jobs, heap)
}

@(private = "file")
lists_free :: proc(l: ^Lists) {
	heap := runtime.heap_allocator()
	delete(l.dir, heap)
	for x in l.plugins do delete(x.id, heap)
	delete(l.plugins)
	for x in l.mcp {
		delete(x.name, heap)
		delete(x.transport, heap)
	}
	delete(l.mcp)
}

// Each account: its settings.json and account file read again when their stamp changed. Reads
// and parses in an arena of its own (any thread), then swaps the results in under cl.mu.
@(private = "file")
lists_refresh :: proc(jobs: []Lists_Job) {
	sync.lock(&cl.run_mu)
	defer sync.unlock(&cl.run_mu)
	heap := runtime.heap_allocator()
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	for j in jobs {
		// what is known of it (stamps only: read under the lock)
		known: Lists
		sync.lock(&cl.mu)
		for &l in cl.lists do if l.dir == j.dir do known = l
		sync.unlock(&cl.mu)
		sp := strings.concatenate({j.dir, "/settings.json"}, context.temp_allocator)
		sk, sst := path_stat(sp)
		ak, ast := path_stat(j.account)
		same :: proc(k: Path_Kind, st: Disk_Stamp, kk: Path_Kind, kst: Disk_Stamp, seen: bool) -> bool {
			return seen && k == kk && st.mtime == kst.mtime && st.size == kst.size && st.inode == kst.inode
		}
		new_plugins := !same(sk, sst, known.settings_kind, known.settings, known.settings_seen)
		new_mcp := !same(ak, ast, known.account_kind, known.account, known.account_seen)
		if !new_plugins && !new_mcp do continue
		plugins: []Claude_Plugin_Entry
		mcp: []Claude_Mcp_Entry
		if new_plugins do plugins = sk == .File && sst.size <= SETTINGS_MAX ? read_plugins(sp) : nil
		if new_mcp do mcp = ak == .File && ast.size <= ACCOUNT_FILE_MAX ? read_mcp(j.account) : nil
		sync.lock(&cl.mu)
		idx := -1
		for l, i in cl.lists do if l.dir == j.dir do idx = i
		if idx < 0 {
			append(&cl.lists, Lists{dir = strings.clone(j.dir, heap)})
			idx = len(cl.lists) - 1
		}
		l := &cl.lists[idx]
		if new_plugins {
			for x in l.plugins do delete(x.id, heap)
			clear(&l.plugins)
			for x in plugins do append(&l.plugins, Claude_Plugin_Entry{strings.clone(x.id, heap), x.enabled})
			l.settings, l.settings_kind, l.settings_seen = sst, sk, true
		}
		if new_mcp {
			for x in l.mcp {
				delete(x.name, heap)
				delete(x.transport, heap)
			}
			clear(&l.mcp)
			for x in mcp do append(&l.mcp, Claude_Mcp_Entry{strings.clone(x.name, heap), strings.clone(x.transport, heap)})
			l.account, l.account_kind, l.account_seen = ast, ak, true
		}
		cl.changed = true
		sync.unlock(&cl.mu)
		virtual.arena_free_all(&arena)
	}
}

// A plugin id or server name as shown: control characters dropped, at most NAME_MAX bytes (on a
// character boundary). Temp.
@(private = "file")
shown_name :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0xfffd do continue
		if strings.builder_len(b) + utf8.rune_size(r) > NAME_MAX do break
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// enabledPlugins of a settings.json: each plugin id and whether it is on, sorted (temp). An entry
// whose value is not true or false is left out (Claude Code reads only those).
@(private = "file")
read_plugins :: proc(path: string) -> []Claude_Plugin_Entry {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil
	v, jerr := jg.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return nil
	root, is := v.(json.Object)
	if !is do return nil
	ep, eis := root["enabledPlugins"].(json.Object)
	if !eis do return nil
	out := make([dynamic]Claude_Plugin_Entry, context.temp_allocator)
	for id, val in ep {
		on, bis := val.(json.Boolean)
		if !bis do continue
		name := shown_name(id)
		if name == "" do continue
		append(&out, Claude_Plugin_Entry{name, bool(on)})
	}
	slice.sort_by(out[:], proc(a, b: Claude_Plugin_Entry) -> bool {return a.id < b.id})
	return out[:min(len(out), LIST_MAX)]
}

// The user-scope MCP servers of an account file: each name under its top-level mcpServers and
// its type (temp, sorted). Read member by member (json_members_raw); only the names and a type
// that is a short word are kept.
@(private = "file")
read_mcp :: proc(path: string) -> []Claude_Mcp_Entry {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil
	top, ok := json_members_raw(strings.trim_space(string(data)))
	if !ok do return nil
	servers := ""
	for m in top do if m.key == "mcpServers" do servers = m.raw
	if servers == "" do return nil
	list, lok := json_members_raw(servers)
	if !lok do return nil
	out := make([dynamic]Claude_Mcp_Entry, context.temp_allocator)
	for s in list {
		name := shown_name(s.key)
		if name == "" do continue
		fields, fok := json_members_raw(s.raw)
		if !fok do continue // not an object: not a server
		transport, command := "", false
		for f in fields {
			switch f.key {
			case "type": transport = transport_word(f.raw)
			case "command": command = true
			}
		}
		if transport == "" && command do transport = "stdio" // Claude Code's default
		append(&out, Claude_Mcp_Entry{name, transport})
	}
	slice.sort_by(out[:], proc(a, b: Claude_Mcp_Entry) -> bool {return a.name < b.name})
	return out[:min(len(out), LIST_MAX)]
}

// A type's raw JSON as a word: a string of 1-16 letters, digits, '-' or '_' ("" otherwise).
@(private = "file")
transport_word :: proc(raw: string) -> string {
	if len(raw) < 3 || len(raw) > 18 || raw[0] != '"' || raw[len(raw) - 1] != '"' do return ""
	w := raw[1:len(raw) - 1]
	for c in transmute([]u8)w do if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') do return ""
	return strings.to_lower(w, context.temp_allocator)
}
