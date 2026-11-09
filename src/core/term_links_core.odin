package core

// From src/term_links.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Terminal_Link :: struct {
	tab_id:   u64, // a pi or shell tab (Home's Atlas too)
	url:      string,
	external: bool, // the default browser even for http(s) (⇧⌘-click)
}

// A link on the grid: its URL and its first and last cells (viewport col,
// row; in reading order, the rows between are whole).
Term_Link :: struct {
	url:  string,
	a, b: [2]int,
	osc8: bool, // an OSC 8 hyperlink (its text may differ from its target)
}

// What a hover lookup depended on: looked up again only when it changes.
Link_Key :: struct {
	at:     [2]f32,
	pane:   [2]f32, // the pane's x, y (a moved pane under a still pointer)
	bytes:  int, // the terminal's output so far
	offset: u64, // its scroll position
	cols, rows: u16,
	cmd:    bool,
}
