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
	target:    Act_Target `cmd:"codec=act_target"`,
	button:    Act_Button `cmd:"omit,names=act_button,codec=enum_of"`,
	double:    bool `cmd:"omit"`,
	modifiers: int `cmd:"omit,codec=mods"`, // ACT_MOD_*
}

Browser_Type :: struct {
	tab_id:   u64,
	selector: string `cmd:"omit"`, // "" = the focused element
	text:     string `cmd:"opt,red=len:text_bytes"`,
	clear:    bool `cmd:"omit"`, // select the field's content and delete it first
	submit:   bool `cmd:"omit"`, // press Enter after
}

Browser_Press :: struct {
	tab_id:   u64,
	selector: string `cmd:"omit"`, // focus it first ("" = where focus is)
	keys:     string, // chords, space separated: "Shift+Tab Enter"
}

Browser_Scroll :: struct {
	tab_id: u64,
	target: Act_Target `cmd:"codec=act_target"`, // none: the page at its centre
	dx: f32 `cmd:"omit"`, // CSS px; none: the target into view
	dy: f32 `cmd:"omit"`, // CSS px; none: the target into view
}

Browser_Select :: struct {
	tab_id:    u64,
	selector:  string `cmd:"omit"`,
	label:     string `cmd:"codec=has"`,
	value:     string `cmd:"codec=has"`,
	has_label: bool `cmd:"log=-,noparse"`,
	has_value: bool `cmd:"log=-,noparse"`,
}

Browser_Hover :: struct {
	tab_id: u64,
	target: Act_Target `cmd:"codec=act_target"`,
}

Browser_Upload :: struct {
	tab_id:   u64,
	selector: string `cmd:"omit"`,
	paths:    []string `cmd:"red=len:files"`,
}

Browser_Upload_Answer :: struct {
	tab_id: u64,
	allow:  bool,
}

// A requester's cancel (socket.odin: its cancel line, or its connection closing): Deckhand's own.
Request_Cancel :: struct {
	request_id: u64,
	closed:     bool `cmd:"-"`, // the connection closed
}

Browser_Agent_Take_Over :: struct {
	tab_id: u64,
	on:     bool, // false: Hand back
}
