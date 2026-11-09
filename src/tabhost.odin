package main

// In-process side of the Deckhand tab protocol (docs/TAB-PROTOCOL.md): what
// the window layer needs from any tab kind. A sketch: terminal tabs fill in
// the parts they have; texture display, capture and the control channel are
// stubs (the Markdown tab is drawn by Deckhand too).

import "core"
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
	draw = proc(tab_id: u64, x, y, w, h: f32) {if t := core.term_of(tab_id); t != nil do term_draw(t)},
}

tab_view :: proc(kind: core.Tab_Kind) -> ^Tab_View {
	switch _ in kind {
	case core.Pi_Tab, core.Shell_Tab, core.Claude_Tab:
		return &terminal_host
	case core.Editor_Tab:
		return &editor_host // editor_view.odin
	case core.Changes_Tab:
		return &changes_host // ui_changes.odin
	case core.Markdown_Tab:
		return &markdown_host // markdown_view.odin
	case core.Browser_Tab:
		return &browser_host // browser.odin
	case core.App_Tab:
		return &app_host // app_tab.odin
	}
	return nil
}

// The window's part of a routed command (a tab_host.call, tabhost_link.odin): the browser, app,
// Markdown and editor commands and a terminal's links. The core checked the caller and the records
// first and changes the records from the answer (src/core/tabhost_route.odin). tab_id: the tab
// the call makes (browser_open, a popup's, terminal_link's, new_app_tab), else 0.
tab_host_apply_app :: proc(cmd: core.Command, caller: core.Caller, request_id: u64, tab_id: u64 = 0) -> (core.Result, bool) {
	#partial switch _ in cmd {
	case core.Open_File, core.Editor_State, core.Save_File, core.Goto_Line, core.Reload_File, core.Keep_Buffer, core.Diff_File, core.Set_Wrap, core.Git_Head_Done:
		return editor_apply(cmd, caller)
	case core.Markdown_Open, core.Markdown_Set_View, core.Markdown_Scroll, core.Markdown_Follow:
		return markdown_apply(cmd, caller)
	case core.Terminal_Link:
		return term_link_apply(cmd.(core.Terminal_Link), caller, tab_id) // a browser tab (term_links.odin)
	case core.New_App_Tab, core.App_Restart, core.App_Input, core.App_Call, core.App_Call_Done, core.App_Screenshot, core.App_Inspect:
		return app_apply(cmd, caller, request_id, tab_id)
	case core.Browser_Open, core.Browser_Navigate, core.Browser_Back, core.Browser_Forward, core.Browser_Reload, core.Browser_Stop:
		if r, refused := browser_agent_nav_refused(cmd, caller); refused do return r, false // Take over (browser_agent.odin)
		r, ch := browser_nav_apply(cmd, caller, tab_id)
		browser_agent_nav_ran(cmd, caller, r) // the agent strip; a load wait's navigation (browser_agent.odin)
		return r, ch
	case core.Browser_Zoom, core.Browser_Find, core.Browser_Find_Close, core.Browser_Dialog, core.Browser_Permission, core.Browser_Popup, core.Browser_Edit, core.Browser_Devtools, core.Browser_External, core.Browser_Download:
		return browser_polish_apply(cmd, caller, tab_id)
	case core.Browser_Tabs, core.Browser_Read, core.Browser_Screenshot, core.Browser_Page_Wait, core.Browser_Console, core.Browser_Network, core.Browser_Comments, core.Browser_Agent_Stop:
		return browser_agent_apply(cmd, caller, request_id)
	case core.Browser_Click, core.Browser_Type, core.Browser_Press, core.Browser_Scroll, core.Browser_Select, core.Browser_Hover, core.Browser_Upload, core.Browser_Upload_Answer, core.Browser_Agent_Take_Over, core.Request_Cancel:
		return browser_act_apply(cmd, caller, request_id)
	}
	return core.fail("not a tab host command"), false
}
