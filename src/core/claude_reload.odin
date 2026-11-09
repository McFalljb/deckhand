package core

// Hot reload and version drift for Claude tabs: reload.odin's parity for Claude Code.
//
// Claude Code applies most of its configuration to a running session by itself (its docs,
// "When edits take effect"): settings files (user, project, local; permissions, hooks, env),
// keybindings.json, skills and subagents in folders that existed when it started. Those are
// never watched here: no bar for them. What a running session reads only when it starts:
//
//   instructions  CLAUDE.md and CLAUDE.local.md in the cwd and every folder above it (and
//                 .claude/CLAUDE.md), and the config folder's CLAUDE.md
//   rules, output styles, commands   <config>/{rules,output-styles,commands}/ and the cwd's
//                 .claude/{rules,output-styles,commands}/
//   MCP servers   the cwd's .mcp.json
//   new folders   <config>/{agents,skills}/ and the cwd's .claude/{agents,skills}/ when they
//                 appear (Claude Code watches only folders that existed at its start)
//   the plugin    Deckhand's own plugin (--plugin-dir): its manifest, hooks, skill, bin
//
// There is no /reload for those: the bar offers Restart (claude_restart_changed), the same
// conversation again with --resume <its session id> in the same tab, as the dead tab's
// Restart does (dead_tab.odin). A tab restarts only when idle: its turn idle per the hooks and
// per OSC 7501, nothing typed or held, no subagent running; busy ones wait; a tab that never
// reported its session id (no --resume possible) is left alone. Restarting stops what Claude
// runs in the background (background shells, monitors), which Deckhand sees only as of Claude's
// last turn (claude_panels.odin): the user always confirms, and the confirmation names them. Only the user's own restart replays the tab's saved flags (CLAUDE.md §3).
//
// Claude Code's version: `claude` is found as the tab's command finds it (the children's
// PATH, ~/.local/bin, ~/.claude/local; DECKHAND_CLAUDE_BIN in tests; none while
// DECKHAND_CLAUDE_CMD replaces claude) and its version read from where it links to, by stat and
// readlink only: never run (native install: .../versions/<v>; Homebrew: Caskroom/claude-code/<v>;
// npm: the package's package.json). An unknown layout: the file's identity (inode, time,
// size). Each Claude tab records it when first seen running (Tab.reload.version); another one
// on disk shows "Claude Code updated to X — Restart N idle Claude tabs".
//
// Never read, watched or listed: credentials, account state, transcripts, caches
// (claude_credential: .credentials.json, .claude.json, everything in the config folder but its
// config files). Only file times and sizes are looked at, never contents (an npm install's
// package.json excepted, for its version).

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

CLAUDE_RELOAD_FOLDER_MAX :: 256 // entries a watched folder's digest looks at
CLAUDE_FIND_EVERY :: 10 * time.Second // claude looked for again (PATH may change)

Claude_File_Class :: enum u8 {
	Ignored, // not Claude Code's, or never looked at (credentials, state)
	Live, // Claude Code applies it to a running session itself
	Restart, // a running session reads it only at start
}

// The Claude bars' model (State.reload.claude). Changed by commands only.
Claude_Reload_Info :: struct {
	gen:              u64, // bumped by every reported change
	changed:          [dynamic]string, // files changed (Details), at most RELOAD_CHANGED_MAX
	changed_more:     int,
	from_save:        bool, // an editor save: the bar shows even with nothing to restart
	dismissed:        bool, // Later: the settings bar hides until the next change
	version:          string, // claude's version on disk ("" = unknown; may be "a new build")
	ident:            string, // what identifies it (the version, or "build:…"); "" = unknown
	update_dismissed: bool, // Later on the update bar: until the next version
}

// claude_restart_changed: restart the running Claude tabs a changed file needs it for (update:
// those on an older claude; all: every one, changed or not); idle ones now, busy ones once idle.
Claude_Restart_Changed :: struct {
	update:  bool,
	all:     bool,
	confirm: string, // class session_restart
}
// claude_reload_later: hide the bar (update: the update bar), drop waiting restarts.
Claude_Reload_Later :: struct {
	update: bool,
}
// Internal: watched Claude files changed (after the debounce), or claude's version on disk is
// known or changed. Scopes as Reload_Watch's ("" every Claude tab, else a folder).
Claude_Reload_Watch :: struct {
	paths:     []string,
	more:      int,
	scopes:    []string,
	version:   string, // "" = unchanged
	ident:     string,
	from_save: bool,
}
// Internal: a Claude tab whose restart waited for idle restarts now, if still idle.
Claude_Reload_Kick :: struct {
	tab_id: u64,
}

// ---- where Claude Code keeps things ----

// CLAUDE_CONFIG_DIR as Claude tabs get it (the children's environment), else this process's.
@(private = "file")
config_env :: proc() -> string {
	if login_env.children != nil {
		v, _ := env_lookup(login_env.children, "CLAUDE_CONFIG_DIR")
		return v
	}
	return os.get_env("CLAUDE_CONFIG_DIR", context.temp_allocator)
}

// Claude Code's config folder: CLAUDE_CONFIG_DIR when absolute, else ~/.claude. Temp-allocated.
claude_config_dir :: proc() -> string {
	if v := config_env(); filepath.is_abs(v) {
		c, _ := filepath.clean(v, context.temp_allocator)
		return c
	}
	h := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	if h == "" do return ""
	return strings.concatenate({h, "/.claude"}, context.temp_allocator)
}

// The config folder's files a user edits (anything else at its top is Claude Code's state).
@(private = "file")
CONFIG_FILES :: [?]string{"settings.json", "settings.local.json", "CLAUDE.md", "keybindings.json"}
// Its folders of the user's own config (skills, subagents, commands…); open in the editor.
CLAUDE_CONFIG_FOLDERS :: [?]string{"agents", "skills", "commands", "output-styles", "rules", "hooks", "themes", "workflows"}

@(private = "file")
under :: proc(p, dir: string) -> bool {return dir != "" && len(p) > len(dir) && strings.has_prefix(p, dir) && p[len(dir)] == '/'}

// A Claude Code file Deckhand never lists, reads, watches or opens: its credentials
// (.credentials.json), its account and MCP state (.claude.json and its backups, wherever they
// are), and everything in a Claude config folder but the user's config (CONFIG_FILES and
// CLAUDE_CONFIG_FOLDERS): transcripts (projects/), history, sessions, file history, caches,
// plugins' data, and whatever a newer Claude Code adds there. Config folders: every one of
// claude_config_dirs (~/.claude and CLAUDE_CONFIG_DIR, each also where it links to), and any
// folder that directly holds a .credentials.json or .claude.json (another profile's). A folder
// that is HOME or above it (by any name) is never one: the names only (never all of HOME).
// p: clean and absolute (settings_credential also checks where it links to, and hard links by
// inode).
claude_credential :: proc(p: string) -> bool {
	base := filepath.base(p)
	if base == ".credentials.json" || base == ".claude.json" || strings.has_prefix(base, ".claude.json.") do return true
	home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	homes := [2]string{home, fs_real(home)}
	home_or_above :: proc(d: string, homes: [2]string) -> bool {
		if d == "" || d == "/" do return true
		for h in homes do if h != "" && (d == h || under(h, d)) do return true
		return false
	}
	for cfg in claude_config_dirs() {
		for c in ([2]string{cfg, fs_real(cfg)}) {
			if home_or_above(c, homes) || !under(p, c) do continue
			return !claude_config_entry(p, c)
		}
	}
	// any other folder holding Claude's sign-in or account file is a config folder too (not a
	// user's home folder: ~/.claude.json lives there without CLAUDE_CONFIG_DIR)
	for d := filepath.dir(p); !home_or_above(d, homes); d = filepath.dir(d) {
		if user_home(d) do continue
		if claude_marked(d) do return !claude_config_entry(p, d)
	}
	return false
}

// The config folders Deckhand guards, whichever CLAUDE_CONFIG_DIR names now: ~/.claude and
// CLAUDE_CONFIG_DIR (claude_config_dir; a relative one is not Claude's and is ignored).
// Temp-allocated.
claude_config_dirs :: proc() -> []string {
	// and every account's folder, found or added, also removed ones (claude_accounts.odin)
	return claude_account_dirs()
}

// Whether p (under the config folder c) is the user's config: a CONFIG_FILES file at its top,
// or anything in a CLAUDE_CONFIG_FOLDERS folder.
@(private = "file")
claude_config_entry :: proc(p, c: string) -> bool {
	first, _, rest := strings.partition(p[len(c) + 1:], "/")
	for f in CLAUDE_CONFIG_FOLDERS do if first == f do return true
	if rest == "" do for f in CONFIG_FILES do if first == f do return true
	return false
}

// Whether d is a user's home folder (another user's, or this one's when HOME is elsewhere).
@(private = "file")
user_home :: proc(d: string) -> bool {
	parent := filepath.dir(d)
	return parent == "/Users" || parent == "/home" || d == "/root" || d == "/var/root"
}

// Whether folder d directly holds Claude's sign-in or account file (stat only, never read);
// remembered for a second (a tree or a changes list asks for many paths at once).
@(private = "file")
marks: map[string]bool
@(private = "file")
marks_at: time.Tick
@(private = "file")
claude_marked :: proc(d: string) -> bool {
	if marks_at == {} || time.tick_since(marks_at) > time.Second {
		for k in marks do delete(k, runtime.heap_allocator())
		clear(&marks)
		marks_at = time.tick_now()
	}
	if v, ok := marks[d]; ok do return v
	v := false
	for f in ([2]string{".credentials.json", ".claude.json"}) {
		if k, _ := path_stat(strings.concatenate({d, "/", f}, context.temp_allocator)); k == .File do v = true
	}
	if marks == nil do marks = make(map[string]bool, runtime.heap_allocator())
	if len(marks) < 4096 do marks[strings.clone(d, runtime.heap_allocator())] = v
	return v
}

// The files of Claude Code's whose other names (hard links) are refused too (credential_ids).
claude_credential_files :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for cfg in claude_config_dirs() do append(&out, strings.concatenate({cfg, "/.credentials.json"}, context.temp_allocator), strings.concatenate({cfg, "/.claude.json"}, context.temp_allocator))
	if h := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/"); h != "" do append(&out, strings.concatenate({h, "/.claude.json"}, context.temp_allocator))
	return out[:]
}

// Whether a running Claude session picks up a change of path by itself, needs a restart, or
// Deckhand ignores it (see the top of the file).
claude_file_class :: proc(path: string) -> Claude_File_Class {
	if path == "" || !filepath.is_abs(path) do return .Ignored
	p, _ := filepath.clean(path, context.temp_allocator)
	if settings_credential(p) do return .Ignored // Claude's state and credentials too (claude_credential)
	if plugin := claude_plugin_dir(); plugin != "" && (under(p, plugin) || under(p, fs_real(plugin))) do return .Restart
	switch filepath.base(p) {
	case "CLAUDE.md", "CLAUDE.local.md", ".mcp.json": return .Restart
	}
	rel := ""
	for cfg in claude_account_dirs() do if under(p, cfg) {
		rel = p[len(cfg) + 1:]
		break
	}
	if rel == "" do if i := strings.last_index(p, "/.claude/"); i >= 0 do rel = p[i + len("/.claude/"):]
	if rel == "" do return .Ignored
	first, _, rest := strings.partition(rel, "/")
	switch first {
	case "settings.json", "settings.local.json", "keybindings.json":
		if rest == "" do return .Live
	case "skills", "agents":
		if rest != "" do return .Live
	case "rules", "output-styles", "commands":
		if rest != "" do return .Restart
	}
	return .Ignored
}

// ---- claude's version, by looking only ----

// Tests: the binary to look at instead of searching (DECKHAND_CLAUDE_BIN).
// The `claude` a Claude tab would start ("" = none found, or tests replace claude): the
// children's PATH, then ~/.local/bin and ~/.claude/local, as CLAUDE_TAB_CMD looks. Stat only.
claude_binary_path :: proc() -> string {
	if b := hook_env(.Claude_Bin); filepath.is_abs(b) do return b
	if hook_env(.Claude_Cmd) != "" do return ""
	dirs := make([dynamic]string, context.temp_allocator)
	if path, ok := env_lookup(child_base_env(), "PATH"); ok do for d in strings.split(path, ":", context.temp_allocator) do append(&dirs, d)
	if h := os.get_env("HOME", context.temp_allocator); strings.has_prefix(h, "/") {
		h = strings.trim_right(h, "/")
		append(&dirs, fmt.tprintf("%s/.local/bin", h), fmt.tprintf("%s/.claude/local", h))
	}
	for d in dirs {
		if !strings.has_prefix(d, "/") do continue
		p := fmt.tprintf("%s/claude", strings.trim_right(d, "/"))
		if path_kind(p) == .File do return p
	}
	return ""
}

// claude's version from where bin links to (never run): the native installer, Homebrew's cask, npm
// (bun and mise's npm backend too), nix's store, mise's installs, a pnpm or nix wrapper script's
// target; label "" when the layout does not say;
// ident is the version, or for an unknown layout its file's identity ("build:…"); both "" when
// bin is missing.
claude_version_of :: proc(bin: string) -> (label, ident: string) {
	real := fs_real(bin)
	k, st := path_stat(real != "" ? real : bin)
	if k != .File do return "", ""
	if real == "" do real = bin
	ok_version :: proc(v: string) -> bool {
		if v == "" || len(v) > 40 || v[0] < '0' || v[0] > '9' do return false
		for c in v do if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '.' || c == '-' || c == '+' || c == '_') do return false
		return true
	}
	// native installer: .../claude/versions/<version>
	if i := strings.last_index(real, "/versions/"); i >= 0 {
		v, _, _ := strings.partition(real[i + len("/versions/"):], "/")
		if ok_version(v) do return v, v
	}
	// Homebrew cask: .../Caskroom/claude-code/<version>/claude (or the claude-code@latest cask's)
	for cask in ([]string{"/Caskroom/claude-code/", "/Caskroom/claude-code@latest/"}) {
		if i := strings.last_index(real, cask); i >= 0 {
			v, _, _ := strings.partition(real[i + len(cask):], "/")
			if ok_version(v) do return v, v
		}
	}
	// npm, bun, mise's npm backend: .../node_modules/@anthropic-ai/claude-code/<entry>: its package.json
	if i := strings.last_index(real, "/@anthropic-ai/claude-code/"); i >= 0 {
		pj := fmt.tprintf("%s/package.json", real[:i + len("/@anthropic-ai/claude-code")])
		if v := pkg_version(pj); ok_version(v) do return v, v
	}
	// nix: /nix/store/<hash>-claude-code-<version>/… (a profile's bin/claude links there)
	if i := strings.last_index(real, "/nix/store/"); i >= 0 {
		seg, _, _ := strings.partition(real[i + len("/nix/store/"):], "/")
		if _, dash, rest := strings.partition(seg, "-"); dash != "" && strings.has_prefix(rest, "claude-code-") {
			if v := rest[len("claude-code-"):]; ok_version(v) do return v, v
		}
	}
	// mise: …/mise/installs/<tool with claude-code in its name>/<version>/…
	if i := strings.last_index(real, "/mise/installs/"); i >= 0 {
		tool, _, rest := strings.partition(real[i + len("/mise/installs/"):], "/")
		v, _, _ := strings.partition(rest, "/")
		if strings.contains(tool, "claude-code") && ok_version(v) do return v, v
	}
	// a wrapper or shim script (pnpm's, nix's makeWrapper) naming the npm package: its package.json
	if pkg := script_target(real, "node_modules/@anthropic-ai/claude-code"); pkg != "" {
		if v := pkg_version(fmt.tprintf("%s/package.json", pkg)); ok_version(v) do return v, v
	}
	return "", fmt.tprintf("build:%d:%d:%d", st.inode, st.mtime, st.size)
}

// The bar's word for a version: "2.1.301", or "a new build" for an unknown layout.
claude_version_label :: proc(v: string) -> string {
	if v == "" || strings.has_prefix(v, "build:") do return "a new build"
	return v
}

// Whether a Claude tab started with another claude than the one on disk.
claude_reload_outdated :: proc(t: ^Tab) -> bool {
	v := state.reload.claude.ident
	return v != "" && t.reload.version != "" && t.reload.version != v
}

// ---- which tabs can restart now ----

// How a Claude tab can take a restart now: Idle (turn idle per the hooks and OSC 7501, nothing
// typed or held, no subagent running), Busy, Blocked (a subagent runs), No_Bridge (it never
// reported its session id: --resume is not possible).
claude_restart_class :: proc(t: ^Tab) -> Reload_Class {
	if replica_process do return t.live.claude_restart // the core's (Tab_Live)
	ct, is := &t.kind.(Claude_Tab)
	if !is do return .No_Bridge
	if ct.session_id == "" do return .No_Bridge
	if ct.turn != .Idle do return .Busy // starting, working, or a dialog
	if v := tab_status_view(t^); v.source == .Osc7501 && (v.state == .Working || v.state == .Blocked) do return .Busy
	if claude_typed(t.id) || len(ct.held) > 0 do return .Busy
	if claude_subagents_running(t.id) > 0 do return .Blocked
	return .Idle
}

// Why a busy Claude tab waits, for Details and notes.
@(private = "file")
busy_why :: proc(t: ^Tab) -> string {
	ct, _ := t.kind.(Claude_Tab)
	switch {
	case ct.turn == .Waiting:                      return "waiting for you"
	case ct.turn == .Unknown:                      return "starting"
	case claude_typed(t.id):                       return "you are typing"
	case len(ct.held) > 0:                         return "a message waits for it"
	case claude_subagents_running(t.id) > 0:       return "a subagent runs"
	}
	return "working"
}

@(private = "file")
tab_cwd :: proc(s: ^Open_Session, t: ^Tab) -> string {return t.cwd != "" ? t.cwd : s.cwd}

// A scope for one account's config folder: only its tabs read those files. "" (every tab) while
// the running tabs all have one account, as before accounts.
@(private = "file")
ACCOUNT_SCOPE :: "account:"
@(private = "file")
account_scope :: proc(cfg: string) -> string {
	if len(accounts_now()) <= 1 do return ""
	return strings.concatenate({ACCOUNT_SCOPE, cfg}, context.temp_allocator)
}

// The account folders of the running Claude tabs, sorted (temp).
@(private = "file")
accounts_now :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for x in running_claude() {
		ct := x.t.kind.(Claude_Tab)
		d := claude_account_dir(ct.account)
		if d != "" && !slice.contains(out[:], d) do append(&out, d)
	}
	slice.sort(out[:])
	return out[:]
}

// Whether a Claude tab at cwd reads files of scope ("" every tab, an account's scope: its tabs,
// else a folder: at or below).
@(private = "file")
in_scope_tab :: proc(t: ^Tab, cwd, scope: string) -> bool {
	if strings.has_prefix(scope, ACCOUNT_SCOPE) {
		ct, _ := t.kind.(Claude_Tab)
		return claude_account_dir(ct.account) == scope[len(ACCOUNT_SCOPE):]
	}
	return in_scope(cwd, scope)
}

@(private = "file")
in_scope :: proc(cwd, scope: string) -> bool {
	if scope == "" do return true
	at :: proc(p, d: string) -> bool {
		if p == "" do return false
		return p == d || d == "/" || under(p, d)
	}
	return at(cwd, scope) || at(fs_real(cwd), scope)
}

@(private = "file")
set_version :: proc(t: ^Tab, v: string) {
	if t.reload.version == v do return
	window_state_changed() // also from ticks, outside commands
	delete(t.reload.version)
	t.reload.version = strings.clone(v)
}

@(private = "file")
set_note :: proc(t: ^Tab, note: string) {
	if t.reload.note != note do window_state_changed() // also from ticks, outside commands
	delete(t.reload.note)
	t.reload.note = strings.clone(cut_utf8(one_line(note, context.temp_allocator), RELOAD_NOTE_MAX))
}

// The running Claude tabs (not Home's: it has none), with their sessions (also the palette's
// restart actions: actions.odin).
Claude_Running :: struct {
	s: ^Open_Session,
	t: ^Tab,
}
running_claude :: proc() -> []Claude_Running {
	out := make([dynamic]Claude_Running, context.temp_allocator)
	for &s in state.open_sessions {
		if s.home do continue
		for &t in s.tabs {
			if _, is := t.kind.(Claude_Tab); is && t.status == .Running do append(&out, Claude_Running{&s, &t})
		}
	}
	return out[:]
}

// Stops a running Claude tab and starts it again on its conversation once the old process is
// gone (dead_tab.odin's restart wait: --resume <its session id>, a new token; flags: the
// user's saved flags). The caller checked it is idle.
@(private = "file")
restart_now :: proc(t: ^Tab, flags: bool) {
	pid: i32
	if tm := term_of(t.id); tm != nil do pid = tm.pty.pid
	drop_term(t.id)
	forget_confirmations_for(t.id)
	socket_forget_tab(t.id)
	tab_clear_panels(t)
	claude_tab_gone(t)
	prog_summary_free(&t.prog)
	t.status, t.exit = .Exited, {}
	t.reload.queued, t.reload.flags, t.reload.stale, t.reload.all = .None, false, false, false
	t.reload.started = false // the new process records the version it starts with
	set_note(t, "restarting")
	append(&restart_waits, Restart_Wait{tab = t.id, pid = pid, since = time.tick_now(), claude = true, flags = flags})
}

@(private = "file")
ids_json :: proc(b: ^strings.Builder, name: string, tabs: []^Tab, first := false) {
	if !first do strings.write_byte(b, ',')
	fmt.sbprintf(b, `"%s":[`, name)
	for t, i in tabs {
		if i > 0 do strings.write_byte(b, ',')
		fmt.sbprintf(b, "%d", t.id)
	}
	strings.write_byte(b, ']')
}

// ---- commands ----

claude_reload_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	info := &state.reload.claude
	#partial switch c in cmd {
	case Claude_Restart_Changed:
		now := make([dynamic]^Tab, context.temp_allocator)
		later := make([dynamic]^Tab, context.temp_allocator)
		cut := make([dynamic]^Tab, context.temp_allocator)
		// confirmed (the user's Confirm resends it as the user's): still the asker's restart
		asker := caller
		if c.confirm != "" do for p in state.pending_confirmations {
			if _, is := p.command.(Claude_Restart_Changed); is && p.token == c.confirm do asker = p.caller
		}
		for x in running_claude() {
			t := x.t
			if owns_tab(asker, t.id) || restart_waiting(t.id) do continue
			if !c.all && (c.update ? !claude_reload_outdated(t) : !t.reload.stale) do continue
			switch claude_restart_class(t) {
			case .Idle:           append(&now, t)
			case .Busy, .Blocked: append(&later, t)
			case .No_Bridge:      append(&cut, t)
			}
		}
		if len(now) + len(later) == 0 {
			if len(cut) > 0 do return fail("no Claude tab here has reported its conversation (its plugin's hooks did not run): restart it by hand"), false
			if c.all do return fail("no Claude tab is running"), false
			return fail(c.update ? "no Claude tab runs an older Claude Code" : "no Claude tab needs a restart"), false
		}
		n := len(now) + len(later)
		what := fmt.tprintf("restart %d Claude tab%s%s? Each resumes its conversation; background work Claude started there (background shells, monitors) stops.", n, n == 1 ? "" : "s", c.update && !c.all ? fmt.tprintf(" on Claude Code %s", claude_version_label(info.version)) : "")
		if len(later) > 0 do what = fmt.tprintf("%s %d busy tab%s wait%s until idle.", what, len(later), len(later) == 1 ? "" : "s", len(later) == 1 ? "s" : "")
		// what runs there now, as Claude's last turn reported it (claude_panels.odin)
		for x in ([][dynamic]^Tab{now, later}) do for t in x do if bg := claude_background_names(t.id); bg != "" do what = fmt.tprintf("%s Running in %s: %s.", what, cut_utf8(one_line(t.title, context.temp_allocator), 40), bg)
		// always asked, by the user: Deckhand sees Claude's background work only as of its last turn
		gr, go_on, ch := confirm_gate(cmd, .Session_Restart, caller, c.confirm, what, force_ask = caller.kind != .Internal)
		if !go_on do return gr, ch
		flags := asker.kind == .UI // the saved flags are the user's to replay, on the user's restart (CLAUDE.md §3)
		for t in now do restart_now(t, flags)
		for t in later {
			t.reload.queued, t.reload.flags, t.reload.all = .Restart, flags, c.all
			set_note(t, fmt.tprintf("restarts when idle (%s)", busy_why(t)))
		}
		if c.all {
			// every tab: the bars' own restarts are done too, or wait with the rest
		} else if c.update do info.update_dismissed = false
		else {
			info.dismissed = false
			info.from_save = false
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '{')
		ids_json(&b, "restarting", now[:], first = true)
		ids_json(&b, "queued", later[:])
		ids_json(&b, "no_session", cut[:])
		strings.write_byte(&b, '}')
		return {ok = true, data = strings.to_string(b)}, true
	case Claude_Reload_Later:
		if c.update do info.update_dismissed = true
		else {
			info.dismissed = true
			info.from_save = false
		}
		for x in running_claude() do if x.t.reload.queued == .Restart {
			x.t.reload.queued, x.t.reload.flags, x.t.reload.all = .None, false, false
			set_note(x.t, "")
		}
		return {ok = true}, true
	case Claude_Reload_Watch:
		if len(c.paths) > 0 || c.more > 0 {
			// a new round: Details lists only what changed since nothing was pending
			pending := false
			for x in running_claude() do if x.t.reload.stale || x.t.reload.queued != .None do pending = true
			if !pending {
				for p in info.changed do delete(p)
				clear(&info.changed)
				info.changed_more = 0
			}
			info.gen += 1
			for p in c.paths {
				if slice.contains(info.changed[:], p) do continue
				if len(info.changed) < RELOAD_CHANGED_MAX do append(&info.changed, strings.clone(p))
				else do info.changed_more += 1
			}
			info.changed_more += c.more
			for x in running_claude() {
				cwd := tab_cwd(x.s, x.t)
				for scope in c.scopes do if in_scope_tab(x.t, cwd, scope) {
					x.t.reload.stale = true
					x.t.reload.stale_gen = info.gen
					break
				}
			}
			info.dismissed = false
			if c.from_save do info.from_save = true
		}
		if c.ident != "" && c.ident != info.ident {
			first := info.ident == ""
			delete(info.ident)
			delete(info.version)
			info.ident = strings.clone(c.ident)
			info.version = strings.clone(c.version)
			info.update_dismissed = false
			// tabs seen before the version was known started with this one
			if first do for x in running_claude() do if x.t.reload.version == "" do set_version(x.t, c.ident)
		}
		return {ok = true}, true
	case Claude_Reload_Kick:
		_, t, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if t.reload.queued != .Restart do return {ok = true}, false // dropped meanwhile (Later)
		if t.status != .Running {
			t.reload.queued = .None
			return fail("Claude is not running in this tab"), true
		}
		if !t.reload.all && !t.reload.stale && !claude_reload_outdated(t) {
			t.reload.queued = .None // restarted some other way meanwhile
			set_note(t, "")
			return {ok = true}, true
		}
		if claude_restart_class(t) != .Idle do return {ok = true}, false // again when idle
		restart_now(t, t.reload.flags)
		return {ok = true}, true
	}
	return fail("not a Claude reload command"), false
}

// For events and the command log; confirmation tokens never.
claude_reload_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Claude_Restart_Changed: return "claude_restart_changed"
	case Claude_Reload_Later:    return "claude_reload_later"
	case Claude_Reload_Watch:    return "claude_reload_watch"
	case Claude_Reload_Kick:     return "claude_reload_kick"
	}
	return ""
}

claude_reload_write :: proc(b: ^strings.Builder, cmd: Command) {
	#partial switch c in cmd {
	case Claude_Restart_Changed:
		if c.update do strings.write_string(b, `,"update":true`)
		if c.all do strings.write_string(b, `,"all":true`)
		if c.confirm != "" do strings.write_string(b, `,"confirm":"<redacted>"`)
	case Claude_Reload_Later:
		if c.update do strings.write_string(b, `,"update":true`)
	case Claude_Reload_Watch:
		fmt.sbprintf(b, `,"files":%d`, len(c.paths) + c.more)
		if c.version != "" {
			strings.write_string(b, `,"version":`)
			json_quote(b, c.version)
		}
	case Claude_Reload_Kick:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
	}
}

claude_reload_clone :: proc(cmd: Command, a: runtime.Allocator) -> Command {
	#partial switch c in cmd {
	case Claude_Restart_Changed: return Claude_Restart_Changed{update = c.update, all = c.all, confirm = strings.clone(c.confirm, a)}
	case Claude_Reload_Watch:
		paths := make([]string, len(c.paths), a)
		scopes := make([]string, len(c.scopes), a)
		for x, i in c.paths do paths[i] = strings.clone(x, a)
		for x, i in c.scopes do scopes[i] = strings.clone(x, a)
		return Claude_Reload_Watch{paths = paths, more = c.more, scopes = scopes, version = strings.clone(c.version, a), ident = strings.clone(c.ident, a), from_save = c.from_save}
	}
	return cmd
}

claude_reload_free :: proc(cmd: Command, a: runtime.Allocator) {
	#partial switch c in cmd {
	case Claude_Restart_Changed: delete(c.confirm, a)
	case Claude_Reload_Watch:
		for x in c.paths do delete(x, a)
		for x in c.scopes do delete(x, a)
		delete(c.paths, a)
		delete(c.scopes, a)
		delete(c.version, a)
		delete(c.ident, a)
	}
}

// The snapshot's "claude" object of "reload".
write_claude_reload :: proc(b: ^strings.Builder, r: Claude_Reload_Info) {
	fmt.sbprintf(b, `{{"gen":%d,"changed":`, r.gen)
	write_strings(b, r.changed[:])
	fmt.sbprintf(b, `,"changed_more":%d,"from_save":%v,"dismissed":%v,"version":`, r.changed_more, r.from_save, r.dismissed)
	json_quote(b, r.version)
	fmt.sbprintf(b, `,"update_dismissed":%v}}`, r.update_dismissed)
}

// ---- watching (runtime, main thread) ----

@(private = "file")
Src_Kind :: enum u8 {
	File, // its stamp
	Folder, // the stamps of its files (a digest), and whether it is there
	Exists, // only whether the folder is there
}

@(private = "file")
Src :: struct {
	path:   string, // owned
	scope:  string, // owned
	kind:   Src_Kind,
	pk:     Path_Kind,
	stamp:  Disk_Stamp,
	digest: u64,
}

@(private = "file")
cw: struct {
	srcs:      [dynamic]Src,
	key:       string, // the running Claude tabs' folders the sources were built for (owned)
	last_poll: time.Tick,
	pending:   [dynamic]string, // owned, at most RELOAD_CHANGED_MAX
	more:      int,
	scopes:    [dynamic]string, // owned
	due:       time.Tick,
	has_due:   bool,
	from_save: bool,
	version:   string, // to report (owned)
	ident:     string, // to report (owned)
	bin:       string, // claude's path (owned; "" = none)
	last_find: time.Tick,
}

// Forgets the watcher's state (tests).
claude_reload_watch_reset :: proc() {
	for s in cw.srcs {
		delete(s.path)
		delete(s.scope)
	}
	for p in cw.pending do delete(p)
	for p in cw.scopes do delete(p)
	delete(cw.srcs)
	delete(cw.pending)
	delete(cw.scopes)
	delete(cw.key)
	delete(cw.version)
	delete(cw.ident)
	delete(cw.bin)
	cw = {}
}

// Notes a changed path; reported once nothing changed for RELOAD_DEBOUNCE.
@(private = "file")
pending_add :: proc(path, scope: string, at := time.Tick{}) {
	now := at == {} ? time.tick_now() : at
	if !slice.contains(cw.scopes[:], scope) do append(&cw.scopes, strings.clone(scope))
	if len(cw.pending) >= RELOAD_CHANGED_MAX do cw.more += 1
	else if !slice.contains(cw.pending[:], path) do append(&cw.pending, strings.clone(path))
	cw.due = time.tick_add(now, RELOAD_DEBOUNCE)
	cw.has_due = true
}

// Reports what changed if the debounce passed (true when it did).
claude_reload_flush :: proc(at := time.Tick{}) -> bool {
	now := at == {} ? time.tick_now() : at
	if !cw.has_due || time.tick_diff(cw.due, now) < 0 do return false
	cw.has_due = false
	run_command(Claude_Reload_Watch{paths = cw.pending[:], more = cw.more, scopes = cw.scopes[:], version = cw.version, ident = cw.ident, from_save = cw.from_save})
	for p in cw.pending do delete(p)
	for p in cw.scopes do delete(p)
	clear(&cw.pending)
	clear(&cw.scopes)
	cw.more = 0
	delete(cw.version)
	delete(cw.ident)
	cw.version, cw.ident = "", ""
	cw.from_save = false
	return true
}

// Paths waiting for the debounce (tests).
claude_reload_pending_count :: proc() -> int {return len(cw.pending)}

// The editor saved a file (settings_after_save): one a running Claude session reads only at
// start shows the bar at once; one it applies live, nothing.
claude_reload_note_save :: proc(path: string) {
	if claude_file_class(path) != .Restart do return
	p, _ := filepath.clean(path, context.temp_allocator)
	scope := ""
	plugin := claude_plugin_dir()
	in_config := false
	for cfg in claude_account_dirs() do if under(p, cfg) {
		// only a running account's tabs read it (none running: the default's, for new tabs)
		running := accounts_now()
		if len(running) > 0 ? !slice.contains(running, cfg) : cfg != claude_config_dir() do return
		in_config = true
		scope = account_scope(cfg) // only that account's tabs read it ("" while one account runs)
	}
	if !in_config && (plugin == "" || !under(p, plugin)) {
		// a project's file: the folder that holds its .claude/ (at any depth in it), else its own
		if i := strings.last_index(p, "/.claude/"); i > 0 do scope = p[:i]
		else do scope = filepath.dir(p)
	}
	pending_add(p, scope)
	cw.due = time.tick_now()
	cw.from_save = true
	window_state_changed()
}

// Every frame (editor_tick): records each Claude tab's version when it starts, restarts the
// queued ones that are idle now, polls while a Claude tab runs, reports after the debounce.
claude_reload_tick :: proc() {
	tabs := running_claude()
	kicks := make([dynamic]u64, context.temp_allocator)
	for &s in state.open_sessions do for &t in s.tabs {
		if _, is := t.kind.(Claude_Tab); is && t.status != .Running && t.reload.started {
			t.reload.started = false
			window_state_changed() // a tick, not a command: the window's replica follows
		}
	}
	for x in tabs {
		t := x.t
		if !t.reload.started {
			// a new process reads every file anew
			t.reload.started = true
			t.reload.stale = false
			window_state_changed()
			set_version(t, state.reload.claude.ident)
			if strings.has_prefix(t.reload.note, "restarting") do set_note(t, "restarted")
		}
		if t.reload.queued == .Restart && claude_restart_class(t) == .Idle do append(&kicks, t.id)
	}
	for id in kicks do run_command(Claude_Reload_Kick{tab_id = id})
	if len(tabs) == 0 {
		if len(cw.srcs) > 0 { 	// stop watching
			claude_reload_build({})
			delete(cw.key)
			cw.key = ""
		}
		claude_reload_flush()
		return
	}
	if cw.last_poll == {} || time.tick_since(cw.last_poll) > RELOAD_POLL {
		cw.last_poll = time.tick_now()
		claude_reload_poll()
	}
	if claude_reload_flush() do window_state_changed()
}

// Tests: a poll now, and its report as if the debounce passed.
claude_reload_poll_now :: proc() {
	claude_reload_poll()
	claude_reload_flush(time.tick_add(time.tick_now(), 2 * RELOAD_DEBOUNCE))
}

// The running Claude tabs' folders, sorted.
@(private = "file")
cwds_now :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for x in running_claude() {
		c := tab_cwd(x.s, x.t)
		if c != "" && !slice.contains(out[:], c) do append(&out, c)
	}
	slice.sort(out[:])
	return out[:]
}

// A folder's digest: the names, times and sizes of what is in it (stat only, never a file's
// contents; at most CLAUDE_RELOAD_FOLDER_MAX entries, 3 levels; hidden names and node_modules
// left out). Only config folders are digested: add never takes a credential or state path.
@(private = "file")
folder_digest :: proc(dir: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	n := 0
	walk :: proc(d: string, depth: int, h: ^u64, n: ^int) {
		entries, err := os.read_all_directory_by_path(d, context.temp_allocator)
		if err != nil do return
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for e in entries {
			if n^ >= CLAUDE_RELOAD_FOLDER_MAX do return
			if strings.has_prefix(e.name, ".") || e.name == "node_modules" do continue
			n^ += 1
			_, st := path_stat(e.fullpath)
			line := fmt.tprintf("%s|%d|%d|%v\n", e.fullpath, st.mtime, st.size, e.type == .Directory)
			h^ = hash.fnv64a(transmute([]u8)line, h^)
			if e.type == .Directory && depth < 3 do walk(e.fullpath, depth + 1, h, n)
		}
	}
	walk(dir, 1, &h, &n)
	return h
}

// One poll: the sources again if the tabs' folders changed, every source, claude's version.
@(private = "file")
claude_reload_poll :: proc() {
	now := time.tick_now()
	cwds := cwds_now()
	key := strings.concatenate({strings.join(cwds, "\x00", context.temp_allocator), "\x01", strings.join(accounts_now(), "\x00", context.temp_allocator)}, context.temp_allocator)
	if key != cw.key {
		delete(cw.key)
		cw.key = strings.clone(key)
		claude_reload_build(cwds)
	}
	for &s in cw.srcs {
		switch s.kind {
		case .File:
			k, st := path_stat(s.path)
			if k == s.pk && (k == .Missing || (st.mtime == s.stamp.mtime && st.size == s.stamp.size && st.inode == s.stamp.inode)) do continue
			s.pk, s.stamp = k, st
			pending_add(s.path, s.scope, now)
		case .Exists:
			k := path_kind(s.path)
			if (k == .Dir) == (s.pk == .Dir) do continue
			s.pk = k
			pending_add(s.path, s.scope, now)
		case .Folder:
			k := path_kind(s.path)
			d := k == .Dir ? folder_digest(s.path) : 0
			if k == s.pk && d == s.digest do continue
			s.pk, s.digest = k, d
			pending_add(s.path, s.scope, now)
		}
	}
	// claude's version on disk: found again now and then (PATH may change), looked at each poll
	if cw.last_find == {} || time.tick_since(cw.last_find) > CLAUDE_FIND_EVERY || hook_env(.Claude_Bin) != "" {
		cw.last_find = now
		b := claude_binary_path()
		if b != cw.bin {
			delete(cw.bin)
			cw.bin = strings.clone(b)
		}
	}
	if cw.bin != "" {
		label, ident := claude_version_of(cw.bin)
		if ident != "" && ident != state.reload.claude.ident && ident != cw.ident {
			delete(cw.version)
			delete(cw.ident)
			cw.version, cw.ident = strings.clone(label), strings.clone(ident)
			cw.due = state.reload.claude.ident == "" ? now : time.tick_add(now, RELOAD_DEBOUNCE)
			cw.has_due = true
		}
	}
}

// The plugin's files a running Claude read at start (Deckhand's own, --plugin-dir).
@(private = "file")
PLUGIN_FILES :: [?]string{".claude-plugin/plugin.json", "hooks/hooks.json", "skills/deckhand/SKILL.md", "bin/deckhand", "bin/pi-desk"}
@(private = "file")
RESTART_FOLDERS :: [?]string{"rules", "output-styles", "commands"}
@(private = "file")
NEW_FOLDERS :: [?]string{"agents", "skills"} // watched only for appearing (Claude watches them once there)

// The sources for these folders (cwds_now; none = stop). What was known of sources still
// watched is kept, so a change between polls still shows.
claude_reload_build :: proc(cwds: []string) {
	old := cw.srcs
	cw.srcs = {}
	if len(cwds) > 0 {
		ids := credential_ids() // the sign-in files' ids, once for every source
		// each running tab's account's config folder (claude_accounts.odin), for its tabs only
		accts := accounts_now()
		if len(accts) == 0 do accts = []string{claude_config_dir()} // none running: the default's
		for cfg in accts {
			sc := account_scope(cfg)
			add(fmt.tprintf("%s/CLAUDE.md", cfg), sc, .File, ids)
			for d in RESTART_FOLDERS do add(fmt.tprintf("%s/%s", cfg, d), sc, .Folder, ids)
			for d in NEW_FOLDERS do add(fmt.tprintf("%s/%s", cfg, d), sc, .Exists, ids)
		}
		if plugin := claude_plugin_dir(); plugin != "" do for f in PLUGIN_FILES do add(fmt.tprintf("%s/%s", plugin, f), "", .File, ids)
		for c in cwds {
			// instructions: the cwd (watched for being made) and every folder above it
			d, _ := filepath.clean(c, context.temp_allocator)
			for i := 0; i < 32; i += 1 {
				for name in ([]string{"CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md"}) {
					p := fmt.tprintf("%s/%s", d == "/" ? "" : d, name)
					if d == c || path_kind(p) == .File do add(p, d, .File, ids)
				}
				if d == "/" || d == "" || d == "." do break
				d = filepath.dir(d)
			}
			add(fmt.tprintf("%s/.mcp.json", c), c, .File, ids)
			for f in RESTART_FOLDERS do add(fmt.tprintf("%s/.claude/%s", c, f), c, .Folder, ids)
			for f in NEW_FOLDERS do add(fmt.tprintf("%s/.claude/%s", c, f), c, .Exists, ids)
		}
	}
	for &s in cw.srcs {
		for &o in old do if o.path == s.path && o.kind == s.kind {
			s.pk, s.stamp, s.digest = o.pk, o.stamp, o.digest
			break
		}
	}
	for o in old {
		delete(o.path)
		delete(o.scope)
	}
	delete(old)
}

// A source; one per path (a scope of every tab wins); never a credential or state file.
@(private = "file")
add :: proc(path, scope: string, kind: Src_Kind, ids: []Cred_Id) {
	p, _ := filepath.clean(path, context.temp_allocator)
	if settings_credential(p, ids) do return
	for &s in cw.srcs {
		if s.path != p do continue
		if scope == "" && s.scope != "" {
			delete(s.scope)
			s.scope = strings.clone(scope)
		}
		return
	}
	if len(cw.srcs) >= RELOAD_FILES_MAX do return
	src := Src{path = strings.clone(p), scope = strings.clone(scope), kind = kind}
	switch kind {
	case .File:   src.pk, src.stamp = path_stat(p)
	case .Exists: src.pk = path_kind(p)
	case .Folder:
		src.pk = path_kind(p)
		if src.pk == .Dir do src.digest = folder_digest(p)
	}
	append(&cw.srcs, src)
}

// For tests: the sources now (path → scope; folders end in "/").
claude_reload_sources_for_test :: proc() -> map[string]string {
	m := make(map[string]string, context.temp_allocator)
	for s in cw.srcs do m[s.kind == .File ? s.path : strings.concatenate({s.path, "/"}, context.temp_allocator)] = s.scope
	return m
}
