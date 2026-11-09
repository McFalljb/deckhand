package core

// From src/editor_view.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Editor_Action :: enum u8 {
	None,
	Undo,
	Redo,
	Cut,
	Copy,
	Paste,
	Select_All,
	Toggle_Comment,
	Indent,
	Outdent,
	Find,
	Replace,
	Goto,
}
