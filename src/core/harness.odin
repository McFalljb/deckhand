package core

// The coding agents ("harnesses") Deckhand can start in a session: pi and Claude Code (sidebar.odin:
// Harness). Either may be missing: a Claude-only user has no pi, a pi user may have no Claude Code.
//
//   - Whether each is installed is looked for, never run: claude_installed (claude.odin) and
//     pi_installed here, by stat on the PATH new tabs get (child_base_env) and in each one's own
//     install folders. DECKHAND_CMD stands in for pi (tests, benchmarks): pi counts as installed.
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

// Whether a `pi` that can run is on `path` (absolute entries only) or in pi's managed install
// (<agent_dir>/bin, <home>/.pi/agent/bin: where PI_TAB_CMD also looks). Never run.
pi_detect :: proc(path, home, agent_dir: string) -> bool {
	for dir in strings.split(path, ":", context.temp_allocator) do if exe_in(dir, "pi") do return true
	if filepath.is_abs(agent_dir) && exe_in(strings.concatenate({strings.trim_right(agent_dir, "/"), "/bin"}, context.temp_allocator), "pi") do return true
	if filepath.is_abs(home) && exe_in(strings.concatenate({strings.trim_right(home, "/"), "/.pi/agent/bin"}, context.temp_allocator), "pi") do return true
	return false
}

// The PATH pi_installed and claude_installed look in: the one new tabs get. Test mode looks in the
// install folders only (under the scene's fake HOME), never PATH, unless DECKHAND_REAL_PI=1: a
// scene finds the same harnesses on every Mac, never the developer's own pi or claude.
detect_path :: proc() -> string {
	if test_mode() && hook_env(.Real_Pi) != "1" do return ""
	path, _ := env_lookup(child_base_env(), "PATH")
	return path
}

// Whether pi is there, cached as claude_found is (Unknown = look at the next use).
pi_found: Claude_Found

// Tests: stands in for the lookup; nil = look.
pi_installed_probe: proc() -> bool

// The login shell's own answer: `$SHELL -l -c 'command -v pi'` (or /bin/sh for fish and co.), on a
// worker, as a pi tab's shell finds pi (a .zprofile adds nvm, fnm, asdf, mise, pnpm). pi itself is
// never run. A stat that finds nothing is never the last word: until the shell answered, pi counts
// as there.
Pi_Lookup :: enum i32 {
	None, // not asked (or asked again since)
	Asking,
	Found,
	Missing,
}
@(private = "file")
pi_lookup: struct {
	state: Pi_Lookup, // atomic
	gen:   i32, // atomic: a recheck while asking drops the old answer
}

// How long the login shell may take to answer (tests shorten it).
pi_lookup_timeout := 10 * time.Second

pi_lookup_state :: proc() -> Pi_Lookup {return Pi_Lookup(sync.atomic_load(&pi_lookup.state))}

// Asks the login shell on a worker (once per recheck). Test mode: only with DECKHAND_REAL_PI=1, as
// detect_path (never the developer's own pi).
@(private = "file")
pi_lookup_start :: proc() {
	if test_mode() && hook_env(.Real_Pi) != "1" {
		sync.atomic_store(&pi_lookup.state, .Missing)
		return
	}
	if _, ok := sync.atomic_compare_exchange_strong(&pi_lookup.state, .None, .Asking); !ok do return
	gen := sync.atomic_load(&pi_lookup.gen)
	thread.create_and_start_with_poly_data(gen, proc(gen: i32) {
		defer free_all(context.temp_allocator)
		out, code, ran := run_bounded_exit("", shell_script_argv(login_shell(), "command -v pi", "sh")[:], pi_lookup_timeout)
		// only a clean answer says no: exit 0 without a runnable pi, or command -v's 1. A timeout, a
		// shell that cannot start, or any other failure (127, a broken rc file, a signal) proves
		// nothing: pi counts as there (a recheck asks again; a pi tab that exits 127 rechecks)
		found := true
		if ran && code == 0 {
			lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
			bin := len(lines) > 0 ? strings.trim_space(lines[len(lines) - 1]) : ""
			found = filepath.is_abs(bin) && exe_in(filepath.dir(bin), filepath.base(bin))
		} else if ran && code == 1 {
			found = false
		}
		if sync.atomic_load(&pi_lookup.gen) == gen do sync.atomic_compare_exchange_strong(&pi_lookup.state, .Asking, found ? .Found : .Missing)
		if platform.wake != nil do platform.wake()
	}, self_cleanup = true)
}

// Whether pi is installed, as new tabs would find it (see the top): a stat of the PATH tabs get and
// pi's managed install, else the login shell's answer (asked once; meanwhile, yes). Cached;
// pi_recheck drops both (Refresh shell environment, a pi tab that exited 127); pi_installed_now
// stats again (the user's New session).
pi_installed :: proc() -> bool {
	if pi_installed_probe != nil do return pi_installed_probe()
	if hook_env(.Cmd) != "" do return true
	if pi_found == .Unknown && pi_detect(detect_path(), os.get_env("HOME", context.temp_allocator), pi_agent_dir()) do pi_found = .Yes
	if pi_found != .Unknown do return pi_found == .Yes
	switch pi_lookup_state() {
	case .Found:
		pi_found = .Yes
	case .Missing:
		pi_found = .No
	case .None:
		pi_lookup_start()
		if pi_lookup_state() == .Missing do pi_found = .No
	case .Asking:
	}
	return pi_found != .No // asking: there
}

// Everything looked up again, the login shell too.
pi_recheck :: proc() {
	pi_found = .Unknown
	sync.atomic_add(&pi_lookup.gen, 1)
	sync.atomic_store(&pi_lookup.state, .None)
}

// pi_installed after a fresh stat (the user may have installed it since); the login shell's
// answer is kept (stat only: cheap enough for every New session).
pi_installed_now :: proc() -> bool {
	if pi_found == .No do pi_found = .Unknown
	return pi_installed()
}

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
		case .Claude:
			// in a project or Chats (claude.odin: New_Claude_Session); a checkout: a project's only
			if !claude_installed() || (p.group != .Projects && !(p.group == .Chats && cwd == "")) do continue
			base := New_Claude_Session{project_id = p.id, cwd = cwd}
			accts := claude_accounts()
			if len(accts) < 2 {
				append(&out, Menu_Item{label = HARNESSES[.Claude].name, icon = harness_icon(.Claude), cmd = base})
				continue
			}
			pick := claude_account_pick(p)
			for pass in 0 ..< 2 { 	// the pick first, then the others in their order
				for a in accts {
					if (a.dir == pick) != (pass == 0) do continue
					c := base
					c.account = a.dir
					append(&out, Menu_Item{label = fmt.tprintf("%s · %s", HARNESSES[.Claude].name, a.label), icon = harness_icon(.Claude), cmd = c})
				}
			}
		case .Codex:
			// a project or a checkout of it; Chats only while chats are not read-only (Codex has no
			// read-only mode yet: codex.odin)
			if !codex_installed() do continue
			if p.group == .Chats {
				if cwd != "" || state.settings.chats_readonly do continue
			} else if p.group != .Projects do continue
			append(&out, Menu_Item{label = HARNESSES[.Codex].name, icon = harness_icon(.Codex), cmd = New_Claude_Session{project_id = p.id, cwd = cwd, codex = true}})
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

// Whether machine no's core starts Codex tabs for this Mac (its hello's features: codex_tabs).
machine_codex :: proc(no: u64) -> bool {
	for m in state.machines do if m.no == no do return m.codex
	return false
}


