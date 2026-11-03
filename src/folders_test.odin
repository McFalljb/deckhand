package main

// The main folder and its subfolders (folders.odin): effective paths and
// overrides, migration from notes_dir/chats_dir, detection of an existing
// notes folder, subfolders made (and nothing else touched), the
// PI_KIT_NOTES_DIR that pi tabs and jobs get, caller rules, the chats'
// AGENTS.md starter. Temp dirs and a temp HOME only.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
fo_dir :: proc() -> string {
	d := fmt.aprintf("%s/pd-folders-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(d)
	return real_path(d)
}

@(private = "file")
Fo_Saved :: struct {
	settings: Settings,
	home:     string,
	env:      string,
	login:    string,
	root:     string,
}

@(private = "file")
fo_begin :: proc(dir: string) -> Fo_Saved {
	s := Fo_Saved{settings = state.settings, home = strings.clone(os.get_env("HOME", context.temp_allocator)), env = strings.clone(os.get_env("PI_KIT_NOTES_DIR", context.temp_allocator)), login = folders_login_notes, root = home_root}
	state.settings = {}
	state.home_dir_prev = ""
	folders_login_notes = ""
	os.unset_env("PI_KIT_NOTES_DIR")
	home := fmt.tprintf("%s/home", dir)
	os.make_directory_all(home)
	os.set_env("HOME", home)
	home_root = fmt.aprintf("%s/data", dir)
	os.make_directory_all(home_root)
	return s
}

@(private = "file")
fo_end :: proc(s: Fo_Saved, dir: string) {
	state.settings = s.settings
	state.home_dir_prev = ""
	folders_login_notes = s.login
	os.set_env("HOME", s.home)
	if s.env != "" do os.set_env("PI_KIT_NOTES_DIR", s.env)
	home_root = s.root
	os.remove_all(dir)
}

@(test)
folders_effective_paths :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	home := os.get_env("HOME", context.temp_allocator)
	// nothing set: no notes folders; chats in ~/Chats as before
	for k in Folder_Kind do if k != .Chats do testing.expect_value(t, folder_of(k), "")
	testing.expect_value(t, folder_of(.Chats), fmt.tprintf("%s/Chats", home))
	testing.expect_value(t, notes_root(), "")
	// a main folder: every subfolder inside it
	state.settings.home_dir = "/m"
	testing.expect_value(t, folder_of(.Jobs), "/m/jobs")
	testing.expect_value(t, folder_of(.Sessions), "/m/sessions")
	testing.expect_value(t, folder_of(.Memory), "/m/memory")
	testing.expect_value(t, folder_of(.Atlas), "/m/atlas")
	testing.expect_value(t, folder_of(.Chats), "/m/chats")
	testing.expect_value(t, notes_root(), "/m")
	// an override wins
	state.settings.folders[.Chats] = "/elsewhere/talks"
	state.settings.folders[.Jobs] = "/j"
	testing.expect_value(t, folder_of(.Chats), "/elsewhere/talks")
	testing.expect_value(t, folder_of(.Jobs), "/j")
	testing.expect(t, folder_custom(.Chats) && !folder_custom(.Atlas))
	// pi-kit writes <PI_KIT_NOTES_DIR>/sessions/: a sessions override is that folder's parent
	state.settings.folders[.Sessions] = "/v/sessions"
	testing.expect_value(t, notes_root(), "/v")
}

@(test)
folders_commands :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	ui := Caller{kind = .UI}
	main_ := fmt.tprintf("%s/main", dir)
	os.make_directory_all(main_)
	// something of the user's in it: never touched
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", main_), transmute([]u8)string("mine"))
	os.make_directory_all(fmt.tprintf("%s/jobs", main_))
	_ = os.write_entire_file(fmt.tprintf("%s/jobs/x.md", main_), transmute([]u8)string("job"))
	// caller rules: the user's only
	for k in ([]Caller_Kind{.Control, .Script, .Panel}) {
		testing.expect_value(t, run_command(Set_Home_Dir{path = main_}, {kind = k}).error, "not allowed for this caller")
		testing.expect_value(t, run_command(Set_Folder{kind = .Jobs, path = main_}, {kind = k}).error, "not allowed for this caller")
		testing.expect_value(t, run_command(Setup_Sheet{open = true}, {kind = k}).error, "not allowed for this caller")
	}
	testing.expect_value(t, run_command(Set_Home_Dir{path = "relative"}, ui).error, "path must be absolute")
	testing.expect_value(t, run_command(Set_Home_Dir{path = fmt.tprintf("%s/nope", dir)}, ui).error, "no such folder")
	r := run_command(Set_Home_Dir{path = main_}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.settings.home_dir, main_)
	// the missing subfolders are made, empty; what was there stays
	for k in Folder_Kind do testing.expectf(t, os.is_dir(fmt.tprintf("%s/%s", main_, FOLDER_NAMES[k])), "%s/ made", FOLDER_NAMES[k])
	entries, _ := os.read_all_directory_by_path(main_, context.temp_allocator)
	testing.expect_value(t, len(entries), len(Folder_Kind) + 1) // the subfolders + README.md
	data, _ := os.read_entire_file(fmt.tprintf("%s/README.md", main_), context.temp_allocator)
	testing.expect_value(t, string(data), "mine")
	data, _ = os.read_entire_file(fmt.tprintf("%s/jobs/x.md", main_), context.temp_allocator)
	testing.expect_value(t, string(data), "job")
	mem, _ := os.read_all_directory_by_path(fmt.tprintf("%s/memory", main_), context.temp_allocator)
	testing.expect_value(t, len(mem), 0)
	// create: ~/pi-desk for a new user
	r = run_command(Set_Home_Dir{path = "~/pi-desk", create = true}, ui)
	testing.expect(t, r.ok, r.error)
	nh := fmt.tprintf("%s/pi-desk", os.get_env("HOME", context.temp_allocator))
	testing.expect_value(t, state.settings.home_dir, nh)
	testing.expect(t, os.is_dir(fmt.tprintf("%s/jobs", nh)))
	// the old main folder is offered (Reveal), never moved
	testing.expect_value(t, state.home_dir_prev, main_)
	testing.expect(t, os.exists(fmt.tprintf("%s/README.md", main_)))
	// overrides: an existing folder, or "" for the default
	other := fmt.tprintf("%s/other-jobs", dir)
	testing.expect_value(t, run_command(Set_Folder{kind = .Jobs, path = other}, ui).error, "no such folder")
	os.make_directory_all(other)
	testing.expect(t, run_command(Set_Folder{kind = .Jobs, path = other}, ui).ok)
	testing.expect_value(t, folder_of(.Jobs), other)
	testing.expect(t, run_command(Set_Folder{kind = .Jobs, path = ""}, ui).ok)
	testing.expect_value(t, folder_of(.Jobs), fmt.tprintf("%s/jobs", nh))
	// the default path given as an override stays the default
	testing.expect(t, run_command(Set_Folder{kind = .Memory, path = fmt.tprintf("%s/memory", nh)}, ui).ok)
	testing.expect(t, !folder_custom(.Memory))
	// pi-kit writes sessions/ in its notes root: a sessions folder must be named sessions
	testing.expect(t, strings.contains(run_command(Set_Folder{kind = .Sessions, path = other}, ui).error, "named sessions"))
	// chats: a folder that may not exist yet (made on the first chat)
	talks := fmt.tprintf("%s/talks", dir)
	testing.expect(t, run_command(Set_Folder{kind = .Chats, path = talks}, ui).ok)
	testing.expect_value(t, folder_of(.Chats), talks)
	// the old wire names still parse
	cmd, perr := parse_command(`{"type":"set_chats_dir","path":"/x"}`)
	testing.expect_value(t, perr, "")
	sf, is_sf := cmd.(Set_Folder)
	testing.expect(t, is_sf && sf.kind == .Chats && sf.path == "/x")
	cmd, perr = parse_command(`{"type":"set_notes_dir","path":"/x"}`)
	_, is_hd := cmd.(Set_Home_Dir)
	testing.expect(t, perr == "" && is_hd)
	cmd, perr = parse_command(`{"type":"set_folder","kind":"memory","path":""}`)
	sf, is_sf = cmd.(Set_Folder)
	testing.expect(t, perr == "" && is_sf && sf.kind == .Memory)
	// get_state shows the effective folders
	b := strings.builder_make(context.temp_allocator)
	write_state(&b, state)
	text := strings.to_string(b)
	testing.expect_value(t, json_path(text, "settings.home_dir"), nh)
	testing.expect_value(t, json_path(text, "settings.folders.jobs.path"), fmt.tprintf("%s/jobs", nh))
	testing.expect_value(t, json_path(text, "settings.folders.jobs.custom"), "false")
	testing.expect_value(t, json_path(text, "settings.folders.chats.custom"), "true")
	testing.expect_value(t, json_path(text, "settings.notes_env.value"), nh)
	testing.expect_value(t, json_path(text, "settings.notes_env.yours"), "false")
}

// An existing notes_dir becomes the main folder (no setup sheet), an
// existing chats_dir (or the old default ~/Chats) the chats override; nothing
// is made or moved.
@(test)
folders_migration :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	home := os.get_env("HOME", context.temp_allocator)
	notes := fmt.tprintf("%s/vault", dir)
	os.make_directory_all(fmt.tprintf("%s/jobs", notes))
	ws :: proc(settings: string) -> string {return fmt.tprintf(`{{"v":%d,"settings":%s}}`, WORKSPACE_VERSION, settings)}
	testing.expect_value(t, workspace_restore(ws(fmt.tprintf(`{{"notes_dir":"%s","chats_dir":"%s/talks"}}`, notes, dir))), "")
	testing.expect_value(t, state.settings.home_dir, notes)
	testing.expect_value(t, folder_of(.Jobs), fmt.tprintf("%s/jobs", notes))
	testing.expect_value(t, folder_of(.Chats), fmt.tprintf("%s/talks", dir))
	testing.expect(t, !setup_due(), "no setup sheet")
	testing.expect(t, !os.exists(fmt.tprintf("%s/sessions", notes)), "nothing made by the migration")
	// saved in the new shape
	text := workspace_json()
	testing.expect(t, strings.contains(text, `"home_dir"`) && !strings.contains(text, `"notes_dir"`), text)
	// notes_dir and no chats_dir: chats stay where they ran (~/Chats)
	state.settings = {}
	testing.expect_value(t, workspace_restore(ws(fmt.tprintf(`{{"notes_dir":"%s"}}`, notes))), "")
	testing.expect_value(t, folder_of(.Chats), fmt.tprintf("%s/Chats", home))
	// a chats_dir that is <main>/chats: the default, no override
	state.settings = {}
	testing.expect_value(t, workspace_restore(ws(fmt.tprintf(`{{"notes_dir":"%s","chats_dir":"%s/chats"}}`, notes, notes))), "")
	testing.expect(t, !folder_custom(.Chats))
	// no notes_dir: the setup sheet is due, once
	state.settings = {}
	testing.expect_value(t, workspace_restore(ws(fmt.tprintf(`{{"chats_dir":"%s/talks"}}`, dir))), "")
	testing.expect(t, setup_due())
	testing.expect_value(t, folder_of(.Chats), fmt.tprintf("%s/talks", dir))
	run_command(Setup_Sheet{open = false}, {kind = .UI})
	testing.expect(t, !setup_due(), "skipped: not again")
	text = workspace_json()
	state.settings = {}
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect(t, !setup_due(), "skipped: saved")
	// the new shape round-trips
	state.settings = {}
	testing.expect_value(t, workspace_restore(ws(fmt.tprintf(`{{"home_dir":"%s","folders":{{"memory":"%s/mem"}}}}`, notes, dir))), "")
	testing.expect_value(t, folder_of(.Memory), fmt.tprintf("%s/mem", dir))
	testing.expect_value(t, folder_of(.Chats), fmt.tprintf("%s/chats", notes))
}

@(test)
folders_detect :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	defer os.remove_all(dir)
	vault := fmt.tprintf("%s/notes/agents-demo", dir)
	repo := fmt.tprintf("%s/code/repo", dir)
	os.make_directory_all(fmt.tprintf("%s/sessions", vault))
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", vault), transmute([]u8)string("rules"))
	os.make_directory_all(repo)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", repo), transmute([]u8)string("repo"))
	agents := fmt.tprintf("%s/AGENTS.md", dir)
	text := fmt.tprintf("# rules\n\nWork in `%s` (a repo).\n- Notes live in `%s/`, shared with pi.\n- Not there: /no/such/place.\n", repo, vault)
	_ = os.write_entire_file(agents, transmute([]u8)text)
	// a folder with sessions/, not one with only a README.md
	p, why := detect_notes_folder("", agents)
	testing.expect_value(t, p, vault)
	testing.expect(t, strings.contains(why, "AGENTS.md"), why)
	// PI_KIT_NOTES_DIR first
	p, why = detect_notes_folder(repo, agents)
	testing.expect_value(t, p, repo)
	testing.expect(t, strings.contains(why, "PI_KIT_NOTES_DIR"), why)
	// a PI_KIT_NOTES_DIR that is not there: the file
	p, _ = detect_notes_folder("/no/such", agents)
	testing.expect_value(t, p, vault)
	// a README-only folder is not offered (review round 1); nothing at all: ""
	_ = os.write_entire_file(agents, transmute([]u8)fmt.tprintf("see %s.\n", repo))
	p, _ = detect_notes_folder("", agents)
	testing.expect_value(t, p, "")
	_ = os.write_entire_file(agents, transmute([]u8)string("nothing here /tmp/x\n"))
	p, why = detect_notes_folder("", agents)
	testing.expect_value(t, p, "")
	p, _ = detect_notes_folder("", fmt.tprintf("%s/missing.md", dir))
	testing.expect_value(t, p, "")
}

// pi tabs and job runs get PI_KIT_NOTES_DIR=<main folder>, unless the
// user's own environment (pi-desk's, or the login shell's) sets it.
@(test)
folders_notes_env :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	testing.expect_value(t, notes_env_pi(), "")
	testing.expect_value(t, notes_env_job(), "")
	state.settings.home_dir = "/m"
	testing.expect_value(t, notes_env_pi(), "PI_KIT_NOTES_DIR=/m")
	testing.expect_value(t, notes_env_job(), "PI_KIT_NOTES_DIR=/m")
	// the login shell's wins
	folders_login_notes = "/theirs"
	testing.expect_value(t, notes_env_pi(), "") // their shell sets it in the tab
	testing.expect_value(t, notes_env_job(), "PI_KIT_NOTES_DIR=/theirs") // jobs get a clean env: theirs
	folders_login_notes = ""
	// pi-desk's own environment wins (the tab inherits it)
	os.set_env("PI_KIT_NOTES_DIR", "/env")
	defer os.unset_env("PI_KIT_NOTES_DIR")
	testing.expect_value(t, notes_env_pi(), "")
	testing.expect_value(t, notes_env_job(), "PI_KIT_NOTES_DIR=/env")
	testing.expect_value(t, notes_env_user(), "/env")
	// the env a pi tab starts with
	os.unset_env("PI_KIT_NOTES_DIR")
	env := child_env(pi_extra_env(nil))
	n := 0
	for e in env do if strings.has_prefix(e, "PI_KIT_NOTES_DIR=") {
		n += 1
		testing.expect_value(t, e, "PI_KIT_NOTES_DIR=/m")
	}
	testing.expect_value(t, n, 1)
}

// The chats folder's AGENTS.md: written when missing, never over a file,
// an unedited older starter upgraded (with a .bak).
@(test)
folders_chats_instructions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	talks := fmt.tprintf("%s/talks", dir)
	p := fmt.tprintf("%s/AGENTS.md", talks)
	// no folder yet: nothing made at startup
	state.settings.folders[.Chats] = strings.clone(talks)
	chats_instructions_ensure("2026-11-01")
	testing.expect(t, !os.exists(talks), "the folder is not made at startup")
	// the folder there: the starter
	os.make_directory_all(talks)
	chats_instructions_ensure("2026-11-01")
	data, _ := os.read_entire_file(p, context.temp_allocator)
	testing.expect_value(t, string(data), CHATS_AGENTS_STARTER)
	// edited: kept
	_ = os.write_entire_file(p, transmute([]u8)string("# my chat rules\n"))
	chats_instructions_ensure("2026-11-01")
	data, _ = os.read_entire_file(p, context.temp_allocator)
	testing.expect_value(t, string(data), "# my chat rules\n")
	// an unedited older starter: replaced, the old one kept as .bak-<date>
	old := "# Chats (an older starter)\n"
	testing.expect(t, chats_instructions_upgrade(p, "2026-11-01", {old}) == false, "an edited file is not an old starter")
	_ = os.write_entire_file(p, transmute([]u8)old)
	testing.expect(t, chats_instructions_upgrade(p, "2026-11-01", {old}))
	data, _ = os.read_entire_file(p, context.temp_allocator)
	testing.expect_value(t, string(data), CHATS_AGENTS_STARTER)
	bak, _ := os.read_entire_file(fmt.tprintf("%s.bak-2026-11-01", p), context.temp_allocator)
	testing.expect_value(t, string(bak), old)
	// a new chats folder gets one when it is set
	other := fmt.tprintf("%s/other", dir)
	os.make_directory_all(other)
	testing.expect(t, run_command(Set_Folder{kind = .Chats, path = other}, {kind = .UI}).ok)
	testing.expect(t, os.exists(fmt.tprintf("%s/AGENTS.md", other)))
	// shown in the Settings tab's Chats group (Create when missing)
	found := false
	for r in settings_file_rows() do if r.group == "chats" && r.path == fmt.tprintf("%s/AGENTS.md", other) do found = true
	testing.expect(t, found, "Settings: Chat instructions")
	// and in the Folders group
	folders_row := false
	for r in settings_file_rows() do if r.group == "folders" && r.path == folder_row_path(.Jobs) do folders_row = true
	testing.expect(t, folders_row, "Settings: Folders")
}

// Review round 1: a chats folder that is $HOME, / or holds a project or a
// job's folder gets no starter AGENTS.md (pi applies it to every folder
// below: "not a coding agent" would reach those pi tabs). The Settings tab's
// Chat instructions row stays (Create is the user's explicit choice).
@(test)
folders_chats_instructions_not_too_wide :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	home := os.get_env("HOME", context.temp_allocator)
	// chats = $HOME (an old chats_dir carried over): nothing written
	state.settings.folders[.Chats] = strings.clone(home)
	chats_instructions_ensure("2026-11-01")
	testing.expect(t, !os.exists(fmt.tprintf("%s/AGENTS.md", home)), "no starter in $HOME")
	found := false
	for r in settings_file_rows() do if r.group == "chats" && r.path == fmt.tprintf("%s/AGENTS.md", home) do found = true
	testing.expect(t, found, "the Chat instructions row is still shown")
	// chats = a folder that holds a known project: nothing written
	work := fmt.tprintf("%s/work", dir)
	repo := fmt.tprintf("%s/repo", work)
	os.make_directory_all(repo)
	saved_projects := state.projects
	state.projects = {}
	defer {
		delete(state.projects)
		state.projects = saved_projects
	}
	append(&state.projects, Project{group = .Projects, cwd = repo})
	state.settings.folders[.Chats] = strings.clone(work)
	chats_instructions_ensure("2026-11-01")
	testing.expect(t, !os.exists(fmt.tprintf("%s/AGENTS.md", work)), "no starter above a project")
	// the project itself as the chats folder: nothing either
	state.settings.folders[.Chats] = strings.clone(repo)
	chats_instructions_ensure("2026-11-01")
	testing.expect(t, !os.exists(fmt.tprintf("%s/AGENTS.md", repo)), "no starter in a project")
	// a folder beside the project: the starter
	talks := fmt.tprintf("%s/talks", dir)
	os.make_directory_all(talks)
	state.settings.folders[.Chats] = strings.clone(talks)
	chats_instructions_ensure("2026-11-01")
	testing.expect(t, os.exists(fmt.tprintf("%s/AGENTS.md", talks)), "a plain chats folder gets the starter")
	// the root: never (checked without writing there)
	testing.expect(t, chats_folder_too_wide("/"), "/ is too wide")
	testing.expect(t, chats_folder_too_wide(home), "$HOME is too wide")
	testing.expect(t, !chats_folder_too_wide(talks), "talks is fine")
}

// Review round 1: detection never offers pi's agent folder (it has
// sessions/) or a folder above it, $HOME, /, or a git checkout; a folder
// with only a README.md is no longer offered.
@(test)
folders_detect_not_wrong :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	home := os.get_env("HOME", context.temp_allocator)
	agent := fmt.tprintf("%s/.pi/agent", home)
	os.make_directory_all(fmt.tprintf("%s/sessions", agent))
	os.make_directory_all(fmt.tprintf("%s/sessions", home))
	repo := fmt.tprintf("%s/code/repo", dir)
	os.make_directory_all(fmt.tprintf("%s/sessions", repo))
	os.make_directory_all(fmt.tprintf("%s/.git", repo))
	readme := fmt.tprintf("%s/docs", dir)
	os.make_directory_all(readme)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", readme), transmute([]u8)string("x"))
	agents := fmt.tprintf("%s/AGENTS.md", agent)
	try :: proc(agents, text: string) -> string {
		_ = os.write_entire_file(agents, transmute([]u8)text)
		p, _ := detect_notes_folder("", agents)
		return p
	}
	testing.expect_value(t, try(agents, fmt.tprintf("pi keeps sessions in %s/\n", agent)), "")
	testing.expect_value(t, try(agents, "pi keeps sessions in ~/.pi/agent/sessions and ~/.pi\n"), "")
	testing.expect_value(t, try(agents, "Home: ~/ and ~\n"), "")
	testing.expect_value(t, try(agents, fmt.tprintf("Home: %s\n", home)), "")
	testing.expect_value(t, try(agents, fmt.tprintf("Work in %s\n", repo)), "")
	testing.expect_value(t, try(agents, fmt.tprintf("Docs in %s\n", readme)), "")
	// the vault is still found among them
	vault := fmt.tprintf("%s/notes/agents-demo", dir)
	os.make_directory_all(fmt.tprintf("%s/sessions", vault))
	testing.expect_value(t, try(agents, fmt.tprintf("%s %s %s %s\n", agent, repo, readme, vault)), vault)
}

// Review round 1: detection reads only ~/.pi/agent/AGENTS.md, never
// CLAUDE.md or AGENTS.override.md.
@(test)
folders_detect_reads_only_agents_md :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	old_cad := strings.clone(os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator))
	os.unset_env("PI_CODING_AGENT_DIR")
	defer if old_cad != "" do os.set_env("PI_CODING_AGENT_DIR", old_cad)
	home := os.get_env("HOME", context.temp_allocator)
	agent := fmt.tprintf("%s/.pi/agent", home)
	os.make_directory_all(agent)
	vault := fmt.tprintf("%s/notes/agents-demo", dir)
	os.make_directory_all(fmt.tprintf("%s/sessions", vault))
	for name in ([]string{"CLAUDE.md", "AGENTS.override.md"}) {
		p := fmt.tprintf("%s/%s", agent, name)
		_ = os.write_entire_file(p, transmute([]u8)fmt.tprintf("Notes live in %s\n", vault))
		got, _ := setup_detect()
		testing.expectf(t, got == "", "%s is not read: got %q", name, got)
		os.remove(p)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/AGENTS.md", agent), transmute([]u8)fmt.tprintf("Notes live in %s\n", vault))
	got, _ := setup_detect()
	testing.expect_value(t, got, vault)
}

// Review round 1: Done keeps the sheet open (setup not marked seen) when
// the main folder cannot be set, and says why.
@(test)
folders_setup_done_fails :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fo_dir()
	saved := fo_begin(dir)
	defer fo_end(saved, dir)
	saved_focus := state.focus_widget
	state.focus_widget = ""
	defer {
		delete(state.focus_widget)
		state.focus_widget = saved_focus
	}
	inbox_drain()
	testing.expect(t, run_command(Setup_Sheet{open = true}, {kind = .UI}).ok)
	gone := fmt.tprintf("%s/gone", dir)
	setup_picked(false, gone) // a picked folder, removed before Done
	setup_ui.separate = false
	setup_ui.step = SETUP_STEPS - 1
	e := sapp.Event{type = .KEY_DOWN, key_code = .ENTER}
	setup_event(&e)
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "setup")
	testing.expect(t, !state.settings.setup_seen, "not marked seen")
	testing.expect_value(t, state.settings.home_dir, "")
	testing.expect(t, setup_ui.err != "", "the error shows in the sheet")
	// the folder there: Done closes it
	os.make_directory_all(gone)
	setup_event(&e)
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "")
	testing.expect(t, state.settings.setup_seen, "seen")
	testing.expect_value(t, state.settings.home_dir, gone)
	testing.expect_value(t, setup_ui.err, "")
}
