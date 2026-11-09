package core

// From src/browser_polish.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Browser_Zoom_Step :: enum u8 {
	Reset,
	In,
	Out,
}

Browser_Edit_Op :: enum u8 {
	Undo,
	Redo,
	Cut,
	Copy,
	Paste,
	Select_All,
}

Browser_Download_Op :: enum u8 {
	Open,
	Reveal,
	Cancel,
	Dismiss,
	Allow, // a download the page started without the user's click: go ahead (download_ask)
	Block, // … or not
}

Browser_Zoom :: struct {
	tab_id: u64,
	step:   Browser_Zoom_Step,
}

Browser_Find :: struct {
	tab_id: u64,
	text:   string, // "" clears the matches (the bar stays)
	back:   bool, // the previous match
}

Browser_Find_Close :: struct {
	tab_id: u64,
}

Browser_Dialog :: struct {
	tab_id: u64,
	ok:     bool,
	text:   string, // a prompt's answer
}

Browser_Permission :: struct {
	tab_id: u64,
	allow:  bool,
}

Browser_Popup :: struct {
	tab_id: u64,
	open:   bool, // false: only the bar goes
}

Browser_Edit :: struct {
	tab_id: u64,
	op:     Browser_Edit_Op,
}

Browser_Devtools :: struct {
	tab_id: u64,
	x, y:   i32, // inspect the element at this page position (logical px); -1: just open
	close:  bool,
}

Browser_External :: struct {
	tab_id: u64,
}

Browser_Download :: struct {
	download_id: u64,
	op:          Browser_Download_Op,
}
