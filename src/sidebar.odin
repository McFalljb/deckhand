package main

// The left column's model: which projects, chats and sessions show, in what
// order (State.sidebar). Pure functions of State, shared by the layout
// (ui_sidebar.odin), the tests and the scripted scenes.
//
// Order in each section: the pinned group first (in pinned order), then the
// rest by the section's sort (Recent activity, Name, Created). With filter
// text, each group is ordered by match score first, then by the sort.
// Filter words match fuzzily, like the palette (fuzzy_score): projects by
// name and path, sessions by title. A selected project that matches the
// text shows all its sessions; a project whose sessions match (the
// selected one's, or an open one's) stays, whatever its name. Quick filters: running and waiting keep rows
// with either status (a project: any of its open sessions); pinned keeps
// pinned rows. Hidden rows are left out unless show_hidden; a project
// hidden as a temp or missing folder (project_tidy.odin) also shows when
// filter text matches it. Subfolders folded into a project have no row of their own.
//
// Work waiting for the user is never concealed, whoever set the filter or
// hid things (control callers may manage the list): hiding never applies to
// a waiting session or its project, the Open group always lists waiting
// sessions and a waiting session's project row always shows. A waiting row
// that the filter takes out of a session list is counted
// (sidebar_waiting_filtered: "N waiting (filtered)", a click clears the
// filter).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

Sidebar_Row :: struct {
	project: ^Project, // project rows
	session: ^Session, // session and chat rows (into state.sessions / state.chats)
	group:   string, // a group row: its folder (project and session nil; project_tidy.odin)
	pin:     int, // position among the pinned, -1 = not pinned
	hidden:  bool,
	reason:  Hide_Reason, // a project's: why it is hidden (project_tidy.odin)
	score:   int, // filter match (0 without filter text)
	// the Projects tree: depth (0 = top level), the folders inside it that
	// show (a group row inside it counts its members, not itself), whether
	// those follow it; sort keys of project and group rows
	depth:   int,
	kids:    int,
	open:    bool,
	forced:  bool, // open because of the filter, the selection or waiting work: a click does nothing
	active:  i64,
	created: i64,
	name:    string,
	node:    int, // (sidebar_projects)
}

list_index :: proc(list: []string, key: string) -> int {
	for x, i in list do if x == key do return i
	return -1
}

// Removes key from list; true if it was there.
list_remove :: proc(list: ^[dynamic]string, key: string) -> bool {
	at := list_index(list[:], key)
	if at < 0 do return false
	delete(list[at])
	ordered_remove(list, at)
	return true
}

project_pinned :: proc(p: Project) -> int {return list_index(state.sidebar.pinned_projects[:], p.cwd)}
session_pinned :: proc(id: string) -> int {return list_index(state.sidebar.pinned_sessions[:], id)}
project_hidden :: proc(p: Project) -> bool {return list_index(state.sidebar.hidden_projects[:], p.cwd) >= 0}
session_hidden :: proc(id: string) -> bool {return list_index(state.sidebar.hidden_sessions[:], id) >= 0}

// The identity a pin or hide command keeps: a project's cwd or a session's
// pi id. Exactly one of cwd, project_id and pi_session_id must be given. It
// must be known, except when removing (unpin, show again): an entry for a
// project or session that is gone can always be cleared.
sidebar_target :: proc(cwd: string, project_id: u64, pi_session_id: string, removing: bool) -> (key: string, is_project: bool, err: string) {
	n := (cwd != "" ? 1 : 0) + (project_id != 0 ? 1 : 0) + (pi_session_id != "" ? 1 : 0)
	if n != 1 do return "", false, "give one of cwd, project_id or pi_session_id"
	if cwd != "" {
		if removing do return cwd, true, ""
		for &p in state.projects do if p.group == .Projects && p.cwd == cwd do return cwd, true, ""
		return "", false, "no such project"
	}
	if project_id != 0 {
		p := find_project(project_id)
		if p == nil do return "", false, "no such project"
		if p.group == .Chats do return "", false, CHATS_NOT_A_PROJECT
		return p.cwd, true, ""
	}
	if !removing && !session_known(pi_session_id) do return "", false, "no such session"
	return pi_session_id, false, ""
}

// Room for one more entry in a full pin or hide list: project entries whose
// folder is gone go first, else the oldest entry. False if still full.
sidebar_make_room :: proc(list: ^[dynamic]string, is_project: bool) -> bool {
	if len(list) < SIDEBAR_LIST_MAX do return true
	if is_project {
		#reverse for x, i in list do if !os.exists(x) {
			delete(x)
			ordered_remove(list, i)
		}
	}
	if len(list) >= SIDEBAR_LIST_MAX {
		delete(list[0])
		ordered_remove(list, 0)
	}
	return len(list) < SIDEBAR_LIST_MAX
}

session_waiting :: proc(id: string) -> bool {return session_status(id) == .Waiting}

// Listed (the selected project's or a chat) or open.
session_known :: proc(id: string) -> bool {
	if session_listed(state.sessions[:], id) || session_listed(state.chats[:], id) do return true
	for s in state.open_sessions do if !s.home && s.pi_session_id == id do return true
	return false
}

// A project's folder (Chats: its session dir) or one of its session files
// (temp allocator).
sidebar_path :: proc(project_id: u64, pi_session_id: string) -> (path: string, err: string) {
	p := find_project(project_id)
	if p == nil do return "", "no such project"
	if pi_session_id != "" {
		path = find_session_file(p^, pi_session_id)
		if path == "" do return "", "no such session in this project"
		return path, ""
	}
	path = p.group == .Chats ? p.dir : p.cwd
	if !os.exists(path) do return "", "the folder is gone"
	return strings.clone(path, context.temp_allocator), ""
}

// The strongest status of a project's open sessions (waiting outranks running).
project_status :: proc(project_id: u64) -> Row_Status {
	best := Row_Status.None
	for &s in state.open_sessions {
		if s.home || s.project_id != project_id do continue
		pt := session_pi_tab(&s)
		if pt == nil do continue
		st := pi_tab_status(pt^)
		if st == .Waiting do return .Waiting
		if st == .Running do best = .Running
	}
	return best
}

// Sum of the best score of each filter word over texts; false if a word
// matches none. The first text (a name or title) matches fuzzily, like the
// palette; the others (a path) only as a substring, at half the score: a
// scattered match would hit almost any long path. No words: (0, true).
filter_score :: proc(words: []string, texts: ..string) -> (score: int, ok: bool) {
	for w in words {
		best := -1
		for t, i in texts {
			if i > 0 && !strings.contains(strings.to_lower(t, context.temp_allocator), strings.to_lower(w, context.temp_allocator)) do continue
			s, _, hit := fuzzy_score(w, t)
			if !hit do continue
			if i > 0 do s /= 2
			best = max(best, s)
		}
		if best < 0 do return 0, false
		score += best
	}
	return score, true
}

@(private = "file")
quick_ok :: proc(st: Row_Status, pinned: bool) -> bool {
	sb := state.sidebar
	if sb.only_pinned && !pinned do return false
	if sb.only_running || sb.only_waiting {
		return (sb.only_running && st == .Running) || (sb.only_waiting && st == .Waiting)
	}
	return true
}

filter_words :: proc() -> []string {return strings.fields(state.sidebar.filter, context.temp_allocator)}

// Whether any filter (text or quick) is on.
sidebar_filtering :: proc() -> bool {
	sb := state.sidebar
	return sb.filter != "" || sb.only_running || sb.only_waiting || sb.only_pinned
}

// The project rows in display order (temp allocator): a tree
// (project_tidy.odin). Top-level rows are sorted as the section's sort says;
// a parent or group row that is open is followed by its rows (depth + 1),
// sorted the same way. The Chats entry is not one of them.
//
// A row shows when it passes the rules above or when one of its rows
// shows (as their context). Parent and group rows are open when saved open
// (Sidebar.expanded), while filtering (the matches show), or when they hold
// the selected project or waiting work.
sidebar_projects :: proc() -> []Sidebar_Row {
	Node :: struct {
		row:   Sidebar_Row,
		ok:    bool, // passes on its own
		kids:  [dynamic]int,
		path:  string,
		hot:   bool, // the selected project or waiting work
		force: bool, // holds a hot row: open
		shown: bool,
		group_in: u64, // a group row: the project it is nested under (0 = top level)
		group_up: string, // a group row: the group row it is inside ("" = none)
	}
	nodes := make([dynamic]Node, context.temp_allocator)
	top := make([dynamic]int, context.temp_allocator)
	words := filter_words()
	for &p in state.projects {
		if p.group != .Projects do continue
		reason := project_hide_reason(p)
		r := Sidebar_Row{project = &p, pin = project_pinned(p), hidden = reason != .None, reason = reason}
		st := project_status(p.id)
		score, ok := filter_score(words, project_name(p), p.cwd)
		pass := true
		if st != .Waiting { 	// waiting work always shows
			found := (reason == .Temp || reason == .Missing) && len(words) > 0 && ok // found by the filter
			if r.hidden && !state.sidebar.show_hidden && !found do pass = false
			// a project whose sessions match stays: its matches show under it (or in Open)
			if (!ok || !quick_ok(st, r.pin >= 0)) && !project_sessions_match(p) do pass = false
		}
		r.score = score
		r.active, r.created, r.name = project_active(p), project_created(p), project_name(p)
		append(&nodes, Node{row = r, ok = pass, path = p.cwd, hot = p.id == state.selected_project || st == .Waiting, kids = make([dynamic]int, context.temp_allocator)})
	}
	n_projects := len(nodes)
	for i in 0 ..< n_projects {
		p := nodes[i].row.project
		at := -1
		if p.parent != 0 {
			for j in 0 ..< n_projects do if nodes[j].row.project.id == p.parent do at = j
		}
		if at < 0 && p.group_dir != "" {
			for j in n_projects ..< len(nodes) do if nodes[j].path == p.group_dir do at = j
			if at < 0 {
				at = len(nodes)
				append(&nodes, Node{row = {group = p.group_dir, pin = -1, name = p.group_dir[strings.last_index_byte(p.group_dir, '/') + 1:]}, path = p.group_dir, kids = make([dynamic]int, context.temp_allocator), group_in = p.group_in, group_up = p.group_up})
			}
		}
		if at >= 0 do append(&nodes[at].kids, i)
		else do append(&top, i)
	}
	// group rows: inside another group row or under a project (project_tidy.odin), else top-level
	for g in n_projects ..< len(nodes) {
		at := -1
		if nodes[g].group_up != "" do for j in n_projects ..< len(nodes) do if nodes[j].path == nodes[g].group_up do at = j
		if at < 0 && nodes[g].group_in != 0 do for j in 0 ..< n_projects do if nodes[j].row.project.id == nodes[g].group_in do at = j
		if at >= 0 do append(&nodes[at].kids, g)
		else do append(&top, g)
	}
	// group rows' labels: the last folder, or as many as tell them apart
	for i in n_projects ..< len(nodes) {
		k := 1
		for ; ; k += 1 {
			mine := path_tail(nodes[i].path, k)
			if mine == strings.trim_right(nodes[i].path, "/") {
				context.allocator = context.temp_allocator
				nodes[i].row.name = short_label(nodes[i].path) // (~/…)
				break
			}
			clash := false
			for j in n_projects ..< len(nodes) do if j != i && path_tail(nodes[j].path, k) == mine do clash = true
			if !clash {
				nodes[i].row.name = mine
				break
			}
		}
	}
	// shown, force and the group rows' keys, from the leaves up
	visit :: proc(nodes: []Node, i: int) {
		n := &nodes[i]
		n.shown = n.ok
		for k in n.kids {
			visit(nodes, k)
			c := nodes[k]
			if c.force || c.hot do n.force = true
			if !c.shown do continue
			n.shown = true
			n.row.kids += c.row.group != "" ? c.row.kids : 1 // the folders it holds: a group row's members, not the group as one
			if n.row.group != "" {
				n.row.score = max(n.row.score, c.row.score)
				n.row.active = max(n.row.active, c.row.active)
				n.row.created = max(n.row.created, c.row.created)
			}
		}
	}
	for i in top do visit(nodes[:], i)
	rows := make([dynamic]Sidebar_Row, context.temp_allocator)
	emit :: proc(nodes: []Node, list: []int, depth: int, rows: ^[dynamic]Sidebar_Row) {
		level := make([dynamic]Sidebar_Row, context.temp_allocator)
		for i in list {
			if !nodes[i].shown do continue
			r := nodes[i].row
			r.depth = depth
			r.node = i
			append(&level, r)
		}
		sort_rows(level[:], .Projects)
		for &r in level {
			n := nodes[r.node]
			r.forced = n.row.kids > 0 && (sidebar_filtering() || n.force)
			r.open = r.forced || (n.row.kids > 0 && list_index(state.sidebar.expanded[:], n.path) >= 0)
			append(rows, r)
			if r.open do emit(nodes, n.kids[:], depth + 1, rows)
		}
	}
	emit(nodes[:], top[:], 0, &rows)
	return rows[:]
}

// Whether the Projects list draws the line between pinned and other rows
// above rows[i]: the first unpinned top-level row after a pinned one (a
// pinned parent's nested rows belong to it, pinned or not).
pinned_divider_before :: proc(rows: []Sidebar_Row, i: int) -> bool {
	if rows[i].depth != 0 || rows[i].pin >= 0 do return false
	for j := i - 1; j >= 0; j -= 1 do if rows[j].depth == 0 do return rows[j].pin >= 0
	return false
}

// The last k folders of path ("/a/b/c", 2 -> "b/c"; all of it when k is
// as many or more).
path_tail :: proc(path: string, k: int) -> string {
	p := strings.trim_right(path, "/")
	i := len(p)
	for _ in 0 ..< k {
		j := strings.last_index_byte(p[:i], '/')
		if j < 0 do return p
		i = j
	}
	return i == 0 ? p : p[i + 1:]
}

// A parent or group row's folder path (Set_Row_Expanded).
row_path :: proc(r: Sidebar_Row) -> string {
	return r.group != "" ? r.group : r.project.cwd
}

// Whether the filter keeps some of a project's sessions: the selected
// project's rows, or an open session's title elsewhere (the only sessions
// known for other projects).
@(private = "file")
project_sessions_match :: proc(p: Project) -> bool {
	if !sidebar_filtering() do return false
	if p.id == state.selected_project do return len(sidebar_sessions(.Sessions)) > 0
	words := filter_words()
	for &o in state.open_sessions {
		if o.home || o.project_id != p.id do continue
		st := Row_Status.None
		if pt := session_pi_tab(&o); pt != nil do st = pi_tab_status(pt^)
		if _, ok := filter_score(words, open_session_title(&o)); ok && quick_ok(st, session_pinned(o.pi_session_id) >= 0) do return true
	}
	return false
}

// The session rows of a section (.Sessions: the selected project's; .Chats)
// in display order (temp allocator).
sidebar_sessions :: proc(section: Sort_Section) -> []Sidebar_Row {
	rows := make([dynamic]Sidebar_Row, context.temp_allocator)
	list := section == .Chats ? state.chats[:] : state.sessions[:]
	words := filter_words()
	// a project found by the filter shows all its sessions
	if section == .Sessions && len(words) > 0 {
		if p := find_project(state.selected_project); p != nil {
			if _, ok := filter_score(words, project_name(p^), p.cwd); ok do words = nil
		}
	}
	for &s in sessions_with_new(section, list) {
		r := Sidebar_Row{session = &s, pin = session_pinned(s.id), hidden = session_hidden(s.id)}
		st := session_status(s.id)
		if r.hidden && !state.sidebar.show_hidden && st != .Waiting do continue // hiding never conceals waiting work
		score, ok := filter_score(words, session_label(s, section == .Chats))
		if !ok || !quick_ok(st, r.pin >= 0) do continue
		r.score = score
		append(&rows, r)
	}
	sort_rows(rows[:], section)
	return rows[:]
}

// A section's listed sessions plus the open ones not listed yet (a new chat
// or session before pi wrote its file, or since the last scan), as the
// section's rows show them (temp allocator; the listed ones are copies).
sessions_with_new :: proc(section: Sort_Section, list: []Session) -> []Session {
	pid := state.selected_project
	if section == .Chats {
		c := chats_project()
		pid = c != nil ? c.id : 0
	}
	out := make([dynamic]Session, 0, len(list) + 4, context.temp_allocator)
	append(&out, ..list)
	if pid == 0 do return out[:]
	for &o in state.open_sessions {
		if o.home || o.project_id != pid || session_listed(list, o.pi_session_id) do continue
		title := open_session_title(&o)
		if o.title == "" do title = "" // not named yet: the section's "Untitled …"
		// no file yet: when it was last made current (stable from frame to frame, so the order is)
		modified := o.mtime != {} ? o.mtime : time.Time{_nsec = o.shown_at}
		append(&out, Session{id = o.pi_session_id, path = o.session_file, when_ = utc_minute(modified), title = title, modified = modified})
	}
	return out[:]
}

// "2026-08-21 01:20" (UTC), as session file names give it (temp).
@(private = "file")
utc_minute :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, _ := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d", y, int(mo), d, h, mi)
}

// A listed session's title: its name or first prompt (titles.odin), else
// "Untitled session · <created>" (in a project) or "Untitled chat · …"; a
// new one pi has not written yet is just "Untitled session" or "… chat".
session_label :: proc(s: Session, chat := false) -> string {
	if s.title != "" do return s.title
	if s.untitled != "" do return s.untitled
	return chat ? "Untitled chat" : "Untitled session"
}

// What a project counts as "last active" and "created" for sorting: its
// newest session, or when it was added by hand if that is later.
project_active :: proc(p: Project) -> i64 {return max(p.newest._nsec, p.added._nsec)}
project_created :: proc(p: Project) -> i64 {
	if p.created == {} do return p.added._nsec
	if p.added == {} do return p.created._nsec
	return min(p.created._nsec, p.added._nsec)
}

@(private = "file")
sorting: Sort_By

@(private = "file")
sort_rows :: proc(rows: []Sidebar_Row, section: Sort_Section) {
	sorting = state.sidebar.sort[section]
	slice.stable_sort_by(rows, proc(a, b: Sidebar_Row) -> bool {
		ap, bp := a.pin >= 0, b.pin >= 0
		if ap != bp do return ap
		if ap do return a.pin < b.pin
		if a.score != b.score do return a.score > b.score
		if a.session == nil { 	// project and group rows
			switch sorting {
			case .Recent:  return a.active > b.active
			case .Created: return a.created > b.created
			case .Name:    return name_less(a.name, b.name)
			}
		}
		x, y := a.session^, b.session^
		switch sorting {
		case .Recent:  return x.modified._nsec > y.modified._nsec
		case .Created: return x.when_ > y.when_
		case .Name:    return name_less(session_label(x), session_label(y))
		}
		return false
	})
}

@(private = "file")
name_less :: proc(a, b: string) -> bool {
	la, lb := strings.to_lower(a, context.temp_allocator), strings.to_lower(b, context.temp_allocator)
	return la < lb
}

// The Open group: every open session of every project and Chats (never
// Home), the current one first, then the most recently shown. It follows the
// filter (title or project name) and the quick filters; hidden does not
// apply (an open session is in use).
sidebar_open :: proc() -> []^Open_Session {
	rows := make([dynamic]^Open_Session, context.temp_allocator)
	words := filter_words()
	for &s in state.open_sessions {
		if s.home do continue
		st := Row_Status.None
		if pt := session_pi_tab(&s); pt != nil do st = pi_tab_status(pt^)
		if st != .Waiting { 	// waiting work always shows
			if _, ok := filter_score(words, open_session_title(&s), session_project_name(&s)); !ok do continue
			if !quick_ok(st, session_pinned(s.pi_session_id) >= 0) do continue
		}
		append(&rows, &s)
	}
	slice.stable_sort_by(rows[:], proc(a, b: ^Open_Session) -> bool {
		ac, bc := a.id == state.current_session, b.id == state.current_session
		if ac != bc do return ac
		return a.shown_at > b.shown_at
	})
	return rows[:]
}


// Waiting sessions the filter took out of the session lists (the selected
// project's and Chats): "N waiting (filtered)".
sidebar_waiting_filtered :: proc() -> int {
	if !sidebar_filtering() do return 0
	n := 0
	for sec in ([2]Sort_Section{.Sessions, .Chats}) {
		list := sessions_with_new(sec, sec == .Chats ? state.chats[:] : state.sessions[:])
		rows := sidebar_sessions(sec)
		for s in list {
			if !session_waiting(s.id) do continue
			shown := false
			for r in rows do if r.session.id == s.id do shown = true
			if !shown do n += 1
		}
	}
	return n
}

// Enter in the filter: the best-scoring row of the three lists (ties: a
// session, then a chat, then a project), as the command a click would send:
// a project is selected, a session or chat opens. nil = nothing matches.
sidebar_best_match :: proc() -> Command {
	best := -1
	cmd: Command
	for r in sidebar_sessions(.Sessions) do if r.score > best {
		best = r.score
		cmd = Open_Session_Cmd{state.selected_project, r.session.id}
	}
	if c := chats_project(); c != nil {
		for r in sidebar_sessions(.Chats) do if r.score > best {
			best = r.score
			cmd = Open_Session_Cmd{c.id, r.session.id}
		}
	}
	for r in sidebar_projects() do if r.project != nil && r.score > best && r.project.id != state.selected_project {
		best = r.score
		cmd = Select_Project{r.project.id}
	}
	return cmd
}

// Stats of open sessions' files (title and age), for tests.
open_session_stats: int

// An open session's file is looked at most once a second (title, age): the
// running dot redraws ten times a second.
open_session_refresh :: proc(s: ^Open_Session) {
	if s.session_file == "" do return
	if s.checked != {} && time.tick_since(s.checked) < time.Second do return
	s.checked = time.tick_now()
	open_session_stats += 1
	fi, err := os.stat(s.session_file, context.temp_allocator)
	if err != nil {
		s.mtime = {}
		return
	}
	s.mtime = fi.modification_time
	if fi.size != s.title_size {
		delete(s.title)
		s.title = title_of(s.session_file, fi.size, fi.modification_time) // cached (titles.odin)
		s.title_size = fi.size
	}
}

// "5m" since the session file last changed; "new" before pi wrote it.
open_session_age :: proc(s: ^Open_Session) -> string {
	if s.session_file == "" do return "new"
	open_session_refresh(s)
	return ago(s.mtime)
}
