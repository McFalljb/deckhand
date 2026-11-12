package main

// Reopen closed tab (⇧⌘T; actions.odin): the window remembers the tabs the user closed by hand, at
// most CLOSED_TABS_MAX, newest last, in the window's memory only (never saved, never sent).
// Recorded ONLY by the user's own close gestures: a tab's × and ⌘W (close_tab_click), the tab
// menu's "Close tab" (menu_run), and the menu bar's and the palette's Close tab (the close_tab
// action's prepare: only the user runs actions). Nothing else records: the confirm bar, the
// comments prompt, agents, scripts, control callers and other machines.
//
// A gesture records a PENDING entry, one per tab (a repeated × replaces it). It becomes
// reopenable only when the tab goes as the result of that same flow: at once when no confirmation
// was asked, or after the user's own Confirm (confirm_pending). Cancel (cancel_pending) drops it;
// so does a confirmation that went away while the tab stayed, or the tab going while it asked and
// the user had not confirmed (someone else closed it). closed_tabs_settle decides, every frame.
//
// ⇧⌘T pops the newest reopenable one and sends what a click would: its session to the front, then the open
// command as the user. An entry whose tab still exists (its close was cancelled) or whose session
// has closed is dropped and the next one taken. What each kind keeps and reopens:
//   editor, Markdown   its file (open_file, markdown_open: the file as it is on disk now)
//   browser            its address as State holds it, the same the workspace saves (browser_open);
//                      not a page at 127.0.0.1: another machine's page ("Open a machine's web
//                      page…") is there, through an ssh forward that ends with its tab
//   Claude             its Claude Code session id (new_claude_tab resume, its history's flags)
//   Changes            its checkout (changes_open)
//   shell              its folder: a NEW shell there ("Reopened a new terminal in …")
// Not kept: app tabs, a blank browser tab, a Claude tab that never reported its session, another
// machine's tabs, a pi tab (it closes its session).

import "core:fmt"
import "core:strings"
import "core"

CLOSED_TABS_MAX :: 10

Closed_Kind :: enum u8 {
	Shell,
	Editor,
	Markdown,
	Browser,
	Claude,
	Changes,
}

Closed_Tab :: struct {
	kind:    Closed_Kind,
	tab_id:  u64, // the closed tab (still there: its close was cancelled)
	session: u64,
	what:    string, // owned: the folder, file, address, Claude session id or checkout
	cwd:     string, // owned: a Claude tab's folder ("" = the session's)
	pending:   bool, // the close is not done yet (see above)
	asked:     bool, // its close asked the user (a confirmation of the user's for this tab was seen)
	confirmed: bool, // the user confirmed it
}

closed_tabs: [dynamic]Closed_Tab // oldest first

closed_tabs_clear :: proc() {
	for x in closed_tabs do closed_tab_free(x)
	clear(&closed_tabs)
}

@(private = "file")
closed_tab_free :: proc(x: Closed_Tab) {
	delete(x.what)
	delete(x.cwd)
}

// The user closes tab_id by hand (its ×, ⌘W, its menu's Close tab).
closed_tab_record :: proc(tab_id: u64) {
	s, tab, i := find_tab(tab_id)
	if s == nil || tab == nil || i == 0 || s.home || s.machine != 0 || tab.machine != 0 do return
	x := Closed_Tab{tab_id = tab_id, session = s.id}
	#partial switch k in tab.kind {
	case core.Shell_Tab:    x.kind, x.what = .Shell, tab.cwd != "" ? tab.cwd : s.cwd
	case core.Editor_Tab:   x.kind, x.what = .Editor, k.path
	case core.Markdown_Tab: x.kind, x.what = .Markdown, k.path
	case core.Browser_Tab:
		if k.url == "" || k.url == "about:blank" do return
		for pre in ([]string{"http://127.0.0.1:", "http://127.0.0.1/", "https://127.0.0.1:", "https://127.0.0.1/"}) do if strings.has_prefix(k.url, pre) do return // maybe another machine's page
		x.kind, x.what = .Browser, core.browser_url_public(k.url)
	case core.Claude_Tab:
		if k.session_id == "" do return
		x.kind, x.what, x.cwd = .Claude, k.session_id, tab.cwd
	case core.Changes_Tab:  x.kind, x.what = .Changes, k.root
	case:                   return // app tabs and the rest
	}
	if x.what == "" do return
	closed_tab_drop(tab_id) // a repeated ×: one entry
	x.pending = true
	x.what = strings.clone(x.what)
	x.cwd = strings.clone(x.cwd)
	if len(closed_tabs) >= CLOSED_TABS_MAX {
		closed_tab_free(closed_tabs[0])
		ordered_remove(&closed_tabs, 0)
	}
	append(&closed_tabs, x)
}

@(private = "file")
closed_tab_drop :: proc(tab_id: u64) {
	for i := len(closed_tabs) - 1; i >= 0; i -= 1 do if closed_tabs[i].tab_id == tab_id {
		closed_tab_free(closed_tabs[i])
		ordered_remove(&closed_tabs, i)
	}
}

// The user's own confirmation to close tab_id is waiting: the confirm bar, or the comments prompt
// (State.comments_ask: only the user's close gets it; its Send or Drop and close is the user's yes,
// closed_tab_answered; its Cancel lets the entry go as the bar's does).
@(private = "file")
closed_tab_asking :: proc(tab_id: u64) -> bool {
	if state.comments_ask.tab_id == tab_id do return true
	for p in state.pending_confirmations {
		if p.caller.kind != .UI || p.caller.hub do continue
		if c, is := p.command.(core.Close_Tab); is && c.tab_id == tab_id do return true
	}
	return false
}

// Pending entries become reopenable or go (see above). Every frame; cheap with none pending.
closed_tabs_settle :: proc() {
	for i := len(closed_tabs) - 1; i >= 0; i -= 1 {
		x := &closed_tabs[i]
		if !x.pending do continue
		asking := closed_tab_asking(x.tab_id)
		if asking do x.asked = true
		_, tab, _ := find_tab(x.tab_id)
		keep := true
		if tab == nil {
			if x.confirmed || !x.asked do x.pending = false // the user's own close went through
			else do keep = false // closed by someone else while it asked
		} else if x.asked && !asking && !x.confirmed {
			keep = false // cancelled, or the question went away: the tab stays
		}
		if !keep {
			closed_tab_free(x^)
			ordered_remove(&closed_tabs, i)
		}
	}
}

// The bar's Confirm or Cancel on a close the user asked for (main.odin confirm_pending,
// cancel_pending), or the comments prompt's Send now or Drop and close (ui_comments.odin).
closed_tab_answered :: proc(cmd: core.Command, confirmed: bool) {
	c, is := cmd.(core.Close_Tab)
	if !is do return
	if !confirmed {
		closed_tab_drop(c.tab_id)
		return
	}
	for &x in closed_tabs do if x.tab_id == c.tab_id && x.pending do x.confirmed = true
}

// ⇧⌘T.
closed_tab_reopen :: proc() {
	closed_tabs_settle()
	for i := len(closed_tabs) - 1; i >= 0; i -= 1 {
		if closed_tabs[i].pending do continue
		x := closed_tabs[i]
		ordered_remove(&closed_tabs, i)
		defer closed_tab_free(x)
		if _, still, _ := find_tab(x.tab_id); still != nil do continue // its close was cancelled
		s := core.find_session(x.session)
		if s == nil || s.home || s.missing do continue
		open: core.Command
		switch x.kind {
		case .Shell:    open = core.New_Shell_Tab{session = s.id, cwd = x.what}
		case .Editor:   open = core.Open_File{path = x.what, session = s.id}
		case .Markdown: open = core.Markdown_Open{path = x.what, session = s.id}
		case .Browser:  open = core.Browser_Open{session = s.id, url = x.what}
		case .Changes:  open = core.Changes_Open{session = s.id, path = x.what}
		case .Claude:
			args: []string
			if rec, _ := core.claude_record(x.what); rec != nil do args = rec.args // the user's own resume: its flags
			open = core.New_Claude_Tab{session = s.id, cwd = x.cwd, resume = x.what, args = args}
		}
		// as a click: the session to the front (the opens show the tab in the session on screen)
		if state.current_session != s.id do ui_do(core.Focus_Session{session = s.id})
		ui_do(core.command_clone(open, context.temp_allocator))
		if x.kind == .Shell do toast_show(fmt.tprintf("Reopened a new terminal in %s", core.path_tilde(x.what)))
		return
	}
	toast_show("No closed tab to reopen")
}
