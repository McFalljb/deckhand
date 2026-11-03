package main

// In-process side of the pi-desk tab protocol (docs/TAB-PROTOCOL.md): what
// the window layer needs from any tab kind. A sketch: terminal tabs fill in
// the parts they have; texture display, capture and the control channel are
// stubs (the Markdown tab is drawn by pi-desk too).

import sapp "../vendor/sokol-odin/sokol/app"

Tab_Display :: enum {
	Drawn, // pi-desk draws it itself (terminal, markdown)
	Texture, // the program renders into a shared GPU texture pi-desk draws as an image
	Native_View, // a native child view over the window; no pi-desk overlays on top
	Own_Window, // the program keeps its own window; the tab only controls it
}

Tab_Host :: struct {
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
terminal_host := Tab_Host {
	display = .Drawn,
	draw = proc(tab_id: u64, x, y, w, h: f32) {if t := term_of(tab_id); t != nil do term_draw(t)},
}

tab_host :: proc(kind: Tab_Kind) -> ^Tab_Host {
	switch _ in kind {
	case Pi_Tab, Shell_Tab:
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
