package main

import "core:time"

// All app state that matters to a user (or a controlling agent) lives in one
// plain struct: no pointers, ids instead of references, so it can be
// serialised and queried as-is (see `state_json`, json_write.odin). Runtime
// resources (PTYs, libghostty-vt terminals, GPU objects) live outside it,
// keyed by tab id.
//
// State only changes inside run_command (commands.odin). Readers may look at
// it anywhere on the main thread.
//
// Model: Project -> Session -> Tabs. An open session has one main tab (the
// first): its pi tab, or for a Claude-only session (agent .Claude,
// claude.odin) its Claude tab and no pi tab; plus any number of other tabs. A tab belongs to exactly one
// session for its whole life: it is created in a named session (a user's
// action in the session on screen, a command or agent in its own), never moves
// to another (no command or drag moves tabs between sessions), and what it
// makes (pending comments, comments.odin) goes to that session's pi.
//
// Ids: projects, open sessions and tabs get a runtime id (u64) that never
// changes or gets reused while the app runs; commands address them by it,
// never by list position. Identity that outlives a run (docs/PERSISTENCE.md):
// a project is its cwd, a session is pi's session id + cwd (+ session dir).

Pi_Tab :: struct {
	readonly: bool, // started read-only (chat_env: a chat while Chats: read-only is on)
}
Shell_Tab :: struct {}
Tab_Kind :: union {
	Pi_Tab,
	Shell_Tab,
	Editor_Tab, // a file (editor_commands.odin); its buffer lives in `editors`
	Changes_Tab, // a checkout's changes (changes.odin); its diff is a read-only editor in `editors`
	Markdown_Tab, // a .md file drawn as a document (markdown_view.odin); its source is a read-only editor in `editors`
	Browser_Tab, // a web page (browser.odin; CEF, docs/BROWSER.md)
	App_Tab, // a program rendering into the tab (app_tab.odin; docs/ENGINE-BRIDGE.md)
	Claude_Tab, // Claude Code in a terminal, with pi-desk's plugin (claude.odin; docs/CLAUDE.md)
}

Tab_Status :: enum {
	Running,
	Exited,
	Not_Started, // restored from the saved workspace; starts when its session is focused
}

// How a tab's process ended (its waitpid status), once pi-desk reaped it.
// Unknown when it could not be reaped (it kept running after closing its
// terminal, and was hung up on).
Exit_Info :: struct {
	known:  bool,
	code:   int, // exited: its status
	signal: int, // killed by this signal (0 = it exited)
}

// What a pi tab's bridge last reported (pi.status, docs/PROTOCOL.md §4).
// Unknown until the bridge connects; then it drives the close rule.
Agent_State :: enum {
	Unknown,
	Idle,
	Working,
	Error,
}

Tab :: struct {
	id:       u64,
	kind:     Tab_Kind,
	title:    string,
	status:   Tab_Status,
	exit:     Exit_Info, // status Exited: how its process ended (dead_tab.odin)
	cwd:      string, // shell tabs: where the shell starts ("" = the session's cwd)
	// pi tabs only, from the bridge
	agent:    Agent_State,
	waiting:  bool, // a pi dialog is open (question tool, permission): prompts are refused
	question: bool, // pi's last answer ended with a question (shown; does not block prompts)
	blockers: [dynamic]string,
	panels:   [dynamic]Panel, // published by the bridge (panel.set), in arrival order
	reload:   Tab_Reload, // pi tabs: hot reload's bookkeeping (reload.odin)
	bridge_at: time.Time, // pi tabs: when the bridge last reported (the status tooltip)
	// any terminal tab: what its program reports over OSC 7501 (agent_status.odin)
	prog:     Prog_Summary,
	unseen:   bool, // its agent finished while the user was not looking, or "Mark as unread"; not saved
	pane:     u64, // the pane of its session it sits in (panes.odin); not saved
	held:     u32, // restored with a session holder terminal id (workspace.json "held"): adopted at launch, then 0
	// its process still runs in a session holder this run could not attach to (it answered but
	// gave no WELCOME): never started here (that would be a second pi or Claude on one session),
	// saved as "held" again so the launch that reaches the holder adopts it (holder_adopt_all)
	held_away: u32,
}

// A panel's content from a pi tab's bridge (docs/PROTOCOL.md §5): rows only,
// no layout. pi-desk picks fonts and colours from the tone.
Panel_Tone :: enum {
	Normal,
	Accent,
	Muted,
	Dim,
	Warning,
	Success,
	Error,
}
Panel_Row :: struct {
	text: string,
	tone: Panel_Tone,
	head: bool, // a section title
}
Panel :: struct {
	id:    string, // "subagents", "shells", "todos", ...
	title: string,
	rows:  [dynamic]Panel_Row,
}

// Bounds per pi tab: a bridge cannot grow State without limit.
PANELS_MAX :: 16 // panels per tab
// Rows kept per tab across all its panels; a panel's rows past it become one
// "+N more" row. Keeps the worst case (16 full panels) inside the text
// layer's run cache, so a pulsing dot does not reshape every row each frame.
PANEL_ROWS_MAX :: 200
PANEL_TEXT_MAX :: 160 // bytes per row text (cut at a character boundary); rows show ~40 characters
PANEL_ID_MAX :: 64
PANEL_TITLE_MAX :: 128
COLLAPSED_MAX :: 64

// What runs in an open session's main tab (its first): pi, or Claude Code (a Claude-only session).
Session_Agent :: enum u8 {
	Pi,
	Claude,
}

Open_Session :: struct {
	id:            u64,
	agent:         Session_Agent,
	pi_session_id: string, // pi's session id (a UUID; pi-desk picks it for new chats); agent .Claude: its main tab's Claude session id ("" until reported)
	session_dir:   string, // "" = pi's default store
	session_file:  string, // as the bridge last reported it (pi.session); "" = unknown
	project_id:    u64,
	cwd:           string,
	tabs:          [dynamic]Tab, // the main tab (pi, or Claude's) is always tabs[0]
	active_tab:    u64, // tab id: always the focused pane's active tab (a mirror kept by panes.odin)
	missing:       bool, // restored, but its session file or cwd is gone: shown "gone", never started
	restored:      bool, // came from the saved workspace: kept in it even while gone
	home:          bool, // the Home session (state.home): no project, only its pi tab, not listed
	title:         string, // cached title from session_file (open_session_title)
	title_size:    i64, // session_file's size when title was read (read again when it grows)
	shown_at:      i64, // when it was last made current (ns; the Open group's order), 0 = never
	checked:       time.Tick, // session_file last looked at (title, mtime): at most once a second
	mtime:         time.Time, // session_file's modification time then
	comments:      [dynamic]Pending_Comment, // made on this session's tabs, for its pi (comments.odin); at most COMMENTS_MAX
	attach:        Comments_Attach, // their delivery to the pi tab's bridge (not in the snapshot)
	// its panes (panes.odin; docs/plans/split-panes.md): a binary layout tree whose leaves are
	// the panes, each showing one of its tabs. One pane for now. Not saved, not in the snapshot.
	panes:         [dynamic]Pane,
	nodes:         [dynamic]Layout_Node, // the tree, nodes[root]
	root:          int,
	focused_pane:  u64, // the pane that gets the keyboard
	pane_mru:      [dynamic]u64, // panes most recently focused last: where focus goes when one closes
}

// Left column and right panel sizes in logical px.
Layout :: struct {
	left_width:    f32,
	right_width:   f32,
	left_open:     bool, // the left column shows (⌘B)
	right_open:    bool,
	drawer_width:  f32, // the agent's chat drawer (⌘J)
	drawer_pinned: bool, // pinned: the drawer takes layout space instead of sliding over
	panels:      [dynamic]string, // open panels in the right column, in order
	collapsed:   [dynamic]string, // panel ids whose section is folded (any tab); at most COLLAPSED_MAX, oldest dropped
	left_tab:    Left_Tab, // what the left column shows (⌘⇧E switches)
}

// The left column's tabs.
Left_Tab :: enum {
	Sessions, // projects, sessions, chats (ui_sidebar.odin)
	Files, // the file tree of the project on screen (ui_files.odin)
	Settings, // pi's settings files as a tree (settings_files.odin, drawn by ui_files.odin)
	Jobs, // Atlas's jobs (jobs.odin, ui_jobs.odin)
}

// The Files tab (files.odin): which folders are expanded, per tree root
// (a project or session folder, real path; for the Settings tab also pi's
// agent folder as written), most recently used first. The
// tree's listings and the selected row are UI state, not here.
Files_Root :: struct {
	root: string, // real path
	dirs: [dynamic]string, // expanded folders, relative to root; at most FILES_EXPANDED_MAX, oldest dropped
}
// The checkout a project's Files tree shows instead of its own folder: a
// worktree (or the main checkout) of the same repository (worktrees.odin).
Files_Checkout :: struct {
	base: string, // the project or session folder (real path)
	path: string, // the checkout's top folder (real path)
}
Files_State :: struct {
	expanded:  [dynamic]Files_Root, // at most FILES_ROOTS_MAX, least recently used dropped
	filter:    string, // fuzzy words matched against paths (not saved)
	checkouts: [dynamic]Files_Checkout, // at most FILES_ROOTS_MAX, most recent first
}
FILES_ROOTS_MAX :: 32
FILES_EXPANDED_MAX :: 256

// A destructive command waiting for a resend with its token.
Pending_Confirmation :: struct {
	token:   string,
	summary: string,
	command: Command,
	class:   Command_Class,
	caller:  Caller,
}

// Destructive commands, grouped so confirmation policies are per class.
Command_Class :: enum {
	Tab_Close,
	Session_Restart, // reload or restart pi tabs (pi_reload, pi_reload_all, pi_restart_updated)
	Settings_Write, // later: edit pi settings
	App_Quit,
	Delete, // delete_path (to the Trash); later: remove projects, sessions
	Fs_Write, // a bound control caller creating or renaming outside its own project
	Open_Link, // a Markdown tab's web or mail link followed by a caller other than the user
}

// How a caller's destructive commands of one class are confirmed.
Confirm_Mode :: enum {
	Ask, // the user confirms in pi-desk's UI; the caller's own token is refused
	Trusted, // the caller may confirm its own tokens
	Auto, // no confirmation
}

// When closing a running tab asks first, per tab kind.
Close_Confirm :: enum {
	Auto, // shell: a program other than the shell runs in it; pi: always, until the bridge reports busy/idle
	Always,
	Never,
}

Tab_Kind_Id :: enum {
	Pi,
	Shell,
	Editor,
	Changes,
	Markdown,
	Browser,
	App,
	Claude,
}

// User settings. confirm and confirm_close are user-only (an agent can never
// raise its own confirmation mode); the look and motion are anyone's.
Settings :: struct {
	confirm:       [Caller_Kind][Command_Class]Confirm_Mode, // ui and internal entries are ignored
	confirm_close: [Tab_Kind_Id]Close_Confirm,
	theme:         Theme_Id, // the look (theme.odin)
	term_text_pt:  int, // terminals' and the editor's text size in points (0 = the look's, TYPE_CODE_PX)
	appearance:    Appearance, // light or dark: system (follows the OS), light, dark
	reduce_motion: bool, // no fades, no pulse
	text_size:     Text_Size, // the chrome's text (theme.odin); terminals keep their size
	chats_readonly: bool, // chats' pi starts with its read tools only (chat_args) and PI_KIT_READONLY=1
	claude_skip_permissions: bool, // the user's default flag for Claude tabs THEY start (claude_with_defaults); user-only, off by default
	agent_name:    string, // the built-in agent's name ("" = AGENT_NAME_DEFAULT)
	agent_model:   string, // the agent's model, "provider/id[:thinking]" ("" = pi's default); user-only
	notify_off:    bool, // no OS notifications from the agent while the window is in the background
	bell_off:      bit_set[Bell_Group], // kinds the bell does not collect (notify.odin); default: all on
	bell_os_off:   bool, // no OS notifications for bell entries (waiting, errors, jobs that need you) while in the background
	// jobs (jobs.odin; user-only)
	// the main folder and its subfolders (folders.odin; user-only)
	home_dir:      string, // the main folder: sessions/, jobs/, memory/, atlas/, chats/ ("" = not set)
	folders:       [Folder_Kind]string, // overrides ("" = <home_dir>/<name>; chats without a main folder: ~/Chats)
	setup_seen:    bool, // the first-run sheet was done or skipped
	pi_path:       string, // the pi the jobs run ("" = pi on jobs_path)
	jobs_path:     string, // PATH for job runs: the login shell's, read once
	jobs_paused:   bool, // the kill switch: no new runs
	job_limits:    Job_Limits,
	tidy_off:      bool, // the project list as found: no temp or missing folders hidden, no subfolders folded (project_tidy.odin)
	keep_sessions: bool, // Experimental: sessions keep running in the session holder when Deckhand quits (off by default)
	// Claude Code accounts (claude_accounts.odin; user-only): what the user changed (labels,
	// added, removed folders) and the account a new Claude session last started with
	claude_accounts:     [dynamic]Claude_Account_Setting,
	claude_account_last: string,
	last_harness: Harness, // the harness the user last started a session with from "New session" (harness.odin): the picker's first row
	claude_account_default: string, // the user's default account ("" = the environment's: CLAUDE_CONFIG_DIR, else ~/.claude)
	pi_extensions: [dynamic]Pi_Extension_Choice, // the user's on/off for the pi integration's optional extensions (pi_integration.odin; user-only); one not listed has the manifest's default
}

// Left column sections, each sorted on its own.
Sort_Section :: enum {
	Projects,
	Sessions, // the selected project's
	Chats,
}

Sort_By :: enum {
	Recent, // last activity first (newest session file)
	Name, // A to Z
	Created, // newest first
	Attention, // needs you, then finished and not seen, then working, then the rest (agent_status.odin: attention_tier); ties by recent activity
}

// How the left column shows projects and sessions (sidebar.odin). Pins and
// hidden items are kept by identity (project cwd, pi session id), so they
// outlive rescans and restarts. The filter and quick filters are not saved.
Sidebar :: struct {
	pinned_projects: [dynamic]string, // cwds, in pinned order
	pinned_sessions: [dynamic]string, // pi session ids (projects' and chats'), in pinned order
	hidden_projects: [dynamic]string, // cwds
	hidden_sessions: [dynamic]string, // pi session ids
	sort:            [Sort_Section]Sort_By,
	folded:          [Sidebar_Fold]bool, // a section's rows are folded under its header
	show_hidden:     bool,
	filter:          string, // words matched fuzzily against names, paths and titles
	only_running:    bool, // quick filters: running or waiting (either), pinned (also)
	only_waiting:    bool,
	only_pinned:     bool,
	expanded:        [dynamic]string, // parent and group rows shown open, by folder path (project_tidy.odin); others are collapsed
}

// Left column sections that fold.
Sidebar_Fold :: enum {
	Open, // the open sessions of every project, on top
	Projects,
	Chats,
}

SIDEBAR_LIST_MAX :: 500 // pinned or hidden items per list
FILTER_MAX :: 200 // bytes

State :: struct {
	projects:              [dynamic]Project, // left column (sessions.odin); the Chats entry is last
	selected_project:      u64, // project id, 0 = none
	sessions:              [dynamic]Session, // sessions of the selected project
	chats:                 [dynamic]Session, // project-less sessions (the Chats entry's)
	sidebar:               Sidebar,
	files:                 Files_State,
	open_sessions:         [dynamic]Open_Session,
	current_session:       u64, // open session id, 0 = none
	focus_widget:          string, // "" = the current tab's terminal has the keyboard
	layout:                Layout,
	pending_confirmations: [dynamic]Pending_Confirmation,
	settings:              Settings,
	home:                  u64, // the Home session (open session id; 0 = not made yet): pi-desk's own agent
	home_open:             bool, // the agent's chat drawer shows
	agent:                 Agent_Info, // the agent's unread count (agent.odin), from its bridge status
	home_model:            string, // agent_model when Atlas last started (agent.odin: --model again only when it changed)
	home_fork_from:        string, // Atlas's old session file while its fork into home_cwd() is not on disk yet (home.odin; "" = none)
	notices:               Notices, // the bell's entries (notify.odin; not saved)
	reload:                Reload_Info, // the hot-reload bar (reload.odin; not saved)
	next_id:               u64,
	version:               u64, // bumped by every command that changed state
	system_light:          bool, // the OS appearance is light (platform layer; not saved). Settings.appearance = system follows it
	jobs:                  [dynamic]Job_Row, // Atlas's jobs as the Jobs tab shows them (jobs.odin; from the notes and the data dir)
	jobs_unread:           int, // unread job runs
	jobs_notified:         int, // OS notifications sent for jobs (tests)
	home_dir_prev:         string, // the main folder before the user changed it (offered in Finder; not saved)
	comments_ask:          Comments_Ask, // the close prompt: a tab or session closed with comments not sent (comments.odin)
	claude_history:        [dynamic]Claude_Record, // Claude Code sessions pi-desk ran, most recent first (claude.odin; saved)
	claude_readonly_ids:   [dynamic]string, // Claude sessions that ran read-only, outside the history's cap (claude.odin §1a; saved)
	claude_disk:          [dynamic]Claude_Disk, // the selected project's Claude transcripts found on disk (claude_disk.odin; not saved)
	claude_disk_chats:    [dynamic]Claude_Disk, // the chats folder's
}

LEFT_WIDTH_DEFAULT :: 300
RIGHT_WIDTH_DEFAULT :: 320
DRAWER_WIDTH_DEFAULT :: 420
DRAWER_WIDTH_MIN :: 320
DRAWER_WIDTH_MAX :: 1600 // the room there is limits it first (drawer_w)

state := State {
	layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true, drawer_width = DRAWER_WIDTH_DEFAULT},
}

// Runtime side: one terminal per terminal-backed tab.
terms: map[u64]^Term

new_id :: proc() -> u64 {
	state.next_id += 1
	return state.next_id
}

find_project :: proc(id: u64) -> ^Project {
	for &p in state.projects do if p.id == id do return &p
	return nil
}

find_session :: proc(id: u64) -> ^Open_Session {
	for &s in state.open_sessions do if s.id == id do return &s
	return nil
}

// The open session holding tab `id`, the tab, and its position in the session.
find_tab :: proc(id: u64) -> (s: ^Open_Session, t: ^Tab, index: int) {
	for &os in state.open_sessions {
		for &tab, i in os.tabs do if tab.id == id do return &os, &tab, i
	}
	return nil, nil, -1
}

// The Home session and its pi tab, or nil.
home_session :: proc() -> ^Open_Session {return find_session(state.home)}
home_tab :: proc() -> ^Tab {return session_pi_tab(home_session())}

// The terminal that gets the keyboard: the agent's while its drawer has the
// keyboard (focus widget agent_input), else the current tab's.
key_term :: proc() -> ^Term {
	if state.focus_widget == "agent_input" && state.home_open do return agent_term()
	return active_term()
}

// The tab whose terminal gets the keyboard (as key_term).
key_tab :: proc() -> ^Tab {
	if state.focus_widget == "agent_input" && state.home_open do return home_tab()
	return active_tab()
}

cur :: proc() -> ^Open_Session {
	return find_session(state.current_session)
}

// The focused tab: the current session's focused pane's active tab (panes.odin), or nil.
active_tab :: proc() -> ^Tab {
	return session_focused_tab(cur())
}

term_of :: proc(tab_id: u64) -> ^Term {
	return terms[tab_id] or_else nil
}

active_term :: proc() -> ^Term {
	if tab := active_tab(); tab != nil do return term_of(tab.id)
	return nil
}

project_name :: proc(p: Project) -> string {
	return p.name != "" ? p.name : p.label
}

tab_kind_id :: proc(k: Tab_Kind) -> Tab_Kind_Id {
	switch _ in k {
	case Pi_Tab:     return .Pi
	case Shell_Tab:  return .Shell
	case Editor_Tab: return .Editor
	case Changes_Tab: return .Changes
	case Markdown_Tab: return .Markdown
	case Browser_Tab: return .Browser
	case App_Tab: return .App
	case Claude_Tab: return .Claude
	}
	return .Shell
}

any_running :: proc() -> bool {
	for s in state.open_sessions do for t in s.tabs do if t.status == .Running do return true
	return false
}

// Whether quitting stops something running: any running tab (as any_running), except, when
// keeps (the session holder keeps sessions at this quit), terminal tabs whose process runs in
// the holder and tabs that come back by themselves (editors, Markdown, browser pages, Changes:
// unsaved edits are asked about apart).
quit_would_stop :: proc(keeps: bool) -> bool {
	if !keeps do return any_running()
	for s in state.open_sessions do for t in s.tabs {
		if t.status != .Running do continue
		switch _ in t.kind {
		case Editor_Tab, Markdown_Tab, Browser_Tab, Changes_Tab:
			continue
		case Shell_Tab, Pi_Tab, Claude_Tab, App_Tab:
		}
		if x := term_of(t.id); x != nil && x.pty.held != 0 do continue
		return true
	}
	return false
}

// The pi tab of an open session (its first tab), or nil.
session_pi_tab :: proc(s: ^Open_Session) -> ^Tab {
	if s == nil || len(s.tabs) == 0 do return nil
	if _, is := s.tabs[0].kind.(Pi_Tab); !is do return nil
	return &s.tabs[0]
}

panel_collapsed :: proc(id: string) -> bool {
	for c in state.layout.collapsed do if c == id do return true
	return false
}

panel_free :: proc(p: ^Panel) {
	delete(p.id)
	delete(p.title)
	for r in p.rows do delete(r.text)
	delete(p.rows)
}

tab_clear_panels :: proc(t: ^Tab) {
	for &p in t.panels do panel_free(&p)
	clear(&t.panels)
}
