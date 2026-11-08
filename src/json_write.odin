package main

// Hand-written JSON encoding for the wire schema in docs/PROTOCOL.md:
// commands and results with an explicit "type" tag, events, the state
// snapshot and reply envelopes. Odin's default marshalling is not used for
// any of these (it does not tag union variants).

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

PROTOCOL_VERSION :: 1

// ---- writer helpers ----

Jw :: struct {
	b:     ^strings.Builder,
	first: bool,
}

json_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case 0 ..< 0x20, 0x7f, 0x2028, 0x2029:
			fmt.sbprintf(b, `\u%04x`, int(r))
		case:
			strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}

@(private = "file")
obj_begin :: proc(b: ^strings.Builder) -> Jw {
	strings.write_byte(b, '{')
	return {b = b, first = true}
}
@(private = "file")
obj_end :: proc(w: ^Jw) {strings.write_byte(w.b, '}')}
@(private = "file")
key :: proc(w: ^Jw, k: string) {
	if !w.first do strings.write_byte(w.b, ',')
	w.first = false
	json_quote(w.b, k)
	strings.write_byte(w.b, ':')
}
@(private = "file")
kv_str :: proc(w: ^Jw, k, v: string) {key(w, k); json_quote(w.b, v)}
@(private = "file")
kv_u64 :: proc(w: ^Jw, k: string, v: u64) {key(w, k); strings.write_u64(w.b, v)}
@(private = "file")
kv_bool :: proc(w: ^Jw, k: string, v: bool) {key(w, k); strings.write_string(w.b, v ? "true" : "false")}
@(private = "file")
kv_f32 :: proc(w: ^Jw, k: string, v: f32) {
	key(w, k)
	buf: [32]u8
	strings.write_string(w.b, strings.trim_prefix(strconv.write_float(buf[:], f64(v), 'g', -1, 32), "+"))
}

// ---- enum names on the wire ----

CALLER_NAMES := [Caller_Kind]string {
	.Internal = "internal",
	.UI       = "ui",
	.Script   = "script",
	.Control  = "control",
	.Panel    = "panel",
	.App      = "app",
}
CLASS_NAMES := [Command_Class]string {
	.Tab_Close       = "tab_close",
	.Session_Restart = "session_restart",
	.Settings_Write  = "settings_write",
	.App_Quit        = "app_quit",
	.Delete          = "delete",
	.Fs_Write        = "fs_write",
	.Open_Link       = "open_link",
}
MODE_NAMES := [Confirm_Mode]string {
	.Ask     = "ask",
	.Trusted = "trusted",
	.Auto    = "auto",
}
CLOSE_NAMES := [Close_Confirm]string {
	.Auto   = "auto",
	.Always = "always",
	.Never  = "never",
}
AGENT_NAMES := [Agent_State]string {
	.Unknown = "unknown",
	.Idle    = "idle",
	.Working = "working",
	.Error   = "error",
}
TONE_NAMES := [Panel_Tone]string {
	.Normal  = "",
	.Accent  = "accent",
	.Muted   = "muted",
	.Dim     = "dim",
	.Warning = "warning",
	.Success = "success",
	.Error   = "error",
}
TAB_STATUS_NAMES := [Tab_Status]string {
	.Running     = "running",
	.Exited      = "exited",
	.Not_Started = "not_started",
}
TAB_KIND_NAMES := [Tab_Kind_Id]string {
	.Pi     = "pi",
	.Shell  = "shell",
	.Editor = "editor",
	.Changes = "changes",
	.Markdown = "markdown",
	.Browser = "browser",
	.App = "app",
	.Claude = "claude",
}
SORT_SECTION_NAMES := [Sort_Section]string {
	.Projects = "projects",
	.Sessions = "sessions",
	.Chats    = "chats",
}
SORT_BY_NAMES := [Sort_By]string {
	.Recent  = "recent",
	.Name    = "name",
	.Created = "created",
	.Attention = "attention",
}
FOLD_NAMES := [Sidebar_Fold]string {
	.Open     = "open",
	.Projects = "projects",
	.Chats    = "chats",
}

// ---- commands ----

command_type :: proc(cmd: Command) -> string {
	switch _ in cmd {
	case Add_Project:         return "add_project"
	case Select_Project:      return "select_project"
	case Rename_Project:      return "rename_project"
	case Open_Session_Cmd:    return "open_session"
	case New_Chat:            return "new_chat"
	case Focus_Session:       return "focus_session"
	case Close_Session:       return "close_session"
	case New_Shell_Tab:       return "new_shell_tab"
	case Close_Tab:           return "close_tab"
	case Focus_Tab:           return "focus_tab"
	case Split_Pane:          return "split_pane"
	case Close_Pane:          return "close_pane"
	case Focus_Pane:          return "focus_pane"
	case Move_Tab:            return "move_tab"
	case Set_Split:           return "set_split"
	case Equalize_Panes:      return "equalize_panes"
	case Copy_Selection:      return "copy_selection"
	case Terminal_Link:       return "terminal_link"
	case Send_Text:           return "send_text"
	case Set_Focus:           return "set_focus"
	case Set_Layout:          return "set_layout"
	case Set_Panel:           return "set_panel"
	case Cancel_Confirmation: return "cancel_confirmation"
	case Rescan:              return "rescan"
	case Refresh_Shell_Env:   return "refresh_shell_env"
	case Quit:                return "quit"
	case Get_State:           return "get_state"
	case List_Commands:       return "list_commands"
	case Set_Home:            return "set_home"
	case Set_Home_Dir:        return "set_home_dir"
	case Set_Folder:          return "set_folder"
	case Setup_Sheet:         return "setup_sheet"
	case Set_Chats_Readonly:  return "set_chats_readonly"
	case Set_Claude_Default_Flags: return "set_claude_default_flags"
	case Set_Pi_Extension:    return "set_pi_extension"
	case Set_Pinned:          return "set_pinned"
	case Set_Hidden:          return "set_hidden"
	case Set_Sort:            return "set_sort"
	case Set_Sidebar_Folded:  return "set_sidebar_folded"
	case Set_Row_Expanded:    return "set_row_expanded"
	case Set_Filter:          return "set_filter"
	case Reveal_Path:         return "reveal"
	case Session_Info:        return "session_info"
	case Copy_Path:           return "copy_path"
	case Restore_Sidebar:     return "restore_sidebar"
	case Set_Agent_Name:      return "set_agent_name"
	case Set_Agent_Model:     return "set_agent_model"
	case Agent_Model_Picker:  return "agent_model_picker"
	case Set_Notify:          return "set_notify"
	case Set_Tidy_Projects:   return "set_tidy_projects"
	case Set_Keep_Sessions:   return "set_keep_sessions"
	case Set_Confirm_Policy:  return "set_confirm_policy"
	case Set_Close_Confirm:   return "set_close_confirm"
	case Set_Theme:           return "set_theme"
	case Set_Reduce_Motion:   return "set_reduce_motion"
	case Set_Terminal_Text_Size: return "set_terminal_text_size"
	case Set_Appearance:      return "set_appearance"
	case Set_Text_Size:       return "set_text_size"
	case System_Appearance:   return "system_appearance"
	case Pi_Session_Update:   return "pi.session"
	case Pi_Status_Update:    return "pi.status"
	case Pi_Prompt:           return "pi_prompt"
	case Pi_Reload:           return "pi_reload"
	case Pi_Restart:          return "pi_restart"
	case Pi_Wait_Idle:        return "pi_wait_idle"
	case Panel_Set:           return "panel.set"
	case Panel_Remove:        return "panel.remove"
	case Set_Panel_Collapsed: return "set_panel_collapsed"
	case Tab_Exited:          return "tab_exited"
	case Program_Status:      return "program_status"
	case Set_Unread:          return "set_unread"
	case Rescan_Done:         return "rescan_done"
	case Refresh_Shell_Env_Done: return "refresh_shell_env_done"
	case Bridge_Done:         return "bridge_done"
	case Restore_Session:     return "restore_session"
	case Open_File:           return "open_file"
	case Editor_State:        return "editor_state"
	case Save_File:           return "save_file"
	case Goto_Line:           return "goto"
	case Reload_File:         return "reload_file"
	case Keep_Buffer:         return "keep_buffer"
	case Diff_File:           return "diff_file"
	case Set_Wrap:            return "set_wrap"
	case List_Dir:            return "list_dir"
	case Create_File:         return "create_file"
	case Create_Dir:          return "create_dir"
	case Rename_Path:         return "rename_path"
	case Delete_Path:         return "delete_path"
	case Git_Head_Done:       return "git_head_done"
	case Git_Status_Done:     return "git_status_done"
	case Reveal_In_Finder:    return "reveal_in_finder"
	case Keep_Tab:            return "keep_tab"
	case Set_Left_Tab:        return "set_left_tab"
	case Files_Expand:        return "files_expand"
	case Files_Collapse_All:  return "files_collapse_all"
	case Files_Reveal:        return "files_reveal"
	case Set_Files_Filter:    return "set_files_filter"
	case File_List_Done:      return "file_list_done"
	case List_Worktrees:      return "list_worktrees"
	case Files_Set_Root:      return "files_set_root"
	case Worktree_Cleanup:    return "worktree_cleanup"
	case Worktree_Session:    return "worktree_session"
	case Worktrees_Done:      return "worktrees_done"
	case Worktree_Cleanup_Done: return "worktree_cleanup_done"
	case Notifications_List:  return "notifications_list"
	case Notifications_Mark_Read: return "notifications_mark_read"
	case Notifications_Clear: return "notifications_clear"
	case Notify_Post:         return "notify_post"
	case Set_Bell:            return "set_notifications"
	case Update_Check, Update_Skip, Update_Later, Update_Download, Update_Install, Set_Update_Check, Update_Env, Update_Tick, Update_Checked, Update_Prepared:
		return update_command_name(cmd)
	case Job_List:            return "job_list"
	case Job_Runs:            return "job_runs"
	case Job_Run_Now:         return "job_run_now"
	case Job_Stop:            return "job_stop"
	case Jobs_Pause:          return "jobs_pause"
	case Jobs_Resume:         return "jobs_resume"
	case Job_Create:          return "job_create"
	case Job_Save:            return "job_save"
	case Job_Sheet:           return "job_sheet"
	case Job_Mark_Read:       return "job_mark_read"
	case Job_Set_Enabled:     return "job_set_enabled"
	case Job_Delete:          return "job_delete"
	case Job_Open:            return "job_open"
	case Set_Pi_Path:         return "set_pi_path"
	case Set_Job_Limits:      return "set_job_limits"
	case Jobs_Sync:           return "jobs_sync"
	case Jobs_Tick:           return "jobs_tick"
	case Job_Run_Done:        return "job_run_done"
	case Jobs_Env:            return "jobs_env"
	case Changes_Open, Changes_List, Changes_Stage, Changes_Unstage, Changes_Discard, Changes_Commit, Changes_Scan_Done, Changes_Diff_Done, Changes_Op_Done:
		return changes_command_type(cmd)
	case Markdown_Open:       return "markdown_open"
	case Show_File:           return "show_file"
	case Markdown_Set_View:   return "markdown_view"
	case Markdown_Scroll:     return "markdown_scroll"
	case Markdown_Follow:     return "markdown_link"
	case New_App_Tab:         return "new_app_tab"
	case App_Restart:         return "app_restart"
	case App_Close:           return "app_close"
	case App_Declared:        return "app_declared"
	case App_Input:           return "app_input"
	case App_Events:          return "app_events"
	case App_Call:            return "app_call"
	case App_Call_Done:       return "app_call_done"
	case App_Screenshot:      return "app_screenshot"
	case App_Inspect:         return "app_inspect"
	case App_Update:          return "app_update"
	case Pi_Reload_All:       return "pi_reload_all"
	case Pi_Restart_Updated:  return "pi_restart_updated"
	case Pi_Reload_Later:     return "pi_reload_later"
	case Reload_Watch:        return "reload_watch"
	case Reload_Kick:      return "reload_kick"
	case Claude_Restart_Changed, Claude_Reload_Later, Claude_Reload_Watch, Claude_Reload_Kick:
		return claude_reload_type(cmd)
	case Comment_Add:         return "comment_add"
	case Comment_Edit:        return "comment_edit"
	case Comment_Delete:      return "comment_delete"
	case Comments_Clear:      return "comments_clear"
	case Comments_Send_Now:   return "comments_send_now"
	case Comments_Ask_Cancel: return "comments_ask_cancel"
	case Pi_Attached:         return "pi.attached"
	case New_Claude_Tab, New_Claude_Session, Claude_Rename, Claude_Resume, Claude_Session_Report, Claude_Turn_Report, Claude_Comments, Claude_Attached, Claude_Prompt, Claude_Held_Op, Claude_Deliver, Claude_Restore_History, Claude_Readonly_Ack:
		return claude_command_type(cmd)
	case Add_Claude_Account, Rename_Claude_Account, Remove_Claude_Account, Set_Claude_Account_Default:
		return claude_account_type(cmd)
	case Claude_Restart, Claude_Todos, Claude_Task, Claude_Subagent, Claude_Background:
		return claude_extra_type(cmd)
	case Claude_Model_Report: return "claude.model"
	case Claude_Wait_Idle:    return "claude_wait_idle"
	case Claude_Wait_Tick:    return "claude_wait_tick"
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update:
		return browser_command_type(cmd)
	case Browser_Zoom, Browser_Find, Browser_Find_Close, Browser_Dialog, Browser_Permission, Browser_Popup, Browser_Edit, Browser_Devtools, Browser_External, Browser_Download:
		return browser_polish_command_type(cmd)
	case Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop:
		return browser_agent_command_type(cmd)
	case Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel:
		return browser_act_command_type(cmd)
	}
	return ""
}

// A pi tab's blocker as events and the log show it: "shell sh1" and "timer wk2" (the bridge's
// "<kind> <id>: <text>"), "subagent", else "<redacted>" (temp-allocated).
blocker_redacted :: proc(b: string) -> string {
	head, sep, _ := strings.partition(b, ": ")
	kind, _, id := strings.partition(head, " ")
	if sep != "" && (kind == "shell" || kind == "timer") && id != "" && !strings.contains_any(id, " :") do return strings.concatenate({kind, " ", id}, context.temp_allocator)
	if strings.has_prefix(b, "subagent ") || b == "subagent" do return "subagent"
	return "<redacted>"
}

// redact: for events and logs. Pasted text becomes its length, tokens vanish.
write_command :: proc(b: ^strings.Builder, cmd: Command, redact := false) {
	w := obj_begin(b)
	kv_str(&w, "type", command_type(cmd))
	token :: proc(w: ^Jw, t: string, redact: bool) {
		if t != "" do kv_str(w, "confirm", redact ? "<redacted>" : t)
	}
	switch c in cmd {
	case Add_Project:
		kv_str(&w, "cwd", c.cwd)
	case Select_Project:
		kv_u64(&w, "project_id", c.project_id)
	case Rename_Project:
		kv_u64(&w, "project_id", c.project_id)
		kv_str(&w, "name", c.name)
	case Open_Session_Cmd:
		kv_u64(&w, "project_id", c.project_id)
		kv_str(&w, "pi_session_id", c.pi_session_id)
	case New_Chat:
		kv_u64(&w, "project_id", c.project_id)
	case Focus_Session:
		kv_u64(&w, "session", c.session)
	case Close_Session:
		kv_u64(&w, "session", c.session)
		token(&w, c.confirm, redact)
		if c.comments != .Ask do kv_str(&w, "comments", COMMENTS_CHOICE_NAMES[c.comments])
	case Set_Home:
		kv_bool(&w, "open", c.open)
	case Set_Home_Dir:
		kv_str(&w, "path", c.path)
		if c.create do kv_bool(&w, "create", true)
	case Set_Folder:
		kv_str(&w, "kind", FOLDER_NAMES[c.kind])
		kv_str(&w, "path", c.path)
	case Setup_Sheet:
		kv_bool(&w, "open", c.open)
	case Set_Chats_Readonly:
		kv_bool(&w, "on", c.on)
	case Set_Pi_Extension:
		kv_str(&w, "name", c.name)
		kv_bool(&w, "on", c.on)
	case Set_Claude_Default_Flags:
		kv_bool(&w, "skip_permissions", c.skip_permissions)
		token(&w, c.confirm, redact)
	case Set_Pinned:
		if c.cwd != "" do kv_str(&w, "cwd", c.cwd)
		if c.project_id != 0 do kv_u64(&w, "project_id", c.project_id)
		if c.pi_session_id != "" do kv_str(&w, "pi_session_id", c.pi_session_id)
		kv_bool(&w, "pinned", c.pinned)
		if i, ok := c.index.?; ok do kv_u64(&w, "index", u64(max(i, 0)))
	case Set_Hidden:
		if c.cwd != "" do kv_str(&w, "cwd", c.cwd)
		if c.project_id != 0 do kv_u64(&w, "project_id", c.project_id)
		if c.pi_session_id != "" do kv_str(&w, "pi_session_id", c.pi_session_id)
		kv_bool(&w, "hidden", c.hidden)
	case Set_Sort:
		kv_str(&w, "section", SORT_SECTION_NAMES[c.section])
		kv_str(&w, "by", SORT_BY_NAMES[c.by])
	case Set_Sidebar_Folded:
		kv_str(&w, "section", FOLD_NAMES[c.section])
		kv_bool(&w, "folded", c.folded)
	case Set_Row_Expanded:
		kv_str(&w, "path", c.path)
		kv_bool(&w, "expanded", c.expanded)
	case Set_Filter:
		if v, ok := c.text.?; ok do kv_str(&w, "text", v)
		if v, ok := c.running.?; ok do kv_bool(&w, "running", v)
		if v, ok := c.waiting.?; ok do kv_bool(&w, "waiting", v)
		if v, ok := c.pinned.?; ok do kv_bool(&w, "pinned", v)
		if v, ok := c.show_hidden.?; ok do kv_bool(&w, "show_hidden", v)
	case Reveal_Path:
		kv_u64(&w, "project_id", c.project_id)
		if c.pi_session_id != "" do kv_str(&w, "pi_session_id", c.pi_session_id)
	case Session_Info:
		kv_u64(&w, "project_id", c.project_id)
		kv_str(&w, "pi_session_id", c.pi_session_id)
		if c.to != "" do kv_str(&w, "to", c.to)
	case Copy_Path:
		kv_u64(&w, "project_id", c.project_id)
		if c.pi_session_id != "" do kv_str(&w, "pi_session_id", c.pi_session_id)
	case Restore_Sidebar:
		key(&w, "pinned_projects")
		write_strings(w.b, c.pinned_projects)
		key(&w, "pinned_sessions")
		write_strings(w.b, c.pinned_sessions)
		key(&w, "hidden_projects")
		write_strings(w.b, c.hidden_projects)
		key(&w, "hidden_sessions")
		write_strings(w.b, c.hidden_sessions)
	case Set_Agent_Name:
		kv_str(&w, "name", c.name)
	case Set_Agent_Model:
		kv_str(&w, "model", c.model)
	case Set_Notify:
		kv_bool(&w, "on", c.on)
	case Set_Tidy_Projects:
		kv_bool(&w, "on", c.on)
	case Set_Keep_Sessions:
		kv_bool(&w, "on", c.on)
	case Notifications_List, Notifications_Mark_Read, Notifications_Clear, Notify_Post, Set_Bell:
		notify_write(w.b, cmd) // after "type": the object is not empty
	case Update_Install:
		token(&w, c.confirm, redact)
	case Update_Check, Update_Skip, Update_Later, Update_Download, Set_Update_Check, Update_Env, Update_Tick, Update_Checked, Update_Prepared:
		update_write(w.b, cmd) // update.odin: never the release body
	case Pi_Reload_All, Pi_Restart_Updated, Pi_Reload_Later, Reload_Watch, Reload_Kick:
		reload_write(w.b, cmd) // reload.odin; confirmation tokens never
	case Claude_Restart_Changed, Claude_Reload_Later, Claude_Reload_Watch, Claude_Reload_Kick:
		claude_reload_write(w.b, cmd) // claude_reload.odin; confirmation tokens never
	case New_Shell_Tab:
		kv_u64(&w, "session", c.session)
		if c.cwd != "" do kv_str(&w, "cwd", c.cwd)
		if c.pane != 0 do kv_u64(&w, "pane", c.pane)
	case Split_Pane:
		if c.pane != 0 do kv_u64(&w, "pane", c.pane)
		kv_str(&w, "direction", PANE_DIR_NAMES[c.direction])
		if c.tab_id != 0 do kv_u64(&w, "tab_id", c.tab_id)
		if c.no_focus do kv_bool(&w, "focus", false)
	case Close_Pane:
		kv_u64(&w, "pane", c.pane)
	case Focus_Pane:
		if c.pane != 0 do kv_u64(&w, "pane", c.pane)
		if c.direction != "" do kv_str(&w, "direction", c.direction)
	case Move_Tab:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_u64(&w, "pane", c.pane)
		if c.index >= 0 do kv_u64(&w, "index", u64(c.index))
	case Set_Split:
		kv_u64(&w, "split", c.split)
		fmt.sbprintf(w.b, `,"ratio":%.3f`, c.ratio)
	case Equalize_Panes:
		if c.session != 0 do kv_u64(&w, "session", c.session)
	case Close_Tab:
		kv_u64(&w, "tab_id", c.tab_id)
		token(&w, c.confirm, redact)
		if c.comments != .Ask do kv_str(&w, "comments", COMMENTS_CHOICE_NAMES[c.comments])
	case Focus_Tab:
		kv_u64(&w, "tab_id", c.tab_id)
	case Copy_Selection:
		kv_u64(&w, "tab_id", c.tab_id)
	case Terminal_Link:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "url", redact ? browser_url_redacted(c.url) : c.url) // never user:pass@ in events
		if c.external do kv_bool(&w, "external", true)
	case Send_Text:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "text", redact ? fmt.tprintf("<redacted %d bytes>", len(c.text)) : c.text)
	case Set_Focus:
		kv_str(&w, "widget", c.widget)
	case Set_Layout:
		if v, ok := c.left_width.?; ok do kv_f32(&w, "left_width", v)
		if v, ok := c.right_width.?; ok do kv_f32(&w, "right_width", v)
		if v, ok := c.left_open.?; ok do kv_bool(&w, "left_open", v)
		if v, ok := c.right_open.?; ok do kv_bool(&w, "right_open", v)
		if v, ok := c.drawer_width.?; ok do kv_f32(&w, "drawer_width", v)
		if v, ok := c.drawer_pinned.?; ok do kv_bool(&w, "drawer_pinned", v)
	case Set_Panel:
		kv_str(&w, "panel", c.panel)
		kv_bool(&w, "open", c.open)
	case Cancel_Confirmation:
		kv_str(&w, "token", redact ? "<redacted>" : c.token)
	case Quit:
		token(&w, c.confirm, redact)
	case Set_Confirm_Policy:
		kv_str(&w, "caller", CALLER_NAMES[c.caller])
		kv_str(&w, "class", CLASS_NAMES[c.class])
		kv_str(&w, "mode", MODE_NAMES[c.mode])
	case Set_Close_Confirm:
		kv_str(&w, "tab_kind", TAB_KIND_NAMES[c.tab_kind])
		kv_str(&w, "rule", CLOSE_NAMES[c.rule])
	case Set_Theme:
		kv_str(&w, "name", THEME_NAMES[c.name])
	case Set_Reduce_Motion:
		kv_bool(&w, "on", c.on)
	case Set_Terminal_Text_Size:
		kv_u64(&w, "pt", u64(c.pt))
	case Set_Appearance:
		kv_str(&w, "mode", APPEARANCE_NAMES[c.mode])
	case Set_Text_Size:
		kv_str(&w, "size", TEXT_SIZE_NAMES[c.size])
	case System_Appearance:
		kv_bool(&w, "light", c.light)
	case Pi_Session_Update:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "pi_session_id", c.pi_session_id)
		kv_str(&w, "session_file", c.session_file)
		kv_str(&w, "cwd", c.cwd)
	case Pi_Status_Update:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "agent", AGENT_NAMES[c.agent])
		kv_bool(&w, "waiting", c.waiting)
		kv_bool(&w, "question", c.question)
		key(&w, "blockers")
		// events and the log: what kind and which id only ("shell sh1"), never a command or a
		// task, as panel rows are only counted; the state keeps the text (Tab.blockers)
		if redact {
			masked := make([]string, len(c.blockers), context.temp_allocator)
			for x, i in c.blockers do masked[i] = blocker_redacted(x)
			write_strings(w.b, masked)
		} else do write_strings(w.b, c.blockers)
	case Pi_Prompt:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "text", redact ? fmt.tprintf("<redacted %d bytes>", len(c.text)) : c.text)
		if len(c.images) > 0 {
			if redact do kv_str(&w, "images", fmt.tprintf("<redacted %d images>", len(c.images)))
			else do write_prompt_images(w.b, c.images)
		}
	case Pi_Reload:
		kv_u64(&w, "tab_id", c.tab_id)
		token(&w, c.confirm, redact)
	case Pi_Restart:
		kv_u64(&w, "tab_id", c.tab_id)
		if c.pick_model do kv_bool(&w, "pick_model", true)
	case Pi_Wait_Idle:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_u64(&w, "timeout_ms", c.timeout_ms)
	case Panel_Set:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "panel", c.panel)
		kv_str(&w, "title", c.title)
		key(&w, "rows")
		// events and the log: only how much (PROTOCOL.md §6)
		if redact do json_quote(w.b, fmt.tprintf("<redacted %d rows>", len(c.rows)))
		else do write_rows(w.b, c.rows)
	case Panel_Remove:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "panel", c.panel)
	case Set_Panel_Collapsed:
		kv_str(&w, "panel", c.panel)
		kv_bool(&w, "collapsed", c.collapsed)
	case Bridge_Done:
		kv_u64(&w, "request_id", c.request_id)
		kv_bool(&w, "ok", c.ok)
		if c.error != "" do kv_str(&w, "error", c.error)
	case Tab_Exited:
		kv_u64(&w, "tab_id", c.tab_id)
		if how := exit_text(c.exit); how != "" do kv_str(&w, "exit", how) // a crash or a hangup (dead_tab.odin)
	case Program_Status:
		// what the program said, not its title or message (untrusted text; the snapshot has them)
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "state", PROG_STATE_NAMES[c.summary.state])
		if c.summary.kind != .None do kv_str(&w, "kind", PROG_KIND_NAMES[c.summary.kind])
		if c.summary.app != "" do kv_str(&w, "app", c.summary.app)
		kv_u64(&w, "records", u64(c.summary.records))
	case Set_Unread:
		if c.tab_id != 0 do kv_u64(&w, "tab_id", c.tab_id)
		if c.pi_session_id != "" do kv_str(&w, "pi_session_id", c.pi_session_id)
		kv_bool(&w, "unread", c.unread)
	case Rescan_Done:
		kv_u64(&w, "request_id", c.request_id)
	case Refresh_Shell_Env_Done:
		kv_u64(&w, "request_id", c.request_id) // never the values
		kv_bool(&w, "ok", c.ok)
	case Restore_Session:
		kv_u64(&w, "project_id", c.project_id)
		kv_str(&w, "pi_session_id", c.pi_session_id)
		kv_str(&w, "session_dir", c.session_dir)
		if c.cwd != "" do kv_str(&w, "cwd", c.cwd)
		if c.agent == .Claude do kv_str(&w, "agent", "claude")
		key(&w, "tabs")
		strings.write_byte(w.b, '[')
		for t, i in c.tabs {
			if i > 0 do strings.write_byte(w.b, ',')
			o := obj_begin(w.b)
			kv_str(&o, "kind", TAB_KIND_NAMES[t.kind])
			kv_str(&o, "title", t.title)
			kv_str(&o, "cwd", t.cwd)
			if t.active do kv_bool(&o, "active", true)
			if len(c.layout.nodes) > 0 {
				if pn, ok := t.pane.?; ok { // its saved pane (left out: not known)
					key(&o, "pane")
					strings.write_int(w.b, pn)
				}
				if t.pane_active do kv_bool(&o, "pane_active", true)
			}
			obj_end(&o)
		}
		strings.write_byte(w.b, ']')
		if len(c.layout.nodes) > 0 {
			// the saved panes (persist.odin panes_parse): the tree in pre-order, the pi tab's pane (left out: not known)
			if pn, ok := c.pi_pane.?; ok && c.agent != .Claude {
				key(&w, "pi_pane")
				strings.write_int(w.b, pn)
			}
			key(&w, "panes")
			lo := obj_begin(w.b)
			kv_u64(&lo, "count", u64(c.layout.panes))
			kv_u64(&lo, "focused", u64(c.layout.focused))
			key(&lo, "tree")
			strings.write_byte(w.b, '[')
			for n, i in c.layout.nodes {
				if i > 0 do strings.write_byte(w.b, ',')
				if n.leaf do fmt.sbprintf(w.b, `{{"pane":%d}}`, n.pane)
				else do fmt.sbprintf(w.b, `{{"split":"%s","ratio":%.3f,"a":%d,"b":%d}}`, n.dir == .Right ? "right" : "down", n.ratio, n.a, n.b)
			}
			strings.write_byte(w.b, ']')
			obj_end(&lo)
		}
		if c.home do kv_bool(&w, "home", true)
	case Open_File:
		kv_str(&w, "path", c.path)
		if c.line > 0 do kv_u64(&w, "line", u64(c.line))
		if c.col > 0 do kv_u64(&w, "col", u64(c.col))
		if c.session != 0 do kv_u64(&w, "session", c.session)
		if c.preview do kv_bool(&w, "preview", true)
	case Keep_Tab:
		kv_u64(&w, "tab_id", c.tab_id)
	case Set_Left_Tab:
		kv_str(&w, "tab", LEFT_TAB_NAMES[c.tab])
	case Files_Expand:
		kv_str(&w, "path", c.path)
		kv_bool(&w, "expanded", c.expanded)
	case Files_Collapse_All:
		kv_str(&w, "root", c.root)
	case Files_Reveal:
		kv_str(&w, "path", c.path)
	case Set_Files_Filter:
		kv_str(&w, "text", c.text)
	case Editor_State:
		kv_u64(&w, "tab_id", c.tab_id)
	case Save_File:
		kv_u64(&w, "tab_id", c.tab_id)
	case Goto_Line:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_u64(&w, "line", u64(max(c.line, 0)))
		if c.col > 0 do kv_u64(&w, "col", u64(c.col))
	case Reload_File:
		kv_u64(&w, "tab_id", c.tab_id)
		token(&w, c.confirm, redact)
	case Keep_Buffer:
		kv_u64(&w, "tab_id", c.tab_id)
	case Diff_File:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "against", EDITOR_VIEW_NAMES[c.against])
	case Set_Wrap:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_bool(&w, "on", c.on)
	case List_Dir:
		kv_str(&w, "path", c.path)
		if c.ignored do kv_bool(&w, "ignored", true)
	case Create_File:
		kv_str(&w, "path", c.path)
		token(&w, c.confirm, redact)
	case Create_Dir:
		kv_str(&w, "path", c.path)
		token(&w, c.confirm, redact)
	case Rename_Path:
		kv_str(&w, "from", c.from)
		kv_str(&w, "to", c.to)
		token(&w, c.confirm, redact)
	case Delete_Path:
		kv_str(&w, "path", c.path)
		token(&w, c.confirm, redact)
	case Reveal_In_Finder:
		kv_str(&w, "path", c.path)
	case Git_Head_Done: // internal; the file's text stays out of events and the log
		kv_u64(&w, "tab_id", c.tab_id)
		kv_bool(&w, "tracked", c.tracked)
	case Git_Status_Done:
		kv_str(&w, "root", c.root)
		kv_bool(&w, "ok", c.ok)
	case File_List_Done:
		kv_str(&w, "root", c.root)
	case List_Worktrees:
		if c.path != "" do kv_str(&w, "path", c.path)
	case Files_Set_Root:
		if c.base != "" do kv_str(&w, "base", c.base)
		kv_str(&w, "path", c.path)
	case Worktree_Cleanup:
		kv_str(&w, "path", c.path)
		token(&w, c.confirm, redact)
	case Worktree_Session:
		kv_u64(&w, "project_id", c.project_id)
		kv_str(&w, "path", c.path)
	case Worktrees_Done:
		kv_str(&w, "common", c.common)
	case Worktree_Cleanup_Done:
		kv_str(&w, "path", c.path)
		if c.err != "" do kv_str(&w, "err", c.err)
	case Job_List:
		if c.unread do kv_bool(&w, "unread", true)
	case Job_Runs:
		kv_str(&w, "job", c.job)
		if c.limit > 0 do kv_u64(&w, "limit", u64(c.limit))
	case Job_Run_Now:     kv_str(&w, "job", c.job)
	case Job_Stop:        if c.job != "" do kv_str(&w, "job", c.job)
	case Jobs_Pause:      if c.job != "" do kv_str(&w, "job", c.job)
	case Jobs_Resume:     if c.job != "" do kv_str(&w, "job", c.job)
	case Job_Save: // the note is the user's text: its length only
		if c.path != "" do kv_str(&w, "path", c.path)
		kv_str(&w, "text", redact ? fmt.tprintf("<redacted %d bytes>", len(c.text)) : c.text)
		if c.based_on != "" do kv_str(&w, "based_on", c.based_on)
	case Job_Sheet:
		kv_bool(&w, "open", c.open)
		if c.job != "" do kv_str(&w, "job", c.job)
		if c.for_project != "" do kv_str(&w, "for_project", c.for_project)
	case Job_Create: // the prompt is the user's text: its length only
		kv_str(&w, "name", c.name)
		if c.schedule != "" do kv_str(&w, "schedule", c.schedule)
		if c.folder != "" do kv_str(&w, "folder", c.folder)
		if c.for_project != "" do kv_str(&w, "for_project", c.for_project)
		if c.prompt != "" do kv_str(&w, "prompt", redact ? fmt.tprintf("<redacted %d bytes>", len(c.prompt)) : c.prompt)
	case Job_Mark_Read:
		if c.job != "" do kv_str(&w, "job", c.job)
		if c.run != "" do kv_str(&w, "run", c.run)
	case Job_Set_Enabled:
		kv_str(&w, "job", c.job)
		kv_bool(&w, "on", c.on)
	case Job_Delete:
		kv_str(&w, "job", c.job)
		token(&w, c.confirm, redact)
	case Job_Open:
		kv_str(&w, "job", c.job)
		kv_str(&w, "what", c.what)
	case Set_Pi_Path:     kv_str(&w, "path", c.path)
	case Set_Job_Limits:
		f :: proc(w: ^Jw, k: string, v: Maybe(f64)) {if x, ok := v.?; ok {key(w, k); fmt.sbprintf(w.b, "%v", x)}}
		n :: proc(w: ^Jw, k: string, v: Maybe(int)) {if x, ok := v.?; ok {key(w, k); fmt.sbprintf(w.b, "%d", x)}}
		t :: proc(w: ^Jw, k: string, v: Maybe(i64)) {if x, ok := v.?; ok {key(w, k); fmt.sbprintf(w.b, "%d", x)}}
		f(&w, "max_cost", c.max_cost)
		f(&w, "day", c.day)
		f(&w, "week", c.week)
		f(&w, "month", c.month)
		t(&w, "timeout", c.timeout)
		t(&w, "stall", c.stall)
		n(&w, "max_turns", c.max_turns)
		n(&w, "concurrency", c.concurrency)
		n(&w, "loop_calls", c.loop_calls)
		n(&w, "fail_pause", c.fail_pause)
	case Job_Run_Done: // its run is freed by then: never read it here
	case Jobs_Env: // the PATH and notes folder stay out of the log
	// the Changes tab (changes.odin): no diff text, no git output; the commit message only as its length in events
	case Changes_Open:
		if c.session != 0 do kv_u64(&w, "session", c.session)
		if c.path != "" do kv_str(&w, "path", c.path)
	case Changes_List:
		if c.tab_id != 0 do kv_u64(&w, "tab_id", c.tab_id)
		if c.path != "" do kv_str(&w, "path", c.path)
	case Changes_Stage:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "path", c.path)
		if c.status != "" do kv_str(&w, "status", c.status)
	case Changes_Unstage:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "path", c.path)
		if c.status != "" do kv_str(&w, "status", c.status)
	case Changes_Discard:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "path", c.path)
		if c.status != "" do kv_str(&w, "status", c.status)
		if c.second do kv_bool(&w, "second", true)
		token(&w, c.confirm, redact)
	case Changes_Commit:
		kv_u64(&w, "tab_id", c.tab_id)
		if redact do kv_u64(&w, "message_bytes", u64(len(c.message)))
		else do kv_str(&w, "message", c.message)
	case Changes_Scan_Done:
		kv_str(&w, "root", c.root)
	case Changes_Diff_Done:
		kv_u64(&w, "tab_id", c.tab_id)
	case Changes_Op_Done:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "what", c.what)
		kv_bool(&w, "ok", c.err == "")
	// the Markdown tab (markdown_view.odin)
	case Markdown_Open:
		kv_str(&w, "path", c.path)
		if c.session != 0 do kv_u64(&w, "session", c.session)
		if c.anchor != "" do kv_str(&w, "anchor", c.anchor)
	case Markdown_Set_View:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_bool(&w, "source", c.source)
	case Show_File:
		kv_str(&w, "path", c.path)
		if c.line > 0 do kv_u64(&w, "line", u64(c.line))
		if c.anchor != "" do kv_str(&w, "anchor", c.anchor)
		if c.session != 0 do kv_u64(&w, "session", c.session)
	case Markdown_Scroll:
		kv_u64(&w, "tab_id", c.tab_id)
		if c.anchor != "" do kv_str(&w, "anchor", c.anchor)
		if c.line > 0 do kv_u64(&w, "line", u64(c.line))
	case Markdown_Follow:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "url", c.url)
		if c.confirm != "" do kv_str(&w, "confirm", c.confirm)
	// app tabs (app_tab.odin): never input, call or argument values in events
	case New_App_Tab:
		if c.session != 0 do kv_u64(&w, "session", c.session)
		if redact do kv_u64(&w, "argc", u64(len(c.argv) + (c.command != "" ? 1 : 0)))
		else {
			key(&w, "argv")
			strings.write_byte(b, '[')
			for a, i in c.argv {
				if i > 0 do strings.write_byte(b, ',')
				json_quote(b, a)
			}
			strings.write_byte(b, ']')
			if c.command != "" do kv_str(&w, "command", c.command)
		}
		if c.cwd != "" do kv_str(&w, "cwd", c.cwd)
		if c.title != "" do kv_str(&w, "title", c.title)
		if c.name != "" do kv_str(&w, "name", c.name)
	case App_Restart:
		kv_u64(&w, "tab_id", c.tab_id)
	case App_Close:
		kv_u64(&w, "tab_id", c.tab_id)
		token(&w, c.confirm, redact)
		if c.comments != .Ask do kv_str(&w, "comments", COMMENTS_CHOICE_NAMES[c.comments])
	case App_Declared:
		if c.session != 0 do kv_u64(&w, "session", c.session)
	case App_Input:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_u64(&w, "events", u64(len(c.events)))
	case App_Events:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "topic", c.topic)
		if c.since != 0 do kv_u64(&w, "since", c.since)
	case App_Call:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "method", c.method)
		if redact do kv_u64(&w, "params_bytes", u64(len(c.params)))
		else if c.params != "" {
			key(&w, "params")
			strings.write_string(b, c.params)
		}
	case App_Screenshot:
		kv_u64(&w, "tab_id", c.tab_id)
		if c.has_rect {
			key(&w, "rect")
			fmt.sbprintf(b, `{{"x":%v,"y":%v,"w":%v,"h":%v}}`, c.rect.x, c.rect.y, c.rect.w, c.rect.h)
		}
	case App_Inspect:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_bool(&w, "on", c.on)
	case App_Call_Done:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_bool(&w, "ok", c.ok)
	case App_Update:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "status", APP_STATUS_NAMES[c.status])
		if c.status == .Exited do kv_u64(&w, "exit_code", u64(max(c.exit_code, 0)))
	// pending comments (comments.odin): never the user's text in events and the log
	case Comment_Add:
		kv_str(&w, "source", COMMENT_SOURCE_NAMES[c.source])
		kv_u64(&w, "tab_id", c.tab_id)
		kv_str(&w, "what", c.what)
		kv_str(&w, "text", redact ? fmt.tprintf("<redacted %d bytes>", len(c.text)) : c.text)
		if c.crop != "" do kv_str(&w, "crop", c.crop)
	case Comment_Edit:
		kv_u64(&w, "comment_id", c.comment_id)
		kv_str(&w, "text", redact ? fmt.tprintf("<redacted %d bytes>", len(c.text)) : c.text)
	case Comment_Delete:
		kv_u64(&w, "comment_id", c.comment_id)
	case Comments_Clear:
		kv_u64(&w, "session", c.session)
	case Comments_Send_Now:
		kv_u64(&w, "session", c.session)
		if c.tab_id != 0 do kv_u64(&w, "tab_id", c.tab_id)
	case Pi_Attached:
		kv_u64(&w, "tab_id", c.tab_id)
		kv_u64(&w, "attachment_id", c.attachment_id)
	case Rescan, Refresh_Shell_Env, Get_State, List_Commands, Agent_Model_Picker, Jobs_Sync, Jobs_Tick, Comments_Ask_Cancel:
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update:
		browser_command_write(&w, cmd, redact) // below
	case Browser_Zoom, Browser_Find, Browser_Find_Close, Browser_Dialog, Browser_Permission, Browser_Popup, Browser_Edit, Browser_Devtools, Browser_External, Browser_Download:
		browser_polish_command_write(&w, cmd, redact) // browser_polish.odin
	case Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop:
		browser_agent_write(b, cmd, redact) // browser_agent.odin
	case Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel:
		browser_act_write(b, cmd, redact) // browser_act.odin
	case New_Claude_Tab, New_Claude_Session, Claude_Rename, Claude_Resume, Claude_Session_Report, Claude_Turn_Report, Claude_Comments, Claude_Attached, Claude_Prompt, Claude_Held_Op, Claude_Deliver, Claude_Restore_History, Claude_Readonly_Ack:
		claude_command_write(b, cmd, redact) // claude.odin: never prompt text, titles or flags
	case Add_Claude_Account, Rename_Claude_Account, Remove_Claude_Account, Set_Claude_Account_Default:
		claude_account_write(b, cmd) // claude_accounts.odin
	case Claude_Restart, Claude_Todos, Claude_Task, Claude_Subagent, Claude_Background:
		claude_extra_write(b, cmd) // claude_panels.odin: never their text
	case Claude_Model_Report:
		fmt.sbprintf(b, `,"tab_id":%d,"model":`, c.tab_id)
		json_quote(b, c.model)
	case Claude_Wait_Idle:
		claude_wait_write(b, c) // claude_wait.odin
	case Claude_Wait_Tick:
	}
	obj_end(&w)
}

command_json :: proc(cmd: Command, redact := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_command(&b, cmd, redact)
	return strings.to_string(b)
}

// ---- results and events ----

write_result :: proc(b: ^strings.Builder, r: Result, redact := false) {
	w := obj_begin(b)
	kv_bool(&w, "ok", r.ok)
	if r.error != "" do kv_str(&w, "error", r.error)
	if r.created_id != 0 do kv_u64(&w, "created_id", r.created_id)
	if r.pending do kv_bool(&w, "pending", true)
	if r.confirm_summary != "" {
		key(&w, "needs_confirmation")
		c := obj_begin(b)
		if !redact && r.confirm_token != "" do kv_str(&c, "token", r.confirm_token)
		kv_str(&c, "summary", r.confirm_summary)
		kv_str(&c, "by", r.confirm_by_user ? "user" : "caller")
		obj_end(&c)
	}
	if r.data != "" {
		key(&w, "data")
		strings.write_string(b, r.data) // already JSON
	}
	obj_end(&w)
}

result_json :: proc(r: Result) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_result(&b, r)
	return strings.to_string(b)
}

caller_kind_name :: proc(k: Caller_Kind) -> string {return CALLER_NAMES[k]}

// One event as an envelope line (redacted). full: a private finished event's data too (its requester's copy).
event_json :: proc(ev: Event, full := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := obj_begin(&b)
	kv_u64(&w, "v", PROTOCOL_VERSION)
	kv_str(&w, "type", "event")
	switch e in ev {
	case Command_Event:
		kv_str(&w, "event", "command")
		kv_u64(&w, "request_id", e.request_id)
		kv_str(&w, "caller", caller_kind_name(e.caller.kind))
		if e.caller.tab_id != 0 do kv_u64(&w, "caller_tab_id", e.caller.tab_id)
		kv_u64(&w, "version", e.version)
		kv_bool(&w, "changed", e.changed)
		key(&w, "command")
		write_command(&b, e.command, redact = true)
		key(&w, "result")
		write_result(&b, e.result, redact = true)
	case Finished_Event:
		kv_str(&w, "event", "finished")
		kv_u64(&w, "request_id", e.request_id)
		key(&w, "result")
		r := e.result
		if e.private && !full && r.data != "" do r.data = fmt.tprintf(`{{"private_bytes":%d}}`, len(r.data))
		write_result(&b, r, redact = true)
	case Job_Event:
		return job_event_json(e)
	}
	obj_end(&w)
	return strings.to_string(b)
}

// Panel rows as pi-kit's Line: {text, tone?, head?}.
write_rows :: proc(b: ^strings.Builder, rows: []Panel_Row) {
	strings.write_byte(b, '[')
	for r, i in rows {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_str(&o, "text", r.text)
		if r.tone != .Normal do kv_str(&o, "tone", TONE_NAMES[r.tone])
		if r.head do kv_bool(&o, "head", true)
		obj_end(&o)
	}
	strings.write_byte(b, ']')
}

// A terminal tab's status in the snapshot (agent_status.odin): the dot, its
// source (bridge, osc7501, none), when it last reported, unseen, and OSC
// 7501's record (app, kind, title, message: untrusted one-line text).
status_tab_json :: proc(b: ^strings.Builder, t: Tab) {
	v := tab_status_view(t)
	w := obj_begin(b)
	kv_str(&w, "dot", ROW_STATUS_NAMES[v.dot])
	kv_str(&w, "source", STATUS_SOURCE_NAMES[v.source])
	kv_bool(&w, "unseen", t.unseen)
	if v.at != {} do kv_str(&w, "at", iso_utc(v.at))
	if t.prog.state != .None {
		key(&w, "osc7501")
		p := obj_begin(b)
		kv_str(&p, "state", PROG_STATE_NAMES[t.prog.state])
		if t.prog.kind != .None do kv_str(&p, "kind", PROG_KIND_NAMES[t.prog.kind])
		if t.prog.progress >= 0 && (t.prog.state == .Working || t.prog.state == .Blocked) do kv_u64(&p, "progress", u64(t.prog.progress))
		if t.prog.app != "" do kv_str(&p, "app", t.prog.app)
		if t.prog.id != "" do kv_str(&p, "id", t.prog.id)
		if t.prog.title != "" do kv_str(&p, "title", t.prog.title)
		if t.prog.msg != "" do kv_str(&p, "message", t.prog.msg)
		kv_u64(&p, "records", u64(t.prog.records))
		kv_str(&p, "at", iso_utc(t.prog.at))
		obj_end(&p)
	}
	obj_end(&w)
}

// "2026-11-03T10:20:30Z" (temp).
iso_utc :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, sec := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, sec)
}

write_strings :: proc(b: ^strings.Builder, list: []string) {
	strings.write_byte(b, '[')
	for x, i in list {
		if i > 0 do strings.write_byte(b, ',')
		json_quote(b, x)
	}
	strings.write_byte(b, ']')
}

// Reply envelope to a request with client id `id`. request_id (commands
// over the socket) is pi-desk's id for the request: a `pending` result's
// `finished` event carries the same one.
reply_json :: proc(id: string, r: Result, request_id: u64 = 0) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := obj_begin(&b)
	kv_str(&w, "id", id)
	kv_u64(&w, "v", PROTOCOL_VERSION)
	kv_str(&w, "type", "result")
	if request_id != 0 do kv_u64(&w, "request_id", request_id)
	key(&w, "result")
	write_result(&b, r)
	obj_end(&w)
	return strings.to_string(b)
}

// ---- state snapshot ----

tab_kind_name :: proc(k: Tab_Kind) -> string {
	switch _ in k {
	case Pi_Tab:     return "pi"
	case Shell_Tab:  return "shell"
	case Editor_Tab: return "editor"
	case Changes_Tab: return "changes"
	case Markdown_Tab: return "markdown"
	case Browser_Tab: return "browser"
	case App_Tab: return "app"
	case Claude_Tab: return "claude"
	}
	return ""
}

// The state as JSON (temp allocator). Confirmation tokens are left out: only
// the caller that triggered a confirmation (or the user, via the UI) gets one.
state_json :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	write_state(&b, state)
	return strings.to_string(b)
}

// The snapshot as one pi tab may see it: only the open session holding
// `tab_id` and its project; no other sessions, listed sessions or pending
// confirmations. Same shape as state_json.
session_state_json :: proc(tab_id: u64) -> string {
	v := State {
		version  = state.version,
		next_id  = state.next_id,
		layout   = state.layout,
		settings = state.settings,
	}
	v.projects = make([dynamic]Project, context.temp_allocator)
	v.open_sessions = make([dynamic]Open_Session, context.temp_allocator)
	if s, _, _ := find_tab(tab_id); s != nil {
		append(&v.open_sessions, s^)
		if p := find_project(s.project_id); p != nil do append(&v.projects, p^)
		if state.current_session == s.id do v.current_session = s.id
	}
	b := strings.builder_make(context.temp_allocator)
	writing_tab_view = true
	write_state(&b, v)
	writing_tab_view = false
	return strings.to_string(b)
}

// A pi or Claude tab's own view is being written (session_state_json): no account folders.
@(private = "file")
writing_tab_view: bool

write_state :: proc(b: ^strings.Builder, s: State) {
	w := obj_begin(b)
	kv_u64(&w, "version", s.version)
	kv_u64(&w, "next_id", s.next_id)
	key(&w, "projects")
	strings.write_byte(b, '[')
	for p, i in s.projects {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_u64(&o, "id", p.id)
		kv_str(&o, "cwd", p.cwd)
		kv_str(&o, "label", p.label)
		kv_str(&o, "name", p.name)
		kv_str(&o, "dir", p.dir)
		if p.missing do kv_bool(&o, "missing", true)
		// the tidy list (project_tidy.odin): why it is hidden (user, temp, missing), the row it shows in
		if p.group == .Projects {
			if r := project_hide_reason(p); r != .None do kv_str(&o, "hidden_reason", HIDE_REASON_NAMES[r])
			if p.repo do kv_bool(&o, "repo", true)
			if p.temp do kv_bool(&o, "temp", true)
			if p.parent != 0 do kv_u64(&o, "parent", p.parent) // nested under that project's row
			if p.group_dir != "" do kv_str(&o, "group_dir", p.group_dir) // in that folder's group row
			if p.group_in != 0 do kv_u64(&o, "group_in", p.group_in) // that group row is nested under this project
			if p.group_up != "" do kv_str(&o, "group_up", p.group_up) // that group row is inside this one
		}
		if p.group == .Chats do kv_str(&o, "group", "chats")
		obj_end(&o)
	}
	strings.write_byte(b, ']')
	kv_u64(&w, "selected_project", s.selected_project)
	write_sessions :: proc(w: ^Jw, b: ^strings.Builder, name: string, list: []Session) {
		key(w, name)
		strings.write_byte(b, '[')
		for x, i in list {
			if i > 0 do strings.write_byte(b, ',')
			o := obj_begin(b)
			kv_str(&o, "id", x.id)
			kv_str(&o, "path", x.path)
			kv_str(&o, "when", x.when_)
			kv_str(&o, "title", x.title)
			obj_end(&o)
		}
		strings.write_byte(b, ']')
	}
	write_sessions(&w, b, "sessions", s.sessions[:])
	write_sessions(&w, b, "chats", s.chats[:])
	key(&w, "sidebar")
	{
		sb := s.sidebar
		o := obj_begin(b)
		key(&o, "pinned_projects")
		write_strings(b, sb.pinned_projects[:])
		key(&o, "pinned_sessions")
		write_strings(b, sb.pinned_sessions[:])
		key(&o, "hidden_projects")
		write_strings(b, sb.hidden_projects[:])
		key(&o, "hidden_sessions")
		write_strings(b, sb.hidden_sessions[:])
		key(&o, "sort")
		so := obj_begin(b)
		for sec in Sort_Section do kv_str(&so, SORT_SECTION_NAMES[sec], SORT_BY_NAMES[sb.sort[sec]])
		obj_end(&so)
		key(&o, "folded")
		fo := obj_begin(b)
		for f in Sidebar_Fold do kv_bool(&fo, FOLD_NAMES[f], sb.folded[f])
		obj_end(&fo)
		kv_bool(&o, "show_hidden", sb.show_hidden)
		key(&o, "expanded")
		write_strings(b, sb.expanded[:])
		key(&o, "filter")
		fl := obj_begin(b)
		kv_str(&fl, "text", sb.filter)
		kv_bool(&fl, "running", sb.only_running)
		kv_bool(&fl, "waiting", sb.only_waiting)
		kv_bool(&fl, "pinned", sb.only_pinned)
		obj_end(&fl)
		obj_end(&o)
	}
	key(&w, "open_sessions")
	strings.write_byte(b, '[')
	for os, i in s.open_sessions {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_u64(&o, "id", os.id)
		// a Claude-only session (claude.odin): its main tab is a Claude tab, and its id (here and as
		// claude_session_id) is that tab's Claude session id
		kv_str(&o, "agent", os.agent == .Claude ? "claude" : "pi")
		if os.agent == .Claude do kv_str(&o, "claude_session_id", os.pi_session_id)
		kv_str(&o, "pi_session_id", os.pi_session_id)
		kv_str(&o, "session_dir", os.session_dir)
		kv_str(&o, "session_file", os.session_file)
		kv_u64(&o, "project_id", os.project_id)
		kv_str(&o, "cwd", os.cwd)
		kv_u64(&o, "active_tab", os.active_tab)
		panes_json(b, &o, os) // its panes and their layout (panes.odin)
		if os.missing do kv_bool(&o, "missing", true)
		if os.home do kv_bool(&o, "home", true)
		// pending comments for its pi (comments.odin), and why they wait ("" = they go with the next message)
		key(&o, "comments")
		strings.write_byte(b, '[')
		for c, k in os.comments {
			if k > 0 do strings.write_byte(b, ',')
			co := obj_begin(b)
			kv_u64(&co, "id", c.id)
			kv_str(&co, "source", COMMENT_SOURCE_NAMES[c.source])
			kv_u64(&co, "tab_id", c.tab_id)
			kv_str(&co, "what", c.what)
			kv_str(&co, "text", c.text)
			kv_str(&co, "crop", c.crop)
			y, mo, d := time.date(c.created)
			h, mi, sec := time.clock(c.created)
			kv_str(&co, "created", fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, sec))
			obj_end(&co)
		}
		strings.write_byte(b, ']')
		if len(os.comments) > 0 {
			sos := os
			_, why := comments_ready(&sos)
			kv_str(&o, "comments_wait", why)
			kv_bool(&o, "comments_sending", os.attach.sending != 0)
		}
		{
			sos := os
			st, _ := session_row_status(&sos)
			kv_str(&o, "agent_status", ROW_STATUS_NAMES[st]) // the row's dot: the strongest of its tabs
		}
		key(&o, "tabs")
		strings.write_byte(b, '[')
		for t, j in os.tabs {
			if j > 0 do strings.write_byte(b, ',')
			to := obj_begin(b)
			kv_u64(&to, "id", t.id)
			kv_str(&to, "kind", tab_kind_name(t.kind))
			kv_str(&to, "title", t.title)
			kv_str(&to, "status", TAB_STATUS_NAMES[t.status])
			{
				sos := os
				pn := session_pane(&sos, t.pane)
				kv_u64(&to, "pane", pn != nil ? pn.id : 0)
				kv_bool(&to, "on_screen", os.id == s.current_session && session_tab_shown(&sos, t.id))
			}
			if t.status == .Exited do if how := exit_text(t.exit); how != "" do kv_str(&to, "exit", how)
			if t.cwd != "" do kv_str(&to, "cwd", t.cwd)
			if et, is_ed := t.kind.(Editor_Tab); is_ed {
				kv_str(&to, "path", et.path)
				if et.view != .File do kv_str(&to, "view", EDITOR_VIEW_NAMES[et.view])
				if et.preview do kv_bool(&to, "preview", true)
				kv_bool(&to, "dirty", editor_dirty(editor_of(t.id)))
			}
			if ct, is_ch := t.kind.(Changes_Tab); is_ch do kv_str(&to, "root", ct.root)
			if _, is_br := t.kind.(Browser_Tab); is_br do annot_tab_json(b, t.id) // comment mode, markers (browser_annotate.odin)
			if _, is_br := t.kind.(Browser_Tab); is_br do browser_polish_tab_json(b, t.id) // zoom, bars, downloads (browser_polish.odin)
			if _, is_br := t.kind.(Browser_Tab); is_br do browser_agent_tab_json(b, t.id) // the agent strip (browser_agent.odin)
			if _, is_br := t.kind.(Browser_Tab); is_br do browser_act_tab_json(b, t.id) // an upload's ask (browser_act.odin)
			if bt, is_web := t.kind.(Browser_Tab); is_web {
				// browser_nav.odin: what the page reported
				kv_str(&to, "url", bt.url)
				kv_bool(&to, "loading", bt.loading)
				kv_bool(&to, "can_back", bt.can_back)
				kv_bool(&to, "can_forward", bt.can_forward)
				if bt.blocked_popup != "" do kv_str(&to, "blocked_popup", bt.blocked_popup)
				// its page: open | waiting (no slot free) | unloaded (opens when shown) | closed (see the tab)
				if b := browser_of(t.id); b != nil do kv_str(&to, "page", b.cef != 0 ? "open" : b.waiting ? "waiting" : b.lazy ? "unloaded" : b.message != "" ? "closed" : "opening")
			}
			if at, is_app := t.kind.(App_Tab); is_app {
				kv_str(&to, "app_status", APP_STATUS_NAMES[at.app_status])
				if at.exit_code >= 0 do kv_u64(&to, "exit_code", u64(at.exit_code))
				if a := app_of(t.id); a != nil {
					kv_u64(&to, "frames", a.ring.shown)
					kv_bool(&to, "inspect", a.inspect)
					kv_u64(&to, "boxes", u64(app_box_count(t.id)))
					if g := ring_gen(&a.ring, a.ring.cur_gen); g != nil {
						kv_u64(&to, "ring_gen", u64(g.gen))
						kv_u64(&to, "ring_w", u64(g.w))
						kv_u64(&to, "ring_h", u64(g.h))
					}
				}
			}
			if _, is_cl := t.kind.(Claude_Tab); is_cl do claude_tab_json(b, t) // claude.odin
			if mt, is_md := t.kind.(Markdown_Tab); is_md {
				kv_str(&to, "path", mt.path)
				kv_bool(&to, "source", mt.source)
				if v := md_view_of(t.id); v != nil && v.laid {
					line, links, headings, matches := md_state_numbers(v, t.id, mt.source)
					kv_u64(&to, "line", u64(line))
					kv_u64(&to, "links", u64(links))
					kv_u64(&to, "headings", u64(headings))
					if matches >= 0 do kv_u64(&to, "matches", u64(matches))
				}
			}
			if tab_is_terminal(t) {
				key(&to, "agent_status") // the dot and where it came from (agent_status.odin)
				status_tab_json(b, t)
			}
			if _, is_pi := t.kind.(Pi_Tab); is_pi {
				kv_str(&to, "agent", AGENT_NAMES[t.agent])
				kv_bool(&to, "waiting", t.waiting)
				kv_bool(&to, "question", t.question)
				key(&to, "blockers")
				write_strings(b, t.blockers[:])
				key(&to, "reload") // hot reload (reload.odin)
				write_tab_reload(b, t.reload)
				key(&to, "panels")
				write_panels(b, t.panels[:])
			}
			if _, is_cl := t.kind.(Claude_Tab); is_cl {
				key(&to, "reload") // hot reload and version (claude_reload.odin)
				write_tab_reload(b, t.reload)
				key(&to, "panels") // Claude's todos and subagents (claude_panels.odin)
				write_panels(b, t.panels[:])
			}
			obj_end(&to)
		}
		strings.write_byte(b, ']')
		obj_end(&o)
	}
	strings.write_byte(b, ']')
	kv_u64(&w, "current_session", s.current_session)
	fmt.sbprintf(b, `,"pi_installed":%v`, pi_installed()) // pi found (harness.odin): stat, else the login shell's answer
	fmt.sbprintf(b, `,"claude_installed":%v`, claude_installed()) // Claude Code found (claude.odin): new_claude_session would start
	if !writing_tab_view do claude_accounts_json(b) // the Claude Code accounts (claude_accounts.odin): labels and folders; the full snapshot only
	claude_history_json(b, s.claude_history[:], s.claude_disk[:], s.claude_disk_chats[:]) // Claude sessions pi-desk ran (claude.odin); not in a pi or Claude tab's own view
	key(&w, "home")
	{
		h := obj_begin(b)
		kv_u64(&h, "session", s.home)
		tab: u64
		for os in s.open_sessions do if os.id == s.home && len(os.tabs) > 0 do tab = os.tabs[0].id
		kv_u64(&h, "tab_id", tab)
		kv_bool(&h, "open", s.home_open)
		obj_end(&h)
	}
	key(&w, "agent")
	write_agent(b, s.agent)
	key(&w, "notifications") // the bell (notify.odin): counts only; notifications_list has the entries
	{
		n := obj_begin(b)
		unread := 0
		for x in s.notices.items do if !x.read do unread += 1
		kv_u64(&n, "count", u64(len(s.notices.items)))
		kv_u64(&n, "unread", u64(unread))
		kv_u64(&n, "os_notified", u64(s.notices.os_sent))
		obj_end(&n)
	}
	key(&w, "update") // pi-desk's own updates (update.odin): read-only for agents
	update_state_json(b)
	key(&w, "jobs")
	write_job_rows(b, s.jobs[:], false)
	key(&w, "jobs_unread")
	strings.write_int(b, s.jobs_unread)
	key(&w, "jobs_notified")
	strings.write_int(b, s.jobs_notified)
	key(&w, "reload") // the hot-reload bar (reload.odin)
	write_reload(b, s.reload)
	key(&w, "focus")
	{
		f := obj_begin(b)
		if s.focus_widget != "" {
			kv_str(&f, "kind", "widget")
			kv_str(&f, "id", s.focus_widget)
			if s.focus_widget == "setup" do setup_json(&f) // the first-run sheet's step (ui_setup.odin)
		} else {
			kv_str(&f, "kind", "terminal")
			tab: u64
			for os in s.open_sessions do if os.id == s.current_session do tab = os.active_tab
			kv_u64(&f, "tab_id", tab)
		}
		obj_end(&f)
	}
	key(&w, "layout")
	{
		l := obj_begin(b)
		kv_f32(&l, "left_width", s.layout.left_width)
		kv_f32(&l, "right_width", s.layout.right_width)
		kv_bool(&l, "left_open", s.layout.left_open)
		kv_bool(&l, "right_open", s.layout.right_open)
		kv_f32(&l, "drawer_width", s.layout.drawer_width)
		kv_bool(&l, "drawer_pinned", s.layout.drawer_pinned)
		key(&l, "panels")
		strings.write_byte(b, '[')
		for p, i in s.layout.panels {
			if i > 0 do strings.write_byte(b, ',')
			json_quote(b, p)
		}
		strings.write_byte(b, ']')
		key(&l, "collapsed")
		write_strings(b, s.layout.collapsed[:])
		kv_str(&l, "left_tab", LEFT_TAB_NAMES[s.layout.left_tab])
		obj_end(&l)
	}
	key(&w, "files")
	{
		f := obj_begin(b)
		kv_str(&f, "filter", s.files.filter)
		key(&f, "expanded")
		strings.write_byte(b, '[')
		for fr, i in s.files.expanded {
			if i > 0 do strings.write_byte(b, ',')
			o := obj_begin(b)
			kv_str(&o, "root", fr.root)
			key(&o, "dirs")
			write_strings(b, fr.dirs[:])
			obj_end(&o)
		}
		strings.write_byte(b, ']')
		key(&f, "checkouts")
		strings.write_byte(b, '[')
		for c, i in s.files.checkouts {
			if i > 0 do strings.write_byte(b, ',')
			o := obj_begin(b)
			kv_str(&o, "base", c.base)
			kv_str(&o, "path", c.path)
			obj_end(&o)
		}
		strings.write_byte(b, ']')
		obj_end(&f)
	}
	key(&w, "pending_confirmations")
	strings.write_byte(b, '[')
	for p, i in s.pending_confirmations {
		if i > 0 do strings.write_byte(b, ',')
		o := obj_begin(b)
		kv_str(&o, "summary", p.summary)
		kv_str(&o, "caller", caller_kind_name(p.caller.kind))
		kv_str(&o, "class", CLASS_NAMES[p.class])
		key(&o, "command")
		write_command(b, p.command, redact = true)
		obj_end(&o)
	}
	strings.write_byte(b, ']')
	// the close prompt (comments.odin): a tab, or a session (tab_id 0), closed with comments not sent
	if s.comments_ask != {} {
		key(&w, "comments_ask")
		o := obj_begin(b)
		kv_u64(&o, "session", s.comments_ask.session)
		kv_u64(&o, "tab_id", s.comments_ask.tab_id)
		obj_end(&o)
	}
	key(&w, "settings")
	{
		st := obj_begin(b)
		key(&st, "confirm")
		cf := obj_begin(b)
		for k in Caller_Kind {
			if k == .UI || k == .Internal do continue
			key(&cf, CALLER_NAMES[k])
			ko := obj_begin(b)
			for cl in Command_Class do kv_str(&ko, CLASS_NAMES[cl], MODE_NAMES[s.settings.confirm[k][cl]])
			obj_end(&ko)
		}
		obj_end(&cf)
		key(&st, "confirm_close")
		cc := obj_begin(b)
		for k in Tab_Kind_Id do kv_str(&cc, TAB_KIND_NAMES[k], CLOSE_NAMES[s.settings.confirm_close[k]])
		obj_end(&cc)
		kv_str(&st, "theme", THEME_NAMES[s.settings.theme])
		kv_bool(&st, "reduce_motion", s.settings.reduce_motion)
		kv_u64(&st, "terminal_text_size", u64(s.settings.term_text_pt))
		kv_str(&st, "appearance", APPEARANCE_NAMES[s.settings.appearance])
		kv_bool(&st, "light", s.settings.appearance == .System ? s.system_light : s.settings.appearance == .Light) // what shows now
		kv_str(&st, "text_size", TEXT_SIZE_NAMES[s.settings.text_size])
		kv_bool(&st, "chats_readonly", s.settings.chats_readonly)
		kv_bool(&st, "claude_skip_permissions", s.settings.claude_skip_permissions)
		// the pi integration's optional extensions, on or off for the pi tabs started from now on
		key(&st, "pi_extensions")
		pe := obj_begin(b)
		for e in pi_integration_optional() do kv_bool(&pe, e.name, e.on)
		obj_end(&pe)
		kv_str(&st, "agent_model", s.settings.agent_model)
		kv_str(&st, "agent_name", s.settings.agent_name)
		kv_bool(&st, "notify", !s.settings.notify_off)
		kv_bool(&st, "tidy_projects", !s.settings.tidy_off)
		kv_bool(&st, "keep_sessions", s.settings.keep_sessions)
		key(&st, "bell")
		bo := obj_begin(b)
		for g in Bell_Group do kv_bool(&bo, BELL_GROUP_NAMES[g], g not_in s.settings.bell_off)
		kv_bool(&bo, "os", !s.settings.bell_os_off)
		obj_end(&bo)
		// the main folder and the effective subfolders (folders.odin)
		kv_str(&st, "home_dir", s.settings.home_dir)
		kv_bool(&st, "setup_seen", s.settings.setup_seen)
		key(&st, "folders")
		fo := obj_begin(b)
		for f in Folder_Kind {
			key(&fo, FOLDER_NAMES[f])
			fe := obj_begin(b)
			kv_str(&fe, "path", folder_path(s.settings, f))
			kv_bool(&fe, "custom", s.settings.folders[f] != "")
			obj_end(&fe)
		}
		obj_end(&fo)
		// what pi tabs and jobs get as PI_KIT_NOTES_DIR; yours: the user's own environment sets it (it wins)
		key(&st, "notes_env")
		ne := obj_begin(b)
		yours := notes_env_user()
		ours := ""
		if sp := folder_path(s.settings, .Sessions); sp != "" && filepath.base(sp) == "sessions" do ours = filepath.dir(sp)
		kv_str(&ne, "value", yours != "" ? yours : ours)
		kv_bool(&ne, "yours", yours != "")
		obj_end(&ne)
		kv_str(&st, "pi_path", s.settings.pi_path)
		kv_bool(&st, "jobs_paused", s.settings.jobs_paused)
		l := s.settings.job_limits
		key(&st, "job_limits")
		fmt.sbprintf(st.b, `{{"max_cost":%v,"timeout":%d,"max_turns":%d,"day":%v,"week":%v,"month":%v,"concurrency":%d,"loop_calls":%d,"stall":%d,"fail_pause":%d}}`, l.max_cost, l.timeout, l.max_turns, l.day, l.week, l.month, l.concurrency, limit_loop(), limit_stall(), limit_fail())
		obj_end(&st)
	}
	obj_end(&w)
}

// `list_commands`' data: {"commands": [{type, args?, does, confirm_class?,
// long_running?}]}, the commands `caller` may send (temp allocator).
list_commands_json :: proc(caller: Caller) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"commands":[`)
	n := 0
	for s in COMMAND_SPECS {
		if s.who == .Internal || !who_allows(caller.kind, s.who) do continue
		// a pi tab's bridge and a Claude tab (both panel) report different things (caller_may)
		if caller.kind == .Panel && (s.who == .Claude) != caller.claude && (s.who == .Claude || s.who == .Report || s.who == .Bridge) do continue
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		w := obj_begin(&b)
		kv_str(&w, "type", s.type)
		if s.args != "" do kv_str(&w, "args", s.args)
		kv_str(&w, "does", s.does)
		if c, ok := s.confirm.?; ok do kv_str(&w, "confirm_class", CLASS_NAMES[c])
		if s.long_running do kv_bool(&w, "long_running", true)
		obj_end(&w)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}


// The agent in the state snapshot: unread runs, whether it waits for the
// user, the model it runs as far as pi-desk can tell (agent_model).
write_agent :: proc(b: ^strings.Builder, a: Agent_Info) {
	w := obj_begin(b)
	kv_u64(&w, "unread", u64(a.unread))
	kv_bool(&w, "needs_user", agent_needs_user())
	kv_str(&w, "model", agent_model())
	kv_u64(&w, "notified", u64(a.notified))
	obj_end(&w)
}

// browser tabs' commands (browser_nav.odin). URLs go into events: they are
// what the tab shows (State has them too).
@(private = "file")
// redact (events, logs): addresses without their user:pass@ (browser_url_public).
browser_command_write :: proc(w: ^Jw, cmd: Command, redact := false) {
	url :: proc(u: string, redact: bool) -> string {return redact ? browser_url_redacted(u) : u}
	#partial switch c in cmd {
	case Browser_Open:
		if c.session != 0 do kv_u64(w, "session", c.session)
		kv_str(w, "url", url(c.url, redact))
	case Browser_Navigate:
		kv_u64(w, "tab_id", c.tab_id)
		kv_str(w, "url", url(c.url, redact))
	case Browser_Back:    kv_u64(w, "tab_id", c.tab_id)
	case Browser_Forward: kv_u64(w, "tab_id", c.tab_id)
	case Browser_Reload:  kv_u64(w, "tab_id", c.tab_id)
	case Browser_Stop:    kv_u64(w, "tab_id", c.tab_id)
	case Browser_Update:
		kv_u64(w, "tab_id", c.tab_id)
		if .Url in c.what do kv_str(w, "url", url(c.url, redact))
		if .Title in c.what do kv_str(w, "title", c.title)
		if .Nav in c.what {
			kv_bool(w, "loading", c.loading)
			kv_bool(w, "can_back", c.can_back)
			kv_bool(w, "can_forward", c.can_forward)
		}
		if .Blocked in c.what do kv_str(w, "blocked_popup", c.blocked)
	}
}

// A tab's panels: [{panel, title, rows}].
@(private = "file")
write_panels :: proc(b: ^strings.Builder, panels: []Panel) {
	strings.write_byte(b, '[')
	for p, k in panels {
		if k > 0 do strings.write_byte(b, ',')
		po := obj_begin(b)
		kv_str(&po, "panel", p.id)
		kv_str(&po, "title", p.title)
		key(&po, "rows")
		write_rows(b, p.rows[:])
		obj_end(&po)
	}
	strings.write_byte(b, ']')
}

// The harness checklist (harness_manifest.odin) as the sheet shows it: each item's state, what it
// found, its action and command; the run.
@(private = "file")
harness_json :: proc(f: ^Jw) {
	key(f, "agents")
	strings.write_byte(f.b, '[')
	for it, i in harness_items {
		if i > 0 do strings.write_byte(f.b, ',')
		r := HARNESS_MANIFEST[it.row]
		o := obj_begin(f.b)
		kv_str(&o, "id", r.id)
		kv_str(&o, "harness", HARNESS_KEYS[r.harness])
		kv_str(&o, "kind", r.kind == .Harness ? "harness" : r.kind == .Built_In ? "built_in" : "third_party")
		kv_str(&o, "need", r.need == .Required ? "required" : "recommended")
		kv_str(&o, "state", HARNESS_STATE_NAMES[it.state])
		if it.version != "" do kv_str(&o, "version", it.version)
		if r.kind == .Harness && it.where_ != "" do kv_str(&o, "layout", INSTALL_LAYOUT_NAMES[it.layout])
		kv_str(&o, "action", it.action == .Install ? "install" : it.action == .Update ? "update" : "none")
		if it.command != "" do kv_str(&o, "command", it.command)
		if it.action != .None do kv_bool(&o, "runnable", it.runnable)
		obj_end(&o)
	}
	strings.write_byte(f.b, ']')
	if harness_run.status == .None do return
	key(f, "run")
	o := obj_begin(f.b)
	kv_str(&o, "item", harness_run.item)
	names := [Harness_Run_Status]string{.None = "none", .Running = "running", .Done = "done", .Failed = "failed"}
	kv_str(&o, "status", names[harness_run.status])
	if harness_run.exit.known do kv_u64(&o, "code", u64(harness_run.exit.code))
	obj_end(&o)
}

// The sheet in the snapshot's focus: its step, how many, and the accounts step's list (labels
// and folders the user sees; nothing written yet).
@(private = "file")
setup_json :: proc(f: ^Jw) {
	u := &setup_ui // ui_setup.odin
	names := [Setup_Step]string{.Agents = "agents", .Main = "main", .Chats = "chats", .Accounts = "accounts", .Folders = "folders"}
	kv_str(f, "step", names[setup_step_kind()])
	kv_u64(f, "steps", u64(setup_steps()))
	if u.err != "" do kv_str(f, "error", u.err)
	harness_json(f)
	if !u.acct_show do return
	key(f, "accounts")
	strings.write_byte(f.b, '[')
	for a, i in u.accounts {
		if i > 0 do strings.write_byte(f.b, ',')
		o := obj_begin(f.b)
		kv_str(&o, "label", a.label)
		kv_str(&o, "dir", a.dir)
		kv_bool(&o, "keep", a.keep)
		kv_bool(&o, "marked", a.marked)
		if i == u.acct_default && a.keep do kv_bool(&o, "default", true)
		if a.hand do kv_bool(&o, "added", true)
		obj_end(&o)
	}
	strings.write_byte(f.b, ']')
	if u.acct_msg != "" do kv_str(f, "message", u.acct_msg)
}

// An open session's panes (panes.odin): "focused_pane", "panes" (in leaf order: id, slot, the
// tab it shows, its tabs in strip order, its content rect in logical px once laid out) and
// "layout", the tree: {"pane": id} or {"split": id, "dir": "right"|"down", "ratio", "a", "b"}.
// A session with no panes yet (one read back from a snapshot): its implicit one, id 0.
@(private = "file")
panes_json :: proc(b: ^strings.Builder, o: ^Jw, os: Open_Session) {
	s := os
	fp := session_focused_pane(&s)
	kv_u64(o, "focused_pane", fp != nil ? fp.id : 0)
	key(o, "panes")
	strings.write_byte(b, '[')
	if len(s.panes) == 0 && fp != nil {
		po := obj_begin(b)
		kv_u64(&po, "id", 0)
		kv_u64(&po, "slot", 0)
		kv_u64(&po, "active_tab", fp.active)
		key(&po, "tabs")
		write_ids(b, pane_strip(&s, fp))
		obj_end(&po)
	}
	for &p, i in s.panes {
		if i > 0 do strings.write_byte(b, ',')
		po := obj_begin(b)
		kv_u64(&po, "id", p.id)
		kv_u64(&po, "slot", u64(p.slot))
		kv_u64(&po, "active_tab", p.active)
		key(&po, "tabs")
		write_ids(b, pane_strip(&s, &p))
		if p.rect.z > 0 && app.dpi > 0 {
			key(&po, "rect")
			r := p.rect / app.dpi
			fmt.sbprintf(b, `{{"x":%d,"y":%d,"w":%d,"h":%d}}`, int(r.x), int(r.y), int(r.z), int(r.w))
		}
		obj_end(&po)
	}
	strings.write_byte(b, ']')
	if len(s.nodes) == 0 do return
	key(o, "layout")
	node :: proc(b: ^strings.Builder, s: ^Open_Session, n: int) {
		x := s.nodes[n]
		if x.leaf {
			fmt.sbprintf(b, `{{"pane":%d}}`, x.pane)
			return
		}
		fmt.sbprintf(b, `{{"split":%d,"dir":"%s","ratio":%.3f,"a":`, x.id, x.dir == .Right ? "right" : "down", x.ratio)
		node(b, s, x.a)
		strings.write_string(b, `,"b":`)
		node(b, s, x.b)
		strings.write_byte(b, '}')
	}
	node(b, &s, s.root)
}

@(private = "file")
write_ids :: proc(b: ^strings.Builder, ids: []u64) {
	strings.write_byte(b, '[')
	for id, i in ids {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_u64(b, id)
	}
	strings.write_byte(b, ']')
}
