package main

// Settings files (settings_files.odin): what the ⌘, sheet lists under a fake
// HOME, credential files refused by the list and the editor, the JSON check
// on save, the reload offer after saving a pi file. Everything runs under a
// temp HOME with a fake ~/.pi/agent: the user's real files are never read.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

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
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}}
	core.reload_watch_reset()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	base := fmt.tprintf("%s/deckhand-settings-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	ad := fmt.tprintf("%s/home/.pi/agent", base)
	os.make_directory_all(fmt.tprintf("%s/extensions/subagent", ad))
	os.make_directory_all(fmt.tprintf("%s/intercom", ad))
	os.make_directory_all(fmt.tprintf("%s/prompts", ad))
	os.make_directory_all(fmt.tprintf("%s/home/proj", base))
	home = core.fs_real(fmt.tprintf("%s/home", base), context.allocator)
	proj = core.fs_real(fmt.tprintf("%s/home/proj", base), context.allocator)
	ensure(strings.contains(home, "/deckhand-settings-test-"), "settings tests: no temp HOME") // never the user's ~/.pi
	os.set_env("HOME", home)
	core.home_root = fmt.aprintf("%s/data", base) // Atlas's prompt file: the Settings tab's Atlas group
	os.unset_env("PI_CODING_AGENT_DIR")
	os.unset_env("XDG_CONFIG_HOME")
	os.unset_env("PI_KIT_NOTES_DIR") // the Folders group shows the user's own as a row
	// pi's files and the Coding agents rows are listed as on a machine with pi and Claude Code
	core.pi_installed_probe = stand_in_installed
	core.claude_installed_probe = stand_in_installed
	ad = fmt.tprintf("%s/.pi/agent", home)
	write_mode(fmt.tprintf("%s/settings.json", ad), `{"defaultModel": "x", "packages": ["npm:pi-subagents@1.2.3", {"source": "../../pkgs/pi-kit"}]}`, 0o644)
	write_mode(fmt.tprintf("%s/models.json", ad), `{"providers": {}}`, 0o600) // pi may make it private: still a config file
	write_mode(fmt.tprintf("%s/auth.json", ad), fmt.tprintf(`{{"anthropic":{{"key":"%s"}}}}`, SECRET), 0o600)
	write_mode(fmt.tprintf("%s/models-store.json", ad), "{}", 0o600)
	write_mode(fmt.tprintf("%s/cursor-sdk-x.json", ad), "{}", 0o644)
	write_mode(fmt.tprintf("%s/private-thing.json", ad), "{}", 0o600)
	write_mode(fmt.tprintf("%s/intercom/inbox.json", ad), "{}", 0o644)
	write_mode(fmt.tprintf("%s/extensions/subagent/config.json", ad), `{"compact": true}`, 0o644)
	append(&state.projects, core.Project{id = core.new_id(), cwd = proj, label = "proj"})
	state.selected_project = state.projects[0].id
	s := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("s-1"), project_id = state.projects[0].id, cwd = proj}
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Exited})
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
ui :: core.Caller{kind = .UI}

@(test)
settings_files_list :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	rows := core.settings_file_rows()
	b := strings.builder_make(context.temp_allocator)
	for r in rows do fmt.sbprintf(&b, "%s|%s|%s|%v\n", r.group, r.label, core.fs_display(r.path), r.exists)
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
	core.settings_create(fmt.tprintf("%s/.pi/settings.json", proj))
	testing.expect_value(t, read(fmt.tprintf("%s/.pi/settings.json", proj)), "{}\n")
	testing.expect_value(t, len(state.open_sessions[0].tabs), 2)
	// only files the tree offers are made
	core.settings_create(fmt.tprintf("%s/.pi/agent/SYSTEM.md", home))
	testing.expect(t, !os.exists(fmt.tprintf("%s/.pi/agent/SYSTEM.md", home)), "SYSTEM.md is not offered for Create")
}

@(test)
settings_files_credentials_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	ad := fmt.tprintf("%s/.pi/agent", home)
	for name in ([]string{"auth.json", "models-store.json", "private-thing.json", "cursor-sdk-x.json", "intercom/inbox.json"}) {
		p := fmt.tprintf("%s/%s", ad, name)
		testing.expectf(t, core.settings_credential(p), "%s is a credential file", name)
		for c in ([]core.Caller{ui, {kind = .Control}, {kind = .Script}}) {
			r := core.run_command(core.Open_File{path = p}, c)
			testing.expectf(t, !r.ok && r.error == core.CREDENTIAL_REFUSED, "%s opened: %v", name, r)
		}
	}
	for name in ([]string{"settings.json", "models.json", "extensions/subagent/config.json"}) {
		testing.expectf(t, !core.settings_credential(fmt.tprintf("%s/%s", ad, name)), "%s is not a credential file", name)
	}
	env := fmt.tprintf("%s/.env", proj)
	write_mode(env, "TOKEN=x", 0o644)
	testing.expect(t, !core.run_command(core.Open_File{path = env}, ui).ok, ".env refused")
	write_mode(fmt.tprintf("%s/.env.example", proj), "TOKEN=", 0o644)
	testing.expect(t, core.run_command(core.Open_File{path = fmt.tprintf("%s/.env.example", proj)}, ui).ok, "examples open")
	// through a symlink too
	link := fmt.tprintf("%s/creds.json", proj)
	os.symlink(fmt.tprintf("%s/auth.json", ad), link)
	testing.expect(t, !core.run_command(core.Open_File{path = link}, ui).ok, "a link to auth.json is refused")
	// a restored editor tab never reads it either
	e := new(Editor)
	defer editor_free(e)
	testing.expect(t, !editor_load(e, fmt.tprintf("%s/auth.json", ad)), "editor_load refuses")
	testing.expect_value(t, tb_len(&e.buf), 0)
	testing.expect(t, !strings.contains(tb_text(&e.buf, context.temp_allocator), SECRET), "no contents")
}

@(test)
settings_files_json_check :: proc(t: ^testing.T) {
	testing.expect_value(t, core.json_check(`{"a": [1, 2.5e3, -0, true, null, "x\n"]}`), "")
	testing.expect_value(t, core.json_check("{\n  \"a\": 1,\n}"), "line 3, column 1: a comma before }")
	testing.expect_value(t, core.json_check("{\n  // note\n  \"a\": 1\n}"), "line 2, column 3: expected a key in double quotes")
	testing.expect_value(t, core.json_check(`{"a": 01}`), "line 1, column 7: a bad number")
	testing.expect_value(t, core.json_check(`{"a": 1} x`), "line 1, column 10: more after the end of the JSON value")
	testing.expect_value(t, core.json_check(`["a",]`), "line 1, column 6: a comma before ]")
	testing.expect_value(t, core.json_check(`{"a": "b}`), "line 1, column 10: a string that never ends")
	testing.expect_value(t, core.json_check(""), "line 1, column 1: unexpected end of the file")
}

@(test)
settings_files_save_checks_json_and_offers_reload :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	path := fmt.tprintf("%s/.pi/agent/settings.json", home)
	before := read(path)
	r := core.run_command(core.Open_File{path = path}, ui)
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	ed_goto(e, 1, 2)
	ed_insert(e, `"broken": ,`)
	r = core.run_command(core.Save_File{e.tab_id}, ui)
	testing.expect(t, !r.ok && strings.has_prefix(r.error, "not saved: invalid JSON at line 1, column 12"), r.error)
	testing.expect_value(t, read(path), before)
	testing.expect(t, strings.contains(e.notice, "invalid JSON"), e.notice)
	testing.expect(t, !core.reload_flush(), "nothing saved: no reload offer")
	// fixed: saved, and pi's reload is offered over that tab
	ed_undo(e)
	ed_insert(e, `"hideThinkingBlock": true, `)
	r = core.run_command(core.Save_File{e.tab_id}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, strings.has_prefix(read(path), `{"hideThinkingBlock": true, "defaultModel"`), read(path))
	testing.expect(t, core.reload_flush(), "the save shows the reload bar at once")
	testing.expect(t, state.reload.from_save && len(state.reload.changed) == 1 && state.reload.changed[0] == path, "the bar lists the saved file")
	testing.expect(t, reload_bar_shows())
	// a project's own JSON that is not a settings file keeps its comments (no check)
	ts := fmt.tprintf("%s/tsconfig.json", proj)
	write_mode(ts, "{\n  // ok here\n}\n", 0o644)
	r = core.run_command(core.Open_File{path = ts}, ui)
	e2 := editor_of(r.created_id)
	ed_insert(e2, " ")
	testing.expect(t, core.run_command(core.Save_File{e2.tab_id}, ui).ok, "not a settings file")
	// a project's .pi/settings.json is checked
	os.make_directory_all(fmt.tprintf("%s/.pi", proj))
	ps := fmt.tprintf("%s/.pi/settings.json", proj)
	write_mode(ps, "{}", 0o644)
	r = core.run_command(core.Open_File{path = ps}, ui)
	e3 := editor_of(r.created_id)
	ed_insert(e3, "x")
	testing.expect(t, !core.run_command(core.Save_File{e3.tab_id}, ui).ok, "project settings checked")
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
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/settings.json", ad)), core.Json_Kind.Strict)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/keybindings.json", ad)), core.Json_Kind.Strict)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/mcp.json", ad)), core.Json_Kind.Strict)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/models.json", ad)), core.Json_Kind.Comments)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/.pi/settings.json", proj)), core.Json_Kind.Strict)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/extensions/subagent/tsconfig.json", ad)), core.Json_Kind.None)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/extensions/subagent/config.json", ad)), core.Json_Kind.None)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/modes.json", ad)), core.Json_Kind.None)
	testing.expect_value(t, core.settings_json_kind(fmt.tprintf("%s/.pi/other.json", proj)), core.Json_Kind.None)
	BOM :: "\xef\xbb\xbf"
	testing.expect_value(t, core.json_check(BOM + `{"a": 1}`), "")
	testing.expect_value(t, core.json_check("{\n  // c\n  \"a\": 1\n}"), "line 2, column 3: expected a key in double quotes") // strict still strict
	testing.expect_value(t, core.json_check(BOM + "{\n  // a note\n  \"u\": \"http://x\", \"l\": [1, 2,],\n}\n", comments = true), "")
	testing.expect_value(t, core.json_check("/* no */ {}", comments = true), "line 1, column 1: a comment (JSON has none)")
	testing.expect_value(t, core.json_check("{\"a\": 1,, }", comments = true), "line 1, column 11: a comma before }") // pi strips only the second
	// saving: models.json with comments and a trailing comma is written
	mp := fmt.tprintf("%s/models.json", ad)
	r := core.run_command(core.Open_File{path = mp}, ui)
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	ed_goto(e, 1, 1)
	ed_insert(e, "// mine\n")
	ed_goto(e, 2, 17)
	ed_insert(e, ",")
	r = core.run_command(core.Save_File{e.tab_id}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, read(mp), "// mine\n{\"providers\": {},}")
	// an extension's tsconfig.json with comments saves as it is
	ts := fmt.tprintf("%s/extensions/subagent/tsconfig.json", ad)
	write_mode(ts, "{\n  // ok\n}\n", 0o644)
	r = core.run_command(core.Open_File{path = ts}, ui)
	e2 := editor_of(r.created_id)
	ed_insert(e2, " ")
	testing.expect(t, core.run_command(core.Save_File{e2.tab_id}, ui).ok, "tsconfig.json is not checked")
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
	for r in core.settings_file_rows() do got = fmt.tprintf("%s%s|%s|%s|%v\n", got, r.group, r.label, core.fs_display(r.path), r.exists)
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
	r := core.run_command(core.Open_File{path = p}, ui)
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	_, _, refused := disk_read(auth, context.temp_allocator)
	testing.expect(t, refused != "", "disk_read refuses auth.json")
	os.remove(p)
	os.symlink(auth, p)
	editor_check_disk(e) // the watcher's path
	r = core.run_command(core.Reload_File{tab_id = e.tab_id}, ui)
	_ = core.run_command(core.Diff_File{e.tab_id, .Diff_Disk}, ui)
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
	testing.expect(t, core.settings_credential(hl), "a hard link to auth.json")
	testing.expect(t, !core.run_command(core.Open_File{path = hl}, ui).ok, "refused")
	_, _, refused := disk_read(hl, context.temp_allocator)
	testing.expect(t, refused != "", "disk_read refuses the hard link")
	os.make_directory_all(fmt.tprintf("%s/extensions/foo", ad))
	priv := fmt.tprintf("%s/extensions/foo/token.json", ad)
	write_mode(priv, `{"t": "x"}`, 0o600)
	testing.expect(t, core.settings_credential(priv), "a private file in a subfolder")
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
	core.settings_create(path)
	testing.expect_value(t, read(path), `{"theirs": 1}`)
	tab := core.active_tab()
	testing.expect(t, tab != nil && strings.has_suffix(tab.kind.(core.Editor_Tab).path, ".pi/settings.json"), "opened as it is")
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
	write_mode(fmt.tprintf("%s/bin/pi", ad), "#!/bin/sh\nexit 1\n", 0o755) // a pi binary for the Coding agents rows (pi's managed install; never run)
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
	core.harness_checklist_forget() // the Coding agents rows look at this HOME (another test's are cached)
	core.settings_watch = true // as while the Settings page shows: its folders are polled
	defer core.settings_watch = false
	got := sf_text()
	want := "[pi (global)]\nsettings.json\nmodels.json\nprompts\nskills\nextensions\n[This project · proj]\n.pi/settings.json (create)\nAGENTS.md (create)\n[Extensions]\npi-subagents config\nsubagent\n[Atlas]\nATLAS.md (create)\nModel: pi's default [Change…]\n[Chats]\nChat instructions (AGENTS.md) (create)\n[Folders]\nMain folder: not set [Set up…]\nsessions/: no main folder [Change…]\njobs/: no main folder [Change…]\nmemory/: no main folder [Change…]\natlas/: no main folder [Change…]\nchats/: default · ~/Chats [Change…]\n[Coding agents]\npi\n  Deckhand integration\n  pi-subagents\n  rpiv-todo: Not installed [Install…]\n  pi-ask-user: Not installed [Install…]\n  pi-web-access: Not installed [Install…]\n  rpiv-btw: Not installed [Install…]\nClaude Code\n  Deckhand integration\nCodex: Not installed [Install…]\n[Machines]\nMachines over SSH is off: turn it on to add a machine [Turn on]\nAllow other machines to connect: off [Turn on…]\n" // the harness checklist (ui_harness.odin), then the Machines group (always shown)
	testing.expect_value(t, got, want)
	// pi's own folders (the Folders group's sessions/ is Deckhand's, below [Chats])
	pis := got[:max(strings.index(got, "[Chats]"), 0)]
	for never in ([]string{"auth", "sessions", "npm", "git", "bin", "logs", "intercom", "private-thing", "cursor-sdk", "models-store", ".env"}) {
		testing.expectf(t, !strings.contains(pis, never), "%s shown:\n%s", never, got)
	}
	// not a settings folder: refused
	testing.expect(t, !core.run_command(core.Files_Expand{path = fmt.tprintf("%s/sessions", ad), expanded = true}, ui).ok, "sessions/ does not open")
	testing.expect(t, !core.run_command(core.Files_Expand{path = fmt.tprintf("%s/prompts", ad), expanded = true}, {kind = .Panel, tab_id = state.open_sessions[0].tabs[0].id}).ok, "a pi tab's bridge stays in its project")
	// the Settings page's search: the files inside the folders and the project's .pi/; credentials never
	found := map[string]bool{}
	defer delete(found)
	for q in ([]string{"skill", "json", "fix", "index", "notes", "token", "env", "secret"}) do for h in core.settings_search(q, deep = true) do if h.kind == .File do found[filepath.base(h.row.path)] = true
	testing.expectf(t, found["SKILL.md"] && found["fix.md"] && found["index.ts"], "the page's search finds files inside folders: %v", found)
	for never in ([]string{"notes.json", "token.json", ".env", "secret.json", "auth.json"}) do testing.expectf(t, !found[never], "the page's search shows %s", never)
	searched :: proc(q, name: string) -> bool {
		for h in core.settings_search(q, deep = true) do if h.kind == .File && filepath.base(h.row.path) == name do return true
		return false
	}
	testing.expect(t, searched("p.md", "p.md"), "the project's .pi/prompts/p.md")
	// a file made outside shows after the poll looks
	testing.expect(t, !searched("new.md", "new.md"), "not there yet")
	core.settings_poll_now() // the poll's baseline
	write_mode(fmt.tprintf("%s/prompts/new.md", ad), "n", 0o644)
	core.settings_poll_now()
	testing.expect(t, searched("new.md", "new.md"), "a new prompt after the poll")
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
	// the commands: the user may make, rename and delete inside prompts/
	r := core.run_command(core.Create_File{path = fmt.tprintf("%s/prompts/a.md", ad)}, ui)
	testing.expect(t, r.ok, r.error)
	r = core.run_command(core.Rename_Path{from = fmt.tprintf("%s/prompts/a.md", ad), to = fmt.tprintf("%s/prompts/b.md", ad)}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, os.exists(fmt.tprintf("%s/prompts/b.md", ad)), "renamed")
	// never pi's config files, never out of the folder, never for other callers
	testing.expect(t, !core.run_command(core.Rename_Path{from = fmt.tprintf("%s/settings.json", ad), to = fmt.tprintf("%s/prompts/s.json", ad)}, ui).ok, "settings.json stays")
	testing.expect(t, !core.run_command(core.Rename_Path{from = fmt.tprintf("%s/prompts/b.md", ad), to = fmt.tprintf("%s/b.md", ad)}, ui).ok, "not out of prompts/")
	testing.expect(t, !core.run_command(core.Delete_Path{path = fmt.tprintf("%s/prompts", ad)}, ui).ok, "not prompts/ itself")
	testing.expect(t, !core.run_command(core.Delete_Path{path = fmt.tprintf("%s/auth.json", ad)}, ui).ok, "never the sign-ins")
	testing.expect(t, !core.run_command(core.Create_File{path = fmt.tprintf("%s/prompts/c.md", ad)}, {kind = .Control}).ok, "the agent may not")
	testing.expect(t, !core.run_command(core.Create_File{path = fmt.tprintf("%s/prompts/c.md", ad)}, {kind = .Script}).ok, "scripts may not")
	// a symlink out of prompts/ does not lead anywhere
	out := fmt.tprintf("%s/elsewhere", home)
	os.make_directory_all(out)
	os.symlink(out, fmt.tprintf("%s/prompts/link", ad))
	testing.expect(t, !core.run_command(core.Create_File{path = fmt.tprintf("%s/prompts/link/x.md", ad)}, ui).ok, "not through a symlink out")
	// Reveal in Finder: the tree's paths, for the user
	testing.expect(t, core.run_command(core.Reveal_In_Finder{path = fmt.tprintf("%s/settings.json", ad)}, ui).ok, "reveal a config file")
	testing.expect(t, !core.run_command(core.Reveal_In_Finder{path = fmt.tprintf("%s/settings.json", ad)}, {kind = .Control}).ok, "not for the agent")
}

// Review round 1 (coordinator): each fix's failing test first.

// 1. The filter is cleared only between the two trees (Files ↔ Settings).
@(test)
review_filter_kept_for_sessions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	setup()
	core.run_command(core.Set_Left_Tab{tab = .Files}, ui)
	core.run_command(core.Set_Files_Filter{text = "main"}, ui)
	core.run_command(core.Set_Left_Tab{tab = .Sessions}, ui)
	testing.expect_value(t, state.files.filter, "main")
	core.run_command(core.Set_Left_Tab{tab = .Files}, ui)
	testing.expect_value(t, state.files.filter, "main")
	// the old Settings tab (an older caller, a saved workspace): Sessions
	core.run_command(core.Set_Left_Tab{tab = .Settings}, ui)
	testing.expect_value(t, state.layout.left_tab, core.Left_Tab.Sessions)
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
	testing.expect(t, core.settings_new_ok(fmt.tprintf("%s/skills", ad)), "skills/ itself")
	testing.expect(t, !core.settings_new_ok(fmt.tprintf("%s/skills/skill-x", ad)), "not in a symlinked skill")
	testing.expect(t, !core.run_command(core.Create_File{path = fmt.tprintf("%s/skills/skill-x/a.md", ad)}, ui).ok, "the command refuses it too")
}

// 4. The command table names the settings tab.
@(test)
review_command_table_names_settings_tab :: proc(t: ^testing.T) {
	found := false
	for c in core.COMMAND_SPECS do if c.type == "set_left_tab" {
		found = true
		testing.expectf(t, strings.contains(c.does, "settings"), "set_left_tab: %q", c.does)
	}
	testing.expect(t, found, "set_left_tab in the table")
}

// ---- Claude Code's files (settings_files.odin, claude_reload.odin) ----

// A fake Claude config folder (CLAUDE_CONFIG_DIR) under the temp HOME, with what Claude Code
// keeps there: config the user edits, and credentials, account state and transcripts that
// Deckhand must never list or open. Returns the config folder.
@(private = "file")
claude_setup :: proc(home, proj: string) -> string {
	cfg := fmt.aprintf("%s/claude-cfg", home)
	for d in ([]string{"projects/-proj", "sessions", "backups", "file-history/s1", "todos", "shell-snapshots", "plugins/cache", "agents", "skills/s1", "commands", "output-styles", "rules"}) do os.make_directory_all(fmt.tprintf("%s/%s", cfg, d))
	write_mode(fmt.tprintf("%s/settings.json", cfg), `{"model": "opus"}`, 0o644)
	write_mode(fmt.tprintf("%s/CLAUDE.md", cfg), "# mine\n", 0o644)
	write_mode(fmt.tprintf("%s/keybindings.json", cfg), `{"bindings": []}`, 0o644)
	write_mode(fmt.tprintf("%s/skills/s1/SKILL.md", cfg), "---\nname: s1\n---\n", 0o644)
	write_mode(fmt.tprintf("%s/agents/a.md", cfg), "---\nname: a\n---\n", 0o600) // private but config
	write_mode(fmt.tprintf("%s/.credentials.json", cfg), fmt.tprintf(`{{"token":"%s"}}`, SECRET), 0o600)
	write_mode(fmt.tprintf("%s/.claude.json", cfg), `{"oauthAccount": {}}`, 0o600) // with CLAUDE_CONFIG_DIR it lives here
	write_mode(fmt.tprintf("%s/.claude.json", home), `{"oauthAccount": {}}`, 0o600) // without: in HOME
	write_mode(fmt.tprintf("%s/projects/-proj/abc.jsonl", cfg), "{}\n", 0o600)
	write_mode(fmt.tprintf("%s/history.jsonl", cfg), "{}\n", 0o600)
	write_mode(fmt.tprintf("%s/sessions/123.json", cfg), "{}", 0o644)
	write_mode(fmt.tprintf("%s/backups/.claude.json.backup.1", cfg), "{}", 0o600)
	write_mode(fmt.tprintf("%s/file-history/s1/x", cfg), "x", 0o644)
	write_mode(fmt.tprintf("%s/stats-cache.json", cfg), "{}", 0o644)
	write_mode(fmt.tprintf("%s/remote-settings.json", cfg), "{}", 0o644)
	write_mode(fmt.tprintf("%s/plugins/installed_plugins.json", cfg), "{}", 0o644)
	os.make_directory_all(fmt.tprintf("%s/.claude", proj))
	write_mode(fmt.tprintf("%s/.claude/settings.local.json", proj), `{"permissions": {}}`, 0o644)
	write_mode(fmt.tprintf("%s/CLAUDE.md", proj), "# proj\n", 0o644)
	os.set_env("CLAUDE_CONFIG_DIR", cfg)
	return cfg
}

// Every path of Claude Code's that Deckhand must never list, read or open.
@(private = "file")
claude_secret_paths :: proc(home, cfg: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out,
		fmt.tprintf("%s/.credentials.json", cfg),
		fmt.tprintf("%s/.claude.json", cfg),
		fmt.tprintf("%s/.claude.json", home),
		fmt.tprintf("%s/projects/-proj/abc.jsonl", cfg),
		fmt.tprintf("%s/history.jsonl", cfg),
		fmt.tprintf("%s/sessions/123.json", cfg),
		fmt.tprintf("%s/backups/.claude.json.backup.1", cfg),
		fmt.tprintf("%s/file-history/s1/x", cfg),
		fmt.tprintf("%s/stats-cache.json", cfg),
		fmt.tprintf("%s/remote-settings.json", cfg),
		fmt.tprintf("%s/plugins/installed_plugins.json", cfg),
	)
	return out[:]
}

@(test)
settings_files_claude_rows :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	cfg := claude_setup(home, proj)
	defer os.unset_env("CLAUDE_CONFIG_DIR")
	rows := core.settings_file_rows()
	b := strings.builder_make(context.temp_allocator)
	for r in rows do fmt.sbprintf(&b, "%s|%s|%s|%v\n", r.group, r.label, r.path, r.exists)
	got := strings.to_string(b)
	want := []string {
		fmt.tprintf("claude|settings.json|%s/settings.json|true", cfg),
		fmt.tprintf("claude|CLAUDE.md|%s/CLAUDE.md|true", cfg),
		fmt.tprintf("claude|keybindings.json|%s/keybindings.json|true", cfg),
		fmt.tprintf("claude|agents|%s/agents|true", cfg),
		fmt.tprintf("claude|skills|%s/skills|true", cfg),
		fmt.tprintf("claude|commands|%s/commands|true", cfg),
		fmt.tprintf("claude|output-styles|%s/output-styles|true", cfg),
		fmt.tprintf("claude|rules|%s/rules|true", cfg),
		fmt.tprintf("claude-project|.claude/settings.json|%s/.claude/settings.json|false", proj), // offered: Create
		fmt.tprintf("claude-project|.claude/settings.local.json|%s/.claude/settings.local.json|true", proj),
		fmt.tprintf("|CLAUDE.md|%s/CLAUDE.md|true", proj), // pi's instructions file here too: listed once
	}
	for w in want do testing.expectf(t, strings.contains(got, w), "missing %q in\n%s", w, got)
	for p in claude_secret_paths(home, cfg) do testing.expectf(t, !strings.contains(got, p), "%s listed:\n%s", p, got)
	for never in ([]string{".credentials", ".claude.json", "/projects", "history.jsonl", "/sessions", "backups", "file-history", "todos", "shell-snapshots", "plugins", "stats-cache"}) {
		testing.expectf(t, !strings.contains(got, never), "%s listed:\n%s", never, got)
	}
	// with an AGENTS.md (pi's), the project's CLAUDE.md shows in Claude's group
	write_mode(fmt.tprintf("%s/AGENTS.md", proj), "# pi\n", 0o644)
	b2 := strings.builder_make(context.temp_allocator)
	for r in core.settings_file_rows() do fmt.sbprintf(&b2, "%s|%s|%s|%v\n", r.group, r.label, r.path, r.exists)
	testing.expectf(t, strings.contains(strings.to_string(b2), fmt.tprintf("claude-project|CLAUDE.md|%s/CLAUDE.md|true", proj)), "%s", strings.to_string(b2))
	testing.expect_value(t, core.settings_group_label("claude", proj), "Claude Code (global)")
	testing.expect_value(t, core.settings_group_label("claude-project", proj), "Claude Code · proj")
	// the palette's Claude entries (pi's parity: edit_pi_settings…): listed while the file is there
	edit :: proc(id: string) -> string {
		a := action_by_id(id)
		if a == nil do return "no such action"
		c, ok := a.make()
		if !ok do return ""
		return c.(core.Open_File).path
	}
	testing.expect_value(t, edit("edit_claude_settings"), fmt.tprintf("%s/settings.json", cfg))
	testing.expect_value(t, edit("edit_claude_md"), fmt.tprintf("%s/CLAUDE.md", cfg))
	testing.expect_value(t, edit("edit_claude_project_settings"), "") // not there yet: the tree's Create
	// Create makes the project's missing settings file ({}), then opens it
	core.settings_create(fmt.tprintf("%s/.claude/settings.json", proj))
	testing.expect_value(t, read(fmt.tprintf("%s/.claude/settings.json", proj)), "{}\n")
	testing.expect_value(t, edit("edit_claude_project_settings"), fmt.tprintf("%s/.claude/settings.json", proj))
	// JSON Claude Code reads strictly: a bad save is refused like pi's
	for p in ([]string{fmt.tprintf("%s/settings.json", cfg), fmt.tprintf("%s/keybindings.json", cfg), fmt.tprintf("%s/.claude/settings.local.json", proj), fmt.tprintf("%s/.claude/settings.json", proj)}) {
		testing.expectf(t, core.settings_json_kind(p) == .Strict, "%s: strict JSON", p)
	}
	// the global folders open in the tree (their open state kept under the config folder)
	testing.expect_value(t, core.settings_tree_root(fmt.tprintf("%s/skills/s1", cfg)), cfg)
	testing.expect_value(t, core.settings_tree_root(fmt.tprintf("%s/projects/-proj", cfg)), "")
	testing.expect_value(t, core.settings_tree_root(cfg), "")
}

// The Claude Code group's default flags for new tabs: a setting row (no file) with a one-click
// Turn on / Turn off for --dangerously-skip-permissions, and its warning line; off by default.
@(test)
settings_files_claude_default_flags :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	claude_setup(home, proj)
	defer os.unset_env("CLAUDE_CONFIG_DIR")
	rows :: proc() -> string {return sf_text()}
	got := rows()
	warning :: proc() -> string {
		b := strings.builder_make(context.temp_allocator)
		for r in core.settings_file_rows() do if r.path == core.CLAUDE_FLAGS_HEAD_ROW || r.path == core.CLAUDE_FLAGS_WARN_ROW do fmt.sbprintf(&b, "%s %s|", r.label, r.detail)
		return strings.to_string(b)
	}
	testing.expectf(t, strings.contains(got, "rules\nDefault flags for new tabs\nSkip permissions: off [Turn on]\nWarning:\n"), "the rows, off:\n%s", got)
	testing.expect_value(t, warning(), "Default flags for new tabs none|Warning: on, Claude acts without asking|")
	testing.expect(t, core.settings_setting_row(core.CLAUDE_FLAGS_HEAD_ROW) && core.settings_setting_row(core.CLAUDE_FLAGS_ROW) && core.settings_setting_row(core.CLAUDE_FLAGS_WARN_ROW), "settings, not files")
	// the button's action (the palette's too) turns it on: the row says so
	action_run("claude_skip_permissions")
	core.inbox_drain()
	testing.expect(t, !state.settings.claude_skip_permissions, "not before the user confirms")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	if len(state.pending_confirmations) == 1 {
		p := state.pending_confirmations[0]
		testing.expect_value(t, p.summary, core.CLAUDE_SKIP_CONFIRM)
		testing.expect(t, core.run_command(core.Set_Claude_Default_Flags{skip_permissions = true, confirm = p.token}, ui).ok)
	}
	testing.expect(t, state.settings.claude_skip_permissions)
	got = rows()
	testing.expectf(t, strings.contains(got, "Default flags for new tabs\nSkip permissions: ON [Turn off]\nWarning:\n"), "the rows, on:\n%s", got)
	testing.expect_value(t, warning(), "Default flags for new tabs --dangerously-skip-permissions|Warning: Claude acts without asking|")
	action_run("claude_skip_permissions")
	core.inbox_drain()
	testing.expect(t, !state.settings.claude_skip_permissions)
	testing.expect(t, strings.contains(rows(), "[Turn on]"))
}

// Claude Code's credentials, account state, transcripts and caches: never listed, never opened by
// anyone (the user too), not inside an opened folder, not under another name; config files are.
@(test)
settings_files_claude_credentials_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	cfg := claude_setup(home, proj)
	defer os.unset_env("CLAUDE_CONFIG_DIR")
	for p in claude_secret_paths(home, cfg) {
		testing.expectf(t, core.settings_credential(p), "%s is refused", p)
		for c in ([]core.Caller{ui, {kind = .Control}, {kind = .Script}}) {
			r := core.run_command(core.Open_File{path = p}, c)
			testing.expectf(t, !r.ok && r.error == core.CREDENTIAL_REFUSED, "%s opened: %v", p, r)
		}
	}
	for p in ([]string{fmt.tprintf("%s/settings.json", cfg), fmt.tprintf("%s/CLAUDE.md", cfg), fmt.tprintf("%s/keybindings.json", cfg), fmt.tprintf("%s/skills/s1/SKILL.md", cfg), fmt.tprintf("%s/agents/a.md", cfg), fmt.tprintf("%s/.claude/settings.local.json", proj), fmt.tprintf("%s/CLAUDE.md", proj)}) {
		testing.expectf(t, !core.settings_credential(p), "%s is config, not refused", p)
	}
	// the folder itself, and anything new Claude Code may add there: refused unless config
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/some-new-state.json", cfg)), "unknown files in the config folder are refused")
	// another name for the credentials file: a symlink, a hard link
	ln := fmt.tprintf("%s/innocent.json", proj)
	os.symlink(fmt.tprintf("%s/.credentials.json", cfg), ln)
	testing.expect(t, core.settings_credential(ln), "a symlink to .credentials.json")
	hl := fmt.tprintf("%s/innocent2.json", proj)
	os.link(fmt.tprintf("%s/.credentials.json", cfg), hl)
	testing.expect(t, core.settings_credential(hl), "a hard link to .credentials.json")
	hl2 := fmt.tprintf("%s/innocent3.json", proj)
	os.link(fmt.tprintf("%s/.claude.json", home), hl2)
	testing.expect(t, core.settings_credential(hl2), "a hard link to ~/.claude.json")
	// opening a refused folder's contents in the tree: they are hidden
	testing.expect(t, core.settings_hidden(fmt.tprintf("%s/.credentials.json", cfg)))
	// without CLAUDE_CONFIG_DIR: ~/.claude
	os.unset_env("CLAUDE_CONFIG_DIR")
	dflt := fmt.tprintf("%s/.claude", home)
	os.make_directory_all(fmt.tprintf("%s/projects", dflt))
	write_mode(fmt.tprintf("%s/.credentials.json", dflt), "{}", 0o600)
	testing.expect_value(t, core.claude_config_dir(), dflt)
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/.credentials.json", dflt)))
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/projects/x.jsonl", dflt)))
	testing.expect(t, !core.settings_credential(fmt.tprintf("%s/settings.json", dflt)))
	// a config folder that is HOME itself (or above it) never makes all of HOME refused
	os.set_env("CLAUDE_CONFIG_DIR", home)
	testing.expect(t, !core.settings_credential(fmt.tprintf("%s/notes.md", proj)), "HOME's files stay openable")
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/.credentials.json", home)), "the credentials file by name still")
	os.set_env("CLAUDE_CONFIG_DIR", "relative/dir") // not absolute: ignored
	testing.expect_value(t, core.claude_config_dir(), dflt)
}

// Every Claude Code config folder is guarded, not only the one CLAUDE_CONFIG_DIR names now:
// ~/.claude too (another profile's), and any folder that holds Claude's sign-in or account file
// (a third profile). A config folder that is HOME by another name never refuses all of HOME.
@(test)
settings_files_claude_every_config_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home, proj := setup()
	third := claude_setup(home, proj) // holds .credentials.json and .claude.json
	defer os.unset_env("CLAUDE_CONFIG_DIR")
	work := fmt.tprintf("%s/.claude-work", home)
	os.make_directory_all(fmt.tprintf("%s/projects/-w", work))
	os.set_env("CLAUDE_CONFIG_DIR", work)
	dflt := fmt.tprintf("%s/.claude", home)
	os.make_directory_all(fmt.tprintf("%s/projects/-p", dflt))
	write_mode(fmt.tprintf("%s/projects/-p/s.jsonl", dflt), "{}\n", 0o600)
	write_mode(fmt.tprintf("%s/history.jsonl", dflt), "{}\n", 0o600)
	write_mode(fmt.tprintf("%s/settings.json", dflt), "{}", 0o644)
	only := fmt.tprintf("%s/acct-only", home) // holds just an account file
	os.make_directory_all(fmt.tprintf("%s/projects/-q", only))
	write_mode(fmt.tprintf("%s/.claude.json", only), "{}", 0o600)
	write_mode(fmt.tprintf("%s/projects/-q/s.jsonl", only), "{}\n", 0o600)
	for p in ([]string{
		fmt.tprintf("%s/projects/-p/s.jsonl", dflt),
		fmt.tprintf("%s/history.jsonl", dflt),
		fmt.tprintf("%s/.credentials.json", dflt),
		fmt.tprintf("%s/projects/-w/s.jsonl", work),
		fmt.tprintf("%s/projects/-proj/abc.jsonl", third),
		fmt.tprintf("%s/history.jsonl", third),
		fmt.tprintf("%s/projects/-q/s.jsonl", only),
	}) {
		testing.expectf(t, core.settings_credential(p), "%s is refused", p)
		r := core.run_command(core.Open_File{path = p}, ui)
		testing.expectf(t, !r.ok && r.error == core.CREDENTIAL_REFUSED, "%s opened: %v", p, r)
	}
	for p in ([]string{
		fmt.tprintf("%s/settings.json", dflt),
		fmt.tprintf("%s/settings.json", third),
		fmt.tprintf("%s/skills/s1/SKILL.md", third),
		fmt.tprintf("%s/notes.md", proj),
		fmt.tprintf("%s/notes.md", home), // HOME holds .claude.json: still not a config folder
	}) {
		testing.expectf(t, !core.settings_credential(p), "%s is not refused", p)
	}
	// CLAUDE_CONFIG_DIR naming HOME through a symlink: HOME's files stay openable
	link := fmt.tprintf("%s-link", home)
	os.symlink(home, link)
	os.set_env("CLAUDE_CONFIG_DIR", link)
	testing.expect(t, !core.settings_credential(fmt.tprintf("%s/notes.md", proj)), "HOME by another name")
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/projects/-p/s.jsonl", dflt)), "~/.claude still")
}

// The settings registry (core/settings_registry.odin) and the window's actions agree: every action
// a setting names exists, takes its label from the registry, and sends the setting's command.
@(test)
settings_registry_actions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	setup()
	for a in ACTIONS do testing.expectf(t, a.label != "", "action %s has no label", a.id)
	check :: proc(t: ^testing.T, s: ^core.Setting, id: string, own_label: bool) {
		a := action_by_id(id)
		testing.expectf(t, a != nil, "setting %s: no action %s", s.id, id)
		if a == nil do return
		if own_label do testing.expectf(t, a.label == core.setting_action_label(id), "action %s: %q, the registry says %q", id, a.label, core.setting_action_label(id))
		if a.ui != nil || a.pick_folder do return // a UI step first (a field, a folder picker)
		cmd, ok := a.make()
		if ok && cmd != nil do testing.expectf(t, core.command_type(cmd) == s.command || !own_label, "action %s sends %s, setting %s says %s", id, core.command_type(cmd), s.id, s.command)
	}
	for &s in core.SETTINGS {
		if s.action != "" do check(t, &s, s.action, true)
		for c in s.choices do check(t, &s, c.action, true)
		for x in s.also do check(t, &s, x, false)
	}
	testing.expect_value(t, action_label(action_by_id("agent_notify")), "Atlas's notifications")
	testing.expect_value(t, action_label(action_by_id("chats_readonly")), "Start chats read-only")
}

// Every file and row the Settings tab lists has a section and is found by searching its name, and
// the tab's filter keeps the setting rows its words match.
@(test)
settings_registry_reaches_every_row :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	setup()
	state.settings.remote_machines = true
	rows := core.settings_file_rows()
	testing.expect(t, len(rows) > 10, "rows listed")
	for r in rows {
		_, _, ok := core.settings_group_section(r.group)
		testing.expectf(t, ok, "%s (%s) has no section", r.label, r.group)
		found := false
		for h in core.settings_search(r.label, rows) do if (h.kind == .File || h.kind == .Row) && h.row.path == r.path do found = true
		testing.expectf(t, found, "search %q does not find its row (%s)", r.label, r.path)
	}
}

// Settings' rows as text, by group (as the old Settings tab drew them): "[group]", a file's label,
// " (create)" while missing, a setting row's ": what [button]".
@(private = "file")
sf_text :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	cwd := core.settings_project_cwd()
	group := ""
	for r in core.settings_file_rows() {
		if r.group != group {
			group = r.group
			fmt.sbprintf(&b, "[%s]\n", core.settings_group_label(group, cwd))
		}
		strings.write_string(&b, r.label)
		if !r.exists do strings.write_string(&b, " (create)")
		if r.button != "" do fmt.sbprintf(&b, ": %s [%s]", r.detail, r.button)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
