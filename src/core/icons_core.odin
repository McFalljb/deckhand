package core

// From src/icons.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Icon :: enum u8 {
	None,
	Search, // magnifier
	Compose, // square and pencil: new chat
	Plus,
	Chevron_Down,
	Sidebar_Left, // a window with its left column (filled while shown)
	Sidebar_Left_On,
	Sidebar_Right,
	Sidebar_Right_On,
	Sliders, // settings
	Close,
	More, // three dots
	Check,
	// the Files tab's header (ui_files.odin)
	New_File, // a page and a plus
	New_Folder, // a folder and a plus
	Collapse_All, // a box with a minus
	Refresh, // a circular arrow
	Reveal, // a folder with an arrow out of it
	// the left column: what a row is (ui_sidebar.odin), the tree and sort controls
	Folder, // a project (and its sessions)
	Chat, // a speech bubble: a chat, outside any project
	Chevron_Right, // a folded tree row or section
	Sort, // two arrows, up and down
	Branch, // a git branch: two commits on a line, a third off it (the Files tab's checkout switcher)
	// the bell (ui_bell.odin)
	Bell, // the notification centre
	Alert, // a triangle with "!": an error, pi exited
	Clock, // a job (the bell; the left column's Jobs tab)
	Play, // a triangle: run now
	Pause, // two bars: pause
	Info, // a ring with an "i": a session's info (ui_sidebar.odin)
	// which agent a session runs (sidebar.odin: HARNESSES): its real logo (logos.odin), in its
	// own colours; the plain glyphs stay as the fallback for a harness without one
	Logo_Pi,
	Logo_Claude,
	Harness_Pi, // "π": a bar on two legs
	Harness_Claude, // a six-pointed asterisk
}
