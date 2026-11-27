package core

// From src/ui_setup.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

// One account on the sheet's accounts step (strings heap).
Setup_Account :: struct {
	dir:        string,
	label:      string,
	orig_label: string, // its label now ("" for one added here)
	keep:       bool, // ticked
	was_kept:   bool, // configured now (not removed)
	fixed:      bool, // the environment's default: always kept
	hand:       bool, // added on the sheet
	marked:     bool, // has Claude Code's account file or sign-in (Antigravity's step: agy's marks)
	name:       string, // Antigravity's step: the account's name ("" for one added here)
}

Setup_Step :: enum u8 {
	Agents,
	Main,
	Chats,
	Accounts,
	Agy_Accounts, // Antigravity accounts (agy_accounts.odin), when two or more are found
	Folders,
}
