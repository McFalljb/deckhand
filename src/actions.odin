package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core"

// User-facing actions: the commands the command palette (palette.odin)
// offers by name, and the labels and shortcuts of the buttons that run them
// (ui_toolbar.odin: tooltips, the shortcuts sheet). One row per action; to
// expose a new command, add a row.
// `make` builds the command from the current state; the palette submits it
// through the inbox as the user (caller ui), exactly as a click does, so
// confirmations apply. `make` returns false when the action does not apply
// now (no session, no closable tab); such actions are not listed.
//
// `prepare` (optional) runs UI-only steps first, like filling the rename
// field. `pick_folder` actions ask the OS for a folder first (platform).

Action :: struct {
	id:          string, // stable: recents, tests
	label:       string,
	title:       proc() -> string, // optional: a label that changes (the agent's name)
	keys:        string, // shortcut shown in the palette ("" = none)
	make:        proc() -> (core.Command, bool),
	detail:      proc() -> string, // optional: current value, shown muted
	prepare:     proc(),
	pick_folder: bool, // make receives the picked folder in action_folder
	ui:          proc(), // runs instead of make's command (a UI step: the harness picker); make still says whether it applies
	no_palette:  bool, // a button and a shortcut only (the palette itself)
	// optional: a short toast once its command is sent ("Pinned"), for an action whose outcome
	// nothing on screen shows; read before it runs (a toggle says what it turns to)
	done:        proc() -> string,
}

// A toggle's toast: what it turns to ("Reduce motion on"), from whether it is on now.
@(private = "file")
turns :: proc(what: string, on_now: bool) -> string {return fmt.tprintf("%s %s", what, on_now ? "off" : "on")}

// The folder a pick_folder action got (valid while its make runs).
action_folder: string
// The subfolder the "folder_change" action sets (the row clicked).
folder_pick_kind: core.Folder_Kind

ACTIONS := [?]Action {
	{id = "palette", label = "Search or run a command", keys = "⌘K", no_palette = true, prepare = proc() {
		if !palette_is_open() do palette_reset()
	}, make = proc() -> (core.Command, bool) {return core.Set_Focus{"palette"}, true}},
	// a chat: outside any project (Chats); a session: in a project
	// both: the installed harnesses' picker, or the only one at once (harness.odin)
	{id = "new_chat", label = "New chat", keys = "⌘N", make = proc() -> (core.Command, bool) {
		c := core.chats_project()
		if c == nil do return nil, false
		return core.New_Chat{c.id}, true
	}, ui = proc() {if c := core.chats_project(); c != nil do new_session_ui(c.id)}},
	{id = "new_session", label = "New session", keys = "⇧⌘N", make = proc() -> (core.Command, bool) {
		if core.find_project(state.selected_project) == nil do return nil, false
		return core.New_Chat{state.selected_project}, true
	}, ui = proc() {new_session_ui(state.selected_project)}, detail = proc() -> string {
		p := core.find_project(state.selected_project)
		return p != nil ? fmt.tprintf("in %s", core.project_name(p^)) : ""
	}},
	{id = "chats_readonly", label = "Chats: read-only", make = proc() -> (core.Command, bool) {
		return core.Set_Chats_Readonly{on = !state.settings.chats_readonly}, true
	}, detail = proc() -> string {return state.settings.chats_readonly ? "on" : "off (full access)"}, done = proc() -> string {return state.settings.chats_readonly ? "Chats: full access" : "Chats read-only"}},
	{id = "claude_skip_permissions", label = "Claude Code: skip permissions in new tabs", make = proc() -> (core.Command, bool) {
		return core.Set_Claude_Default_Flags{skip_permissions = !state.settings.claude_skip_permissions}, true
	}, detail = proc() -> string {return state.settings.claude_skip_permissions ? "on: --dangerously-skip-permissions in the tabs you start" : "off"}, done = proc() -> string {return turns("Skip permissions", state.settings.claude_skip_permissions)}},
	{id = "chats_dir", label = "Chats folder…", pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder == "" do return core.Set_Folder{kind = .Chats, path = state.settings.folders[.Chats]}, true // listing
		return core.Set_Folder{kind = .Chats, path = action_folder}, true
	}, detail = proc() -> string {
		c := core.chats_project()
		return c != nil ? core.short_label(c.cwd) : ""
	}},
	{id = "chats_dir_default", label = "Chats folder: back to the default", make = proc() -> (core.Command, bool) {
		if !core.folder_custom(.Chats) do return nil, false
		return core.Set_Folder{kind = .Chats, path = ""}, true
	}, detail = proc() -> string {
		st := state.settings
		st.folders[.Chats] = ""
		return core.fs_display(core.folder_path(st, .Chats))
	}},
	// the chats folder's AGENTS.md (folders.odin): made with the starter if missing
	{id = "chat_instructions", label = "Edit chat instructions", make = proc() -> (core.Command, bool) {
		if core.cur() == nil do return nil, false
		d := core.chats_cwd()
		name := core.context_file(d)
		if name == "" do name = "AGENTS.md"
		return core.Open_File{path = fmt.tprintf("%s/%s", d, name)}, true
	}, prepare = proc() {
		if !os.is_dir(core.chats_cwd()) do os.make_directory_all(core.chats_cwd())
		core.chats_instructions_ensure(core.date_stamp())
	}},
	{id = "new_shell_tab", label = "New shell tab", keys = "⌘T", make = proc() -> (core.Command, bool) {
		cs := core.cur_view() // another machine's session: a shell there (machine_route.odin)
		if cs == nil do return nil, false
		return core.New_Shell_Tab{session = cs.id}, true
	}},
	// Claude Code (claude.odin): claude with Deckhand's plugin, in the session on screen's folder
	{id = "new_claude_tab", label = "New Claude tab", keys = "⌥⌘T", title = proc() -> string {return core.claude_label("New Claude tab")}, make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || cs.home || cs.missing do return nil, false // in chats too (read-only while chats are: claude.odin)
		return core.New_Claude_Tab{session = cs.id}, true
	}},
	{id = "claude_held_send", label = "Claude: send the waiting message now", make = proc() -> (core.Command, bool) {
		t := core.active_tab()
		if t == nil do return nil, false
		if ct, is := t.kind.(core.Claude_Tab); !is || len(ct.held) == 0 do return nil, false
		return core.Claude_Held_Op{tab_id = t.id, op = "send"}, true
	}},
	{id = "claude_held_drop", label = "Claude: drop the waiting messages", make = proc() -> (core.Command, bool) {
		t := core.active_tab()
		if t == nil do return nil, false
		if ct, is := t.kind.(core.Claude_Tab); !is || len(ct.held) == 0 do return nil, false
		return core.Claude_Held_Op{tab_id = t.id, op = "drop"}, true
	}},
	// browser tabs (browser_nav.odin): a blank page in the session on screen, its URL field focused
	{id = "new_browser_tab", label = "New browser tab", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || cs.home do return nil, false
		return core.Browser_Open{session = cs.id}, true
	}},
	{id = "browser_back", label = "Browser: back", make = proc() -> (core.Command, bool) {
		bt, id := browser_shown()
		if bt == nil || !bt.can_back do return nil, false
		return core.Browser_Back{id}, true
	}},
	{id = "browser_forward", label = "Browser: forward", make = proc() -> (core.Command, bool) {
		bt, id := browser_shown()
		if bt == nil || !bt.can_forward do return nil, false
		return core.Browser_Forward{id}, true
	}},
	{id = "browser_reload", label = "Browser: reload page", make = proc() -> (core.Command, bool) {
		bt, id := browser_shown()
		if bt == nil do return nil, false
		return core.Browser_Reload{id}, true
	}},
	// browser tabs' polish (browser_polish.odin): the keys (⌘F, ⌘+, ⌘−, ⌘0) are the page's while a
	// browser tab is on screen; the menu bar's items with those keys stay the editor's and the text's
	{id = "browser_find", label = "Browser: find in page", make = proc() -> (core.Command, bool) {
		b := tab_browser()
		if b == nil || b.cef == 0 do return nil, false
		return core.Set_Focus{"browser_find"}, true
	}, prepare = browser_find_prepare},
	{id = "browser_zoom_in", label = "Browser: zoom in", make = proc() -> (core.Command, bool) {return browser_zoom_action(.In)}},
	{id = "browser_zoom_out", label = "Browser: zoom out", make = proc() -> (core.Command, bool) {return browser_zoom_action(.Out)}},
	{id = "browser_zoom_reset", label = "Browser: actual size", make = proc() -> (core.Command, bool) {return browser_zoom_action(.Reset)}},
	{id = "browser_devtools", label = "Browser: DevTools", make = proc() -> (core.Command, bool) {
		b := tab_browser()
		if b == nil || b.cef == 0 do return nil, false
		p := page_extras[b.tab_id]
		return core.Browser_Devtools{tab_id = b.tab_id, x = -1, y = -1, close = p != nil && p.devtools}, true
	}},
	// the agent strip's buttons (browser_agent.odin), also when a narrow pane cuts its toolbar short
	{id = "browser_agent_takeover", label = "Browser: take over from the agent", make = proc() -> (core.Command, bool) {
		t := browser_agent_shown()
		if t == nil || t.user_control do return nil, false
		return core.Browser_Agent_Take_Over{tab_id = t.tab_id, on = true}, true
	}},
	{id = "browser_agent_handback", label = "Browser: hand back to the agent", make = proc() -> (core.Command, bool) {
		t := browser_agent_shown()
		if t == nil || !t.user_control do return nil, false
		return core.Browser_Agent_Take_Over{tab_id = t.tab_id, on = false}, true
	}},
	{id = "browser_agent_stop", label = "Browser: stop the agent", make = proc() -> (core.Command, bool) {
		t := browser_agent_shown()
		if t == nil do return nil, false
		return core.Browser_Agent_Stop{t.tab_id}, true
	}},
	{id = "browser_external", label = "Browser: open in default browser", make = proc() -> (core.Command, bool) {
		bt, id := browser_shown()
		if bt == nil || !browser_external_ok(bt.url) do return nil, false
		return core.Browser_External{id}, true
	}},
	{id = "browser_open_popup", label = "Browser: open the blocked popup", make = proc() -> (core.Command, bool) {
		bt, id := browser_shown()
		if bt == nil || bt.blocked_popup == "" do return nil, false
		return core.Browser_Popup{tab_id = id, open = true}, true
	}},
	{id = "browser_downloads", label = "Browser: show downloads folder", make = proc() -> (core.Command, bool) {
		if tab_browser() == nil do return nil, false
		return core.Browser_Download{download_id = 0, op = .Reveal}, true
	}},
	{id = "close_tab", label = "Close tab", keys = "⌘W", make = proc() -> (core.Command, bool) {
		cs := core.cur_view() // another machine's: closed there
		if cs == nil || len(cs.tabs) == 0 || cs.active_tab == cs.tabs[0].id do return nil, false // the pi tab stays
		return core.Close_Tab{tab_id = cs.active_tab}, true
	}},
	// the Changes tab (changes.odin): the session's checkout
	{id = "changes_open", label = "Show changes", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || cs.home || core.changes_root_of(cs.cwd) == "" do return nil, false
		return core.Changes_Open{session = cs.id}, true
	}, detail = proc() -> string {
		cs := core.cur()
		if cs == nil do return ""
		r := core.changes_repo(core.changes_root_of(cs.cwd))
		if r == nil || !r.loaded do return ""
		n := core.changes_count(r)
		return n == 1 ? "1 file" : fmt.tprintf("%d files", n)
	}},
	{id = "close_session", label = "Close session", make = proc() -> (core.Command, bool) {
		cs := core.cur_view() // another machine's: closed there
		if cs == nil do return nil, false
		return core.Close_Session{session = cs.id}, true
	}},
	// the core keeps the user's last closed tabs (core/closed_tabs.odin): "No closed tab to reopen" when none
	{id = "reopen_closed_tab", label = "Reopen closed tab", keys = "⇧⌘T", make = proc() -> (core.Command, bool) {return core.Reopen_Closed_Tab{}, true}},
	{id = "ask_agent", label = "Ask Atlas…", title = proc() -> string {return fmt.tprintf("Ask %s…", core.agent_name())}, make = proc() -> (core.Command, bool) {
		if !core.atlas_offered() do return nil, false // Atlas runs on pi (harness.odin)
		return core.Set_Home{open = true}, true // its terminal takes the keyboard
	}},
	// pi's own model selector in Atlas's terminal (agent.odin); the gear's row says "Atlas model…"
	{id = "agent_model", label = "Atlas: change model", title = proc() -> string {return fmt.tprintf("%s: change model", core.agent_name())}, make = proc() -> (core.Command, bool) {
		if !core.atlas_offered() do return nil, false
		return core.Agent_Model_Picker{}, true
	}, detail = proc() -> string {m := core.agent_model_short(); return m != "" ? m : "pi's default"}},
	{id = "agent_model_pop", label = "Atlas model…", title = proc() -> string {return fmt.tprintf("%s model…", core.agent_name())}, no_palette = true, make = proc() -> (core.Command, bool) {
		if !core.atlas_offered() do return nil, false
		return core.Agent_Model_Picker{}, true
	}, detail = proc() -> string {m := core.agent_model_short(); return m != "" ? m : "pi's default"}},
	// Atlas's prompt file (<data dir>/atlas/ATLAS.md), in an editor tab
	{id = "agent_prompt", label = "Atlas: edit prompt", title = proc() -> string {return fmt.tprintf("%s: edit prompt", core.agent_name())}, make = proc() -> (core.Command, bool) {
		if core.cur() == nil || core.home_root == "" do return nil, false
		p := core.agent_prompt_ensure()
		if p == "" do return nil, false
		return core.Open_File{path = p}, true
	}},
	// Atlas's jobs (jobs.odin, ui_jobs.odin)
	{id = "show_jobs", label = "Show jobs", make = proc() -> (core.Command, bool) {
		return core.Set_Left_Tab{tab = .Jobs}, true
	}, detail = proc() -> string {return state.jobs_unread > 0 ? fmt.tprintf("%d unread", state.jobs_unread) : ""}},
	{id = "job_new", label = "New job", make = proc() -> (core.Command, bool) {
		if core.folder_of(.Jobs) == "" do return nil, false
		return core.Job_Sheet{open = true}, true // the job sheet (ui_job_sheet.odin)
	}},
	// the main folder and its subfolders (folders.odin), the first-run sheet (ui_setup.odin)
	{id = "setup", label = "Set up Deckhand…", make = proc() -> (core.Command, bool) {
		return core.Setup_Sheet{open = true}, true
	}, detail = proc() -> string {return state.settings.home_dir != "" ? core.fs_display(state.settings.home_dir) : "no main folder"}},
	{id = "home_dir", label = "Main folder…", pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder == "" do return core.Set_Home_Dir{path = state.settings.home_dir}, true // listing
		return core.Set_Home_Dir{path = action_folder}, true
	}, detail = proc() -> string {return state.settings.home_dir != "" ? core.fs_display(state.settings.home_dir) : "not set"}},
	// a subfolder's Change… (the Settings tab's Folders group: folder_pick_kind first)
	{id = "folder_change", label = "Change…", no_palette = true, pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder == "" do return core.Set_Folder{kind = folder_pick_kind, path = state.settings.folders[folder_pick_kind]}, true
		return core.Set_Folder{kind = folder_pick_kind, path = action_folder}, true
	}},
	// Settings → Claude accounts → Add account…: a Claude Code config folder (claude_accounts.odin)
	{id = "claude_account_add", label = "Add Claude account…", pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder == "" do return nil, false
		return core.Add_Claude_Account{dir = action_folder}, true
	}},
	// the setup sheet's "Choose…" buttons: the picked folder goes into the sheet
	{id = "setup_pick_main", label = "Choose another folder…", no_palette = true, pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder != "" do setup_picked(false, action_folder)
		return core.Set_Focus{"setup"}, true
	}},
	{id = "setup_pick_account", label = "Add folder…", no_palette = true, pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder != "" do setup_account_picked(action_folder)
		return core.Set_Focus{"setup"}, true
	}},
	{id = "setup_pick_chats", label = "Choose separate folder…", no_palette = true, pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder != "" do setup_picked(true, action_folder)
		return core.Set_Focus{"setup"}, true
	}},
	{id = "jobs_pause_all", label = "Pause all jobs", make = proc() -> (core.Command, bool) {
		if state.settings.jobs_paused do return nil, false
		return core.Jobs_Pause{}, true
	}, done = proc() -> string {return "Jobs paused"}},
	{id = "jobs_resume_all", label = "Resume all jobs", make = proc() -> (core.Command, bool) {
		if !state.settings.jobs_paused do return nil, false
		return core.Jobs_Resume{}, true
	}, done = proc() -> string {return "Jobs resumed"}},
	{id = "jobs_stop_all", label = "Stop all running jobs", make = proc() -> (core.Command, bool) {
		for r in state.jobs do if r.running do return core.Job_Stop{}, true
		return nil, false
	}},
	{id = "toggle_agent", label = "Toggle Atlas", title = proc() -> string {return fmt.tprintf("Toggle %s", core.agent_name())}, keys = "⌘J", make = proc() -> (core.Command, bool) {
		if !core.atlas_offered() do return nil, false // Atlas runs on pi (harness.odin)
		return core.Set_Home{open = !state.home_open}, true
	}, detail = proc() -> string {return state.home_open ? "shown" : ""}},
	{id = "pin_agent", label = "Dock the agent's drawer", make = proc() -> (core.Command, bool) {
		return core.Set_Layout{drawer_pinned = !state.layout.drawer_pinned}, true
	}, detail = proc() -> string {return state.layout.drawer_pinned ? "pinned" : ""}},
	{id = "agent_notify", label = "Agent notifications", make = proc() -> (core.Command, bool) {
		return core.Set_Notify{on = state.settings.notify_off}, true
	}, detail = proc() -> string {return state.settings.notify_off ? "off" : "on"}, done = proc() -> string {return turns("Agent notifications", !state.settings.notify_off)}},
	// the bell (notify.odin, ui_bell.odin)
	{id = "notifications", label = "Notifications", make = proc() -> (core.Command, bool) {
		return core.Set_Focus{"notifications"}, true
	}, detail = proc() -> string {n := core.notices_unread(); return n > 0 ? fmt.tprintf("%d unread", n) : ""}},
	{id = "notifications_read", label = "Notifications: mark all read", make = proc() -> (core.Command, bool) {
		if core.notices_unread() == 0 do return nil, false
		return core.Notifications_Mark_Read{all = true}, true
	}},
	{id = "notifications_clear", label = "Notifications: clear", make = proc() -> (core.Command, bool) {
		if len(state.notices.items) == 0 do return nil, false
		return core.Notifications_Clear{}, true
	}},
	{id = "bell_finished", label = "Notify me about: Finished", make = proc() -> (core.Command, bool) {
		return core.Set_Bell{finished = .Finished in state.settings.bell_off}, true
	}, detail = proc() -> string {return .Finished in state.settings.bell_off ? "off" : "on"}, done = proc() -> string {return turns("Finished alerts", .Finished not_in state.settings.bell_off)}},
	{id = "bell_waiting", label = "Notify me about: Needs you", make = proc() -> (core.Command, bool) {
		return core.Set_Bell{waiting = .Waiting in state.settings.bell_off}, true
	}, detail = proc() -> string {return .Waiting in state.settings.bell_off ? "off" : "on"}, done = proc() -> string {return turns("Needs-you alerts", .Waiting not_in state.settings.bell_off)}},
	{id = "bell_errors", label = "Notify me about: Errors", make = proc() -> (core.Command, bool) {
		return core.Set_Bell{errors = .Errors in state.settings.bell_off}, true
	}, detail = proc() -> string {return .Errors in state.settings.bell_off ? "off" : "on"}, done = proc() -> string {return turns("Error alerts", .Errors not_in state.settings.bell_off)}},
	{id = "bell_jobs", label = "Notify me about: Jobs", make = proc() -> (core.Command, bool) {
		return core.Set_Bell{jobs = .Jobs in state.settings.bell_off}, true
	}, detail = proc() -> string {return .Jobs in state.settings.bell_off ? "off" : "on"}, done = proc() -> string {return turns("Job alerts", .Jobs not_in state.settings.bell_off)}},
	// the gear's grid (ui_toolbar.odin): each steps to the next choice
	{id = "bell_os_waiting", label = "Needs you: macOS notification", make = proc() -> (core.Command, bool) {return bell_os_step(.Waiting), true}, detail = proc() -> string {return bell_os_detail(.Waiting)}},
	{id = "bell_os_finished", label = "Finished: macOS notification", make = proc() -> (core.Command, bool) {return bell_os_step(.Finished), true}, detail = proc() -> string {return bell_os_detail(.Finished)}},
	{id = "bell_os_errors", label = "Errors: macOS notification", make = proc() -> (core.Command, bool) {return bell_os_step(.Errors), true}, detail = proc() -> string {return bell_os_detail(.Errors)}},
	{id = "bell_os_jobs", label = "Jobs: macOS notification", make = proc() -> (core.Command, bool) {return bell_os_step(.Jobs), true}, detail = proc() -> string {return bell_os_detail(.Jobs)}},
	{id = "bell_sound_waiting", label = "Needs you: sound", make = proc() -> (core.Command, bool) {return bell_sound_step(.Waiting), true}, detail = proc() -> string {return bell_sound_detail(.Waiting)}},
	{id = "bell_sound_finished", label = "Finished: sound", make = proc() -> (core.Command, bool) {return bell_sound_step(.Finished), true}, detail = proc() -> string {return bell_sound_detail(.Finished)}},
	{id = "bell_sound_errors", label = "Errors: sound", make = proc() -> (core.Command, bool) {return bell_sound_step(.Errors), true}, detail = proc() -> string {return bell_sound_detail(.Errors)}},
	{id = "bell_sound_jobs", label = "Jobs: sound", make = proc() -> (core.Command, bool) {return bell_sound_step(.Jobs), true}, detail = proc() -> string {return bell_sound_detail(.Jobs)}},
	{id = "bell_dock", label = "Badge Dock icon", make = proc() -> (core.Command, bool) {
		return core.Set_Bell{dock = state.settings.bell_dock_off}, true
	}, detail = proc() -> string {return state.settings.bell_dock_off ? "off" : "on (sessions waiting for you)"}, done = proc() -> string {return turns("Dock badge", !state.settings.bell_dock_off)}},
	{id = "toggle_left", label = "Toggle left column", keys = "⌘B", make = proc() -> (core.Command, bool) {
		return core.Set_Layout{left_open = !state.layout.left_open}, true
	}},
	{id = "toggle_right", label = "Toggle right column", keys = "⌥⌘B", make = proc() -> (core.Command, bool) {
		return core.Set_Layout{right_open = !state.layout.right_open}, true
	}},
	{id = "settings", label = "Settings…", keys = "⌘,", prepare = proc() {ui_do(core.Set_Left_Tab{tab = .Settings})}, make = proc() -> (core.Command, bool) {
		return core.Set_Focus{"files"}, true // the left column's Settings tab, with the keyboard (settings_files.odin)
	}},
	{id = "quick_settings", label = "Quick settings", no_palette = true, make = proc() -> (core.Command, bool) {
		return core.Set_Focus{"settings"}, true // the gear's popover (ui_toolbar.odin)
	}},
	{id = "edit_pi_settings", label = "Edit pi settings (settings.json)", make = proc() -> (core.Command, bool) {return core.settings_file_action("pi", "settings.json")}},
	{id = "edit_pi_models", label = "Edit pi models (models.json)", make = proc() -> (core.Command, bool) {return core.settings_file_action("pi", "models.json")}},
	{id = "edit_pi_agents_md", label = "Edit global AGENTS.md", make = proc() -> (core.Command, bool) {return core.settings_file_action("pi", "AGENTS.md")}},
	{id = "edit_project_settings", label = "Edit project pi settings (.pi/settings.json)", make = proc() -> (core.Command, bool) {return core.settings_file_action("project", ".pi/settings.json")}},
	// Claude Code's (settings_files.odin: the Settings tab's Claude groups; listed once Claude Code has its folder)
	{id = "edit_claude_settings", label = "Edit Claude settings (settings.json)", make = proc() -> (core.Command, bool) {return core.settings_file_action("claude", "settings.json")}},
	{id = "edit_claude_md", label = "Edit global CLAUDE.md", make = proc() -> (core.Command, bool) {return core.settings_file_action("claude", "CLAUDE.md")}},
	{id = "edit_claude_project_settings", label = "Edit project Claude settings", make = proc() -> (core.Command, bool) {return core.settings_file_action("claude-project", ".claude/settings.json")}, detail = proc() -> string {return ".claude/settings.json"}},
	{id = "shortcuts", label = "Keyboard shortcuts", keys = "⌘/", make = proc() -> (core.Command, bool) {
		return core.Set_Focus{"shortcuts"}, true // the shortcuts sheet (ui_toolbar.odin)
	}},
	{id = "look_graphite", label = "Look: Graphite", make = proc() -> (core.Command, bool) {return core.Set_Theme{.Graphite}, true}, detail = proc() -> string {return state.settings.theme == .Graphite ? "current" : ""}},
	{id = "look_warm", label = "Look: Warm", make = proc() -> (core.Command, bool) {return core.Set_Theme{.Warm}, true}, detail = proc() -> string {return state.settings.theme == .Warm ? "current" : ""}},
	{id = "look_ghostty", label = "Look: Ghostty", make = proc() -> (core.Command, bool) {return core.Set_Theme{.Ghostty}, true}, detail = proc() -> string {return state.settings.theme == .Ghostty ? "current" : ""}},
	{id = "appearance_system", label = "Appearance: System", make = proc() -> (core.Command, bool) {return core.Set_Appearance{.System}, true}, detail = proc() -> string {return state.settings.appearance == .System ? (state.system_light ? "current (light)" : "current (dark)") : ""}},
	{id = "appearance_light", label = "Appearance: Light", make = proc() -> (core.Command, bool) {return core.Set_Appearance{.Light}, true}, detail = proc() -> string {return state.settings.appearance == .Light ? "current" : ""}},
	{id = "appearance_dark", label = "Appearance: Dark", make = proc() -> (core.Command, bool) {return core.Set_Appearance{.Dark}, true}, detail = proc() -> string {return state.settings.appearance == .Dark ? "current" : ""}},
	{id = "text_small", label = "Text size: Small", make = proc() -> (core.Command, bool) {return core.Set_Text_Size{.Small}, true}, detail = proc() -> string {return state.settings.text_size == .Small ? "current" : ""}},
	{id = "text_medium", label = "Text size: Medium", make = proc() -> (core.Command, bool) {return core.Set_Text_Size{.Medium}, true}, detail = proc() -> string {return state.settings.text_size == .Medium ? "current" : ""}},
	{id = "text_default", label = "Text size: Default", make = proc() -> (core.Command, bool) {return core.Set_Text_Size{.Default}, true}, detail = proc() -> string {return state.settings.text_size == .Default ? "current" : ""}},
	{id = "text_large", label = "Text size: Large", make = proc() -> (core.Command, bool) {return core.Set_Text_Size{.Large}, true}, detail = proc() -> string {return state.settings.text_size == .Large ? "current" : ""}},
	{id = "reduce_motion", label = "Reduce motion", make = proc() -> (core.Command, bool) {
		return core.Set_Reduce_Motion{!state.settings.reduce_motion}, true
	}, detail = proc() -> string {return state.settings.reduce_motion ? "on" : "off"}, done = proc() -> string {return turns("Reduce motion", state.settings.reduce_motion)}},
	{id = "rescan", label = "Rescan sessions", make = proc() -> (core.Command, bool) {return core.Rescan{}, true}, done = proc() -> string {return "Rescanning sessions…"}},
	// login_env.odin: Dock and Finder launches only (a terminal's environment is that terminal's)
	{id = "refresh_shell_env", label = "Refresh shell environment", make = proc() -> (core.Command, bool) {return core.Refresh_Shell_Env{}, true}, detail = proc() -> string {
		return core.login_env.gui ? "new tabs only" : "uses the terminal's"
	}},
	{id = "copy_control_token", label = "Copy a control token", make = proc() -> (core.Command, bool) {return core.Copy_Control_Token{}, true}, detail = proc() -> string {return "for deckhand --ctl"}},
	{id = "separate_core", label = "Run sessions in a background core (at the next launch)", make = proc() -> (core.Command, bool) {
		return core.Set_Separate_Core{on = !state.settings.separate_core}, true
	}, detail = proc() -> string {return state.settings.separate_core ? "on" : "off"}},
	// machines.odin (on by default): links to the machines in Settings › Machines
	{id = "remote_machines", label = "Machines over SSH", make = proc() -> (core.Command, bool) {
		return core.Set_Remote_Machines{on = !state.settings.remote_machines}, true
	}, detail = proc() -> string {return state.settings.remote_machines ? "on" : "off"}},
	// the machines themselves: the same add field, commands and Settings group as the sidebar's
	{id = "machine_add", label = "Add a machine…", make = proc() -> (core.Command, bool) {
		return core.Set_Left_Tab{tab = .Settings}, state.settings.remote_machines
	}, ui = proc() {machine_add_open()}, detail = proc() -> string {return "over ssh"}},
	{id = "machine_remove", label = "Remove a machine…", make = proc() -> (core.Command, bool) {
		return core.Set_Focus{"palette"}, state.settings.remote_machines && len(state.machines) > 0
	}, prepare = proc() {palette_open_machines(.Remove)}},
	{id = "machine_connect", label = "Connect to a machine", make = proc() -> (core.Command, bool) {
		if state.settings.remote_machines do for m in state.machines do if machine_connectable(m) do return core.Set_Focus{"palette"}, true
		return nil, false
	}, prepare = proc() {palette_open_machines(.Connect)}},
	{id = "machines_settings", label = "Machines settings", make = proc() -> (core.Command, bool) {
		return core.Set_Left_Tab{tab = .Settings}, state.settings.remote_machines || state.settings.machines_reachable
	}, ui = proc() {
		ui_do(core.Set_Left_Tab{tab = .Settings})
		core.files_select_in(&core.settings_ui, state.settings.remote_machines ? core.MACHINE_ADD_ROW : core.MACHINE_REACH_ROW) // scrolled into view
	}},
	// a separate core only (core_handover.odin): the sessions go back to the core before the last update
	{id = "use_previous_core", label = "Use previous core", make = proc() -> (core.Command, bool) {
		return core.Core_Handover{to = core.CORE_PREVIOUS}, client_separate()
	}, detail = proc() -> string {return "background core"}},
	{id = "keep_sessions", label = "Keep sessions running when Deckhand quits", make = proc() -> (core.Command, bool) {
		return core.Set_Keep_Sessions{on = !state.settings.keep_sessions}, true
	}, detail = proc() -> string {return state.settings.keep_sessions ? "on" : "off"}, done = proc() -> string {return turns("Keep sessions running", state.settings.keep_sessions)}},
	// development builds only (holder_restart.odin, the core's): the session holder re-execs into
	// this build's holder binary in place; sessions keep running
	{id = "restart_session_holder", label = "Restart session holder", make = proc() -> (core.Command, bool) {
		return nil, core.holder_restart_offered()
	}, ui = proc() {client_internal(core.Holder_Restart{})}, detail = proc() -> string {return "development build: upgrade in place, sessions keep running"}},
	// development builds only (client.odin, tabhost_route.odin): the window plays gone, so agents'
	// page, app and file-view calls answer no_window (M4's case, now); Attach window brings it back
	{id = "detach_window", label = "Detach window", make = proc() -> (core.Command, bool) {
		return nil, core.TEST_HOOKS && client.attached && !client_separate() // a separate core's window: ⌘Q closes it for real
	}, ui = client_detach, detail = proc() -> string {return "development build: agents' page and app calls answer no_window"}},
	{id = "attach_window", label = "Attach window", make = proc() -> (core.Command, bool) {
		return nil, core.TEST_HOOKS && client.detached
	}, ui = client_reattach, detail = proc() -> string {return "development build: the window is the core's client again"}},
	{id = "tidy_projects", label = "Tidy project list", make = proc() -> (core.Command, bool) {
		return core.Set_Tidy_Projects{on = state.settings.tidy_off}, true
	}, detail = proc() -> string {return state.settings.tidy_off ? "off" : "on"}},
	// Deckhand's own updates (update.odin)
	{id = "check_updates", label = "Check for Updates…", make = proc() -> (core.Command, bool) {return core.Update_Check{}, true}, detail = proc() -> string {
		if core.update_view().offered do return fmt.tprintf("%s available", core.update_view().release.version)
		return core.update_view().current != "" ? fmt.tprintf("Deckhand %s", core.update_view().current) : ""
	}},
	{id = "update_checks", label = "Check for updates automatically", make = proc() -> (core.Command, bool) {
		return core.Set_Update_Check{on = core.update_view().checks_off}, true
	}, detail = proc() -> string {return core.update_view().checks_off ? "off" : "on (about once a day)"}, done = proc() -> string {return turns("Update checks", !core.update_view().checks_off)}},
	{id = "update_install", label = "Restart to update Deckhand", make = proc() -> (core.Command, bool) {
		if core.update_view().phase != .Ready do return nil, false
		return core.Update_Install{}, true
	}, detail = proc() -> string {return core.update_view().release.version}},
	// hot reload (reload.odin): /reload every pi tab; restart them on a new pi
	{id = "reload_all_pi", label = "Reload all pi tabs", make = proc() -> (core.Command, bool) {
		for &s in state.open_sessions do if t := core.session_pi_tab(&s); t != nil && t.status == .Running do return core.Pi_Reload_All{}, true
		return nil, false
	}},
	{id = "restart_updated_pi", label = "Restart pi tabs on the new pi", make = proc() -> (core.Command, bool) {
		for &s in state.open_sessions do if t := core.session_pi_tab(&s); t != nil && t.status == .Running && core.reload_outdated(t) do return core.Pi_Restart_Updated{}, true
		return nil, false
	}, detail = proc() -> string {return state.reload.pi_version != "" ? fmt.tprintf("pi %s", state.reload.pi_version) : ""}},
	// Claude tabs (claude_reload.odin): no /reload; a restart resumes each conversation, always confirmed
	{id = "restart_changed_claude", label = "Restart Claude tabs for changed settings", make = proc() -> (core.Command, bool) {
		for x in core.running_claude() do if x.t.reload.stale do return core.Claude_Restart_Changed{}, true
		return nil, false
	}},
	{id = "restart_updated_claude", label = "Restart Claude tabs on the new Claude Code", make = proc() -> (core.Command, bool) {
		for x in core.running_claude() do if core.claude_reload_outdated(x.t) do return core.Claude_Restart_Changed{update = true}, true
		return nil, false
	}, detail = proc() -> string {return state.reload.claude.version != "" ? fmt.tprintf("Claude Code %s", core.claude_version_label(state.reload.claude.version)) : ""}},
	{id = "restart_all_claude", label = "Restart all Claude tabs", make = proc() -> (core.Command, bool) {
		if len(core.running_claude()) == 0 do return nil, false
		return core.Claude_Restart_Changed{all = true}, true
	}},
	{id = "add_project", label = "Add project…", pick_folder = true, make = proc() -> (core.Command, bool) {
		if action_folder == "" do return core.Add_Project{}, true // listing: always available
		return core.Add_Project{cwd = action_folder}, true
	}},
	{id = "rename_project", label = "Rename project", prepare = proc() {
		if p := core.find_project(state.selected_project); p != nil do tf_set(&rename_field, core.project_name(p^))
	}, make = proc() -> (core.Command, bool) {
		if core.find_project(state.selected_project) == nil do return nil, false
		return core.Set_Focus{"rename_project"}, true
	}},
	// the left column (sidebar.odin): pins, hiding, filter, sort
	{id = "filter", label = "Filter projects and sessions", keys = "⇧⌘F", prepare = proc() {
		tf_set(&filter_field, state.sidebar.filter)
		tf_select_all(&filter_field)
	}, make = proc() -> (core.Command, bool) {return core.Set_Focus{"sidebar_filter"}, true}},
	{id = "clear_filter", label = "Clear filter", make = proc() -> (core.Command, bool) {
		if !core.sidebar_filtering() do return nil, false
		return core.Set_Filter{text = "", running = false, waiting = false, pinned = false}, true
	}},
	{id = "quick_running", label = "Filter: running", make = proc() -> (core.Command, bool) {return core.Set_Filter{running = !state.sidebar.only_running}, true}, detail = proc() -> string {return state.sidebar.only_running ? "on" : "off"}},
	{id = "quick_waiting", label = "Filter: waiting for you", make = proc() -> (core.Command, bool) {return core.Set_Filter{waiting = !state.sidebar.only_waiting}, true}, detail = proc() -> string {return state.sidebar.only_waiting ? "on" : "off"}},
	{id = "quick_pinned", label = "Filter: pinned", make = proc() -> (core.Command, bool) {return core.Set_Filter{pinned = !state.sidebar.only_pinned}, true}, detail = proc() -> string {return state.sidebar.only_pinned ? "on" : "off"}},
	{id = "show_hidden", label = "Show hidden projects and sessions", make = proc() -> (core.Command, bool) {return core.Set_Filter{show_hidden = !state.sidebar.show_hidden}, true}, detail = proc() -> string {return state.sidebar.show_hidden ? "on" : "off"}},
	{id = "pin_project", label = "Pin project", make = proc() -> (core.Command, bool) {
		p := core.find_project(state.selected_project)
		if p == nil || core.project_pinned(p^) >= 0 do return nil, false
		return core.Set_Pinned{project_id = p.id, pinned = true}, true
	}, detail = proc() -> string {p := core.find_project(state.selected_project); return p != nil ? core.project_name(p^) : ""}, done = proc() -> string {return "Pinned"}},
	{id = "unpin_project", label = "Unpin project", make = proc() -> (core.Command, bool) {
		p := core.find_project(state.selected_project)
		if p == nil || core.project_pinned(p^) < 0 do return nil, false
		return core.Set_Pinned{project_id = p.id, pinned = false}, true
	}, detail = proc() -> string {p := core.find_project(state.selected_project); return p != nil ? core.project_name(p^) : ""}, done = proc() -> string {return "Unpinned"}},
	{id = "hide_project", label = "Hide project", make = proc() -> (core.Command, bool) {
		p := core.find_project(state.selected_project)
		if p == nil || core.project_hidden(p^) do return nil, false
		return core.Set_Hidden{project_id = p.id, hidden = true}, true
	}, detail = proc() -> string {p := core.find_project(state.selected_project); return p != nil ? core.project_name(p^) : ""}},
	{id = "pin_session", label = "Pin session", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || !core.session_known(cs.pi_session_id) || core.session_pinned(cs.pi_session_id) >= 0 do return nil, false
		return core.Set_Pinned{pi_session_id = cs.pi_session_id, pinned = true}, true
	}, done = proc() -> string {return "Pinned"}},
	{id = "unpin_session", label = "Unpin session", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || core.session_pinned(cs.pi_session_id) < 0 do return nil, false
		return core.Set_Pinned{pi_session_id = cs.pi_session_id, pinned = false}, true
	}, done = proc() -> string {return "Unpinned"}},
	{id = "hide_session", label = "Hide session", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || !core.session_known(cs.pi_session_id) || core.session_hidden(cs.pi_session_id) do return nil, false
		return core.Set_Hidden{pi_session_id = cs.pi_session_id, hidden = true}, true
	}},
	{id = "sort_projects", label = "Sort projects (next order)", make = proc() -> (core.Command, bool) {return next_sort(.Projects), true}, detail = proc() -> string {return SORT_SHORT[state.sidebar.sort[.Projects]]}},
	{id = "sort_sessions", label = "Sort sessions (next order)", make = proc() -> (core.Command, bool) {return next_sort(.Sessions), true}, detail = proc() -> string {return SORT_SHORT[state.sidebar.sort[.Sessions]]}},
	{id = "sort_chats", label = "Sort chats (next order)", make = proc() -> (core.Command, bool) {return next_sort(.Chats), true}, detail = proc() -> string {return SORT_SHORT[state.sidebar.sort[.Chats]]}},
	{id = "quit", label = "Quit Deckhand", keys = "⌘Q", make = proc() -> (core.Command, bool) {return core.Quit{}, true}},
	{id = "quit_stop_sessions", label = "Quit Deckhand and Stop All Sessions…", make = proc() -> (core.Command, bool) {return core.Quit{stop_sessions = true}, true}},
	// the terminals' and the editor's text size (the menu bar's View menu)
	{id = "text_bigger", label = "Bigger text", keys = "⌘+", make = proc() -> (core.Command, bool) {
		pt := int(term_text_pt())
		if pt >= core.TERM_TEXT_MAX do return nil, false
		return core.Set_Terminal_Text_Size{pt = pt + 1}, true
	}, detail = proc() -> string {return fmt.tprintf("%d pt", int(term_text_pt()))}},
	{id = "text_smaller", label = "Smaller text", keys = "⌘−", make = proc() -> (core.Command, bool) {
		pt := int(term_text_pt())
		if pt <= core.TERM_TEXT_MIN do return nil, false
		return core.Set_Terminal_Text_Size{pt = pt - 1}, true
	}, detail = proc() -> string {return fmt.tprintf("%d pt", int(term_text_pt()))}},
	{id = "text_reset", label = "Actual text size", keys = "⌘0", make = proc() -> (core.Command, bool) {
		if state.settings.term_text_pt == 0 do return nil, false
		return core.Set_Terminal_Text_Size{pt = 0}, true
	}},
	// panes (panes_commands.odin, ui_panes.odin; the Window menu)
	{id = "split_right", label = "Split pane right", keys = "⌘D", make = proc() -> (core.Command, bool) {return pane_split_action(.Right)}},
	{id = "split_down", label = "Split pane down", keys = "⇧⌘D", make = proc() -> (core.Command, bool) {return pane_split_action(.Down)}},
	{id = "close_pane", label = "Close pane (its tabs stay)", keys = "⇧⌘W", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || len(cs.panes) <= 1 do return nil, false
		return core.Close_Pane{pane = cs.focused_pane}, true
	}},
	{id = "equalize_panes", label = "Even out panes", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || len(cs.panes) <= 1 do return nil, false
		return core.Equalize_Panes{session = cs.id}, true
	}},
	{id = "focus_pane_left", label = "Focus pane left", keys = "⌃⌘←", make = proc() -> (core.Command, bool) {return pane_focus_action(.Left)}},
	{id = "focus_pane_right", label = "Focus pane right", keys = "⌃⌘→", make = proc() -> (core.Command, bool) {return pane_focus_action(.Right)}},
	{id = "focus_pane_up", label = "Focus pane up", keys = "⌃⌘↑", make = proc() -> (core.Command, bool) {return pane_focus_action(.Up)}},
	{id = "focus_pane_down", label = "Focus pane down", keys = "⌃⌘↓", make = proc() -> (core.Command, bool) {return pane_focus_action(.Down)}},
	{id = "move_tab_left", label = "Move tab to the pane left", keys = "⌃⇧⌘←", make = proc() -> (core.Command, bool) {return pane_move_action(.Left)}},
	{id = "move_tab_right", label = "Move tab to the pane right", keys = "⌃⇧⌘→", make = proc() -> (core.Command, bool) {return pane_move_action(.Right)}},
	{id = "move_tab_up", label = "Move tab to the pane above", keys = "⌃⇧⌘↑", make = proc() -> (core.Command, bool) {return pane_move_action(.Up)}},
	{id = "move_tab_down", label = "Move tab to the pane below", keys = "⌃⇧⌘↓", make = proc() -> (core.Command, bool) {return pane_move_action(.Down)}},
	// tabs and sessions in order (the Window menu)
	{id = "next_tab", label = "Next tab", keys = "⇧⌘]", make = proc() -> (core.Command, bool) {return tab_step(1)}},
	{id = "prev_tab", label = "Previous tab", keys = "⇧⌘[", make = proc() -> (core.Command, bool) {return tab_step(-1)}},
	{id = "tab_1", label = "Tab 1", keys = "⌘1", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(0)}},
	{id = "tab_2", label = "Tab 2", keys = "⌘2", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(1)}},
	{id = "tab_3", label = "Tab 3", keys = "⌘3", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(2)}},
	{id = "tab_4", label = "Tab 4", keys = "⌘4", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(3)}},
	{id = "tab_5", label = "Tab 5", keys = "⌘5", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(4)}},
	{id = "tab_6", label = "Tab 6", keys = "⌘6", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(5)}},
	{id = "tab_7", label = "Tab 7", keys = "⌘7", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(6)}},
	{id = "tab_8", label = "Tab 8", keys = "⌘8", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(7)}},
	{id = "tab_9", label = "Tab 9", keys = "⌘9", no_palette = true, make = proc() -> (core.Command, bool) {return tab_nth(8)}},
	{id = "next_session", label = "Next session", keys = "⌥⌘↓", make = proc() -> (core.Command, bool) {return session_step(1)}},
	{id = "prev_session", label = "Previous session", keys = "⌥⌘↑", make = proc() -> (core.Command, bool) {return session_step(-1)}},
	// the core picks where (core/needing_you.odin): "Nothing needs you" when nothing does
	{id = "next_needing_you", label = "Next needing you", keys = "⌥⌘A", make = proc() -> (core.Command, bool) {return core.Next_Needing_You{}, true}},
	{id = "prev_needing_you", label = "Previous needing you", keys = "⌥⇧⌘A", make = proc() -> (core.Command, bool) {return core.Next_Needing_You{back = true}, true}},
	// "finished, not seen" by hand (core/agent_status.odin's set_unread, as the row menu's Mark as unread)
	{id = "mark_unread", label = "Mark as unread", keys = "⇧⌘U", make = mark_unread},
	{id = "mark_all_read", label = "Mark all as read", keys = "⌥⇧⌘U", make = proc() -> (core.Command, bool) {return nil, true}, ui = mark_all_read},
	// the session shown before this one, as ⌘-Tab between two apps (shown_at); ⌃⇧⇥: the one shown longest ago
	{id = "recent_session", label = "Recent session", keys = "⌃⇥", make = proc() -> (core.Command, bool) {return session_recent(false)}},
	{id = "least_recent_session", label = "Least recent session", keys = "⌃⇧⇥", make = proc() -> (core.Command, bool) {return session_recent(true)}},
	// the Open section's rows as ordered now (sidebar_open)
	{id = "session_1", label = "Go to open session 1", keys = "⌥⌘1", make = proc() -> (core.Command, bool) {return session_nth(0)}, detail = proc() -> string {return session_nth_title(0)}},
	{id = "session_2", label = "Go to open session 2", keys = "⌥⌘2", make = proc() -> (core.Command, bool) {return session_nth(1)}, detail = proc() -> string {return session_nth_title(1)}},
	{id = "session_3", label = "Go to open session 3", keys = "⌥⌘3", make = proc() -> (core.Command, bool) {return session_nth(2)}, detail = proc() -> string {return session_nth_title(2)}},
	{id = "session_4", label = "Go to open session 4", keys = "⌥⌘4", make = proc() -> (core.Command, bool) {return session_nth(3)}, detail = proc() -> string {return session_nth_title(3)}},
	{id = "session_5", label = "Go to open session 5", keys = "⌥⌘5", make = proc() -> (core.Command, bool) {return session_nth(4)}, detail = proc() -> string {return session_nth_title(4)}},
	{id = "session_6", label = "Go to open session 6", keys = "⌥⌘6", make = proc() -> (core.Command, bool) {return session_nth(5)}, detail = proc() -> string {return session_nth_title(5)}},
	// the guide's copy in the data dir (agent.odin), in a Markdown tab: read-only (editor_load)
	{id = "user_guide", label = "Deckhand user guide", make = proc() -> (core.Command, bool) {
		p := core.agent_guide_path()
		if core.cur() == nil || p == "" || !os.exists(p) do return nil, false
		return core.Markdown_Open{path = p}, true
	}},
	// the Markdown tab (markdown_view.odin): an editor's .md file as a document, or a Markdown tab's other view
	{id = "markdown_preview", label = "Markdown preview", keys = "⇧⌘V", make = proc() -> (core.Command, bool) {
		tab := core.active_tab()
		if tab == nil do return nil, false
		if mt, is := tab.kind.(core.Markdown_Tab); is do return core.Markdown_Set_View{tab_id = tab.id, source = !mt.source}, true
		e := tab_editor()
		if e == nil || e.view != .File || e.refused != "" || !core.md_is_markdown_path(e.path) do return nil, false
		return core.Markdown_Open{path = e.path}, true
	}, detail = proc() -> string {
		tab := core.active_tab()
		if tab == nil do return ""
		if mt, is := tab.kind.(core.Markdown_Tab); is do return mt.source ? "show the preview" : "show the source"
		return "open in a Markdown tab"
	}},
	{id = "markdown_edit", label = "Open in editor", make = proc() -> (core.Command, bool) {
		tab := core.active_tab()
		if tab == nil do return nil, false
		mt, is := tab.kind.(core.Markdown_Tab)
		if !is do return nil, false
		return core.Open_File{path = mt.path}, true
	}},
	// another machine's web page in a local browser tab (machine_page.odin): the palette asks for its port
	{id = "machine_open_page", label = "Open a machine's web page…", make = proc() -> (core.Command, bool) {
		for m in state.machines do if m.status == .Online do return core.Set_Focus{"palette"}, true
		return nil, false
	}, prepare = proc() {palette_open_pages(0)}},
	// app tabs (app_tab.odin): the palette asks for a command line, or lists .deckhand/apps.json's
	{id = "new_app_tab", label = "New app tab…", make = proc() -> (core.Command, bool) {
		cs := core.cur()
		if cs == nil || cs.home do return nil, false
		return core.Set_Focus{"palette"}, true
	}, prepare = proc() {
		palette_reset()
		palette.apps = true
		palette.was_open = true
	}},
	{id = "app_inspect", label = "Inspect app boxes", make = proc() -> (core.Command, bool) {
		a := tab_app()
		if a == nil do return nil, false
		return core.App_Inspect{tab_id = a.tab_id, on = !a.inspect}, true
	}, detail = proc() -> string {
		a := tab_app()
		return a != nil && a.inspect ? "on" : "off"
	}},
	// editor (editor_*.odin)
	{id = "open_file", label = "Open file…", keys = "⌘P", make = proc() -> (core.Command, bool) {
		if core.fs_base_dir() == "" || core.cur() == nil do return nil, false
		return core.Set_Focus{"palette"}, true
	}, prepare = proc() {
		palette_reset()
		palette.files = true
		palette.was_open = true
	}},
	{id = "save_file", label = "Save", keys = "⌘S", make = proc() -> (core.Command, bool) {
		e := tab_editor()
		if e == nil || e.view != .File || e.refused != "" do return nil, false
		return core.Save_File{e.tab_id}, true
	}},
	{id = "find_in_file", label = "Find in file", keys = "⌘F", make = proc() -> (core.Command, bool) {
		e := tab_editor()
		if e == nil || e.refused != "" do return nil, false
		return core.Set_Focus{"editor_find"}, true
	}, prepare = proc() {if e := tab_editor(); e != nil do e.bar = .Find}},
	{id = "goto_line", label = "Go to line…", keys = "⌘L", make = proc() -> (core.Command, bool) {
		e := tab_editor()
		if e == nil || e.refused != "" do return nil, false
		return core.Set_Focus{"editor_goto"}, true
	}, prepare = proc() {
		if e := tab_editor(); e != nil {
			e.bar = .Goto
			tf_set(&e.find.goto_line, "")
		}
	}},
	{id = "toggle_wrap", label = "Toggle soft wrap", make = proc() -> (core.Command, bool) {
		e := tab_editor()
		if e == nil do return nil, false
		return core.Set_Wrap{e.tab_id, !e.wrap}, true
	}, detail = proc() -> string {
		e := tab_editor()
		return e != nil && e.wrap ? "on" : "off"
	}},
	{id = "diff_head", label = "Diff with HEAD", make = proc() -> (core.Command, bool) {
		e := tab_editor()
		if e == nil || e.view != .File || e.refused != "" || !e.git.in_repo do return nil, false
		return core.Diff_File{e.tab_id, .Diff_Head}, true
	}},
	// the Files tab (ui_files.odin)
	{id = "show_files", label = "Files", keys = "⇧⌘E", prepare = proc() {
		if state.layout.left_tab != .Files do ui_do(core.Set_Left_Tab{tab = .Files})
	}, make = proc() -> (core.Command, bool) {
		return core.Set_Focus{"files"}, true // the Files tab, with the keyboard (opens the left column)
	}},
	{id = "show_sessions", label = "Sessions and projects", prepare = proc() {
		if state.focus_widget == "files" do ui_do(core.Set_Focus{""}) // the Files or Settings tree had the keyboard
	}, make = proc() -> (core.Command, bool) {
		return core.Set_Left_Tab{tab = .Sessions}, true
	}},
	{id = "files_new_file", label = "New file…", make = proc() -> (core.Command, bool) {
		if core.files_root() == "" || files_new_target() == "" do return nil, false
		return core.Set_Focus{"files_name"}, true
	}, prepare = proc() {files_begin_edit(.New_File, files_new_target(), "", focus = false)}},
	{id = "files_new_folder", label = "New folder…", make = proc() -> (core.Command, bool) {
		if core.files_root() == "" || files_new_target() == "" do return nil, false
		return core.Set_Focus{"files_name"}, true
	}, prepare = proc() {files_begin_edit(.New_Folder, files_new_target(), "", focus = false)}},
	{id = "files_collapse_all", label = "Collapse all folders", make = proc() -> (core.Command, bool) {
		root := core.files_root()
		if root == "" do return nil, false
		return core.Files_Collapse_All{root = root}, true
	}, done = proc() -> string {return "Folders collapsed"}},
	{id = "files_refresh", label = "Refresh files", make = proc() -> (core.Command, bool) {
		root := core.files_root()
		if root == "" do return nil, false
		return core.Set_Left_Tab{tab = .Files}, true
	}, prepare = proc() {
		// listings, git status and the file list are read again
		core.fs_model_changed(core.files_root())
		core.files_refresh()
	}},
	{id = "files_reveal_finder", label = "Reveal in Finder", make = proc() -> (core.Command, bool) {
		root := core.files_root()
		if root == "" do return nil, false
		p := core.files_ui.cursor
		if p == "" || !strings.has_prefix(p, root) || !os.exists(p) do p = root
		return core.Reveal_In_Finder{path = p}, true
	}},
	{id = "files_reveal_active", label = "Reveal active file in Files", make = proc() -> (core.Command, bool) {
		e := tab_editor()
		if e == nil || e.view != .File do return nil, false
		return core.Files_Reveal{path = e.path}, true
	}, prepare = proc() {
		if !files_shown() do ui_do(core.Set_Left_Tab{tab = .Files})
	}},
	// the Settings tab (settings_files.odin, drawn by ui_files.odin)
	{id = "settings_collapse_all", label = "Collapse all settings folders", make = proc() -> (core.Command, bool) {
		ad := core.settings_agent_dir()
		if len(core.files_expanded_dirs(ad)) == 0 && len(core.settings_open_pi_dirs()) == 0 do return nil, false
		return core.Files_Collapse_All{root = ad}, true
	}, prepare = proc() {
		// the project's .pi/ folders are in the project's tree: closed one by one
		for p in core.settings_open_pi_dirs() do ui_do(core.Files_Expand{path = p, expanded = false})
	}, done = proc() -> string {return "Folders collapsed"}},
	{id = "settings_refresh", label = "Refresh settings files", make = proc() -> (core.Command, bool) {
		return core.Set_Left_Tab{tab = .Settings}, true
	}, prepare = proc() {
		// every listing of the tree is read again
		ad := core.settings_agent_dir()
		core.files_path_changed(ad)
		for d in core.files_cached_dirs(ad) do core.files_path_changed(d)
		if cwd := core.settings_project_cwd(); cwd != "" do core.fs_model_changed(strings.concatenate({cwd, "/.pi"}, context.temp_allocator))
		core.harness_checklist_refresh() // the Coding agents group looks again (ui_harness.odin)
		core.settings_gen += 1
	}},
	{id = "settings_reveal_finder", label = "Reveal in Finder", no_palette = true, make = proc() -> (core.Command, bool) {
		p := core.settings_ui.cursor // a row of the tree (Reveal_In_Finder checks it again)
		if p == "" || !os.exists(p) do p = core.settings_agent_dir()
		if !os.exists(p) do return nil, false
		return core.Reveal_In_Finder{path = p}, true
	}},
	{id = "reveal_file", label = "Reveal in Finder", make = proc() -> (core.Command, bool) {
		e := tab_editor()
		if e == nil || e.view != .File do return nil, false
		return core.Reveal_In_Finder{path = e.path}, true
	}},
}

// The tab `d` steps from the current one, round the session's tabs.
// The tab `d` steps from the focused one, within the focused pane's strip (panes.odin).
tab_step :: proc(d: int) -> (core.Command, bool) {
	cs := core.cur()
	if cs == nil do return nil, false
	p := core.session_focused_pane(cs)
	strip := core.pane_strip(cs, p)
	if len(strip) < 2 do return nil, false
	for id, i in strip do if id == p.active do return core.Focus_Tab{strip[(i + d + len(strip)) % len(strip)]}, true
	return core.Focus_Tab{strip[0]}, true
}

// The focused pane's i-th tab (panes.odin).
tab_nth :: proc(i: int) -> (core.Command, bool) {
	cs := core.cur_view() // another machine's: its tab there
	if cs == nil do return nil, false
	strip := core.pane_strip(cs, core.session_focused_pane(cs))
	if i >= len(strip) do return nil, false
	return core.Focus_Tab{strip[i]}, true
}

// The open session `d` steps from the current one, in the Open section's order.
session_step :: proc(d: int) -> (core.Command, bool) {
	rows := core.sidebar_open()
	if len(rows) == 0 || (len(rows) == 1 && rows[0].id == state.current_session) do return nil, false
	for s, i in rows do if s.id == state.current_session do return core.Focus_Session{session = rows[(i + d + len(rows)) % len(rows)].id}, true
	return core.Focus_Session{session = rows[0].id}, true
}

// The open session shown most recently before the current one (least: the one shown longest ago),
// this Mac's or an online machine's; Home never.
session_recent :: proc(least: bool) -> (core.Command, bool) {
	best: ^core.Open_Session
	for &s in state.open_sessions {
		if s.home || s.id == state.current_session do continue
		if s.machine != 0 {
			online := false
			for m in state.machines do if m.no == s.machine do online = m.status == .Online
			if !online do continue
		}
		if best == nil || (least ? s.shown_at < best.shown_at : s.shown_at > best.shown_at) do best = &s
	}
	if best == nil do return nil, false
	return core.Focus_Session{session = best.id}, true
}

// The Open section's i-th row (this Mac's sessions, ordered as the sidebar shows them).
session_nth :: proc(i: int) -> (core.Command, bool) {
	rows := core.sidebar_open()
	if i >= len(rows) do return nil, false
	return core.Focus_Session{session = rows[i].id}, true
}

session_nth_title :: proc(i: int) -> string {
	rows := core.sidebar_open()
	return i < len(rows) ? core.open_session_title(rows[i]) : ""
}

// ⇧⌘U: the focused tab (a terminal), else the session's (its active tab, or its main tab).
mark_unread :: proc() -> (core.Command, bool) {
	cs := core.cur()
	if cs == nil || cs.home do return nil, false
	if t := core.active_tab(); t != nil && core.tab_is_terminal(t^) do return core.Set_Unread{tab_id = t.id, unread = true}, true
	if cs.pi_session_id == "" do return nil, false
	return core.Set_Unread{pi_session_id = cs.pi_session_id, unread = true}, true
}

// ⌥⇧⌘U: every tab of this Mac's open sessions that finished and was not seen is seen. Only that
// mark: waiting for you, errors and questions are what the tab's program says, not this mark.
mark_all_read :: proc() {
	ids := make([dynamic]u64, context.temp_allocator)
	n := 0
	for s in state.open_sessions {
		if s.home || s.machine != 0 do continue
		k := len(ids)
		for t in s.tabs do if t.unseen do append(&ids, t.id)
		if len(ids) > k do n += 1
	}
	for id in ids do ui_do(core.Set_Unread{tab_id = id, unread = false})
	toast_show(n == 0 ? "Nothing unread" : fmt.tprintf("Marked %d as read", n))
}

// Recent → Name → Created → Recent.
next_sort :: proc(sec: core.Sort_Section) -> core.Command {
	by := state.sidebar.sort[sec]
	return core.Set_Sort{section = sec, by = core.Sort_By((int(by) + 1) % len(core.Sort_By))}
}

action_by_id :: proc(id: string) -> ^Action {
	for &a in ACTIONS do if a.id == id do return &a
	return nil
}

// Runs an action as the user, as the palette does: a click on its button.
// Actions with a folder picker ask for the folder first (outside the event
// handler: the picker is a modal loop).
action_run :: proc(id: string, menu := "") {
	client.busy += 1 // it may hold the replica across a drain (client_on_drain)
	defer client.busy -= 1
	a := action_by_id(id)
	if a == nil do return
	if id != "quit" && job_sheet_open() do return // modal: nothing behind it takes over (menubar.odin greys these)
	if a.pick_folder {
		for &b, i in ACTIONS do if &b == a do palette.pick_for = i + 1
		delete(palette.pick_menu)
		palette.pick_menu = strings.clone(menu) // its result toast after the picker (palette_run_deferred)
		if core.platform.run_later != nil do core.platform.run_later(palette_run_deferred)
		return
	}
	run_action(a, menu)
}

// What the action is called now (its title, else its label).
action_label :: proc(a: ^Action) -> string {return a.title != nil ? a.title() : a.label}

// The action applies now (its make succeeds): its button is enabled.
action_ok :: proc(id: string) -> bool {
	a := action_by_id(id)
	if a == nil do return false
	_, ok := a.make()
	return ok
}

// Shortcuts that are neither actions nor in the menu bar (menubar.odin): the
// shortcuts sheet lists them after the menus', under their group.
SHORTCUTS_EXTRA := [?]struct {
	group, label, keys: string,
}{
	{"Terminal", "Terminal: delete to line start, word back", "⌘⌫, ⌥⌫"},
	{"Terminal", "Terminal: line start, line end", "⌘←, ⌘→"},
	{"Terminal", "Terminal: word back, word forward", "⌥←, ⌥→"},
	{"Terminal", "Terminal: open a link (hold ⌘ to see it; ⇧: the default browser)", "⌘-click, ⇧⌘-click"},
	{"Editor", "Editor: toggle comment (⌘/ opens the shortcuts elsewhere)", "⌘/"},
	{"Editor", "Editor: go to line (as ⌘L)", "⌃G"},
	{"Editor", "Editor: indent, outdent", "⌘], ⌘["},
	{"Editor", "Editor: start, end of the file", "⌘↑, ⌘↓"},
	{"Files tab", "Files: move to Trash", "⌘⌫"},
	{"Files tab", "Files: rename", "F2"},
}
