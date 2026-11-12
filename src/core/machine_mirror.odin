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
// tabs, each session in one pane (its own split layout is not mirrored), while one of its projects
// is selected here, that project's sessions, and (M6-F) its jobs, read-only (State.machine_jobs:
// no paths, ids "m<no>:<its id>" so no job command here finds one). Nothing else: never its
// confirmations, settings or panels.
//
// Its bell and its jobs that need the user ring here (mirror_alerts, M6-F, §8.6): its core can't
// use window.request, so this core makes the notification, naming the machine. A bell entry rings
// once: ids above the newest seen of that core's run (a core seen for the first time, or a new run
// of it, sets that mark without ringing, so a reconnect or a fresh state.full never rings old
// ones); a job that needs the user rings once per run (its last_run), unread ones too when first
// seen. At most MIRROR_BELL_SCAN of its newest entries are looked at per state, and at most
// MIRROR_RING_PER_MIN ring per machine a minute (the rest are dropped and logged). Every string is
// text_clean_remote's (one line, no control, bidi or invisible characters, bounded); its job
// lines and folders, a run's folder and a pi session id are dropped. What it rang goes with the
// machine (removed, or Machines over SSH off); a link that drops keeps them as last seen. Another machine's State is untrusted: every string is cleaned
// (text_clean: printable, no bidi controls, bounded; what the sidebar draws or its filter matches, names,
// folders and titles, text_clean_remote's, one line too), every list capped, an id that does not pack
// is dropped, and a tab keeps only its kind and its status (no paths, URLs or runtime; of a Claude
// tab's hooks only the enums its dot is made of; its OSC 7501 summary through mirror_prog: state,
// kind, progress, app and message, cleaned and bounded; since when: mirror_since): the merged entries carry
// nothing this Mac's core could act on. They are never saved (persist.odin), never started here
// (term_start refuses their tab ids), and a command naming one runs on that machine, not here
// (machine_route.odin, M6-C), except focusing one and selecting one of its projects (this Mac's
// view). A merge replaces that machine's entries whole; other machines' and this Mac's are not
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
// What another machine's state stream may decode to: per message (state_read.odin's budget, far
// below a window's own core's), and the bytes of its deltas since its last state.full. Past the
// second, its deltas are left until a fresh state.full (asked for) replaces the replica. A full is at
// most a frame (cw.MAX_PAYLOAD) and never counts toward the deltas' cap; a refused one is asked for
// again after MIRROR_FULL_RETRY.
MIRROR_READ_MAX :: 64 << 20
MIRROR_STREAM_MAX :: 4 << 20
MIRROR_FULL_RETRY :: 30 * time.Second
MIRROR_JOBS_MAX :: 100 // its jobs
MIRROR_JOB_LINES :: 5 // per job: its needs-you lines (the first rings)
MIRROR_LINE_MAX :: 200 // a headline, a summary, a needs-you line (bytes)
MIRROR_BELL_SCAN :: 20 // its newest bell entries looked at per state
MIRROR_RING_PER_MIN :: 4 // what rings here from one machine, per minute

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
	jobs:     [dynamic]Job_Row, // in arena; State.machine_jobs holds copies
	// what rang here (mirror_alerts): heap, kept across reconnects, gone with the machine
	bell_based: bool, // bell_seen is set for bell_run
	bell_run:   string, // its core's run id (its hello's) when bell_seen was set
	bell_seen:  u64, // its newest bell entry's id seen
	jobs_rang:  map[string]string, // its job's id here -> the run whose needs-you rang
	rang_at:    time.Tick, // the rate window's start
	rang_n:     int,
	dropped:    int, // not rung: past the rate (logs)
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

// Another machine's text as the bell, the Jobs tab and Atlas see it (M6-F): one line, without
// control, bidi or invisible characters (one_line), then printable and bounded (text_clean)
// (temp). Stricter than text_clean, and only for other machines' text: this Mac's own titles keep
// their emoji sequences.
text_clean_remote :: proc(s: string, max: int) -> string {
	return strings.trim_space(text_clean(one_line(s, context.temp_allocator), max))
}

// "<machine> · <owner> · <job>", without the owner when it is "" (heap or a).
job_title_with_owner :: proc(machine, owner, job: string, a: runtime.Allocator) -> string {
	if owner == "" do return fmt.aprintf("%s · %s", machine, job, allocator = a)
	return fmt.aprintf("%s · %s · %s", machine, owner, job, allocator = a)
}

// A job's owner as a bell title's part: its name as its machine sent it; "" for Other (and for an
// older core that sends none).
job_owner_title :: proc(r: Job_Row) -> string {return r.owner == .Other ? "" : r.owner_name}

@(private = "file")
remote_text :: proc(s: string, max: int, a: runtime.Allocator) -> string {
	return strings.clone(text_clean_remote(s, max), a)
}

// A job's status word: one this Mac knows, else "unknown".
@(private = "file")
remote_status :: proc(s: string) -> string {
	if s == "" do return ""
	return job_status_icon(s) != "•" ? s : "unknown"
}

// A tab's kind without what it holds (paths, URLs, accounts): which kind it is, and for a Claude
// tab only the two enums its dot is made of.
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
	case Claude_Tab:
		// its hooks' turn and how its last turn ended: what its dot is made of (claude_status_dot,
		// tab_status_view), so its row and next_needing_you see a permission or an error
		ct := k.(Claude_Tab)
		return Claude_Tab{turn = ct.turn <= max(Claude_Turn) ? ct.turn : .Unknown, ended = ct.ended <= max(Claude_Ended) ? ct.ended : .None}
	}
	return Shell_Tab{}
}

// A tab's OSC 7501 summary as another machine sent it, for its mark and tooltip only: a state and
// kind this build knows (else none), progress in -1..100, its app and message cleaned and bounded,
// no id or title, its time never ahead of this Mac's clock (heap or a).
mirror_prog :: proc(p: Prog_Summary, now: time.Time, a: runtime.Allocator) -> Prog_Summary {
	out := Prog_Summary{progress = -1}
	if p.state < min(Prog_State) || p.state > max(Prog_State) || p.state == .None do return out
	out.state = p.state
	if p.state == .Blocked && p.kind >= min(Prog_Kind) && p.kind <= max(Prog_Kind) do out.kind = p.kind
	if p.progress >= 0 && p.progress <= 100 do out.progress = p.progress
	out.app = remote_text(p.app, PROG_APP_MAX, a)
	out.msg = remote_text(p.msg, PROG_MSG_MAX, a)
	out.records = clamp(p.records, 0, PROG_RECORDS_MAX)
	if p.at._nsec > 0 do out.at = time.Time{min(p.at._nsec, now._nsec)}
	return out
}

// What a mirrored tab's status was at the last merge.
Mirror_Since :: struct {
	key:   u16,
	since: time.Time,
}

MIRROR_SINCE_MAX :: 365 * 24 * time.Hour // older than this by that machine's clock: not believed

// Since when a mirrored tab's status has been what it is: unchanged since the last merge, as it
// was; changed while this Mac watched, now (this Mac's clock, so skew cannot show); first seen,
// that machine's own time, never ahead of now and never absurdly old ({} = not known).
mirror_since :: proc(key: u16, theirs: time.Time, prev: Mirror_Since, seen: bool, now: time.Time) -> (u16, time.Time) {
	if seen do return key, prev.key == key ? prev.since : now
	if theirs._nsec <= 0 do return key, {}
	if theirs._nsec > now._nsec do return key, now
	if time.diff(theirs, now) > MIRROR_SINCE_MAX do return key, {}
	return key, theirs
}

// Machine no's entries from r (its replica) into State, replacing what was there of it.
mirror_merge :: proc(no: u64, r: ^State, m: ^Machine_Mirror) {
	heap := runtime.heap_allocator()
	context.allocator = heap
	// this Mac's view of them stays: when each was last shown (the Open group's order)
	shown := make(map[u64]i64, 16, context.temp_allocator)
	for s in state.open_sessions do if s.machine == no do shown[s.id] = s.shown_at
	// and since when each tab's status has been what it is (mirror_since)
	was := make(map[u64]Mirror_Since, 16, context.temp_allocator)
	for s in state.open_sessions do if s.machine == no do for t in s.tabs do was[t.id] = {t.status_key, t.status_since}
	now := time.now()
	mirror_unmerge(no)
	virtual.arena_free_all(&m.arena)
	a := virtual.arena_allocator(&m.arena)

	m.projects = make([dynamic]Project, a)
	for p in r.projects {
		if len(m.projects) >= MIRROR_PROJECTS_MAX do break
		if p.group != .Projects do continue
		id, ok := id_pack(no, p.id)
		if !ok do continue
		append(&m.projects, Project{id = id, machine = no, group = .Projects, name = remote_text(p.name, MIRROR_TEXT_MAX, a), cwd = remote_text(p.cwd, MIRROR_PATH_MAX, a), label = remote_text(p.label, MIRROR_TEXT_MAX, a), newest = p.newest, created = p.created, missing = p.missing, repo = p.repo})
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
			cwd           = remote_text(os.cwd, MIRROR_PATH_MAX, heap),
			title         = remote_text(os.title, MIRROR_TEXT_MAX, heap),
			missing       = os.missing,
			shown_at      = shown[id] or_else 0,
		}
		pane := id // its one pane: the session's own id (no tab or pane of that machine has it)
		for tab in os.tabs {
			if len(ns.tabs) >= MIRROR_TABS_MAX do break
			tid, tok := id_pack(no, tab.id)
			if !tok do continue
			nt := Tab{id = tid, machine = no, kind = tab_kind_bare(tab.kind), title = remote_text(tab.title, MIRROR_TEXT_MAX, heap), status = tab.status, exit = tab.exit, agent = tab.agent, waiting = tab.waiting, question = tab.question, unseen = tab.unseen, output_recent = tab.output_recent, has_term = tab.has_term, pane = pane}
			nt.prog = mirror_prog(tab.prog, now, heap)
			prev, seen := was[tid]
			nt.status_key, nt.status_since = mirror_since(status_key(tab_status_view(nt)), tab.status_since, prev, seen, now)
			append(&ns.tabs, nt)
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
		append(&m.sessions, Session{id = fmt.aprintf("m%d:%s", no, text_clean(x.id, MIRROR_TEXT_MAX), allocator = a), path = mirror_text(x.path, MIRROR_PATH_MAX, a), when_ = remote_text(x.when_, 32, a), title = remote_text(x.title, MIRROR_TEXT_MAX, a), untitled = remote_text(x.untitled, MIRROR_TEXT_MAX, a), modified = x.modified, claude = x.claude})
	}
	mirror_sessions_show(no, m)

	m.jobs = make([dynamic]Job_Row, a)
	for j in r.jobs {
		if len(m.jobs) >= MIRROR_JOBS_MAX do break
		if j.machine != 0 do continue // its own machines' (never chained)
		jid := text_clean_remote(j.id, 64)
		if jid == "" do continue
		row := Job_Row {
			id            = fmt.aprintf("m%d:%s", no, jid, allocator = a),
			machine       = no,
			name          = remote_text(j.name != "" ? j.name : j.id, MIRROR_TEXT_MAX, a),
			schedule      = remote_text(j.schedule, 80, a),
			enabled       = j.enabled,
			paused        = j.paused,
			paused_why    = remote_text(j.paused_why, MIRROR_TEXT_MAX, a),
			running       = j.running,
			queued        = j.queued,
			err           = remote_text(j.err, MIRROR_LINE_MAX, a),
			next_due      = max(j.next_due, 0),
			last_at       = max(j.last_at, 0),
			last_status   = strings.clone(remote_status(text_clean_remote(j.last_status, 32)), a),
			last_headline = remote_text(j.last_headline, MIRROR_LINE_MAX, a),
			last_run      = remote_text(j.last_run, 64, a),
			unread        = clamp(j.unread, 0, 999),
		}
		// whose it is, as that machine's own Jobs tab groups it (jobs_owners_refresh there): a kind
		// of the fixed set, else Other; its name cleaned. None from an older core: a flat list here
		row.owner = j.owner >= min(Job_Owner_Kind) && j.owner <= max(Job_Owner_Kind) ? j.owner : .Other
		row.owner_name = remote_text(j.owner_name, MIRROR_TEXT_MAX, a)
		row.needs_you = make([dynamic]string, a)
		for x in j.needs_you {
			if len(row.needs_you) >= MIRROR_JOB_LINES do break
			if line := remote_text(x, MIRROR_LINE_MAX, a); line != "" do append(&row.needs_you, line)
		}
		append(&m.jobs, row)
	}
	for j in m.jobs do append(&state.machine_jobs, j)

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
	for i := len(state.machine_jobs) - 1; i >= 0; i -= 1 do if state.machine_jobs[i].machine == no do ordered_remove(&state.machine_jobs, i)
}

// Machine no is gone (removed, or Machines over SSH turned off): its entries leave State, and what
// this Mac showed of it.
mirror_drop :: proc(no: u64, m: ^Machine_Mirror) {
	mirror_unmerge(no)
	mirror_free(m)
	notify_drop_machine(no) // what it rang here
	if id_machine(state.current_session) == no {
		state.current_session = 0
		if s := machine_local_session(); s != nil do focus_session(s.id, {kind = .Internal}) // this Mac's last session, not an empty view
	}
	if id_machine(state.selected_project) == no do state.selected_project = 0
	window_state_changed()
}

mirror_free :: proc(m: ^Machine_Mirror) {
	heap := runtime.heap_allocator()
	delete(m.bell_run, heap)
	for k, v in m.jobs_rang {
		delete(k, heap)
		delete(v, heap)
	}
	delete(m.jobs_rang)
	virtual.arena_destroy(&m.arena)
	m^ = {}
}

// Machine no's bell entries and its jobs that need the user, rung here (after mirror_merge: its
// jobs are m.jobs). run: its core's run id (its hello's).
mirror_alerts :: proc(no: u64, r: ^State, m: ^Machine_Mirror, run: string) {
	heap := runtime.heap_allocator()
	now := time.tick_now()
	newest: u64
	for x in r.notices.items do newest = max(newest, x.id)
	if !m.bell_based || m.bell_run != run { 	// a core seen for the first time: what it has is old
		delete(m.bell_run, heap)
		m.bell_run = strings.clone(run, heap)
		m.bell_based, m.bell_seen = true, newest
	} else {
		items := r.notices.items[:]
		for x in items[max(len(items) - MIRROR_BELL_SCAN, 0):] {
			if x.id <= m.bell_seen || x.machine != 0 do continue // seen, or its own machines' (never chained)
			if x.kind < min(Notice_Kind) || x.kind > max(Notice_Kind) || x.kind == .Job_Needs_You do continue // its jobs' ring below, once per run
			mirror_ring(no, m, remote_notice(no, x), now)
		}
		m.bell_seen = max(m.bell_seen, newest)
	}
	if m.jobs_rang == nil do m.jobs_rang = make(map[string]string, 16, heap)
	for j in m.jobs {
		if len(j.needs_you) == 0 || j.unread <= 0 || j.last_run == "" do continue
		if prev, rang := m.jobs_rang[j.id]; rang {
			if prev == j.last_run do continue
			delete(prev, heap)
			m.jobs_rang[j.id] = strings.clone(j.last_run, heap)
		} else do m.jobs_rang[strings.clone(j.id, heap)] = strings.clone(j.last_run, heap)
		n := Notice{kind = .Job_Needs_You, machine = no, job_id = strings.clone(j.id, heap), title = job_title_with_owner(machine_name(no), job_owner_title(j), j.name, heap), summary = strings.clone(j.needs_you[0], heap)}
		mirror_ring(no, m, n, now)
	}
	// jobs it no longer has
	gone := make([dynamic]string, context.temp_allocator)
	for k in m.jobs_rang {
		found := false
		for j in m.jobs do if j.id == k do found = true
		if !found do append(&gone, k)
	}
	for k in gone {
		key, v := delete_key(&m.jobs_rang, k)
		delete(key, heap)
		delete(v, heap)
	}
}

// Another machine's bell entry as this Mac's (heap; cleaned).
@(private = "file")
remote_notice :: proc(no: u64, x: Notice) -> Notice {
	heap := runtime.heap_allocator()
	n := Notice{kind = x.kind, machine = no, claude = x.claude}
	title := text_clean_remote(x.title, MIRROR_TEXT_MAX)
	n.summary = remote_text(x.summary, MIRROR_LINE_MAX, heap)
	if x.job_id != "" {
		n.job_id = fmt.aprintf("m%d:%s", no, text_clean_remote(x.job_id, 64), allocator = heap)
		// its project, from its mirrored row, unless that machine's title says it already
		owner := ""
		for j in state.machine_jobs do if j.id == n.job_id do owner = job_owner_title(j)
		if strings.has_prefix(title, fmt.tprintf("%s · ", owner)) do owner = ""
		n.title = job_title_with_owner(machine_name(no), owner, title, heap)
		return n
	}
	n.title = strings.clone(title, heap)
	place := text_clean_remote(x.place, MIRROR_TEXT_MAX)
	n.place = place != "" ? fmt.aprintf("%s · %s", machine_name(no), place, allocator = heap) : strings.clone(machine_name(no), heap)
	// its session, tab and project: only ids that pack and are mirrored here
	if sid, ok := id_pack(no, x.session); ok && find_session(sid) != nil {
		n.session = sid
		if tid, tok := id_pack(no, x.tab_id); tok {
			if _, t, _ := find_tab(tid); t != nil do n.tab_id = tid
		}
		if pid, pok := id_pack(no, x.project_id); pok && find_project(pid) != nil do n.project_id = pid
	}
	return n
}

// Rings n here (owned), unless machine no rang MIRROR_RING_PER_MIN already this minute.
@(private = "file")
mirror_ring :: proc(no: u64, m: ^Machine_Mirror, n: Notice, now: time.Tick) {
	n := n
	if m.rang_at == {} || time.tick_diff(m.rang_at, now) >= time.Minute do m.rang_at, m.rang_n = now, 0
	if m.rang_n >= MIRROR_RING_PER_MIN {
		if m.dropped == 0 || m.dropped % 50 == 0 do fmt.eprintfln("Deckhand: machine %s rings too often: %d not rung", machine_name(no), m.dropped + 1)
		m.dropped += 1
		notice_free(&n)
		return
	}
	m.rang_n += 1
	if autotest_active do fmt.printfln("[autotest] machine %s: rang %s %s", machine_name(no), NOTICE_KIND_NAMES[n.kind], n.title)
	if notify_remote(n) do window_state_changed() // (n is the bell's now, or freed)
}

// Fields of a command that name an open session, tab, pane, split or project (machine_route.odin
// routes a command by them).
@(private = "file")
MACHINE_ID_FIELDS := [?]string{"tab_id", "session", "project_id", "pane", "tab", "split", "opener"}

machine_id_field :: proc(name: string) -> bool {
	for f in MACHINE_ID_FIELDS do if f == name do return true
	return false
}

