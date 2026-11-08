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

@(private = "file")
sb_reset :: proc(data_dir := "") -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	persist = {}
	home_root = data_dir
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {sb_clip = strings.clone(s)}, reveal = proc(s: string) {sb_revealed = strings.clone(s)}}
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
names :: proc(rows: []Sidebar_Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in rows {
		if i > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, r.project != nil ? project_name(r.project^) : session_label(r.session^))
	}
	return strings.to_string(b)
}

@(private = "file")
by_cwd :: proc(cwd: string) -> ^Project {
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
	rescan_now()
	proj := sb_dir("brand-new")
	r := run_command(Add_Project{cwd = strings.concatenate({proj, "/"})}, {kind = .UI}) // trailing slash: the same folder
	testing.expect(t, r.ok, r.error)
	p := find_project(r.created_id)
	testing.expect(t, p != nil && p.cwd == proj, "cleaned cwd")
	testing.expect_value(t, state.selected_project, r.created_id)
	testing.expect_value(t, len(state.sessions), 0)
	testing.expect_value(t, names(sidebar_projects()), project_name(p^))
	// again: found, not added twice
	r2 := run_command(Add_Project{cwd = proj})
	testing.expect_value(t, r2.created_id, r.created_id)
	// a new chat there starts pi with an id pi-desk picked
	args := fake_pi("new")
	r = run_command(New_Chat{project_id = p.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	s := find_session(r.created_id)
	got := read_args(args)
	testing.expectf(t, strings.has_prefix(got, fmt.tprintf("--session-id %s RO= CWD=%s", s.pi_session_id, proj)), "pi args: %q", got)
	// pi writes its file and reports it: the project learns its store folder and lists it
	dir := store_dir(home, proj)
	sb_session(dir, proj, s.pi_session_id, "first words", 1, 0)
	file := fmt.tprintf("%s/2026-10-30T10-01-00-000Z_%s.jsonl", dir, s.pi_session_id)
	// (a copy: the update frees the session's old id before it keeps the new one)
	r = run_command(Pi_Session_Update{tab_id = s.tabs[0].id, pi_session_id = strings.clone(s.pi_session_id, context.temp_allocator), session_file = file}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "first words")
	// relative paths are made absolute
	r = run_command(Add_Project{cwd = "relative/dir"})
	testing.expect(t, r.ok && strings.has_prefix(find_project(r.created_id).cwd, "/"), r.error)
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
	rescan_now()
	c := chats_project()
	testing.expect(t, c != nil, "Chats entry")
	if c == nil do return
	testing.expect_value(t, c.cwd, chats)
	testing.expect_value(t, state.selected_project, u64(0)) // never selected by default
	testing.expect_value(t, names(sidebar_projects()), "") // ~/Chats is not also a project row
	testing.expect_value(t, names(sidebar_sessions(.Chats)), "Plan a trip")
	r := run_command(Select_Project{project_id = c.id})
	testing.expect_value(t, r.error, CHATS_NOT_A_PROJECT)
	// a new chat: full pi in ~/Chats, pi's normal store (so `cd ~/Chats && pi --resume` finds it)
	os.remove(chats) // made on the first new chat (no files in it: the store is pi's)
	args := fake_pi("chat")
	r = run_command(New_Chat{project_id = c.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	s := find_session(r.created_id)
	got := read_args(args)
	testing.expectf(t, got == fmt.tprintf("--session-id %s RO= CWD=%s", s.pi_session_id, chats), "pi args: %q", got)
	testing.expect(t, os.is_dir(chats), "~/Chats made")
	testing.expect_value(t, session_project_name(s), "Chats")
	// resume the listed one
	r = run_command(Open_Session_Cmd{project_id = c.id, pi_session_id = "chat-1"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	// saved as a chat, restored into Chats (not a project at ~/Chats)
	persist_init(data)
	text := strings.clone(workspace_json())
	testing.expect(t, strings.contains(text, `"chat":true`), text)
	sb_reset(data)
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 1)
	testing.expect_value(t, state.open_sessions[0].project_id, chats_project().id)
	testing.expect(t, by_cwd(chats) == nil, "no project made for ~/Chats")
	// adding ~/Chats by hand finds Chats, not a second entry
	r = run_command(Add_Project{cwd = chats})
	testing.expect(t, !r.ok || r.created_id != 0 && by_cwd(chats) == nil, r.error)
}

// Chats settings: where new chats run (and are stored by pi), read-only or
// not. User-only; saved.
@(test)
chats_settings :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	home := sb_dir("home")
	os.set_env("HOME", home)
	old := fmt.tprintf("%s/Chats", home)
	sb_session(store_dir(home, old), old, "old-1", "older chat", 1, time.Hour)
	rescan_now()
	ui := Caller{kind = .UI}
	// agents cannot change them
	testing.expect_value(t, run_command(Set_Chats_Readonly{on = true}, {kind = .Control}).error, "not allowed for this caller")
	testing.expect_value(t, run_command(Set_Folder{kind = .Chats, path = "/tmp"}, {kind = .Script}).error, "not allowed for this caller")
	// read-only chats
	testing.expect(t, run_command(Set_Chats_Readonly{on = true}, ui).ok)
	args := fake_pi("ro")
	r := run_command(New_Chat{project_id = chats_project().id}, ui)
	testing.expect(t, strings.contains(read_args(args), " RO=1 "), read_args(args))
	run_command(Close_Session{session = r.created_id}, {kind = .Internal})
	// another folder: new chats go there; the old folder's chats stay where they are (a project now)
	elsewhere := sb_dir("talks")
	testing.expect_value(t, run_command(Set_Folder{kind = .Chats, path = "relative"}, ui).error, "path must be absolute")
	r = run_command(Set_Folder{kind = .Chats, path = elsewhere}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, chats_project().cwd, elsewhere)
	testing.expect_value(t, len(state.chats), 0)
	testing.expect(t, by_cwd(old) != nil, "the old folder is an ordinary project now")
	args = fake_pi("dir")
	run_command(New_Chat{project_id = chats_project().id}, ui)
	testing.expect(t, strings.contains(read_args(args), fmt.tprintf("CWD=%s", elsewhere)), read_args(args))
	// saved, and back after a restart
	persist_init(data)
	text := strings.clone(workspace_json())
	sb_reset(data)
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, state.settings.folders[.Chats], elsewhere)
	testing.expect(t, state.settings.chats_readonly)
	testing.expect_value(t, chats_project().cwd, elsewhere)
	testing.expect(t, by_cwd(old) != nil)
	// "" = back to ~/Chats
	run_command(Set_Folder{kind = .Chats, path = ""}, ui)
	testing.expect_value(t, chats_project().cwd, old)
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
	rescan_now()
	pa, pb, pc := by_cwd(a), by_cwd(b), by_cwd(c)
	run_command(Rename_Project{project_id = pa.id, name = "alpha"})
	run_command(Rename_Project{project_id = pb.id, name = "bravo"})
	run_command(Rename_Project{project_id = pc.id, name = "charlie"})
	testing.expect_value(t, names(sidebar_projects()), "charlie,bravo,alpha") // recent activity (default)
	run_command(Set_Sort{section = .Projects, by = .Name}, {kind = .Script})
	testing.expect_value(t, names(sidebar_projects()), "alpha,bravo,charlie")
	// pinned on top, in pinned order, whatever the sort
	r := run_command(Set_Pinned{project_id = pc.id, pinned = true}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	run_command(Set_Pinned{project_id = pb.id, pinned = true})
	testing.expect_value(t, names(sidebar_projects()), "charlie,bravo,alpha")
	run_command(Set_Pinned{project_id = pb.id, pinned = true, index = 0}) // move up
	testing.expect_value(t, names(sidebar_projects()), "bravo,charlie,alpha")
	// sessions of charlie: recent first, then by name, created
	run_command(Select_Project{project_id = pc.id})
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "charlie talk,Apple pie")
	run_command(Set_Sort{section = .Sessions, by = .Created})
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "Apple pie,charlie talk") // minute 4 > 1
	run_command(Set_Pinned{pi_session_id = "c-1", pinned = true})
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "charlie talk,Apple pie")
	// hide: gone from the list, back with show_hidden; nothing deleted
	r = run_command(Set_Hidden{project_id = pa.id, hidden = true}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, names(sidebar_projects()), "bravo,charlie")
	run_command(Set_Filter{show_hidden = true})
	rows := sidebar_projects()
	testing.expect_value(t, names(rows), "bravo,charlie,alpha")
	testing.expect(t, rows[2].hidden)
	testing.expect(t, os.exists(a), "the folder stays")
	run_command(Set_Filter{show_hidden = false})
	// quick filter: pinned
	run_command(Set_Filter{pinned = true})
	testing.expect_value(t, names(sidebar_projects()), "bravo,charlie")
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "charlie talk")
	run_command(Set_Filter{pinned = false})
	// errors
	r = run_command(Set_Pinned{pinned = true})
	testing.expect_value(t, r.error, "give one of cwd, project_id or pi_session_id")
	r = run_command(Set_Pinned{project_id = pa.id, pi_session_id = "c-1", pinned = true})
	testing.expect_value(t, r.error, "give one of cwd, project_id or pi_session_id")
	r = run_command(Set_Hidden{pi_session_id = "nope", hidden = true})
	testing.expect_value(t, r.error, "no such session")
	r = run_command(Set_Pinned{project_id = chats_project().id, pinned = true})
	testing.expect_value(t, r.error, CHATS_NOT_A_PROJECT)
	// reveal and copy path
	r = run_command(Copy_Path{project_id = pc.id, pi_session_id = "c-2"}, {kind = .Script})
	testing.expect(t, r.ok && strings.has_suffix(sb_clip, "_c-2.jsonl"), sb_clip)
	r = run_command(Reveal_Path{project_id = pb.id})
	testing.expect(t, r.ok && sb_revealed == b, sb_revealed)
	// a Finder window: the user and control (the Home agent) only, not scripts
	testing.expect(t, caller_may({kind = .UI}, Reveal_Path{}) && caller_may({kind = .Control}, Reveal_Path{}), "user and control may reveal")
	testing.expect(t, !caller_may({kind = .Script}, Reveal_Path{}), "a script may not reveal")
	testing.expect(t, !caller_may({kind = .Panel, tab_id = 1}, Reveal_Path{}), "a pi tab may not reveal")
	// a session filter text and a quick filter are not saved; the rest is
	run_command(Set_Filter{text = "zzz", running = true})
	run_command(Set_Sidebar_Folded{section = .Chats, folded = true})
	persist_init(data)
	text := strings.clone(workspace_json())
	testing.expect(t, !strings.contains(text, "zzz"), text)
	sb_reset(data)
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, state.sidebar.sort[.Projects], Sort_By.Name)
	testing.expect_value(t, state.sidebar.sort[.Sessions], Sort_By.Created)
	testing.expect_value(t, state.sidebar.sort[.Chats], Sort_By.Recent)
	testing.expect(t, state.sidebar.folded[.Chats] && !state.sidebar.folded[.Open])
	testing.expect_value(t, state.sidebar.filter, "")
	testing.expect(t, !state.sidebar.only_running)
	testing.expect_value(t, len(state.sidebar.pinned_projects), 2)
	testing.expect_value(t, state.sidebar.pinned_projects[0], b)
	testing.expect_value(t, state.sidebar.pinned_sessions[0], "c-1")
	testing.expect_value(t, state.sidebar.hidden_projects[0], a)
	testing.expect_value(t, names(sidebar_projects()), "bravo,charlie")
	again := workspace_json()
	testing.expectf(t, again == text, "second save differs:\n%s\n---\n%s", text, again)
	// adding a hidden project again shows it
	run_command(Add_Project{cwd = a})
	testing.expect_value(t, len(state.sidebar.hidden_projects), 0)
}

@(test)
filter_ranking :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	os.set_env("HOME", sb_dir("home"))
	rescan_now()
	for name in ([]string{"other", "pi-desk", "desktop-tools", "dense kit"}) {
		r := run_command(Add_Project{cwd = sb_dir(name)})
		run_command(Rename_Project{project_id = r.created_id, name = name})
	}
	run_command(Set_Filter{text = "desk"})
	// a prefix beats a word start, which beats a scattered match; "other" has none
	testing.expect_value(t, names(sidebar_projects()), "desktop-tools,pi-desk,dense kit")
	// every word must match (name or path)
	run_command(Set_Filter{text = "desk pi-"})
	testing.expect_value(t, names(sidebar_projects()), "pi-desk")
	run_command(Set_Filter{text = "nothing-like-it"})
	testing.expect_value(t, len(sidebar_projects()), 0)
	testing.expect(t, sidebar_filtering())
	// control characters never reach the state; long text is cut
	run_command(Set_Filter{text = "a\nb"})
	testing.expect_value(t, state.sidebar.filter, "a b")
	run_command(Set_Filter{text = strings.repeat("x", 500, context.temp_allocator)})
	testing.expect_value(t, len(state.sidebar.filter), FILTER_MAX)
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
	rescan_now()
	pa, pb := by_cwd(a), by_cwd(b)
	testing.expect_value(t, len(sidebar_open()), 0) // nothing open: no Open group
	r := run_command(Open_Session_Cmd{project_id = pa.id, pi_session_id = "a-1"}, {kind = .UI})
	sa := r.created_id
	r = run_command(Select_Project{project_id = pb.id})
	r = run_command(Open_Session_Cmd{project_id = pb.id, pi_session_id = "b-1"}, {kind = .UI})
	sbid := r.created_id
	r = run_command(New_Chat{project_id = chats_project().id}, {kind = .UI})
	chat := r.created_id
	open := sidebar_open()
	testing.expect_value(t, len(open), 3)
	testing.expect_value(t, open[0].id, chat) // current first, then most recently shown
	testing.expect_value(t, open[1].id, sbid)
	testing.expect_value(t, open[2].id, sa)
	// browsing projects never changes what the centre shows
	run_command(Select_Project{project_id = pa.id}, {kind = .UI})
	testing.expect_value(t, state.current_session, chat)
	run_command(Select_Project{project_id = pb.id}, {kind = .UI})
	testing.expect_value(t, state.current_session, chat)
	// focusing from the Open group: current moves to the top
	run_command(Focus_Session{session = sa}, {kind = .UI})
	testing.expect_value(t, sidebar_open()[0].id, sa)
	testing.expect_value(t, sidebar_open()[1].id, chat)
	// the filter applies: title or project name
	run_command(Set_Filter{text = "second"})
	testing.expect_value(t, len(sidebar_open()), 1)
	testing.expect_value(t, sidebar_open()[0].id, sbid)
	run_command(Set_Filter{text = "chats"})
	testing.expect_value(t, len(sidebar_open()), 1)
	testing.expect_value(t, sidebar_open()[0].id, chat)
	// Home is never in it
	testing.expect(t, run_command(Set_Sidebar_Folded{section = .Open, folded = true}).ok)
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
	rescan_now()
	pa := by_cwd(a)
	run_command(Select_Project{project_id = pa.id})
	r := run_command(Open_Session_Cmd{project_id = pa.id, pi_session_id = "w-1"}, {kind = .UI})
	s := find_session(r.created_id)
	r = run_command(Pi_Status_Update{tab_id = s.tabs[0].id, agent = .Idle, waiting = true}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	control := Caller{kind = .Control}
	testing.expect(t, run_command(Set_Hidden{pi_session_id = "w-1", hidden = true}, control).ok)
	testing.expect(t, run_command(Set_Hidden{project_id = pa.id, hidden = true}, control).ok)
	testing.expect(t, run_command(Set_Filter{text = "zzz", running = true}, control).ok)
	testing.expect_value(t, len(sidebar_open()), 1) // still in the Open group
	testing.expect_value(t, names(sidebar_projects()), project_name(pa^)) // its project row stays
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "") // the filter text takes it out of the list
	testing.expect_value(t, sidebar_waiting_filtered(), 1) // counted
	run_command(Set_Filter{text = "", running = false}, control)
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "needs an answer") // hiding does not apply to waiting work
	testing.expect_value(t, sidebar_waiting_filtered(), 0)
	// the filter alone hides it from the session list: counted
	run_command(Set_Filter{running = false})
	run_command(Set_Hidden{pi_session_id = "w-1", hidden = false})
	run_command(Set_Filter{text = "other"})
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "") // filtered from the list...
	testing.expect_value(t, sidebar_waiting_filtered(), 1) // ...and counted ("1 waiting (filtered)")
	testing.expect_value(t, len(sidebar_open()), 1) // the Open group still has it
	testing.expect_value(t, names(sidebar_projects()), project_name(pa^))
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
	r := run_command(Add_Project{cwd = link})
	testing.expect(t, r.ok, r.error)
	p := find_project(r.created_id)
	testing.expect_value(t, p.cwd, real)
	run_command(Set_Pinned{project_id = p.id, pinned = true})
	testing.expect_value(t, state.sidebar.pinned_projects[0], real)
	// pi writes its session under the real path; a rescan finds one project, not two
	sb_session(store_dir(home, real), real, "s-1", "hello", 1, 0)
	rescan_now()
	n := 0
	for q in state.projects do if q.group == .Projects do n += 1
	testing.expect_value(t, n, 1)
	testing.expect_value(t, pi_store_dir(real), store_dir(home, real))
}

// Entries for things that are gone can be removed, and do not pile up.
@(test)
stale_pins_and_hidden :: proc(t: ^testing.T) {
	data := sb_dir("data")
	context.allocator = sb_reset(data)
	os.set_env("HOME", sb_dir("home"))
	rescan_now()
	gone := "/nonexistent/pi-desk-gone"
	run_command(Restore_Sidebar{pinned_projects = {gone}, hidden_projects = {gone}, pinned_sessions = {"gone-id"}, hidden_sessions = {"gone-id"}})
	r := run_command(Set_Pinned{cwd = gone, pinned = false}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.sidebar.pinned_projects), 0)
	r = run_command(Set_Pinned{pi_session_id = "gone-id", pinned = false}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.sidebar.pinned_sessions), 0)
	r = run_command(Set_Hidden{pi_session_id = "gone-id", hidden = false})
	testing.expect(t, r.ok, r.error)
	// pinning something unknown is still refused
	r = run_command(Set_Pinned{pi_session_id = "gone-id", pinned = true})
	testing.expect_value(t, r.error, "no such session")
	// saving drops projects whose folder is gone
	persist_init(data)
	text := workspace_json()
	testing.expect(t, !strings.contains(text, gone), text)
	// a full list makes room by dropping entries whose folder is gone
	stale := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< SIDEBAR_LIST_MAX do append(&stale, fmt.tprintf("/nonexistent/p%d", i))
	run_command(Restore_Sidebar{pinned_projects = stale[:]})
	real := sb_dir("live")
	pr := run_command(Add_Project{cwd = real})
	r = run_command(Set_Pinned{project_id = pr.created_id, pinned = true})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.sidebar.pinned_projects[0], real)
}

// Enter in the filter takes the best match, not the first (pinned) row.
@(test)
filter_enter_best_match :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	os.set_env("HOME", sb_dir("home"))
	rescan_now()
	ids: [2]u64
	for name, i in ([]string{"xdeskx-scattered", "desk"}) {
		r := run_command(Add_Project{cwd = sb_dir(name)})
		run_command(Rename_Project{project_id = r.created_id, name = name})
		ids[i] = r.created_id
	}
	run_command(Set_Pinned{project_id = ids[0], pinned = true})
	run_command(Select_Project{project_id = ids[0]})
	run_command(Set_Filter{text = "desk"})
	testing.expect_value(t, names(sidebar_projects()), "xdeskx-scattered,desk") // pinned first
	cmd := sidebar_best_match()
	sp, ok := cmd.(Select_Project)
	testing.expect(t, ok && sp.project_id == ids[1], "the better match")
}

// A chat's PI_KIT_READONLY cannot be overridden by pi-desk's own environment.
@(test)
child_env_drops_readonly :: proc(t: ^testing.T) {
	context.allocator = sb_reset()
	os.set_env("PI_KIT_READONLY", "0")
	defer os.unset_env("PI_KIT_READONLY")
	for e in child_env({"PI_KIT_READONLY=1"}) do testing.expect(t, e != "PI_KIT_READONLY=0", "inherited value dropped")
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
	rescan_now()
	r := run_command(Open_Session_Cmd{project_id = by_cwd(a).id, pi_session_id = "t-1"})
	s := find_session(r.created_id)
	run_command(Add_Project{cwd = sb_dir("elsewhere")}) // t-1 is not listed any more: read from its file
	before := open_session_stats
	for _ in 0 ..< 10 {
		testing.expect_value(t, open_session_title(s), "cached title")
		_ = open_session_age(s)
	}
	testing.expect(t, open_session_stats - before <= 1, "at most one stat")
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
	rescan_now()
	c := chats_project()
	if !testing.expect(t, c != nil && state.selected_project != 0, "Chats and a project") do return
	r := run_command(New_Chat{project_id = c.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	chat_id := find_session(r.created_id).pi_session_id
	r = run_command(New_Chat{project_id = state.selected_project}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	sess_id := find_session(r.created_id).pi_session_id
	rows := sidebar_sessions(.Chats)
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, rows[0].session.id, chat_id)
		testing.expect_value(t, session_label(rows[0].session^, true), "Untitled chat")
		testing.expect_value(t, rows[1].session.id, "chat-1")
	}
	rows = sidebar_sessions(.Sessions)
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, rows[0].session.id, sess_id)
		testing.expect_value(t, session_label(rows[0].session^), "Untitled session")
	}
	// a new one's place does not move from one call (frame) to the next: its
	// time is when it was opened, not "now" (a row whose selection fade
	// flips each frame redraws for ever)
	run_command(New_Chat{project_id = c.id}, {kind = .UI})
	a := sessions_with_new(.Chats, state.chats[:])
	b := sessions_with_new(.Chats, state.chats[:])
	testing.expect_value(t, len(a), 3)
	for x, i in a do testing.expectf(t, x.id == b[i].id && x.modified == b[i].modified, "row %d moved: %v / %v", i, x.modified, b[i].modified)
	// the filter applies to them like any row
	run_command(Set_Filter{text = "trip"}, {kind = .UI})
	testing.expect_value(t, names(sidebar_sessions(.Chats)), "Plan a trip")
	run_command(Set_Filter{text = ""}, {kind = .UI})
	close_all()
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
	rescan_now()
	pa, pb := by_cwd(a), by_cwd(b)
	run_command(Rename_Project{project_id = pa.id, name = "alpha"})
	run_command(Rename_Project{project_id = pb.id, name = "bravo"})
	run_command(Select_Project{project_id = pa.id})
	// a session title only: its project stays, with the match under it
	run_command(Set_Filter{text = "zebra"}, {kind = .UI})
	testing.expect_value(t, names(sidebar_projects()), "alpha")
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "Zebra notes")
	// an open session in another project: that project stays too
	r := run_command(Open_Session_Cmd{project_id = pb.id, pi_session_id = "b-1"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	run_command(Select_Project{project_id = pa.id})
	run_command(Set_Filter{text = "quokka"}, {kind = .UI})
	testing.expect_value(t, names(sidebar_projects()), "bravo")
	// the Pinned chip: a pinned session keeps its unpinned project
	run_command(Set_Filter{text = ""}, {kind = .UI})
	run_command(Set_Pinned{pi_session_id = "a-1", pinned = true}, {kind = .UI})
	run_command(Set_Filter{pinned = true}, {kind = .UI})
	testing.expect_value(t, names(sidebar_sessions(.Sessions)), "Zebra notes")
	testing.expect_value(t, names(sidebar_projects()), "alpha")
	run_command(Set_Filter{pinned = false}, {kind = .UI})
	close_all()
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
	rescan_now()
	c := chats_project()
	if !testing.expect(t, c != nil && state.selected_project != 0, "Chats and a project") do return
	r := run_command(New_Chat{project_id = c.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	sid := find_session(r.created_id).pi_session_id
	testing.expect_value(t, session_row_project(sid), c.id)
	testing.expect_value(t, session_row_project("a-1"), state.selected_project)
	close_all()
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
	p := Project{id = 99, dir = dir, cwd = cwd}
	testing.expect_value(t, find_session_file(p, "s-1"), file)
	testing.expect_value(t, find_session_file(Project{id = 98, cwd = cwd}, "s-1", dir), file)
	testing.expect_value(t, session_file_in(dir, "s-1"), file)
	// only a folder: no session
	os.remove(file)
	testing.expect_value(t, find_session_file(p, "s-1"), "")
	testing.expect_value(t, session_file_in(dir, "s-1"), "")
	_, err := session_facts_read(folder)
	testing.expect_value(t, err, "not a session file")
}
