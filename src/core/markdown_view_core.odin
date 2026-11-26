package core

// From src/markdown_view.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Markdown_Tab :: struct {
	path:   string, // absolute (owned)
	source: bool, // the source (the editor) instead of the preview
}

// Commands (rows in command_table.odin).
Markdown_Open :: struct {
	path:    string, // absolute, or relative to the session's folder
	session: u64 `cmd:"omit"`, // 0 = the caller's, else the one on screen
	anchor:  string `cmd:"omit"`, // a heading id to scroll to ("" = the top)
}

Markdown_Set_View :: struct {
	tab_id: u64,
	source: bool `cmd:"opt"`,
}

Markdown_Scroll :: struct {
	tab_id: u64,
	anchor: string `cmd:"omit"`, // a heading id, or
	line:   int `cmd:"omit,nonneg"`, // a source line (1-based)
}

// Follows a link of the document, as a click on it does.
Markdown_Follow :: struct {
	tab_id:  u64,
	url:     string,
	confirm: string `cmd:"omit"`, // a web or mail link from a caller other than the user: the user confirms
}
