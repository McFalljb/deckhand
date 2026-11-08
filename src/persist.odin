package main

// The saved workspace (docs/PERSISTENCE.md): <data dir>/workspace.json.
// Written whole and atomically (temp file + rename, 0600) at most once a
// second after State changes, and at quit. Read once at startup and turned
// back into State through ordinary commands (caller internal), so a restore
// shows up in the command log like anything else. Restored sessions start
// lazily: their tabs run only once the session is focused.
//
// Only identities and preferences are saved: never runtime ids, tokens,
// pending confirmations, panel contents, pi status or typed text.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import gh "ghostty"

WORKSPACE_VERSION :: 1
WORKSPACE_FILE :: "workspace.json"
WORKSPACE_MAX :: 4 * 1024 * 1024 // bigger is not ours: treated as corrupt
SAVE_DELAY :: time.Second

Persist :: struct {
	path:          string, // "" = persistence off
	gen:           u64, // bumped by commands that change saved data (persist_on_event)
	saved_gen:     u64, // gen at the last save check
	lookups:       map[string]Lookup, // session-file lookups by session (session_on_disk)
	dirty_since:   time.Tick,
	last_written:  string, // what the file holds: unchanged content is not rewritten
	done:          bool, // the final save ran at quit: no more writes
	focus_tab:     u64, // restored current tab: focused (started) once the pane has a size
	launch:        time.Tick, // main() started (launch-time log)
	laid_out:      bool,
	checks:        int, // save checks (workspace_json runs) and writes, for the log
	writes:        int,
	dir_lists:     int, // session dir listings by the save check (tests)
}

persist: Persist

// Turns persistence on for <dir>/workspace.json.
persist_init :: proc(dir: string) {
	persist.path, _ = filepath.join({dir, WORKSPACE_FILE}, context.allocator)
	persist.saved_gen = persist.gen
}

// Every command event (events.odin): marks the workspace dirty unless the
// command only touched what is never saved. A working pi reports status and
// panels about once a second; those must not cost a save check each.
persist_on_event :: proc(ev: Event) {
	e, ok := ev.(Command_Event)
	if !ok || !e.changed do return
	#partial switch _ in e.command {
	case Browser_Update:
		// the page's address and title are saved; loading and history are not
		// (an empty `what`: a popup's new tab, saved)
		if c := e.command.(Browser_Update); c.what != {} && c.what & {.Url, .Title} == {} do return
	case Pi_Status_Update, Program_Status, Set_Unread, Panel_Set, Panel_Remove, Set_Focus, Set_Files_Filter, Tab_Exited, Cancel_Confirmation, Bridge_Done, Agent_Model_Picker, Notifications_Mark_Read, Notifications_Clear, Notify_Post, Update_Check, Update_Skip, Update_Later, Update_Download, Update_Install, Set_Update_Check, Update_Env, Update_Tick, Update_Checked, Update_Prepared, Jobs_Sync, Jobs_Tick, Job_Run_Done, Job_Mark_Read, Job_Run_Now, Job_Stop, Job_Open, App_Update, App_Restart, App_Input, App_Call, App_Call_Done, App_Screenshot, App_Inspect, Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop, Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel, Claude_Comments, Claude_Prompt, Claude_Wait_Idle, Claude_Wait_Tick, Claude_Held_Op, Claude_Deliver, Claude_Todos, Claude_Task, Claude_Subagent, Claude_Background, Claude_Readonly_Ack:
		return
	}
	persist.gen += 1
}

// ---- saving ----

// Something saved changed since the last save check.
persist_dirty :: proc() -> bool {return persist.gen != persist.saved_gen}

// Called every frame: saves SAVE_DELAY after the first unsaved change.
persist_tick :: proc() {
	if persist.path == "" || persist.done do return
	if !persist_dirty() {
		persist.dirty_since = {}
		return
	}
	now := time.tick_now()
	if persist.dirty_since == {} do persist.dirty_since = now
	if time.tick_diff(persist.dirty_since, now) < SAVE_DELAY do return
	persist_save()
}

// Saves now if the content changed.
persist_save :: proc() {
	if persist.path == "" || persist.done do return
	persist.saved_gen = persist.gen
	persist.dirty_since = {}
	persist.checks += 1
	text := workspace_json()
	if text == persist.last_written do return
	persist.writes += 1
	if err := write_atomic(persist.path, text); err != "" {
		fmt.eprintln("Deckhand: could not save the workspace:", err)
		return
	}
	delete(persist.last_written)
	persist.last_written = strings.clone(text)
}

// At quit, before the tabs' processes are stopped (shell cwds are read from
// the live processes). Later calls do nothing.
persist_quit :: proc() {
	if persist.done do return
	persist_save()
	persist.done = true
	if persist.path != "" && os.get_env("PI_DESK_SCRIPT", context.temp_allocator) != "" do fmt.eprintf("Deckhand: workspace save checks %d, writes %d\n", persist.checks, persist.writes)
}

// Writes `text` to `path` through a temp file in the same dir and a rename,
// so a crash leaves the old file or the new one, never half of one.
write_atomic :: proc(path, text: string) -> string {
	dir := filepath.dir(path)
	if !os.is_dir(dir) do if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil do return fmt.tprint(err)
	tmp := fmt.tprintf("%s.tmp-%d", path, os.get_pid())
	os.remove(tmp)
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil do return fmt.tprint(err)
	_, werr := os.write_string(f, text)
	serr := os.sync(f)
	os.close(f)
	if werr == nil do werr = serr
	if werr == nil do werr = os.rename(tmp, path)
	if werr != nil {
		os.remove(tmp)
		return fmt.tprint(werr)
	}
	return ""
}

// A cached session-file lookup: the file found, or the dir and its
// modification time when nothing was found (listed again once it changes).
Lookup :: struct {
	path:  string,
	dir:   string,
	mtime: time.Time,
}

// Whether the session's file exists now. Sessions opened this run without
// one (a new chat pi has not written yet) are not saved; restored ones always
// are (a gone session may be on a volume that comes back). A found file
// costs a stat afterwards; a missing one a stat of its dir.
@(private = "file")
session_on_disk :: proc(s: Open_Session) -> bool {
	if s.session_file != "" && os.exists(s.session_file) do return true
	p := find_project(s.project_id)
	if p == nil do return false
	key := strings.concatenate({s.pi_session_id, "\x00", s.session_dir, "\x00", p.cwd}, context.temp_allocator)
	l, cached := persist.lookups[key]
	if cached && l.path != "" && os.exists(l.path) do return true
	dir := s.session_dir != "" ? s.session_dir : (p.dir != "" ? p.dir : pi_store_dir(p.cwd))
	mtime, _ := os.modification_time_by_path(dir)
	if cached && l.path == "" && l.dir == dir && l.mtime == mtime do return false
	persist.dir_lists += 1
	path := find_session_file(p^, s.pi_session_id, s.session_dir)
	if cached {
		delete(l.path)
		delete(l.dir)
	} else do key = strings.clone(key)
	persist.lookups[key] = {path = strings.clone(path), dir = strings.clone(dir), mtime = mtime}
	return path != ""
}

// The session holder terminal a tab's process runs in, while the holder keeps it at quit
// (holder_keeps_sessions); 0 = none. Saved as "held", so the next launch adopts it.
tab_held :: proc(tab_id: u64) -> u32 {
	t := term_of(tab_id)
	if t == nil || !t.running || t.pty.held == 0 || !holder_keeps_sessions() do return 0
	return t.pty.held
}

// A saved "held" (1..max u32), else 0. workspace.json is not MAC'd: a same-user edit can only
// map one of the user's held terminals to another of their tabs (tokens are bound by terminal
// in the MAC'd tokens.json, so it hands no token to another program).
held_of :: proc(o: json.Object) -> u32 {
	n, ok := o["held"].(json.Integer)
	if !ok || n <= 0 || i64(n) > i64(max(u32)) do return 0
	return u32(n)
}

// A shell tab's cwd: the live shell's, else where it started.
@(private = "file")
shell_cwd :: proc(s: Open_Session, tab: Tab) -> string {
	if t := term_of(tab.id); t != nil && t.running {
		if cwd := pty_child_cwd(&t.pty); cwd != "" do return cwd
	}
	return tab.cwd != "" ? tab.cwd : s.cwd
}

@(private = "file")
W :: struct {
	b:     strings.Builder,
	first: bool,
}

@(private = "file")
k :: proc(w: ^W, key: string) {
	if !w.first do strings.write_byte(&w.b, ',')
	w.first = false
	json_quote(&w.b, key)
	strings.write_byte(&w.b, ':')
}
@(private = "file")
ks :: proc(w: ^W, key, v: string) {k(w, key); json_quote(&w.b, v)}
@(private = "file")
kb :: proc(w: ^W, key: string, v: bool) {k(w, key); strings.write_string(&w.b, v ? "true" : "false")}
@(private = "file")
ki :: proc(w: ^W, key: string, v: int) {k(w, key); strings.write_int(&w.b, v)}
@(private = "file")
open_obj :: proc(w: ^W) {strings.write_byte(&w.b, '{'); w.first = true}
@(private = "file")
close_obj :: proc(w: ^W) {strings.write_byte(&w.b, '}'); w.first = false}

// A split session's "panes" (docs/PERSISTENCE.md "Panes"): its tree with the ratios (3
// decimals), per saved tab its pane, per pane the saved tab it shows, the focused pane. Panes
// are numbered in leaf order, tabs by their place in the saved list (every tab is written).
@(private = "file")
write_panes :: proc(w: ^W, s: ^Open_Session) {
	order := pane_leaf_order(s)
	index :: proc(order: []u64, id: u64) -> int {
		for x, i in order do if x == id do return i
		return 0
	}
	node :: proc(w: ^W, s: ^Open_Session, order: []u64, n: int) {
		x := s.nodes[n]
		open_obj(w)
		if x.leaf do ki(w, "pane", index(order, x.pane))
		else {
			ks(w, "split", x.dir == .Right ? "right" : "down")
			k(w, "ratio")
			fmt.sbprintf(&w.b, "%.3f", x.ratio)
			k(w, "a")
			node(w, s, order, x.a)
			k(w, "b")
			node(w, s, order, x.b)
		}
		close_obj(w)
	}
	k(w, "panes")
	open_obj(w)
	k(w, "tree")
	node(w, s, order, s.root)
	k(w, "tab_pane")
	strings.write_byte(&w.b, '[')
	for t, j in s.tabs {
		if j > 0 do strings.write_byte(&w.b, ',')
		strings.write_int(&w.b, index(order, t.pane))
	}
	strings.write_byte(&w.b, ']')
	k(w, "active")
	strings.write_byte(&w.b, '[')
	for id, i in order {
		if i > 0 do strings.write_byte(&w.b, ',')
		at := 0
		if p := session_pane(s, id); p != nil do for t, j in s.tabs do if t.id == p.active do at = j
		strings.write_int(&w.b, at)
	}
	strings.write_byte(&w.b, ']')
	f := session_focused_pane(s)
	ki(w, "focused", f != nil ? index(order, f.id) : 0)
	close_obj(w)
}

// The workspace file's content (temp allocator). See docs/PERSISTENCE.md.
workspace_json :: proc() -> string {
	w := W{b = strings.builder_make(context.temp_allocator)}
	open_obj(&w)
	ki(&w, "v", WORKSPACE_VERSION)

	saved := make([dynamic]^Open_Session, context.temp_allocator)
	for &s in state.open_sessions {
		if s.home do continue
		// a Claude-only session once its Claude session id came (claude.session), a pi session once its file is there
		keep := s.agent == .Claude ? s.pi_session_id != "" : s.restored || session_on_disk(s)
		if keep do append(&saved, &s)
	}

	// projects: added by hand, renamed, selected, or holding a saved session
	strings.write_string(&w.b, ",\n")
	w.first = true
	k(&w, "projects")
	strings.write_byte(&w.b, '[')
	n := 0
	for p in state.projects {
		if p.group != .Projects do continue // Chats is always there
		keep := p.dir == "" || p.name != "" || p.by_hand || p.id == state.selected_project
		for s in saved do if s.project_id == p.id do keep = true
		if !keep do continue
		if n > 0 do strings.write_byte(&w.b, ',')
		n += 1
		open_obj(&w)
		ks(&w, "cwd", p.cwd)
		if p.name != "" do ks(&w, "name", p.name)
		if p.by_hand do kb(&w, "added", true) // its own row (project_tidy.odin)
		if p.claude && p.dir == "" do kb(&w, "claude", true) // only Claude ran there: the next Rescan confirms it
		close_obj(&w)
	}
	strings.write_byte(&w.b, ']')
	if p := find_project(state.selected_project); p != nil do ks(&w, "selected_project", p.cwd)

	strings.write_string(&w.b, ",\n")
	w.first = true
	k(&w, "open_sessions")
	strings.write_byte(&w.b, '[')
	current := -1
	for s, i in saved {
		if i > 0 do strings.write_string(&w.b, ",\n")
		if s.id == state.current_session do current = i
		p := find_project(s.project_id)
		open_obj(&w)
		if s.agent == .Claude {
			// a Claude-only session (claude.odin): its main tab's Claude session; pi_session_id ""
			// so that an older pi-desk leaves it out
			ks(&w, "agent", "claude")
			ks(&w, "claude_session_id", s.pi_session_id)
			ks(&w, "pi_session_id", "")
		} else do ks(&w, "pi_session_id", s.pi_session_id)
		ks(&w, "cwd", s.cwd)
		ks(&w, "session_dir", s.session_dir)
		ks(&w, "project", p != nil ? p.cwd : s.cwd)
		if p != nil && p.group == .Chats do kb(&w, "chat", true)
		k(&w, "tabs")
		strings.write_byte(&w.b, '[')
		active := 0
		for tab, j in s.tabs {
			if j > 0 do strings.write_byte(&w.b, ',')
			if tab.id == s.active_tab do active = j
			open_obj(&w)
			ks(&w, "kind", TAB_KIND_NAMES[tab_kind_id(tab.kind)])
			if held := tab_held(tab.id); held != 0 {
				ki(&w, "held", int(held)) // its process runs on in the session holder
				if pt, is_pi := tab.kind.(Pi_Tab); is_pi && pt.readonly do kb(&w, "readonly", true) // as it was started (adopted: kept)
			}
			if _, is_shell := tab.kind.(Shell_Tab); is_shell {
				ks(&w, "title", tab.title)
				ks(&w, "cwd", shell_cwd(s^, tab))
			}
			if et, is_ed := tab.kind.(Editor_Tab); is_ed && et.view == .File do ks(&w, "path", et.path) // diff views are not kept
			if mt, is_md := tab.kind.(Markdown_Tab); is_md do ks(&w, "path", mt.path)
			if ct, is_cl := tab.kind.(Claude_Tab); is_cl {
				// Claude Code (claude.odin): its session (resumed on restore), folder and the user's flags
				if ct.session_id != "" do ks(&w, "claude_session_id", ct.session_id)
				ks(&w, "cwd", tab.cwd != "" ? tab.cwd : s.cwd)
				if ct.readonly do kb(&w, "readonly", true) // pi-desk's read-only profile: kept at every start
				if ct.account != "" do ks(&w, "account", ct.account) // its Claude Code account's folder (claude_accounts.odin)
				if len(ct.args) > 0 {
					k(&w, "args")
					write_strings(&w.b, ct.args)
				}
			}
			if bt, is_web := tab.kind.(Browser_Tab); is_web {
				// its address now and its title (browser_nav.odin); the back/forward list is not kept
				ks(&w, "url", bt.url)
				ks(&w, "title", tab.title)
			}
			close_obj(&w)
		}
		strings.write_byte(&w.b, ']')
		ki(&w, "active_tab", active)
		if len(s.panes) > 1 do write_panes(&w, s) // one pane: no key (the file as before panes)
		close_obj(&w)
	}
	strings.write_byte(&w.b, ']')
	if current >= 0 do ki(&w, "current_session", current)
	// Home: only its pi session id (its dir and cwd are pi-desk's own)
	if hs := home_session(); hs != nil {
		strings.write_string(&w.b, ",\n")
		w.first = true
		k(&w, "home")
		open_obj(&w)
		ks(&w, "pi_session_id", hs.pi_session_id)
		if len(hs.tabs) > 0 { if held := tab_held(hs.tabs[0].id); held != 0 do ki(&w, "held", int(held)) }
		if state.home_model != "" do ks(&w, "model_applied", state.home_model) // the --model of its last start
		if state.home_fork_from != "" do ks(&w, "fork_from", state.home_fork_from) // a fork pi has not written yet (home.odin)
		close_obj(&w)
	}

	strings.write_string(&w.b, ",\n")
	w.first = true
	l := state.layout
	k(&w, "layout")
	open_obj(&w)
	k(&w, "left_width")
	strings.write_int(&w.b, int(l.left_width))
	k(&w, "right_width")
	strings.write_int(&w.b, int(l.right_width))
	kb(&w, "left_open", l.left_open)
	kb(&w, "right_open", l.right_open)
	if l.drawer_width > 0 {
		k(&w, "drawer_width")
		strings.write_int(&w.b, int(l.drawer_width))
	}
	if l.drawer_pinned do kb(&w, "drawer_pinned", true)
	if state.home_open do kb(&w, "drawer_open", true)
	k(&w, "panels")
	write_strings(&w.b, l.panels[:])
	k(&w, "collapsed")
	write_strings(&w.b, l.collapsed[:])
	if l.left_tab != .Sessions do ks(&w, "left_tab", LEFT_TAB_NAMES[l.left_tab])
	close_obj(&w)

	// the Files tab: expanded folders per tree root, most recent first (the
	// filter is not saved); the checkout each project's tree shows
	if len(state.files.expanded) > 0 || len(state.files.checkouts) > 0 {
		strings.write_string(&w.b, ",\n")
		w.first = true
		k(&w, "files")
		open_obj(&w)
		k(&w, "expanded")
		strings.write_byte(&w.b, '[')
		n := 0
		for fr in state.files.expanded {
			if len(fr.dirs) == 0 do continue
			if n > 0 do strings.write_byte(&w.b, ',')
			n += 1
			open_obj(&w)
			ks(&w, "root", fr.root)
			k(&w, "dirs")
			write_strings(&w.b, fr.dirs[:])
			close_obj(&w)
		}
		strings.write_byte(&w.b, ']')
		if len(state.files.checkouts) > 0 {
			k(&w, "checkouts")
			strings.write_byte(&w.b, '[')
			for c, i in state.files.checkouts {
				if i > 0 do strings.write_byte(&w.b, ',')
				open_obj(&w)
				ks(&w, "base", c.base)
				ks(&w, "path", c.path)
				close_obj(&w)
			}
			strings.write_byte(&w.b, ']')
		}
		close_obj(&w)
	}

	// Claude sessions that ran read-only (claude.odin §1a): kept apart from the history's cap
	if len(state.claude_readonly_ids) > 0 {
		strings.write_string(&w.b, ",\n")
		w.first = true
		k(&w, "claude_readonly_ids")
		write_strings(&w.b, state.claude_readonly_ids[:])
	}

	// Claude Code sessions pi-desk ran (claude.odin): Resume in a project's menu
	if len(state.claude_history) > 0 {
		strings.write_string(&w.b, ",\n")
		w.first = true
		k(&w, "claude_sessions")
		strings.write_byte(&w.b, '[')
		for r, i in state.claude_history {
			if i > 0 do strings.write_byte(&w.b, ',')
			open_obj(&w)
			ks(&w, "id", r.id)
			ks(&w, "cwd", r.cwd)
			ks(&w, "project", r.project)
			if r.title != "" do ks(&w, "title", r.title)
			ki(&w, "used", int(r.used))
			if r.readonly do kb(&w, "readonly", true)
			if r.named do kb(&w, "named", true)
			if r.transcript != "" do ks(&w, "transcript", r.transcript)
			if r.model != "" do ks(&w, "model", r.model)
			if r.account != "" do ks(&w, "account", r.account)
			if len(r.args) > 0 {
				k(&w, "args")
				write_strings(&w.b, r.args)
			}
			close_obj(&w)
		}
		strings.write_byte(&w.b, ']')
	}

	// the left column: only what differs from the defaults (the filter is not saved)
	sb := state.sidebar
	strings.write_string(&w.b, ",\n")
	w.first = true
	k(&w, "sidebar")
	open_obj(&w)
	lists := [4]string{"pinned_projects", "pinned_sessions", "hidden_projects", "hidden_sessions"}
	for l, i in ([4][]string{sb.pinned_projects[:], sb.pinned_sessions[:], sb.hidden_projects[:], sb.hidden_sessions[:]}) {
		keep := l
		if i % 2 == 0 { 	// projects whose folder is gone are not saved
			live := make([dynamic]string, context.temp_allocator)
			for x in l do if os.exists(x) do append(&live, x)
			keep = live[:]
		}
		if len(keep) == 0 do continue
		k(&w, lists[i])
		write_strings(&w.b, keep)
	}
	sorted := false
	for sec in Sort_Section do if sb.sort[sec] != .Recent do sorted = true
	if sorted {
		k(&w, "sort")
		open_obj(&w)
		for sec in Sort_Section do if sb.sort[sec] != .Recent do ks(&w, SORT_SECTION_NAMES[sec], SORT_BY_NAMES[sb.sort[sec]])
		close_obj(&w)
	}
	folded := false
	for f in Sidebar_Fold do if sb.folded[f] do folded = true
	if folded {
		k(&w, "folded")
		open_obj(&w)
		for f in Sidebar_Fold do if sb.folded[f] do kb(&w, FOLD_NAMES[f], true)
		close_obj(&w)
	}
	if sb.show_hidden do kb(&w, "show_hidden", true)
	if len(sb.expanded) > 0 {
		k(&w, "expanded")
		strings.write_byte(&w.b, '[')
		for x, i in sb.expanded {
			if i > 0 do strings.write_byte(&w.b, ',')
			json_quote(&w.b, x)
		}
		strings.write_byte(&w.b, ']')
	}
	close_obj(&w)

	// settings: only values that differ from the defaults
	strings.write_string(&w.b, ",\n")
	w.first = true
	st := state.settings
	k(&w, "settings")
	open_obj(&w)
	k(&w, "confirm")
	open_obj(&w)
	for ck in Caller_Kind {
		if ck == .UI || ck == .Internal do continue
		set := false
		for cl in Command_Class do if st.confirm[ck][cl] != .Ask do set = true
		if !set do continue
		k(&w, CALLER_NAMES[ck])
		open_obj(&w)
		for cl in Command_Class do if st.confirm[ck][cl] != .Ask do ks(&w, CLASS_NAMES[cl], MODE_NAMES[st.confirm[ck][cl]])
		close_obj(&w)
	}
	close_obj(&w)
	k(&w, "confirm_close")
	open_obj(&w)
	for tk in Tab_Kind_Id do if st.confirm_close[tk] != .Auto do ks(&w, TAB_KIND_NAMES[tk], CLOSE_NAMES[st.confirm_close[tk]])
	close_obj(&w)
	if st.theme != Theme_Id(0) do ks(&w, "theme", THEME_NAMES[st.theme])
	if st.reduce_motion do kb(&w, "reduce_motion", true)
	if st.term_text_pt != 0 do ki(&w, "terminal_text_size", st.term_text_pt)
	if st.appearance != .System do ks(&w, "appearance", APPEARANCE_NAMES[st.appearance])
	if st.text_size != .Default do ks(&w, "text_size", TEXT_SIZE_NAMES[st.text_size])
	if st.chats_readonly do kb(&w, "chats_readonly", true)
	if st.claude_skip_permissions do kb(&w, "claude_skip_permissions", true)
	if len(st.pi_extensions) > 0 {
		k(&w, "pi_extensions")
		open_obj(&w)
		for e in st.pi_extensions do kb(&w, e.name, e.on)
		close_obj(&w)
	}
	if st.agent_name != "" do ks(&w, "agent_name", st.agent_name)
	if st.agent_model != "" do ks(&w, "agent_model", st.agent_model)
	if st.notify_off do kb(&w, "notify", false)
	if st.tidy_off do kb(&w, "tidy_projects", false)
	if st.keep_sessions do kb(&w, "keep_sessions", true)
	if st.last_harness != .Pi do ks(&w, "last_harness", HARNESS_KEYS[st.last_harness]) // the picker's first row (harness.odin)
	if st.bell_off != {} || st.bell_os_off {
		k(&w, "bell")
		open_obj(&w)
		for g in Bell_Group do if g in st.bell_off do kb(&w, BELL_GROUP_NAMES[g], false)
		if st.bell_os_off do kb(&w, "os", false)
		close_obj(&w)
	}
	// Claude Code accounts (claude_accounts.odin): what the user changed, and the last used
	if len(st.claude_accounts) > 0 {
		k(&w, "claude_accounts")
		strings.write_byte(&w.b, '[')
		for a, i in st.claude_accounts {
			if i > 0 do strings.write_byte(&w.b, ',')
			open_obj(&w)
			ks(&w, "dir", a.dir)
			if a.label != "" do ks(&w, "label", a.label)
			if a.added do kb(&w, "added", true)
			if a.removed do kb(&w, "removed", true)
			close_obj(&w)
		}
		strings.write_byte(&w.b, ']')
	}
	if st.claude_account_last != "" do ks(&w, "claude_account_last", st.claude_account_last)
	if st.claude_account_default != "" do ks(&w, "claude_account_default", st.claude_account_default)
	if st.home_dir != "" do ks(&w, "home_dir", st.home_dir)
	if st.folders != {} {
		k(&w, "folders")
		open_obj(&w)
		for f in Folder_Kind do if st.folders[f] != "" do ks(&w, FOLDER_NAMES[f], st.folders[f])
		close_obj(&w)
	}
	if st.setup_seen do kb(&w, "setup_seen", true)
	if st.pi_path != "" do ks(&w, "pi_path", st.pi_path)
	if st.jobs_path != "" do ks(&w, "jobs_path", st.jobs_path)
	if st.jobs_paused do kb(&w, "jobs_paused", true)
	if l := st.job_limits; l != {} {
		k(&w, "job_limits")
		fmt.sbprintf(&w.b, `{{"max_cost":%v,"timeout":%d,"max_turns":%d,"day":%v,"week":%v,"month":%v,"concurrency":%d,"loop_calls":%d,"stall":%d,"fail_pause":%d}}`, l.max_cost, l.timeout, l.max_turns, l.day, l.week, l.month, l.concurrency, l.loop_calls, l.stall, l.fail_pause)
	}
	close_obj(&w)
	close_obj(&w)
	strings.write_byte(&w.b, '\n')
	return strings.to_string(w.b)
}

// ---- loading ----

// Startup: reads the saved workspace and restores it. A file that cannot be
// read as a workspace (corrupt, too big, another version) is moved aside to
// workspace.json.bad-<unix time> and the app starts empty. fresh (--fresh):
// no restore; an existing file is moved aside to .bak-<unix time>.
persist_load :: proc(fresh := false) {
	if persist.path == "" do return
	if !os.exists(persist.path) do return
	if fresh {
		move_aside("bak")
		return
	}
	start := time.tick_now()
	fi, serr := os.stat(persist.path, context.temp_allocator)
	if serr != nil {
		fmt.eprintln("Deckhand: could not read the saved workspace:", serr)
		return
	}
	if fi.type != .Regular || fi.size > WORKSPACE_MAX {
		fmt.eprintln("Deckhand: saved workspace not restored:", fi.type != .Regular ? "not a regular file" : "file too big")
		move_aside("bad")
		return
	}
	data, err := os.read_entire_file(persist.path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("Deckhand: could not read the saved workspace:", err)
		return
	}
	if rerr := workspace_restore(string(data)); rerr != "" {
		fmt.eprintln("Deckhand: saved workspace not restored:", rerr)
		move_aside("bad")
		return
	}
	persist.last_written = strings.clone(string(data))
	fmt.eprintf("Deckhand: workspace restored (%d projects, %d sessions) in %.1f ms\n", len(state.projects), len(state.open_sessions), time.duration_milliseconds(time.tick_since(start)))
}

@(private = "file")
move_aside :: proc(tag: string) {
	to := fmt.tprintf("%s.%s-%d", persist.path, tag, time.time_to_unix(time.now()))
	if err := os.rename(persist.path, to); err != nil do fmt.eprintln("Deckhand: could not move", persist.path, "aside:", err)
	else do fmt.eprintln("Deckhand: kept the old workspace as", to)
}

// Restores State from a workspace file's text through commands. Returns an
// error, before changing anything, if the file is not a workspace of this
// version; entries that no longer fit (a removed project dir, a deleted
// session) are restored marked missing or skipped, never fatal.
workspace_restore :: proc(text: string) -> string {
	if len(text) > WORKSPACE_MAX do return "file too big"
	if !json_depth_ok(text) do return "JSON nested too deeply"
	v, jerr := json.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return "invalid JSON"
	root, ok := v.(json.Object)
	if !ok do return "not a JSON object"
	ver, has_v := root["v"].(json.Integer)
	if !has_v do return "no version"
	if ver != WORKSPACE_VERSION do return fmt.tprintf("unknown version %d (Deckhand reads %d)", ver, WORKSPACE_VERSION)

	run :: proc(c: Command) -> Result {return run_command(c, {kind = .Internal})}

	// settings first: the look applies before anything is drawn
	if st, is := root["settings"].(json.Object); is {
		if cf, cok := st["confirm"].(json.Object); cok {
			for ck in Caller_Kind {
				if ck == .UI || ck == .Internal do continue
				ko, kok := cf[CALLER_NAMES[ck]].(json.Object)
				if !kok do continue
				for cl in Command_Class {
					if m, mok := enum_of(ko, CLASS_NAMES[cl], MODE_NAMES); mok do run(Set_Confirm_Policy{caller = ck, class = cl, mode = m})
				}
			}
		}
		if cc, cok := st["confirm_close"].(json.Object); cok {
			for tk in Tab_Kind_Id do if r, rok := enum_of(cc, TAB_KIND_NAMES[tk], CLOSE_NAMES); rok do run(Set_Close_Confirm{tab_kind = tk, rule = r})
		}
		if th, tok := enum_of(st, "theme", THEME_NAMES); tok do run(Set_Theme{name = th})
		if rm, rok := st["reduce_motion"].(json.Boolean); rok do run(Set_Reduce_Motion{on = bool(rm)})
		if pt, pok := num_of(st, "terminal_text_size"); pok do run(Set_Terminal_Text_Size{pt = int(pt)})
		if ap, aok := enum_of(st, "appearance", APPEARANCE_NAMES); aok do run(Set_Appearance{mode = ap})
		if ts, tok := enum_of(st, "text_size", TEXT_SIZE_NAMES); tok do run(Set_Text_Size{size = ts})
		if ro, rok := st["chats_readonly"].(json.Boolean); rok do run(Set_Chats_Readonly{on = bool(ro)})
		if sp, sok := st["claude_skip_permissions"].(json.Boolean); sok do run(Set_Claude_Default_Flags{skip_permissions = bool(sp)})
		if pe, pok := st["pi_extensions"].(json.Object); pok {
			names := make([dynamic]string, context.temp_allocator)
			for n in pe do append(&names, n)
			slice.sort(names[:]) // the saved order is not kept by the parsed object
			for n in names do if on, ok := pe[n].(json.Boolean); ok do run(Set_Pi_Extension{name = n, on = bool(on)})
		}
		if an, aok := st["agent_name"].(json.String); aok do run(Set_Agent_Name{name = an})
		if am, aok := st["agent_model"].(json.String); aok do run(Set_Agent_Model{model = am})
		if no, nok := st["notify"].(json.Boolean); nok do run(Set_Notify{on = bool(no)})
		if tp, tok := st["tidy_projects"].(json.Boolean); tok do run(Set_Tidy_Projects{on = bool(tp)})
		if ks, kok := st["keep_sessions"].(json.Boolean); kok do run(Set_Keep_Sessions{on = bool(ks)})
		claude_accounts_restore(st) // claude_accounts.odin
		if lh, lok := enum_of(st, "last_harness", HARNESS_KEYS); lok do state.settings.last_harness = lh // harness.odin
		if bo, bok := st["bell"].(json.Object); bok {
			on :: proc(o: json.Object, k: string) -> Maybe(bool) {
				if v, ok := o[k].(json.Boolean); ok do return bool(v)
				return nil
			}
			run(Set_Bell{finished = on(bo, "finished"), waiting = on(bo, "waiting"), errors = on(bo, "errors"), jobs = on(bo, "jobs"), os = on(bo, "os")})
		}
		// the folders (folders.odin): overrides, then the main folder. Older
		// files: notes_dir becomes the main folder, and chats keep running
		// where they did (chats_dir, else ~/Chats) unless that is <main>/chats
		if fo, fok := st["folders"].(json.Object); fok {
			for f in Folder_Kind do if p, pok := fo[FOLDER_NAMES[f]].(json.String); pok && strings.has_prefix(p, "/") do run(Set_Folder{kind = f, path = p})
		}
		hd, has_home := st["home_dir"].(json.String)
		nd, has_notes := st["notes_dir"].(json.String)
		cd, has_chats := st["chats_dir"].(json.String)
		if !has_home && has_notes && nd != "" {
			hd, has_home = nd, true
			if !has_chats || !strings.has_prefix(cd, "/") do cd, has_chats = json.String(fmt.tprintf("%s/Chats", os.get_env("HOME", context.temp_allocator))), true
		}
		if has_chats && strings.has_prefix(cd, "/") && state.settings.folders[.Chats] == "" {
			path := string(cd)
			if has_home && path == fmt.tprintf("%s/chats", strings.trim_right(string(hd), "/")) do path = ""
			if path != "" do run(Set_Folder{kind = .Chats, path = path})
		}
		if has_home && hd != "" do run(Set_Home_Dir{path = string(hd)})
		if ss, sok := st["setup_seen"].(json.Boolean); sok && bool(ss) do state.settings.setup_seen = true
		if pp, pok := st["pi_path"].(json.String); pok do run(Set_Pi_Path{path = pp})
		if jp, jok := st["jobs_path"].(json.String); jok do run(Jobs_Env{path = jp})
		if jp, jok := st["jobs_paused"].(json.Boolean); jok && bool(jp) do run(Jobs_Pause{})
		if lo, lok := st["job_limits"].(json.Object); lok {
			f :: proc(o: json.Object, k: string) -> Maybe(f64) {
				#partial switch n in o[k] {
				case json.Float:   return f64(n)
				case json.Integer: return f64(n)
				}
				return nil
			}
			i :: proc(o: json.Object, k: string) -> Maybe(i64) {if v, ok := f(o, k).?; ok && v > 0 do return i64(v); return nil}
			n :: proc(o: json.Object, k: string) -> Maybe(int) {if v, ok := f(o, k).?; ok && v > 0 do return int(v); return nil}
			run(Set_Job_Limits{max_cost = f(lo, "max_cost"), day = f(lo, "day"), week = f(lo, "week"), month = f(lo, "month"), timeout = i(lo, "timeout"), stall = i(lo, "stall"), max_turns = n(lo, "max_turns"), concurrency = n(lo, "concurrency"), loop_calls = n(lo, "loop_calls"), fail_pause = n(lo, "fail_pause")})
		}
	}

	// projects: hand-added ones go back on top in their saved order; names
	projects, _ := root["projects"].(json.Array)
	#reverse for pv in projects {
		po, _ := pv.(json.Object)
		cwd, _ := po["cwd"].(json.String)
		if !strings.has_prefix(cwd, "/") do continue
		p := ensure_project(cwd)
		name, _ := po["name"].(json.String)
		if p != nil && name != "" && name != p.name do run(Rename_Project{project_id = p.id, name = name})
		if p == nil do continue
		added, _ := po["added"].(json.Boolean)
		p.by_hand = bool(added)
		if claude, _ := po["claude"].(json.Boolean); claude && p.dir == "" do p.claude = true
	}
	projects_tidy() // hand-added ones keep their rows

	// open sessions, not started; the current one starts once the window
	// has a size (persist_after_layout)
	sessions, _ := root["open_sessions"].(json.Array)
	current, _ := root["current_session"].(json.Integer)
	has_current := "current_session" in root
	for sv, i in sessions {
		so, _ := sv.(json.Object)
		id, _ := so["pi_session_id"].(json.String)
		pcwd, _ := so["project"].(json.String)
		if pcwd == "" do pcwd, _ = so["cwd"].(json.String)
		// a Claude-only session (claude.odin): known by its Claude session id (a Claude chat too)
		agent, _ := so["agent"].(json.String)
		claude := agent == "claude"
		if claude do id, _ = so["claude_session_id"].(json.String)
		if id == "" || !strings.has_prefix(pcwd, "/") do continue
		// a chat goes back into Chats while chats still run in its folder;
		// from an earlier Chats folder it belongs to that folder's project
		chat, _ := so["chat"].(json.Boolean)
		p: ^Project
		if c := chats_project(); chat && c != nil && c.cwd == pcwd do p = c
		else do p = ensure_project(pcwd)
		if p == nil do continue
		dir, _ := so["session_dir"].(json.String)
		tabs := make([dynamic]Restore_Tab, context.temp_allocator)
		want_active, _ := so["active_tab"].(json.Integer)
		saved_tabs, _ := so["tabs"].(json.Array)
		// the saved panes: by the saved tab's place, before dropped tabs shift the places (panes_parse)
		layout, tab_pane, pane_active := panes_parse(so["panes"], len(saved_tabs))
		pi_pane: Maybe(int)
		pi_active := false
		pi_held: u32
		pi_readonly := false
		for tv, j in saved_tabs {
			to, _ := tv.(json.Object)
			kind, _ := to["kind"].(json.String)
			held := held_of(to)
			if j == 0 && kind == "pi" {
				pi_pane, pi_active, pi_held = known(tab_pane[0]), pane_active[0], held
				pro, _ := to["readonly"].(json.Boolean)
				pi_readonly = bool(pro)
			}
			if kind == "editor" {
				// a file tab: reopens when its session starts (unsaved edits are not kept)
				if path, _ := to["path"].(json.String); strings.has_prefix(path, "/") do append(&tabs, Restore_Tab{kind = .Editor, cwd = path, active = i64(j) == i64(want_active), pane = known(tab_pane[j]), pane_active = pane_active[j]})
				continue
			}
			if kind == "markdown" {
				if path, _ := to["path"].(json.String); strings.has_prefix(path, "/") do append(&tabs, Restore_Tab{kind = .Markdown, cwd = path, active = i64(j) == i64(want_active), pane = known(tab_pane[j]), pane_active = pane_active[j]})
				continue
			}
			if kind == "browser" {
				// a web page (browser_nav.odin): its URL (in cwd), loaded once its session is focused
				url, _ := to["url"].(json.String)
				title, _ := to["title"].(json.String)
				if url != "" do append(&tabs, Restore_Tab{kind = .Browser, cwd = url, title = one_line(title, context.temp_allocator), active = i64(j) == i64(want_active), pane = known(tab_pane[j]), pane_active = pane_active[j]})
				continue
			}
			if kind == "claude" {
				// Claude Code: resumed with --resume once its session is focused (claude.odin)
				id, _ := to["claude_session_id"].(json.String)
				cwd, _ := to["cwd"].(json.String)
				args := make([dynamic]string, context.temp_allocator)
				if a, aok := to["args"].(json.Array); aok do for v in a do if x, xok := v.(json.String); xok do append(&args, string(x))
				ro, _ := to["readonly"].(json.Boolean)
				acct, _ := to["account"].(json.String)
				append(&tabs, Restore_Tab{kind = .Claude, cwd = cwd, claude_id = id, args = args[:], readonly = bool(ro), account = string(acct), active = i64(j) == i64(want_active), pane = known(tab_pane[j]), pane_active = pane_active[j], held = held})
				continue
			}
			if kind != "shell" do continue // the pi tab is always made; unknown kinds are dropped
			title, _ := to["title"].(json.String)
			cwd, _ := to["cwd"].(json.String)
			append(&tabs, Restore_Tab{kind = .Shell, title = one_line(title, context.temp_allocator), cwd = cwd, active = i64(j) == i64(want_active), pane = known(tab_pane[j]), pane_active = pane_active[j], held = held})
		}
		scwd, _ := so["cwd"].(json.String) // a worktree of the project (Restore_Session checks it)
		r := claude ? run(Restore_Session{project_id = p.id, pi_session_id = id, tabs = tabs[:], agent = .Claude, layout = layout}) : run(Restore_Session{project_id = p.id, pi_session_id = id, session_dir = dir, cwd = scwd != pcwd ? string(scwd) : "", tabs = tabs[:], layout = layout, pi_pane = pi_pane, pi_active = pi_active, pi_held = pi_held, pi_readonly = pi_readonly})
		if r.ok && has_current && i64(i) == i64(current) {
			if s := find_session(r.created_id); s != nil do persist.focus_tab = s.active_tab
		}
	}

	// Home, not started until its pane opens
	if h, is := root["home"].(json.Object); is {
		if id, iok := h["pi_session_id"].(json.String); iok && id != "" do run(Restore_Session{pi_session_id = id, home = true, pi_held = held_of(h)})
		if m, mok := h["model_applied"].(json.String); mok {
			delete(state.home_model)
			state.home_model = strings.clone(string(m))
		}
		if ff, fok := h["fork_from"].(json.String); fok && strings.has_prefix(string(ff), "/") {
			delete(state.home_fork_from)
			state.home_fork_from = strings.clone(string(ff))
		}
	}

	// layout: panels first (opening one opens the right column)
	if l, is := root["layout"].(json.Object); is {
		panels, _ := l["panels"].(json.Array)
		for pv in panels do if p, pok := pv.(json.String); pok && p != "" do run(Set_Panel{panel = p, open = true})
		collapsed, _ := l["collapsed"].(json.Array)
		for pv in collapsed do if p, pok := pv.(json.String); pok && p != "" do run(Set_Panel_Collapsed{panel = p, collapsed = true})
		if t, tok := enum_of(l, "left_tab", LEFT_TAB_NAMES); tok do run(Set_Left_Tab{tab = t})
		sl: Set_Layout
		if n, nok := num_of(l, "left_width"); nok do sl.left_width = n
		if n, nok := num_of(l, "right_width"); nok do sl.right_width = n
		if b, bok := l["left_open"].(json.Boolean); bok do sl.left_open = bool(b)
		if b, bok := l["right_open"].(json.Boolean); bok do sl.right_open = bool(b)
		if n, nok := num_of(l, "drawer_width"); nok do sl.drawer_width = n
		if b, bok := l["drawer_pinned"].(json.Boolean); bok do sl.drawer_pinned = bool(b)
		run(sl)
		// the drawer was open: the agent starts with the app
		if b, bok := l["drawer_open"].(json.Boolean); bok && b && state.home != 0 do run(Set_Home{open = true})
	}

	// the Files tab's expanded folders (ones gone since are dropped); the
	// least recent root first, so the order comes back as it was
	if fo, is := root["files"].(json.Object); is {
		// first the checkouts the trees show (worktrees: their folders become tree roots); gone ones are dropped
		checkouts, _ := fo["checkouts"].(json.Array)
		#reverse for cv in checkouts {
			co, _ := cv.(json.Object)
			b, _ := co["base"].(json.String)
			p, _ := co["path"].(json.String)
			if strings.has_prefix(b, "/") && strings.has_prefix(p, "/") do run(Files_Set_Root{base = b, path = p})
		}
		roots, _ := fo["expanded"].(json.Array)
		#reverse for rv in roots {
			ro, _ := rv.(json.Object)
			r, _ := ro["root"].(json.String)
			dirs, _ := ro["dirs"].(json.Array)
			if !strings.has_prefix(r, "/") do continue
			for dv in dirs do if d, dok := dv.(json.String); dok && d != "" && !strings.has_prefix(d, "/") {
				run(Files_Expand{path = strings.concatenate({r, "/", d}, context.temp_allocator), expanded = true})
			}
		}
	}

	// Claude Code sessions pi-desk ran, and the conversations that ran read-only (one command:
	// the saved id list goes first, then the history's read-only records while there is room)
	recs := make([dynamic]Claude_Record, context.temp_allocator)
	ro_ids := make([dynamic]string, context.temp_allocator)
	if list, is := root["claude_sessions"].(json.Array); is {
		for v in list {
			o, ok := v.(json.Object)
			if !ok do continue
			id, _ := o["id"].(json.String)
			cwd, _ := o["cwd"].(json.String)
			project, _ := o["project"].(json.String)
			title, _ := o["title"].(json.String)
			used, _ := o["used"].(json.Integer)
			ro, _ := o["readonly"].(json.Boolean)
			named, _ := o["named"].(json.Boolean)
			transcript, _ := o["transcript"].(json.String)
			model, _ := o["model"].(json.String)
			acct, _ := o["account"].(json.String)
			args := make([dynamic]string, context.temp_allocator)
			if a, aok := o["args"].(json.Array); aok do for x in a do if xs, xok := x.(json.String); xok do append(&args, string(xs))
			if id == "" || !strings.has_prefix(project, "/") || claude_args_check(args[:]) != "" do continue
			append(&recs, Claude_Record{id = id, cwd = cwd, project = project, title = one_line(title, context.temp_allocator), used = i64(used), args = args[:], named = bool(named), transcript = string(transcript), model = string(model), readonly = bool(ro), account = string(acct)})
		}
	}
	if list, is := root["claude_readonly_ids"].(json.Array); is {
		for v in list do if x, ok := v.(json.String); ok do append(&ro_ids, string(x))
	}
	if len(recs) > 0 || len(ro_ids) > 0 do run(Claude_Restore_History{records = recs[:], readonly_ids = ro_ids[:]})

	// the left column: pins and hidden items by identity, sort, folds
	if sb, is := root["sidebar"].(json.Object); is {
		strs :: proc(o: json.Object, key: string) -> []string {
			a, _ := o[key].(json.Array)
			out := make([dynamic]string, context.temp_allocator)
			for v in a do if s, ok := v.(json.String); ok do append(&out, string(s))
			return out[:]
		}
		run(Restore_Sidebar{pinned_projects = strs(sb, "pinned_projects"), pinned_sessions = strs(sb, "pinned_sessions"), hidden_projects = strs(sb, "hidden_projects"), hidden_sessions = strs(sb, "hidden_sessions")})
		if so, sok := sb["sort"].(json.Object); sok {
			for sec in Sort_Section do if by, bok := enum_of(so, SORT_SECTION_NAMES[sec], SORT_BY_NAMES); bok do run(Set_Sort{section = sec, by = by})
		}
		if fo, fok := sb["folded"].(json.Object); fok {
			for f in Sidebar_Fold do if b, bok := fo[FOLD_NAMES[f]].(json.Boolean); bok do run(Set_Sidebar_Folded{section = f, folded = bool(b)})
		}
		if b, bok := sb["show_hidden"].(json.Boolean); bok do run(Set_Filter{show_hidden = bool(b)})
		for x in strs(sb, "expanded") do if strings.has_prefix(x, "/") do run(Set_Row_Expanded{path = x, expanded = true})
	}

	if sel, is := root["selected_project"].(json.String); is {
		for p in state.projects do if p.cwd == sel {
			if p.id != state.selected_project do run(Select_Project{project_id = p.id})
			break
		}
	}
	return ""
}

// An open session's saved "panes" (write_panes) for a session saved with `ntabs` tabs: its
// layout, and per saved tab its pane (-1 = not known) and whether its pane showed it. The shape
// is checked here: not an object, a tree that is not one (a node neither a pane nor a split of
// "right" or "down" with a numeric ratio and two children, a pane number twice or not below the
// count of panes), more than PANES_MAX panes, or one pane → no layout (one pane, as from a file
// from before panes). A ratio is clamped to [RATIO_MIN, 1 - RATIO_MIN]. A tab's pane that is not
// a pane, or missing → -1; a pane's shown tab that is not one of its tabs → none (its first tab
// then, restore_panes); a focused pane that is not one → the first pane. Which tabs come back is
// the restore's business (restore_panes).
panes_parse :: proc(v: json.Value, ntabs: int) -> (layout: Restore_Layout, tab_pane: []int, pane_active: []bool) {
	tab_pane = make([]int, ntabs, context.temp_allocator)
	pane_active = make([]bool, ntabs, context.temp_allocator)
	for &x in tab_pane do x = -1
	o, is := v.(json.Object)
	if !is do return
	nodes := make([dynamic]Restore_Node, context.temp_allocator)
	// the subtree at v as nodes (pre-order: a node before its children), its index; -1: not a tree
	node :: proc(v: json.Value, nodes: ^[dynamic]Restore_Node) -> int {
		o, is := v.(json.Object)
		if !is || len(nodes) >= 2 * PANES_MAX - 1 do return -1
		if pv, leaf := o["pane"]; leaf {
			n, nok := pv.(json.Integer)
			if !nok || n < 0 || n >= PANES_MAX || "split" in o do return -1
			append(nodes, Restore_Node{leaf = true, pane = int(n)})
			return len(nodes) - 1
		}
		dir: Split_Dir
		switch d, _ := o["split"].(json.String); d {
		case "right": dir = .Right
		case "down":  dir = .Down
		case:         return -1
		}
		ratio, rok := num_of(o, "ratio")
		if !rok || ratio != ratio do return -1
		i := len(nodes)
		append(nodes, Restore_Node{dir = dir, ratio = clamp(ratio, RATIO_MIN, 1 - RATIO_MIN)})
		a := node(o["a"], nodes)
		if a < 0 do return -1
		b := node(o["b"], nodes)
		if b < 0 do return -1
		nodes[i].a, nodes[i].b = a, b
		return i
	}
	if node(o["tree"], &nodes) != 0 do return
	n := 0
	for x in nodes do if x.leaf do n += 1
	if n <= 1 || n > PANES_MAX do return
	seen := make([]bool, n, context.temp_allocator)
	for x in nodes do if x.leaf {
		if x.pane >= n || seen[x.pane] do return
		seen[x.pane] = true
	}
	layout = {nodes = nodes[:], panes = n}
	if f, fok := o["focused"].(json.Integer); fok && f >= 0 && f < i64(n) do layout.focused = int(f)
	else {
		at := 0
		for !nodes[at].leaf do at = nodes[at].a
		layout.focused = nodes[at].pane
	}
	tp, _ := o["tab_pane"].(json.Array)
	for x, j in tp {
		if j >= ntabs do break
		if p, pok := x.(json.Integer); pok && p >= 0 && p < i64(n) do tab_pane[j] = int(p)
	}
	act, _ := o["active"].(json.Array)
	for x, k in act {
		if k >= n do break
		if j, jok := x.(json.Integer); jok && j >= 0 && j < i64(ntabs) && tab_pane[j] == k do pane_active[j] = true
	}
	return
}

// A saved pane from panes_parse (-1: not known) as Restore_Tab.pane / Restore_Session.pi_pane.
@(private = "file")
known :: proc(pane: int) -> Maybe(int) {return pane >= 0 ? pane : nil}

// The project with this cwd, listed if the scan did not find it: not as added by hand (the
// saved "added" says that) and not selected (the saved selection is restored after).
@(private = "file")
ensure_project :: proc(cwd: string) -> ^Project {
	for &p in state.projects do if p.cwd == cwd do return &p
	want, _ := filepath.clean(cwd, context.temp_allocator)
	want = real_path(want)
	if c := chats_project(); c != nil && c.cwd == want do return nil
	if p := project_by_cwd(want); p != nil do return p
	if claude_account_holding(want) != "" do return nil
	c := strings.clone(want)
	inject_at(&state.projects, 0, Project{id = new_id(), cwd = c, label = short_label(c), missing = !os.exists(c), repo = is_repo_root(c)})
	return &state.projects[0]
}

@(private = "file")
enum_of :: proc(obj: json.Object, key: string, names: [$E]string) -> (E, bool) {
	s, ok := obj[key].(json.String)
	if !ok do return {}, false
	for name, e in names do if name == s do return e, true
	return {}, false
}

@(private = "file")
num_of :: proc(obj: json.Object, key: string) -> (f32, bool) {
	#partial switch n in obj[key] {
	case json.Integer: return f32(n), true
	case json.Float:   return f32(n), true
	}
	return 0, false
}

// After the first layout (the pane has a size): focus the restored current
// tab, which starts its session. Skipped when `pi-desk DIR` opens a new chat.
persist_after_layout :: proc(skip: bool) {
	if persist.launch != {} && !persist.laid_out {
		persist.laid_out = true
		fmt.eprintf("Deckhand: first layout %.1f ms after launch\n", time.duration_milliseconds(time.tick_since(persist.launch)))
	}
	id := persist.focus_tab
	if id == 0 do return
	persist.focus_tab = 0
	if skip do return
	run_command(Focus_Tab{tab_id = id}, {kind = .Internal})
	if persist.launch != {} do fmt.eprintf("Deckhand: restored session started %.1f ms after launch\n", time.duration_milliseconds(time.tick_since(persist.launch)))
}

// A dim line in a terminal before its child starts (restored shells).
term_note :: proc(t: ^Term, text: string) {
	msg := fmt.tprintf("\x1b[2m%s\x1b[0m\r\n", text)
	gh.terminal_vt_write(t.gt, raw_data(msg), len(msg))
}
