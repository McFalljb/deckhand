package core

// From src/ui.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

// What a session row or tab shows. pi tabs: the bridge's pi.status; shell
// tabs: recent output (they have no bridge).
Row_Status :: enum {
	None, // not open, idle, or no bridge yet: no dot
	Running, // pi is working (pulses); a shell printed recently
	Waiting, // waiting for you: a pi dialog is open
	Question, // pi's last answer asked something (softer)
	Error, // pi's last run ended in an error
	Exited, // pi exited
	Unseen, // finished while you were not looking (or marked unread): agent_status.odin
}
