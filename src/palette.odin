package main

// Command palette (⌘K): one text field over everything, fuzzy search over
// actions (actions.odin), open tabs, sessions and projects. Open while
// State.focus_widget is "palette" (Set_Focus opens and closes it, like any
// widget); the query, selection and recents are UI state, kept here.
//
// Running an item submits the same command a click would, through the inbox
// as the user (ui_do): confirmations and permissions apply unchanged.
//
// Sessions: the selected project's listed sessions plus every open session
// (other projects' stored sessions are not scanned; that would read
// thousands of files).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Palette_Kind :: enum {
	Action,
	Tab,
	Session,
	Project,
	File, // ⌘P: a file of the current project (editor_finder.odin)
	App, // "New app tab…": a command line or an apps.json entry (app_tab.odin)
}

PALETTE_KIND_NAMES := [Palette_Kind]string {
	.Action  = "Action",
	.Tab     = "Tab",
	.Session = "Session",
	.Project = "Project",
	.File    = "File",
	.App     = "App",
}

Palette_Item :: struct {
	kind:    Palette_Kind,
	key:     string, // stable identity (recents): "action:new_chat", "tab:12", ...
	title:   string,
	detail:  string, // project, session, current value (muted)
	hint:    string, // shortcut
	action:  int, // ACTIONS index
	id:      u64, // tab, open session or project id
	project: u64, // sessions: the project
	session: string, // listed sessions: pi session id
	score:   int,
	order:   int, // position before ranking (stable ties)
	matched: u64, // title runes that matched (bit i = rune i, first 64)
	path:    string, // files: absolute path
	chat:    bool, // a session in Chats (a bubble), not in a project (a folder)
}

Palette :: struct {
	field:    Text_Field,
	selected: int,
	first:    int, // first visible row
	recent:   [dynamic]string, // item keys, most recent first (owned)
	was_open: bool,
	pick_for: int, // ACTIONS index + 1 whose folder picker runs next (palette_run_deferred; 0 = none)
	pick_menu: string, // the context menu row that asked for it (owned; "" = not a menu): its outcome is shown
	files:    bool, // file mode (⌘P): only the current project's files
	apps:     bool, // app mode ("New app tab…"): the query is a command line to run in an app tab
}

palette: Palette

palette_is_open :: proc() -> bool {return state.focus_widget == "palette"}

// A fresh palette: empty query, best match selected. ⌘K calls it before
// opening (keys may follow before the next frame); the layout calls
// palette_sync for any other opener (set_focus from a script).
palette_reset :: proc() {
	tf_set(&palette.field, "")
	palette.selected, palette.first = 0, 0
	palette.files = false
	palette.apps = false
	palette.was_open = true
}

palette_sync :: proc() {
	open := palette_is_open()
	if open && !palette.was_open do palette_reset()
	palette.was_open = open
}

// All items, before matching (temp allocator).
palette_items :: proc() -> [dynamic]Palette_Item {
	items := make([dynamic]Palette_Item, context.temp_allocator)
	for &a, i in ACTIONS {
		if a.no_palette do continue
		if _, ok := a.make(); !ok do continue
		it := Palette_Item{kind = .Action, key = fmt.tprintf("action:%s", a.id), title = a.title != nil ? a.title() : a.label, hint = a.keys, action = i}
		if a.detail != nil do it.detail = a.detail()
		append(&items, it)
	}
	cs := cur()
	for &s in state.open_sessions {
		if s.home do continue // the agent has its own actions
		stitle := open_session_title(&s)
		for tab in s.tabs {
			detail := stitle
			if cs != nil && s.id == cs.id do detail = fmt.tprintf("%s · current session", stitle)
			append(&items, Palette_Item{kind = .Tab, key = fmt.tprintf("tab:%d", tab.id), title = tab.title, detail = detail, id = tab.id})
		}
	}
	sel := find_project(state.selected_project)
	listed := make(map[string]bool, context.temp_allocator)
	if sel != nil {
		pname := project_display(sel^)
		for s in state.sessions {
			listed[s.id] = true
			append(&items, Palette_Item{kind = .Session, key = fmt.tprintf("session:%s", s.id), title = session_label(s), detail = pname, project = sel.id, session = s.id})
		}
	}
	if c := chats_project(); c != nil {
		for s in state.chats {
			listed[s.id] = true
			append(&items, Palette_Item{kind = .Session, key = fmt.tprintf("session:%s", s.id), title = session_label(s, true), project = c.id, session = s.id, chat = true})
		}
	}
	for &s in state.open_sessions {
		if s.home || listed[s.pi_session_id] do continue
		ic, place := session_place(&s)
		chat := ic == .Chat
		append(&items, Palette_Item{kind = .Session, key = fmt.tprintf("session:%s", s.pi_session_id), title = open_session_title(&s), detail = chat ? "" : place, id = s.id, chat = chat})
	}
	for p in state.projects {
		if p.group != .Projects do continue // Chats is no project to select
		append(&items, Palette_Item{kind = .Project, key = fmt.tprintf("project:%s", p.cwd), title = project_name(p), detail = p.name != "" ? p.label : "", id = p.id})
	}
	for &it, i in items do it.order = i
	return items
}

// A title for an open session, in any project: its listed title (the
// selected project's), else read from its session file (cached until the
// file grows); "Untitled session · <created>" (a project's) or "Untitled
// chat · …" while the file has no title, plain while there is no file yet.
open_session_title :: proc(s: ^Open_Session) -> string {
	untitled := open_session_is_chat(s) ? "Untitled chat" : "Untitled session"
	for l in state.sessions do if l.id == s.pi_session_id do return session_label(l)
	if s.session_file == "" do return untitled
	open_session_refresh(s) // at most once a second (sidebar.odin)
	// a copy for this frame: a later call may replace the cached one while
	// earlier palette items still point at it
	if s.title != "" do return strings.clone(s.title, context.temp_allocator)
	// a file without a title yet: when it was created, from its name
	if s.mtime != {} {
		context.allocator = context.temp_allocator
		base := filepath.base(s.session_file)
		if when_ := name_time(base); when_ != base do return untitled_label(open_session_is_chat(s), when_)
	}
	return untitled
}

// Fuzzy match of one query word in text (case-insensitive subsequence).
// Higher is better: whole-text prefix, word starts and runs of consecutive
// characters score more. matched marks the text runes used (first 64).
fuzzy_score :: proc(word, text: string) -> (score: int, matched: u64, ok: bool) {
	if word == "" do return 0, 0, true
	lw := strings.to_lower(word, context.temp_allocator)
	lt := strings.to_lower(text, context.temp_allocator)
	// a substring wins over a scattered match: prefer it, at a word start
	if at := strings.index(lt, lw); at >= 0 {
		best := at
		for i := at; i >= 0 && i < len(lt); {
			if word_start(lt, i) {
				best = i
				break
			}
			next := strings.index(lt[i + 1:], lw)
			if next < 0 do break
			i += 1 + next
		}
		ri := strings.rune_count(lt[:best])
		n := strings.rune_count(lw)
		for k in ri ..< min(ri + n, 64) do matched |= 1 << u64(k)
		score = 10 * n + (best == 0 ? 30 : 0) + (word_start(lt, best) ? 15 : 0)
		return score, matched, true
	}
	qi := 0
	q := utf8.string_to_runes(lw, context.temp_allocator)
	prev := -2
	ri := 0
	for r, off in lt {
		defer ri += 1
		if qi == len(q) do break
		if r != q[qi] do continue
		s := 1
		if word_start(lt, off) do s += 6
		if ri == prev + 1 do s += 4
		score += s
		if ri < 64 do matched |= 1 << u64(ri)
		prev = ri
		qi += 1
	}
	if qi < len(q) do return 0, 0, false
	return score, matched, true
}

@(private = "file")
word_start :: proc(s: string, off: int) -> bool {
	if off == 0 do return true
	r, _ := utf8.decode_last_rune(s[:off])
	c, _ := utf8.decode_rune(s[off:])
	if !is_word_rune(r) do return true
	return unicode.is_lower(r) && unicode.is_upper(c)
}

// Items matching query, best first; ties: recent first, then kind and order.
// Every word of the query must match the title or the detail. Empty query:
// recent items first, then everything in order.
palette_search :: proc(query: string) -> []Palette_Item {
	items := palette_items()
	out := make([dynamic]Palette_Item, 0, len(items), context.temp_allocator)
	words := strings.fields(query, context.temp_allocator)
	for &it in items {
		total := 0
		ok := true
		for w in words {
			s, m, hit := fuzzy_score(w, it.title)
			if hit {
				total += s
				it.matched |= m
				continue
			}
			s, _, hit = fuzzy_score(w, it.detail)
			if !hit {
				ok = false
				break
			}
			total += s / 2
		}
		if !ok do continue
		it.score = total
		append(&out, it)
	}
	recent_rank :: proc(key: string) -> int {
		for k, i in palette.recent do if k == key do return i
		return PALETTE_RECENT_MAX
	}
	less :: proc(a, b: Palette_Item) -> bool {
		if a.score != b.score do return a.score > b.score
		ra, rb := recent_rank(a.key), recent_rank(b.key)
		if ra != rb do return ra < rb
		if a.kind != b.kind do return a.kind < b.kind
		return a.order < b.order
	}
	// insertion sort: stable, small lists
	for i in 1 ..< len(out) {
		x := out[i]
		j := i
		for j > 0 && less(x, out[j - 1]) {
			out[j] = out[j - 1]
			j -= 1
		}
		out[j] = x
	}
	if len(out) > PALETTE_RESULTS_MAX do resize(&out, PALETTE_RESULTS_MAX)
	return out[:]
}

palette_results :: proc() -> []Palette_Item {
	if palette.files do return file_finder_results(tf_text(&palette.field))
	if palette.apps do return app_palette_results(tf_text(&palette.field))
	return palette_search(tf_text(&palette.field))
}

// Moves the selection by d rows (clamped) and keeps it visible.
palette_move :: proc(d: int) {
	n := len(palette_results())
	palette.selected = clamp(palette.selected + d, 0, max(n - 1, 0))
	palette_keep_visible()
}

palette_keep_visible :: proc() {
	if palette.selected < palette.first do palette.first = palette.selected
	if palette.selected >= palette.first + PALETTE_ROWS do palette.first = palette.selected - PALETTE_ROWS + 1
}

// The query changed: back to the best match.
palette_edited :: proc() {
	palette.selected, palette.first = 0, 0
}

// Runs result i: closes the palette, then submits the item's command as the
// user (same path as a click).
palette_run_index :: proc(i: int) {
	rs := palette_results()
	if i < 0 || i >= len(rs) do return
	palette_run(rs[i])
}

palette_run :: proc(it: Palette_Item) {
	palette_remember(it.key)
	ui_do(Set_Focus{""})
	switch it.kind {
	case .Action:
		a := &ACTIONS[it.action]
		if a.pick_folder {
			// the picker is a modal loop: not inside this key/click handler
			palette.pick_for = it.action + 1
			delete(palette.pick_menu)
			palette.pick_menu = "" // the palette's own: no menu toast
			if platform.run_later != nil do platform.run_later(palette_run_deferred)
			return
		}
		run_action(a)
	case .Tab:
		ui_do(Focus_Tab{it.id})
	case .Session:
		if it.session != "" do ui_do(Open_Session_Cmd{it.project, it.session})
		else do ui_do(Focus_Session{it.id})
	case .Project:
		ui_do(Select_Project{it.id})
	case .File:
		ui_do(Open_File{path = it.path})
	case .App:
		cs := cur()
		if cs == nil do return
		// path: a command line; argv (detail's entry): an apps.json app
		for e in app_entries(cs.cwd) do if e.name == it.title && it.path == "" {
			ui_do(New_App_Tab{session = cs.id, argv = e.argv, cwd = e.cwd, title = e.name})
			return
		}
		if it.path != "" do ui_do(New_App_Tab{session = cs.id, command = it.path})
	}
}

palette_remember :: proc(key: string) {
	for k, i in palette.recent do if k == key {
		delete(k)
		ordered_remove(&palette.recent, i)
		break
	}
	inject_at(&palette.recent, 0, strings.clone(key))
	if len(palette.recent) > PALETTE_RECENT_MAX {
		delete(palette.recent[len(palette.recent) - 1])
		pop(&palette.recent)
	}
}

// The folder picker of an action like "Add project…", run outside every
// input handler and frame: it is a modal loop, and sokol keeps calling
// frame() inside it (the display link runs in the modal run loop mode).
// platform.run_later schedules it on the main queue; tests call it directly.
palette_run_deferred :: proc() {
	if palette.pick_for == 0 do return
	a := &ACTIONS[palette.pick_for - 1]
	palette.pick_for = 0
	menu := palette.pick_menu
	palette.pick_menu = ""
	defer delete(menu)
	if platform.pick_folder == nil do return
	action_folder = strings.clone(platform.pick_folder()) // heap: frames ran during the modal loop
	defer {
		delete(action_folder)
		action_folder = ""
	}
	if action_folder != "" do run_action(a, menu)
}

// menu: the context menu row's label that ran it (its outcome is shown, menu_result).
run_action :: proc(a: ^Action, menu := "") {
	cmd, ok := a.make()
	if !ok {
		// a menu row that cannot run now: say so (the palette and menu bar grey these instead)
		if menu != "" do toast_show(fmt.tprintf("%s: not available now", strings.trim_suffix(menu, "…")), err = true)
		return
	}
	if a.prepare != nil do a.prepare()
	if menu != "" do ui_do_menu(cmd, menu)
	else do ui_do(cmd)
}
