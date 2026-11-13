package main

// Left column tests (sidebar.odin and its commands): projects added by hand,
// new chats, Chats, pins, sort, filter, hidden items, the Open group and
// their persistence. Same rules as core_test.odin (one thread, harmless
// processes).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
sb_reset :: proc(data_dir := "") -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	core.persist = {}
	core.home_root = data_dir
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {sb_clip = strings.clone(s)}, reveal = proc(s: string) {sb_revealed = strings.clone(s)}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	return runtime.heap_allocator()
}

@(private = "file")
sb_clip, sb_revealed: string

@(private = "file")
sb_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/pd-sb-%s-%d", os.get_env("TMPDIR", context.temp_allocator), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r), context.temp_allocator) : d
}

// One session file: id, title, file-name minute (created) and mtime offset.
@(private = "file")
sb_session :: proc(dir, cwd, id, title: string, minute: int, age: time.Duration) {
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/2026-10-30T10-%02d-00-000Z_%s.jsonl", dir, minute, id)
	text := fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n"+`{{"type":"message","message":{{"role":"user","content":"%s"}}}}`+"\n", id, cwd, title)
	_ = os.write_entire_file(path, transmute([]u8)text)
	t := time.time_add(time.now(), -age)
	os.change_times(path, t, t)
}

@(private = "file")
store_dir :: proc(home, cwd: string) -> string {
	name, _ := strings.replace_all(strings.trim_prefix(cwd, "/"), "/", "-", context.temp_allocator)
	return fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
}

@(private = "file")
names :: proc(rows: []core.Sidebar_Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in rows {
		if i > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, r.project != nil ? core.project_name(r.project^) : core.session_label(r.session^))
	}
	return strings.to_string(b)
}

@(private = "file")
by_cwd :: proc(cwd: string) -> ^core.Project {
	for &p in state.projects do if p.group == .Projects && p.cwd == cwd do return &p
	return nil
}

// The pi command line pi-desk ran last (the fake pi writes it).
@(private = "file")
fake_pi :: proc(tag: string) -> string {
	out := fmt.aprintf("%s/pd-sb-args-%s-%d", os.get_env("TMPDIR", context.temp_allocator), tag, time.now()._nsec)
	os.set_env("DECKHAND_CMD", fmt.tprintf(`echo "$* RO=$PI_KIT_READONLY CWD=$(pwd)" > '%s'; exec sleep 30`, out))
	return out
}

@(private = "file")
read_args :: proc(path: string) -> string {
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 do return strings.trim_space(string(data))
		time.sleep(10 * time.Millisecond)
	}
	return ""
}

@(test)
add_project_without_sessions :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	home := sb_dir("home")
	os.set_env("HOME", home)
	core.rescan_now()
	proj := sb_dir("brand-new")
	r := core.run_command(core.Add_Project{cwd = strings.concatenate({proj, "/"})}, {kind = .UI}) // trailing slash: the same folder
	testing.expect(t, r.ok, r.error)
	p := core.find_project(r.created_id)
	testing.expect(t, p != nil && p.cwd == proj, "cleaned cwd")
	testing.expect_value(t, state.selected_project, r.created_id)
	testing.expect_value(t, len(state.sessions), 0)
	testing.expect_value(t, names(core.sidebar_projects()), core.project_name(p^))
	// again: found, not added twice
	r2 := core.run_command(core.Add_Project{cwd = proj})
	testing.expect_value(t, r2.created_id, r.created_id)
	// a new chat there starts pi with an id pi-desk picked
	args := fake_pi("new")
	r = core.run_command(core.New_Chat{project_id = p.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	s := core.find_session(r.created_id)
	got := read_args(args)
	testing.expectf(t, strings.has_prefix(got, fmt.tprintf("--session-id %s RO= CWD=%s", s.pi_session_id, proj)), "pi args: %q", got)
	// pi writes its file and reports it: the project learns its store folder and lists it
	dir := store_dir(home, proj)
	sb_session(dir, proj, s.pi_session_id, "first words", 1, 0)
	file := fmt.tprintf("%s/2026-10-30T10-01-00-000Z_%s.jsonl", dir, s.pi_session_id)
	// (a copy: the update frees the session's old id before it keeps the new one)
	r = core.run_command(core.Pi_Session_Update{tab_id = s.tabs[0].id, pi_session_id = strings.clone(s.pi_session_id, context.temp_allocator), session_file = file}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "first words")
	// relative paths are made absolute
	r = core.run_command(core.Add_Project{cwd = "relative/dir"})
	testing.expect(t, r.ok && strings.has_prefix(core.find_project(r.created_id).cwd, "/"), r.error)
}

@(test)
chats_section :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	chats := fmt.tprintf("%s/Chats", home)
	// a chat pi wrote earlier: pi's own store, cwd ~/Chats
	sb_session(store_dir(home, chats), chats, "chat-1", "Plan a trip", 1, time.Hour)
	core.rescan_now()
	c := core.chats_project()
	testing.expect(t, c != nil, "Chats entry")
	if c == nil do return
	testing.expect_value(t, c.cwd, chats)
	testing.expect_value(t, state.selected_project, u64(0)) // never selected by default
	testing.expect_value(t, names(core.sidebar_projects()), "") // ~/Chats is not also a project row
	testing.expect_value(t, names(core.sidebar_sessions(.Chats)), "Plan a trip")
	r := core.run_command(core.Select_Project{project_id = c.id})
	testing.expect_value(t, r.error, core.CHATS_NOT_A_PROJECT)
	// a new chat: full pi in ~/Chats, pi's normal store (so `cd ~/Chats && pi --resume` finds it)
	os.remove(chats) // made on the first new chat (no files in it: the store is pi's)
	args := fake_pi("chat")
	r = core.run_command(core.New_Chat{project_id = c.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	s := core.find_session(r.created_id)
	got := read_args(args)
	testing.expectf(t, got == fmt.tprintf("--session-id %s RO= CWD=%s", s.pi_session_id, chats), "pi args: %q", got)
	testing.expect(t, os.is_dir(chats), "~/Chats made")
	testing.expect_value(t, core.session_project_name(s), "Chats")
	// resume the listed one
	r = core.run_command(core.Open_Session_Cmd{project_id = c.id, pi_session_id = "chat-1"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	// saved as a chat, restored into Chats (not a project at ~/Chats)
	core.persist_init(data)
	text := strings.clone(core.workspace_json())
	testing.expect(t, strings.contains(text, `"chat":true`), text)
	sb_reset(data)
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 1)
	testing.expect_value(t, state.open_sessions[0].project_id, core.chats_project().id)
	testing.expect(t, by_cwd(chats) == nil, "no project made for ~/Chats")
	// adding ~/Chats by hand finds Chats, not a second entry
	r = core.run_command(core.Add_Project{cwd = chats})
	testing.expect(t, !r.ok || r.created_id != 0 && by_cwd(chats) == nil, r.error)
}

// Chats settings: where new chats run (and are stored by pi). User-only; saved.
@(test)
chats_settings :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	old := fmt.tprintf("%s/Chats", home)
	sb_session(store_dir(home, old), old, "old-1", "older chat", 1, time.Hour)
	core.rescan_now()
	ui := core.Caller{kind = .UI}
	// agents cannot change them
	testing.expect_value(t, core.run_command(core.Set_Folder{kind = .Chats, path = "/tmp"}, {kind = .Script}).error, "not allowed for this caller")
	// a chat's pi is full pi (what it may do: the chats folder's AGENTS.md)
	args := fake_pi("ro")
	r := core.run_command(core.New_Chat{project_id = core.chats_project().id}, ui)
	testing.expect(t, strings.contains(read_args(args), " RO= ") && !strings.contains(read_args(args), "--tools"), read_args(args))
	core.run_command(core.Close_Session{session = r.created_id}, {kind = .Internal})
	// another folder: new chats go there; the old folder's chats stay where they are (a project now)
	elsewhere := sb_dir("talks")
	testing.expect_value(t, core.run_command(core.Set_Folder{kind = .Chats, path = "relative"}, ui).error, "path must be absolute")
	r = core.run_command(core.Set_Folder{kind = .Chats, path = elsewhere}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.chats_project().cwd, elsewhere)
	testing.expect_value(t, len(state.chats), 0)
	testing.expect(t, by_cwd(old) != nil, "the old folder is an ordinary project now")
	args = fake_pi("dir")
	core.run_command(core.New_Chat{project_id = core.chats_project().id}, ui)
	testing.expect(t, strings.contains(read_args(args), fmt.tprintf("CWD=%s", elsewhere)), read_args(args))
	// saved, and back after a restart
	core.persist_init(data)
	text := strings.clone(core.workspace_json())
	sb_reset(data)
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, state.settings.folders[.Chats], elsewhere)
	testing.expect_value(t, core.chats_project().cwd, elsewhere)
	testing.expect(t, by_cwd(old) != nil)
	// "" = back to ~/Chats
	core.run_command(core.Set_Folder{kind = .Chats, path = ""}, ui)
	testing.expect_value(t, core.chats_project().cwd, old)
	testing.expect(t, by_cwd(old) == nil)
}

@(test)
pin_sort_filter_hide :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	a, b, c := sb_dir("alpha"), sb_dir("bravo"), sb_dir("charlie")
	// alpha: oldest activity, created last; charlie: newest activity
	sb_session(store_dir(home, a), a, "a-1", "Zebra notes", 3, 3 * time.Hour)
	sb_session(store_dir(home, b), b, "b-1", "bravo work", 2, 2 * time.Hour)
	sb_session(store_dir(home, c), c, "c-1", "charlie talk", 1, time.Hour)
	sb_session(store_dir(home, c), c, "c-2", "Apple pie", 4, 4 * time.Hour)
	core.rescan_now()
	pa, pb, pc := by_cwd(a), by_cwd(b), by_cwd(c)
	core.run_command(core.Rename_Project{project_id = pa.id, name = "alpha"})
	core.run_command(core.Rename_Project{project_id = pb.id, name = "bravo"})
	core.run_command(core.Rename_Project{project_id = pc.id, name = "charlie"})
	testing.expect_value(t, names(core.sidebar_projects()), "charlie,bravo,alpha") // recent activity (default)
	core.run_command(core.Set_Sort{section = .Projects, by = .Name}, {kind = .Script})
	testing.expect_value(t, names(core.sidebar_projects()), "alpha,bravo,charlie")
	// pinned on top, in pinned order, whatever the sort
	r := core.run_command(core.Set_Pinned{project_id = pc.id, pinned = true}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	core.run_command(core.Set_Pinned{project_id = pb.id, pinned = true})
	testing.expect_value(t, names(core.sidebar_projects()), "charlie,bravo,alpha")
	core.run_command(core.Set_Pinned{project_id = pb.id, pinned = true, index = 0}) // move up
	testing.expect_value(t, names(core.sidebar_projects()), "bravo,charlie,alpha")
	// sessions of charlie: recent first, then by name, created
	core.run_command(core.Select_Project{project_id = pc.id})
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "charlie talk,Apple pie")
	core.run_command(core.Set_Sort{section = .Sessions, by = .Created})
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "Apple pie,charlie talk") // minute 4 > 1
	core.run_command(core.Set_Pinned{pi_session_id = "c-1", pinned = true})
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "charlie talk,Apple pie")
	// hide: gone from the list, back with show_hidden; nothing deleted
	r = core.run_command(core.Set_Hidden{project_id = pa.id, hidden = true}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, names(core.sidebar_projects()), "bravo,charlie")
	core.run_command(core.Set_Filter{show_hidden = true})
	rows := core.sidebar_projects()
	testing.expect_value(t, names(rows), "bravo,charlie,alpha")
	testing.expect(t, rows[2].hidden)
	testing.expect(t, os.exists(a), "the folder stays")
	core.run_command(core.Set_Filter{show_hidden = false})
	// quick filter: pinned
	core.run_command(core.Set_Filter{pinned = true})
	testing.expect_value(t, names(core.sidebar_projects()), "bravo,charlie")
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "charlie talk")
	core.run_command(core.Set_Filter{pinned = false})
	// errors
	r = core.run_command(core.Set_Pinned{pinned = true})
	testing.expect_value(t, r.error, "give one of cwd, project_id or pi_session_id")
	r = core.run_command(core.Set_Pinned{project_id = pa.id, pi_session_id = "c-1", pinned = true})
	testing.expect_value(t, r.error, "give one of cwd, project_id or pi_session_id")
	r = core.run_command(core.Set_Hidden{pi_session_id = "nope", hidden = true})
	testing.expect_value(t, r.error, "no such session")
	r = core.run_command(core.Set_Pinned{project_id = core.chats_project().id, pinned = true})
	testing.expect_value(t, r.error, core.CHATS_NOT_A_PROJECT)
	// reveal and copy path
	r = core.run_command(core.Copy_Path{project_id = pc.id, pi_session_id = "c-2"}, {kind = .Script})
	testing.expect(t, r.ok && strings.has_suffix(sb_clip, "_c-2.jsonl"), sb_clip)
	r = core.run_command(core.Reveal_Path{project_id = pb.id})
	testing.expect(t, r.ok && sb_revealed == b, sb_revealed)
	// a Finder window: the user and control (the Home agent) only, not scripts
	testing.expect(t, core.caller_may({kind = .UI}, core.Reveal_Path{}) && core.caller_may({kind = .Control}, core.Reveal_Path{}), "user and control may reveal")
	testing.expect(t, !core.caller_may({kind = .Script}, core.Reveal_Path{}), "a script may not reveal")
	testing.expect(t, !core.caller_may({kind = .Panel, tab_id = 1}, core.Reveal_Path{}), "a pi tab may not reveal")
	// a session filter text and a quick filter are not saved; the rest is
	core.run_command(core.Set_Filter{text = "zzz", running = true})
	core.run_command(core.Set_Sidebar_Folded{section = .Chats, folded = true})
	core.persist_init(data)
	text := strings.clone(core.workspace_json())
	testing.expect(t, !strings.contains(text, "zzz"), text)
	sb_reset(data)
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, state.sidebar.sort[.Projects], core.Sort_By.Name)
	testing.expect_value(t, state.sidebar.sort[.Sessions], core.Sort_By.Created)
	testing.expect_value(t, state.sidebar.sort[.Chats], core.Sort_By.Recent)
	testing.expect(t, state.sidebar.folded[.Chats] && !state.sidebar.folded[.Open])
	testing.expect_value(t, state.sidebar.filter, "")
	testing.expect(t, !state.sidebar.only_running)
	testing.expect_value(t, len(state.sidebar.pinned_projects), 2)
	testing.expect_value(t, state.sidebar.pinned_projects[0], b)
	testing.expect_value(t, state.sidebar.pinned_sessions[0], "c-1")
	testing.expect_value(t, state.sidebar.hidden_projects[0], a)
	testing.expect_value(t, names(core.sidebar_projects()), "bravo,charlie")
	again := core.workspace_json()
	testing.expectf(t, again == text, "second save differs:\n%s\n---\n%s", text, again)
	// adding a hidden project again shows it
	core.run_command(core.Add_Project{cwd = a})
	testing.expect_value(t, len(state.sidebar.hidden_projects), 0)
}

@(test)
filter_ranking :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	os.set_env("HOME", sb_dir("home"))
	core.rescan_now()
	for name in ([]string{"other", "pi-desk", "desktop-tools", "dense kit"}) {
		r := core.run_command(core.Add_Project{cwd = sb_dir(name)})
		core.run_command(core.Rename_Project{project_id = r.created_id, name = name})
	}
	core.run_command(core.Set_Filter{text = "desk"})
	// a prefix beats a word start, which beats a scattered match; "other" has none
	testing.expect_value(t, names(core.sidebar_projects()), "desktop-tools,pi-desk,dense kit")
	// every word must match (name or path)
	core.run_command(core.Set_Filter{text = "desk pi-"})
	testing.expect_value(t, names(core.sidebar_projects()), "pi-desk")
	core.run_command(core.Set_Filter{text = "nothing-like-it"})
	testing.expect_value(t, len(core.sidebar_projects()), 0)
	testing.expect(t, core.sidebar_filtering())
	// control characters never reach the state; long text is cut
	core.run_command(core.Set_Filter{text = "a\nb"})
	testing.expect_value(t, state.sidebar.filter, "a b")
	core.run_command(core.Set_Filter{text = strings.repeat("x", 500, context.temp_allocator)})
	testing.expect_value(t, len(state.sidebar.filter), core.FILTER_MAX)
}

@(test)
open_group_and_browsing :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	a, b := sb_dir("one"), sb_dir("two")
	sb_session(store_dir(home, a), a, "a-1", "first", 1, time.Hour)
	sb_session(store_dir(home, b), b, "b-1", "second", 2, time.Hour)
	core.rescan_now()
	pa, pb := by_cwd(a), by_cwd(b)
	testing.expect_value(t, len(core.sidebar_open()), 0) // nothing open: no Open group
	r := core.run_command(core.Open_Session_Cmd{project_id = pa.id, pi_session_id = "a-1"}, {kind = .UI})
	sa := r.created_id
	r = core.run_command(core.Select_Project{project_id = pb.id})
	r = core.run_command(core.Open_Session_Cmd{project_id = pb.id, pi_session_id = "b-1"}, {kind = .UI})
	sbid := r.created_id
	r = core.run_command(core.New_Chat{project_id = core.chats_project().id}, {kind = .UI})
	chat := r.created_id
	open := core.sidebar_open()
	testing.expect_value(t, len(open), 3)
	testing.expect_value(t, open[0].id, chat) // current first, then most recently shown
	testing.expect_value(t, open[1].id, sbid)
	testing.expect_value(t, open[2].id, sa)
	// browsing projects never changes what the centre shows
	core.run_command(core.Select_Project{project_id = pa.id}, {kind = .UI})
	testing.expect_value(t, state.current_session, chat)
	core.run_command(core.Select_Project{project_id = pb.id}, {kind = .UI})
	testing.expect_value(t, state.current_session, chat)
	// focusing from the Open group: current moves to the top
	core.run_command(core.Focus_Session{session = sa}, {kind = .UI})
	testing.expect_value(t, core.sidebar_open()[0].id, sa)
	testing.expect_value(t, core.sidebar_open()[1].id, chat)
	// one waiting for you: after the current one, before those shown more recently; the Dock's count
	testing.expect_value(t, core.sessions_waiting_count(), 0)
	core.find_session(sbid).tabs[0].waiting = true
	open = core.sidebar_open()
	testing.expect_value(t, open[0].id, sa)
	testing.expect_value(t, open[1].id, sbid)
	testing.expect_value(t, open[2].id, chat)
	testing.expect_value(t, core.sessions_waiting_count(), 1)
	core.find_session(sbid).tabs[0].waiting = false
	testing.expect_value(t, core.sessions_waiting_count(), 0)
	// the filter applies: title or project name
	core.run_command(core.Set_Filter{text = "second"})
	testing.expect_value(t, len(core.sidebar_open()), 1)
	testing.expect_value(t, core.sidebar_open()[0].id, sbid)
	core.run_command(core.Set_Filter{text = "chats"})
	testing.expect_value(t, len(core.sidebar_open()), 1)
	testing.expect_value(t, core.sidebar_open()[0].id, chat)
	// Home is never in it
	testing.expect(t, core.run_command(core.Set_Sidebar_Folded{section = .Open, folded = true}).ok)
	testing.expect(t, state.sidebar.folded[.Open])
}

// ---- review round 1 ----

// pi in an open session waits for the user: neither hiding nor a filter
// (from anyone, control included) conceals it.
@(test)
waiting_is_never_concealed :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	a, b := sb_dir("wa"), sb_dir("wb")
	sb_session(store_dir(home, a), a, "w-1", "needs an answer", 1, time.Hour)
	sb_session(store_dir(home, b), b, "o-1", "other", 2, time.Hour)
	core.rescan_now()
	pa := by_cwd(a)
	core.run_command(core.Select_Project{project_id = pa.id})
	r := core.run_command(core.Open_Session_Cmd{project_id = pa.id, pi_session_id = "w-1"}, {kind = .UI})
	s := core.find_session(r.created_id)
	r = core.run_command(core.Pi_Status_Update{tab_id = s.tabs[0].id, agent = .Idle, waiting = true}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	control := core.Caller{kind = .Control}
	testing.expect(t, core.run_command(core.Set_Hidden{pi_session_id = "w-1", hidden = true}, control).ok)
	testing.expect(t, core.run_command(core.Set_Hidden{project_id = pa.id, hidden = true}, control).ok)
	testing.expect(t, core.run_command(core.Set_Filter{text = "zzz", running = true}, control).ok)
	testing.expect_value(t, len(core.sidebar_open()), 1) // still in the Open group
	testing.expect_value(t, names(core.sidebar_projects()), core.project_name(pa^)) // its project row stays
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "") // the filter text takes it out of the list
	testing.expect_value(t, core.sidebar_waiting_filtered(), 1) // counted
	core.run_command(core.Set_Filter{text = "", running = false}, control)
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "needs an answer") // hiding does not apply to waiting work
	testing.expect_value(t, core.sidebar_waiting_filtered(), 0)
	// the filter alone hides it from the session list: counted
	core.run_command(core.Set_Filter{running = false})
	core.run_command(core.Set_Hidden{pi_session_id = "w-1", hidden = false})
	core.run_command(core.Set_Filter{text = "other"})
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "") // filtered from the list...
	testing.expect_value(t, core.sidebar_waiting_filtered(), 1) // ...and counted ("1 waiting (filtered)")
	testing.expect_value(t, len(core.sidebar_open()), 1) // the Open group still has it
	testing.expect_value(t, names(core.sidebar_projects()), core.project_name(pa^))
}

// The texts the whole window draws, one per line.
@(private = "file")
sb_drawn :: proc() -> string {
	cmds := ui_layout(2000, 1400)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		tx := c.renderData.text
		strings.write_string(&b, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// A question needs the user as a block does (tab_need, as the Attention view, the pill and ⌥⌘A
// count it): a folded project tree and a folded Open group keep it, and the filter counts it.
@(test)
question_is_never_concealed :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	if !testing.expect(t, audit_ui(), "fonts") do return
	defer state^ = core.State{}
	// a project, its one session open in a pi tab whose agent asked a question (no process: nothing
	// can end it meanwhile)
	append(&state.projects, core.Project{id = 1, group = .Projects, cwd = strings.clone("/tmp/sb-q-proj"), label = strings.clone("qproj")})
	state.selected_project = 1
	append(&state.sessions, core.Session{id = strings.clone("q-1"), path = strings.clone("/tmp/sb-q-proj/q-1.jsonl"), title = strings.clone("asks you something")})
	o := core.Open_Session{id = 2, project_id = 1, pi_session_id = strings.clone("q-1"), cwd = strings.clone("/tmp/sb-q-proj"), title = strings.clone("asks you something")}
	tab := core.Tab{id = 3, kind = core.Pi_Tab{}, title = strings.clone("pi"), status = .Running, agent = .Idle, question = true}
	tab.prog.progress = -1
	append(&o.tabs, tab)
	o.active_tab = 3
	core.session_panes_init(&o)
	append(&state.open_sessions, o)
	q := &state.open_sessions[0].tabs[0]
	testing.expect(t, core.session_waiting("q-1"))
	// the filter takes it out of the list: counted ("1 waiting (filtered)")
	core.run_command(core.Set_Filter{text = "zzz"})
	testing.expectf(t, core.sidebar_waiting_filtered() == 1, "rows %q", names(core.sidebar_sessions(.Sessions)))
	core.run_command(core.Set_Filter{text = ""})
	// folded: the project's tree and the Open group keep it
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 400, .Sessions
	project_row_click(1) // the selected project's row: folds its sessions
	defer tree.folded = false
	state.sidebar.folded[.Open] = true
	testing.expect(t, tree.folded)
	// drawn as often as when it waits on a permission: in the folded tree, the folded Open group
	// (and the empty centre's list of what needs you)
	q.question, q.waiting = false, true
	blocked := strings.count(sb_drawn(), "asks you something")
	testing.expect(t, blocked >= 2, "a waiting session shows folded")
	q.question, q.waiting = true, false
	testing.expect_value(t, strings.count(sb_drawn(), "asks you something"), blocked)
	q.question = false // answered
	testing.expect(t, !core.session_waiting("q-1"))
	testing.expect(t, !strings.contains(sb_drawn(), "asks you something"), "answered: folded away")
}

// Paths are resolved (pi runs in the real folder): a symlink adds the same
// project the store has, and pins are kept by the real path.
@(test)
symlinked_project_is_the_real_one :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	home := sb_dir("home")
	os.set_env("HOME", home)
	real := sb_dir("real")
	link := fmt.tprintf("%s/link", sb_dir("links"))
	testing.expect_value(t, posix.symlink(strings.clone_to_cstring(real, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator)), posix.result(.OK))
	r := core.run_command(core.Add_Project{cwd = link})
	testing.expect(t, r.ok, r.error)
	p := core.find_project(r.created_id)
	testing.expect_value(t, p.cwd, real)
	core.run_command(core.Set_Pinned{project_id = p.id, pinned = true})
	testing.expect_value(t, state.sidebar.pinned_projects[0], real)
	// pi writes its session under the real path; a rescan finds one project, not two
	sb_session(store_dir(home, real), real, "s-1", "hello", 1, 0)
	core.rescan_now()
	n := 0
	for q in state.projects do if q.group == .Projects do n += 1
	testing.expect_value(t, n, 1)
	testing.expect_value(t, core.pi_store_dir(real), store_dir(home, real))
}

// Entries for things that are gone can be removed, and do not pile up.
@(test)
stale_pins_and_hidden :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	os.set_env("HOME", sb_dir("home"))
	core.rescan_now()
	gone := "/nonexistent/pi-desk-gone"
	core.run_command(core.Restore_Sidebar{pinned_projects = {gone}, hidden_projects = {gone}, pinned_sessions = {"gone-id"}, hidden_sessions = {"gone-id"}})
	r := core.run_command(core.Set_Pinned{cwd = gone, pinned = false}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.sidebar.pinned_projects), 0)
	r = core.run_command(core.Set_Pinned{pi_session_id = "gone-id", pinned = false}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.sidebar.pinned_sessions), 0)
	r = core.run_command(core.Set_Hidden{pi_session_id = "gone-id", hidden = false})
	testing.expect(t, r.ok, r.error)
	// pinning something unknown is still refused
	r = core.run_command(core.Set_Pinned{pi_session_id = "gone-id", pinned = true})
	testing.expect_value(t, r.error, "no such session")
	// saving drops projects whose folder is gone
	core.persist_init(data)
	text := core.workspace_json()
	testing.expect(t, !strings.contains(text, gone), text)
	// a full list makes room by dropping entries whose folder is gone
	stale := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< core.SIDEBAR_LIST_MAX do append(&stale, fmt.tprintf("/nonexistent/p%d", i))
	core.run_command(core.Restore_Sidebar{pinned_projects = stale[:]})
	real := sb_dir("live")
	pr := core.run_command(core.Add_Project{cwd = real})
	r = core.run_command(core.Set_Pinned{project_id = pr.created_id, pinned = true})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.sidebar.pinned_projects[0], real)
}

// Enter in the filter takes the best match, not the first (pinned) row.
@(test)
filter_enter_best_match :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	os.set_env("HOME", sb_dir("home"))
	core.rescan_now()
	ids: [2]u64
	for name, i in ([]string{"xdeskx-scattered", "desk"}) {
		r := core.run_command(core.Add_Project{cwd = sb_dir(name)})
		core.run_command(core.Rename_Project{project_id = r.created_id, name = name})
		ids[i] = r.created_id
	}
	core.run_command(core.Set_Pinned{project_id = ids[0], pinned = true})
	core.run_command(core.Select_Project{project_id = ids[0]})
	core.run_command(core.Set_Filter{text = "desk"})
	testing.expect_value(t, names(core.sidebar_projects()), "xdeskx-scattered,desk") // pinned first
	cmd := core.sidebar_best_match()
	sp, ok := cmd.(core.Select_Project)
	testing.expect(t, ok && sp.project_id == ids[1], "the better match")
}

// A chat's PI_KIT_READONLY cannot be overridden by pi-desk's own environment.
@(test)
child_env_drops_readonly :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	os.set_env("PI_KIT_READONLY", "0")
	defer os.unset_env("PI_KIT_READONLY")
	for e in core.child_env({"PI_KIT_READONLY=1"}) do testing.expect(t, e != "PI_KIT_READONLY=0", "inherited value dropped")
}

// Open-session titles and ages are read at most once a second (animated
// frames would stat each session file several times per frame).
@(test)
open_session_title_cached :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	home := sb_dir("home")
	os.set_env("HOME", home)
	a := sb_dir("ca")
	sb_session(store_dir(home, a), a, "t-1", "cached title", 1, 0)
	core.rescan_now()
	r := core.run_command(core.Open_Session_Cmd{project_id = by_cwd(a).id, pi_session_id = "t-1"})
	s := core.find_session(r.created_id)
	core.run_command(core.Add_Project{cwd = sb_dir("elsewhere")}) // t-1 is not listed any more: read from its file
	before := core.open_session_stats
	for _ in 0 ..< 10 {
		testing.expect_value(t, core.open_session_title(s), "cached title")
		_ = core.open_session_age(s)
	}
	testing.expect(t, core.open_session_stats - before <= 1, "at most one stat")
}

// p with symlinks resolved (macOS: /tmp is /private/tmp), as add_project keeps it.
resolved :: proc(p: string) -> string {
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(p, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r), context.temp_allocator) : p
}

// A new chat or session (open, no session file yet) is listed in its
// section at once: under Chats or its project, newest first, "Untitled …".
@(test)
new_sessions_are_listed :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	chats := fmt.tprintf("%s/Chats", home)
	proj := fmt.tprintf("%s/code/alpha", home)
	sb_session(store_dir(home, chats), chats, "chat-1", "Plan a trip", 1, time.Hour)
	sb_session(store_dir(home, proj), proj, "a1", "Write the notes", 1, time.Hour)
	core.rescan_now()
	c := core.chats_project()
	if !testing.expect(t, c != nil && state.selected_project != 0, "Chats and a project") do return
	r := core.run_command(core.New_Chat{project_id = c.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	chat_id := core.find_session(r.created_id).pi_session_id
	r = core.run_command(core.New_Chat{project_id = state.selected_project}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	sess_id := core.find_session(r.created_id).pi_session_id
	rows := core.sidebar_sessions(.Chats)
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, rows[0].session.id, chat_id)
		testing.expect_value(t, core.session_label(rows[0].session^, true), "Untitled chat")
		testing.expect_value(t, rows[1].session.id, "chat-1")
	}
	rows = core.sidebar_sessions(.Sessions)
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, rows[0].session.id, sess_id)
		testing.expect_value(t, core.session_label(rows[0].session^), "Untitled session")
	}
	// a new one's place does not move from one call (frame) to the next: its
	// time is when it was opened, not "now" (a row whose selection fade
	// flips each frame redraws for ever)
	core.run_command(core.New_Chat{project_id = c.id}, {kind = .UI})
	a := core.sessions_with_new(.Chats, state.chats[:])
	b := core.sessions_with_new(.Chats, state.chats[:])
	testing.expect_value(t, len(a), 3)
	for x, i in a do testing.expectf(t, x.id == b[i].id && x.modified == b[i].modified, "row %d moved: %v / %v", i, x.modified, b[i].modified)
	// the filter applies to them like any row
	core.run_command(core.Set_Filter{text = "trip"}, {kind = .UI})
	testing.expect_value(t, names(core.sidebar_sessions(.Chats)), "Plan a trip")
	core.run_command(core.Set_Filter{text = ""}, {kind = .UI})
	core.close_all()
}

// The filter and the Pinned chip keep a project whose sessions match (the
// selected one's rows, or an open session's title) even when its own name
// does not: Enter must never open a row that is not shown.
@(test)
filter_keeps_projects_of_matching_sessions :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	a, b := sb_dir("alpha"), sb_dir("bravo")
	sb_session(store_dir(home, a), a, "a-1", "Zebra notes", 1, time.Hour)
	sb_session(store_dir(home, b), b, "b-1", "Quokka plan", 2, 2 * time.Hour)
	core.rescan_now()
	pa, pb := by_cwd(a), by_cwd(b)
	core.run_command(core.Rename_Project{project_id = pa.id, name = "alpha"})
	core.run_command(core.Rename_Project{project_id = pb.id, name = "bravo"})
	core.run_command(core.Select_Project{project_id = pa.id})
	// a session title only: its project stays, with the match under it
	core.run_command(core.Set_Filter{text = "zebra"}, {kind = .UI})
	testing.expect_value(t, names(core.sidebar_projects()), "alpha")
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "Zebra notes")
	// an open session in another project: that project stays too
	r := core.run_command(core.Open_Session_Cmd{project_id = pb.id, pi_session_id = "b-1"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	core.run_command(core.Select_Project{project_id = pa.id})
	core.run_command(core.Set_Filter{text = "quokka"}, {kind = .UI})
	testing.expect_value(t, names(core.sidebar_projects()), "bravo")
	// the Pinned chip: a pinned session keeps its unpinned project
	core.run_command(core.Set_Filter{text = ""}, {kind = .UI})
	core.run_command(core.Set_Pinned{pi_session_id = "a-1", pinned = true}, {kind = .UI})
	core.run_command(core.Set_Filter{pinned = true}, {kind = .UI})
	testing.expect_value(t, names(core.sidebar_sessions(.Sessions)), "Zebra notes")
	testing.expect_value(t, names(core.sidebar_projects()), "alpha")
	core.run_command(core.Set_Filter{pinned = false}, {kind = .UI})
	core.close_all()
}

// A session row's "…" acts in the session's own project: a new chat (no
// file yet, not listed) is in Chats, whatever project is selected.
@(test)
session_menu_project_of_new_chat :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	a := sb_dir("alpha")
	sb_session(store_dir(home, a), a, "a-1", "Zebra notes", 1, time.Hour)
	core.rescan_now()
	c := core.chats_project()
	if !testing.expect(t, c != nil && state.selected_project != 0, "Chats and a project") do return
	r := core.run_command(core.New_Chat{project_id = c.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	sid := core.find_session(r.created_id).pi_session_id
	testing.expect_value(t, session_row_project(sid), c.id)
	testing.expect_value(t, session_row_project("a-1"), state.selected_project)
	core.close_all()
}

// pi-subagents keeps a folder named like each session file ("<ts>_<id>",
// no .jsonl) beside it: the lookups by id find the file, never the folder,
// and the info of a folder says it is not a session file.
@(test)
session_file_lookup_skips_same_named_folder :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	dir := sb_dir("store")
	cwd := sb_dir("proj")
	sb_session(dir, cwd, "s-1", "Subagents ran here", 1, 0)
	file := fmt.tprintf("%s/2026-10-30T10-01-00-000Z_s-1.jsonl", dir)
	folder := fmt.tprintf("%s/2026-10-30T10-01-00-000Z_s-1", dir)
	os.make_directory_all(fmt.tprintf("%s/run-1", folder))
	// not the selected project: found by listing its store folder
	p := core.Project{id = 99, dir = dir, cwd = cwd}
	testing.expect_value(t, core.find_session_file(p, "s-1"), file)
	testing.expect_value(t, core.find_session_file(core.Project{id = 98, cwd = cwd}, "s-1", dir), file)
	testing.expect_value(t, core.session_file_in(dir, "s-1"), file)
	// only a folder: no session
	os.remove(file)
	testing.expect_value(t, core.find_session_file(p, "s-1"), "")
	testing.expect_value(t, core.session_file_in(dir, "s-1"), "")
	_, err := core.session_facts_read(folder)
	testing.expect_value(t, err, "not a session file")
}
