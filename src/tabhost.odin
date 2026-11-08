package main

// In-process side of the Deckhand tab protocol (docs/TAB-PROTOCOL.md): what
// the window layer needs from any tab kind. A sketch: terminal tabs fill in
// the parts they have; texture display, capture and the control channel are
// stubs (the Markdown tab is drawn by Deckhand too).

import sapp "../vendor/sokol-odin/sokol/app"

Tab_Display :: enum {
	Drawn, // Deckhand draws it itself (terminal, markdown)
	Texture, // the program renders into a shared GPU texture Deckhand draws as an image
	Native_View, // a native child view over the window; no Deckhand overlays on top
	Own_Window, // the program keeps its own window; the tab only controls it
}

Tab_View :: struct {
	display: Tab_Display,
	// Drawn: draw into the pane rect (framebuffer px), inside draw_begin/draw_end.
	draw:    proc(tab_id: u64, x, y, w, h: f32),
	// Texture: the sg.Image id to draw this frame (0 = nothing yet).
	texture: proc(tab_id: u64) -> u32,
	// Keyboard/mouse for the focused tab (already routed by focus).
	input:   proc(tab_id: u64, e: ^sapp.Event),
	// RGBA pixels of a region in tab coordinates (annotations, screenshots).
	capture: proc(tab_id: u64, x, y, w, h: int) -> (pixels: []u8, ok: bool),
	// Control channel: one NDJSON request in, one reply out (PROTOCOL.md envelope).
	control: proc(tab_id: u64, request: string) -> string,
}

// Terminal tabs (pi and shell): libghostty-vt in process, drawn by us.
terminal_host := Tab_View {
	display = .Drawn,
	draw = proc(tab_id: u64, x, y, w, h: f32) {if t := term_of(tab_id); t != nil do term_draw(t)},
}

tab_view :: proc(kind: Tab_Kind) -> ^Tab_View {
	switch _ in kind {
	case Pi_Tab, Shell_Tab, Claude_Tab:
		return &terminal_host
	case Editor_Tab:
		return &editor_host // editor_view.odin
	case Changes_Tab:
		return &changes_host // ui_changes.odin
	case Markdown_Tab:
		return &markdown_host // markdown_view.odin
	case Browser_Tab:
		return &browser_host // browser.odin
	case App_Tab:
		return &app_host // app_tab.odin
	}
	return nil
}

// The window's side of tab host routing (window_hooks.odin): the browser, app, Markdown and
// editor commands, as commands.odin's apply sent them before.
tab_host_apply_app :: proc(cmd: Command, caller: Caller, request_id: u64) -> (Result, bool) {
	#partial switch _ in cmd {
	case Open_File, Editor_State, Save_File, Goto_Line, Reload_File, Keep_Buffer, Diff_File, Set_Wrap, List_Dir, Create_File, Create_Dir, Rename_Path, Delete_Path, Reveal_In_Finder, Keep_Tab, Git_Head_Done, Git_Status_Done, File_List_Done:
		return editor_apply(cmd, caller)
	case Markdown_Open, Markdown_Set_View, Markdown_Scroll, Markdown_Follow:
		return markdown_apply(cmd, caller)
	case New_App_Tab, App_Restart, App_Close, App_Declared, App_Input, App_Events, App_Call, App_Call_Done, App_Update, App_Screenshot, App_Inspect:
		return app_apply(cmd, caller, request_id)
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
	}
	return fail("not a tab host command"), false
}
