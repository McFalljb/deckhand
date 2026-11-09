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

// A page's popup (target=_blank, window.open, ⌘-click) with a user gesture, as the window reports
// it (the tab_host caller; browser.odin's on_cef_popup): a new tab in the opener's session, never
// another. created_id: the tab, whose page CEF opens in the slot it reserved.
Browser_Popup_Open :: struct {
	opener:     u64, // the page's tab
	url:        string, // as the page asked (State gets it without user:pass@)
	background: bool, // behind the view (⌘-click, or an agent acting on the opener)
	pane:       u64, // the pane it goes into (an agent's: its own tab's); 0 = the focused one
}

BROWSER_BLANK :: "about:blank"
