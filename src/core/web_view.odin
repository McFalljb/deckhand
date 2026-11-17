package core

// The views a browser draws, computed here (#148) and sent only to a web link (state_sections).
// The native window computes the same from its replica with these very procs (sidebar.odin,
// needing_you.odin); a browser has no replica in Odin, so the core sends their results and the
// page never re-implements the tree, the filter, the sort or the Attention order.
//
// The tree goes as data, keyed, a state section per row, so the state stream's per-section
// deltas carry only what changed: a session's status flip touches no row here (its tabs section
// and "web" carry it), a rename one row, a new order or filter one list of keys. The page folds
// rows itself (its own view state: no command); the core lists every row that passes the
// filter, in its order, whatever is folded.
//
//   web           {fleet {waiting, errors, unseen, working}, next (open session id, 0), open [ids],
//                 attention [{session, group, tab}], deck [same], filtered (waiting rows the
//                 filter hides), here {name, label}, watch [project ids], new [{machine,
//                 projects, chats, claude_tab, codex_tab, note}]: the New session picker's harnesses (web_view_new_choices)}
//   webo:<id>     an open session's row: {title, place, chat, at (Unix ns, 0 = new)}
//   webm          [{no, open [ids], projects [{id, depth, name}]}]: each other machine
//   webtree       the Projects tree in order: [[key, depth, kids, forced] or key (0, 0, 0)]; key = a project's
//                 id, or g<hash> for a group folder; kids = nested folders shown; forced = open
//                 whatever the page folded (the filter, waiting work)
//   webp:<key>    a tree row: {id (0 = a group folder), name, path, pin, hidden}
//   websl:<p>     the session ids of project p in order, for the projects the page opened
//                 (web_watch) and the selected one
//   webs:<p>:<id> a session row: {label, open (open session id, 0), pin, hidden, dot, claude,
//                 codex, modified (ns)}
//   webcl, webc:<id>  the Chats, the same way
//   webbars       the tabs' bars as text, with the actions a browser may take (tab_bars.odin:
//                 web_bars_json)
//
// Computed only when something it reads changed (web_view_cached: a hash of the other sections,
// the open sessions' file stamps and the watched lists), and never reading a disk on a flush:
// titles and stamps are what web_view_tick last read, at most once a second per open session;
// watched projects are listed by web_watch_apply and again by web_view_tick every
// WEB_WATCH_RESCAN.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"

WEB_VIEW_SECTION :: "web"
WEB_WATCH_MAX :: 48 // projects a browser lists sessions for at once (the first ones it names)
WEB_WATCH_IN_MAX :: 1000 // ids in one web_watch (more is refused)
WEB_WATCH_RESCAN :: 10 * time.Second

ATTENTION_GROUP_NAMES := [Attention_Group]string {
	.Needs_You = "needs_you",
	.Finished  = "finished",
	.Working   = "working",
	.Idle      = "idle",
}

// web_view_tick's last look at the bars (web_bars_json's hash)
@(private = "file")
web_bars_seen: u64

// The page's open projects (web_watch): their sessions listed here (the selected project's are
// state.sessions already).
Web_Watched :: struct {
	pid:    u64,
	arena:  virtual.Arena,
	list:   [dynamic]Session,
	at:     time.Tick, // last listed
	digest: u64, // what the list held then (a change bumps web_watch_gen)
}
@(private)
web_watch: [dynamic]Web_Watched
@(private)
web_watch_gen: u64

// The page opened (or still has open) these projects in its tree: list their sessions.
Web_Watch :: struct {
	projects: []u64, // at most WEB_WATCH_MAX are kept
}

web_watch_apply :: proc(c: Web_Watch) -> Result {
	context.allocator = runtime.heap_allocator()
	keep := make([dynamic]u64, context.temp_allocator)
	for id in c.projects {
		if len(keep) >= WEB_WATCH_MAX do break
		if p := find_project(id); p != nil && p.group == .Projects && p.machine == 0 do append(&keep, id)
	}
	// the ones no longer open go
	for i := len(web_watch) - 1; i >= 0; i -= 1 {
		w := &web_watch[i]
		found := false
		for id in keep do if id == w.pid do found = true
		if found do continue
		virtual.arena_destroy(&w.arena)
		ordered_remove(&web_watch, i)
	}
	for id in keep {
		found := false
		for w in web_watch do if w.pid == id do found = true
		if found do continue
		append(&web_watch, Web_Watched{pid = id})
		web_watch_list(&web_watch[len(web_watch) - 1])
	}
	web_watch_gen += 1
	window_state_changed()
	return {ok = true}
}

// Lists a watched project's sessions (its folder; a directory read and cached titles).
@(private = "file")
web_watch_list :: proc(w: ^Web_Watched) {
	w.at = time.tick_now()
	p := find_project(w.pid)
	if p == nil || p.id == state.selected_project do return // the selected one: state.sessions
	read_project_sessions(p.dir, &w.arena, &w.list)
	h := hash.fnv64a(transmute([]u8)string("w"))
	for s in w.list {
		h = hash.fnv64a(transmute([]u8)s.id, h)
		h = hash.fnv64a(transmute([]u8)s.title, h)
		stamp := s.modified._nsec
		h = hash.fnv64a(mem.ptr_to_bytes(&stamp), h)
	}
	if h != w.digest {
		w.digest = h
		web_watch_gen += 1
		window_state_changed()
	}
}

// The last sections and what they were computed from (heap); builds counts computations (tests).
@(private)
web_view_last: struct {
	key:      u64,
	sections: [dynamic][2]string,
	builds:   int,
}

// While it computes, titles and ages come from what the core holds (no disk: sidebar.odin).
web_view_computing: bool

// The sections for these other sections (state_sections' out so far): the last ones when none
// of them, nor an open session's file stamp, nor a watched list changed.
web_view_cached :: proc(sections: [][2]string) -> [][2]string {
	h := hash.fnv64a(transmute([]u8)string("web"))
	for x in sections {
		h = hash.fnv64a(transmute([]u8)x[0], h)
		h = hash.fnv64a(transmute([]u8)x[1], h)
	}
	for &s in state.open_sessions {
		stamp := [2]i64{s.mtime._nsec, s.title_size}
		h = hash.fnv64a(mem.ptr_to_bytes(&stamp), h)
		h = hash.fnv64a(transmute([]u8)s.title, h)
	}
	gen := web_watch_gen
	h = hash.fnv64a(mem.ptr_to_bytes(&gen), h)
	nk := web_view_new_key()
	h = hash.fnv64a(mem.ptr_to_bytes(&nk), h)
	// the tabs' bars: some change with time alone (a Claude tab's hooks silent past their grace)
	h = hash.fnv64a(transmute([]u8)web_bars_json(), h)
	if web_view_last.builds > 0 && h == web_view_last.key do return web_view_last.sections[:]
	heap := runtime.heap_allocator()
	for x in web_view_last.sections {
		delete(x[0], heap)
		delete(x[1], heap)
	}
	clear(&web_view_last.sections)
	if web_view_last.sections == nil do web_view_last.sections = make([dynamic][2]string, heap)
	web_view_computing = true
	web_view_build(&web_view_last.sections)
	web_view_computing = false
	web_view_last.key = h
	web_view_last.builds += 1
	return web_view_last.sections[:]
}

// While a browser is attached: each open session's file looked at (title, stamp), at most once a
// second (open_session_refresh), and the watched projects listed again now and then.
web_view_tick :: proc() {
	if !window_link_web() do return
	for &s in state.open_sessions {
		if s.home do continue
		before := s.mtime
		open_session_refresh(&s)
		if s.mtime != before do window_state_changed()
	}
	for &w in web_watch do if time.tick_since(w.at) >= WEB_WATCH_RESCAN do web_watch_list(&w)
	changes_web_tick()
	web_settings_tick()
	// a bar that came or went with time alone (no command, no section change): a flush
	if bh := hash.fnv64a(transmute([]u8)web_bars_json()); bh != web_bars_seen {
		web_bars_seen = bh
		window_state_changed()
	}
}

@(private = "file")
put :: proc(out: ^[dynamic][2]string, name: string, b: ^strings.Builder) {
	heap := runtime.heap_allocator()
	append(out, [2]string{strings.clone(name, heap), strings.clone(strings.to_string(b^), heap)})
}

@(private = "file")
web_view_build :: proc(out: ^[dynamic][2]string) {
	// ---- web: the small part (fleet, Open, Attention, the Deck) ----
	b := strings.builder_make(context.temp_allocator)
	f := fleet_tally()
	fmt.sbprintf(&b, `{{"fleet":{{"waiting":%d,"errors":%d,"unseen":%d,"working":%d}}`, f.waiting, f.errors, f.unseen, f.working)
	next: u64
	if s, _ := next_needing_target(hub = true); s != nil do next = s.id
	fmt.sbprintf(&b, `,"next":%d,"open":[`, next)
	for s, i in sidebar_open() {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%d", s.id)
	}
	strings.write_string(&b, `],"attention":`)
	web_view_attention(&b, attention_rows())
	strings.write_string(&b, `,"deck":`)
	web_view_attention(&b, attention_rows(deck = true))
	fmt.sbprintf(&b, `,"filtered":%d,"here":{{"name":`, sidebar_waiting_filtered())
	json_quote(&b, machine_here_name())
	strings.write_string(&b, `,"label":`)
	json_quote(&b, ODIN_OS == .Darwin ? "this Mac" : "this machine")
	strings.write_string(&b, `},"watch":[`)
	for w, i in web_watch {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%d", w.pid)
	}
	strings.write_string(&b, `],"new":`)
	web_view_new_choices(&b)
	strings.write_string(&b, "}")
	put(out, WEB_VIEW_SECTION, &b)

	// ---- webo:<id>: an open session's title row ----
	for &s in state.open_sessions {
		if s.home do continue
		b = strings.builder_make(context.temp_allocator)
		ic, place := session_place(&s)
		strings.write_string(&b, `{"title":`)
		json_quote(&b, open_session_title(&s, refresh = false))
		strings.write_string(&b, `,"place":`)
		json_quote(&b, place)
		fmt.sbprintf(&b, `,"chat":%v,"at":%d}}`, ic == .Chat, web_view_stamp(&s))
		put(out, fmt.tprintf("webo:%d", s.id), &b)
	}

	// ---- webm: other machines (few rows) ----
	b = strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for m, i in state.machines {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"no":%d,"open":[`, m.no)
		for s, k in machine_open_rows(m.no) {
			if k > 0 do strings.write_byte(&b, ',')
			fmt.sbprintf(&b, "%d", s.id)
		}
		strings.write_string(&b, `],"projects":[`)
		for r, k in machine_project_rows(m.no) {
			if k > 0 do strings.write_byte(&b, ',')
			id: u64
			name := r.name
			if r.project != nil {
				id = r.project.id
				name = project_display(r.project^)
			}
			fmt.sbprintf(&b, `{{"id":%d,"depth":%d,"name":`, id, r.depth)
			json_quote(&b, name)
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
	}
	strings.write_byte(&b, ']')
	put(out, "webm", &b)

	// ---- webtree: the Projects tree's order (the rows that pass the filter); webp:<key>: every
	// row, filtered out or not (a filter keystroke sends the order, not the rows) ----
	rows := sidebar_projects(all = true)
	for &p in state.projects {
		if p.group != .Projects || p.machine != 0 do continue
		web_view_project_row(out, Sidebar_Row{project = &p, pin = project_pinned(p), hidden = project_hide_reason(p) != .None})
	}
	t := strings.builder_make(context.temp_allocator)
	strings.write_byte(&t, '[')
	for r, i in rows {
		key := web_row_key(r)
		if i > 0 do strings.write_byte(&t, ',')
		// [key, depth, nested folders shown, open whatever the page folded (filter, waiting work)];
		// a top-level row with no nested folders: its key alone (most rows: the list stays small)
		if r.depth == 0 && r.kids == 0 && !r.forced do json_quote(&t, key)
		else {
			strings.write_byte(&t, '[')
			json_quote(&t, key)
			fmt.sbprintf(&t, ",%d,%d,%d]", r.depth, r.kids, r.forced ? 1 : 0)
		}
		if r.project == nil do web_view_project_row(out, r) // a group folder's (the projects': above)
	}
	strings.write_byte(&t, ']')
	put(out, "webtree", &t)

	// ---- the sessions of the watched projects (and of the selected one: another machine's
	// list comes only that way): websl:<p> their order, webs:<p>:<id> the rows; Chats: webcl, webc:<id> ----
	sel := find_project(state.selected_project)
	if sel != nil && sel.group == .Projects {
		watched := false
		for w in web_watch do if w.pid == sel.id do watched = true
		if !watched do web_view_session_rows(out, .Sessions, state.sessions[:], sel.id, fmt.tprintf("websl:%d", sel.id), fmt.tprintf("webs:%d:", sel.id))
	}
	for &w in web_watch {
		if find_project(w.pid) == nil do continue
		list := w.pid == state.selected_project ? state.sessions[:] : w.list[:]
		web_view_session_rows(out, .Sessions, list, w.pid, fmt.tprintf("websl:%d", w.pid), fmt.tprintf("webs:%d:", w.pid))
	}
	web_view_session_rows(out, .Chats, state.chats[:], 0, "webcl", "webc:")

	// ---- webbars: the tabs' bars as text (tab_bars.odin), the browser's status strip ----
	b = strings.builder_make(context.temp_allocator)
	strings.write_string(&b, web_bars_json())
	put(out, "webbars", &b)
}

// The New session picker's harnesses per machine (0 = this one) and kind of project, as the native
// picker offers them (new_session_choices: installed here, or on that machine by its checklist;
// Claude Code and Codex in Chats here, never another machine's): [{machine, projects [{harness,
// label, account}], chats [same], claude_tab [{account, name}], codex_tab [same], note}] in the
// picker's order (the last used first), one row per account while there are several; the tab
// lists are New Claude tab and New Codex tab there ([] = not installed). note: why a list is empty.
// project_rows (this machine's, while there are several accounts): [{project, rows [same]}] for
// each project whose picker differs from its kind's list (its last used account first: the native
// picker's own rows, new_session_choices).
@(private = "file")
web_view_new_choices :: proc(b: ^strings.Builder) {
	// the picker's rows: Claude Code and Codex once per account while there are several (the
	// default's first is the core's pick, or p's own), each with its account ("" = the core's pick)
	rows :: proc(b: ^strings.Builder, p: ^Project) {
		strings.write_byte(b, '[')
		n := 0
		for it in new_session_choices(p, "") {
			h, ok := harness_of(it.cmd)
			if !ok do continue
			if n > 0 do strings.write_byte(b, ',')
			n += 1
			account := ""
			if c, is := it.cmd.(New_Claude_Session); is do account = c.account
			fmt.sbprintf(b, `{{"harness":"%s","label":`, HARNESS_KEYS[h])
			json_quote(b, it.label)
			strings.write_string(b, `,"account":`)
			json_quote(b, account)
			strings.write_byte(b, '}')
		}
		strings.write_byte(b, ']')
	}
	list :: proc(b: ^strings.Builder, no: u64, group: Sidebar_Group) {
		p := Project{id = no << MACHINE_ID_SHIFT, machine = no, group = group}
		rows(b, &p)
	}
	// New Claude tab / New Codex tab there: once per account while there are several (this
	// machine's; claude_account_items), [] while that harness is not there
	tabs :: proc(b: ^strings.Builder, no: u64, harness: Harness) {
		strings.write_byte(b, '[')
		on: bool
		if no == 0 do on = harness_is_codex(harness) ? codex_installed() : claude_installed()
		else {
			_, claude, cx := machine_harnesses(no)
			on = harness_is_codex(harness) ? cx : claude
		}
		if on {
			items := make([dynamic]Menu_Item, context.temp_allocator)
			if no == 0 do claude_account_items(&items, "", New_Claude_Tab{harness = harness})
			else do append(&items, Menu_Item{cmd = New_Claude_Tab{harness = harness}})
			for it, i in items {
				c, _ := it.cmd.(New_Claude_Tab)
				name := ""
				if c.account != "" do for a in claude_accounts(harness) do if a.dir == c.account do name = a.label
				if i > 0 do strings.write_byte(b, ',')
				strings.write_string(b, `{"account":`)
				json_quote(b, c.account)
				strings.write_string(b, `,"name":`)
				json_quote(b, name)
				strings.write_byte(b, '}')
			}
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '[')
	for i in 0 ..= len(state.machines) {
		no := i == 0 ? 0 : state.machines[i - 1].no
		if i > 0 do strings.write_byte(b, ',')
		fmt.sbprintf(b, `{{"machine":%d,"projects":`, no)
		list(b, no, .Projects)
		strings.write_string(b, `,"chats":`)
		list(b, no, .Chats)
		strings.write_string(b, `,"claude_tab":`)
		tabs(b, no, .Claude)
		strings.write_string(b, `,"codex_tab":`)
		tabs(b, no, .Codex)
		strings.write_string(b, `,"note":`)
		json_quote(b, no == 0 ? NO_HARNESS : machine_no_harness_note(no))
		if no == 0 do web_view_new_project_rows(b, rows)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

// This machine's projects whose New session picker is not their kind's list (with several
// accounts, its last used account first: claude_account_pick): ,"project_rows":[{project, rows}].
@(private = "file")
web_view_new_project_rows :: proc(b: ^strings.Builder, rows: proc(b: ^strings.Builder, p: ^Project)) {
	if len(claude_accounts(.Claude)) < 2 && len(claude_accounts(.Codex)) < 2 do return
	strings.write_string(b, `,"project_rows":[`)
	kinds: [Sidebar_Group]string
	for g in Sidebar_Group do if g == .Projects || g == .Chats {
		p := Project{group = g}
		k := strings.builder_make(context.temp_allocator)
		rows(&k, &p)
		kinds[g] = strings.to_string(k)
	}
	n := 0
	for &p in state.projects {
		if p.machine != 0 || (p.group != .Projects && p.group != .Chats) do continue
		r := strings.builder_make(context.temp_allocator)
		rows(&r, &p)
		if strings.to_string(r) == kinds[p.group] do continue
		if n > 0 do strings.write_byte(b, ',')
		n += 1
		fmt.sbprintf(b, `{{"project":%d,"rows":%s}}`, p.id, strings.to_string(r))
	}
	strings.write_byte(b, ']')
}

// What the New session picker reads besides the other sections (web_view_cached's key): which
// harnesses this machine has and the last used one; with several accounts, each project's pick
// (claude_account_pick: its last used account, from the history no section carries).
@(private = "file")
web_view_new_key :: proc() -> u64 {
	k := u64(state.settings.last_harness)
	if pi_installed() do k |= 1 << 8
	if claude_installed() do k |= 1 << 9
	if codex_installed() do k |= 1 << 10
	for h in ([2]Harness{.Claude, .Codex}) do if len(claude_accounts(h)) >= 2 {
		for &p in state.projects do if p.machine == 0 {
			k = hash.fnv64a(transmute([]u8)claude_account_pick(&p, h), k)
		}
	}
	return k
}

// A tree row's key: its project's id, or g and a hash of a group row's folder.
@(private = "file")
web_row_key :: proc(r: Sidebar_Row) -> string {
	if r.project != nil do return fmt.tprintf("%d", r.project.id)
	return fmt.tprintf("g%x", hash.fnv64a(transmute([]u8)r.group))
}

// A tree row's section: {id (0 = a group folder), name, path, pin, hidden}.
@(private = "file")
web_view_project_row :: proc(out: ^[dynamic][2]string, r: Sidebar_Row) {
	b := strings.builder_make(context.temp_allocator)
	id: u64
	name, path := r.name, r.group
	if r.project != nil {
		id = r.project.id
		name = project_display(r.project^)
		path = r.project.cwd
	}
	fmt.sbprintf(&b, `{{"id":%d,"name":`, id)
	json_quote(&b, name)
	strings.write_string(&b, `,"path":`)
	json_quote(&b, path)
	fmt.sbprintf(&b, `,"pin":%d,"hidden":%v}}`, r.pin, r.hidden)
	put(out, strings.concatenate({"webp:", web_row_key(r)}, context.temp_allocator), &b)
}

// A session list's rows, one section each, every one whatever the filter; and the order of
// the ones that pass (the ids) in one more.
@(private = "file")
web_view_session_rows :: proc(out: ^[dynamic][2]string, section: Sort_Section, list: []Session, pid: u64, order_name, prefix: string) {
	for &s in sessions_with_new(section, list, pid) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"label":`)
		json_quote(&b, session_label(s, section == .Chats))
		fmt.sbprintf(&b, `,"open":%d,"pin":%d,"hidden":%v,"dot":"%s","claude":%v,"codex":%v,"modified":%d}}`, open_session_any(s.id), session_pinned(s.id), session_hidden(s.id), ROW_STATUS_NAMES[session_status(s.id)], s.claude, s.codex, s.modified._nsec)
		put(out, strings.concatenate({prefix, s.id}, context.temp_allocator), &b)
	}
	o := strings.builder_make(context.temp_allocator)
	strings.write_byte(&o, '[')
	for r, i in sidebar_sessions_of(section, list, pid) {
		if i > 0 do strings.write_byte(&o, ',')
		json_quote(&o, r.session.id)
	}
	strings.write_byte(&o, ']')
	put(out, order_name, &o)
}

// When an open session last changed, as its row's age says it (open_session_age, without a
// disk read): Unix ns, 0 = "new" (or another machine's: not known here).
@(private = "file")
web_view_stamp :: proc(s: ^Open_Session) -> i64 {
	if s.machine != 0 do return 0
	if s.agent == .Claude {
		if r, _ := claude_record(s.pi_session_id); r != nil do return time.to_unix_nanoseconds(time.unix(r.used, 0))
		return 0
	}
	if s.session_file == "" do return 0
	return s.mtime._nsec
}

@(private = "file")
web_view_attention :: proc(b: ^strings.Builder, rows: []Attention_Row) {
	strings.write_byte(b, '[')
	for r, i in rows {
		if i > 0 do strings.write_byte(b, ',')
		tab: u64
		if r.tier != NEED_NONE do if t := session_need_tab(r.session, r.tier); t != nil do tab = t.id
		fmt.sbprintf(b, `{{"session":%d,"group":"%s","tab":%d}}`, r.session.id, ATTENTION_GROUP_NAMES[r.group], tab)
	}
	strings.write_byte(b, ']')
}

// The "projects" section as a browser gets it (state_sections, a web link): what the page reads of
// each project (id, machine, group, name, cwd, label; missing, temp, repo and parent when set), not
// the window's whole Project (its session folder, times and tidy fields): 190 KB -> about 45 KB at
// 420 projects, on every load and reconnect. Same section name and shape.
web_projects_json :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"projects":[`)
	for &p, i in state.projects {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"id":%d,"machine":%d,"group":`, p.id, p.machine)
		wire_write(&b, &p.group, type_info_of(Sidebar_Group))
		strings.write_string(&b, `,"name":`)
		json_quote(&b, p.name)
		strings.write_string(&b, `,"cwd":`)
		json_quote(&b, p.cwd)
		strings.write_string(&b, `,"label":`)
		json_quote(&b, p.label)
		if p.missing do strings.write_string(&b, `,"missing":true`)
		if p.temp do strings.write_string(&b, `,"temp":true`)
		if p.repo do strings.write_string(&b, `,"repo":true`)
		if p.parent != 0 do fmt.sbprintf(&b, `,"parent":%d`, p.parent)
		strings.write_byte(&b, '}')
	}
	fmt.sbprintf(&b, `],"selected_project":%d}}`, state.selected_project)
	return strings.to_string(b)
}

// A browser's new session (its picker, web/src/app/harness.ts): that harness goes first in the
// picker next time, as the native picker's harness_used does (a browser sends no window.command).
// Only a browser's own (the user's): never an agent's or a hub's.
web_note_harness :: proc(cmd: Command, caller: Caller) {
	if !caller.web || caller.kind != .UI do return
	if h, ok := harness_of(cmd); ok do run_command(Set_Last_Harness{harness = h}, {kind = .Internal})
}
