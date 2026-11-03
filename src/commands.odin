package main

// The one way to change app state. Clicks, shortcuts, the test script (and
// later a control socket) build a Command and submit it to the inbox
// (inbox.odin); the main thread runs it through run_command. Commands name
// their targets by id (project, open session, tab), never by list position or
// "whatever is current". Each run returns a Result and emits an event
// (events.odin); state.version is bumped only when State changed.
//
// Not commands: raw keyboard/mouse/paste bytes forwarded to the focused
// terminal, and keystrokes inside a text field. They change a child's screen
// or an edit buffer, not app state. Agents get Send_Text for terminals.
//
// No window or OS-UI calls here: clipboard and quit go through `platform`
// (platform.odin), which the window layer implements.

import "core:crypto"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"

Add_Project :: struct {
	cwd: string, // added at the top if not listed yet (and shown again if hidden), then selected
}
Select_Project :: struct {
	project_id: u64,
}
Rename_Project :: struct {
	project_id: u64,
	name:       string, // "" = back to the path label
}
Open_Session_Cmd :: struct {
	project_id:    u64,
	pi_session_id: string, // resume this pi session; focuses it if already open
}
New_Chat :: struct {
	project_id: u64,
}
Focus_Session :: struct {
	session: u64, // open session id
}
// Stops an open session's tabs and forgets it (open sessions, saved
// workspace); pi's session file stays. Confirms (class tab_close) while any
// of its tabs would ask to close.
Close_Session :: struct {
	session:  u64,
	confirm:  string,
	ask:      bool, // always confirm, even with nothing running (the pi tab's × and ⌘W: UI only, not on the wire)
	comments: Comments_Choice, // its pending comments (comments.odin): ask (the user's close prompt), drop; send is refused
}
New_Shell_Tab :: struct {
	session: u64,
	cwd:     string, // where the shell starts: a folder inside a project ("" = the session's folder)
}
Close_Tab :: struct {
	tab_id:   u64, // a session's pi tab cannot be closed
	confirm:  string, // token from a needs_confirmation result
	comments: Comments_Choice, // the comments made on it (comments.odin): ask (the user's close prompt), send, drop
}
Focus_Tab :: struct {
	tab_id: u64, // also makes its session current
}
Copy_Selection :: struct {
	tab_id: u64,
}
Send_Text :: struct {
	tab_id: u64,
	text:   string, // pasted into the tab (bracketed if the app asked)
}
Set_Focus :: struct {
	widget: string, // "" = the current tab's terminal; else a widget id (FOCUS_WIDGETS)
}
Set_Layout :: struct {
	left_width:    Maybe(f32), // unset fields keep their value
	right_width:   Maybe(f32),
	left_open:     Maybe(bool),
	right_open:    Maybe(bool),
	drawer_width:  Maybe(f32),
	drawer_pinned: Maybe(bool),
}
Set_Panel :: struct {
	panel: string,
	open:  bool,
}
Cancel_Confirmation :: struct {
	token: string,
}
Rescan :: struct {} // long-running: returns pending, finishes with an event
Quit :: struct {
	confirm: string,
}
Get_State :: struct {} // query: Result.data is the state JSON
List_Commands :: struct {} // query: the commands this caller may send (command_table.odin)
// Shows or hides the agent's chat drawer; the first open makes and starts
// the agent's pi (Home), an open after it exited starts it again.
Set_Home :: struct {
	open: bool,
}

// The left column (sidebar.odin). A target is a project (project_id) or a
// session (pi_session_id: a project's or a chat), not both.
Set_Pinned :: struct {
	cwd:           string, // a project by its folder (unpinning one that is not listed any more)
	project_id:    u64,
	pi_session_id: string,
	pinned:        bool,
	index:         Maybe(int), // place among the pinned (also moves a pinned one); unset = last, or where it is
}
Set_Hidden :: struct {
	cwd:           string, // a project by its folder (showing one that is not listed any more)
	project_id:    u64,
	pi_session_id: string,
	hidden:        bool, // hidden items are left out of the list unless show_hidden; nothing is deleted
}
Set_Sort :: struct {
	section: Sort_Section,
	by:      Sort_By,
}
Set_Sidebar_Folded :: struct {
	section: Sidebar_Fold,
	folded:  bool,
}
// Opens or collapses a parent or group row of the Projects tree (its folder
// path; project_tidy.odin). Saved; collapsed by default.
Set_Row_Expanded :: struct {
	path:     string,
	expanded: bool,
}
// Unset fields keep their value.
Set_Filter :: struct {
	text:        Maybe(string),
	running:     Maybe(bool),
	waiting:     Maybe(bool),
	pinned:      Maybe(bool),
	show_hidden: Maybe(bool),
}
// Shows a project's folder, or a session's file, in the file manager.
Reveal_Path :: struct {
	project_id:    u64,
	pi_session_id: string, // "" = the project's folder
}
// Copies the same path to the clipboard.
Copy_Path :: struct {
	project_id:    u64,
	pi_session_id: string,
}

// Chats settings (user-only): read-only or full pi (where they run: Set_Folder, folders.odin).
Set_Chats_Readonly :: struct {
	on: bool,
}
Set_Agent_Name :: struct {
	name: string, // "" = the default
}
// The agent's model (agent.odin): "provider/id", optionally ":thinking";
// "" = pi's default. Passed as --model when Atlas starts.
Set_Agent_Model :: struct {
	model: string,
}
// Shows the drawer and opens pi's model selector in Atlas's terminal.
Agent_Model_Picker :: struct {}
Set_Notify :: struct {
	on: bool,
}
// The tidy project list (project_tidy.odin): temp folders and missing ones
// hidden, subfolders folded into their project. On by default.
Set_Tidy_Projects :: struct {
	on: bool,
}

// User-only (caller ui or internal): settings that bound what agents may do.
Set_Confirm_Policy :: struct {
	caller: Caller_Kind, // script, control or panel
	class:  Command_Class,
	mode:   Confirm_Mode,
}
Set_Close_Confirm :: struct {
	tab_kind: Tab_Kind_Id,
	rule:     Close_Confirm,
}

// Appearance (any caller but panels).
Set_Theme :: struct {
	name: Theme_Id,
}
Set_Reduce_Motion :: struct {
	on: bool,
}
// The terminal and editor text size in points (0 = the look's own).
Set_Terminal_Text_Size :: struct {
	pt: int,
}
Set_Appearance :: struct {
	mode: Appearance,
}
Set_Text_Size :: struct {
	size: Text_Size,
}

// From a pi tab's bridge (docs/PROTOCOL.md §4). Over the socket the tab is
// the caller's own (tab_id 0 = the token's tab); a pi tab may only report
// for itself.
Pi_Session_Update :: struct {
	tab_id:        u64,
	pi_session_id: string,
	session_file:  string,
	cwd:           string,
}
Pi_Status_Update :: struct {
	tab_id:   u64,
	agent:    Agent_State,
	waiting:  bool,
	question: bool,
	blockers: []string,
}

// A pi tab's panels (docs/PROTOCOL.md §5). Only the tab's own bridge may
// publish them (tab_id 0 over the socket = the token's tab).
Panel_Set :: struct {
	tab_id: u64,
	panel:  string,
	title:  string,
	rows:   []Panel_Row,
}
Panel_Remove :: struct {
	tab_id: u64,
	panel:  string,
}
// Folds or unfolds a panel's section in the right column (any tab's).
Set_Panel_Collapsed :: struct {
	panel:     string,
	collapsed: bool,
}

// To a pi tab's bridge: routed to the tab's socket connection. Long-running:
// `pending`, then a `finished` event with the bridge's result.
Pi_Prompt :: struct {
	tab_id: u64,
	text:   string, // submitted as a user message; refused while pi is waiting
	images: []Prompt_Image, // sent with it (comments.odin; Send now); at most COMMENT_IMAGES_MAX
}
Pi_Reload :: struct {
	tab_id:  u64,
	confirm: string, // class session_restart
}
Pi_Wait_Idle :: struct {
	tab_id:     u64,
	timeout_ms: u64,
}

// Internal only (never parsed from JSON): posted by the app itself.
System_Appearance :: struct {
	light: bool, // the OS appearance is light (the platform layer saw it change)
}
Tab_Exited :: struct {
	tab_id: u64,
}
Rescan_Done :: struct {
	request_id: u64,
	scan:       ^Scan_Result,
}
// Internal only: one saved session back into State (persist.odin) with its
// tabs not started. Focusing the session starts them (lazy restore).
Restore_Tab :: struct {
	kind:  Tab_Kind_Id,
	title: string,
	cwd:   string, // shells: where to start; editors: the file; browser tabs: the URL
	active: bool, // the session's active tab (none: the pi tab)
}
Restore_Session :: struct {
	project_id:    u64,
	pi_session_id: string,
	session_dir:   string, // "" = pi's default store
	cwd:           string, // where pi runs: a checkout of the project's repository ("" = the project's folder)
	tabs:          []Restore_Tab, // the tabs after the pi tab
	home:          bool, // the Home session (no project, no other tabs; session dir and cwd are pi-desk's)
}
Bridge_Done :: struct { 	// a bridge answered (or dropped) a Pi_Prompt/Pi_Reload/Pi_Wait_Idle
	request_id: u64,
	ok:         bool,
	error:      string,
}

// Internal only: the saved pins and hidden items back into State.
Restore_Sidebar :: struct {
	pinned_projects: []string,
	pinned_sessions: []string,
	hidden_projects: []string,
	hidden_sessions: []string,
}

Command :: union {
	Add_Project,
	Select_Project,
	Rename_Project,
	Open_Session_Cmd,
	New_Chat,
	Focus_Session,
	Close_Session,
	New_Shell_Tab,
	Close_Tab,
	Focus_Tab,
	Copy_Selection,
	Terminal_Link, // a link in a terminal tab (term_links.odin)
	Send_Text,
	Set_Focus,
	Set_Layout,
	Set_Panel,
	Cancel_Confirmation,
	Rescan,
	Quit,
	Get_State,
	List_Commands,
	Set_Home,
	Set_Pinned,
	Set_Hidden,
	Set_Sort,
	Set_Sidebar_Folded,
	Set_Row_Expanded,
	Set_Filter,
	Reveal_Path,
	Copy_Path,
	Session_Info, // a session's info for Atlas (session_info.odin)
	// the main folder (folders.odin)
	Set_Home_Dir,
	Set_Folder,
	Setup_Sheet,
	Set_Chats_Readonly,
	Set_Agent_Name,
	Set_Agent_Model,
	Agent_Model_Picker,
	Set_Notify,
	Set_Tidy_Projects,
	Set_Confirm_Policy,
	Set_Close_Confirm,
	Set_Theme,
	Set_Reduce_Motion,
	Set_Terminal_Text_Size,
	Set_Appearance,
	Set_Text_Size,
	System_Appearance,
	Pi_Session_Update,
	Pi_Status_Update,
	Pi_Prompt,
	Pi_Reload,
	Pi_Wait_Idle,
	Panel_Set,
	Panel_Remove,
	Set_Panel_Collapsed,
	Tab_Exited,
	Rescan_Done,
	Bridge_Done,
	Restore_Session,
	Restore_Sidebar,
	// editor and files (editor_commands.odin)
	Open_File,
	Editor_State,
	Save_File,
	Goto_Line,
	Reload_File,
	Keep_Buffer,
	Diff_File,
	Set_Wrap,
	List_Dir,
	Create_File,
	Create_Dir,
	Rename_Path,
	Delete_Path,
	Reveal_In_Finder,
	Keep_Tab,
	// the Files tab (files.odin)
	Set_Left_Tab,
	Files_Expand,
	Files_Collapse_All,
	Files_Reveal,
	Set_Files_Filter,
	// worktrees and branches (worktrees.odin)
	List_Worktrees,
	Files_Set_Root,
	Worktree_Cleanup,
	Worktree_Session,
	Worktree_Cleanup_Done,
	Worktrees_Done,
	Git_Head_Done,
	Git_Status_Done,
	File_List_Done,
	// the bell (notify.odin)
	Notifications_List,
	Notifications_Mark_Read,
	Notifications_Clear,
	Notify_Post,
	Set_Bell,
	// updates (update.odin)
	Update_Check,
	Update_Skip,
	Update_Later,
	Update_Download,
	Update_Install,
	Set_Update_Check,
	Update_Env,
	Update_Tick,
	Update_Checked,
	Update_Prepared,
	// jobs (jobs.odin)
	Job_List,
	Job_Runs,
	Job_Run_Now,
	Job_Stop,
	Jobs_Pause,
	Jobs_Resume,
	Job_Create,
	Job_Save,
	Job_Sheet, // the job sheet (ui_job_sheet.odin)
	Job_Mark_Read,
	Job_Set_Enabled,
	Job_Delete,
	Job_Open,
	Set_Pi_Path,
	Set_Job_Limits,
	Jobs_Sync,
	Jobs_Tick,
	Job_Run_Done,
	Jobs_Env,
	// the Changes tab (changes.odin)
	Changes_Open,
	Changes_List,
	Changes_Stage,
	Changes_Unstage,
	Changes_Discard,
	Changes_Commit,
	Changes_Scan_Done,
	Changes_Diff_Done,
	Changes_Op_Done,
	// the Markdown tab (markdown_view.odin)
	Markdown_Open,
	Markdown_Set_View,
	Markdown_Scroll,
	Markdown_Follow,
	// app tabs (app_tab.odin)
	New_App_Tab,
	App_Restart,
	App_Input,
	App_Events,
	App_Call,
	App_Call_Done,
	App_Screenshot,
	App_Inspect,
	App_Update,
	// hot reload (reload.odin)
	Pi_Reload_All,
	Pi_Restart_Updated,
	Pi_Reload_Later,
	Reload_Watch,
	Reload_Kick,
	// pending comments (comments.odin)
	Comment_Add,
	Comment_Edit,
	Comment_Delete,
	Comments_Clear,
	Comments_Send_Now,
	Comments_Ask_Cancel,
	Pi_Attached,
	// browser tabs' navigation (browser_nav.odin)
	Browser_Open,
	Browser_Navigate,
	Browser_Back,
	Browser_Forward,
	Browser_Reload,
	Browser_Stop,
	Browser_Update,
	// browser tabs' polish (browser_polish.odin)
	Browser_Zoom,
	Browser_Find,
	Browser_Find_Close,
	Browser_Dialog,
	Browser_Permission,
	Browser_Popup,
	Browser_Edit,
	Browser_Devtools,
	Browser_External,
	Browser_Download,
	// agents read pages (browser_agent.odin)
	Browser_Tabs,
	Browser_Read,
	Browser_Screenshot,
	Browser_Page_Wait,
	Browser_Console,
	Browser_Network,
	Browser_Comments,
	Browser_Agent_Stop,
	// agents act on pages (browser_act.odin)
	Browser_Click,
	Browser_Type,
	Browser_Press,
	Browser_Scroll,
	Browser_Select,
	Browser_Hover,
	Browser_Upload,
	Browser_Upload_Answer,
	Browser_Agent_Take_Over,
	Request_Cancel,
}

// Widgets that can take keyboard focus (editor_*: the editor's find,
// replace and go-to-line fields).
FOCUS_WIDGETS :: [?]string{"rename_project", "palette", "sidebar_filter", "agent_input", "settings", "shortcuts", "editor_find", "editor_replace", "editor_goto", "files", "files_filter", "files_name", "notifications", "changes_message", "setup", "job_sheet", "comment_edit", "comment_new", "browser_url", "browser_find", "browser_prompt"}

Result :: struct {
	ok:              bool,
	error:           string,
	created_id:      u64, // what the command created or focused (project, open session, tab)
	pending:         bool, // accepted; finishes later with a "finished" event for this request id
	confirm_token:   string, // set with error "needs_confirmation" if this caller may confirm: resend with it
	confirm_summary: string,
	confirm_by_user: bool, // needs_confirmation: only the user can confirm (in the UI)
	data:            string, // query results (JSON)
}

// Who sent a command. tab_id is the caller's own tab for pi-tab callers.
Caller_Kind :: enum {
	Internal,
	UI,
	Script,
	Control,
	Panel,
	App, // an app tab's program (app_tab.odin): answers tab.* requests, sends no commands
}
Caller :: struct {
	kind:   Caller_Kind,
	tab_id: u64,
}

fail :: proc(msg: string) -> Result {return {error = msg}}

// Runs one command on the main thread. request_id ties it to its events.
run_command :: proc(cmd: Command, caller := Caller{kind = .Internal}, request_id: u64 = 0) -> Result {
	r: Result
	changed := false
	if !caller_may(caller, cmd) {
		r = fail("not allowed for this caller")
	} else {
		r, changed = apply(cmd, caller, request_id)
	}
	// what the tidy project list depends on (project_tidy.odin)
	#partial switch _ in cmd {
	case Add_Project, Rename_Project, Set_Pinned, Set_Hidden, Restore_Sidebar, Set_Tidy_Projects:
		if changed do projects_tidy()
	case:
		// a project shown or hidden by an opened or closed session: nesting skips hidden rows
		if changed && tidy_shown_sig() != tidy_shown do projects_tidy()
	}
	if changed {
		state.version += 1
		app.redraw = true
	}
	_, q1 := cmd.(Get_State)
	_, q2 := cmd.(List_Commands)
	// the scheduler's own bookkeeping and the job queries: no event unless State moved
	q3 := false
	#partial switch _ in cmd {
	case Notifications_List:   q3 = true
	case Jobs_Sync, Jobs_Tick: q3 = !changed
	case Job_List, Job_Runs:   q3 = true
	case Job_Run_Done:         q3 = true // job.finished says it (the run is freed by now)
	}
	// app tabs: answers and queries (App_Call_Done finishes its request itself)
	#partial switch _ in cmd {
	case App_Call_Done, App_Events: q3 = true
	// browser tabs' queries: their answers hold page content (the requester's only)
	case Browser_Tabs, Browser_Console, Browser_Network, Browser_Comments: q3 = true
	}
	_, q4 := cmd.(Editor_State)
	_, q5 := cmd.(List_Dir)
	if !q1 && !q2 && !q3 && !q4 && !q5 do emit_event(Command_Event{request_id = request_id, caller = caller, version = state.version, changed = changed, command = cmd, result = r})
	return r
}

// Capabilities, from the command table (command_table.odin): panel callers
// (pi tabs) may query, report their own tab's pi session and status, and
// publish their own tab's panels (nobody else may: not control, not
// scripts). Settings that bound agents are user-only. The control caller
// drives pi tabs through pi_prompt/pi_reload/pi_wait_idle, never reports.
caller_may :: proc(caller: Caller, cmd: Command) -> bool {
	spec := command_spec(command_type(cmd))
	if spec == nil || !who_allows(caller.kind, spec.who) do return false
	// a pi tab reports and publishes only for itself
	if caller.kind == .Panel {
		#partial switch c in cmd {
		case Pi_Session_Update: return caller.tab_id == c.tab_id
		case Pi_Status_Update:  return caller.tab_id == c.tab_id
		case Panel_Set:         return caller.tab_id == c.tab_id
		case Panel_Remove:      return caller.tab_id == c.tab_id
		case Pi_Attached:       return caller.tab_id == c.tab_id
		}
	}
	return true
}

// Whether `tab_id` is the caller's own tab or in its own session: a caller
// bound to a tab (a pi tab's bridge, Home's control token) never closes,
// reloads, prompts or types into itself.
owns_tab :: proc(caller: Caller, tab_id: u64) -> bool {
	if caller.tab_id == 0 do return false
	if tab_id == caller.tab_id do return true
	own, _, _ := find_tab(caller.tab_id)
	s, _, _ := find_tab(tab_id)
	return own != nil && own == s
}

owns_session :: proc(caller: Caller, session: u64) -> bool {
	if caller.tab_id == 0 do return false
	own, _, _ := find_tab(caller.tab_id)
	return own != nil && own.id == session
}

// How `caller` confirms commands of `class`: the app itself never asks; the
// user (ui) confirms in the UI; agents and scripts follow the user's settings.
confirm_mode :: proc(caller: Caller, class: Command_Class) -> Confirm_Mode {
	switch caller.kind {
	case .Internal: return .Auto
	case .UI:       return .Ask
	case .Script, .Control, .Panel:
		return state.settings.confirm[caller.kind][class]
	case .App:
		return .Ask
	}
	return .Ask
}

// Whether closing this running tab should ask (Settings.confirm_close).
close_needs_confirm :: proc(tab: Tab) -> bool {
	if tab.status != .Running do return false
	switch state.settings.confirm_close[tab_kind_id(tab.kind)] {
	case .Always: return true
	case .Never:  return false
	case .Auto:
		switch _ in tab.kind {
		case Pi_Tab:
			// unknown until the bridge reports pi.status: ask to be safe
			return tab.agent == .Unknown || tab.agent == .Working || tab.waiting
		case Shell_Tab:
			t := term_of(tab.id)
			return t != nil && pty_foreground_busy(&t.pty)
		case Editor_Tab:
			return editor_dirty(editor_of(tab.id)) // unsaved changes
		case Changes_Tab, Browser_Tab:
			return false // nothing of its own to lose
		case Markdown_Tab:
			return false // read-only: nothing to lose
		case App_Tab:
			return false // closing asks the app to quit (tab.quit) first
		}
	}
	return true
}

@(private = "file")
apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	switch c in cmd {
	case Add_Project:
		if c.cwd == "" do return fail("cwd is empty"), false
		want := c.cwd
		if !filepath.is_abs(want) {
			wd, err := os.get_working_directory(context.temp_allocator)
			if err != nil do return fail("cwd must be an absolute path"), false
			want, _ = filepath.join({wd, want}, context.temp_allocator)
		}
		want, _ = filepath.clean(want, context.temp_allocator)
		// pi runs in the real folder (its cwd, and so its store dir, has no
		// symlinks): the project, its pins and hidden entry use that path too
		want = real_path(want)
		if c := chats_project(); c != nil && c.cwd == want do return fail("that folder is where chats run: they are in the Chats section"), false
		p := project_by_cwd(want)
		if p == nil {
			cwd := strings.clone(want)
			inject_at(&state.projects, 0, Project{id = new_id(), cwd = cwd, label = short_label(cwd), added = time.now(), missing = !os.exists(cwd), repo = is_repo_root(cwd)}) // label may be cwd itself
			p = &state.projects[0]
		}
		p.by_hand = true // a top-level row (project_tidy.odin)
		list_remove(&state.sidebar.hidden_projects, p.cwd) // adding it again shows it
		select_project(p^)
		return {ok = true, created_id = p.id}, true
	case Select_Project:
		p := find_project(c.project_id)
		if p == nil do return fail("no such project"), false
		if p.group == .Chats do return fail(CHATS_NOT_A_PROJECT), false
		select_project(p^)
		return {ok = true}, true
	case Rename_Project:
		p := find_project(c.project_id)
		if p == nil do return fail("no such project"), false
		if p.group == .Chats do return fail(CHATS_NOT_A_PROJECT), false
		p.name = strings.clone(strings.trim_space(c.name))
		return {ok = true}, true
	case Open_Session_Cmd:
		p := find_project(c.project_id)
		if p == nil do return fail("no such project"), false
		if c.pi_session_id == "" do return fail("pi_session_id is empty"), false
		for s in state.open_sessions {
			if s.home do continue
			if s.pi_session_id == c.pi_session_id && (s.cwd == p.cwd || s.project_id == p.id) {
				focus_session(s.id)
				return {ok = true, created_id = s.id}, true
			}
		}
		path := find_session_file(p^, c.pi_session_id)
		if path == "" do return fail("no such session in this project"), false
		return open_new_session(p^, c.pi_session_id, path)
	case New_Chat:
		p := find_project(c.project_id)
		if p == nil do return fail("no such project"), false
		return open_new_session(p^, new_uuid(), "")
	case Worktree_Session:
		p := find_project(c.project_id)
		at, err := wt_session_check(p, c.path, listed = true)
		if err != "" do return fail(err), false
		if at == fs_real(p.cwd) do return open_new_session(p^, new_uuid(), "")
		// kept with the project's sessions (its store), running in the checkout
		return open_new_session(p^, new_uuid(), "", cwd = at, session_dir = p.dir != "" ? p.dir : pi_store_dir(p.cwd))
	case Focus_Session:
		s := find_session(c.session)
		if s == nil do return fail("no such session"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		focus_session(c.session)
		return {ok = true}, true
	case Close_Session:
		s := find_session(c.session)
		if s == nil do return fail("no such session"), false
		if s.home do return fail("Home cannot be closed"), false
		if owns_session(caller, s.id) do return fail("a caller cannot close its own session"), false
		// comments not sent to its pi yet: the user picks (close prompt), others say what to do
		if cr, go_on, cch := comments_close_check(s, 0, c.comments, caller); !go_on do return cr, cch
		busy := false
		for tab in s.tabs do if close_needs_confirm(tab) do busy = true
		if busy || c.ask {
			what := busy ? "close session %q in %s? Its processes are still running." : "close session %q in %s?"
			gr, go_on, ch := confirm_gate(cmd, .Tab_Close, caller, c.confirm, fmt.tprintf(what, summary_title(s), session_project_name(s)))
			if !go_on do return gr, ch
		}
		close_session(s.id)
		return {ok = true}, true
	case New_Shell_Tab:
		s := find_session(c.session)
		if s == nil do return fail("no such session"), false
		if s.home do return fail("Home has only its pi tab"), false
		cwd := s.cwd
		if c.cwd != "" {
			p, _, err := fs_check(c.cwd, caller, allow_root = true)
			if err != "" && wt_known_checkout(fs_abs(c.cwd, caller)) do p, err = fs_real(fs_abs(c.cwd, caller)), "" // a worktree of a project
			if err != "" do return fail(err), false
			if path_kind(p) != .Dir do return fail("not a folder"), false
			cwd = p
		}
		tab := Tab{id = new_id(), kind = Shell_Tab{}, title = fmt.aprintf("shell %d", len(s.tabs))}
		if cwd != s.cwd do tab.cwd = strings.clone(cwd)
		t := new_term(tab.id)
		if !term_start(t, {login_shell(), "-l"}, cwd) {
			drop_term(tab.id)
			return fail("could not start the shell"), false
		}
		append(&s.tabs, tab)
		s.active_tab = tab.id
		focus_session(s.id)
		return {ok = true, created_id = tab.id}, true
	case Close_Tab:
		s, tab, i := find_tab(c.tab_id)
		if tab == nil do return fail("no such tab"), false
		if i == 0 do return fail("a session's pi tab cannot be closed"), false
		if owns_tab(caller, c.tab_id) do return fail("a caller cannot close its own tab"), false
		// comments made on it, not sent yet: the user picks send or drop in the close prompt, others say
		if cr, go_on, cch := comments_close_check(s, tab.id, c.comments, caller); !go_on do return cr, cch
		if close_needs_confirm(tab^) {
			why := "Its process is still running."
			if _, is_ed := tab.kind.(Editor_Tab); is_ed do why = "Its unsaved changes will be lost."
			gr, go_on, ch := confirm_gate(cmd, .Tab_Close, caller, c.confirm, fmt.tprintf("close %q in %s? %s", tab.title, session_where(s), why))
			if !go_on do return gr, ch
		}
		comments_close_act(s, tab.id, c.comments) // send or drop them (the close is going ahead)
		drop_term(tab.id)
		forget_confirmations_for(tab.id)
		socket_forget_tab(tab.id)
		tab_clear_panels(tab)
		delete(tab.panels)
		ordered_remove(&s.tabs, i)
		if s.active_tab == c.tab_id do s.active_tab = s.tabs[min(i, len(s.tabs) - 1)].id
		return {ok = true}, true
	case Focus_Tab:
		s, tab, _ := find_tab(c.tab_id)
		if tab == nil do return fail("no such tab"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		s.active_tab = tab.id
		focus_session(s.id)
		return {ok = true}, true
	case Copy_Selection:
		_, tab, _ := find_tab(c.tab_id)
		t := tab != nil ? term_of(tab.id) : nil
		if t == nil do return fail("no such terminal tab"), false
		text := term_selection_text(t)
		if text == "" do return fail("nothing selected"), false
		if platform.set_clipboard != nil do platform.set_clipboard(text)
		return {ok = true}, false // side effect only
	case Send_Text:
		s, tab, _ := find_tab(c.tab_id)
		if owns_tab(caller, c.tab_id) do return fail("a caller cannot act on its own tab"), false
		t := tab != nil ? term_of(tab.id) : nil
		if t == nil do return fail("no such terminal tab"), false
		if caller.kind == .Control {
			// keystrokes into pi bypass its prompt handling; and a session
			// whose pi waits for the user is the user's to answer
			if _, is_pi := tab.kind.(Pi_Tab); is_pi do return fail("send prompts to a pi tab with pi_prompt, not send_text"), false
			if pt := session_pi_tab(s); pt != nil && pt.waiting do return fail("pi in this session is waiting for the user"), false
			// only at a shell prompt: never into whatever runs there (ssh, sudo, rm -i, a pi)
			if pty_foreground_busy(&t.pty) do return fail("a program is running in this tab; control callers type only at a shell prompt"), false
		}
		if tab.status != .Running do return fail("the tab's process has exited"), false
		term_paste(t, c.text)
		return {ok = true}, false // the child's screen changes, not State
	case Set_Focus:
		if c.widget != "" && !is_widget(c.widget) do return fail("no such widget"), false
		if state.focus_widget == "agent_input" && caller.kind == .Control do return fail("the agent's terminal has the keyboard"), false
		if c.widget == "agent_input" && caller.kind != .UI && caller.kind != .Internal do return fail("only the user moves the keyboard into the agent's terminal"), false
		if c.widget == "agent_input" && !state.home_open do return fail("the agent's drawer is shut"), false
		// the overlays that take the user's keys (Space/Enter run settings) open for the user only
		if (c.widget == "palette" || c.widget == "settings" || c.widget == "shortcuts" || c.widget == "notifications" || c.widget == "setup" || c.widget == "job_sheet") && caller.kind != .UI && caller.kind != .Internal do return fail("only the user opens the palette, settings, shortcuts, notifications and setup"), false
		// the job sheet is modal: it closes by its own Save / Cancel (job_sheet)
		if job_sheet_open() && c.widget != "job_sheet" do return fail("the job sheet is open (save or cancel it first)"), false
		if c.widget == "job_sheet" && !job_sheet_open() do return fail("the job sheet opens with job_sheet"), false
		if c.widget == state.focus_widget do return {ok = true}, false
		if c.widget == "setup" do setup_begin() // the first-run sheet starts at step 1 (ui_setup.odin)
		state.focus_widget = strings.clone(c.widget)
		if c.widget == "sidebar_filter" || c.widget == "rename_project" do state.layout.left_open = true // its field must show
		if c.widget == "sidebar_filter" || c.widget == "rename_project" do state.layout.left_tab = .Sessions
		if strings.has_prefix(c.widget, "files") {
			state.layout.left_open = true
			if state.layout.left_tab == .Sessions do state.layout.left_tab = .Files // the Settings tab is a tree too
		}
		return {ok = true}, true
	case Set_Layout:
		l := &state.layout
		if w, ok := c.left_width.?; ok do l.left_width = clamp(w, LEFT_MIN, LEFT_MAX)
		if w, ok := c.right_width.?; ok do l.right_width = clamp(w, RIGHT_MIN, RIGHT_MAX)
		if o, ok := c.left_open.?; ok do l.left_open = o
		if o, ok := c.right_open.?; ok do l.right_open = o
		if w, ok := c.drawer_width.?; ok do l.drawer_width = clamp(w, DRAWER_WIDTH_MIN, DRAWER_WIDTH_MAX)
		if p, ok := c.drawer_pinned.?; ok do l.drawer_pinned = p
		return {ok = true}, true
	case Set_Panel:
		if c.panel == "" do return fail("panel is empty"), false
		l := &state.layout
		at := -1
		for p, i in l.panels do if p == c.panel do at = i
		if c.open && at < 0 do append(&l.panels, strings.clone(c.panel))
		if !c.open && at >= 0 do ordered_remove(&l.panels, at)
		if c.open do l.right_open = true
		return {ok = true}, true
	case Cancel_Confirmation:
		for p, i in state.pending_confirmations {
			if p.token == c.token {
				ordered_remove(&state.pending_confirmations, i)
				return {ok = true}, true
			}
		}
		return fail("unknown confirmation token"), false
	case Rescan:
		if scan_thread != nil do return fail("a rescan is already running"), false
		scan_thread = thread.create_and_start_with_poly_data(request_id, scan_worker)
		return {ok = true, pending = true}, false
	case Rescan_Done:
		thread.join(scan_thread)
		thread.destroy(scan_thread)
		scan_thread = nil
		apply_scan(c.scan)
		emit_event(Finished_Event{request_id = c.request_id, result = {ok = true}})
		return {ok = true}, true
	case Quit:
		if job_sheet_holds_quit() do return fail("the job sheet has changes: discard them first (Cancel or Esc), then quit"), true
		if any_running() {
			what := "quit pi-desk? Running sessions will be stopped."
			if n := editors_unsaved(); n > 0 do what = fmt.tprintf("quit pi-desk? Running sessions will be stopped, and %d file%s with unsaved changes will be lost.", n, n == 1 ? "" : "s")
			gr, go_on, ch := confirm_gate(cmd, .App_Quit, caller, c.confirm, what)
			if !go_on do return gr, ch
		}
		if platform.quit != nil do platform.quit()
		return {ok = true}, false
	case Get_State:
		// a pi tab sees only its own session (PROTOCOL.md §2)
		if caller.kind == .Panel do return {ok = true, data = session_state_json(caller.tab_id)}, false
		return {ok = true, data = state_json()}, false
	case List_Commands:
		return {ok = true, data = list_commands_json(caller)}, false
	case Set_Home:
		// the drawer and the keyboard are the user's: the agent cannot hide
		// itself, other agents cannot hide it either
		if caller.kind == .Panel || home_bound(caller) || (caller.kind == .Control && !c.open) do return fail("only the user shows or hides the agent's drawer"), false
		if !c.open {
			if !state.home_open do return {ok = true}, false
			state.home_open = false
			if state.focus_widget == "agent_input" do state.focus_widget = ""
			return {ok = true}, true
		}
		if state.home == 0 {
			if home_root == "" do return fail("the agent is not available (no data dir)"), false
			s := Open_Session {
				id            = new_id(),
				pi_session_id = new_uuid(),
				session_dir   = home_dir(),
				cwd           = home_cwd(),
				home          = true,
			}
			append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "Home", status = .Not_Started})
			s.active_tab = s.tabs[0].id
			append(&state.open_sessions, s)
			state.home = s.id
		}
		hs := home_session()
		ht := session_pi_tab(hs)
		state.agent.unread = 0
		if ht.status == .Exited {
			drop_term(ht.id) // starts again, resuming its session
			forget_confirmations_for(ht.id) // the old agent's requests die with it
			agent_picker = {} // the selector asked of the old pi
			ht.status = .Not_Started
			ht.agent, ht.waiting = .Unknown, false
		}
		start_restored_tabs(hs)
		state.home_open = true
		// its terminal has the keyboard, when the user opens it (only the user
		// moves the keyboard there; a script's open leaves it where it is)
		if caller.kind == .UI || caller.kind == .Internal do state.focus_widget = "agent_input"
		if ht.status != .Running do return {ok = false, error = "could not start the agent's pi", created_id = ht.id}, true
		return {ok = true, created_id = ht.id}, true
	case Set_Pinned:
		key, is_project, err := sidebar_target(c.cwd, c.project_id, c.pi_session_id, !c.pinned)
		if err != "" do return fail(err), false
		list := is_project ? &state.sidebar.pinned_projects : &state.sidebar.pinned_sessions
		at := list_index(list[:], key)
		if !c.pinned do return {ok = true}, list_remove(list, key)
		to, has := c.index.?
		if at >= 0 {
			if !has do return {ok = true}, false
			to = clamp(to, 0, len(list) - 1)
			if to == at do return {ok = true}, false
			k := list[at]
			ordered_remove(list, at)
			inject_at(list, to, k)
			return {ok = true}, true
		}
		if !sidebar_make_room(list, is_project) do return fail(fmt.tprintf("too many pinned items (max %d)", SIDEBAR_LIST_MAX)), false
		inject_at(list, has ? clamp(to, 0, len(list)) : len(list), strings.clone(key))
		return {ok = true}, true
	case Set_Hidden:
		key, is_project, err := sidebar_target(c.cwd, c.project_id, c.pi_session_id, !c.hidden)
		if err != "" do return fail(err), false
		list := is_project ? &state.sidebar.hidden_projects : &state.sidebar.hidden_sessions
		if !c.hidden do return {ok = true}, list_remove(list, key)
		if list_index(list[:], key) >= 0 do return {ok = true}, false
		if !sidebar_make_room(list, is_project) do return fail(fmt.tprintf("too many hidden items (max %d)", SIDEBAR_LIST_MAX)), false
		append(list, strings.clone(key))
		return {ok = true}, true
	case Set_Sort:
		if state.sidebar.sort[c.section] == c.by do return {ok = true}, false
		state.sidebar.sort[c.section] = c.by
		return {ok = true}, true
	case Set_Sidebar_Folded:
		if state.sidebar.folded[c.section] == c.folded do return {ok = true}, false
		state.sidebar.folded[c.section] = c.folded
		return {ok = true}, true
	case Set_Row_Expanded:
		if !strings.has_prefix(c.path, "/") do return fail("path must be absolute"), false
		list := &state.sidebar.expanded
		if !c.expanded do return {ok = true}, list_remove(list, c.path)
		if list_index(list[:], c.path) >= 0 do return {ok = true}, false
		if len(list) >= SIDEBAR_LIST_MAX {
			delete(list[0])
			ordered_remove(list, 0)
		}
		append(list, strings.clone(c.path))
		return {ok = true}, true
	case Set_Filter:
		sb := &state.sidebar
		ch := false
		if text, ok := c.text.?; ok {
			text = cut_utf8(one_line(text, context.temp_allocator), FILTER_MAX)
			if text != sb.filter {
				delete(sb.filter)
				sb.filter = strings.clone(text)
				ch = true
			}
		}
		set :: proc(field: ^bool, v: Maybe(bool), ch: ^bool) {
			if b, ok := v.?; ok && b != field^ {
				field^ = b
				ch^ = true
			}
		}
		set(&sb.only_running, c.running, &ch)
		set(&sb.only_waiting, c.waiting, &ch)
		set(&sb.only_pinned, c.pinned, &ch)
		set(&sb.show_hidden, c.show_hidden, &ch)
		return {ok = true}, ch
	case Reveal_Path:
		path, err := sidebar_path(c.project_id, c.pi_session_id)
		if err != "" do return fail(err), false
		if platform.reveal != nil do platform.reveal(path)
		return {ok = true}, false // side effect only
	case Session_Info:
		return session_info_apply(c, caller)
	case Job_Sheet:
		return job_sheet_apply(c, caller)
	case Copy_Path:
		path, err := sidebar_path(c.project_id, c.pi_session_id)
		if err != "" do return fail(err), false
		if platform.set_clipboard != nil do platform.set_clipboard(path)
		return {ok = true}, false
	case Restore_Sidebar:
		sb := &state.sidebar
		lists := [4]^[dynamic]string{&sb.pinned_projects, &sb.pinned_sessions, &sb.hidden_projects, &sb.hidden_sessions}
		from := [4][]string{c.pinned_projects, c.pinned_sessions, c.hidden_projects, c.hidden_sessions}
		for l, i in lists {
			for x in l do delete(x)
			clear(l)
			for v in from[i] {
				if v == "" || len(l) >= SIDEBAR_LIST_MAX || list_index(l[:], v) >= 0 do continue
				if i % 2 == 0 && !strings.has_prefix(v, "/") do continue // project cwds are absolute
				append(l, strings.clone(v))
			}
		}
		return {ok = true}, true
	case Set_Chats_Readonly:
		if state.settings.chats_readonly == c.on do return {ok = true}, false
		state.settings.chats_readonly = c.on
		return {ok = true}, true
	case Set_Agent_Name:
		name := strings.clone(cut_utf8(strings.trim_space(one_line(c.name, context.temp_allocator)), AGENT_NAME_MAX))
		if name == state.settings.agent_name {
			delete(name)
			return {ok = true}, false
		}
		delete(state.settings.agent_name)
		state.settings.agent_name = name
		return {ok = true}, true
	case Set_Agent_Model:
		model := strings.trim_space(c.model)
		if model != "" && !agent_model_valid(model) do return fail(`model must be "provider/id" (optionally ":thinking")`), false
		if model == state.settings.agent_model do return {ok = true}, false
		delete(state.settings.agent_model)
		state.settings.agent_model = strings.clone(model)
		return {ok = true}, true // Atlas uses it from its next start
	case Agent_Model_Picker:
		// the drawer shows with the keyboard in Atlas's terminal, then pi's
		// model selector opens there (once pi is up, if it is just starting)
		r := run_command(Set_Home{open = true}, caller)
		if !r.ok do return r, true
		state.focus_widget = "agent_input"
		ht := home_tab()
		if ht == nil || ht.status != .Running do return fail("the agent's pi is not running"), true
		// Ctrl+L would land in pi's open dialog
		if ht.waiting do return fail(fmt.tprintf("%s is waiting for you", agent_name())), true
		if ht.agent != .Unknown {
			if !agent_open_model_picker() do return fail("the agent's pi is not running"), true
			return {ok = true}, true
		}
		// pi is starting: the selector opens at its first status, if it comes
		// soon (no desk-bridge: it never does)
		if time.tick_since(agent_started) > PICKER_WAIT {
			agent_picker = {}
			return fail(fmt.tprintf("%s's pi reports no status (pi-kit's desk-bridge): press Ctrl+L in its terminal", agent_name())), true
		}
		agent_picker = {tab = ht.id, deadline = time.tick_add(agent_started, PICKER_WAIT)}
		return {ok = true}, true
	case Set_Notify:
		if state.settings.notify_off == !c.on do return {ok = true}, false
		state.settings.notify_off = !c.on
		return {ok = true}, true
	case Set_Tidy_Projects:
		if state.settings.tidy_off == !c.on do return {ok = true}, false
		state.settings.tidy_off = !c.on
		return {ok = true}, true // projects_tidy runs after (run_command)
	case Set_Confirm_Policy:
		if c.caller == .UI || c.caller == .Internal do return fail("ui and internal callers have fixed policies"), false
		state.settings.confirm[c.caller][c.class] = c.mode
		return {ok = true}, true
	case Set_Close_Confirm:
		state.settings.confirm_close[c.tab_kind] = c.rule
		return {ok = true}, true
	case Set_Terminal_Text_Size:
		if c.pt != 0 && (c.pt < TERM_TEXT_MIN || c.pt > TERM_TEXT_MAX) do return fail(fmt.tprintf("pt must be 0 (the look's) or %d-%d", TERM_TEXT_MIN, TERM_TEXT_MAX)), false
		pt := c.pt == TYPE_CODE_PX ? 0 : c.pt
		if state.settings.term_text_pt == pt do return {ok = true}, false
		state.settings.term_text_pt = pt // the frame loop opens the fonts again (main.odin)
		return {ok = true}, true
	case Set_Theme:
		if state.settings.theme == c.name do return {ok = true}, false
		state.settings.theme = c.name
		for _, t in terms do term_apply_theme(t)
		return {ok = true}, true
	case Set_Appearance:
		if state.settings.appearance == c.mode do return {ok = true}, false
		was := theme_is_light()
		state.settings.appearance = c.mode
		if platform.set_appearance != nil do platform.set_appearance(c.mode)
		if theme_is_light() != was do for _, t in terms do term_apply_theme(t)
		return {ok = true}, true
	case System_Appearance:
		if state.system_light == c.light do return {ok = true}, false
		was := theme_is_light()
		state.system_light = c.light
		if theme_is_light() != was do for _, t in terms do term_apply_theme(t)
		return {ok = true}, true
	case Set_Reduce_Motion:
		if state.settings.reduce_motion == c.on do return {ok = true}, false
		state.settings.reduce_motion = c.on
		return {ok = true}, true
	case Set_Text_Size:
		// the frame applies it (main.odin: fonts_apply when it changed)
		if state.settings.text_size == c.size do return {ok = true}, false
		state.settings.text_size = c.size
		return {ok = true}, true
	case Tab_Exited:
		ts, tab, _ := find_tab(c.tab_id)
		if tab == nil || tab.status == .Exited do return {ok = true}, false
		notify_tab_exited(ts, tab) // the bell (notify.odin)
		tab.status = .Exited
		if agent_picker.tab == tab.id do agent_picker = {}
		agent_pending_drop(tab.id) // Send to Atlas text waiting for it (session_info.odin)
		tab_clear_panels(tab) // nobody publishes them any more
		forget_confirmations_for(tab.id) // nothing left to confirm
		socket_forget_tab(tab.id) // its token dies with the process
		if _, is_pi := tab.kind.(Pi_Tab); is_pi do comments_pi_exited(ts) // pending comments wait for the next pi
		return {ok = true}, true
	case Pi_Session_Update:
		s, tab := pi_tab(c.tab_id)
		if tab == nil do return fail("no such pi tab"), false
		if c.pi_session_id == "" do return fail("pi_session_id is empty"), false
		for o in state.open_sessions do if o.id != s.id && o.pi_session_id == c.pi_session_id do return fail("this pi session is open in another tab"), false
		delete(s.pi_session_id)
		delete(s.session_file)
		s.pi_session_id = strings.clone(c.pi_session_id)
		s.session_file = strings.clone(c.session_file)
		delete(s.title)
		s.title, s.title_size = "", -1
		s.checked = {} // read the new file at once
		refresh_listing(s)
		comments_bridge_hello(s) // a new connection holds no comments: send them again
		return {ok = true}, true
	case Pi_Status_Update:
		ps, tab := pi_tab(c.tab_id)
		if tab == nil do return fail("no such pi tab"), false
		// unknown: only pi-desk itself, when the tab's last bridge connection is gone
		if c.agent == .Unknown && caller.kind != .Internal do return fail("agent must be idle, working or error"), false
		// a turn ended: a new chat's file exists now, list it
		if c.agent == .Idle && tab.agent != .Idle do refresh_listing(ps)
		if ps.home {
			agent_status_changed(tab.agent, tab.waiting, c.agent, c.waiting)
			if c.agent != .Unknown {
				// pi is up: a model selector asked for while it started opens
				// now, unless a dialog would take the key or it waited too long
				picker := false
				if agent_picker.tab == tab.id {
					in_time := time.tick_diff(time.tick_now(), agent_picker.deadline) > 0
					agent_picker = {}
					if in_time && !c.waiting {
						agent_open_model_picker()
						picker = true
					}
				}
				agent_pending_status(tab.id, c.waiting, picker) // Send to Atlas while it started (session_info.odin)
				// it runs: the model it started with took (pi exits at once on
				// an unknown one, so a failed --model is passed again next start)
				if agent_model_starting != state.home_model {
					delete(state.home_model)
					state.home_model = strings.clone(agent_model_starting)
				}
			}
		}
		notify_pi_status(ps, tab, c.agent, c.waiting, c.question) // the bell (notify.odin)
		was := tab.agent
		tab.agent = c.agent
		tab.waiting = c.waiting
		tab.question = c.question
		for b in tab.blockers do delete(b)
		clear(&tab.blockers)
		for b in c.blockers do append(&tab.blockers, strings.clone(b))
		reload_status_changed(tab) // a reload or restart waiting for idle goes now (reload.odin)
		// unknown = the last bridge connection is gone: its panels go too
		// (the bridge publishes them again after it reconnects)
		if c.agent == .Unknown do tab_clear_panels(tab)
		comments_bridge_status(ps, was, c.agent) // pending comments: the bridge went away, or is back
		return {ok = true}, true
	case Panel_Set:
		_, tab := pi_tab(c.tab_id)
		if tab == nil do return fail("no such pi tab"), false
		if tab.status != .Running do return fail("the tab's process has exited"), false
		id := one_line(c.panel, context.temp_allocator)
		if r, bad := check_panel_id(id); bad do return r, false
		at := -1
		used := 0 // rows of the tab's other panels
		for p, i in tab.panels {
			if p.id == id do at = i
			else do used += len(p.rows)
		}
		if at < 0 && len(tab.panels) >= PANELS_MAX do return fail(fmt.tprintf("too many panels (max %d)", PANELS_MAX)), false
		p := Panel{id = strings.clone(id), title = strings.clone(cut_utf8(one_line(c.title, context.temp_allocator), PANEL_TITLE_MAX))}
		n := clamp(PANEL_ROWS_MAX - used, 0, len(c.rows))
		for row in c.rows[:n] do append(&p.rows, Panel_Row{text = strings.clone(cut_utf8(one_line(row.text, context.temp_allocator), PANEL_TEXT_MAX)), tone = row.tone, head = row.head})
		if len(c.rows) > n do append(&p.rows, Panel_Row{text = fmt.aprintf("+%d more", len(c.rows) - n), tone = .Muted})
		if at >= 0 {
			panel_free(&tab.panels[at])
			tab.panels[at] = p
		} else do append(&tab.panels, p)
		return {ok = true}, true
	case Panel_Remove:
		_, tab := pi_tab(c.tab_id)
		if tab == nil do return fail("no such pi tab"), false
		id := one_line(c.panel, context.temp_allocator)
		if r, bad := check_panel_id(id); bad do return r, false
		for &p, i in tab.panels {
			if p.id != id do continue
			panel_free(&p)
			ordered_remove(&tab.panels, i)
			return {ok = true}, true
		}
		return {ok = true}, false // already gone
	case Set_Panel_Collapsed:
		id := one_line(c.panel, context.temp_allocator)
		if r, bad := check_panel_id(id); bad do return r, false
		l := &state.layout
		at := -1
		for p, i in l.collapsed do if p == id do at = i
		if c.collapsed == (at >= 0) do return {ok = true}, false
		if c.collapsed {
			if len(l.collapsed) >= COLLAPSED_MAX { 	// forget the oldest
				delete(l.collapsed[0])
				ordered_remove(&l.collapsed, 0)
			}
			append(&l.collapsed, strings.clone(id))
		} else {
			delete(l.collapsed[at])
			ordered_remove(&l.collapsed, at)
		}
		return {ok = true}, true
	case Pi_Prompt:
		_, tab := pi_tab(c.tab_id)
		if r, bad := bridge_target(tab, caller); bad do return r, false
		if tab.waiting do return fail("pi is waiting for the user"), false
		if err := prompt_images_check(c.images); err != "" do return fail(err), false
		if !socket_bridge_send(c.tab_id, request_id, cmd) do return fail("no bridge connected for this tab"), false
		return {ok = true, pending = true}, false
	case Pi_Reload:
		rs, tab := pi_tab(c.tab_id)
		if rs != nil && rs.home && agent_picker.tab == c.tab_id do agent_picker = {} // pi starts over
		if r, bad := bridge_target(tab, caller); bad do return r, false
		what := rs != nil && rs.home ? fmt.tprintf("restart %s? Its pi reloads (prompt, settings, extensions); the session stays.", agent_name()) : fmt.tprintf("reload pi in %s?", session_where(rs))
		what = strings.concatenate({what, reload_blockers_note(tab)}, context.temp_allocator)
		gr, go_on, ch := confirm_gate(cmd, .Session_Restart, caller, c.confirm, what)
		if !go_on do return gr, ch
		if !socket_bridge_send(c.tab_id, request_id, cmd) do return fail("no bridge connected for this tab"), ch
		reload_sent(tab, request_id) // hot reload's bookkeeping (reload.odin)
		return {ok = true, pending = true}, true
	case Pi_Wait_Idle:
		_, tab := pi_tab(c.tab_id)
		if r, bad := bridge_target(tab, caller); bad do return r, false
		if !socket_bridge_send(c.tab_id, request_id, cmd) do return fail("no bridge connected for this tab"), false
		return {ok = true, pending = true}, false
	case Bridge_Done:
		reload_bridge_done(c) // a reload of the hot-reload bar finished (reload.odin)
		sent := comments_bridge_done(c.request_id, c.ok) // Send now's pi.prompt (comments.odin)
		emit_event(Finished_Event{request_id = c.request_id, result = {ok = c.ok, error = c.error}})
		return {ok = true}, sent
	case Open_File, Editor_State, Save_File, Goto_Line, Reload_File, Keep_Buffer, Diff_File, Set_Wrap, List_Dir, Create_File, Create_Dir, Rename_Path, Delete_Path, Reveal_In_Finder, Keep_Tab, Git_Head_Done, Git_Status_Done, File_List_Done:
		return editor_apply(cmd, caller)
	case Set_Left_Tab, Files_Expand, Files_Collapse_All, Files_Reveal, Set_Files_Filter:
		return files_apply(cmd, caller)
	case List_Worktrees, Files_Set_Root, Worktree_Cleanup, Worktree_Cleanup_Done, Worktrees_Done:
		return worktrees_apply(cmd, caller, request_id)
	case Changes_Open, Changes_List, Changes_Stage, Changes_Unstage, Changes_Discard, Changes_Commit, Changes_Scan_Done, Changes_Diff_Done, Changes_Op_Done:
		return changes_apply(cmd, caller, request_id)
	case Markdown_Open, Markdown_Set_View, Markdown_Scroll, Markdown_Follow:
		return markdown_apply(cmd, caller)
	case Terminal_Link:
		return term_link_apply(c, caller)
	case New_App_Tab, App_Restart, App_Input, App_Events, App_Call, App_Call_Done, App_Update, App_Screenshot, App_Inspect:
		return app_apply(cmd, caller, request_id)
	case Comment_Add, Comment_Edit, Comment_Delete, Comments_Clear, Comments_Send_Now, Comments_Ask_Cancel, Pi_Attached:
		return comments_apply(cmd, caller, request_id)
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update:
		if r, refused := browser_agent_nav_refused(cmd, caller); refused do return r, false // Take over (browser_agent.odin)
		r, ch := browser_nav_apply(cmd, caller)
		browser_agent_nav_ran(cmd, caller, r) // the agent strip; a load wait's navigation (browser_agent.odin)
		return r, ch
	case Browser_Zoom, Browser_Find, Browser_Find_Close, Browser_Dialog, Browser_Permission, Browser_Popup, Browser_Edit, Browser_Devtools, Browser_External, Browser_Download:
		return browser_polish_apply(cmd, caller)
	case Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop:
		return browser_agent_apply(cmd, caller, request_id)
	case Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel:
		return browser_act_apply(cmd, caller, request_id)
	case Notifications_List, Notifications_Mark_Read, Notifications_Clear, Notify_Post, Set_Bell:
		return notify_apply(cmd, caller)
	case Update_Check, Update_Skip, Update_Later, Update_Download, Update_Install, Set_Update_Check, Update_Env, Update_Tick, Update_Checked, Update_Prepared:
		return update_apply(cmd, caller)
	case Set_Home_Dir, Set_Folder, Setup_Sheet:
		return folders_apply(cmd, caller)
	case Job_List, Job_Runs, Job_Run_Now, Job_Stop, Jobs_Pause, Jobs_Resume, Job_Create, Job_Save, Job_Mark_Read, Job_Set_Enabled, Job_Delete, Job_Open, Set_Pi_Path, Set_Job_Limits, Jobs_Sync, Jobs_Tick, Job_Run_Done, Jobs_Env:
		return jobs_apply(cmd, caller)
	case Pi_Reload_All, Pi_Restart_Updated, Pi_Reload_Later, Reload_Watch, Reload_Kick:
		return reload_apply(cmd, caller, request_id)
	case Restore_Session:
		if c.home {
			if state.home != 0 do return fail("Home is already there"), false
			if c.pi_session_id == "" do return fail("pi_session_id is empty"), false
			if home_root == "" do return fail("Home is not available (no data dir)"), false
			s := Open_Session{id = new_id(), pi_session_id = strings.clone(c.pi_session_id), session_dir = home_dir(), cwd = home_cwd(), home = true, restored = true}
			append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "Home", status = .Not_Started})
			s.active_tab = s.tabs[0].id
			append(&state.open_sessions, s)
			state.home = s.id
			return {ok = true, created_id = s.id}, true
		}
		p := find_project(c.project_id)
		if p == nil do return fail("no such project"), false
		if c.pi_session_id == "" do return fail("pi_session_id is empty"), false
		for s in state.open_sessions do if !s.home && s.pi_session_id == c.pi_session_id do return fail("this session is already open"), false
		path := find_session_file(p^, c.pi_session_id, c.session_dir)
		cwd := p.cwd
		if c.cwd != "" && c.cwd != p.cwd {
			// a session in a worktree: there again while it is a checkout of the project's repository
			if at, err := wt_session_check(p, c.cwd, listed = false); err == "" do cwd = at
		}
		s := Open_Session {
			pi_session_id = strings.clone(c.pi_session_id),
			session_dir   = strings.clone(c.session_dir),
			session_file  = strings.clone(path),
			project_id    = p.id,
			cwd           = strings.clone(cwd),
			missing       = path == "" || !os.exists(cwd),
			restored      = true,
		}
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Not_Started})
		s.id = new_id()
		for rt in c.tabs {
			if rt.kind == .Editor {
				// rt.cwd is the file's path; it opens when the session starts.
				// Not a regular file now (a FIFO, a device): left out
				if !regular_or_missing(rt.cwd) do continue
				append(&s.tabs, Tab{id = new_id(), kind = Editor_Tab{path = strings.clone(rt.cwd)}, title = strings.clone(filepath.base(rt.cwd)), status = .Not_Started})
				if rt.active do s.active_tab = s.tabs[len(s.tabs) - 1].id
				continue
			}
			if rt.kind == .Markdown {
				if !regular_or_missing(rt.cwd) do continue
				append(&s.tabs, Tab{id = new_id(), kind = Markdown_Tab{path = strings.clone(rt.cwd)}, title = strings.clone(filepath.base(rt.cwd)), status = .Not_Started})
				if rt.active do s.active_tab = s.tabs[len(s.tabs) - 1].id
				continue
			}
			if rt.kind == .Browser {
				// rt.cwd is its URL; the page loads once the session is focused
				url, err := browser_url_normalize(rt.cwd)
				if err != "" do continue
				append(&s.tabs, Tab{id = new_id(), kind = Browser_Tab{url = strings.clone(url)}, title = strings.clone(rt.title != "" ? rt.title : "Browser"), status = .Not_Started})
				if rt.active do s.active_tab = s.tabs[len(s.tabs) - 1].id
				continue
			}
			if rt.kind != .Shell do continue
			title := rt.title != "" ? strings.clone(rt.title) : fmt.aprintf("shell %d", len(s.tabs))
			append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = title, status = .Not_Started, cwd = strings.clone(rt.cwd)})
			if rt.active do s.active_tab = s.tabs[len(s.tabs) - 1].id
		}
		if s.active_tab == 0 do s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
		return {ok = true, created_id = s.id}, true
	}
	return fail("unknown command"), false
}

// Policy check for a destructive command of `class`. Auto: go ahead.
// Without a token: park it and ask; the token goes only to a caller that may
// use it (the user, or a caller trusted for this class). With a token: it must
// match a parked command with the same target, and the resending caller must
// be the user or that same trusted caller.
confirm_gate :: proc(cmd: Command, class: Command_Class, caller: Caller, token, what: string, force_ask := false) -> (r: Result, proceed: bool, changed: bool) {
	mode := force_ask ? Confirm_Mode.Ask : confirm_mode(caller, class) // force_ask: the user confirms, whatever the policy
	if mode == .Auto do return {}, true, false
	summary := asked_by(caller, what)
	if token == "" {
		// asked again: the same pending entry, never a second one
		mine := 0
		for p in state.pending_confirmations {
			if p.caller != caller do continue
			mine += 1
			if !same_target(p.command, cmd) do continue
			r = {error = "needs_confirmation", confirm_summary = p.summary}
			if caller.kind == .UI || mode == .Trusted do r.confirm_token = p.token
			else do r.confirm_by_user = true
			return r, false, false
		}
		if caller.kind != .UI && mine >= PENDING_PER_CALLER do return fail(fmt.tprintf("too many confirmations waiting for this caller (max %d)", PENDING_PER_CALLER)), false, false
		p := Pending_Confirmation {
			token   = new_uuid(),
			summary = strings.clone(summary),
			command = command_clone(cmd, context.allocator),
			class   = class,
			caller  = caller,
		}
		append(&state.pending_confirmations, p)
		r = {error = "needs_confirmation", confirm_summary = p.summary}
		if caller.kind == .UI || mode == .Trusted do r.confirm_token = p.token
		else do r.confirm_by_user = true
		return r, false, true
	}
	for p, i in state.pending_confirmations {
		if p.token != token || !same_target(p.command, cmd) do continue
		by_user := caller.kind == .UI
		by_trusted := !force_ask && caller == p.caller && confirm_mode(p.caller, p.class) == .Trusted
		if !by_user && !by_trusted do return fail("only the user can confirm this, in pi-desk"), false, false
		ordered_remove(&state.pending_confirmations, i)
		return {}, true, true
	}
	return fail("unknown or expired confirmation token"), false, false
}

@(private = "file")
check_panel_id :: proc(id: string) -> (r: Result, bad: bool) {
	if id == "" do return fail("panel is empty"), true
	if len(id) > PANEL_ID_MAX do return fail(fmt.tprintf("panel id too long (max %d bytes)", PANEL_ID_MAX)), true
	return {}, false
}

// Control characters and line or paragraph separators (one_line makes them spaces).
rune_breaks_line :: proc(r: rune) -> bool {
	return r < 0x20 || (r >= 0x7f && r < 0xa0) || r == 0x2028 || r == 0x2029
}

// Characters that do not show or that reorder text: direction overrides and isolates,
// zero-width and direction marks, word joiners, deprecated format controls, BOM, interlinear
// annotation, tag characters, the Arabic letter mark, soft hyphen, Mongolian vowel separator,
// Hangul fillers, variation selectors (one_line drops them; so does download_safe_name).
rune_hidden :: proc(r: rune) -> bool {
	switch r {
	case 0x202a ..= 0x202e, 0x2066 ..= 0x2069:
		return true
	case 0x200b ..= 0x200f, 0x2060 ..= 0x2064, 0x206a ..= 0x206f, 0xfeff, 0xfff9 ..= 0xfffb, 0xe0000 ..= 0xe007f:
		return true
	case 0x061c, 0x00ad, 0x180e, 0x115f, 0x1160, 0x3164, 0xffa0, 0xfe00 ..= 0xfe0f, 0xe0100 ..= 0xe01ef:
		return true
	}
	return false
}

// s as one line for the chrome: control characters (C0, DEL, C1) become
// spaces (Clay breaks lines at \n even without wrapping) and bidi
// embeddings, overrides and isolates (U+202A–202E, U+2066–2069) are dropped,
// as are invisible characters (format controls, zero-width marks, BOM, tag
// characters, soft hyphen, Hangul fillers, variation selectors: rune_hidden),
// so a bridge or a page cannot reorder, spill or hide text. Returns s itself when clean.
one_line :: proc(s: string, allocator := context.allocator) -> string {
	clean := true
	for r in s do if rune_breaks_line(r) || rune_hidden(r) {
		clean = false
		break
	}
	if clean do return s
	b := strings.builder_make(0, len(s), allocator)
	for r in s {
		switch {
		case rune_breaks_line(r): strings.write_byte(&b, ' ') // line and paragraph separators end a line too
		case rune_hidden(r):
		case:                                                strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// s cut to at most max bytes, at a UTF-8 character boundary (no copy).
cut_utf8 :: proc(s: string, max: int) -> string {
	if len(s) <= max do return s
	i := max
	for i > 0 && s[i] & 0xC0 == 0x80 do i -= 1
	return s[:i]
}

// A confirmation's summary: who asks (when it is not the user) and what
// (`what` starts lower case: "close \"shell 1\" in app · Fix the build?").
asked_by :: proc(caller: Caller, what: string) -> string {
	who: string
	switch caller.kind {
	case .UI, .Internal:
	case .Script:  who = "A script asks"
	case .App:     who = "An app asks"
	case .Control: who = home_bound(caller) ? fmt.tprintf("%s asks", agent_name()) : "A script asks"
	case .Panel:
		s, _, _ := find_tab(caller.tab_id)
		who = fmt.tprintf("pi in %s asks", s != nil ? session_project_name(s) : "a session")
	}
	if who != "" do return fmt.tprintf("%s: %s", who, what)
	if what == "" || what[0] < 'a' || what[0] > 'z' do return what
	return fmt.tprintf("%c%s", what[0] - 32, what[1:])
}

session_project_name :: proc(s: ^Open_Session) -> string {
	if s.home do return agent_name()
	if p := find_project(s.project_id); p != nil do return project_name(p^)
	return s.cwd
}

// "project · session title", where a tab or session is.
session_where :: proc(s: ^Open_Session) -> string {
	if s == nil do return "?"
	if s.home do return agent_name()
	return fmt.tprintf("%s · %s", session_project_name(s), summary_title(s))
}

// A session title for a confirmation summary: at most SUMMARY_TITLE_MAX
// bytes, so a long one cannot push the bar's buttons out.
SUMMARY_TITLE_MAX :: 60
summary_title :: proc(s: ^Open_Session) -> string {
	t := open_session_title(s)
	if len(t) <= SUMMARY_TITLE_MAX do return t
	return fmt.tprintf("%s…", cut_utf8(t, SUMMARY_TITLE_MAX))
}

// The open session and pi tab with this id, or nil.
@(private = "file")
pi_tab :: proc(id: u64) -> (^Open_Session, ^Tab) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil
	if _, is := tab.kind.(Pi_Tab); !is do return nil, nil
	return s, tab
}

// Checks shared by the commands that go to a pi tab's bridge.
@(private = "file")
bridge_target :: proc(tab: ^Tab, caller: Caller) -> (r: Result, bad: bool) {
	if tab == nil do return fail("no such pi tab"), true
	if owns_tab(caller, tab.id) do return fail("a caller cannot act on its own tab"), true
	if tab.status != .Running do return fail("the tab's process has exited"), true
	return {}, false
}

@(private = "file")
same_target :: proc(a, b: Command) -> bool {
	#partial switch x in a {
	case Close_Tab:
		y, ok := b.(Close_Tab)
		return ok && x.tab_id == y.tab_id
	case Pi_Reload:
		y, ok := b.(Pi_Reload)
		return ok && x.tab_id == y.tab_id
	case Close_Session:
		y, ok := b.(Close_Session)
		return ok && x.session == y.session
	case Quit:
		_, ok := b.(Quit)
		return ok
	case Update_Install:
		_, ok := b.(Update_Install)
		return ok
	case Reload_File:
		y, ok := b.(Reload_File)
		return ok && x.tab_id == y.tab_id
	case Pi_Reload_All:
		y, ok := b.(Pi_Reload_All)
		return ok && x.only_changed == y.only_changed
	case Pi_Restart_Updated:
		_, ok := b.(Pi_Restart_Updated)
		return ok
	// file commands are parked with absolute paths (editor_apply resolves them first)
	case Delete_Path:
		y, ok := b.(Delete_Path)
		return ok && x.path == y.path
	case Create_File:
		y, ok := b.(Create_File)
		return ok && x.path == y.path
	case Create_Dir:
		y, ok := b.(Create_Dir)
		return ok && x.path == y.path
	case Rename_Path:
		y, ok := b.(Rename_Path)
		return ok && x.from == y.from && x.to == y.to
	case Worktree_Cleanup:
		y, ok := b.(Worktree_Cleanup)
		return ok && x.path == y.path
	case Job_Delete:
		y, ok := b.(Job_Delete)
		return ok && x.job == y.job
	case Markdown_Follow:
		y, ok := b.(Markdown_Follow)
		return ok && x.tab_id == y.tab_id && x.url == y.url
	case Changes_Discard: // parked with the listed path; the second question is its own entry
		y, ok := b.(Changes_Discard)
		return ok && x.tab_id == y.tab_id && x.path == y.path && x.status == y.status && x.second == y.second
	}
	return false
}

HOME_NOT_A_SESSION :: "the agent is not a session tab: show it with set_home"
CHATS_NOT_A_PROJECT :: "Chats is not a project: its sessions are in state.chats (new_chat with its project_id starts one)"

// The caller is the agent itself (its control token is bound to Home's tab).
home_bound :: proc(caller: Caller) -> bool {
	ht := home_tab()
	return caller.tab_id != 0 && ht != nil && caller.tab_id == ht.id
}

PENDING_PER_CALLER :: 3 // confirmations one caller (not the user) may have waiting at once

// Stops an open session's tabs and removes it (and its pending
// confirmations); the current session moves to the last other open one.
@(private = "file")
close_session :: proc(id: u64) {
	s := find_session(id)
	if s == nil do return
	for &tab in s.tabs {
		drop_term(tab.id)
		forget_confirmations_for(tab.id)
		socket_forget_tab(tab.id)
		tab_clear_panels(&tab)
		delete(tab.panels)
	}
	for i := len(state.pending_confirmations) - 1; i >= 0; i -= 1 {
		if c, is := state.pending_confirmations[i].command.(Close_Session); is && c.session == id do ordered_remove(&state.pending_confirmations, i)
	}
	delete(s.tabs)
	comments_free(s) // its pending comments go with it (their crops too)
	for o, i in state.open_sessions do if o.id == id {
		ordered_remove(&state.open_sessions, i)
		break
	}
	if state.current_session == id {
		state.current_session = 0
		#reverse for o in state.open_sessions do if !o.home {
			focus_session(o.id)
			break
		}
	}
}

forget_confirmations_for :: proc(tab_id: u64) {
	for i := len(state.pending_confirmations) - 1; i >= 0; i -= 1 {
		target: u64
		p := state.pending_confirmations[i]
		#partial switch c in p.command {
		case Close_Tab: target = c.tab_id
		case Pi_Reload: target = c.tab_id
		case Reload_File: target = c.tab_id
		case Markdown_Follow: target = c.tab_id
		}
		// its target, or its requester (a pi tab, Home) is gone
		if target == tab_id || p.caller.tab_id == tab_id do ordered_remove(&state.pending_confirmations, i)
	}
}

is_widget :: proc(id: string) -> bool {
	for w in FOCUS_WIDGETS do if w == id do return true
	return false
}

// Random v4 UUID: new pi session ids and confirmation tokens (unguessable).
new_uuid :: proc() -> string {
	context.random_generator = crypto.random_generator()
	return uuid.to_string(uuid.generate_v4(), context.allocator)
}

// ---- helpers (only called from run_command) ----

@(private = "file")
select_project :: proc(p: Project) {
	state.selected_project = p.id
	if p.dir != "" do scan_sessions(p)
	else do clear(&state.sessions)
}

@(private = "file")
project_by_cwd :: proc(cwd: string) -> ^Project {
	for &p in state.projects do if p.group == .Projects && p.cwd == cwd do return &p
	return nil
}

// A session pi just wrote (or reported) that its list does not show yet:
// list it. A project added by hand learns its folder in pi's store. Lists
// only once the file exists, so a busy pi costs nothing.
@(private = "file")
refresh_listing :: proc(s: ^Open_Session) {
	if s == nil || s.home || s.session_file == "" || !os.exists(s.session_file) do return
	p := find_project(s.project_id)
	if p == nil do return
	if p.group == .Chats {
		if !session_listed(state.chats[:], s.pi_session_id) do scan_chats()
		return
	}
	if p.dir == "" && s.session_dir == "" do p.dir = project_string(filepath.dir(s.session_file))
	if p.id == state.selected_project && p.dir != "" && !session_listed(state.sessions[:], s.pi_session_id) do scan_sessions(p^)
}

focus_session :: proc(id: u64) {
	state.current_session = id
	if s := find_session(id); s != nil do s.shown_at = time.now()._nsec
	notify_seen(id) // its bell entries are read (notify.odin)
	if s := find_session(id); s != nil do start_restored_tabs(s)
	if t := active_term(); t != nil do t.changed = true
}

// Lazy restore: starts the tabs of a restored session that have not started
// yet. A gone session (missing) starts nothing. pi resumes its session
// file; shells are new shells in their saved cwd (or the session's, if that
// is gone), with a note that the old history is not kept.
@(private = "file")
start_restored_tabs :: proc(s: ^Open_Session) {
	if s.missing do return
	for &tab in s.tabs {
		if tab.status != .Not_Started do continue
		if et, is_ed := tab.kind.(Editor_Tab); is_ed {
			// no process: the file opens again (a gone file says so in its tab)
			if editor_of(tab.id) == nil do editor_new(tab.id, et.path)
			tab.status = .Running
			continue
		}
		if mt, is_md := tab.kind.(Markdown_Tab); is_md {
			if md_view_of(tab.id) == nil do md_view_new(tab.id, mt.path)
			tab.status = .Running
			continue
		}
		if _, is_web := tab.kind.(Browser_Tab); is_web {
			// its page loads now (browser_tick), at the URL it was saved with
			browser_restore(&tab)
			tab.status = .Running
			continue
		}
		t := new_term(tab.id)
		ok: bool
		switch _ in tab.kind {
		case Pi_Tab:
			if s.home {
				// the agent (agent.odin): its bridge and control tokens, its
				// prompt file and model; it resumes its session file
				path := session_file_in(s.session_dir, s.pi_session_id)
				ok = start_pi(t, s.pi_session_id, path, s.session_dir, s.cwd, agent_env(tab.id), agent_extra_args(path == ""))
				if ok {
					// applied (home_model) at its first status (Pi_Status_Update)
					delete(agent_model_starting)
					agent_model_starting = strings.clone(state.settings.agent_model)
					agent_started = time.tick_now()
				}
			} else {
				env := chat_env(s.project_id, socket_child_env({kind = .Panel, tab_id = tab.id}))
				ok = start_pi(t, s.pi_session_id, s.session_file, s.session_dir, s.cwd, env)
			}
			if !ok do socket_forget_tab(tab.id)
		case Shell_Tab:
			cwd := tab.cwd != "" && os.is_dir(tab.cwd) ? tab.cwd : s.cwd
			ok = term_start(t, {login_shell(), "-l"}, cwd) // a fresh terminal: the note goes after
			if ok do term_note(t, "Restored tab: a new shell (the previous one's history is not kept).")
		case Editor_Tab, Changes_Tab, Markdown_Tab, Browser_Tab, App_Tab: // handled above; Changes and app tabs are not kept
		}
		if ok do tab.status = .Running
		else do drop_term(tab.id)
	}
}

// Restarting a pi tab on the same session (hot reload after a pi update,
// reload.odin), in two steps so two pi never share a session file. Stop:
// the process is hung up on (returns its pid), its tokens, panels and
// confirmations go; the tab shows as exited (nothing starts it). The caller
// checked with the bridge that pi is idle.
stop_pi_tab :: proc(tab: ^Tab) -> (pid: i32) {
	if t := term_of(tab.id); t != nil do pid = t.pty.pid
	drop_term(tab.id)
	forget_confirmations_for(tab.id)
	socket_forget_tab(tab.id)
	tab_clear_panels(tab)
	if agent_picker.tab == tab.id do agent_picker = {}
	agent_pending_drop(tab.id)
	tab.status, tab.agent, tab.waiting, tab.question = .Exited, .Unknown, false, false
	for b in tab.blockers do delete(b)
	clear(&tab.blockers)
	return
}

// Start, once the old process exited: pi starts as a restored tab does
// (Atlas with its own tokens and prompt).
start_pi_tab_again :: proc(s: ^Open_Session, tab: ^Tab) -> bool {
	tab.status = .Not_Started
	start_restored_tabs(s)
	return tab.status == .Running
}

// The session file for a pi session id: from the listed sessions if this is
// the selected project, else from the session dir (`session_dir`, or the
// project's dir in pi's store). Temp-allocated; "" = not found.
find_session_file :: proc(p: Project, pi_session_id: string, session_dir := "") -> string {
	dir := session_dir != "" ? session_dir : p.dir
	if session_dir == "" && p.id == state.selected_project do for s in state.sessions do if s.id == pi_session_id do return s.path
	if dir == "" do dir = pi_store_dir(p.cwd)
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return ""
	return strings.clone(session_file_among(files, pi_session_id), context.temp_allocator)
}

// path = "" starts a new chat with `pi --session-id <id>`, so pi-desk knows
// which file it will be; otherwise resumes the file.
@(private = "file")
open_new_session :: proc(p: Project, pi_session_id: string, path: string, cwd := "", session_dir := "") -> (Result, bool) {
	tab := Tab{id = new_id(), kind = Pi_Tab{}, title = "pi"}
	// the bridge in this pi finds pi-desk with these (token = this tab, panel)
	env := chat_env(p.id, socket_child_env({kind = .Panel, tab_id = tab.id}))
	// session_dir "": pi's own store, also for chats (`cd ~/Chats && pi --resume`)
	at := cwd != "" ? cwd : p.cwd // cwd: a worktree of the project
	if p.group == .Chats && !os.is_dir(p.cwd) {
		os.make_directory_all(p.cwd) // made on the first chat, with its instructions (folders.odin)
		chats_instructions_ensure(date_stamp())
	}
	if !start_pi(new_term(tab.id), pi_session_id, path, session_dir, at, env) {
		socket_forget_tab(tab.id)
		drop_term(tab.id)
		return fail("could not start pi"), false
	}
	s := Open_Session {
		id            = new_id(),
		pi_session_id = strings.clone(pi_session_id),
		session_dir   = strings.clone(session_dir),
		session_file  = strings.clone(path), // "" for a new chat until its bridge reports it
		project_id    = p.id,
		cwd           = strings.clone(at),
		active_tab    = tab.id,
	}
	append(&s.tabs, tab)
	append(&state.open_sessions, s)
	focus_session(s.id)
	return {ok = true, created_id = s.id}, true
}

// A chat's pi is read-only (pi-kit's guardrails, PI_KIT_READONLY) when the
// user set Settings.chats_readonly; full pi by default.
@(private = "file")
chat_env :: proc(project_id: u64, env: []string) -> []string {
	p := find_project(project_id)
	if p == nil || p.group != .Chats || !state.settings.chats_readonly do return env
	out := make([]string, len(env) + 1, context.temp_allocator)
	copy(out, env)
	out[len(env)] = "PI_KIT_READONLY=1"
	return out
}

@(private = "file")
new_term :: proc(tab_id: u64) -> ^Term {
	t := new(Term)
	term_init(t, 80, 24)
	// size it to the pane before the child starts, so it sees the right grid
	if app.pane.z > 0 do term_set_rect(t, app.pane.x, app.pane.y, app.pane.z, app.pane.w)
	terms[tab_id] = t
	return t
}

drop_term :: proc(tab_id: u64) {
	editor_drop(tab_id) // an editor tab's buffer (editor_commands.odin)
	changes_drop(tab_id) // a Changes tab's view (changes.odin)
	md_drop(tab_id) // a Markdown tab's view (markdown_view.odin)
	browser_drop(tab_id) // a browser tab's page (browser.odin)
	app_drop(tab_id) // an app tab's process and frames (app_tab.odin)
	if t := term_of(tab_id); t != nil {
		term_free(t)
		free(t)
		delete_key(&terms, tab_id)
	}
}

@(private = "file")
login_shell :: proc() -> string {
	shell := os.get_env("SHELL", context.temp_allocator)
	return shell != "" ? shell : "/bin/zsh"
}

// pi, or why there is none (the shell's own "command not found" says too little)
@(private = "file")
PI_TAB_CMD :: `command -v pi >/dev/null 2>&1 || { printf '%s\n' "pi was not found on your login shell's PATH:" "  $PATH" "Install pi, or add its folder to PATH in your shell's login profile (~/.zprofile for zsh, ~/.bash_profile for bash), then open this tab again."; exit 127; }; exec pi "$@"`

@(private = "file")
start_pi :: proc(t: ^Term, pi_session_id, path, session_dir, cwd: string, env: []string, extra: []string = nil) -> bool {
	argv := make([dynamic]string, context.temp_allocator)
	// A login shell finds pi on the user's PATH (from Finder or the Dock, PATH
	// is the interactive shell's: login_env.odin). PI_DESK_CMD replaces pi (benchmarks: e.g.
	// "cat big.log"); it sees the pi arguments as "$@".
	cmd := os.get_env("PI_DESK_CMD", context.temp_allocator)
	if cmd == "" do cmd = PI_TAB_CMD
	append(&argv, login_shell(), "-l", "-c", cmd, "pi")
	if session_dir != "" do append(&argv, "--session-dir", session_dir)
	if path != "" do append(&argv, "--session", path)
	else do append(&argv, "--session-id", pi_session_id)
	append(&argv, ..extra)
	return term_start(t, argv[:], cwd, pi_extra_env(env)) // + PI_KIT_NOTES_DIR (folders.odin)
}

// Runtime upkeep, not state changes: read every terminal (background tabs
// and sessions included), report exits as commands, shut down on exit.
pump_all :: proc() {
	for id, t in terms {
		term_pump(t)
		if !t.running {
			if _, tab, _ := find_tab(id); tab != nil && tab.status == .Running do run_command(Tab_Exited{id})
		}
	}
}

close_all :: proc() {
	for _, t in terms do reader_stop_and_close(t)
}

// ---- Rescan on a worker thread ----

scan_thread: ^thread.Thread

@(private = "file")
scan_worker :: proc(request_id: u64) {
	scan := new(Scan_Result)
	scan_projects(scan)
	inbox_submit(Rescan_Done{request_id = request_id, scan = scan}, {kind = .Internal})
}
