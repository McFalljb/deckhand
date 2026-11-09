package core

// The main folder (Settings.home_dir) and its standard subfolders:
//
//   <main>/sessions/   session notes (pi-kit writes <PI_KIT_NOTES_DIR>/sessions/)
//   <main>/jobs/       Atlas's job notes (jobs.odin)
//   <main>/memory/     memory notes (planned)
//   <main>/atlas/      Atlas's prompt ATLAS.md, HEARTBEAT.md (agent.odin)
//   <main>/chats/      where chats run (sessions.odin), with their AGENTS.md
//
// Each subfolder may be overridden (Settings.folders, user-only); the
// effective path is the override, else <main>/<name> (folder_of). Without a
// main folder there are no notes folders (jobs wait for one) and chats run
// in ~/Chats, as before. Setting the main folder makes the missing standard
// subfolders, empty; nothing else in it is touched, and nothing is ever
// moved. The first-run sheet (ui_setup.odin) sets it up.
//
// pi tabs and job runs get PI_KIT_NOTES_DIR=<main folder> (pi-kit's notes
// root, the parent of the sessions folder) unless the user's own
// environment sets it: theirs wins.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Folder_Kind :: enum u8 {
	Sessions,
	Jobs,
	Memory,
	Atlas,
	Chats,
}

FOLDER_NAMES := [Folder_Kind]string {
	.Sessions = "sessions",
	.Jobs     = "jobs",
	.Memory   = "memory",
	.Atlas    = "atlas",
	.Chats    = "chats",
}

// What each subfolder holds (the Settings tab, the setup summary).
FOLDER_DOES := [Folder_Kind]string {
	.Sessions = "session notes (pi-kit)",
	.Jobs     = "Atlas's job notes",
	.Memory   = "memory notes",
	.Atlas    = "Atlas's prompt",
	.Chats    = "where chats run",
}

// User-only: the main folder ("" = not set). create: make it first (the
// setup sheet's "Create ~/Deckhand").
Set_Home_Dir :: struct {
	path:   string,
	create: bool,
	setup:  bool, // the setup sheet's Done (UI only): closes it when this succeeds, else shows why there
}
// User-only: a subfolder's override ("" = <main>/<name>).
Set_Folder :: struct {
	kind: Folder_Kind,
	path: string,
}
// User-only: the first-run sheet opens; closing it (Done or Skip) marks
// setup as seen, so it does not open by itself again.
Setup_Sheet :: struct {
	open: bool,
}

// PI_KIT_NOTES_DIR in the user's login shell (jobs.odin reads it once at
// start; "" = unset or not known yet).
folders_login_notes: string

// The effective path of a subfolder for these settings (temp allocator).
folder_path :: proc(st: Settings, k: Folder_Kind) -> string {
	if st.folders[k] != "" do return st.folders[k]
	if st.home_dir != "" do return fmt.tprintf("%s/%s", st.home_dir, FOLDER_NAMES[k])
	if k == .Chats do return fmt.tprintf("%s/Chats", os.get_env("HOME", context.temp_allocator))
	return ""
}

folder_of :: proc(k: Folder_Kind) -> string {return folder_path(state.settings, k)}
folder_custom :: proc(k: Folder_Kind) -> bool {return state.settings.folders[k] != ""}

// The folder is set and can be reached (its override, or the main folder).
folder_reachable :: proc(k: Folder_Kind) -> bool {
	if o := state.settings.folders[k]; o != "" do return os.is_dir(o)
	return state.settings.home_dir != "" && os.is_dir(state.settings.home_dir)
}

// pi-kit's notes root (PI_KIT_NOTES_DIR as Deckhand passes it): the sessions
// folder's parent, so pi-kit's sessions/ is ours ("" = none).
notes_root :: proc() -> string {
	s := folder_of(.Sessions)
	if s == "" || filepath.base(s) != "sessions" do return ""
	return filepath.dir(s)
}

// The user's own PI_KIT_NOTES_DIR: Deckhand's environment, else the login shell's.
notes_env_user :: proc() -> string {
	if v := os.get_env("PI_KIT_NOTES_DIR", context.temp_allocator); v != "" do return v
	return folders_login_notes
}

// The entry a pi tab gets ("" = none: the user's own wins, it reaches the
// tab through Deckhand's environment or the login shell).
notes_env_pi :: proc() -> string {
	if notes_env_user() != "" do return ""
	if r := notes_root(); r != "" do return fmt.tprintf("PI_KIT_NOTES_DIR=%s", r)
	return ""
}

// The entry a job run gets (its environment is an allowlist): the user's, else ours.
notes_env_job :: proc() -> string {
	if u := notes_env_user(); u != "" do return fmt.tprintf("PI_KIT_NOTES_DIR=%s", u)
	if r := notes_root(); r != "" do return fmt.tprintf("PI_KIT_NOTES_DIR=%s", r)
	return ""
}

// A pi tab's extra environment plus PI_KIT_NOTES_DIR (temp allocator).
pi_extra_env :: proc(env: []string) -> []string {
	n := notes_env_pi()
	if n == "" do return env
	out := make([]string, len(env) + 1, context.temp_allocator)
	copy(out, env)
	out[len(env)] = n
	return out
}

// The first-run sheet opens by itself: no main folder, never set up or skipped.
setup_due :: proc() -> bool {return state.settings.home_dir == "" && !state.settings.setup_seen}

// The Settings tab's row for a folder (not a file).
folder_row_path :: proc(k: Folder_Kind) -> string {return fmt.tprintf("deckhand:folder:%s", FOLDER_NAMES[k])}
FOLDER_MAIN_ROW :: "deckhand:folder:main"
FOLDER_PREV_ROW :: "deckhand:folder:previous"
FOLDER_ENV_ROW :: "deckhand:folder:env"

// The folder kind of a Settings row path, or false.
folder_row_kind :: proc(path: string) -> (Folder_Kind, bool) {
	for k in Folder_Kind do if path == folder_row_path(k) do return k, true
	return {}, false
}

// ~/x -> $HOME/x; then absolute and clean, or an error (also the setup sheet's typed account folder).
folder_arg :: proc(p: string) -> (string, string) {
	path := strings.trim_space(p)
	if path == "" do return "", ""
	if path == "~" || strings.has_prefix(path, "~/") do path = strings.concatenate({os.get_env("HOME", context.temp_allocator), path[1:]}, context.temp_allocator)
	if !filepath.is_abs(path) do return "", "path must be absolute"
	path, _ = filepath.clean(path, context.temp_allocator)
	return path, ""
}

// Makes the main folder's missing standard subfolders (not overridden
// ones), empty. Nothing else in it is touched.
folders_make :: proc() {
	h := state.settings.home_dir
	if h == "" || !os.is_dir(h) do return
	for k in Folder_Kind {
		if state.settings.folders[k] != "" do continue
		p := fmt.tprintf("%s/%s", h, FOLDER_NAMES[k])
		if !os.exists(p) do os.make_directory(p)
	}
}

// Today as YYYY-MM-DD (local), for .bak names.
date_stamp :: proc() -> string {
	y, m, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
}

// After a folder changed: Atlas's prompt follows (a copy, §8), the jobs are
// read again, the Settings tab rebuilt, and a new chats folder leaves the
// project list (the old one becomes an ordinary project) and gets its
// instructions.
@(private = "file")
folders_changed :: proc(chats_before: string) {
	if folder_reachable(.Atlas) {
		if path_kind(agent_prompt_data_path()) == .File do agent_prompt_ensure()
		agent_prompt_migrate(date_stamp())
	}
	jobs_scan(true)
	settings_gen += 1
	if chats_cwd() != chats_before {
		rescan_now()
		chats_instructions_ensure(date_stamp())
	}
}

// Set_Home_Dir: the main folder (folders_apply).
@(private = "file")
home_dir_apply :: proc(c: Set_Home_Dir, caller: Caller) -> (r: Result, changed: bool) {
	path, err := folder_arg(c.path)
	if err != "" do return fail(err), false
	if l := claude_account_holding(path); l != "" && caller.kind != .Internal do return fail(fmt.tprintf("that folder is inside the Claude account %s's config folder (Settings → Claude accounts)", l)), false
	if path != "" {
		if c.create do os.make_directory_all(path)
		// a saved main folder on a drive that is not there stays set
		if !os.is_dir(path) && caller.kind != .Internal do return fail("no such folder"), false
	}
	before := strings.clone(chats_cwd(), context.temp_allocator)
	if path != state.settings.home_dir {
		if old := state.settings.home_dir; old != "" {
			delete(state.home_dir_prev)
			state.home_dir_prev = strings.clone(old) // offered in Finder, never moved
		}
		delete(state.settings.home_dir)
		state.settings.home_dir = strings.clone(path)
		// an override that is the new default is the default
		for k in Folder_Kind do if path != "" && state.settings.folders[k] == fmt.tprintf("%s/%s", path, FOLDER_NAMES[k]) {
			delete(state.settings.folders[k])
			state.settings.folders[k] = ""
		}
		changed = true
	}
	if caller.kind != .Internal {
		folders_make()
		chats_instructions_ensure(date_stamp())
	}
	if changed do folders_changed(before)
	return {ok = true}, changed
}

folders_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	if c, ok := cmd.(Set_Home_Dir); ok && c.setup {
		r, changed = home_dir_apply(c, caller)
		if !r.ok {
			window_setup_sheet(.Failed, r.error)
			return
		}
		cr, cch := folders_apply(Setup_Sheet{open = false}, caller)
		return cr, changed || cch
	}
	#partial switch c in cmd {
	case Set_Home_Dir:
		return home_dir_apply(c, caller)
	case Set_Folder:
		path, err := folder_arg(c.path)
		if err != "" do return fail(err), false
		if path != "" {
			if l := claude_account_holding(path); l != "" && caller.kind != .Internal do return fail(fmt.tprintf("that folder is inside the Claude account %s's config folder (Settings → Claude accounts)", l)), false
			if c.kind == .Sessions && filepath.base(path) != "sessions" do return fail("pi-kit writes session notes to <notes root>/sessions/: pick a folder named sessions"), false
			if c.kind == .Chats do path = real_path(path) // pi's cwd, and so its store dir, has no symlinks; made on the first chat
			else if !os.is_dir(path) && caller.kind != .Internal do return fail("no such folder"), false
			if h := state.settings.home_dir; h != "" && path == fmt.tprintf("%s/%s", h, FOLDER_NAMES[c.kind]) do path = ""
		}
		if path == state.settings.folders[c.kind] {
			if caller.kind != .Internal do folders_make()
			return {ok = true}, false
		}
		before := strings.clone(chats_cwd(), context.temp_allocator)
		delete(state.settings.folders[c.kind])
		state.settings.folders[c.kind] = strings.clone(path)
		if caller.kind != .Internal do folders_make() // back to the default: made if missing
		folders_changed(before)
		return {ok = true}, true
	case Setup_Sheet:
		if !c.open && harness_run_holds_sheet() do return fail("an install is running on the setup sheet: wait for it, or ⌃C in its terminal"), false
		if c.open {
			window_setup_sheet(.Begin)
			if state.focus_widget != "setup" {
				delete(state.focus_widget)
				state.focus_widget = strings.clone("setup")
			}
			return {ok = true}, true
		}
		if state.focus_widget == "setup" {
			delete(state.focus_widget)
			state.focus_widget = ""
		}
		state.settings.setup_seen = true
		return {ok = true}, true
	}
	return fail("unknown command"), false
}

// ---- finding an existing notes folder (the setup sheet's first choice) ----

// Where the user keeps notes already: PI_KIT_NOTES_DIR when it is a folder,
// else the first absolute path named in pi's global AGENTS.md that is a
// folder with a sessions/ folder, and not pi's agent folder or a folder
// above it, $HOME, / or a git checkout (no suggestion beats a wrong one).
// why says how it was found ("" path = none).
detect_notes_folder :: proc(env_value, agents_md: string) -> (path: string, why: string) {
	if env_value != "" && os.is_dir(env_value) do return env_value, "PI_KIT_NOTES_DIR is set to it"
	if settings_credential(agents_md) do return "", "" // never a sign-in or Claude's state, by any name
	if k, st := path_stat(agents_md); k != .File || st.size > 1 << 20 do return "", ""
	data, err := os.read_entire_file(agents_md, context.temp_allocator)
	if err != nil do return "", ""
	home := os.get_env("HOME", context.temp_allocator)
	// pi's agent folder (it has sessions/ too) and every folder above it
	agent_dirs := [2]string{agents_md[:max(strings.last_index_byte(agents_md, '/'), 0)], pi_agent_dir()}
	never :: proc(p, home: string, agent_dirs: []string) -> bool {
		if p == "/" || p == home || p == real_path(home) do return true
		for a in agent_dirs do if a != "" && (path_under(a, p) || path_under(real_path(a), p)) do return true
		return os.exists(fmt.tprintf("%s/.git", p))
	}
	is_sep :: proc(r: rune) -> bool {
		switch r {
		case ' ', '\t', '\n', '\r', '`', '"', '\'', '(', ')', '[', ']', '<', '>', ',', ';', '|', '*':
			return true
		}
		return false
	}
	text := string(data)
	for len(text) > 0 {
		i := 0
		for i < len(text) && is_sep(rune(text[i])) do i += 1
		j := i
		for j < len(text) && !is_sep(rune(text[j])) do j += 1
		tok := text[i:j]
		text = text[j:]
		if len(tok) > 1024 || !(strings.has_prefix(tok, "/") || strings.has_prefix(tok, "~/")) do continue
		tok = strings.trim_right(tok, ".:!?_")
		if strings.has_prefix(tok, "~/") {
			if home == "" do continue
			tok = strings.concatenate({home, tok[1:]}, context.temp_allocator)
		}
		p, _ := filepath.clean(tok, context.temp_allocator)
		if !os.is_dir(p) || never(p, home, agent_dirs[:]) do continue
		if os.is_dir(fmt.tprintf("%s/sessions", p)) do return p, fmt.tprintf("named in %s; it has a sessions/ folder", fs_display(agents_md))
	}
	return "", ""
}

// q is p or inside it (clean absolute paths).
path_under :: proc(q, p: string) -> bool {
	if p == "/" do return strings.has_prefix(q, "/")
	return q == p || strings.has_prefix(q, p) && len(q) > len(p) && q[len(p)] == '/'
}

// The detection for this machine: the user's PI_KIT_NOTES_DIR, else pi's
// global AGENTS.md (only that file: never pi's CLAUDE.md or an override),
// else Claude Code's global CLAUDE.md (its config folder's: CLAUDE_CONFIG_DIR
// or ~/.claude; that folder, which has a sessions/ of its own, is never the
// answer). Read in Deckhand only; the sheet shows only the path found.
setup_detect :: proc() -> (string, string) {
	if p, why := detect_notes_folder(notes_env_user(), fmt.tprintf("%s/AGENTS.md", pi_agent_dir())); p != "" do return p, why
	if cd := claude_config_dir(); cd != "" do return detect_notes_folder("", fmt.tprintf("%s/CLAUDE.md", cd))
	return "", ""
}

// The setup sheet's line about the harnesses (pi_installed, claude_installed: looked for, never
// run; harness.odin): which are installed, and what that means.
setup_claude_line :: proc() -> string {
	pi, claude := pi_installed(), claude_installed()
	if !pi && !claude do return NO_HARNESS
	if claude {
		// one account (a config folder there): which; several: the step before listed them
		which := "Claude Code is installed"
		if accts := claude_accounts(); len(accts) == 1 && path_kind(accts[0].dir) == .Dir do which = fmt.tprintf("Claude Code is installed (its account: %s)", path_tilde(accts[0].dir))
		if !pi do return fmt.tprintf("%s: New session starts it. pi isn't installed (optional: Atlas and jobs run on pi).", which)
		return fmt.tprintf("%s, and pi: New session asks which one to start.%s", which, pi_setup_note())
	}
	return fmt.tprintf("Claude Code isn't installed (optional): install it to open Claude tabs and sessions; everything else works without it.%s", pi_setup_note()) // here pi is installed (neither: NO_HARNESS above)
}

// ---- the chats' instructions (pi reads AGENTS.md from its cwd) ----

CHATS_AGENTS_STARTER :: `# Chats

This folder is where the user chats with pi outside any project. Here you are a
conversation partner and researcher, not a coding agent.

## Default to talking, not building
- Answer the question asked: explain, compare, summarise, brainstorm, plan.
- Lead with the answer, then the reasoning. Plain language; short paragraphs.
- Don't create, edit or run files unless the user asks for that. If a request
  really is a coding task, say so and suggest opening it in a project instead.
- The coding workflow rules in the global AGENTS.md (worktrees, delegating to
  workers, review gates, session notes) don't apply in chats unless the user
  asks for coding work.

## Look things up
- For anything recent, factual, niche or checkable, search the web with the
  web search and fetch tools you have (pi has none built in: extensions or MCP
  servers add them; say so if you have none) instead of answering from
  memory. Read the sources, then answer.
- Cite sources as links next to the claims they support. Say when sources
  disagree or when you couldn't verify something.
- Prefer primary sources (official docs, papers, filings) over summaries.

## Show, don't just tell
- Use a diagram when structure, flow, sequence or comparison matters. The
  answer is read in a terminal, so draw with Unicode box characters inside a
  code block:

      ┌─────────┐    request    ┌─────────┐
      │ Client  │ ────────────▶ │ Server  │
      └─────────┘ ◀──────────── └─────────┘
                    response

- Use markdown tables for comparisons, numbered steps for procedures, and
  short code snippets only when they explain something.
- Use a mermaid block only if the user asks for one (the terminal shows it as
  text).

## Keep it a conversation
- Ask one clarifying question when the request is ambiguous; otherwise make a
  sensible assumption and say what it was.
- Offer a next step or a deeper dive at the end, in one line.
`

// Earlier starters, byte for byte: an unedited copy of one is replaced by
// the current starter (kept as AGENTS.md.bak-<date>). Add the old text here
// whenever CHATS_AGENTS_STARTER changes.
CHATS_AGENTS_OLD_STARTERS := []string{}

// A chats folder that is $HOME, / or holds (or is) a project's or a job's
// folder: pi applies its AGENTS.md to every folder below, so the starter
// ("not a coding agent") would reach those pi tabs. No starter there; the
// Settings tab's Chat instructions row still offers Create.
chats_folder_too_wide :: proc(d: string) -> bool {
	if d == "" || d == "/" do return true
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && (d == home || d == real_path(home)) do return true
	for p in state.projects do if p.group == .Projects && p.machine == 0 && p.cwd != "" && path_under(p.cwd, d) do return true
	for f in jobs_folders() do if path_under(f, d) || path_under(real_path(f), d) do return true
	return false
}

// The chats folder's AGENTS.md (temp allocator).
chats_instructions_path :: proc() -> string {return fmt.tprintf("%s/AGENTS.md", chats_cwd())}

// At startup, setup and when the chats folder changes: the starter in a
// chats folder that exists and has no instructions file pi reads (never
// over a file: O_EXCL; never beside an AGENTS.override.md or CLAUDE.md,
// which pi would read instead); an unedited older starter is upgraded.
chats_instructions_ensure :: proc(today: string) {
	d := chats_cwd()
	if !os.is_dir(d) || chats_folder_too_wide(d) do return
	p := fmt.tprintf("%s/AGENTS.md", d)
	if path_kind(p) == .File {
		chats_instructions_upgrade(p, today, CHATS_AGENTS_OLD_STARTERS)
		return
	}
	if context_file(d) != "" do return
	f, err := os.open(p, {.Write, .Create, .Excl}, os.perm_number(0o644))
	if err != nil do return
	_, werr := os.write_string(f, CHATS_AGENTS_STARTER)
	os.close(f)
	if werr != nil do os.remove(p)
}

// An AGENTS.md that is byte for byte an older starter becomes the current
// one; the old text stays as <path>.bak-<today>. True when it replaced it.
chats_instructions_upgrade :: proc(path, today: string, olds: []string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	old := false
	for x in olds do if string(data) == x do old = true
	if !old do return false
	bak := fmt.tprintf("%s.bak-%s", path, today)
	if os.exists(bak) do return false
	if os.write_entire_file(bak, data) != nil do return false
	return os.write_entire_file(path, transmute([]u8)string(CHATS_AGENTS_STARTER)) == nil
}
