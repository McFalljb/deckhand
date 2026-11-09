package core

// Other machines in the sidebar (docs/plans/background-core.md §8.1, §10.4 M6-B): each linked
// machine's State, as its core streams it to this core (state.subscribe on the hub link,
// machines.odin), is kept as a replica (state_read.odin) and merged into this core's State, so the
// window keeps one State and one core.
//
// Ids are {machine, id} packed into the u64 every id already is: machine 0 is this Mac (every
// local id unchanged), and another machine's id is its number (1-8191, machines.json) in bits
// 40-52 over its own id, which must be below 2^40. Every packed id stays below 2^53, so the
// TypeScript agents read it exactly. A machine's pi session ids get "m<no>:" before them, so pins,
// status and "already open" never mix them with this Mac's.
//
// What is merged: its projects (not its Chats entry), its open sessions (not Home) with their
// tabs, each session in one pane (its own split layout is not mirrored), and, while one of its
// projects is selected here, that project's sessions. Nothing else: never its confirmations,
// jobs, settings or panels. Another machine's State is untrusted: every string is cleaned
// (text_clean: printable, no bidi controls, bounded), every list capped, an id that does not pack
// is dropped, and a tab keeps only its kind (no paths or runtime; a browser tab its address and
// history, for its toolbar: M6-D): the merged entries carry nothing this Mac's core could act on.
// They are never saved (persist.odin), never started here (term_start refuses their tab ids),
// and a command naming one runs on that machine, not here (machine_route.odin, M6-C), except
// focusing one and selecting one of its projects (this Mac's view). A merge replaces that machine's entries whole; other machines' and this Mac's are not
// touched.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"

import cw "../corewire"

MACHINE_ID_SHIFT :: 40
MACHINE_ID_MASK :: (u64(1) << MACHINE_ID_SHIFT) - 1

MIRROR_PROJECTS_MAX :: 300
MIRROR_SESSIONS_MAX :: 64 // open sessions
MIRROR_TABS_MAX :: 32 // per open session
MIRROR_LIST_MAX :: MAX_SESSIONS // the selected project's sessions
MIRROR_TEXT_MAX :: 160 // names, titles, session ids (bytes)
MIRROR_PATH_MAX :: 1024
MIRROR_URL_MAX :: 2048 // a browser tab's address
// What another machine's state stream may decode to: per message (state_read.odin's budget, far
// below a window's own core's), and the bytes of its deltas since its last state.full. Past the
// second, its deltas are left until a fresh state.full (asked for) replaces the replica. A full is at
// most a frame (cw.MAX_PAYLOAD) and never counts toward the deltas' cap; a refused one is asked for
// again after MIRROR_FULL_RETRY.
MIRROR_READ_MAX :: 64 << 20
MIRROR_STREAM_MAX :: 4 << 20
MIRROR_FULL_RETRY :: 30 * time.Second

Mirror_Stream :: struct {
	bytes:      int, // its deltas' bytes since its last state.full
	want_full:  bool, // deltas wait for a state.full
	full_again: time.Tick, // a refused full: ask again then ({} = not waiting)
}

Mirror_Take :: enum u8 {
	Apply,
	Skip, // left: a delta while a full is awaited, or a full over a frame
	Ask_Full, // left, and a state.full asked for
}

// What to do with a state message of size bytes (full: a state.full).
mirror_stream_take :: proc(s: ^Mirror_Stream, size: int, full: bool, now: time.Tick) -> Mirror_Take {
	if full {
		if size > cw.MAX_PAYLOAD {
			mirror_stream_refused(s, true, now)
			return .Skip
		}
		return .Apply
	}
	if s.want_full do return .Skip
	s.bytes += size
	if s.bytes > MIRROR_STREAM_MAX {
		s.want_full = true
		return .Ask_Full
	}
	return .Apply
}

// A message went into the replica.
mirror_stream_applied :: proc(s: ^Mirror_Stream, full: bool) {
	if full do s^ = {}
}

// The replica refused a message: true = ask for a state.full now (a delta); a full waits first.
mirror_stream_refused :: proc(s: ^Mirror_Stream, full: bool, now: time.Tick) -> bool {
	s.want_full = true
	if !full do return true
	s.full_again = time.tick_add(now, MIRROR_FULL_RETRY)
	return false
}

// A refused full's wait is over: ask again now.
mirror_stream_due :: proc(s: ^Mirror_Stream, now: time.Tick) -> bool {
	if s.full_again == {} || time.tick_diff(s.full_again, now) < 0 do return false
	s.full_again = {}
	return true
}

// Machine `machine`'s id `id` as this core holds it. Machine 0 (this Mac): id itself. False: it does
// not pack (no id, 2^40 or more, or no such machine number).
id_pack :: proc(machine, id: u64) -> (u64, bool) {
	if machine == 0 do return id, true
	if machine > MACHINE_NO_MAX || id == 0 || id > MACHINE_ID_MASK do return 0, false
	return machine << MACHINE_ID_SHIFT | id, true
}

// Which machine an id is on (0: this Mac), and its id there.
id_machine :: proc(id: u64) -> u64 {return id >> MACHINE_ID_SHIFT}
id_local :: proc(id: u64) -> u64 {return id & MACHINE_ID_MASK}

// What State holds of one machine besides its open sessions (those are State's own, heap).
Machine_Mirror :: struct {
	arena:    virtual.Arena,
	projects: [dynamic]Project, // in arena; State's entries are copies of these (apply_scan adds them again)
	sessions: [dynamic]Session, // in arena: its selected project's (state.sessions while that is selected here)
	selected: u64, // its selected project (packed)
}

// Whether the left column lists other machines: Machines over SSH is on and one is added.
machines_in_sidebar :: proc() -> bool {return state.settings.remote_machines && len(state.machines) > 0}

// Machine no's name (State's machines section), for get_state's `machine`.
machine_name :: proc(no: u64) -> string {
	for m in state.machines do if m.no == no do return m.name
	return fmt.tprintf("machine %d", no)
}

@(private = "file")
mirror_text :: proc(s: string, max: int, a: runtime.Allocator) -> string {
	return strings.clone(text_clean(s, max), a)
}

// A tab's kind without what it holds (paths, URLs, accounts): which kind it is, only.
@(private = "file")
tab_kind_bare :: proc(k: Tab_Kind) -> Tab_Kind {
	switch _ in k {
	case Pi_Tab:       return Pi_Tab{}
	case Shell_Tab:    return Shell_Tab{}
	case Editor_Tab:   return Editor_Tab{}
	case Changes_Tab:  return Changes_Tab{}
	case Markdown_Tab: return Markdown_Tab{}
	case Browser_Tab:  return Browser_Tab{}
	case App_Tab:      return App_Tab{}
	case Claude_Tab:   return Claude_Tab{}
	}
	return Shell_Tab{}
}

// Machine no's entries from r (its replica) into State, replacing what was there of it.
mirror_merge :: proc(no: u64, r: ^State, m: ^Machine_Mirror) {
	heap := runtime.heap_allocator()
	context.allocator = heap
	// this Mac's view of them stays: when each was last shown (the Open group's order)
	shown := make(map[u64]i64, 16, context.temp_allocator)
	for s in state.open_sessions do if s.machine == no do shown[s.id] = s.shown_at
	mirror_unmerge(no)
	virtual.arena_free_all(&m.arena)
	a := virtual.arena_allocator(&m.arena)

	m.projects = make([dynamic]Project, a)
	for p in r.projects {
		if len(m.projects) >= MIRROR_PROJECTS_MAX do break
		if p.group != .Projects do continue
		id, ok := id_pack(no, p.id)
		if !ok do continue
		append(&m.projects, Project{id = id, machine = no, group = .Projects, name = mirror_text(p.name, MIRROR_TEXT_MAX, a), cwd = mirror_text(p.cwd, MIRROR_PATH_MAX, a), label = mirror_text(p.label, MIRROR_TEXT_MAX, a), newest = p.newest, created = p.created, missing = p.missing, repo = p.repo})
	}
	for p in m.projects do append(&state.projects, p)

	for &os in r.open_sessions {
		if state_mirrored_sessions(no) >= MIRROR_SESSIONS_MAX do break
		if os.home do continue
		id, ok := id_pack(no, os.id)
		if !ok do continue
		pid, _ := id_pack(no, os.project_id)
		ns := Open_Session {
			id            = id,
			machine       = no,
			agent         = os.agent,
			project_id    = pid,
			pi_session_id = fmt.aprintf("m%d:%s", no, text_clean(os.pi_session_id, MIRROR_TEXT_MAX)),
			session_dir   = mirror_text(os.session_dir, MIRROR_PATH_MAX, heap),
			session_file  = mirror_text(os.session_file, MIRROR_PATH_MAX, heap),
			cwd           = mirror_text(os.cwd, MIRROR_PATH_MAX, heap),
			title         = mirror_text(os.title, MIRROR_TEXT_MAX, heap),
			missing       = os.missing,
			shown_at      = shown[id] or_else 0,
		}
		pane := id // its one pane: the session's own id (no tab or pane of that machine has it)
		for tab in os.tabs {
			if len(ns.tabs) >= MIRROR_TABS_MAX do break
			tid, tok := id_pack(no, tab.id)
			if !tok do continue
			kind := tab_kind_bare(tab.kind)
			if bt, is := tab.kind.(Browser_Tab); is {
				// its page lives in this Mac's window (M6-D): the toolbar shows its address and history
				kind = Browser_Tab{url = mirror_text(bt.url, MIRROR_URL_MAX, heap), loading = bt.loading, can_back = bt.can_back, can_forward = bt.can_forward}
			}
			append(&ns.tabs, Tab{id = tid, machine = no, kind = kind, title = mirror_text(tab.title, MIRROR_TEXT_MAX, heap), status = tab.status, exit = tab.exit, agent = tab.agent, waiting = tab.waiting, question = tab.question, unseen = tab.unseen, output_recent = tab.output_recent, has_term = tab.has_term, pane = pane})
		}
		if len(ns.tabs) == 0 { 	// an open session always has its main tab
			wire_free(&ns, type_info_of(Open_Session), heap)
			continue
		}
		active, _ := id_pack(no, os.active_tab)
		found := false
		for t in ns.tabs do if t.id == active do found = true
		if !found do active = ns.tabs[0].id
		ns.active_tab = active
		append(&ns.panes, Pane{id = pane, active = active})
		append(&ns.nodes, Layout_Node{id = pane, leaf = true, pane = pane, parent = -1})
		append(&ns.pane_mru, pane)
		ns.focused_pane = pane
		append(&state.open_sessions, ns)
	}

	m.sessions = make([dynamic]Session, a)
	m.selected, _ = id_pack(no, r.selected_project)
	for x in r.sessions {
		if len(m.sessions) >= MIRROR_LIST_MAX do break
		append(&m.sessions, Session{id = fmt.aprintf("m%d:%s", no, text_clean(x.id, MIRROR_TEXT_MAX), allocator = a), path = mirror_text(x.path, MIRROR_PATH_MAX, a), when_ = mirror_text(x.when_, 32, a), title = mirror_text(x.title, MIRROR_TEXT_MAX, a), untitled = mirror_text(x.untitled, MIRROR_TEXT_MAX, a), modified = x.modified, claude = x.claude})
	}
	mirror_sessions_show(no, m)

	// what this Mac showed of it and is gone there
	if id_machine(state.current_session) == no && find_session(state.current_session) == nil do state.current_session = 0
	if id_machine(state.selected_project) == no && find_project(state.selected_project) == nil {
		state.selected_project = 0
		state.sessions = {}
	}
	window_state_changed()
}

@(private = "file")
state_mirrored_sessions :: proc(no: u64) -> (n: int) {
	for s in state.open_sessions do if s.machine == no do n += 1
	return
}

// While one of machine no's projects is selected here: its sessions, once that machine shows the
// same project (select_project went to it), else none yet.
mirror_sessions_show :: proc(no: u64, m: ^Machine_Mirror) {
	if id_machine(state.selected_project) != no do return
	state.sessions = m.selected == state.selected_project ? m.sessions : {}
}

// Takes machine no's entries out of State (its projects are m's; its open sessions are freed).
mirror_unmerge :: proc(no: u64) {
	heap := runtime.heap_allocator()
	for i := len(state.projects) - 1; i >= 0; i -= 1 do if state.projects[i].machine == no do ordered_remove(&state.projects, i)
	for i := len(state.open_sessions) - 1; i >= 0; i -= 1 do if state.open_sessions[i].machine == no {
		wire_free(&state.open_sessions[i], type_info_of(Open_Session), heap)
		ordered_remove(&state.open_sessions, i)
	}
	// state.sessions is that machine's while one of its projects is selected (else this Mac's)
	if id_machine(state.selected_project) == no do state.sessions = {}
}

// Machine no is gone (removed, or Machines over SSH turned off): its entries leave State, and what
// this Mac showed of it.
mirror_drop :: proc(no: u64, m: ^Machine_Mirror) {
	mirror_unmerge(no)
	mirror_free(m)
	if id_machine(state.current_session) == no do state.current_session = 0
	if id_machine(state.selected_project) == no do state.selected_project = 0
	window_state_changed()
}

mirror_free :: proc(m: ^Machine_Mirror) {
	virtual.arena_destroy(&m.arena)
	m^ = {}
}

// Fields of a command that name an open session, tab, pane, split or project (machine_route.odin
// routes a command by them).
@(private = "file")
MACHINE_ID_FIELDS := [?]string{"tab_id", "session", "project_id", "pane", "tab", "split", "opener"}

machine_id_field :: proc(name: string) -> bool {
	for f in MACHINE_ID_FIELDS do if f == name do return true
	return false
}
