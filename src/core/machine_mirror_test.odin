package core

// Other machines in the sidebar (machine_mirror.odin; §10.4 M6-B): ids packed as {machine, id},
// a machine's mirror merged into State and taken out again, never saved, and what get_state
// shows of it. No link runs: a replica (state_read.odin's shape) is built by hand. Shared global
// State, one thread (tests/unit.py).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
mirror_id_packing :: proc(t: ^testing.T) {
	id, ok := id_pack(0, 12345)
	testing.expect(t, ok && id == 12345, "machine 0 (this Mac): the id is unchanged")
	id, ok = id_pack(3, 7)
	testing.expect(t, ok && id == 3 << 40 | 7, "machine 3: its number in bits 40-52")
	testing.expect_value(t, id_machine(id), u64(3))
	testing.expect_value(t, id_local(id), u64(7))
	testing.expect_value(t, id_machine(12345), u64(0))
	_, ok = id_pack(1, 1 << 40)
	testing.expect(t, !ok, "a remote id of 2^40 or more is refused")
	_, ok = id_pack(1, 0)
	testing.expect(t, !ok, "a remote id 0 is refused (no id)")
	_, ok = id_pack(MACHINE_NO_MAX + 1, 1)
	testing.expect(t, !ok, "a machine number past 8191 is refused")
	top, tok := id_pack(MACHINE_NO_MAX, (1 << 40) - 1)
	testing.expect(t, tok && top < 1 << 53, "the largest packed id is below 2^53 (exact in TypeScript)")
}

// A remote core's State as its state.full would decode: a project, an open session with two
// shells, the Home session, a pending confirmation with its token, and hostile text.
@(private = "file")
mm_replica :: proc(project_id, session_id: u64, tabs: int) -> State {
	context.allocator = runtime.heap_allocator()
	r: State
	append(&r.projects, Project{id = project_id, cwd = strings.clone("/home/me/proj"), label = strings.clone("proj"), name = strings.clone("Pro‮ject\x1b[31m")})
	os := Open_Session{id = session_id, project_id = project_id, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/proj"), title = strings.clone("fix ⁦it⁩")}
	for i in 0 ..< tabs do append(&os.tabs, Tab{id = session_id + 1 + u64(i), kind = Shell_Tab{}, title = fmt.aprintf("shell %d", i + 1), status = .Running, held = 77})
	os.active_tab = os.tabs[0].id
	append(&r.open_sessions, os)
	append(&r.open_sessions, Open_Session{id = 900, home = true, pi_session_id = strings.clone("home")})
	append(&r.pending_confirmations, Pending_Confirmation{token = strings.clone("SECRET-TOKEN"), summary = strings.clone("close it")})
	r.selected_project = project_id
	append(&r.sessions, Session{id = strings.clone("abc"), title = strings.clone("fix it")})
	return r
}

@(private = "file")
mm_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	state = State{}
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = "/Users/me/local", label = "local"})
	s := Open_Session{id = new_id(), project_id = state.projects[0].id, pi_session_id = strings.clone("local-1"), cwd = strings.clone("/Users/me/local"), restored = true}
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = strings.clone("sh"), status = .Running})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.machines = make([]Machine_View, 2)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	state.machines[1] = {no = 4, name = "mini", status = .Online}
}

@(private = "file")
mm_count :: proc(no: u64) -> (projects, sessions, tabs: int) {
	for p in state.projects do if p.machine == no do projects += 1
	for s in state.open_sessions do if s.machine == no {
		sessions += 1
		tabs += len(s.tabs)
	}
	return
}

@(test)
mirror_merge_and_unmerge :: proc(t: ^testing.T) {
	mm_reset()
	local_project, local_session := state.projects[0].id, state.open_sessions[0].id
	r3 := mm_replica(5, 9, 2)
	r4 := mm_replica(5, 9, 1) // the same ids on another machine
	m3, m4: Machine_Mirror
	mirror_merge(3, &r3, &m3)
	mirror_merge(4, &r4, &m4)

	testing.expect_value(t, state.projects[0].id, local_project)
	testing.expect_value(t, state.open_sessions[0].id, local_session)
	p3, s3, t3 := mm_count(3)
	testing.expectf(t, p3 == 1 && s3 == 1 && t3 == 2, "machine 3: %d projects, %d sessions, %d tabs (the Home session left out)", p3, s3, t3)
	p4, s4, t4 := mm_count(4)
	testing.expectf(t, p4 == 1 && s4 == 1 && t4 == 1, "machine 4: %d projects, %d sessions, %d tabs", p4, s4, t4)

	pid, _ := id_pack(3, 5)
	sid, _ := id_pack(3, 9)
	p := find_project(pid)
	s := find_session(sid)
	if testing.expect(t, p != nil && s != nil, "packed ids") {
		testing.expect_value(t, p.machine, u64(3))
		testing.expect(t, !strings.contains(p.name, "‮") && !strings.contains(p.name, "\x1b"), "the project's name is cleaned")
		testing.expect_value(t, s.project_id, pid)
		testing.expect_value(t, s.pi_session_id, "m3:abc") // never another machine's or this Mac's session id
		testing.expect(t, !strings.contains(s.title, "⁦"), "the title is cleaned")
		for tab in s.tabs {
			testing.expect_value(t, id_machine(tab.id), u64(3))
			testing.expect_value(t, tab.machine, u64(3))
			testing.expect_value(t, tab.held, u32(0)) // nothing of the other machine's runtime
		}
		testing.expect(t, len(s.panes) == 1 && session_focused_tab(s) != nil && session_focused_tab(s).id == s.active_tab, "one pane, showing its active tab")
	}
	testing.expect_value(t, len(state.pending_confirmations), 0) // a remote never confirms anything here
	gs := state_json()
	testing.expect(t, !strings.contains(gs, "SECRET-TOKEN"), "get_state never carries another machine's confirmation token")
	testing.expect(t, strings.contains(gs, `"machine":"nuc"`) && strings.contains(gs, `"machine":"mini"`), "get_state names each entry's machine")

	// a project of this Mac's selected after one of machine 3's: its sessions stay through 3's merges
	state.selected_project = pid
	mirror_merge(3, &r3, &m3)
	testing.expect(t, len(state.sessions) == 1 && state.sessions[0].id == "m3:abc", "machine 3's project selected: its sessions")
	state.selected_project = local_project
	state.sessions = make([dynamic]Session, runtime.heap_allocator())
	append(&state.sessions, Session{id = "local-1"})
	mirror_merge(3, &r3, &m3)
	testing.expect(t, len(state.sessions) == 1 && state.sessions[0].id == "local-1", "this Mac's sessions list is not another machine's to clear")
	delete(state.sessions)
	state.sessions = {}

	// a delta on machine 3 (a tab gone) changes only machine 3's entries
	context.allocator = runtime.heap_allocator()
	replica_free(&r3)
	r3 = mm_replica(5, 9, 1)
	mirror_merge(3, &r3, &m3)
	_, _, t3 = mm_count(3)
	p4, s4, t4 = mm_count(4)
	testing.expect_value(t, t3, 1)
	testing.expect(t, p4 == 1 && s4 == 1 && t4 == 1, "machine 4 untouched")

	// hostile: an id past 2^40 is left out, and the lists are capped
	replica_free(&r4)
	r4 = mm_replica(5, 1 << 40, 1)
	for i in 0 ..< MIRROR_SESSIONS_MAX + 10 {
		os := Open_Session{id = 1000 + 2 * u64(i), pi_session_id = strings.clone("x")}
		append(&os.tabs, Tab{id = 1001 + 2 * u64(i), kind = Pi_Tab{}, title = strings.clone("pi")})
		append(&r4.open_sessions, os)
	}
	mirror_merge(4, &r4, &m4)
	_, s4, _ = mm_count(4)
	testing.expectf(t, s4 == MIRROR_SESSIONS_MAX, "%d mirrored sessions (an unpackable one dropped, the rest capped)", s4)

	// dropping a machine takes out its entries only
	mirror_unmerge(3)
	mirror_free(&m3)
	p3, s3, t3 = mm_count(3)
	testing.expect(t, p3 == 0 && s3 == 0, "machine 3 gone")
	testing.expect(t, find_project(local_project) != nil && find_session(local_session) != nil, "this Mac's entries stay")
	mirror_unmerge(4)
	mirror_free(&m4)
	replica_free(&r3, runtime.heap_allocator())
	replica_free(&r4, runtime.heap_allocator())
}

@(test)
mirror_never_saved :: proc(t: ^testing.T) {
	mm_reset()
	r := mm_replica(5, 9, 2)
	m: Machine_Mirror
	mirror_merge(3, &r, &m)
	// even marked as the user's own (selected, restored, added by hand) a mirrored entry is not saved
	pid, _ := id_pack(3, 5)
	sid, _ := id_pack(3, 9)
	state.selected_project = pid
	if p := find_project(pid); p != nil do p.by_hand = true
	if s := find_session(sid); s != nil do s.restored = true
	ws := workspace_json()
	testing.expect(t, strings.contains(ws, "local-1"), "this Mac's session is saved")
	testing.expect(t, !strings.contains(ws, "/home/me/proj") && !strings.contains(ws, "m3:abc"), "nothing of the other machine is saved")
	mirror_unmerge(3)
	mirror_free(&m)
	replica_free(&r, runtime.heap_allocator())
}

// Review round 1: another machine's session on screen is not "the session on screen" for anything
// that acts (cur): a split, a shown file or quick-open, the Files tab's base. Nothing local is added
// to it, and no local folder it names is read.
@(private = "file")
rv_replica :: proc() -> State {
	context.allocator = runtime.heap_allocator()
	r: State
	append(&r.projects, Project{id = 5, group = .Projects, cwd = strings.clone("/tmp"), label = strings.clone("tmp")})
	os := Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/tmp"), title = strings.clone("t")}
	append(&os.tabs, Tab{id = 10, kind = Shell_Tab{}, title = strings.clone("sh"), status = .Running})
	os.active_tab = 10
	append(&r.open_sessions, os)
	return r
}

@(private = "file")
rv_on_screen :: proc(r: ^State, m: ^Machine_Mirror) -> u64 {
	context.allocator = runtime.heap_allocator()
	state = State{}
	state.machines = make([]Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	mirror_merge(3, r, m)
	sid, _ := id_pack(3, 9)
	run_command(Focus_Session{session = sid}, {kind = .UI})
	return sid
}

@(private = "file")
rv_local_tabs :: proc(sid: u64) -> (n: int) {
	if s := find_session(sid); s != nil do for tab in s.tabs do if tab.machine == 0 do n += 1
	return
}

@(test)
mirror_on_screen_acts_nowhere :: proc(t: ^testing.T) {
	r := rv_replica()
	m: Machine_Mirror
	sid := rv_on_screen(&r, &m)
	testing.expect(t, state.current_session == sid && cur_view() != nil, "shown (the window draws it)")
	testing.expect(t, cur() == nil, "but not the session commands act in")
	run_command(Split_Pane{direction = .Right}, {kind = .UI}) // ⌘D
	run_command(Show_File{path = "/etc/hosts"}, {kind = .Script})
	run_command(Show_File{path = "/etc/hosts"}, {kind = .UI}) // quick-open's
	testing.expect_value(t, rv_local_tabs(sid), 0)
	testing.expect(t, len(terms) == 0, "no terminal started here")
	testing.expect(t, files_base() == "" || files_base() != fs_real("/tmp"), "the Files tab never lists a folder another machine named")
	testing.expect(t, fs_base_dir() != "/tmp", "nor bases paths on it")
	s := find_session(sid)
	_, err := shell_tab_start(s, s.cwd)
	testing.expect(t, err != "", "shell_tab_start refuses another machine's session")
	mirror_unmerge(3)
	mirror_free(&m)
	replica_free(&r, runtime.heap_allocator())
}

@(test)
mirror_titles_not_refreshed_here :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r := rv_replica()
	r.selected_project = 5
	append(&r.sessions, Session{id = strings.clone("abc"), path = strings.clone("/nope/x.jsonl"), title = strings.clone("remote title")})
	m: Machine_Mirror
	state = State{}
	state.machines = make([]Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	pid, _ := id_pack(3, 5)
	state.selected_project = pid
	mirror_merge(3, &r, &m)
	refresh_listed_titles()
	testing.expect(t, len(state.sessions) == 1 && state.sessions[0].title == "remote title", "another machine's titles are its own")
	mirror_unmerge(3)
	mirror_free(&m)
	replica_free(&r, runtime.heap_allocator())
}

// Review round 1: another machine's stream. A state.full never counts toward the deltas' cap (a
// full over 4 MiB looped: counted, past the cap, asked for again); deltas past the cap ask for one
// full and wait for it; a refused full is asked for again only after a wait.
@(test)
mirror_stream_bounds :: proc(t: ^testing.T) {
	st: Mirror_Stream
	now := time.tick_now()
	testing.expect_value(t, mirror_stream_take(&st, 5 << 20, true, now), Mirror_Take.Apply)
	mirror_stream_applied(&st, true)
	testing.expect_value(t, st.bytes, 0)
	testing.expect_value(t, mirror_stream_take(&st, 3 << 20, false, now), Mirror_Take.Apply)
	testing.expect_value(t, mirror_stream_take(&st, 2 << 20, false, now), Mirror_Take.Ask_Full)
	testing.expect_value(t, mirror_stream_take(&st, 10, false, now), Mirror_Take.Skip) // waits for the full
	testing.expect_value(t, mirror_stream_take(&st, 5 << 20, true, now), Mirror_Take.Apply)
	testing.expect(t, !mirror_stream_refused(&st, true, now), "a refused full is not asked for again at once")
	testing.expect(t, !mirror_stream_due(&st, now), "not yet")
	testing.expect(t, mirror_stream_due(&st, time.tick_add(now, MIRROR_FULL_RETRY)), "after the wait")
	testing.expect(t, mirror_stream_refused(&st, false, now), "a refused delta asks for a full at once")
}

// M6-F: another machine's job that needs the user rings here once, naming the machine, and again
// only for a new run; its bell entries ring once (a core seen for the first time, or again after a
// reconnect, rings none of what it had); hostile text is cleaned; past the rate per machine
// nothing rings; the machine removed takes its entries and jobs with it.
@(test)
mirror_alerts_ring_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	mm_reset()
	defer {
		notice_test_now = {}
		state = State{}
	}
	notice_test_now = time.now()
	later :: proc() {notice_test_now = time.time_add(notice_test_now, 20 * time.Second)} // past coalescing
	r := mm_replica(5, 9, 1)
	m: Machine_Mirror
	needs := proc(r: ^State, run: string) {
		for &j in r.jobs do delete(j.needs_you)
		clear(&r.jobs)
		j := Job_Row{id = strings.clone("daily"), name = strings.clone("Dai​ly‮\nreport"), project = strings.clone("Gar‮den\x1b[31m\nnext"), last_run = strings.clone(run), unread = 1, last_status = strings.clone("needs_you"), path = strings.clone("/home/me/jobs/daily.md")}
		append(&j.needs_you, strings.clone("sign the\x1b[31m form"))
		append(&r.jobs, j)
	}
	rang :: proc(kind: Notice_Kind) -> (n: int) {
		for x in state.notices.items do if x.kind == kind && x.machine == 3 do n += 1
		return
	}
	// an old bell entry and a job that needs you, first seen: the job rings, the entry does not
	append(&r.notices.items, Notice{id = 40, kind = .Waiting, title = strings.clone("old"), session = 9})
	needs(&r, "run-1")
	mirror_merge(3, &r, &m)
	mirror_alerts(3, &r, &m, "core-a")
	testing.expect_value(t, rang(.Job_Needs_You), 1)
	testing.expect_value(t, rang(.Waiting), 0)
	if testing.expect_value(t, len(state.machine_jobs), 1) {
		j := state.machine_jobs[0]
		testing.expect_value(t, j.id, "m3:daily")
		testing.expect(t, j.path == "" && j.folder == "", "no paths")
		testing.expect(t, !strings.contains(j.name, "​") && !strings.contains(j.name, "‮") && !strings.contains(j.name, "\n"), "its name: one line, nothing invisible")
		testing.expect_value(t, j.owner, Job_Owner_Kind.Project)
		testing.expectf(t, strings.has_prefix(j.project, "Gar") && !strings.contains(j.project, "‮") && !strings.contains(j.project, "\x1b") && !strings.contains(j.project, "\n"), "its project: cleaned, one line: %q", j.project)
	}
	for x in state.notices.items do if x.kind == .Job_Needs_You {
		testing.expectf(t, strings.has_prefix(x.title, fmt.tprintf("nuc · %s · ", state.machine_jobs[0].project)), "it names the machine and the project: %q", x.title)
		testing.expect(t, !strings.contains(x.summary, "\x1b") && x.run_dir == "", "cleaned, no folder")
	}
	// the same state again, a reconnect (the same core), a fresh full: nothing new rings
	later()
	for _ in 0 ..< 3 {
		mirror_merge(3, &r, &m)
		mirror_alerts(3, &r, &m, "core-a")
	}
	testing.expect_value(t, rang(.Job_Needs_You), 1)
	// a new run that needs you: once more
	later()
	needs(&r, "run-2")
	mirror_merge(3, &r, &m)
	mirror_alerts(3, &r, &m, "core-a")
	testing.expect_value(t, len(state.notices.items), 2)
	// a new bell entry rings, naming the machine, its session mirrored here; its own machines' never
	later()
	append(&r.notices.items, Notice{id = 41, kind = .Waiting, title = strings.clone("now"), session = 9, place = strings.clone("proj")})
	append(&r.notices.items, Notice{id = 42, kind = .Waiting, title = strings.clone("chained"), machine = 2})
	mirror_merge(3, &r, &m)
	mirror_alerts(3, &r, &m, "core-a")
	testing.expect_value(t, rang(.Waiting), 1)
	for x in state.notices.items do if x.kind == .Waiting {
		testing.expect(t, strings.has_prefix(x.place, "nuc · "), "where: the machine")
		sid, _ := id_pack(3, 9)
		testing.expect_value(t, x.session, sid)
	}
	// a flood: at most MIRROR_RING_PER_MIN a minute (3 rang so far)
	for i in 0 ..< 10 do append(&r.notices.items, Notice{id = u64(50 + i), kind = .Error, title = strings.clone("spam"), session = u64(1000 + i)})
	mirror_merge(3, &r, &m)
	mirror_alerts(3, &r, &m, "core-a")
	testing.expect_value(t, rang(.Error), MIRROR_RING_PER_MIN - 3)
	// a new run of its core: what it has is old (the mark again)
	mirror_merge(3, &r, &m)
	mirror_alerts(3, &r, &m, "core-b")
	testing.expect_value(t, rang(.Error), MIRROR_RING_PER_MIN - 3)
	// removed: its entries and jobs go
	mirror_drop(3, &m)
	testing.expect_value(t, len(state.machine_jobs), 0)
	n := 0
	for x in state.notices.items do if x.machine == 3 do n += 1
	testing.expect_value(t, n, 0)
}

// Whose another machine's job is (display text only): for_project's words, a name, a path (that
// machine's project with the folder, else its last part), else the deepest project holding its
// folder (never one at a home folder), else Other.
@(test)
machine_job_owner_rules :: proc(t: ^testing.T) {
	r: State
	append(&r.projects, Project{id = 1, group = .Projects, cwd = "/home/jb/garden", name = "Veg"})
	append(&r.projects, Project{id = 2, group = .Projects, cwd = "/home/jb"})
	check :: proc(t: ^testing.T, r: ^State, project, folder: string, kind: Job_Owner_Kind, name: string, loc := #caller_location) {
		k, n := machine_job_owner(Job_Row{project = project, folder = folder}, r)
		testing.expectf(t, k == kind && n == name, "%q in %q: %v %q, want %v %q", project, folder, k, n, kind, name, loc = loc)
	}
	check(t, &r, "Atlas", "", .Atlas, "")
	check(t, &r, "chats", "", .Chats, "")
	check(t, &r, "none", "/home/jb/garden", .Other, "")
	check(t, &r, "roses", "", .Project, "roses")
	check(t, &r, "~/garden", "", .Project, "Veg")
	check(t, &r, "/srv/orchard/", "", .Project, "orchard")
	check(t, &r, "", "/home/jb/garden/beds", .Project, "Veg")
	check(t, &r, "", "/home/jb/notes", .Other, "")
}
