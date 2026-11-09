package core

// From src/ui_sidebar.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Menu_Item :: struct {
	label:  string,
	keys:   string, // shortcut, shown muted
	check:  bool,
	action: string, // runs this action (actions.odin) instead of cmd
	cmd:    Command,
	rename: bool, // UI steps: select the project and focus the rename field
	sep:    bool, // a divider line (no action)
	editor: Editor_Action, // an editor step that is not a command (cut, paste…)
	files:  Files_Step, // a Files step that is not a command (rename, copy path…)
	copy:   string, // copies this text (a path, a branch name)
	note:   bool, // a muted line of text, not a choice (the ⓘ menu's info)
	icon:   Icon, // drawn before the label (the harness picker's)
	picker: Maybe(Menu_New_Session), // opens the harness picker for this place (harness.odin)
}
