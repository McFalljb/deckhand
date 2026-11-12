package core

// Reopen closed tab (reopen_closed_tab; ⇧⌘T): the tabs the user closed on this Mac, newest last,
// at most CLOSED_TABS_MAX, in the core's memory only (never saved, never in State, never sent to a
// window or another machine). Each keeps only what reopens it honestly, never a terminal's text, a
// token or flags:
//   editor tab      its file (Open_File: the file as it is on disk now)
//   Markdown tab    its file (Markdown_Open)
//   browser tab     its address as State has it (browser_url_public: no user:pass@; the workspace
//                   saves the same); a blank tab is not kept
//   app tab         its name, command line and folder, when it is an app its project's
//                   .deckhand/apps.json declares (that name and command line); reopened only while
//                   the declaration still resolves to exactly that command and folder (as the
//                   palette's open would run it now), else "That app's command changed"; a command
//                   line typed in the palette is not kept
//   Claude tab      its Claude Code session id: resumed (new_claude_tab resume, with the history's
//                   flags as the user's own resume); before Claude reported one, not kept
//   shell tab       its folder: a NEW shell there (its program and scrollback are gone)
//   Changes tab     its checkout (Changes_Open)
// Kept: the user's own closes of this Mac's tabs: the caller that asked for the close (a close an
// agent asked for and the user confirmed is the agent's: confirm_gate's origin), not a hub's
// (another machine's user closing a tab here reopens nothing on theirs). A session's pi tab and a Claude session's main tab
// never close alone. An entry whose session has closed since is dropped when it comes up.

import "core:fmt"
import "core:strings"

CLOSED_TABS_MAX :: 10

Closed_Kind :: enum u8 {
	Shell,
	Editor,
	Markdown,
	Browser,
	App,
	Claude,
	Changes,
}

Closed_Tab :: struct {
	kind:    Closed_Kind,
	session: u64, // its open session
	what:    string, // owned: the folder, file, address, app name, Claude session id or checkout
	cwd:     string, // owned: a Claude tab's or an app tab's folder ("" = the session's)
	argv:    []string, // owned: an app tab's command line (what it ran)
}

closed_tabs: [dynamic]Closed_Tab // oldest first

// The user's ⇧⌘T (who: User_Here, command_table.odin: never a hub's, never an agent's).
Reopen_Closed_Tab :: struct {}

closed_tabs_clear :: proc() {
	for x in closed_tabs do closed_tab_free(x)
	clear(&closed_tabs)
}

@(private = "file")
closed_tab_free :: proc(x: Closed_Tab) {
	delete(x.what)
	delete(x.cwd)
	for a in x.argv do delete(a)
	delete(x.argv)
}

// Close_Tab: the tab is going (its kind not freed yet). caller: who asked for the close (the
// requester a confirmation was parked for, not the user who confirmed it).
closed_tab_note :: proc(s: ^Open_Session, tab: Tab, caller: Caller) {
	if caller.kind != .UI || caller_from_hub(caller) || s.home || s.machine != 0 || tab.machine != 0 do return
	x := Closed_Tab{session = s.id}
	switch k in tab.kind {
	case Pi_Tab:
		return
	case Shell_Tab:
		x.kind, x.what = .Shell, tab.cwd != "" ? tab.cwd : s.cwd
	case Editor_Tab:
		x.kind, x.what = .Editor, k.path
	case Markdown_Tab:
		x.kind, x.what = .Markdown, k.path
	case Browser_Tab:
		u := browser_url_public(k.url)
		if u == "" || u == "about:blank" do return
		x.kind, x.what = .Browser, u
	case App_Tab:
		e, ok := app_entry(s.cwd, tab.title)
		if !ok || len(e.argv) != len(k.argv) do return
		for a, i in e.argv do if a != k.argv[i] do return
		x.kind, x.what, x.cwd, x.argv = .App, e.name, k.cwd, k.argv
	case Claude_Tab:
		if k.session_id == "" do return
		x.kind, x.what, x.cwd = .Claude, k.session_id, tab.cwd
	case Changes_Tab:
		x.kind, x.what = .Changes, k.root
	}
	if x.what == "" do return
	x.what = strings.clone(x.what)
	x.cwd = strings.clone(x.cwd)
	if len(x.argv) > 0 {
		argv := make([]string, len(x.argv))
		for a, i in x.argv do argv[i] = strings.clone(a)
		x.argv = argv
	}
	if len(closed_tabs) >= CLOSED_TABS_MAX {
		closed_tab_free(closed_tabs[0])
		ordered_remove(&closed_tabs, 0)
	}
	append(&closed_tabs, x)
}

// The newest entry whose session is still open, taken off the stack (ok false: none).
@(private = "file")
closed_tab_pop :: proc() -> (x: Closed_Tab, s: ^Open_Session, ok: bool) {
	for len(closed_tabs) > 0 {
		x = pop(&closed_tabs)
		if s = find_session(x.session); s != nil && !s.home && !s.missing do return x, s, true
		closed_tab_free(x)
	}
	return {}, nil, false
}

reopen_closed_tab :: proc(caller: Caller, request_id: u64) -> (Result, bool) {
	x, s, ok := closed_tab_pop()
	if !ok {
		if caller.kind == .UI do window_toast("No closed tab to reopen")
		return {ok = true}, false
	}
	defer closed_tab_free(x)
	// a declared app: only the command and folder its tab ran (an agent may have rewritten
	// apps.json since); what runs is what the palette's open would run now, checked equal
	app: New_App_Tab
	if x.kind == .App {
		now, _, bad := app_new_resolve(New_App_Tab{session = s.id, name = x.what}, caller)
		same := !bad && now.cwd == x.cwd && len(now.argv) == len(x.argv)
		if same do for a, i in now.argv do if a != x.argv[i] do same = false
		if !same {
			if caller.kind == .UI do window_toast("That app's command changed: open it from the project")
			return {ok = true}, false
		}
		app = now
	}
	// its session comes to the front first: the open commands show the tab in the session on screen
	if state.current_session != s.id do run_command(Focus_Session{session = s.id}, caller)
	open: Command
	switch x.kind {
	case .Shell:    open = New_Shell_Tab{session = s.id, cwd = x.what}
	case .Editor:   open = Open_File{path = x.what, session = s.id}
	case .Markdown: open = Markdown_Open{path = x.what, session = s.id}
	case .Browser:  open = Browser_Open{session = s.id, url = x.what}
	case .App:      open = app // the argv and folder checked above
	case .Changes:  open = Changes_Open{session = s.id, path = x.what}
	case .Claude:
		args: []string
		if rec, _ := claude_record(x.what); rec != nil do args = rec.args // the user's own resume: its flags
		open = New_Claude_Tab{session = s.id, cwd = x.cwd, resume = x.what, args = args}
	}
	r := run_command(open, caller, request_id)
	if r.ok && x.kind == .Shell && caller.kind == .UI do window_toast(fmt.tprintf("Reopened a new terminal in %s", path_tilde(x.what)))
	return r, false // the open command changed State (and said so)
}
