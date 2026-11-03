package main

// Settings files (settings_files.odin): what the ⌘, sheet lists under a fake
// HOME, credential files refused by the list and the editor, the JSON check
// on save, the reload offer after saving a pi file. Everything runs under a
// temp HOME with a fake ~/.pi/agent: the user's real files are never read.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
SECRET :: "sk-" + "DUMMY-SECRET-123" // in pieces: no whole key-shaped string in the source

// A clean State, a temp HOME with ~/.pi/agent (settings.json with two
// packages, auth.json holding a dummy secret, other private files, an
// extension's config), one open session in a project folder. Returns
// HOME and the project folder.
@(private = "file")
setup :: proc() -> (home, proj: string) {
	context.allocator = runtime.heap_allocator()
	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids do editor_drop(id)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	reload_watch_reset()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	base := fmt.tprintf("%s/pi-desk-settings-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	ad := fmt.tprintf("%s/home/.pi/agent", base)
	os.make_directory_all(fmt.tprintf("%s/extensions/subagent", ad))
	os.make_directory_all(fmt.tprintf("%s/intercom", ad))
	os.make_directory_all(fmt.tprintf("%s/prompts", ad))
	os.make_directory_all(fmt.tprintf("%s/home/proj", base))
	home = fs_real(fmt.tprintf("%s/home", base), context.allocator)
	proj = fs_real(fmt.tprintf("%s/home/proj", base), context.allocator)
	ensure(strings.contains(home, "/pi-desk-settings-test-"), "settings tests: no temp HOME") // never the user's ~/.pi
	os.set_env("HOME", home)
	home_root = fmt.aprintf("%s/data", base) // Atlas's prompt file: the Settings tab's Atlas group
	os.unset_env("PI_CODING_AGENT_DIR")
	os.unset_env("XDG_CONFIG_HOME")
	ad = fmt.tprintf("%s/.pi/agent", home)
	write_mode(fmt.tprintf("%s/settings.json", ad), `{"defaultModel": "x", "packages": ["npm:pi-subagents@1.2.3", {"source": "../../pkgs/pi-kit"}]}`, 0o644)
	write_mode(fmt.tprintf("%s/models.json", ad), `{"providers": {}}`, 0o600) // pi may make it private: still a config file
	write_mode(fmt.tprintf("%s/auth.json", ad), fmt.tprintf(`{{"anthropic":{{"key":"%s"}}}}`, SECRET), 0o600)
	write_mode(fmt.tprintf("%s/models-store.json", ad), "{}", 0o600)
	write_mode(fmt.tprintf("%s/cursor-sdk-x.json", ad), "{}", 0o644)
	write_mode(fmt.tprintf("%s/private-thing.json", ad), "{}", 0o600)
	write_mode(fmt.tprintf("%s/intercom/inbox.json", ad), "{}", 0o644)
	write_mode(fmt.tprintf("%s/extensions/subagent/config.json", ad), `{"compact": true}`, 0o644)
	append(&state.projects, Project{id = new_id(), cwd = proj, label = "proj"})
	state.selected_project = state.projects[0].id
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("s-1"), project_id = state.projects[0].id, cwd = proj}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	return
}

@(private = "file")
write_mode :: proc(path, text: string, mode: int) {
	_ = os.write_entire_file(path, transmute([]u8)text)
	os.change_mode(path, os.perm_number(mode))
}

@(private = "file")
read :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

@(private = "file")
ui :: Caller{kind = .UI}

@(test)
settings_files_list :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	rows := settings_file_rows()
	b := strings.builder_make(context.temp_allocator)
	for r in rows do fmt.sbprintf(&b, "%s|%s|%s|%v\n", r.group, r.label, fs_display(r.path), r.exists)
	got := strings.to_string(b)
	want := []string {
		"pi|settings.json|~/.pi/agent/settings.json|true",
		"pi|models.json|~/.pi/agent/models.json|true",
		"pi|prompts|~/.pi/agent/prompts|true",
		"pi|extensions|~/.pi/agent/extensions|true",
		"project|.pi/settings.json|~/proj/.pi/settings.json|false", // offered: Create
		"project|AGENTS.md|~/proj/AGENTS.md|false",
		"ext|pi-subagents config|~/.pi/agent/extensions/subagent/config.json|true",
		"ext|subagent|~/.pi/agent/extensions/subagent|true", // the local extension's folder
	}
	for w in want do testing.expectf(t, strings.contains(got, w), "missing %q in\n%s", w, got)
	for never in ([]string{"auth.json", "models-store.json", "cursor-sdk", "private-thing", "intercom", "skills", "SYSTEM.md"}) {
		testing.expectf(t, !strings.contains(got, never), "%s listed:\n%s", never, got)
	}
	// Create makes a missing project file, then opens it
	settings_create(fmt.tprintf("%s/.pi/settings.json", proj))
	testing.expect_value(t, read(fmt.tprintf("%s/.pi/settings.json", proj)), "{}\n")
	testing.expect_value(t, len(state.open_sessions[0].tabs), 2)
	// only files the tree offers are made
	settings_create(fmt.tprintf("%s/.pi/agent/SYSTEM.md", home))
	testing.expect(t, !os.exists(fmt.tprintf("%s/.pi/agent/SYSTEM.md", home)), "SYSTEM.md is not offered for Create")
}

@(test)
settings_files_credentials_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	for name in ([]string{"auth.json", "models-store.json", "private-thing.json", "cursor-sdk-x.json", "intercom/inbox.json"}) {
		p := fmt.tprintf("%s/%s", ad, name)
		testing.expectf(t, settings_credential(p), "%s is a credential file", name)
		for c in ([]Caller{ui, {kind = .Control}, {kind = .Script}}) {
			r := run_command(Open_File{path = p}, c)
			testing.expectf(t, !r.ok && r.error == CREDENTIAL_REFUSED, "%s opened: %v", name, r)
		}
	}
	for name in ([]string{"settings.json", "models.json", "extensions/subagent/config.json"}) {
		testing.expectf(t, !settings_credential(fmt.tprintf("%s/%s", ad, name)), "%s is not a credential file", name)
	}
	env := fmt.tprintf("%s/.env", proj)
	write_mode(env, "TOKEN=x", 0o644)
	testing.expect(t, !run_command(Open_File{path = env}, ui).ok, ".env refused")
	write_mode(fmt.tprintf("%s/.env.example", proj), "TOKEN=", 0o644)
	testing.expect(t, run_command(Open_File{path = fmt.tprintf("%s/.env.example", proj)}, ui).ok, "examples open")
	// through a symlink too
	link := fmt.tprintf("%s/creds.json", proj)
	os.symlink(fmt.tprintf("%s/auth.json", ad), link)
	testing.expect(t, !run_command(Open_File{path = link}, ui).ok, "a link to auth.json is refused")
	// a restored editor tab never reads it either
	e := new(Editor)
	defer editor_free(e)
	testing.expect(t, !editor_load(e, fmt.tprintf("%s/auth.json", ad)), "editor_load refuses")
	testing.expect_value(t, tb_len(&e.buf), 0)
	testing.expect(t, !strings.contains(tb_text(&e.buf, context.temp_allocator), SECRET), "no contents")
}

@(test)
settings_files_json_check :: proc(t: ^testing.T) {
	testing.expect_value(t, json_check(`{"a": [1, 2.5e3, -0, true, null, "x\n"]}`), "")
	testing.expect_value(t, json_check("{\n  \"a\": 1,\n}"), "line 3, column 1: a comma before }")
	testing.expect_value(t, json_check("{\n  // note\n  \"a\": 1\n}"), "line 2, column 3: expected a key in double quotes")
	testing.expect_value(t, json_check(`{"a": 01}`), "line 1, column 7: a bad number")
	testing.expect_value(t, json_check(`{"a": 1} x`), "line 1, column 10: more after the end of the JSON value")
	testing.expect_value(t, json_check(`["a",]`), "line 1, column 6: a comma before ]")
	testing.expect_value(t, json_check(`{"a": "b}`), "line 1, column 10: a string that never ends")
	testing.expect_value(t, json_check(""), "line 1, column 1: unexpected end of the file")
}

@(test)
settings_files_save_checks_json_and_offers_reload :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	path := fmt.tprintf("%s/.pi/agent/settings.json", home)
	before := read(path)
	r := run_command(Open_File{path = path}, ui)
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	ed_goto(e, 1, 2)
	ed_insert(e, `"broken": ,`)
	r = run_command(Save_File{e.tab_id}, ui)
	testing.expect(t, !r.ok && strings.has_prefix(r.error, "not saved: invalid JSON at line 1, column 12"), r.error)
	testing.expect_value(t, read(path), before)
	testing.expect(t, strings.contains(e.notice, "invalid JSON"), e.notice)
	testing.expect(t, !reload_flush(), "nothing saved: no reload offer")
	// fixed: saved, and pi's reload is offered over that tab
	ed_undo(e)
	ed_insert(e, `"hideThinkingBlock": true, `)
	r = run_command(Save_File{e.tab_id}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, strings.has_prefix(read(path), `{"hideThinkingBlock": true, "defaultModel"`), read(path))
	testing.expect(t, reload_flush(), "the save shows the reload bar at once")
	testing.expect(t, state.reload.from_save && len(state.reload.changed) == 1 && state.reload.changed[0] == path, "the bar lists the saved file")
	testing.expect(t, reload_bar_shows())
	// a project's own JSON that is not a settings file keeps its comments (no check)
	ts := fmt.tprintf("%s/tsconfig.json", proj)
	write_mode(ts, "{\n  // ok here\n}\n", 0o644)
	r = run_command(Open_File{path = ts}, ui)
	e2 := editor_of(r.created_id)
	ed_insert(e2, " ")
	testing.expect(t, run_command(Save_File{e2.tab_id}, ui).ok, "not a settings file")
	// a project's .pi/settings.json is checked
	os.make_directory_all(fmt.tprintf("%s/.pi", proj))
	ps := fmt.tprintf("%s/.pi/settings.json", proj)
	write_mode(ps, "{}", 0o644)
	r = run_command(Open_File{path = ps}, ui)
	e3 := editor_of(r.created_id)
	ed_insert(e3, "x")
	testing.expect(t, !run_command(Save_File{e3.tab_id}, ui).ok, "project settings checked")
}

// Review fix 1: the check follows pi's own readers. models.json goes through
// stripJsonComments (// comments, trailing commas) after a BOM; settings.json,
// keybindings.json, mcp.json and a project's .pi/settings.json are JSON.parse
// after a BOM; nothing else (an extension's tsconfig.json, modes.json) is checked.
@(test)
settings_files_json_check_matches_pi :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/settings.json", ad)), Json_Kind.Strict)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/keybindings.json", ad)), Json_Kind.Strict)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/mcp.json", ad)), Json_Kind.Strict)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/models.json", ad)), Json_Kind.Comments)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/.pi/settings.json", proj)), Json_Kind.Strict)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/extensions/subagent/tsconfig.json", ad)), Json_Kind.None)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/extensions/subagent/config.json", ad)), Json_Kind.None)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/modes.json", ad)), Json_Kind.None)
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/.pi/other.json", proj)), Json_Kind.None)
	BOM :: "\xef\xbb\xbf"
	testing.expect_value(t, json_check(BOM + `{"a": 1}`), "")
	testing.expect_value(t, json_check("{\n  // c\n  \"a\": 1\n}"), "line 2, column 3: expected a key in double quotes") // strict still strict
	testing.expect_value(t, json_check(BOM + "{\n  // a note\n  \"u\": \"http://x\", \"l\": [1, 2,],\n}\n", comments = true), "")
	testing.expect_value(t, json_check("/* no */ {}", comments = true), "line 1, column 1: a comment (JSON has none)")
	testing.expect_value(t, json_check("{\"a\": 1,, }", comments = true), "line 1, column 11: a comma before }") // pi strips only the second
	// saving: models.json with comments and a trailing comma is written
	mp := fmt.tprintf("%s/models.json", ad)
	r := run_command(Open_File{path = mp}, ui)
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	ed_goto(e, 1, 1)
	ed_insert(e, "// mine\n")
	ed_goto(e, 2, 17)
	ed_insert(e, ",")
	r = run_command(Save_File{e.tab_id}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, read(mp), "// mine\n{\"providers\": {},}")
	// an extension's tsconfig.json with comments saves as it is
	ts := fmt.tprintf("%s/extensions/subagent/tsconfig.json", ad)
	write_mode(ts, "{\n  // ok\n}\n", 0o644)
	r = run_command(Open_File{path = ts}, ui)
	e2 := editor_of(r.created_id)
	ed_insert(e2, " ")
	testing.expect(t, run_command(Save_File{e2.tab_id}, ui).ok, "tsconfig.json is not checked")
}

// Review fix 2: pi reads the first of AGENTS.override.md, AGENTS.md,
// AGENTS.MD, CLAUDE.md, CLAUDE.MD in a folder; the list shows that one by
// its name, and offers Create only when there is none.
@(test)
settings_files_context_file :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	write_mode(fmt.tprintf("%s/CLAUDE.md", proj), "# mine", 0o644)
	write_mode(fmt.tprintf("%s/AGENTS.md", ad), "# all", 0o644)
	write_mode(fmt.tprintf("%s/AGENTS.override.md", ad), "# over", 0o644)
	got := ""
	for r in settings_file_rows() do got = fmt.tprintf("%s%s|%s|%s|%v\n", got, r.group, r.label, fs_display(r.path), r.exists)
	testing.expectf(t, strings.contains(got, "pi|AGENTS.override.md|~/.pi/agent/AGENTS.override.md|true"), "global override:\n%s", got)
	testing.expectf(t, !strings.contains(got, "pi|AGENTS.md|"), "the shadowed AGENTS.md is not offered:\n%s", got)
	testing.expectf(t, strings.contains(got, "project|CLAUDE.md|~/proj/CLAUDE.md|true"), "project CLAUDE.md:\n%s", got)
	testing.expectf(t, !strings.contains(got, "~/proj/AGENTS.md"), "no Create when CLAUDE.md is there:\n%s", got)
}

// Review fix 3: the watcher, Reload_File and Diff_File read through
// disk_read, which refuses a credentials file even when an open tab's file
// is swapped for a symlink to auth.json.
@(test)
settings_files_swapped_for_credentials :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	auth := fmt.tprintf("%s/.pi/agent/auth.json", home)
	p := fmt.tprintf("%s/notes.txt", proj)
	write_mode(p, "hello\n", 0o644)
	r := run_command(Open_File{path = p}, ui)
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	_, _, refused := disk_read(auth, context.temp_allocator)
	testing.expect(t, refused != "", "disk_read refuses auth.json")
	os.remove(p)
	os.symlink(auth, p)
	editor_check_disk(e) // the watcher's path
	r = run_command(Reload_File{tab_id = e.tab_id}, ui)
	_ = run_command(Diff_File{e.tab_id, .Diff_Disk}, ui)
	for _, x in editors {
		testing.expect(t, !strings.contains(tb_text(&x.buf, context.temp_allocator), SECRET), "no secret in a buffer")
		testing.expect(t, !strings.contains(x.disk_text, SECRET), "no secret in the disk text")
	}
}

// Review fix 4: a hard link to auth.json is the same file; private files in
// the agent dir's subfolders are refused too.
@(test)
settings_files_hard_link_and_private_subfolder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	hl := fmt.tprintf("%s/innocent.json", proj)
	testing.expect(t, os.link(fmt.tprintf("%s/auth.json", ad), hl) == nil, "hard link made")
	testing.expect(t, settings_credential(hl), "a hard link to auth.json")
	testing.expect(t, !run_command(Open_File{path = hl}, ui).ok, "refused")
	_, _, refused := disk_read(hl, context.temp_allocator)
	testing.expect(t, refused != "", "disk_read refuses the hard link")
	os.make_directory_all(fmt.tprintf("%s/extensions/foo", ad))
	priv := fmt.tprintf("%s/extensions/foo/token.json", ad)
	write_mode(priv, `{"t": "x"}`, 0o600)
	testing.expect(t, settings_credential(priv), "a private file in a subfolder")
}

// Review fix 5: Create never overwrites (a file made since the tree was
// drawn stays as it is, and opens).
@(test)
settings_files_create_exclusive :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, proj := setup()
	path := fmt.tprintf("%s/.pi/settings.json", proj)
	os.make_directory_all(fmt.tprintf("%s/.pi", proj))
	write_mode(path, `{"theirs": 1}`, 0o644) // made by someone else meanwhile
	settings_create(path)
	testing.expect_value(t, read(path), `{"theirs": 1}`)
	tab := active_tab()
	testing.expect(t, tab != nil && strings.has_suffix(tab.kind.(Editor_Tab).path, ".pi/settings.json"), "opened as it is")
}

// The Settings tab's tree: the allowlist of the agent folder, groups, the
// project's .pi/ contents, credential files hidden at the top and inside
// opened folders, folders opening, missing files offered for Create.
@(test)
settings_tree_contents :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	for d in ([]string{"sessions/--x--", "npm/node_modules", "git", "bin", "logs", "skills/review", "extensions/subagent/lib"}) do os.make_directory_all(fmt.tprintf("%s/%s", ad, d))
	write_mode(fmt.tprintf("%s/prompts/fix.md", ad), "fix", 0o644)
	write_mode(fmt.tprintf("%s/prompts/token.json", ad), `{"t": "x"}`, 0o600) // private: a credential
	write_mode(fmt.tprintf("%s/prompts/.env", ad), "K=v", 0o644)
	write_mode(fmt.tprintf("%s/skills/review/SKILL.md", ad), "# review", 0o644)
	write_mode(fmt.tprintf("%s/extensions/subagent/index.ts", ad), "x", 0o644)
	write_mode(fmt.tprintf("%s/extensions/subagent/lib/secret.json", ad), "{}", 0o600)
	os.link(fmt.tprintf("%s/auth.json", ad), fmt.tprintf("%s/skills/review/notes.json", ad)) // the sign-ins by another name
	os.make_directory_all(fmt.tprintf("%s/.pi/prompts", proj))
	write_mode(fmt.tprintf("%s/.pi/prompts/p.md", proj), "p", 0o644)
	write_mode(fmt.tprintf("%s/.pi/.env", proj), "K=v", 0o644)
	run_command(Set_Left_Tab{tab = .Settings}, ui)
	tree :: proc() -> string {return files_rows_text(settings_tree_rows())}
	got := tree()
	want := "[pi (global)]\nsettings.json\nmodels.json\nprompts\nskills\nextensions\n[This project · proj]\n.pi/settings.json (create)\n.pi/prompts\nAGENTS.md (create)\n[Extensions]\npi-subagents config\nsubagent\n[Atlas]\nATLAS.md (create)\nModel: pi's default [Change…]\n[Chats]\nChat instructions (AGENTS.md) (create)\n[Folders]\nMain folder: not set [Set up…]\nsessions/: no main folder [Change…]\njobs/: no main folder [Change…]\nmemory/: no main folder [Change…]\natlas/: no main folder [Change…]\nchats/: default · ~/Chats [Change…]\n"
	testing.expect_value(t, got, want)
	// pi's own folders (the Folders group's sessions/ is pi-desk's, below [Chats])
	pis := got[:max(strings.index(got, "[Chats]"), 0)]
	for never in ([]string{"auth", "sessions", "npm", "git", "bin", "logs", "intercom", "private-thing", "cursor-sdk", "models-store", ".env"}) {
		testing.expectf(t, !strings.contains(pis, never), "%s shown:\n%s", never, got)
	}
	// folders open like the Files tab's; credentials stay hidden inside them
	for d in ([]string{"prompts", "skills", "skills/review", "extensions", "extensions/subagent", "extensions/subagent/lib"}) {
		r := run_command(Files_Expand{path = fmt.tprintf("%s/%s", ad, d), expanded = true}, ui)
		testing.expectf(t, r.ok, "expand %s: %s", d, r.error)
	}
	r := run_command(Files_Expand{path = fmt.tprintf("%s/.pi/prompts", proj), expanded = true}, ui)
	testing.expect(t, r.ok, r.error)
	got = tree()
	testing.expectf(t, strings.contains(got, "prompts/\n  fix.md\nskills/\n  review/\n    SKILL.md\nextensions/\n  subagent/\n    lib/\n    config.json\n    index.ts\n"), "opened:\n%s", got)
	testing.expectf(t, strings.contains(got, ".pi/prompts/\n  p.md\n"), "project folder opened:\n%s", got)
	for never in ([]string{"token.json", ".env", "notes.json", "secret.json"}) {
		testing.expectf(t, !strings.contains(got, never), "%s shown in an opened folder:\n%s", never, got)
	}
	// not a settings folder: refused
	testing.expect(t, !run_command(Files_Expand{path = fmt.tprintf("%s/sessions", ad), expanded = true}, ui).ok, "sessions/ does not open")
	testing.expect(t, !run_command(Files_Expand{path = fmt.tprintf("%s/prompts", ad), expanded = true}, {kind = .Panel, tab_id = state.open_sessions[0].tabs[0].id}).ok, "a pi tab's bridge stays in its project")
	// the open state is kept (saved with the workspace) under the agent folder
	testing.expect(t, list_index(files_expanded_dirs(ad), "prompts") >= 0, "kept under the agent folder")
	// a file made outside shows after the poll looks
	write_mode(fmt.tprintf("%s/SYSTEM.md", ad), "sys", 0o644)
	settings_poll_now()
	testing.expectf(t, strings.contains(tree(), "SYSTEM.md\n"), "SYSTEM.md after the poll:\n%s", tree())
	write_mode(fmt.tprintf("%s/prompts/new.md", ad), "n", 0o644)
	settings_poll_now()
	testing.expectf(t, strings.contains(tree(), "  new.md\n"), "a new prompt after the poll:\n%s", tree())
	// the filter: every file of the tree, open or not; credentials never
	run_command(Files_Expand{path = fmt.tprintf("%s/skills", ad), expanded = false}, ui)
	run_command(Set_Files_Filter{text = "skill"}, ui)
	got = tree()
	testing.expectf(t, strings.contains(got, "skills/review/SKILL.md"), "filter finds a closed folder's file:\n%s", got)
	run_command(Set_Files_Filter{text = "json"}, ui)
	got = tree()
	testing.expectf(t, !strings.contains(got, "notes.json") && !strings.contains(got, "token.json") && !strings.contains(got, "auth"), "filter hides credentials:\n%s", got)
	// switching trees clears the filter
	run_command(Set_Left_Tab{tab = .Files}, ui)
	testing.expect_value(t, state.files.filter, "")
	_ = home
}

// The row menu: rename and delete only inside prompts/, skills/,
// extensions/ and a project's .pi/; never pi's config files, never outside.
// The file commands follow the same rule, for the user only.
@(test)
settings_tree_menu_restrictions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	write_mode(fmt.tprintf("%s/prompts/fix.md", ad), "fix", 0o644)
	os.make_directory_all(fmt.tprintf("%s/.pi", proj))
	write_mode(fmt.tprintf("%s/.pi/settings.json", proj), "{}", 0o644)
	run_command(Set_Left_Tab{tab = .Settings}, ui)
	labels :: proc(path: string) -> string {
		items := make([dynamic]Menu_Item, context.temp_allocator)
		files_menu_items(path, &items)
		b := strings.builder_make(context.temp_allocator)
		for it in items do if !it.sep do fmt.sbprintf(&b, "%s|", it.label)
		return strings.to_string(b)
	}
	for p in ([]string{"settings.json", "models.json", "prompts", "extensions"}) {
		m := labels(fmt.tprintf("%s/%s", ad, p))
		testing.expectf(t, !strings.contains(m, "Rename") && !strings.contains(m, "Trash"), "%s: %s", p, m)
	}
	m := labels(fmt.tprintf("%s/prompts/fix.md", ad))
	testing.expectf(t, strings.contains(m, "Open|") && strings.contains(m, "New file…|") && strings.contains(m, "Rename…|") && strings.contains(m, "Move to Trash…|") && strings.contains(m, "Reveal in Finder|"), "a prompt: %s", m)
	m = labels(fmt.tprintf("%s/prompts", ad))
	testing.expectf(t, strings.contains(m, "New file…|") && !strings.contains(m, "Rename"), "prompts/: %s", m)
	m = labels(fmt.tprintf("%s/extensions/subagent", ad))
	testing.expectf(t, strings.contains(m, "Rename…|") && !strings.contains(m, "New file"), "an extension's folder: %s", m)
	m = labels(fmt.tprintf("%s/.pi/settings.json", proj))
	testing.expectf(t, strings.contains(m, "Rename…|"), "inside the project's .pi/: %s", m)
	m = labels(fmt.tprintf("%s/AGENTS.md", proj))
	testing.expectf(t, !strings.contains(m, "Rename"), "the project's instructions file: %s", m)
	// the commands: the user may make, rename and delete inside prompts/
	r := run_command(Create_File{path = fmt.tprintf("%s/prompts/a.md", ad)}, ui)
	testing.expect(t, r.ok, r.error)
	r = run_command(Rename_Path{from = fmt.tprintf("%s/prompts/a.md", ad), to = fmt.tprintf("%s/prompts/b.md", ad)}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, os.exists(fmt.tprintf("%s/prompts/b.md", ad)), "renamed")
	// never pi's config files, never out of the folder, never for other callers
	testing.expect(t, !run_command(Rename_Path{from = fmt.tprintf("%s/settings.json", ad), to = fmt.tprintf("%s/prompts/s.json", ad)}, ui).ok, "settings.json stays")
	testing.expect(t, !run_command(Rename_Path{from = fmt.tprintf("%s/prompts/b.md", ad), to = fmt.tprintf("%s/b.md", ad)}, ui).ok, "not out of prompts/")
	testing.expect(t, !run_command(Delete_Path{path = fmt.tprintf("%s/prompts", ad)}, ui).ok, "not prompts/ itself")
	testing.expect(t, !run_command(Delete_Path{path = fmt.tprintf("%s/auth.json", ad)}, ui).ok, "never the sign-ins")
	testing.expect(t, !run_command(Create_File{path = fmt.tprintf("%s/prompts/c.md", ad)}, {kind = .Control}).ok, "the agent may not")
	testing.expect(t, !run_command(Create_File{path = fmt.tprintf("%s/prompts/c.md", ad)}, {kind = .Script}).ok, "scripts may not")
	// a symlink out of prompts/ does not lead anywhere
	out := fmt.tprintf("%s/elsewhere", home)
	os.make_directory_all(out)
	os.symlink(out, fmt.tprintf("%s/prompts/link", ad))
	testing.expect(t, !run_command(Create_File{path = fmt.tprintf("%s/prompts/link/x.md", ad)}, ui).ok, "not through a symlink out")
	// Reveal in Finder: the tree's paths, for the user
	testing.expect(t, run_command(Reveal_In_Finder{path = fmt.tprintf("%s/settings.json", ad)}, ui).ok, "reveal a config file")
	testing.expect(t, !run_command(Reveal_In_Finder{path = fmt.tprintf("%s/settings.json", ad)}, {kind = .Control}).ok, "not for the agent")
}

// Review round 1 (coordinator): each fix's failing test first.

// 1. The filter is cleared only between the two trees (Files ↔ Settings).
@(test)
review_filter_kept_for_sessions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	setup()
	run_command(Set_Left_Tab{tab = .Files}, ui)
	run_command(Set_Files_Filter{text = "main"}, ui)
	run_command(Set_Left_Tab{tab = .Sessions}, ui)
	testing.expect_value(t, state.files.filter, "main")
	run_command(Set_Left_Tab{tab = .Files}, ui)
	testing.expect_value(t, state.files.filter, "main")
	run_command(Set_Left_Tab{tab = .Settings}, ui)
	testing.expect_value(t, state.files.filter, "")
}

// 2. ↓ in the Settings filter selects in the Settings tree, not the Files tree.
@(test)
review_filter_down_selects_settings_row :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, _ := setup()
	write_mode(fmt.tprintf("%s/.pi/agent/prompts/fix.md", home), "fix", 0o644)
	run_command(Set_Left_Tab{tab = .Settings}, ui)
	run_command(Set_Files_Filter{text = "fix"}, ui)
	before := strings.clone(files_ui.cursor, context.temp_allocator)
	files_filter_key(.DOWN)
	inbox_drain()
	testing.expect_value(t, settings_ui.cursor, fmt.tprintf("%s/.pi/agent/prompts/fix.md", home))
	testing.expect_value(t, files_ui.cursor, before)
}

// 3. New file/folder are not offered where the real folder is outside
// (a skill that is a symlink to a repo), as the command would refuse.
@(test)
review_new_not_offered_in_symlinked_skill :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, _ := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	out := fmt.tprintf("%s/repo/skill-x", home)
	os.make_directory_all(out)
	os.make_directory_all(fmt.tprintf("%s/skills", ad))
	os.symlink(out, fmt.tprintf("%s/skills/skill-x", ad))
	testing.expect(t, settings_new_ok(fmt.tprintf("%s/skills", ad)), "skills/ itself")
	testing.expect(t, !settings_new_ok(fmt.tprintf("%s/skills/skill-x", ad)), "not in a symlinked skill")
	testing.expect(t, !run_command(Create_File{path = fmt.tprintf("%s/skills/skill-x/a.md", ad)}, ui).ok, "the command refuses it too")
}

// 4. The command table names the settings tab.
@(test)
review_command_table_names_settings_tab :: proc(t: ^testing.T) {
	found := false
	for c in COMMAND_SPECS do if c.type == "set_left_tab" {
		found = true
		testing.expectf(t, strings.contains(c.does, "settings"), "set_left_tab: %q", c.does)
	}
	testing.expect(t, found, "set_left_tab in the table")
}

// 5. Collapse all closes the project's .pi/ folders only, not .pip-cache.
@(test)
review_collapse_all_only_dot_pi :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, proj := setup()
	os.make_directory_all(fmt.tprintf("%s/.pi/prompts", proj))
	os.make_directory_all(fmt.tprintf("%s/.pip-cache/x", proj))
	testing.expect(t, run_command(Files_Expand{path = fmt.tprintf("%s/.pi/prompts", proj), expanded = true}, ui).ok, "expand .pi/prompts")
	testing.expect(t, run_command(Files_Expand{path = fmt.tprintf("%s/.pip-cache", proj), expanded = true}, ui).ok, "expand .pip-cache")
	run_command(Set_Left_Tab{tab = .Settings}, ui)
	action_run("settings_collapse_all")
	inbox_drain()
	testing.expect(t, !files_is_open(fmt.tprintf("%s/.pi/prompts", proj)), ".pi/prompts closed")
	testing.expect(t, files_is_open(fmt.tprintf("%s/.pip-cache", proj)), ".pip-cache stays open")
}

// 6. The Settings header's Reveal is not a second "Reveal in Finder" in the palette.
@(test)
review_settings_reveal_not_in_palette :: proc(t: ^testing.T) {
	a := action_by_id("settings_reveal_finder")
	testing.expect(t, a != nil && a.no_palette, "settings_reveal_finder is a button only")
}
