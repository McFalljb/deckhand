package core

// From src/browser_act.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Act_Target :: struct {
	selector: string, // a simple selector or ref=eN (agent_selector_ok)
	x, y:     f32, // or a point: the page's CSS px from the viewport's top-left
	has_xy:   bool,
}

Act_Button :: enum u8 {
	Left,
	Right,
	Middle,
}

Browser_Click :: struct {
	tab_id:    u64,
	target:    Act_Target,
	button:    Act_Button,
	double:    bool,
	modifiers: int, // ACT_MOD_*
}

Browser_Type :: struct {
	tab_id:   u64,
	selector: string, // "" = the focused element
	text:     string,
	clear:    bool, // select the field's content and delete it first
	submit:   bool, // press Enter after
}

Browser_Press :: struct {
	tab_id:   u64,
	selector: string, // focus it first ("" = where focus is)
	keys:     string, // chords, space separated: "Shift+Tab Enter"
}

Browser_Scroll :: struct {
	tab_id: u64,
	target: Act_Target, // none: the page at its centre
	dx, dy: f32, // CSS px; none: the target into view
}

Browser_Select :: struct {
	tab_id:    u64,
	selector:  string,
	label:     string,
	value:     string,
	has_label: bool,
	has_value: bool,
}

Browser_Hover :: struct {
	tab_id: u64,
	target: Act_Target,
}

Browser_Upload :: struct {
	tab_id:   u64,
	selector: string,
	paths:    []string,
}

Browser_Upload_Answer :: struct {
	tab_id: u64,
	allow:  bool,
}

// A requester's cancel (socket.odin: its cancel line, or its connection closing): Deckhand's own.
Request_Cancel :: struct {
	request_id: u64,
	closed:     bool, // the connection closed
}

Browser_Agent_Take_Over :: struct {
	tab_id: u64,
	on:     bool, // false: Hand back
}
