package core

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
	reopen:  bool, // the user opened it (its row, the palette): its pi starts again if it exited (UI only)
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
	pane:    u64, // the pane of the session it opens in (0 = the focused one; panes.odin)
}
Close_Tab :: struct {
	tab_id:   u64, // a session's pi tab cannot be closed
	confirm:  string, // token from a needs_confirmation result
	comments: Comments_Choice, // the comments made on it (comments.odin): ask (the user's close prompt), send, drop
}
Focus_Tab :: struct {
	tab_id: u64, // also makes its session current
}
// Panes (panes_commands.odin; docs/plans/split-panes.md).
Split_Pane :: struct {
	pane:      u64, // 0 = the current session's focused pane
	direction: Pane_Dir, // where the new pane goes
	tab_id:    u64, // moved into the new pane (0: a new shell tab there)
	no_focus:  bool, // the wire's focus: false (the new pane gets the keyboard by default)
}
Close_Pane :: struct {
	pane: u64, // its tabs join the neighbouring pane
}
Focus_Pane :: struct {
	pane:      u64, // a pane, or 0 with a direction from the current session's focused pane
	direction: string, // left, right, up, down, next, prev ("" with a pane)
}
Move_Tab :: struct {
	tab_id: u64,
	pane:   u64, // a pane of the tab's session (its own: a reorder)
	index:  int, // strip position there (-1 = the end)
}
Set_Split :: struct {
	split: u64, // a divider: a split node's id (the snapshot's layout)
	ratio: f32, // its first child's share
}
Equalize_Panes :: struct {
	session: u64, // 0 = the current session
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
// Deckhand itself moves the keyboard (a sheet it opened, a new tab's URL field, an install's
// setup sheet), without set_focus's caller rules: the window's former direct writes.
Focus_Take :: struct {
	widget: string,
}
// A widget that closed lets go of the keyboard (back to the terminal); nothing when the keyboard
// is elsewhere.
Focus_Release :: struct {
	widget: string,
}
// The harness the New session picker lists first (harness.odin).
Set_Last_Harness :: struct {
	harness: Harness,
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
Refresh_Shell_Env :: struct {} // long-running: asks the login shell again (login_env.odin); new tabs get it
Quit :: struct {
	confirm:       string,
	stop_sessions: bool, // "Quit Deckhand and Stop All Sessions…": the session holder hangs up everything too
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
// The default Claude Code flags for the tabs the user starts (user-only; claude_with_defaults).
Set_Claude_Default_Flags :: struct {
	skip_permissions: bool, // --dangerously-skip-permissions
	confirm:          string, // turning it on: the user's confirmation (confirm_gate)
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
// Keep sessions running in the session holder when Deckhand quits and while it updates
// (docs/plans/background-core.md). On by default (keep_sessions_default). User-only.
Set_Keep_Sessions :: struct {
	on: bool,
}
// keep_sessions' default (keep_sessions_default_on), except in test mode, where a scene turns it
// on when it tests it (every other scene would leave a session holder running after it quits).
// Saved only once the user chose (Settings.keep_sessions_chosen): turning the default back off
// turns it off for everyone who never chose.
keep_sessions_default_on := true // on by default: this line alone turns it off again (revert its commit)

// Settings › Run sessions in a background core (docs/plans/background-core.md §10.3): the window
// and the core as two processes (`deckhand-core serve` over core.sock). Read by the window at
// launch (main.odin separate_core_wanted), so a change takes effect at the next launch. User-only.
// On by default; saved only when it differs from the default (an opt-out), so this line alone
// turns it off again for everyone who never chose.
Set_Separate_Core :: struct {
	on: bool,
}
separate_core_default_on := true

// The answer to state.holder_ask (a session holder from another build runs, holder_client.odin):
// stop true stops it (SIGTERM, then SIGKILL), removes its socket and starts a new holder; its
// sessions end. false: run on without a holder, as before. User-only.
Holder_Replace :: struct {
	stop: bool,
}

// A separate core hands its sessions over to another core process (docs/plans/background-core.md
// §7.2, core_handover.odin): to "current" (the installed core this app's install pointed
// current at: an update, or Use this app's core) or "previous" (Use previous core). Job runs
// get up to 2 min to end, then stop. The window's connection ends; it dials the new core.
// User-only; only a separate core does it.
Core_Handover :: struct {
	to: string,
}

// A window in another process: the user typed in a Claude tab's prompt (claude_note_typed), so
// held texts wait (internal; window.command only).
Claude_Typed :: struct {
	tab_id: u64,
}
// A window in another process: the user closed a Claude tab's status banner (claude_status_dismiss;
// internal; window.command only).
Claude_Status_Dismiss :: struct {
	tab_id: u64,
}
// How a replica process tells its core (client.odin sets it; nil in a core).
claude_typed_send: proc(tab_id: u64)
claude_status_dismiss_send: proc(tab_id: u64)
files_root_reset_send: proc(base: string) // the Files tree back to base's own folder (worktrees_done)

// The commands a window process runs itself with a separate core (replica_process): its own
// workers' results, for its own caches (the Files tree, the worktree switcher, the Changes tab).
// Anything else run there acts on the replica, not the core: test builds count and log it
// (run_command; autotest fails the scene), as is one of these that changed State.
window_local_command :: proc(cmd: Command) -> bool {
	#partial switch _ in cmd {
	case File_List_Done, Git_Status_Done, Worktrees_Done, Changes_Scan_Done, Changes_Diff_Done: return true
	}
	return false
}

replica_core_runs: int // test builds: the core commands a window process ran (window_local_command)

// Copy a control token's clipboard entry: cleared at deadline if it still holds the token.
CONTROL_TOKEN_CLIP_TTL :: 60 * time.Second
control_token_clip: struct {
	count:    int,
	deadline: time.Tick, // zero: nothing to clear
}

// Main thread, every frame (control_token_clip).
control_token_clip_tick :: proc() {
	if control_token_clip.deadline == {} || time.tick_diff(control_token_clip.deadline, time.tick_now()) < 0 do return
	window_clipboard_clear_if(control_token_clip.count)
	control_token_clip = {}
}
keep_sessions_default :: proc() -> bool {
	return keep_sessions_default_on && !autotest_active
}

// The settings with a default that can change between builds, until the saved workspace says
// otherwise (main.odin and serve.odin at start, persist.odin's load).
settings_defaults :: proc() {
	state.settings.keep_sessions, state.settings.keep_sessions_chosen = keep_sessions_default(), false
	state.settings.separate_core = separate_core_default_on
	state.settings.remote_machines = remote_machines_default_on
	state.settings.machines_reachable = machines_reachable_default_on
}

// Settings › Copy a control token: a new control token, as the shell exports `deckhand --ctl` reads,
// onto the clipboard (docs/PROTOCOL.md §2). The user's only: the one way a release build mints a
// control token (test_hooks.odin: no --print-token there). The token is never logged or returned.
Copy_Control_Token :: struct {}

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
// A pi tab whose process exited: pi starts again in it, on its session
// (dead_tab.odin). pick_model: pi's model selector opens once it is up.
Pi_Restart :: struct {
	tab_id:     u64,
	pick_model: bool,
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
	exit:   Exit_Info, // how it ended (waitpid), if reaped
}
Rescan_Done :: struct {
	request_id: u64,
	scan:       ^Scan_Result,
}
Refresh_Shell_Env_Done :: struct {
	request_id: u64,
	ok:         bool,
	env:        []string, // the merged environment (heap, handed over; never logged)
}
// Internal only: one saved session back into State (persist.odin) with its
// tabs not started. Focusing the session starts them (lazy restore).
Restore_Tab :: struct {
	kind:  Tab_Kind_Id,
	title: string,
	cwd:   string, // shells: where to start; editors: the file; browser tabs: the URL; Claude tabs: where it runs
	active: bool, // the session's active tab (none: the pi tab)
	claude_id: string, // Claude tabs: the Claude session to resume ("" = a new one)
	args:  []string, // Claude tabs: the user's extra flags
	readonly: bool, // Claude tabs: started with Deckhand's read-only profile (kept: claude.odin)
	account: string, // Claude tabs: its account's config folder (claude_accounts.odin; "" = the default)
	pane:  Maybe(int), // with a layout: its saved pane, an index into the layout's panes (nil, unset = not known: the focused pane)
	pane_active: bool, // with a layout: the tab its pane showed
	held:  u32, // its process runs in the session holder's terminal `held` (adopted at launch)
}
// A restored session's saved panes (persist.odin panes_parse; restored by restore_panes in
// panes_restore.odin). nodes[0] is the tree's root; no nodes: one pane holding every tab.
Restore_Layout :: struct {
	nodes:   []Restore_Node,
	panes:   int, // how many panes (the tree's leaves, numbered 0..panes-1)
	focused: int, // the pane with the keyboard
}
Restore_Node :: struct {
	leaf:  bool,
	pane:  int, // leaf: its pane's index
	dir:   Split_Dir, // split
	ratio: f32, // split: child a's share, in [RATIO_MIN, 1 - RATIO_MIN]
	a, b:  int, // split: indices into nodes
}
Restore_Session :: struct {
	project_id:    u64,
	pi_session_id: string,
	session_dir:   string, // "" = pi's default store
	cwd:           string, // where pi runs: a checkout of the project's repository ("" = the project's folder)
	tabs:          []Restore_Tab, // the tabs after the pi tab (agent claude: all of them, the main Claude tab first)
	home:          bool, // the Home session (no project, no other tabs; session dir and cwd are Deckhand's)
	agent:         Session_Agent, // claude: a Claude-only session; pi_session_id is its Claude session id
	layout:        Restore_Layout, // its panes ({}: one pane)
	pi_pane:       Maybe(int), // with a layout: the pi tab's saved pane (nil, unset = not known: the focused pane); a Claude-only session's main tab is tabs[0]
	pi_active:     bool, // with a layout: the pi tab was its pane's shown tab
	pi_held:       u32, // the pi tab's (Home's) session holder terminal (Restore_Tab.held)
	pi_readonly:   bool, // that pi was started read-only (an adopted one keeps it)
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
	New_Claude_Session,
	Add_Claude_Account,
	Rename_Claude_Account,
	Remove_Claude_Account,
	Set_Claude_Account_Default,
	Claude_Rename,
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
	Split_Pane,
	Close_Pane,
	Focus_Pane,
	Move_Tab,
	Set_Split,
	Equalize_Panes,
	Copy_Selection,
	Terminal_Link, // a link in a terminal tab (term_links.odin)
	Send_Text,
	Set_Focus,
	Focus_Take,
	Focus_Release,
	Set_Last_Harness,
	Set_Layout,
	Set_Panel,
	Cancel_Confirmation,
	Rescan,
	Refresh_Shell_Env,
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
	Set_Claude_Default_Flags,
	Set_Pi_Extension, // pi_integration.odin
	Set_Agent_Name,
	Set_Agent_Model,
	Agent_Model_Picker,
	Set_Notify,
	Set_Tidy_Projects,
	Set_Keep_Sessions,
	Set_Separate_Core,
	Set_Remote_Machines,
	Set_Machines_Reachable,
	Machine_Add,
	Machine_Remove,
	Machine_Rename,
	Machine_Connect,
	Machine_Login,
	Machine_Open_Page, // a machine's web page in a local browser tab (machine_page.odin)
	Machine_Install, // Install… and Update of another machine's core (machine_install.odin)
	Machine_Linger, // Linux: linger on there (machine_install.odin)
	Holder_Replace,
	Holder_Restart, // a separate core's window: the palette's Restart session holder (holder_restart.odin)
	Core_Handover,
	Claude_Typed,
	Claude_Status_Dismiss,
	App_Socket, // a separate core: the window's app tabs' connections (app_tab_core.odin)
	Harness_Install, // and the setup sheet's install runs (harness_install.odin)
	Fs_Changed, // and what its file watcher saw (fs_model.odin)
	Copy_Control_Token,
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
	Pi_Restart,
	Pi_Wait_Idle,
	Panel_Set,
	Panel_Remove,
	Set_Panel_Collapsed,
	Tab_Exited,
	Program_Status, // internal: a tab's OSC 7501 status (agent_status.odin)
	Set_Unread, // "Mark as unread" (agent_status.odin)
	Rescan_Done,
	Refresh_Shell_Env_Done,
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
	// an agent shows the user a file (show_file.odin)
	Show_File,
	Markdown_Set_View,
	Markdown_Scroll,
	Markdown_Follow,
	// app tabs (app_tab.odin)
	New_App_Tab,
	App_Restart,
	App_Close,
	App_Declared,
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
	Browser_Popup_Open,
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
	// Claude Code tabs (claude.odin)
	New_Claude_Tab,
	Claude_Resume,
	Claude_Session_Report,
	Claude_Turn_Report,
	Claude_Comments,
	Claude_Attached,
	Claude_Prompt,
	Claude_Wait_Idle,
	Claude_Wait_Tick,
	Claude_Held_Op,
	Claude_Deliver,
	Claude_Restore_History,
	Claude_Readonly_Ack,
	// Claude tabs, part two (claude_panels.odin, dead_tab.odin)
	Claude_Restart,
	Claude_Todos,
	Claude_Task,
	Claude_Subagent,
	Claude_Background,
	Claude_Model_Report, // claude_rows.odin
	// Claude Code's hot reload and version (claude_reload.odin)
	Claude_Restart_Changed,
	Claude_Reload_Later,
	Claude_Reload_Watch,
	Claude_Reload_Kick,
}

// Widgets that can take keyboard focus (editor_*: the editor's find,
// replace and go-to-line fields).
FOCUS_WIDGETS :: [?]string{"rename_project", "rename_session", "palette", "sidebar_filter", "agent_input", "settings", "shortcuts", "editor_find", "editor_replace", "editor_goto", "files", "files_filter", "files_name", "notifications", "changes_message", "setup", "job_sheet", "comment_edit", "comment_new", "browser_url", "browser_find", "browser_prompt"}

Result :: struct {
	ok:              bool,
	error:           string,
	created_id:      u64, // what the command created or focused (project, open session, tab)
	pending:         bool, // accepted; finishes later with a "finished" event for this request id
	confirm_token:   string, // set with error "needs_confirmation" if this caller may confirm: resend with it
	confirm_summary: string,
	confirm_by_user: bool, // needs_confirmation: only the user can confirm (in the UI)
	data:            string, // query results (JSON)
	remote:          u64, // the machine that answered (machine_route.odin's route_result only; 0 = this one): "machine" beside data, never in it, so no local command's data can claim it
}

// Who sent a command. tab_id is the caller's own tab for pi-tab callers.
Caller_Kind :: enum {
	None, // the zero value: a Caller nobody set. Every caller rule refuses it (caller_may); the core's own is .Internal, spelled out
	Internal,
	UI,
	Script,
	Control,
	Panel,
	App, // an app tab's program (app_tab.odin): answers tab.* requests, sends no commands
	Tab_Host, // what a tab's page or app reports through the window (tabhost_route.odin): TAB_HOST_COMMANDS only, never ui
}
Caller :: struct {
	kind:   Caller_Kind,
	tab_id: u64,
	claude: bool, // kind panel: a Claude tab's plugin and CLI (claude.odin), not a pi tab's bridge
	hub:    bool, // it came over a hub link (another machine's core, on_behalf): kept with a queued command, so a hub that is gone by the time it runs still counts (caller_from_hub)
}

// The command came from another machine's core: its own link said so (kept with it in the inbox),
// or this core's attached link is a hub now. A User_Here command (every machine_*) is refused
// then (caller_may).
caller_from_hub :: proc(c: Caller) -> bool {return c.hub || window_link_hub()}

fail :: proc(msg: string) -> Result {return {error = msg}}

// Run after every command by the unit tests (panes_test.odin sets it: every session's panes stay
// whole); nil in the app.
after_command_check: proc(cmd: Command)

// Runs one command on the main thread. request_id ties it to its events.
run_command :: proc(cmd: Command, caller := Caller{kind = .Internal}, request_id: u64 = 0) -> Result {
	if window.test_facts != nil do window.test_facts() // unit tests only (window_hooks.odin)
	r: Result
	changed := false
	defer when TEST_HOOKS {
		// a window process runs only its own caches' commands, and they change no State
		if replica_process && (!window_local_command(cmd) || changed) {
			replica_core_runs += 1
			fmt.eprintfln("Deckhand: BUG: the window process ran %s on its replica (it is the core's to run)", command_type(cmd))
		}
	}
	if !caller_may(caller, cmd) {
		r = fail("not allowed for this caller")
	} else if why := claude_readonly_refuses(caller, cmd); why != "" {
		r = fail(why) // a read-only Claude tab acting on a page or an app (claude.odin)
	} else if mr, routed := machine_route(cmd, caller, request_id); routed {
		r = mr // another machine's session, tab or project: run there, or refused (machine_route.odin)
	} else {
		r, changed = apply(cmd, caller, request_id)
	}
	if after_command_check != nil do after_command_check(cmd) // the unit tests' (panes_test.odin)
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
		window_state_changed()
	}
	if changed do tab_term_facts_tick(time.tick_now()) // a terminal it made or dropped: its tab's record says so (core_loop.odin)
	_, q1 := cmd.(Get_State)
	_, q2 := cmd.(List_Commands)
	// the scheduler's own bookkeeping and the job queries: no event unless State moved
	q3 := false
	#partial switch _ in cmd {
	case Notifications_List:   q3 = true
	case Jobs_Sync, Jobs_Tick: q3 = !changed
	case Claude_Wait_Tick:     q3 = true // the timer's: what it does says itself
	case Job_List, Job_Runs:   q3 = true
	case Job_Run_Done:         q3 = true // job.finished says it (the run is freed by now)
	case Focus_Release:        q3 = !changed // nothing had the keyboard (test mode's barrier: client_barrier)
	}
	// app tabs: answers and queries (App_Call_Done finishes its request itself)
	#partial switch _ in cmd {
	case App_Call_Done, App_Events, App_Declared: q3 = true
	case App_Socket, Fs_Changed: q3 = true // a separate core's window: an app's lines and tokens, the watcher's paths
	// browser tabs' queries: their answers hold page content (the requester's only)
	case Browser_Tabs, Browser_Console, Browser_Network, Browser_Comments: q3 = true
	}
	_, q4 := cmd.(Editor_State)
	_, q5 := cmd.(List_Dir)
	if !q1 && !q2 && !q3 && !q4 && !q5 do emit_event(Command_Event{request_id = request_id, caller = caller, version = state.version, changed = changed, command = cmd, result = r})
	return r
}

// The focus_widget string focus_take made (heap). Other writers set literals or clones nobody
// frees, so only this one is freed when the keyboard moves on (as browser_nav did).
@(private = "file")
focus_taken: string

// Frees the current focus_widget when focus_take made it; anything else is left alone.
@(private = "file")
focus_taken_free :: proc() {
	if focus_taken != "" && raw_data(state.focus_widget) == raw_data(focus_taken) do delete(state.focus_widget)
	focus_taken = ""
}

// Capabilities, from the command table (command_table.odin): panel callers
// (pi tabs) may query, report their own tab's pi session and status, and
// publish their own tab's panels (nobody else may: not control, not
// scripts). Settings that bound agents are user-only. The control caller
// drives pi tabs through pi_prompt/pi_reload/pi_wait_idle, never reports.
caller_may :: proc(caller: Caller, cmd: Command) -> bool {
	if caller.kind == .None do return false // never set: nobody's
	if caller.kind == .Tab_Host do return tab_host_may(cmd) // a page's or an app's reports only (tabhost_route.odin)
	spec := command_spec(command_type(cmd))
	if spec == nil || !who_allows(caller.kind, spec.who) do return false
	if spec.who == .User_Here && caller_from_hub(caller) do return false // the one gate: this machine's own user only
	// a Claude tab (panel + claude): its own claude.* reports, never a pi bridge's; and only
	// a Claude tab sends those (scripts too, for tests)
	if spec.who == .Claude do return caller.kind != .Panel || (caller.claude && caller.tab_id == claude_command_tab(cmd))
	if caller.kind == .Panel && caller.claude && (spec.who == .Report || spec.who == .Bridge) do return false
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
	case .App, .Tab_Host, .None:
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
			dirty, known := window_tab_dirty(tab.id)
			return dirty || !known // unsaved changes (not known with no window: ask)
		case Changes_Tab, Browser_Tab:
			return false // nothing of its own to lose
		case Markdown_Tab:
			return false // read-only: nothing to lose
		case App_Tab:
			return false // closing asks the app to quit (tab.quit) first
		case Claude_Tab:
			// unknown until its plugin's hooks report: ask to be safe (as pi); a held text is lost
			ct := tab.kind.(Claude_Tab)
			return ct.turn != .Idle || len(ct.held) > 0
		}
	}
	return true
}

// close_tab's close for app_close (app_tab.odin), which checked the caller and the tab first.
close_tab_apply :: proc(c: Close_Tab, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	return apply(c, caller, request_id)
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
		if l := claude_account_holding(want); l != "" do return fail(fmt.tprintf("that folder is inside the Claude account %s's config folder (Settings → Claude accounts)", l)), false
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
		if p.machine != 0 { 	// another machine's: its core lists its sessions (machines.odin)
			machine_select_project(p^)
			return {ok = true}, true
		}
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
		for &s in state.open_sessions {
			if s.home do continue
			if s.pi_session_id == c.pi_session_id && (s.cwd == p.cwd || s.project_id == p.id) {
				focus_session(s.id, caller)
				restart_if_dead(&s, caller.kind == .UI) // its pi (or the Claude tab it shows) exited: starts again, same tab and session (dead_tab.odin)
				return {ok = true, created_id = s.id}, true
			}
		}
		// a pi session's file first: a Claude id never stands for a pi session
		path := find_session_file(p^, c.pi_session_id)
		if path != "" do return open_new_session(p^, c.pi_session_id, path)
		// a Claude session of this project's (its row in the left column; claude.odin): resumed in a
		// Claude-only session, or its tab focused (a dead one starts again in place)
		if rec, _ := claude_record(c.pi_session_id); rec != nil && rec.project == p.cwd {
			rr, ch := claude_apply(Claude_Resume{claude_session_id = c.pi_session_id}, caller, request_id)
			if rr.ok do if s, _, _ := find_tab(rr.created_id); s != nil do rr.created_id = s.id
			return rr, ch
		}
		// a Claude Code transcript found on disk for this project (claude_disk.odin): resumed under
		// its account, by its path; created_id = the session
		if f, ok := claude_disk_lookup(p, c.pi_session_id); ok do return claude_disk_resume(p, f, caller)
		return fail("no such session in this project"), false
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
		focus_session(c.session, caller)
		if c.reopen do restart_if_dead(s, caller.kind == .UI)
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
		close_session(s.id, caller)
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
		if c.pane != 0 && session_pane(s, c.pane) == nil do return fail("no such pane in this session"), false
		id, err := shell_tab_start(s, cwd, c.pane)
		if err != "" do return fail(err), false
		session_show_tab(s, id)
		focus_session(s.id, caller)
		return {ok = true, created_id = id}, true
	case Close_Tab:
		s, tab, i := find_tab(c.tab_id)
		if tab == nil do return fail("no such tab"), false
		if i == 0 do return fail(s.agent == .Claude ? "a Claude session's main tab cannot be closed: close the session" : "a session's pi tab cannot be closed"), false
		// (an app tab in its own session: app_close, a session's agents closing what they opened)
		_, is_app := tab.kind.(App_Tab)
		if owns_tab(caller, c.tab_id) && !(is_app && c.tab_id != caller.tab_id) do return fail("a caller cannot close its own tab"), false
		// comments made on it, not sent yet: the user picks send or drop in the close prompt, others say
		if cr, go_on, cch := comments_close_check(s, tab.id, c.comments, caller); !go_on do return cr, cch
		if close_needs_confirm(tab^) {
			why := "Its process is still running."
			if _, is_ed := tab.kind.(Editor_Tab); is_ed do why = "Its unsaved changes will be lost."
			gr, go_on, ch := confirm_gate(cmd, .Tab_Close, caller, c.confirm, fmt.tprintf("close %q in %s? %s", tab.title, session_where(s), why))
			if !go_on do return gr, ch
		}
		comments_close_act(s, tab.id, c.comments) // send or drop them (the close is going ahead)
		claude_tab_gone(tab) // a Claude tab's held texts; its history entry is used now
		tab_free_kind(tab)
		drop_term(tab.id)
		forget_confirmations_for(tab.id)
		socket_forget_tab(tab.id)
		tab_clear_panels(tab)
		delete(tab.panels)
		prog_summary_free(&tab.prog)
		shown := session_tab_shown(s, c.tab_id)
		pane_tab_gone(s, c.tab_id) // its pane's next tab takes over (panes.odin)
		ordered_remove(&s.tabs, i)
		if shown && s.id == state.current_session do status_seen(s) // the tab that shows now is seen (agent_status.odin)
		return {ok = true}, true
	case Focus_Tab:
		s, tab, _ := find_tab(c.tab_id)
		if tab == nil do return fail("no such tab"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		session_show_tab(s, tab.id) // and its pane gets the keyboard
		focus_session(s.id, caller)
		return {ok = true}, true
	case Copy_Selection:
		_, tab, _ := find_tab(c.tab_id)
		// another machine's terminal: the window's copy too (relayed, machine_route.odin)
		if tab == nil || (term_of(tab.id) == nil && !(tab.machine != 0 && tab.has_term)) do return fail("no such terminal tab"), false
		// the selection is the window's copy's (term_view.odin): it copies it (no window: none)
		if !window_copy_selection(tab.id) do return fail("nothing selected"), false
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
			if _, is_cl := tab.kind.(Claude_Tab); is_cl do return fail("send prompts to a Claude tab with claude_prompt, not send_text"), false
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
		if window_job_sheet_open() && c.widget != "job_sheet" do return fail("the job sheet is open (save or cancel it first)"), false
		if c.widget == "job_sheet" && !window_job_sheet_open() do return fail("the job sheet opens with job_sheet"), false
		// an install or update runs on the setup sheet: only the user moves away from it (harness_install.odin)
		// an install or update runs on the setup sheet: modal until it ends, for every caller (its terminal and ⌃C stay reachable)
		if harness_run_holds_sheet() && c.widget != "setup" do return fail("an install is running on the setup sheet: wait for it, or ⌃C in its terminal"), false
		if c.widget == state.focus_widget do return {ok = true}, false
		if c.widget == "setup" do window_setup_sheet(.Begin) // the first-run sheet starts at step 1 (ui_setup.odin)
		state.focus_widget = strings.clone(c.widget)
		if c.widget == "sidebar_filter" || c.widget == "rename_project" || c.widget == "rename_session" do state.layout.left_open = true // its field must show
		if c.widget == "sidebar_filter" || c.widget == "rename_project" || c.widget == "rename_session" do state.layout.left_tab = .Sessions
		if strings.has_prefix(c.widget, "files") {
			state.layout.left_open = true
			if state.layout.left_tab == .Sessions do state.layout.left_tab = .Files // the Settings tab is a tree too
		}
		return {ok = true}, true
	case Focus_Take:
		if c.widget == state.focus_widget do return {ok = true}, false
		focus_taken_free()
		state.focus_widget = strings.clone(c.widget)
		focus_taken = state.focus_widget
		return {ok = true}, true
	case Focus_Release:
		if c.widget == "" || state.focus_widget != c.widget do return {ok = true}, false
		focus_taken_free()
		state.focus_widget = ""
		return {ok = true}, true
	case Set_Last_Harness:
		if state.settings.last_harness == c.harness do return {ok = true}, false
		state.settings.last_harness = c.harness
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
		claude_accounts_refresh() // Claude Code's config folders again, then each one's projects/ (claude_disk.odin)
		claude_scan_prepare()
		scan_thread = thread.create_and_start_with_poly_data(request_id, scan_worker)
		return {ok = true, pending = true}, false
	case Refresh_Shell_Env:
		if !login_env.gui {
			msg := "Deckhand was started from a terminal: its tabs use that terminal's environment (start it again there to pick up profile changes)"
			window_toast(msg, err = true)
			return fail(msg), false
		}
		if !login_env_refresh_start(request_id, timeout = login_env_refresh_timeout) do return fail("a refresh is already running"), false
		window_toast("Reading your shell environment…")
		return {ok = true, pending = true}, false
	case Refresh_Shell_Env_Done:
		login_env_refresh_done(c.ok, c.env)
		claude_recheck() // Claude Code may be on the new PATH (claude.odin)
		pi_recheck() // and pi (harness.odin)
		claude_accounts_refresh() // and CLAUDE_CONFIG_DIR may name another default (claude_accounts.odin)
		harness_checklist_forget() // the coding agents checklist looks again when it next shows (harness_manifest.odin)
		err := ""
		if c.ok {
			window_toast("Shell environment refreshed: new tabs use it; open tabs keep theirs")
		} else {
			err = "your login shell gave no environment in time (4 s): new tabs keep the current one"
			window_toast(fmt.tprintf("Refresh shell environment: %s", err), err = true)
		}
		emit_event(Finished_Event{request_id = c.request_id, result = {ok = c.ok, error = err}})
		return {ok = true}, false
	case Rescan_Done:
		thread.join(scan_thread)
		thread.destroy(scan_thread)
		scan_thread = nil
		apply_scan(c.scan)
		emit_event(Finished_Event{request_id = c.request_id, result = {ok = true}})
		if claude_rescan_again {
			claude_rescan_again = false
			run_command(Rescan{}, {kind = .Internal})
		}
		return {ok = true}, true
	case Quit:
		if window_job_sheet_holds_quit() do return fail("the job sheet has changes: discard them first (Cancel or Esc), then quit"), true
		// keep_sessions: what the session holder keeps running is not stopped, so not asked about
		keeps := !c.stop_sessions && holder_keeps_sessions()
		unsaved, known := window_unsaved_files() // not known (no window to ask): asked, never taken as none
		if quit_would_stop(keeps) || !known || (keeps && unsaved > 0) {
			what := "quit Deckhand? Running sessions will be stopped."
			if unsaved > 0 do what = fmt.tprintf("quit Deckhand? Running sessions will be stopped, and %d file%s with unsaved changes will be lost.", unsaved, unsaved == 1 ? "" : "s")
			else if !known do what = fmt.tprintf("%s %s", what, unsaved_files_note(unsaved, known))
			if keeps || c.stop_sessions {
				what = keeps ? "quit Deckhand? Sessions the session holder keeps run on; others will be stopped." : "quit Deckhand and stop all sessions? Every session, including those kept running, will be stopped."
				if note := unsaved_files_note(unsaved, known); note != "" do what = fmt.tprintf("%s %s", what, note)
			}
			gr, go_on, ch := confirm_gate(cmd, .App_Quit, caller, c.confirm, what)
			if !go_on do return gr, ch
		}
		app_stop_sessions = c.stop_sessions
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
		// Atlas runs on pi (harness.odin): without it nothing starts and the user is told how to install it
		if !agent_running() && !(caller.kind == .UI ? pi_installed_now() : pi_installed()) {
			if caller.kind == .UI do window_toast(ATLAS_NEEDS_PI, err = true)
			return fail(ATLAS_NEEDS_PI), false
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
			session_panes_init(&s)
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
		if (caller.kind == .UI || caller.kind == .Internal) && !harness_run_holds_sheet() do state.focus_widget = "agent_input"
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
		window_reveal(path)
		return {ok = true}, false // side effect only
	case Session_Info:
		return session_info_apply(c, caller)
	case Job_Sheet:
		return window_job_sheet(c, caller) // the sheet is the window's (ui_job_sheet.odin)
	case Copy_Path:
		path, err := sidebar_path(c.project_id, c.pi_session_id)
		if err != "" do return fail(err), false
		window_clipboard_set(path)
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
	case Set_Claude_Default_Flags:
		if state.settings.claude_skip_permissions == c.skip_permissions do return {ok = true}, false
		// on: the user confirms first, with the warning (a saved setting coming back does not ask)
		if c.skip_permissions && caller.kind != .Internal {
			gr, go_on, ch := confirm_gate(cmd, .Settings_Write, caller, c.confirm, CLAUDE_SKIP_CONFIRM, force_ask = true)
			if !go_on do return gr, ch
		}
		state.settings.claude_skip_permissions = c.skip_permissions
		settings_gen += 1 // the Settings tab's row
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
		if harness_run_holds_sheet() do return fail("an install is running on the setup sheet: wait for it, or ⌃C in its terminal"), false
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
			return fail(fmt.tprintf("%s's pi reports no status (Deckhand's pi integration did not connect): press Ctrl+L in its terminal", agent_name())), true
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
	case Copy_Control_Token:
		if !socket_running() do return fail("Deckhand's control socket is not running"), false
		// multi-use (each `deckhand --ctl` says hello with it anew), so the clipboard is the risk:
		// marked concealed and transient, and cleared after CONTROL_TOKEN_CLIP_TTL if still there
		tok := socket_mint_token({kind = .Control}, context.temp_allocator)
		// with the old names too, for scripts that read them (env_names.odin)
		exports := fmt.tprintf("export DECKHAND_SOCKET='%s' DECKHAND_TOKEN='%s' PI_DESK_SOCKET='%s' PI_DESK_TOKEN='%s'\n", socket_path(), tok, socket_path(), tok)
		// the window marks it (or, with no concealed pasteboard, puts it there plainly: nothing to clear)
		if count, ok := window_clipboard_secret(exports); ok {
			control_token_clip = {count = count, deadline = time.tick_add(time.tick_now(), CONTROL_TOKEN_CLIP_TTL)}
		}
		window_toast("Control token copied: paste it into a terminal within a minute (then it leaves the clipboard), then use deckhand --ctl (it works until you quit Deckhand)")
		return {ok = true}, false // side effect only: the token is on the clipboard, nowhere else
	case Set_Keep_Sessions:
		// the user's choice (only the user may run it; the restore runs it for a saved choice)
		if state.settings.keep_sessions == c.on && state.settings.keep_sessions_chosen do return {ok = true}, false
		state.settings.keep_sessions, state.settings.keep_sessions_chosen = c.on, true
		return {ok = true}, true
	case Set_Remote_Machines: // Settings › Machines over SSH (machines.odin)
		if state.settings.remote_machines == c.on do return {ok = true}, false
		state.settings.remote_machines = c.on
		return {ok = true}, true
	case Set_Machines_Reachable: // Settings › Machines › Allow other machines to connect (the hub door, window_sock.odin)
		if state.settings.machines_reachable == c.on do return {ok = true}, false
		state.settings.machines_reachable = c.on
		return {ok = true}, true
	case Machine_Add:     return machine_add_apply(c), false // the machines section changes itself (machines_publish)
	case Machine_Remove:  return machine_remove_apply(c, caller)
	case Machine_Rename:  return machine_rename_apply(c), false
	case Machine_Connect: return machine_connect_apply(c), false
	case Machine_Login:   return machine_login_apply(c, caller)
	case Machine_Open_Page: return machine_open_page_apply(c, caller, request_id)
	case Machine_Install: return machine_install_apply(c, caller), false // its job changes the machines section itself
	case Machine_Linger:  return machine_linger_apply(c, caller), false
	case Holder_Replace:
		return holder_replace(c.stop), true
	case Holder_Restart:
		holder_restart_start()
		return {ok = true}, false
	case Core_Handover:
		return core_handover_start(c.to), false
	case Claude_Typed:
		_, tab, _ := find_tab(c.tab_id)
		claude_note_typed(tab)
		return {ok = true}, false
	case Claude_Status_Dismiss:
		_, tab, _ := find_tab(c.tab_id)
		if tab == nil do return {ok = true}, false
		claude_status_dismiss(tab)
		return {ok = true}, true
	case App_Socket:
		return app_socket_apply(c), false
	case Harness_Install:
		return harness_install_apply(c), false
	case Fs_Changed:
		for p, i in c.paths {
			reload_fs_event(p) // one of pi's config folders? (reload.odin: the core has no watcher of its own)
			fs_model_changed(p, i < len(c.flags) ? c.flags[i] : 0)
		}
		return {ok = true}, false
	case Set_Separate_Core:
		if state.settings.separate_core == c.on do return {ok = true}, false
		state.settings.separate_core = c.on
		window_toast(c.on ? "Sessions run in a background core from the next launch: quit Deckhand and open it again" : "Sessions run in Deckhand itself from the next launch: Quit Deckhand and Stop All Sessions, then open it again")
		return {ok = true}, true
	case Set_Confirm_Policy:
		if c.caller == .None || c.caller == .UI || c.caller == .Internal || c.caller == .Tab_Host do return fail("ui, internal and tab_host callers have fixed policies"), false
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
		window_set_appearance(c.mode)
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
		notify_tab_exited(ts, tab, c.exit) // the bell (notify.odin)
		if ts.home do home_fork_exited(ts, tab) // a fork pi did not write: back to the old session (home.odin)
		tab.status = .Exited
		tab.exit = c.exit // shown by its bar and tooltips (dead_tab.odin); logged with this command
		if agent_picker.tab == tab.id do agent_picker = {}
		agent_pending_drop(tab.id) // Send to Atlas text waiting for it (session_info.odin)
		tab_clear_panels(tab) // nobody publishes them any more
		forget_confirmations_for(tab.id) // nothing left to confirm
		socket_forget_tab(tab.id) // its token dies with the process
		if _, is_pi := tab.kind.(Pi_Tab); is_pi do comments_pi_exited(ts) // pending comments wait for the next pi
		claude_tab_gone(tab) // a Claude tab: what it held goes
		// claude not found (the tab's command exits 127): look for it again before the next start
		if _, is_cl := tab.kind.(Claude_Tab); is_cl && c.exit.known && c.exit.code == 127 do claude_recheck()
		if _, is_pi := tab.kind.(Pi_Tab); is_pi && c.exit.known && c.exit.code == 127 do pi_recheck()
		return {ok = true}, true
	case Pi_Restart:
		s, tab := pi_tab(c.tab_id)
		if tab == nil do return fail("no such pi tab"), false
		if tab.status == .Running do return fail("pi is running in this tab (pi_reload restarts a running one)"), false
		if tab_held_away(tab) != 0 do return fail("this session still runs in the session holder, which isn't answering: quit and reopen Deckhand to get it back"), false
		if tab.status == .Not_Started do return fail("pi has not started in this tab yet: it starts when its session is shown"), false
		if reload_step_is(tab, true) || restart_waiting(tab.id) do return fail("this tab is restarting"), false
		if s.missing do return fail("its session file or folder no longer exists"), false
		return pi_tab_restart(s, tab, c.pick_model), true
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
		// unknown: only Deckhand itself, when the tab's last bridge connection is gone
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
		status_bridge_report(ps, tab, c.agent) // unseen, and when (agent_status.odin)
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
		return tab_host_apply(cmd, caller, request_id) // editor: the window hosts it (tabhost_route.odin)
	case Set_Left_Tab, Files_Expand, Files_Collapse_All, Files_Reveal, Set_Files_Filter:
		return files_apply(cmd, caller)
	case List_Worktrees, Files_Set_Root, Worktree_Cleanup, Worktree_Cleanup_Done, Worktrees_Done:
		return worktrees_apply(cmd, caller, request_id)
	case Changes_Open, Changes_List, Changes_Stage, Changes_Unstage, Changes_Discard, Changes_Commit, Changes_Scan_Done, Changes_Diff_Done, Changes_Op_Done:
		return changes_apply(cmd, caller, request_id)
	case Markdown_Open, Markdown_Set_View, Markdown_Scroll, Markdown_Follow:
		return tab_host_apply(cmd, caller, request_id) // Markdown
	case Show_File:
		return show_file_apply(c, caller)
	case Split_Pane, Close_Pane, Focus_Pane, Move_Tab, Set_Split, Equalize_Panes:
		return panes_apply(cmd, caller) // panes_commands.odin
	case Terminal_Link:
		return tab_host_apply(cmd, caller, request_id) // a browser tab or the default browser (term_links.odin)
	case New_App_Tab, App_Restart, App_Close, App_Declared, App_Input, App_Events, App_Call, App_Call_Done, App_Update, App_Screenshot, App_Inspect:
		return tab_host_apply(cmd, caller, request_id) // app tabs
	case New_Claude_Tab, New_Claude_Session, Claude_Rename, Claude_Resume, Claude_Session_Report, Claude_Turn_Report, Claude_Comments, Claude_Attached, Claude_Prompt, Claude_Held_Op, Claude_Deliver, Claude_Restore_History, Claude_Readonly_Ack:
		return claude_apply(cmd, caller, request_id) // claude.odin
	case Add_Claude_Account, Rename_Claude_Account, Remove_Claude_Account, Set_Claude_Account_Default:
		r, ch := claude_account_apply(cmd, caller) // claude_accounts.odin
		if ch {
			claude_accounts_refresh()
			claude_disk_rescan()
			// an added account's projects (scan_projects: on the Rescan worker)
			// (one running: once more after it, so every account added at once is scanned)
			if _, is := cmd.(Add_Claude_Account); is && caller.kind == .UI {
				if scan_thread == nil do run_command(Rescan{}, {kind = .Internal})
				else do claude_rescan_again = true
			}
		}
		return r, ch
	case Claude_Restart, Claude_Todos, Claude_Task, Claude_Subagent, Claude_Background:
		return claude_extra_apply(cmd, caller, request_id) // claude_panels.odin
	case Claude_Model_Report:
		return claude_rows_apply(cmd, caller) // claude_rows.odin
	case Claude_Wait_Idle:
		return claude_wait_apply(c, caller, request_id) // claude_wait.odin
	case Claude_Wait_Tick:
		return claude_wait_tick_apply()
	case Comment_Add, Comment_Edit, Comment_Delete, Comments_Clear, Comments_Send_Now, Comments_Ask_Cancel, Pi_Attached:
		return comments_apply(cmd, caller, request_id)
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update, Browser_Popup_Open:
		return tab_host_apply(cmd, caller, request_id) // browser tabs
	case Browser_Zoom, Browser_Find, Browser_Find_Close, Browser_Dialog, Browser_Permission, Browser_Popup, Browser_Edit, Browser_Devtools, Browser_External, Browser_Download:
		return tab_host_apply(cmd, caller, request_id)
	case Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop:
		return tab_host_apply(cmd, caller, request_id)
	case Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel:
		return tab_host_apply(cmd, caller, request_id)
	case Notifications_List, Notifications_Mark_Read, Notifications_Clear, Notify_Post, Set_Bell:
		return notify_apply(cmd, caller)
	case Program_Status, Set_Unread:
		return status_apply(cmd, caller)
	case Update_Check, Update_Skip, Update_Later, Update_Download, Update_Install, Set_Update_Check, Update_Env, Update_Tick, Update_Checked, Update_Prepared:
		return update_apply(cmd, caller)
	case Set_Home_Dir, Set_Folder, Setup_Sheet:
		return folders_apply(cmd, caller)
	case Job_List, Job_Runs, Job_Run_Now, Job_Stop, Jobs_Pause, Jobs_Resume, Job_Create, Job_Save, Job_Mark_Read, Job_Set_Enabled, Job_Delete, Job_Open, Set_Pi_Path, Set_Job_Limits, Jobs_Sync, Jobs_Tick, Job_Run_Done, Jobs_Env:
		return jobs_apply(cmd, caller)
	case Pi_Reload_All, Pi_Restart_Updated, Pi_Reload_Later, Reload_Watch, Reload_Kick:
		return reload_apply(cmd, caller, request_id)
	case Set_Pi_Extension:
		return pi_integration_apply(cmd, caller)
	case Claude_Restart_Changed, Claude_Reload_Later, Claude_Reload_Watch, Claude_Reload_Kick:
		return claude_reload_apply(cmd, caller, request_id)
	case Restore_Session:
		if c.home {
			if state.home != 0 do return fail("Home is already there"), false
			if c.pi_session_id == "" do return fail("pi_session_id is empty"), false
			if home_root == "" do return fail("Home is not available (no data dir)"), false
			s := Open_Session{id = new_id(), pi_session_id = strings.clone(c.pi_session_id), session_dir = home_dir(), cwd = home_cwd(), home = true, restored = true}
			append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "Home", status = .Not_Started, held = c.pi_held})
			s.active_tab = s.tabs[0].id
			session_panes_init(&s)
			append(&state.open_sessions, s)
			state.home = s.id
			return {ok = true, created_id = s.id}, true
		}
		p := find_project(c.project_id)
		if p == nil do return fail("no such project"), false
		if c.pi_session_id == "" do return fail("pi_session_id is empty"), false
		for s in state.open_sessions do if !s.home && s.pi_session_id == c.pi_session_id do return fail("this session is already open"), false
		if c.agent == .Claude do return claude_restore_session(p, c)
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
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{readonly = c.pi_readonly}, title = "pi", status = .Not_Started, held = c.pi_held})
		s.id = new_id()
		restore_tabs(&s, c.tabs, c.layout, c.pi_pane, c.pi_active)
		if s.active_tab == 0 do session_show_tab(&s, s.tabs[0].id)
		append(&state.open_sessions, s)
		return {ok = true, created_id = s.id}, true
	}
	return fail("unknown command"), false
}

// The saved tabs of a restored session, after what it has (Restore_Session), not started; then
// its saved panes (layout: restore_panes, panes_restore.odin), the tabs it had already (the pi
// tab) in pane `pi_pane`. Tabs that do not come back (restore_tab) leave their panes' places.
restore_tabs :: proc(s: ^Open_Session, tabs: []Restore_Tab, layout: Restore_Layout = {}, pi_pane: Maybe(int) = nil, pi_active := false) {
	session_panes_init(s) // one pane (a Claude-only session's: empty until its main tab)
	places := make([dynamic]Restore_Place, context.temp_allocator)
	for t in s.tabs do append(&places, Restore_Place{tab = t.id, pane = pi_pane.? or_else -1, active = pi_active})
	for rt in tabs {
		added := restore_tab(s, rt)
		if added == 0 do continue
		if rt.held != 0 do for &t in s.tabs do if t.id == added do t.held = rt.held // terminal tabs only (holder_adopt_all)
		append(&places, Restore_Place{tab = added, pane = rt.pane.? or_else -1, active = rt.pane_active})
		if rt.active do session_show_tab(s, added)
	}
	restore_panes(s, layout, places[:])
}

// One saved tab back into s (its focused pane), not started; its id, 0 when it does not come
// back (a file that is not a regular one, a bad URL or Claude session, an unknown kind).
@(private = "file")
restore_tab :: proc(s: ^Open_Session, rt: Restore_Tab) -> u64 {
	if rt.kind == .Editor {
		// rt.cwd is the file's path; it opens when the session starts.
		// Not a regular file now (a FIFO, a device): left out
		if !regular_or_missing(rt.cwd) do return 0
		return pane_add_tab(s, Tab{id = new_id(), kind = Editor_Tab{path = strings.clone(rt.cwd)}, title = strings.clone(filepath.base(rt.cwd)), status = .Not_Started}).id
	}
	if rt.kind == .Markdown {
		if !regular_or_missing(rt.cwd) do return 0
		return pane_add_tab(s, Tab{id = new_id(), kind = Markdown_Tab{path = strings.clone(rt.cwd)}, title = strings.clone(filepath.base(rt.cwd)), status = .Not_Started}).id
	}
	if rt.kind == .Browser {
		// rt.cwd is its URL; the page loads once the session is focused
		url, err := browser_url_normalize(rt.cwd)
		if err != "" do return 0
		return pane_add_tab(s, Tab{id = new_id(), kind = Browser_Tab{url = strings.clone(url)}, title = strings.clone(rt.title != "" ? rt.title : "Browser"), status = .Not_Started}).id
	}
	if rt.kind == .Claude {
		if rt.claude_id != "" && !claude_id_ok(rt.claude_id) do return 0
		if claude_args_check(rt.args) != "" do return 0
		args := make([]string, len(rt.args))
		for a, i in rt.args do args[i] = strings.clone(a)
		// its account: an absolute folder; checked again at its start (claude_start: configured only)
		acct := filepath.is_abs(rt.account) ? rt.account : ""
		return pane_add_tab(s, Tab{id = new_id(), kind = Claude_Tab{session_id = strings.clone(rt.claude_id), args = args, readonly = rt.readonly, account = strings.clone(acct)}, title = strings.clone("Claude"), status = .Not_Started, cwd = strings.clone(rt.cwd)}).id
	}
	if rt.kind != .Shell do return 0
	title := rt.title != "" ? strings.clone(rt.title) : fmt.aprintf("shell %d", len(s.tabs))
	return pane_add_tab(s, Tab{id = new_id(), kind = Shell_Tab{}, title = title, status = .Not_Started, cwd = strings.clone(rt.cwd)}).id
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
		window_confirmation_parked(p.summary, r.confirm_by_user) // the bar shows it (window_link.odin)
		return r, false, true
	}
	for p, i in state.pending_confirmations {
		if p.token != token || !same_target(p.command, cmd) do continue
		by_user := caller.kind == .UI
		by_trusted := !force_ask && caller == p.caller && confirm_mode(p.caller, p.class) == .Trusted
		if !by_user && !by_trusted do return fail("only the user can confirm this, in Deckhand"), false, false
		ordered_remove(&state.pending_confirmations, i)
		window_state_changed() // consumed: callers that go on (Quit) may answer "not changed"
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
	case .UI, .Internal, .None:
	case .Script:  who = "A script asks"
	case .App:     who = "An app asks"
	case .Tab_Host: who = "A page asks"
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
		y, ok := b.(Quit)
		ok = ok && x.stop_sessions == y.stop_sessions
		return ok
	case Set_Claude_Default_Flags:
		y, ok := b.(Set_Claude_Default_Flags)
		return ok && x.skip_permissions == y.skip_permissions
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
	case Claude_Restart_Changed:
		y, ok := b.(Claude_Restart_Changed)
		return ok && x.update == y.update && x.all == y.all
	// file commands are parked with absolute paths (editor_apply resolves them first)
	case Machine_Remove:
		y, ok := b.(Machine_Remove)
		return ok && x.no == y.no
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
close_session :: proc(id: u64, caller: Caller) {
	s := find_session(id)
	if s == nil do return
	for &tab in s.tabs {
		claude_tab_gone(&tab)
		tab_free_kind(&tab)
		drop_term(tab.id)
		forget_confirmations_for(tab.id)
		socket_forget_tab(tab.id)
		tab_clear_panels(&tab)
		delete(tab.panels)
		prog_summary_free(&tab.prog)
	}
	for i := len(state.pending_confirmations) - 1; i >= 0; i -= 1 {
		if c, is := state.pending_confirmations[i].command.(Close_Session); is && c.session == id do ordered_remove(&state.pending_confirmations, i)
	}
	delete(s.tabs)
	session_panes_free(s)
	comments_free(s) // its pending comments go with it (their crops too)
	for o, i in state.open_sessions do if o.id == id {
		ordered_remove(&state.open_sessions, i)
		break
	}
	if state.current_session == id {
		state.current_session = 0
		#reverse for o in state.open_sessions do if !o.home {
			focus_session(o.id, caller) // an agent's close never starts the next one's Claude tabs
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
	claude_disk_rescan() // its Claude Code transcripts (claude_disk.odin)
}

project_by_cwd :: proc(cwd: string) -> ^Project {
	for &p in state.projects do if p.group == .Projects && p.machine == 0 && p.cwd == cwd do return &p
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

// caller: who brings it up. An agent's (control) never starts restored Claude tabs: they would
// run with the user's saved flags (docs/CLAUDE.md §3, §4); they stay not started until the user
// (or Deckhand itself, or a test script) shows the session.
focus_session :: proc(id: u64, caller: Caller) {
	// a session made current is laid out again; until then its panes' rects come from its tree
	// inside the window's last centre (tab_rect, panes.odin)
	if id != state.current_session do if s := find_session(id); s != nil do for &p in s.panes do p.rect, p.frame = {}, {}
	state.current_session = id
	if s := find_session(id); s != nil do s.shown_at = time.now()._nsec
	notify_seen(id) // its bell entries are read (notify.odin)
	status_seen(find_session(id)) // its tab on screen is seen (agent_status.odin)
	if s := find_session(id); s != nil do start_restored_tabs(s, claude = caller.kind != .Control && caller.kind != .Panel && caller.kind != .App)
	if s := find_session(id); s != nil do for tab in s.tabs do if session_tab_shown(s, tab.id) {
		if t := term_of(tab.id); t != nil do t.changed = true // drawn again (every pane's)
	}
}

// Lazy restore: starts the tabs of a restored session that have not started
// yet. A gone session (missing) starts nothing. pi resumes its session
// file; shells are new shells in their saved cwd (or the session's, if that
// is gone), with a note that the old history is not kept. claude: Claude tabs too (the user
// shows the session; they run with its saved flags); else they stay not started.
@(private = "file")
start_restored_tabs :: proc(s: ^Open_Session, claude := false) {
	if s.missing || s.machine != 0 do return // gone, or another machine's: nothing of it runs here (machine_mirror.odin)
	for &tab in s.tabs {
		if tab.status != .Not_Started do continue
		if tab_held_away(&tab) != 0 do continue // it runs on in the session holder (holder_client.odin)
		window_state_changed() // statuses change here, also from ticks (hot reload) that say nothing
		if _, is_cl := tab.kind.(Claude_Tab); is_cl && !claude do continue // an agent's: never (§3); in a chat read-only while chats are (claude_start)
		if et, is_ed := tab.kind.(Editor_Tab); is_ed {
			// no process: the file opens again (a gone file says so in its tab)
			window_view_open(tab.id, et)
			tab.status = .Running
			continue
		}
		if mt, is_md := tab.kind.(Markdown_Tab); is_md {
			window_view_open(tab.id, mt)
			tab.status = .Running
			continue
		}
		if bt, is_web := tab.kind.(Browser_Tab); is_web {
			// its page loads now (browser_tick), at the URL it was saved with
			window_view_open(tab.id, bt)
			tab.status = .Running
			continue
		}
		t := new_term(tab.id)
		ok: bool
		switch _ in tab.kind {
		case Pi_Tab:
			if s.home {
				// the agent (agent.odin): its bridge and control tokens, its
				// prompt file and model; it resumes its session file. Its cwd is
				// looked up again at each start (home_cwd): the main folder as it is now
				if cwd := home_cwd(); cwd != s.cwd {
					delete(s.cwd)
					s.cwd = cwd
				} else do delete(cwd)
				path, fork := home_session_start(s)
				ok = start_pi(t, &tab, s.pi_session_id, path, s.session_dir, s.cwd, agent_env(tab.id), agent_extra_args(path == "" && fork == ""), fork)
				if ok {
					// applied (home_model) at its first status (Pi_Status_Update)
					delete(agent_model_starting)
					agent_model_starting = strings.clone(state.settings.agent_model)
					agent_started = time.tick_now()
				}
			} else if chat_readonly(s.project_id) && pi_readonly_too_old() {
				// never a chat that says read-only on a pi whose flags would not hold
				term_note(t, PI_READONLY_CHAT_TOO_OLD)
				tab.status, tab.exit = .Exited, {known = true, code = 1}
				continue
			} else {
				env := chat_env(s.project_id, socket_pi_env({kind = .Panel, tab_id = tab.id}))
				tab.kind = Pi_Tab{readonly = chat_readonly(s.project_id)} // as started (app_tab.odin)
				ok = start_pi(t, &tab, s.pi_session_id, s.session_file, s.session_dir, s.cwd, env, chat_args(s.project_id))
			}
			if !ok do socket_forget_tab(tab.id)
		case Shell_Tab:
			cwd := tab.cwd != "" && os.is_dir(tab.cwd) ? tab.cwd : s.cwd
			ok = term_start(t, {login_shell(), "-l"}, cwd, start = {kind = .Shell}) // a fresh terminal: the note goes after
			if ok do term_note(t, "Restored tab: a new shell (the previous one's history is not kept).")
		case Claude_Tab:
			if !claude_installed_now() { // installed since it was restored: looked up again
				// not installed (any more): nothing starts, the tab says why and shows as exited; no
				// bell entry, no retry (Restart, once it is installed)
				term_note(t, CLAUDE_MISSING)
				tab.status, tab.exit = .Exited, {known = true, code = 127}
				continue
			}
			// Claude Code again, resuming its session (--resume) when its plugin reported one
			cwd := tab.cwd != "" && os.is_dir(tab.cwd) ? tab.cwd : s.cwd
			ok = claude_start(s, t, tab.id, &tab.kind.(Claude_Tab), cwd, defaults = true) // shown by the user (an agent's focus leaves it not started): the default flags as set now
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
	window_state_changed() // from reload ticks too
	for b in tab.blockers do delete(b)
	clear(&tab.blockers)
	prog_summary_free(&tab.prog) // its terminal (and records) went with drop_term
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

// path = "" starts a new chat with `pi --session-id <id>`, so Deckhand knows
// which file it will be; otherwise resumes the file.
open_new_session :: proc(p: Project, pi_session_id: string, path: string, cwd := "", session_dir := "") -> (Result, bool) {
	if chat_readonly(p.id) && pi_readonly_too_old() do return fail(PI_READONLY_CHAT_TOO_OLD), false
	tab := Tab{id = new_id(), kind = Pi_Tab{readonly = chat_readonly(p.id)}, title = "pi"}
	// the bridge in this pi finds Deckhand with these (token = this tab, panel)
	env := chat_env(p.id, socket_pi_env({kind = .Panel, tab_id = tab.id}))
	// session_dir "": pi's own store, also for chats (`cd ~/Chats && pi --resume`)
	at := cwd != "" ? cwd : p.cwd // cwd: a worktree of the project
	if p.group == .Chats && !os.is_dir(p.cwd) {
		os.make_directory_all(p.cwd) // made on the first chat, with its instructions (folders.odin)
		chats_instructions_ensure(date_stamp())
	}
	if !start_pi(new_term(tab.id), &tab, pi_session_id, path, session_dir, at, env, chat_args(p.id)) {
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
	session_panes_init(&s)
	append(&state.open_sessions, s)
	focus_session(s.id, {kind = .Internal}) // a new session: nothing restored in it to start
	return {ok = true, created_id = s.id}, true
}

// A chat's pi is read-only when the user set Settings.chats_readonly; full pi
// by default. pi limits the tools the model may call (chat_args); PI_KIT_READONLY
// (chat_env) makes the guardrails read-only (the integration's optional one when
// on, or pi-kit's), keeps the integration's shell unregistered, and its
// app_open, app_restart and app_close.
chat_readonly :: proc(project_id: u64) -> bool {
	p := find_project(project_id)
	return p != nil && p.group == .Chats && state.settings.chats_readonly
}

// pi's flags for a read-only run, chats and read-only jobs alike. What they
// limit is the model's tools: `--tools` with plain names allowlists built-in,
// extension and custom tools by name (one it does not name is never
// registered, so neither an extension's setActiveTools nor a transcript turns
// it on), so the model has no bash, edit or write. A plain allowlist keeps
// `mcp__*` tools, whatever registers them: `--exclude-tools 'mcp__*'` drops
// those and `--no-mcp` pi's built-in MCP. What they do not limit: installed
// extensions still load and run their own code (hooks such as agent_end,
// slash commands), and an extension tool named read, grep, find or ls replaces
// the built-in one. pi keeps the last `--tools`, so these go last in argv
// (start_pi's extra). Needs pi PI_READONLY_MIN_PI (pi_readonly_too_old).
PI_READONLY_ARGS :: [?]string{"--tools", "read,grep,find,ls", "--exclude-tools", "mcp__*", "--no-mcp"}
// A read-only chat's: the same, plus desk_show (display only: it shows the user a file in a tab
// and gives the model nothing of it). In a chat's TUI Deckhand's bundled browser extension, loaded
// first (-e), owns that name; a job (pi --mode json) loads it inert, so jobs keep PI_READONLY_ARGS
// and another extension's desk_show is never allowed there.
PI_READONLY_CHAT_ARGS :: [?]string{"--tools", "read,grep,find,ls,desk_show", "--exclude-tools", "mcp__*", "--no-mcp"}

// The oldest pi whose flags mean the above: `--no-mcp` and `*` patterns came in
// 1.0.4 (and `--tools` allowlists extension tools since 0.68.0).
PI_READONLY_MIN_PI :: "1.0.4"
PI_READONLY_CHAT_TOO_OLD :: "Read-only chats need pi " + PI_READONLY_MIN_PI + " or newer; update pi or turn off read-only chats"
PI_READONLY_JOB_TOO_OLD :: "Read-only jobs need pi " + PI_READONLY_MIN_PI + " or newer; update pi or give the job full access"

// pi's version on disk (hot reload's look at its package.json) is known and
// older than PI_READONLY_MIN_PI. Unknown or unparsable: false (allowed).
pi_readonly_too_old :: proc() -> bool {
	v, ok := semver_parse(state.reload.pi_version)
	if !ok do return false
	min, _ := semver_parse(PI_READONLY_MIN_PI)
	return semver_less(v, min)
}

// The extra flags a chat's pi starts with (every start: new, resume, restore,
// restart, reload): PI_READONLY_CHAT_ARGS while chats are read-only, else none.
chat_args :: proc(project_id: u64) -> []string {
	if !chat_readonly(project_id) do return nil
	ro := PI_READONLY_CHAT_ARGS
	out := make([]string, len(ro), context.temp_allocator)
	copy(out, ro[:])
	return out
}

@(private = "file")
chat_env :: proc(project_id: u64, env: []string) -> []string {
	if !chat_readonly(project_id) do return env
	out := make([]string, len(env) + 1, context.temp_allocator)
	copy(out, env)
	out[len(env)] = "PI_KIT_READONLY=1"
	return out
}

// A new shell tab of s in pane `pane` (0: the focused one), started in cwd, not shown yet: its id,
// or why not.
// argv: what runs in place of the login shell (machine_login), title its tab's.
shell_tab_start :: proc(s: ^Open_Session, cwd: string, pane: u64 = 0, argv: []string = nil, title := "") -> (u64, string) {
	if s.machine != 0 do return 0, "this session runs on another machine" // never a local shell in it (machine_mirror.odin)
	tab := Tab{id = new_id(), kind = Shell_Tab{}, title = title != "" ? strings.clone(title) : fmt.aprintf("shell %d", len(s.tabs))}
	if cwd != s.cwd do tab.cwd = strings.clone(cwd)
	id := pane_add_tab(s, tab, pane = pane).id // first: its terminal is sized to its pane (tab_rect)
	t := new_term(id)
	if !term_start(t, argv != nil ? argv : {login_shell(), "-l"}, cwd, start = {kind = .Shell}) {
		drop_term(id)
		pane_tab_gone(s, id)
		for x, i in s.tabs do if x.id == id {
			delete(x.title)
			delete(x.cwd)
			ordered_remove(&s.tabs, i)
			break
		}
		return 0, "could not start the shell"
	}
	return id, ""
}

new_term :: proc(tab_id: u64) -> ^Term {
	t := new(Term)
	term_init(t, 80, 24)
	// size it to its pane before the child starts, so it sees the right grid (the window's
	// tab_rect; a tab not added yet: the focused pane's)
	window_term_fit(t, tab_id)
	terms[tab_id] = t
	return t
}

drop_term :: proc(tab_id: u64) {
	window_view_drop(tab_id) // its buffer, Markdown view, page or app (tab_views.odin)
	window_tab_facts_drop(tab_id) // what the window said of it (window.tab_facts)
	changes_drop(tab_id) // a Changes tab's view (changes.odin)
	if t := term_of(tab_id); t != nil {
		term_free(t)
		free(t)
		delete_key(&terms, tab_id)
	}
}

login_shell :: proc() -> string {
	shell := os.get_env("SHELL", context.temp_allocator)
	return shell != "" ? shell : "/bin/zsh"
}

// Login shells that do not take POSIX sh syntax (`fish -l -c 'for d in …; do'` fails), by name
// (a version suffix allowed: fish-3.7). Any other shell (zsh, bash, sh, dash, ksh…, and one
// Deckhand does not know) runs Deckhand's sh scripts itself, as it always has.
NON_POSIX_SHELLS :: [?]string{"fish", "nu", "nushell", "xonsh", "elvish", "tcsh", "csh", "pwsh", "pwsh-preview", "powershell", "ysh", "ion", "murex", "rc", "es"}

shell_is_posix :: proc(shell: string) -> bool {
	name := strings.trim_right(filepath.base(shell), "0123456789.-")
	for n in NON_POSIX_SHELLS do if name == n do return false
	return true
}

// argv that runs Deckhand's own sh script (PI_TAB_CMD, CLAUDE_TAB_CMD, a stand-in) with $0 = name;
// the caller appends the script's arguments ("$@"). A POSIX login shell runs it itself (`-l -c`:
// the login profile's PATH, as in a terminal); any other (fish, nushell, xonsh) would refuse sh
// syntax, so /bin/sh runs it, in the environment Deckhand took from the login shell at startup or
// at Refresh shell environment (login_env.odin), or the terminal's it was started from. Temp.
shell_script_argv :: proc(shell, script, name: string) -> [dynamic]string {
	argv := make([dynamic]string, context.temp_allocator)
	if shell_is_posix(shell) do append(&argv, shell, "-l", "-c", script, name)
	else do append(&argv, "/bin/sh", "-c", script, name)
	return argv
}

// pi, or why there is none (the shell's own "command not found" says too little).
// Not on PATH: pi's managed install ($PI_CODING_AGENT_DIR/bin, then
// ~/.pi/agent/bin; absolute folders only, never one relative to the project;
// pi_managed_path) runs, after a line saying where it was
// found and that PATH lacks it. Neither: what to do, exit 127 (dead_tab.odin).
PI_TAB_CMD :: `_pa=${PI_CODING_AGENT_DIR:-}; case "$_pa" in "~") _pa=$HOME;; "~/"*) _pa=$HOME/${_pa#"~/"};; esac; command -v pi >/dev/null 2>&1 || for d in "${_pa:+$_pa/bin}" "$HOME/.pi/agent/bin"; do case "$d" in /*) ;; *) continue;; esac; if [ -f "$d/pi" ] && [ -x "$d/pi" ]; then printf '%s\n' "Deckhand: pi is installed at $d/pi but is not on your login shell's PATH; starting it from there. Add $d to PATH in your shell's login profile (~/.zprofile for zsh) so other tools find it too."; PATH="$d:$PATH"; export PATH; break; fi; done; command -v pi >/dev/null 2>&1 || { printf '%s\n' "pi was not found: it is not on your login shell's PATH:" "  $PATH" "nor in ~/.pi/agent/bin (pi's managed install)." "Install pi, or add its folder to PATH in your shell's login profile (~/.zprofile for zsh, ~/.bash_profile for bash), then open this tab again."; exit 127; }; exec pi "$@"`

// Test mode (DECKHAND_SCRIPT) fails closed: without a stand-in a tab runs this instead of the real
// pi or claude (docs/DEVELOPING.md "Test mode"). Deckhand's own log says so too (test_mode_refused).
// (Test builds only: a release build has no test mode, test_hooks.odin.)
when TEST_HOOKS {
	TEST_NO_PI_CMD :: `printf '%s\n' "Deckhand test mode: no DECKHAND_CMD; refusing to run the real pi (DECKHAND_REAL_PI=1 allows it)"; exit 127`
	TEST_NO_CLAUDE_CMD :: `printf '%s\n' "Deckhand test mode: no DECKHAND_CLAUDE_CMD; refusing to run the real claude"; exit 127`
}

// Deckhand runs a test script (autotest.odin): scenes, never the user's own session.
test_mode :: proc() -> bool {return hook_env(.Script) != ""}

// Said on Deckhand's stderr (the scene's log) whenever test mode refuses a real binary.
test_mode_refused :: proc(what: string) {
	fmt.eprintf("Deckhand: test mode: refusing to run the real %s (no stand-in command set)\n", what)
}

// What a pi tab runs: DECKHAND_CMD (tests, benchmarks), else pi (PI_TAB_CMD); in test mode the
// real pi only with DECKHAND_REAL_PI=1 (real-pi scenes), else TEST_NO_PI_CMD.
pi_tab_cmd :: proc() -> string {
	if c := hook_env(.Cmd); c != "" do return c
	when TEST_HOOKS {
		if test_mode() && hook_env(.Real_Pi) != "1" {
			test_mode_refused("pi")
			return TEST_NO_PI_CMD
		}
	}
	return PI_TAB_CMD
}

@(private = "file")
start_pi :: proc(t: ^Term, tab: ^Tab, pi_session_id, path, session_dir, cwd: string, env: []string, extra: []string = nil, fork := "") -> bool {
	argv: [dynamic]string
	// A login shell finds pi on the user's PATH (from Finder or the Dock, PATH
	// is the interactive shell's: login_env.odin). DECKHAND_CMD replaces pi (benchmarks: e.g.
	// "cat big.log"); it sees the pi arguments as "$@". Test mode fails closed (pi_tab_cmd).
	argv = shell_script_argv(login_shell(), pi_tab_cmd(), "pi") // fish and co.: /bin/sh
	append(&argv, ..pi_integration_args()) // first: Deckhand's pi integration, `-e` per extension (pi_integration.odin)
	tab.reload.extras = pi_integration_extras() // which optional ones: a later change offers a restart (reload_outdated)
	if session_dir != "" do append(&argv, "--session-dir", session_dir)
	if fork != "" do append(&argv, "--fork", fork) // Atlas only (home_session_start): copied into session pi_session_id, here
	if path != "" do append(&argv, "--session", path)
	else do append(&argv, "--session-id", pi_session_id)
	append(&argv, ..extra) // last: a chat's read-only flags (chat_args)
	pk, _ := tab.kind.(Pi_Tab)
	return term_start(t, argv[:], cwd, pi_extra_env(env), {kind = .Pi, pi_ro = pk.readonly, extras = tab.reload.extras}) // + PI_KIT_NOTES_DIR (folders.odin)
}

// Runtime upkeep, not state changes: read every terminal (background tabs
// and sessions included), report exits as commands, shut down on exit.
pump_all :: proc() {
	for id, t in terms {
		term_pump(t)
		status_pump(id, t) // OSC 7501: the tab's new status, live records gone at exit (agent_status.odin)
		if !t.running {
			if id == harness_run.term_id do harness_run_exited(t.exit) // the checklist's install (harness_install.odin)
			else if _, tab, _ := find_tab(id); tab != nil && tab.status == .Running do run_command(Tab_Exited{tab_id = id, exit = t.exit})
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

// What the URL field's text becomes: a URL with a scheme Deckhand opens
// (http, https, file, about, deckhand-test: test fixtures) as is; a bare host
// ("example.com", "example.com/path", "example.com:8080") gets https://, a local
// one http://: localhost, 127.x, [::1], a private or tailnet IPv4 (10.x, 172.16-31.x,
// 192.168.x, 169.254.x, 100.64-127.x), and a one-word machine name with a port or a
// path ("nuc:3001", "nuc/": a LAN or tailnet host; a dev server rarely has TLS). A
// bare word alone, or anything with spaces, is not a web address: search is not
// built in yet (BROWSER.md §2.2). Pure.
browser_url_normalize :: proc(text: string, allocator := context.temp_allocator) -> (url: string, err: string) {
	t := strings.trim_space(text)
	if t == "" do return "", "type a web address"
	if strings.contains_any(t, " \t\n\r") do return "", "not a web address (search is not built in yet)"
	lower := strings.to_lower(t, context.temp_allocator)
	if lower == BROWSER_BLANK do return strings.clone(BROWSER_BLANK, allocator), ""
	if i := strings.index(lower, "://"); i > 0 {
		scheme := lower[:i]
		switch scheme {
		case "http", "https", "file", "deckhand-test":
			if len(t) == i + 3 do return "", "the address has nothing after ://"
			return strings.clone(t, allocator), ""
		}
		return "", fmt.tprintf("Deckhand does not open %s: addresses (http, https and file only)", scheme)
	}
	if strings.has_prefix(lower, "about:") || strings.has_prefix(lower, "javascript:") || strings.has_prefix(lower, "data:") || strings.has_prefix(lower, "mailto:") || strings.has_prefix(lower, "chrome:") {
		return "", fmt.tprintf("Deckhand does not open %s: addresses (http, https and file only)", lower[:strings.index_byte(lower, ':')])
	}
	// a bare host, maybe with a port and a path
	end := len(t)
	if k := strings.index_any(t, "/?#"); k >= 0 do end = k
	hostport := lower[:end]
	// user@host: never typed as a bare host here (127.0.0.1@evil.com is evil.com)
	if strings.contains_rune(hostport, '@') do return "", "not a web address (a user name before @ is not opened from here)"
	host := hostport
	if strings.has_prefix(host, "[") {
		// [::1]:8080
		k := strings.index_byte(host, ']')
		if k < 0 do return "", "not a web address"
		rest := host[k + 1:]
		host = host[:k + 1]
		if rest != "" && !port_ok(rest) do return "", "not a web address"
	} else if k := strings.index_byte(host, ':'); k >= 0 {
		if !port_ok(host[k:]) do return "", "not a web address (search is not built in yet)"
		host = host[:k]
	}
	if host == "" do return "", "not a web address"
	local := host == "localhost" || strings.has_suffix(host, ".localhost") || host == "[::1]" || strings.has_prefix(host, "127.") || private_ipv4(host)
	// a one-word machine name (LAN, tailnet) counts only with a port or a path: "nuc" alone could be a search
	if !local && !strings.contains_rune(host, '.') && len(host) <= 63 && (len(hostport) > len(host) || end < len(t)) {
		local = host[0] != '-' && host[len(host) - 1] != '-'
		for r in host do if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') do local = false
	}
	if !local {
		// letters, digits, - and . with a dot inside and a top-level part of letters (or an IPv4 address)
		if !strings.contains_rune(host, '.') || strings.has_prefix(host, ".") || strings.has_suffix(host, ".") do return "", "not a web address (search is not built in yet)"
		for r in host do if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '.' || r > 0x7f) do return "", "not a web address (search is not built in yet)"
		tld := host[strings.last_index_byte(host, '.') + 1:]
		ipv4 := true
		for r in host do if !(r >= '0' && r <= '9' || r == '.') do ipv4 = false
		if !ipv4 {
			for r in tld do if r >= '0' && r <= '9' do return "", "not a web address (search is not built in yet)"
			if len(tld) < 2 do return "", "not a web address (search is not built in yet)"
		}
	}
	return strings.concatenate({local ? "http://" : "https://", t}, allocator), ""

	// 10.x, 172.16-31.x, 192.168.x, 169.254.x and 100.64-127.x (CGNAT: a tailnet's), four numbers 0-255
	private_ipv4 :: proc(h: string) -> bool {
		n: [4]int
		parts := strings.split(h, ".", context.temp_allocator)
		if len(parts) != 4 do return false
		for p, i in parts {
			if len(p) == 0 || len(p) > 3 do return false
			for r in p {
				if r < '0' || r > '9' do return false
				n[i] = n[i] * 10 + int(r - '0')
			}
			if n[i] > 255 do return false
		}
		return n[0] == 10 || n[0] == 172 && n[1] >= 16 && n[1] <= 31 || n[0] == 192 && n[1] == 168 || n[0] == 169 && n[1] == 254 || n[0] == 100 && n[1] >= 64 && n[1] <= 127
	}

	port_ok :: proc(s: string) -> bool {
		// ":" then 1-5 digits
		if len(s) < 2 || len(s) > 6 || s[0] != ':' do return false
		for r in s[1:] do if r < '0' || r > '9' do return false
		return true
	}
}
