package core

// The coding agents ("harnesses") Deckhand can start in a session: pi, Claude Code and Codex
// (sidebar.odin: Harness). Any may be missing: a Claude-only user has no pi, a pi user may have no
// Claude Code.
//
//   - Whether each is installed is looked for, never run, the same way for all three:
//     harness_installed below (the PATH new tabs get, the harness's own install folders, then the
//     login shell's `command -v`). DECKHAND_CMD stands in for pi (tests, benchmarks).
//   - The user's one "New session" (⌘N in Chats, ⇧⌘N, "+ New session", Chats' "+ New chat", a
//     project's "+" and menu, a checkout's "New session here", the palette and the menu bar) goes
//     through new_session_ui: no harness installed, a toast with how to install one; one, it
//     starts at once; two or more, a small picker (Menu_New_Session) lists the installed ones
//     with their icons (Claude Code once per account while there are several), numbered 1-9, the
//     last used first and selected, so Enter repeats it.
//   - The agents' and the CLI's commands (new_chat, new_claude_session, worktree_session…) are
//     unchanged: they name their harness.
//   - Atlas and jobs run pi only (for now): without pi, Atlas is not offered (ATLAS_NEEDS_PI) and
//     a job's run fails with JOBS_NEED_PI.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Saved names (workspace.json settings.last_harness).
HARNESS_KEYS := [Harness]string {
	.Pi     = "pi",
	.Claude = "claude",
	.Codex  = "codex",
}

PI_INSTALL :: "npm install -g @earendil-works/pi-coding-agent"
// What the user sees when no harness is installed: how to install either.
NO_HARNESS :: "No coding agent is installed: install pi (`" + PI_INSTALL + "`, Node 22.19 or later) or Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`, or `brew install --cask claude-code`), then use the gear's Refresh shell environment or restart Deckhand"
// Atlas runs on pi (agent.odin).
ATLAS_NEEDS_PI :: "Atlas needs pi, which is not installed: install it with `" + PI_INSTALL + "`, then use the gear's Refresh shell environment or restart Deckhand"
// Jobs run pi (jobs.odin).
JOBS_NEED_PI :: "Jobs run pi, which was not found on the jobs' PATH or in pi's managed install: install it with `" + PI_INSTALL + "`, or set pi_path"

// An executable regular file `name` in the absolute folder dir (stat and access only).
exe_in :: proc(dir, name: string) -> bool {
	if !filepath.is_abs(dir) do return false
	p := strings.concatenate({strings.trim_right(dir, "/"), "/", name}, context.temp_allocator)
	cp := strings.clone_to_cstring(p, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(cp, &st) != .OK || !posix.S_ISREG(st.st_mode) do return false
	return posix.access(cp, {.X_OK}) == .OK
}
// ---- is a harness installed? (looked for, never run) ----
//
// One lookup for pi, Claude Code and Codex (harness_installed), in the order a tab's own command
// finds its harness: the PATH new tabs get (detect_path), then the folders the harness's own
// installer uses (harness_folders: PI_TAB_CMD and CLAUDE_TAB_CMD fall back to the same ones), then
// the login shell's `command -v <name>` on a worker (a .zprofile that adds nvm, fnm, asdf, mise or
// pnpm). Stat, access(X_OK) and `command -v` only: a harness is never run to find it. A stat that
// finds nothing is never the last word: until the login shell answered, the harness counts as there.

// Whether a harness is there, cached (Unknown = look at the next use).
Claude_Found :: enum u8 {
	Unknown,
	Yes,
	No,
}
harness_found: [Harness]Claude_Found
// Where it was found ("" = not known: a stand-in, or a login shell that gave no clear answer). Heap.
@(private = "file")
harness_where: [Harness]string

// Tests: stands in for the lookup of a harness; nil = look.
harness_installed_probe: [Harness]proc() -> bool

// The folders a harness's own installer puts it in, looked in after PATH (absolute ones only;
// temp): pi's managed install ($PI_CODING_AGENT_DIR/bin, ~/.pi/agent/bin), Claude Code's native
// installer (~/.local/bin) and its older local install (~/.claude/local). Codex has none: npm,
// Homebrew and its own installer put it on the login shell's PATH (the login shell finds it).
harness_folders :: proc(h: Harness, home, agent_dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	home := strings.trim_right(home, "/")
	switch h {
	case .Pi:
		if filepath.is_abs(agent_dir) do append(&out, strings.concatenate({strings.trim_right(agent_dir, "/"), "/bin"}, context.temp_allocator))
		if filepath.is_abs(home) do append(&out, strings.concatenate({home, "/.pi/agent/bin"}, context.temp_allocator))
	case .Claude:
		if filepath.is_abs(home) do append(&out, strings.concatenate({home, "/.local/bin"}, context.temp_allocator), strings.concatenate({home, "/.claude/local"}, context.temp_allocator))
	case .Codex:
	}
	return out[:]
}

// The harness binary on `path` (absolute entries only), else in its folders, else in a Node version
// manager's (managers: node_manager_dirs, harness_node.odin). "" = none of them. Temp.
harness_find :: proc(h: Harness, path, home, agent_dir: string, managers: []string = nil) -> string {
	name := HARNESS_BIN_NAMES[h]
	for dir in strings.split(path, ":", context.temp_allocator) do if exe_in(dir, name) do return strings.concatenate({strings.trim_right(dir, "/"), "/", name}, context.temp_allocator)
	for dir in harness_folders(h, home, agent_dir) do if exe_in(dir, name) do return strings.concatenate({dir, "/", name}, context.temp_allocator)
	for dir in managers do if exe_in(dir, name) do return strings.concatenate({dir, "/", name}, context.temp_allocator)
	return ""
}

// The PATH the lookup searches: the one new tabs get. Test mode looks in the install folders only
// (under the scene's fake HOME), never PATH, unless DECKHAND_REAL_PI=1: a scene finds the same
// harnesses on every Mac, never the developer's own pi or claude.
detect_path :: proc() -> string {
	if test_mode() && hook_env(.Real_Pi) != "1" do return ""
	path, _ := env_lookup(child_base_env(), "PATH")
	return path
}

// The harness binary Deckhand would start, by stat (harness_find on detect_path); the tests' named
// binaries first (DECKHAND_CLAUDE_BIN, DECKHAND_CODEX_BIN). Unit tests and test mode never find a
// codex by search (a codex the developer installed must not change what they see). "" = not
// found this way. Temp.
harness_binary :: proc(h: Harness) -> string {
	switch h {
	case .Pi:
	case .Claude:
		if b := hook_env(.Claude_Bin); filepath.is_abs(b) do return b
	case .Codex:
		if b := hook_env(.Codex_Bin); filepath.is_abs(b) do return b
		when TEST_HOOKS {
			if ODIN_TEST || test_mode() do return ""
		}
	}
	home := os.get_env("HOME", context.temp_allocator)
	// nvm's and fnm's folders (harness_node.odin): $NVM_DIR and $FNM_DIR as new tabs get them; test
	// mode and unit tests only their defaults under the (fake) HOME, never the developer's
	nvm_dir, fnm_dir: string
	if !(ODIN_TEST || test_mode()) {
		env := child_base_env()
		nvm_dir, _ = env_lookup(env, "NVM_DIR")
		fnm_dir, _ = env_lookup(env, "FNM_DIR")
	}
	return harness_find(h, detect_path(), home, pi_agent_dir(), node_manager_dirs(home, nvm_dir, fnm_dir))
}

// The login shell's answer about a harness: `$SHELL -l -c 'command -v <name>'` (or /bin/sh for
// fish and co.), asked on a worker once per recheck, as the tab's shell would find it.
Harness_Lookup :: enum i32 {
	None, // not asked (or asked again since)
	Asking,
	Found,
	Missing,
}
@(private = "file")
Lookup :: struct {
	state: Harness_Lookup, // atomic
	gen:   i32, // atomic: a recheck while asking drops the old answer
	lock:  sync.Mutex,
	path:  string, // heap, under lock: what the shell named ("" = no clear answer)
}
@(private = "file")
lookups: [Harness]Lookup

// How long the login shell may take to answer (tests shorten it).
harness_lookup_timeout := 10 * time.Second

when TEST_HOOKS {
	// Unit tests: the login shell is asked only by a test that turns this on (never otherwise: the
	// developer's own shell must not change what a test sees, nor a "there meanwhile" answer).
	harness_lookup_in_unit_tests: bool
}

harness_lookup_state :: proc(h: Harness) -> Harness_Lookup {return Harness_Lookup(sync.atomic_load(&lookups[h].state))}

// Whether the login shell is being asked about any harness.
harness_lookup_asking :: proc() -> bool {
	for h in Harness do if harness_lookup_state(h) == .Asking do return true
	return false
}

// What the login shell named, once it answered ("" = not asked, no answer yet, or none). Temp.
harness_shell_path :: proc(h: Harness) -> string {
	if harness_lookup_state(h) != .Found do return ""
	l := &lookups[h]
	sync.lock(&l.lock)
	defer sync.unlock(&l.lock)
	return strings.clone(l.path, context.temp_allocator)
}

// Asks the login shell on a worker (once per recheck). Test mode: only with DECKHAND_REAL_PI=1, as
// detect_path (never the developer's own harnesses).
@(private = "file")
harness_lookup_start :: proc(h: Harness) {
	skip := test_mode() && hook_env(.Real_Pi) != "1"
	when TEST_HOOKS {
		if ODIN_TEST && !harness_lookup_in_unit_tests do skip = true
	}
	if skip {
		sync.atomic_store(&lookups[h].state, .Missing)
		return
	}
	if _, ok := sync.atomic_compare_exchange_strong(&lookups[h].state, .None, .Asking); !ok do return
	gen := sync.atomic_load(&lookups[h].gen)
	thread.create_and_start_with_poly_data2(h, gen, proc(h: Harness, gen: i32) {
		defer free_all(context.temp_allocator)
		name := HARNESS_BIN_NAMES[h]
		out, code, ran := run_bounded_exit("", shell_script_argv(login_shell(), strings.concatenate({"command -v ", name}, context.temp_allocator), "sh")[:], harness_lookup_timeout)
		// only a clean answer says no: exit 0 without a runnable binary, or command -v's 1. A
		// timeout, a shell that cannot start, or any other failure (127, a broken rc file, a signal)
		// proves nothing: the harness counts as there (a recheck asks again; a tab that exits 127
		// rechecks)
		found, bin := true, ""
		if ran && code == 0 {
			lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
			bin = len(lines) > 0 ? strings.trim_space(lines[len(lines) - 1]) : ""
			found = filepath.is_abs(bin) && exe_in(filepath.dir(bin), filepath.base(bin))
			if !found do bin = ""
		} else if ran && code == 1 {
			found = false
		}
		l := &lookups[h]
		sync.lock(&l.lock)
		if sync.atomic_load(&l.gen) == gen {
			delete(l.path, runtime.heap_allocator())
			l.path = strings.clone(bin, runtime.heap_allocator())
			sync.atomic_compare_exchange_strong(&l.state, .Asking, found ? .Found : .Missing)
		}
		sync.unlock(&l.lock)
		if platform.wake != nil do platform.wake()
	}, self_cleanup = true)
}

@(private = "file")
harness_cache_set :: proc(h: Harness, found: Claude_Found, path: string) {
	harness_found[h] = found
	path := harness_real_dir(path) // a per-shell folder (fnm's) resolved to the install, which stays
	if harness_where[h] == path do return
	delete(harness_where[h], runtime.heap_allocator())
	harness_where[h] = strings.clone(path, runtime.heap_allocator())
}

// Whether harness h is installed, as new tabs would find it (see above), and where ("" = not
// known). DECKHAND_CMD stands in for pi (tests, benchmarks): pi counts as installed. Cached;
// harness_recheck drops it and the login shell's answer (Refresh shell environment, a tab that
// exited 127); harness_installed_now stats again (a user's action).
harness_installed :: proc(h: Harness) -> (path: string, found: bool) {
	if p := harness_installed_probe[h]; p != nil {
		if !p() do return "", false
		return harness_binary(h), true
	}
	if h == .Pi && hook_env(.Cmd) != "" do return "", true
	if harness_found[h] == .Unknown {
		if b := harness_binary(h); b != "" do harness_cache_set(h, .Yes, b)
	}
	if harness_found[h] == .Unknown {
		switch harness_lookup_state(h) {
		case .Found:
			harness_cache_set(h, .Yes, harness_shell_path(h))
		case .Missing:
			harness_cache_set(h, .No, "")
		case .None:
			harness_lookup_start(h)
			if harness_lookup_state(h) == .Missing do harness_cache_set(h, .No, "")
		case .Asking:
		}
	}
	return harness_where[h], harness_found[h] != .No // asking: there
}

// Everything looked up again, the login shell too.
harness_recheck :: proc(h: Harness) {
	harness_found[h] = .Unknown
	sync.atomic_add(&lookups[h].gen, 1)
	sync.atomic_store(&lookups[h].state, .None)
}

// harness_installed after a fresh stat (the user may have installed it since); the login shell's
// answer is kept (stat only: cheap enough for every New session, Restart or click).
harness_installed_now :: proc(h: Harness) -> bool {
	if harness_found[h] == .No do harness_found[h] = .Unknown
	_, found := harness_installed(h)
	return found
}

// The binary to read a harness's version from: by stat, else what the login shell named ("" =
// none). Temp.
harness_path :: proc(h: Harness) -> string {
	if b := harness_binary(h); b != "" do return b
	return harness_shell_path(h)
}

pi_installed :: proc() -> bool {
	_, found := harness_installed(.Pi)
	return found
}
pi_installed_now :: proc() -> bool {return harness_installed_now(.Pi)}
pi_recheck :: proc() {harness_recheck(.Pi)}

// ---- the one "New session" ----

// Atlas is offered: it runs on pi (open or running already: as it is).
atlas_offered :: proc() -> bool {return state.home_open || agent_running() || pi_installed()}

// The picker's target (ui_sidebar.odin menus): a new session in the project, in cwd (a checkout
// of it; "" = the project's folder). cwd is owned while the menu is open. Another machine's
// project: its core's run and the project's folder when the picker opened (a restart there gives
// ids out again: ui_handoff.odin checks them before a choice starts anything); owned too.
Menu_New_Session :: struct {
	project_id: u64,
	cwd:        string,
	run:        string,
	folder:     string,
}

// Which harness a picker row's command starts.
harness_of :: proc(cmd: Command) -> (h: Harness, ok: bool) {
	#partial switch c in cmd {
	case New_Chat, Worktree_Session: return .Pi, true
	case New_Claude_Session:         return c.codex ? .Codex : .Claude, true
	}
	return {}, false
}

// The rows for a new session in p (in cwd, a checkout of it; "" = its folder): one per installed
// harness, Claude Code once per account while there are several (the one this project would use
// first), the last used harness first, numbered 1-9 (temp).
new_session_choices :: proc(p: ^Project, cwd: string) -> []Menu_Item {
	out := make([dynamic]Menu_Item, context.temp_allocator)
	if p == nil do return out[:]
	// the last used first, then the others in their order
	order: [len(Harness)]Harness
	order[0] = state.settings.last_harness
	n := 1
	for h in Harness do if h != order[0] {
		order[n] = h
		n += 1
	}
	// another machine's project: what that machine has (its checklist), with its own account;
	// never this Mac's harnesses, accounts or folders
	if no := id_machine(p.id); no != 0 {
		pi, claude, codex := machine_harnesses(no)
		for h in order {
			if h == .Pi && pi do append(&out, Menu_Item{label = HARNESSES[.Pi].name, icon = harness_icon(.Pi), cmd = New_Chat{project_id = p.id}})
			if h == .Claude && claude && p.group == .Projects do append(&out, Menu_Item{label = HARNESSES[.Claude].name, icon = harness_icon(.Claude), cmd = New_Claude_Session{project_id = p.id}})
			// Codex: only where its core says it starts one (machine_codex; an older core would start Claude Code)
			if h == .Codex && codex && p.group == .Projects do append(&out, Menu_Item{label = HARNESSES[.Codex].name, icon = harness_icon(.Codex), cmd = New_Claude_Session{project_id = p.id, codex = true}})
		}
		for &it, i in out do it.keys = fmt.tprint(i + 1)
		return out[:]
	}
	for h in order {
		switch h {
		case .Pi:
			if !pi_installed() do continue
			cmd: Command = New_Chat{project_id = p.id}
			if cwd != "" do cmd = Worktree_Session{project_id = p.id, path = cwd}
			append(&out, Menu_Item{label = HARNESSES[.Pi].name, icon = harness_icon(.Pi), cmd = cmd})
		case .Claude, .Codex:
			codex := h == .Codex
			if codex {
				// a project or a checkout of it, or Chats
				if !codex_installed() do continue
				if p.group == .Chats {
					if cwd != "" do continue
				} else if p.group != .Projects do continue
			} else {
				// in a project or Chats (claude.odin: New_Claude_Session); a checkout: a project's only
				if !claude_installed() || (p.group != .Projects && !(p.group == .Chats && cwd == "")) do continue
			}
			base := New_Claude_Session{project_id = p.id, cwd = cwd, codex = codex}
			accts := claude_accounts(codex)
			if len(accts) < 2 {
				append(&out, Menu_Item{label = HARNESSES[h].name, icon = harness_icon(h), cmd = base})
				continue
			}
			pick := claude_account_pick(p, codex)
			for pass in 0 ..< 2 { 	// the pick first, then the others in their order
				for a in accts {
					if (a.dir == pick) != (pass == 0) do continue
					c := base
					c.account = a.dir
					append(&out, Menu_Item{label = fmt.tprintf("%s · %s", HARNESSES[h].name, a.label), icon = harness_icon(h), cmd = c})
				}
			}
		}
	}
	for &it, i in out do if i < 9 do it.keys = fmt.tprint(i + 1)
	return out[:]
}

// Which harnesses machine no has, as its checklist says (found, old or not); Codex only while its
// core also starts Codex tabs (machine_codex). No checklist yet: its default, pi, only.
machine_harnesses :: proc(no: u64) -> (pi, claude, codex: bool) {
	for m in state.machines do if m.no == no {
		if len(m.checklist) == 0 do return true, false, false
		for c in m.checklist do if c.state == .Ok || c.state == .Too_Old || c.state == .Unchecked {
			if c.id == "pi" do pi = true
			if c.id == "claude" do claude = true
			if c.id == "codex" do codex = m.codex
		}
		return
	}
	return true, false, false
}

// Whether New Codex tab is offered for id (a project's or an open session's): this Mac's, while
// codex is installed here; another machine's, while machine_harnesses says it has Codex.
codex_offered :: proc(id: u64) -> bool {
	if no := id_machine(id); no != 0 {
		_, _, codex := machine_harnesses(no)
		return codex
	}
	return codex_installed()
}

// Whether machine no's core starts Codex tabs for this Mac (its hello's features: codex_tabs).
machine_codex :: proc(no: u64) -> bool {
	for m in state.machines do if m.no == no do return m.codex
	return false
}



// New session on machine no offers nothing (new_session_choices): it opens a session there anyway
// (new_session_ui), and this says why. Codex there but its core too old to start Codex tabs from
// here: that, not "no coding agent".
machine_no_harness_note :: proc(no: u64) -> string {
	for m in state.machines do if m.no == no && !m.codex {
		for c in m.checklist do if c.id == "codex" && (c.state == .Ok || c.state == .Too_Old || c.state == .Unchecked) {
			return fmt.tprintf("On %s: %s; its pi tab says how to install pi, and ⌘T opens a terminal there", m.name, CODEX_REMOTE)
		}
	}
	return "No coding agent is installed on that machine yet: its pi tab says how to install one, and ⌘T opens a terminal there"
}

// ---- where a tab starts its harness from ----

// Each tab's command (PI_TAB_CMD, CLAUDE_TAB_CMD, CODEX_TAB_CMD) finds its harness on the login
// shell's PATH and in its own folders. Where Deckhand found it elsewhere (a Node version manager's
// folder: nvm loaded lazily, fnm; or what the login shell named), harness_found_sh tells the
// script that folder (`_dh_found=<dir>; `), and this step puts it first on PATH when nothing else
// has the harness: the binary Deckhand found starts, with the node next to it (nvm, fnm).
HARNESS_FOUND_PI_SH :: `command -v pi >/dev/null 2>&1 || { case "${_dh_found:-}" in /*) if [ -f "$_dh_found/pi" ] && [ -x "$_dh_found/pi" ]; then printf '%s\n' "Deckhand: starting pi from $_dh_found/pi, where Deckhand found it (it is not on your login shell's PATH)."; PATH="$_dh_found:$PATH"; export PATH; fi;; esac; }; `
HARNESS_FOUND_CLAUDE_SH :: `command -v claude >/dev/null 2>&1 || { case "${_dh_found:-}" in /*) if [ -f "$_dh_found/claude" ] && [ -x "$_dh_found/claude" ]; then printf '%s\n' "Deckhand: starting Claude Code from $_dh_found/claude, where Deckhand found it (it is not on your login shell's PATH)."; PATH="$_dh_found:$PATH"; export PATH; fi;; esac; }; `
HARNESS_FOUND_CODEX_SH :: `command -v codex >/dev/null 2>&1 || { case "${_dh_found:-}" in /*) if [ -f "$_dh_found/codex" ] && [ -x "$_dh_found/codex" ]; then printf '%s\n' "Deckhand: starting Codex from $_dh_found/codex, where Deckhand found it (it is not on your login shell's PATH)."; PATH="$_dh_found:$PATH"; export PATH; fi;; esac; }; `

// `_dh_found=<the folder Deckhand found h in>; ` for the front of its tab's command ("" = not
// found, or found by a stand-in). Temp.
harness_found_sh :: proc(h: Harness) -> string {
	if harness_found[h] != .Yes || !filepath.is_abs(harness_where[h]) do return ""
	return strings.concatenate({"_dh_found=", sh_quote(filepath.dir(harness_where[h])), "; "}, context.temp_allocator)
}
