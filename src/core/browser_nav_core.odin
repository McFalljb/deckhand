package core

// From src/browser_nav.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Browser_Open :: struct {
	session: u64, // 0: the caller's own (see above)
	url:     string, // "" (the user only): a blank tab with the keyboard in its URL field
}

Browser_Navigate :: struct {
	tab_id: u64,
	url:    string, // as typed: normalised (browser_url_normalize)
}

Browser_Back :: struct {tab_id: u64}

Browser_Forward :: struct {tab_id: u64}

Browser_Reload :: struct {tab_id: u64}

Browser_Stop :: struct {tab_id: u64}

Browser_Field :: enum {
	Url,
	Title,
	Nav, // loading, can_back, can_forward
	Blocked, // a popup without a user gesture was refused
}

// What CEF reported for a tab (internal). An empty `what` only says the tab
// changed (a popup's tab was made).
Browser_Update :: struct {
	tab_id:      u64,
	what:        bit_set[Browser_Field],
	url, title:  string,
	loading:     bool,
	can_back:    bool,
	can_forward: bool,
	blocked:     string, // the refused popup's URL
}

BROWSER_BLANK :: "about:blank"
