package core

// Command inbox: the one path into run_command. Any thread submits; the main
// thread drains at the top of every frame, after each UI event, and when
// platform.wake fires (so commands run even while frames are paused). Each
// entry has a request id; a caller that wants the Result passes a Reply and
// waits on it. Long-running commands return `pending` at once and finish with
// a Finished_Event carrying the same request id.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"

Reply :: struct {
	done:    sync.One_Shot_Event,
	result:  Result, // heap copies; release with result_free
	// optional, main thread, before `done` fires: lets the socket queue the
	// reply line in order with the events that follow it
	deliver: proc(reply: ^Reply, request_id: u64),
}

Request :: struct {
	id:     u64,
	caller: Caller,
	cmd:    Command, // heap copy owned by the inbox
	reply:  ^Reply,
	menu:   string, // a menu row's label (heap): its outcome is shown (menu_result)
}

@(private = "file")
inbox_mu: sync.Mutex
@(private = "file")
inbox_queue: [dynamic]Request
@(private = "file")
inbox_next: u64

// Queues cmd (copied) and returns its request id. Any thread.
inbox_submit :: proc(cmd: Command, caller: Caller, reply: ^Reply = nil, menu := "") -> u64 {
	heap := runtime.heap_allocator()
	c := command_clone(cmd, heap)
	label := strings.clone(menu, heap)
	sync.lock(&inbox_mu)
	inbox_next += 1
	id := inbox_next
	if inbox_queue.allocator.procedure == nil do inbox_queue.allocator = heap
	append(&inbox_queue, Request{id = id, caller = caller, cmd = c, reply = reply, menu = label})
	sync.unlock(&inbox_mu)
	if platform.wake != nil do platform.wake()
	return id
}

// Runs everything queued, in order. Main thread only. The window's frames are read first
// (window_link.odin: its queued commands join the queue), and its state delta goes at the end.
inbox_drain :: proc() {
	heap := runtime.heap_allocator()
	ui_ran := false // the user's commands: their delta compares every section (window_link_flush)
	for {
		window_link_pump()
		sync.lock(&inbox_mu)
		batch := inbox_queue
		inbox_queue = make([dynamic]Request, heap)
		sync.unlock(&inbox_mu)
		if len(batch) == 0 {
			delete(batch)
			window_link_flush(sweep = ui_ran)
			return
		}
		for r in batch {
			if r.caller.kind == .UI do ui_ran = true
			res := run_command(r.cmd, r.caller, r.id)
			if r.reply != nil {
				r.reply.result = result_clone(res, heap)
				if r.reply.deliver != nil do r.reply.deliver(r.reply, r.id)
				sync.one_shot_event_signal(&r.reply.done)
			}
			if r.menu != "" do menu_result(r.menu, r.cmd, res)
			delete(r.menu, heap)
			command_free(r.cmd, heap)
		}
		delete(batch)
	}
}

// Runs cmd now, with a request id of its own, outside the queue (what a direct run_command did):
// the window's calls that need their result at once (window_link.odin). Main thread.
inbox_run_now :: proc(cmd: Command, caller: Caller, menu := "") -> (Result, u64) {
	sync.lock(&inbox_mu)
	inbox_next += 1
	id := inbox_next
	sync.unlock(&inbox_mu)
	res := run_command(cmd, caller, id)
	if menu != "" do menu_result(menu, cmd, res)
	return res, id
}

result_clone :: proc(r: Result, allocator: runtime.Allocator) -> Result {
	out := r
	out.error = strings.clone(r.error, allocator)
	out.confirm_token = strings.clone(r.confirm_token, allocator)
	out.confirm_summary = strings.clone(r.confirm_summary, allocator)
	out.data = strings.clone(r.data, allocator)
	return out
}

result_free :: proc(r: Result) {
	allocator := runtime.heap_allocator()
	delete(r.error, allocator)
	delete(r.confirm_token, allocator)
	delete(r.confirm_summary, allocator)
	delete(r.data, allocator)
}

// Deep copy of a command's strings.
command_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	s :: proc(v: string, a: runtime.Allocator) -> string {return strings.clone(v, a)}
	switch c in cmd {
	case Add_Project:         return Add_Project{cwd = s(c.cwd, allocator)}
	case Rename_Project:      return Rename_Project{project_id = c.project_id, name = s(c.name, allocator)}
	case Open_Session_Cmd:    return Open_Session_Cmd{project_id = c.project_id, pi_session_id = s(c.pi_session_id, allocator)}
	case Close_Tab:           return Close_Tab{tab_id = c.tab_id, confirm = s(c.confirm, allocator), comments = c.comments}
	case Close_Session:       return Close_Session{session = c.session, confirm = s(c.confirm, allocator), ask = c.ask, comments = c.comments}
	case Send_Text:           return Send_Text{tab_id = c.tab_id, text = s(c.text, allocator)}
	case Terminal_Link:       return Terminal_Link{tab_id = c.tab_id, url = s(c.url, allocator), external = c.external}
	case Set_Focus:           return Set_Focus{widget = s(c.widget, allocator)}
	case Focus_Take:          return Focus_Take{widget = s(c.widget, allocator)}
	case Focus_Release:       return Focus_Release{widget = s(c.widget, allocator)}
	case Set_Last_Harness:    return cmd
	case Set_Panel:           return Set_Panel{panel = s(c.panel, allocator), open = c.open}
	case Cancel_Confirmation: return Cancel_Confirmation{token = s(c.token, allocator)}
	case Quit:                return Quit{confirm = s(c.confirm, allocator), stop_sessions = c.stop_sessions}
	case Set_Claude_Default_Flags: return Set_Claude_Default_Flags{skip_permissions = c.skip_permissions, confirm = s(c.confirm, allocator)}
	case Set_Pi_Extension:    return Set_Pi_Extension{name = s(c.name, allocator), on = c.on}
	case Pi_Session_Update:   return Pi_Session_Update{tab_id = c.tab_id, pi_session_id = s(c.pi_session_id, allocator), session_file = s(c.session_file, allocator), cwd = s(c.cwd, allocator)}
	case Pi_Status_Update:
		b := make([]string, len(c.blockers), allocator)
		for x, i in c.blockers do b[i] = s(x, allocator)
		return Pi_Status_Update{tab_id = c.tab_id, agent = c.agent, waiting = c.waiting, question = c.question, blockers = b}
	case Pi_Prompt:
		imgs := make([]Prompt_Image, len(c.images), allocator)
		for im, i in c.images do imgs[i] = {mime = s(im.mime, allocator), data = s(im.data, allocator)}
		return Pi_Prompt{tab_id = c.tab_id, text = s(c.text, allocator), images = imgs}
	case Pi_Reload:           return Pi_Reload{tab_id = c.tab_id, confirm = s(c.confirm, allocator)}
	case Bridge_Done:         return Bridge_Done{request_id = c.request_id, ok = c.ok, error = s(c.error, allocator)}
	case Panel_Set:
		rows := make([]Panel_Row, len(c.rows), allocator)
		for r, i in c.rows do rows[i] = {text = s(r.text, allocator), tone = r.tone, head = r.head}
		return Panel_Set{tab_id = c.tab_id, panel = s(c.panel, allocator), title = s(c.title, allocator), rows = rows}
	case Panel_Remove:        return Panel_Remove{tab_id = c.tab_id, panel = s(c.panel, allocator)}
	case Set_Pinned:          return Set_Pinned{cwd = s(c.cwd, allocator), project_id = c.project_id, pi_session_id = s(c.pi_session_id, allocator), pinned = c.pinned, index = c.index}
	case Set_Home_Dir:        return Set_Home_Dir{path = s(c.path, allocator), create = c.create, setup = c.setup}
	case Set_Folder:          return Set_Folder{kind = c.kind, path = s(c.path, allocator)}
	case Set_Row_Expanded:    return Set_Row_Expanded{path = s(c.path, allocator), expanded = c.expanded}
	case Set_Unread:          return Set_Unread{tab_id = c.tab_id, pi_session_id = s(c.pi_session_id, allocator), unread = c.unread}
	case Program_Status: 	// internal, run at once (status_pump); never queued: its strings stay borrowed
		return cmd
	case Set_Hidden:          return Set_Hidden{cwd = s(c.cwd, allocator), project_id = c.project_id, pi_session_id = s(c.pi_session_id, allocator), hidden = c.hidden}
	case Reveal_Path:         return Reveal_Path{project_id = c.project_id, pi_session_id = s(c.pi_session_id, allocator)}
	case Session_Info:        return Session_Info{project_id = c.project_id, pi_session_id = s(c.pi_session_id, allocator), to = s(c.to, allocator)}
	case Copy_Path:           return Copy_Path{project_id = c.project_id, pi_session_id = s(c.pi_session_id, allocator)}
	case Set_Filter:
		out := c
		if t, ok := c.text.?; ok do out.text = s(t, allocator)
		return out
	case Restore_Sidebar:
		l :: proc(v: []string, a: runtime.Allocator) -> []string {
			o := make([]string, len(v), a)
			for x, i in v do o[i] = strings.clone(x, a)
			return o
		}
		return Restore_Sidebar{pinned_projects = l(c.pinned_projects, allocator), pinned_sessions = l(c.pinned_sessions, allocator), hidden_projects = l(c.hidden_projects, allocator), hidden_sessions = l(c.hidden_sessions, allocator)}
	case Set_Panel_Collapsed: return Set_Panel_Collapsed{panel = s(c.panel, allocator), collapsed = c.collapsed}
	case Restore_Session:
		tabs := make([]Restore_Tab, len(c.tabs), allocator)
		for t, i in c.tabs {
			args := make([]string, len(t.args), allocator)
			for x, j in t.args do args[j] = s(x, allocator)
			tabs[i] = {kind = t.kind, title = s(t.title, allocator), cwd = s(t.cwd, allocator), active = t.active, claude_id = s(t.claude_id, allocator), args = args, readonly = t.readonly, account = s(t.account, allocator), pane = t.pane, pane_active = t.pane_active, held = t.held}
		}
		layout := c.layout
		layout.nodes = make([]Restore_Node, len(c.layout.nodes), allocator)
		copy(layout.nodes, c.layout.nodes)
		return Restore_Session{project_id = c.project_id, pi_session_id = s(c.pi_session_id, allocator), session_dir = s(c.session_dir, allocator), cwd = s(c.cwd, allocator), tabs = tabs, home = c.home, agent = c.agent, layout = layout, pi_pane = c.pi_pane, pi_active = c.pi_active, pi_held = c.pi_held, pi_readonly = c.pi_readonly}
	case Set_Agent_Name:      return Set_Agent_Name{name = s(c.name, allocator)}
	case Set_Agent_Model:     return Set_Agent_Model{model = s(c.model, allocator)}
	case Open_File:           return Open_File{path = s(c.path, allocator), line = c.line, col = c.col, session = c.session, preview = c.preview}
	case New_Shell_Tab:       return New_Shell_Tab{session = c.session, cwd = s(c.cwd, allocator)}
	case Files_Expand:        return Files_Expand{path = s(c.path, allocator), expanded = c.expanded}
	case Files_Collapse_All:  return Files_Collapse_All{root = s(c.root, allocator)}
	case Files_Reveal:        return Files_Reveal{path = s(c.path, allocator)}
	case Set_Files_Filter:    return Set_Files_Filter{text = s(c.text, allocator)}
	case Reload_File:         return Reload_File{tab_id = c.tab_id, confirm = s(c.confirm, allocator)}
	case List_Dir:            return List_Dir{path = s(c.path, allocator), ignored = c.ignored}
	case Create_File:         return Create_File{path = s(c.path, allocator), confirm = s(c.confirm, allocator)}
	case Create_Dir:          return Create_Dir{path = s(c.path, allocator), confirm = s(c.confirm, allocator)}
	case Rename_Path:         return Rename_Path{from = s(c.from, allocator), to = s(c.to, allocator), confirm = s(c.confirm, allocator)}
	case Delete_Path:         return Delete_Path{path = s(c.path, allocator), confirm = s(c.confirm, allocator)}
	case Reveal_In_Finder:    return Reveal_In_Finder{path = s(c.path, allocator)}
	case Git_Head_Done:       return Git_Head_Done{tab_id = c.tab_id, gen = c.gen, path = s(c.path, allocator), in_repo = c.in_repo, tracked = c.tracked, head = s(c.head, allocator)}
	case Git_Status_Done:     return Git_Status_Done{root = s(c.root, allocator), gen = c.gen, ok = c.ok, out = s(c.out, allocator)}
	case File_List_Done:      return File_List_Done{root = s(c.root, allocator), out = s(c.out, allocator)}
	case List_Worktrees:      return List_Worktrees{path = s(c.path, allocator)}
	case Files_Set_Root:      return Files_Set_Root{base = s(c.base, allocator), path = s(c.path, allocator)}
	case Worktree_Cleanup:    return Worktree_Cleanup{path = s(c.path, allocator), confirm = s(c.confirm, allocator)}
	case Worktree_Session:    return Worktree_Session{project_id = c.project_id, path = s(c.path, allocator)}
	case Worktrees_Done:      return Worktrees_Done{common = s(c.common, allocator), gen = c.gen, out = s(c.out, allocator)}
	case Worktree_Cleanup_Done:
		return Worktree_Cleanup_Done{path = s(c.path, allocator), main = s(c.main, allocator), request_id = c.request_id, remove = c.remove, removed = c.removed, branch = s(c.branch, allocator), ignored = s(c.ignored, allocator), err = s(c.err, allocator)}
	case Job_Runs:            return Job_Runs{job = s(c.job, allocator), limit = c.limit}
	case Job_Run_Now:         return Job_Run_Now{job = s(c.job, allocator)}
	case Job_Stop:            return Job_Stop{job = s(c.job, allocator)}
	case Jobs_Pause:          return Jobs_Pause{job = s(c.job, allocator)}
	case Jobs_Resume:         return Jobs_Resume{job = s(c.job, allocator)}
	case Job_Save:            return Job_Save{path = s(c.path, allocator), text = s(c.text, allocator), based_on = s(c.based_on, allocator)}
	case Job_Sheet:           return Job_Sheet{open = c.open, job = s(c.job, allocator), for_project = s(c.for_project, allocator)}
	case Job_Create:          return Job_Create{name = s(c.name, allocator), schedule = s(c.schedule, allocator), prompt = s(c.prompt, allocator), folder = s(c.folder, allocator), for_project = s(c.for_project, allocator)}
	case Job_Mark_Read:       return Job_Mark_Read{job = s(c.job, allocator), run = s(c.run, allocator)}
	case Job_Set_Enabled:     return Job_Set_Enabled{job = s(c.job, allocator), on = c.on}
	case Job_Delete:          return Job_Delete{job = s(c.job, allocator), confirm = s(c.confirm, allocator)}
	case Job_Open:            return Job_Open{job = s(c.job, allocator), what = s(c.what, allocator)}
	case Set_Pi_Path:         return Set_Pi_Path{path = s(c.path, allocator)}
	case Jobs_Env:            return Jobs_Env{path = s(c.path, allocator), notes = s(c.notes, allocator), login = c.login}
	case Job_List, Set_Job_Limits, Jobs_Sync, Jobs_Tick, Job_Run_Done:
		return cmd
	case Editor_State, Save_File, Goto_Line, Keep_Buffer, Diff_File, Set_Wrap, Keep_Tab, Set_Left_Tab:
		return cmd
	case Set_Terminal_Text_Size:
		return cmd
	case Notify_Post:
		j := c.job
		return Notify_Post{job = {job_id = s(j.job_id, allocator), title = s(j.title, allocator), status = j.status, summary = s(j.summary, allocator), run_dir = s(j.run_dir, allocator)}}
	case Notifications_List, Notifications_Mark_Read, Notifications_Clear, Set_Bell:
		return cmd
	case Update_Check, Update_Skip, Update_Later, Update_Download, Update_Install, Set_Update_Check, Update_Env, Update_Tick, Update_Checked, Update_Prepared:
		return update_clone(cmd, allocator)
	case Changes_Open, Changes_List, Changes_Stage, Changes_Unstage, Changes_Discard, Changes_Commit, Changes_Scan_Done, Changes_Diff_Done, Changes_Op_Done:
		return changes_command_clone(cmd, allocator)
	case Markdown_Open, Markdown_Set_View, Markdown_Scroll, Markdown_Follow:
		return md_command_clone(cmd, allocator)
	case Show_File:
		return Show_File{path = strings.clone(c.path, allocator), line = c.line, anchor = strings.clone(c.anchor, allocator), session = c.session}
	case New_App_Tab, App_Restart, App_Close, App_Declared, App_Input, App_Events, App_Call, App_Call_Done, App_Update, App_Screenshot, App_Inspect:
		return app_command_clone(cmd, allocator)
	case Pi_Reload_All, Pi_Restart_Updated, Pi_Reload_Later, Reload_Watch, Reload_Kick:
		return reload_clone(cmd, allocator)
	case Claude_Restart_Changed, Claude_Reload_Later, Claude_Reload_Watch, Claude_Reload_Kick:
		return claude_reload_clone(cmd, allocator)
	case Comment_Add:         return Comment_Add{source = c.source, tab_id = c.tab_id, what = s(c.what, allocator), text = s(c.text, allocator), crop = s(c.crop, allocator)}
	case Comment_Edit:        return Comment_Edit{comment_id = c.comment_id, text = s(c.text, allocator)}
	case New_Claude_Tab, New_Claude_Session, Claude_Rename, Claude_Resume, Claude_Session_Report, Claude_Turn_Report, Claude_Comments, Claude_Attached, Claude_Prompt, Claude_Held_Op, Claude_Deliver, Claude_Restore_History, Claude_Readonly_Ack:
		return claude_command_clone(cmd, allocator)
	case Add_Claude_Account, Rename_Claude_Account, Remove_Claude_Account, Set_Claude_Account_Default:
		return claude_account_clone(cmd, allocator)
	case Claude_Restart, Claude_Todos, Claude_Task, Claude_Subagent, Claude_Background:
		return claude_extra_clone(cmd, allocator)
	case Claude_Model_Report: return Claude_Model_Report{tab_id = c.tab_id, model = s(c.model, allocator)}
	case Claude_Wait_Idle, Claude_Wait_Tick:
		return cmd
	case Comment_Delete, Comments_Clear, Comments_Send_Now, Comments_Ask_Cancel, Pi_Attached:
		return cmd
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update:
		return browser_command_clone(cmd, allocator)
	case Browser_Zoom, Browser_Find, Browser_Find_Close, Browser_Dialog, Browser_Permission, Browser_Popup, Browser_Edit, Browser_Devtools, Browser_External, Browser_Download:
		return browser_polish_command_clone(cmd, allocator)
	case Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop:
		return browser_agent_clone(cmd, allocator)
	case Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel:
		return browser_act_clone(cmd, allocator)
	case Setup_Sheet, Set_Chats_Readonly, Set_Sort, Set_Sidebar_Folded, Select_Project, New_Chat, Focus_Session, Focus_Tab, Split_Pane, Close_Pane, Focus_Pane, Move_Tab, Set_Split, Equalize_Panes, Copy_Selection, Set_Layout, Rescan, Refresh_Shell_Env, Refresh_Shell_Env_Done, Get_State, List_Commands, Set_Home, Agent_Model_Picker, Set_Notify, Set_Tidy_Projects, Set_Keep_Sessions, Copy_Control_Token, Set_Confirm_Policy, Set_Close_Confirm, Set_Theme, Set_Reduce_Motion, Set_Appearance, Set_Text_Size, System_Appearance, Tab_Exited, Rescan_Done, Pi_Wait_Idle, Pi_Restart:
		return cmd
	}
	return cmd
}

command_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	#partial switch c in cmd {
	case Add_Project:         delete(c.cwd, allocator)
	case Rename_Project:      delete(c.name, allocator)
	case Open_Session_Cmd:    delete(c.pi_session_id, allocator)
	case Close_Tab:           delete(c.confirm, allocator)
	case Close_Session:       delete(c.confirm, allocator)
	case Send_Text:           delete(c.text, allocator)
	case Terminal_Link:       delete(c.url, allocator)
	case Set_Focus:           delete(c.widget, allocator)
	case Focus_Take:          delete(c.widget, allocator)
	case Focus_Release:       delete(c.widget, allocator)
	case Set_Panel:           delete(c.panel, allocator)
	case Cancel_Confirmation: delete(c.token, allocator)
	case Quit:                delete(c.confirm, allocator)
	case Set_Claude_Default_Flags: delete(c.confirm, allocator)
	case Set_Pi_Extension:    delete(c.name, allocator)
	case Pi_Session_Update:
		delete(c.pi_session_id, allocator)
		delete(c.session_file, allocator)
		delete(c.cwd, allocator)
	case Pi_Status_Update:
		for x in c.blockers do delete(x, allocator)
		delete(c.blockers, allocator)
	case Pi_Prompt:
		delete(c.text, allocator)
		for im in c.images {
			delete(im.mime, allocator)
			delete(im.data, allocator)
		}
		delete(c.images, allocator)
	case Comment_Add:
		delete(c.what, allocator)
		delete(c.text, allocator)
		delete(c.crop, allocator)
	case Comment_Edit:        delete(c.text, allocator)
	case New_Claude_Tab, New_Claude_Session, Claude_Rename, Claude_Resume, Claude_Session_Report, Claude_Turn_Report, Claude_Comments, Claude_Attached, Claude_Prompt, Claude_Held_Op, Claude_Deliver, Claude_Restore_History, Claude_Readonly_Ack:
		claude_command_free(cmd, allocator)
	case Add_Claude_Account, Rename_Claude_Account, Remove_Claude_Account, Set_Claude_Account_Default:
		claude_account_free(cmd, allocator)
	case Claude_Restart, Claude_Todos, Claude_Task, Claude_Subagent, Claude_Background:
		claude_extra_free(cmd, allocator)
	case Claude_Model_Report: delete(c.model, allocator)
	case Claude_Wait_Idle, Claude_Wait_Tick:
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update:
		browser_command_free(cmd, allocator)
	case Browser_Zoom, Browser_Find, Browser_Find_Close, Browser_Dialog, Browser_Permission, Browser_Popup, Browser_Edit, Browser_Devtools, Browser_External, Browser_Download:
		browser_polish_command_free(cmd, allocator)
	case Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop:
		browser_agent_free(cmd, allocator)
	case Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel:
		browser_act_free(cmd, allocator)
	case Update_Install, Update_Env, Update_Checked, Update_Prepared:
		update_free(cmd, allocator)
	case Notify_Post:
		delete(c.job.job_id, allocator)
		delete(c.job.title, allocator)
		delete(c.job.summary, allocator)
		delete(c.job.run_dir, allocator)
	case Set_Agent_Name:      delete(c.name, allocator)
	case Set_Agent_Model:     delete(c.model, allocator)
	case Pi_Reload:           delete(c.confirm, allocator)
	case Pi_Reload_All, Pi_Restart_Updated, Reload_Watch: reload_free(cmd, allocator)
	case Claude_Restart_Changed, Claude_Reload_Watch: claude_reload_free(cmd, allocator)
	case Bridge_Done:         delete(c.error, allocator)
	case Panel_Set:
		delete(c.panel, allocator)
		delete(c.title, allocator)
		for r in c.rows do delete(r.text, allocator)
		delete(c.rows, allocator)
	case Panel_Remove:        delete(c.panel, allocator)
	case Set_Home_Dir:        delete(c.path, allocator)
	case Set_Folder:          delete(c.path, allocator)
	case Set_Pinned:
		delete(c.cwd, allocator)
		delete(c.pi_session_id, allocator)
	case Set_Hidden:
		delete(c.cwd, allocator)
		delete(c.pi_session_id, allocator)
	case Reveal_Path:         delete(c.pi_session_id, allocator)
	case Copy_Path:           delete(c.pi_session_id, allocator)
	case Session_Info:
		delete(c.pi_session_id, allocator)
		delete(c.to, allocator)
	case Set_Filter:          if t, ok := c.text.?; ok do delete(t, allocator)
	case Set_Row_Expanded:    delete(c.path, allocator)
	case Set_Unread:          delete(c.pi_session_id, allocator)
	case Restore_Sidebar:
		for l in ([4][]string{c.pinned_projects, c.pinned_sessions, c.hidden_projects, c.hidden_sessions}) {
			for x in l do delete(x, allocator)
			delete(l, allocator)
		}
	case Set_Panel_Collapsed: delete(c.panel, allocator)
	case Open_File:           delete(c.path, allocator)
	case New_Shell_Tab:       delete(c.cwd, allocator)
	case Files_Expand:        delete(c.path, allocator)
	case Files_Collapse_All:  delete(c.root, allocator)
	case Files_Reveal:        delete(c.path, allocator)
	case Set_Files_Filter:    delete(c.text, allocator)
	case Reload_File:         delete(c.confirm, allocator)
	case List_Dir:            delete(c.path, allocator)
	case Create_File:
		delete(c.path, allocator)
		delete(c.confirm, allocator)
	case Create_Dir:
		delete(c.path, allocator)
		delete(c.confirm, allocator)
	case Rename_Path:
		delete(c.from, allocator)
		delete(c.to, allocator)
		delete(c.confirm, allocator)
	case Delete_Path:
		delete(c.path, allocator)
		delete(c.confirm, allocator)
	case Reveal_In_Finder:    delete(c.path, allocator)
	case Git_Head_Done:
		delete(c.path, allocator)
		delete(c.head, allocator)
	case Git_Status_Done:
		delete(c.root, allocator)
		delete(c.out, allocator)
	case File_List_Done:
		delete(c.root, allocator)
		delete(c.out, allocator)
	case List_Worktrees:      delete(c.path, allocator)
	case Files_Set_Root:
		delete(c.base, allocator)
		delete(c.path, allocator)
	case Worktree_Cleanup:
		delete(c.path, allocator)
		delete(c.confirm, allocator)
	case Worktree_Session:    delete(c.path, allocator)
	case Worktrees_Done:
		delete(c.common, allocator)
		delete(c.out, allocator)
	case Worktree_Cleanup_Done:
		delete(c.path, allocator)
		delete(c.main, allocator)
		delete(c.branch, allocator)
		delete(c.ignored, allocator)
		delete(c.err, allocator)
	case Job_Runs:            delete(c.job, allocator)
	case Job_Run_Now:         delete(c.job, allocator)
	case Job_Stop:            delete(c.job, allocator)
	case Jobs_Pause:          delete(c.job, allocator)
	case Jobs_Resume:         delete(c.job, allocator)
	case Job_Save:
		delete(c.path, allocator)
		delete(c.text, allocator)
		delete(c.based_on, allocator)
	case Job_Sheet:
		delete(c.job, allocator)
		delete(c.for_project, allocator)
	case Job_Create:
		delete(c.name, allocator)
		delete(c.schedule, allocator)
		delete(c.prompt, allocator)
		delete(c.folder, allocator)
		delete(c.for_project, allocator)
	case Job_Mark_Read:
		delete(c.job, allocator)
		delete(c.run, allocator)
	case Job_Set_Enabled:     delete(c.job, allocator)
	case Job_Delete:
		delete(c.job, allocator)
		delete(c.confirm, allocator)
	case Job_Open:
		delete(c.job, allocator)
		delete(c.what, allocator)
	case Set_Pi_Path:         delete(c.path, allocator)
	case Jobs_Env:
		delete(c.path, allocator)
		delete(c.notes, allocator)
	case Changes_Open, Changes_List, Changes_Stage, Changes_Unstage, Changes_Discard, Changes_Commit, Changes_Scan_Done, Changes_Diff_Done, Changes_Op_Done:
		changes_command_free(cmd, allocator)
	case Markdown_Open, Markdown_Set_View, Markdown_Scroll, Markdown_Follow:
		md_command_free(cmd, allocator)
	case Show_File:
		delete(c.path, allocator)
		delete(c.anchor, allocator)
	case New_App_Tab, App_Restart, App_Close, App_Declared, App_Input, App_Events, App_Call, App_Call_Done, App_Update, App_Screenshot, App_Inspect:
		app_command_free(cmd, allocator)
	case Restore_Session:
		delete(c.pi_session_id, allocator)
		delete(c.session_dir, allocator)
		for t in c.tabs {
			delete(t.claude_id, allocator)
			for x in t.args do delete(x, allocator)
			delete(t.args, allocator)
			delete(t.title, allocator)
			delete(t.cwd, allocator)
		}
		delete(c.layout.nodes, allocator)
		delete(c.tabs, allocator)
	}
}

// What a menu row's command did, where nothing else on screen shows it: a
// failure always (else a click seems to do nothing), a copy when it worked.
// Not a command that finishes later or asks first (the confirmation bar).
menu_result :: proc(label: string, cmd: Command, r: Result) {
	if r.pending || r.error == "needs_confirmation" do return
	if r.error == CLAUDE_MISSING do return // the command said how to install it already (claude.odin)
	if !r.ok {
		why := r.error != "" ? r.error : "it did not work"
		window_toast(fmt.tprintf("%s: %s", strings.trim_suffix(label, "…"), why), err = true)
		return
	}
	#partial switch c in cmd {
	case Session_Info: if c.to == "clipboard" do window_toast("Session info copied")
	case Copy_Path:    window_toast("Path copied")
	}
}
