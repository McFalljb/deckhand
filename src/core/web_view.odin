package core

// The views a browser draws, computed here (#148): the state stream's "web" section, sent only to a
// web link (state_sections). The native window computes the same from its replica with these very
// procs (sidebar.odin, needing_you.odin); a browser has no replica in Odin, so the core sends their
// results and the page never re-implements the left column's tree, filter, sort or the Attention
// order. Ids only, plus the few strings the procs derive (labels, ages); everything else the page
// reads from the other sections.
//
//   fleet      {waiting, errors, unseen, working}: the top bar's pill
//   next       the open session next_needing_you goes to (0: none)
//   open       this machine's Open group: open session ids in order
//   projects   this machine's project tree: [{id | group, name, depth, kids, open, forced, pin,
//              hidden, path, divider}] (a group row has id 0 and its folder in path)
//   sessions   the selected project's session rows; chats: the Chats rows:
//              [{id (pi's), label, open (open session id, 0), pin, hidden, dot, claude, codex}]
//   machines   [{no, open: [ids], projects: [{id, name}]}], each other machine in state.machines
//   attention  [{session, group, tab}]: the Attention view (group: needs_you, finished, working, idle)
//   deck       the same for the Deck's cards
//   titles     {open session id: {title, place, chat, at}}: the rows' words; at: when its file (a
//              Claude session: its history entry) last changed, Unix ns (0: "new")
//
// Computed only when something it reads changed (web_view_cached: a hash of the other sections
// and the open sessions' file stamps), and never reading a disk on a flush: the titles and stamps
// are the ones web_view_tick last read, at most once a second per open session.
//   filtered   waiting sessions the filter hides ("N waiting (filtered)")

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:strings"
import "core:time"

WEB_VIEW_SECTION :: "web"

ATTENTION_GROUP_NAMES := [Attention_Group]string {
	.Needs_You = "needs_you",
	.Finished  = "finished",
	.Working   = "working",
	.Idle      = "idle",
}

// The section's last JSON and what it was computed from (heap); builds counts computations (tests).
@(private)
web_view_last: struct {
	key:    u64,
	json:   string,
	builds: int,
}

// The section for these other sections (state_sections' out so far): the last one when none of
// them, nor an open session's file stamp, changed.
web_view_cached :: proc(sections: [][2]string) -> string {
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
	if web_view_last.builds > 0 && h == web_view_last.key do return web_view_last.json
	j := web_view_json()
	delete(web_view_last.json, runtime.heap_allocator())
	web_view_last.json = strings.clone(j, runtime.heap_allocator())
	web_view_last.key = h
	web_view_last.builds += 1
	return web_view_last.json
}

// While a browser is attached: each open session's file looked at (title, stamp), at most once a
// second (open_session_refresh); a changed stamp is a change to send.
web_view_tick :: proc() {
	if !window_link_web() do return
	for &s in state.open_sessions {
		if s.home do continue
		before := s.mtime
		open_session_refresh(&s)
		if s.mtime != before do window_state_changed()
	}
}

web_view_json :: proc() -> string {
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
	strings.write_string(&b, `],"projects":`)
	rows := sidebar_projects()
	web_view_project_rows(&b, rows, true)
	strings.write_string(&b, `,"sessions":`)
	web_view_session_rows(&b, sidebar_sessions(.Sessions))
	strings.write_string(&b, `,"chats":`)
	web_view_session_rows(&b, sidebar_sessions(.Chats))
	strings.write_string(&b, `,"machines":[`)
	for m, i in state.machines {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"no":%d,"open":[`, m.no)
		for s, k in machine_open_rows(m.no) {
			if k > 0 do strings.write_byte(&b, ',')
			fmt.sbprintf(&b, "%d", s.id)
		}
		strings.write_string(&b, `],"projects":`)
		web_view_project_rows(&b, machine_project_rows(m.no), false)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `],"attention":`)
	web_view_attention(&b, attention_rows())
	strings.write_string(&b, `,"deck":`)
	web_view_attention(&b, attention_rows(deck = true))
	strings.write_string(&b, `,"titles":{`)
	n := 0
	for &s in state.open_sessions {
		if s.home do continue
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		ic, place := session_place(&s)
		fmt.sbprintf(&b, `"%d":{{"title":`, s.id)
		json_quote(&b, open_session_title(&s, refresh = false))
		strings.write_string(&b, `,"place":`)
		json_quote(&b, place)
		fmt.sbprintf(&b, `,"chat":%v,"at":%d}}`, ic == .Chat, web_view_stamp(&s))
	}
	fmt.sbprintf(&b, `}},"filtered":%d}}`, sidebar_waiting_filtered())
	return strings.to_string(b)
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
web_view_project_rows :: proc(b: ^strings.Builder, rows: []Sidebar_Row, local: bool) {
	strings.write_byte(b, '[')
	for r, i in rows {
		if i > 0 do strings.write_byte(b, ',')
		id: u64
		name, path := r.name, r.group
		if r.project != nil {
			id = r.project.id
			name = project_display(r.project^)
			path = r.project.cwd
		}
		fmt.sbprintf(b, `{{"id":%d,"name":`, id)
		json_quote(b, name)
		strings.write_string(b, `,"path":`)
		json_quote(b, path)
		fmt.sbprintf(b, `,"depth":%d,"kids":%d,"open":%v,"forced":%v,"pin":%d,"hidden":%v,"divider":%v}}`, r.depth, r.kids, r.open, r.forced, r.pin, r.hidden, local && pinned_divider_before(rows, i))
	}
	strings.write_byte(b, ']')
}

@(private = "file")
web_view_session_rows :: proc(b: ^strings.Builder, rows: []Sidebar_Row) {
	strings.write_byte(b, '[')
	for r, i in rows {
		if i > 0 do strings.write_byte(b, ',')
		s := r.session
		strings.write_string(b, `{"id":`)
		json_quote(b, s.id)
		strings.write_string(b, `,"label":`)
		json_quote(b, session_label(s^))
		fmt.sbprintf(b, `,"open":%d,"pin":%d,"hidden":%v,"dot":"%s","claude":%v,"codex":%v,"modified":%d}}`, open_session_any(s.id), r.pin, r.hidden, ROW_STATUS_NAMES[session_status(s.id)], s.claude, s.codex, s.modified._nsec)
	}
	strings.write_byte(b, ']')
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
