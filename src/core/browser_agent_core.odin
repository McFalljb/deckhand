package core

// From src/browser_agent.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Browser_Tabs :: struct {
	session: u64 `cmd:"omit"`, // 0: a pi tab's own; for others every session's
}

Browser_Read :: struct {
	tab_id:   u64,
	mode:     string `cmd:"omit"`, // text (default) | outline | html
	selector: string `cmd:"omit"`, // a CSS selector or ref=eN (an outline's); "" = the whole page
	max:      int `cmd:"omit,signed,max=1073741824"`, // characters (0 = AGENT_READ_MAX)
}

Browser_Screenshot :: struct {
	tab_id:   u64,
	rect:     App_Rect `cmd:"codec=rect"`, // the page's CSS px from its top-left (the viewport)
	has_rect: bool `cmd:"log=-,noparse"`,
}

Browser_Page_Wait :: struct {
	tab_id:     u64,
	what:       string `cmd:"key=for,omit,req"`, // load | selector | text (the wire's "for")
	value:      string `cmd:"omit,codec=wait_value"`, // the selector or the text
	timeout_ms: int `cmd:"omit,signed,max=600000"`,
}

Browser_Console :: struct {
	tab_id: u64,
	since:  u64 `cmd:"omit"`,
	limit:  int `cmd:"log=-,full,omit,pos,max=1000"`,
}

Browser_Network :: struct {
	tab_id: u64,
	since:  u64 `cmd:"omit"`,
	limit:  int `cmd:"log=-,full,omit,pos,max=1000"`,
}

Browser_Comments :: struct {
	tab_id:  u64 `cmd:"omit"`, // 0: the session's
	session: u64 `cmd:"omit"`,
}

Browser_Agent_Stop :: struct {
	tab_id: u64,
}
