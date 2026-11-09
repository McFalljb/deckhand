package core

// From src/browser_agent.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Browser_Tabs :: struct {
	session: u64, // 0: a pi tab's own; for others every session's
}

Browser_Read :: struct {
	tab_id:   u64,
	mode:     string, // text (default) | outline | html
	selector: string, // a CSS selector or ref=eN (an outline's); "" = the whole page
	max:      int, // characters (0 = AGENT_READ_MAX)
}

Browser_Screenshot :: struct {
	tab_id:   u64,
	rect:     App_Rect, // the page's CSS px from its top-left (the viewport)
	has_rect: bool,
}

Browser_Page_Wait :: struct {
	tab_id:     u64,
	what:       string, // load | selector | text (the wire's "for")
	value:      string, // the selector or the text
	timeout_ms: int,
}

Browser_Console :: struct {
	tab_id: u64,
	since:  u64,
	limit:  int,
}

Browser_Network :: struct {
	tab_id: u64,
	since:  u64,
	limit:  int,
}

Browser_Comments :: struct {
	tab_id:  u64, // 0: the session's
	session: u64,
}

Browser_Agent_Stop :: struct {
	tab_id: u64,
}
