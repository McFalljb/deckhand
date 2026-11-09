package core

// From src/browser.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Browser_Tab :: struct {
	url:           string, // the page's address now; what it opens with (owned; browser_nav.odin)
	loading:       bool,
	can_back:      bool,
	can_forward:   bool,
	blocked_popup: string, // the last popup refused for want of a user gesture ("" = none)
}
