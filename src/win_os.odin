package main

// The window's own OS layer: what was the window's half of core.Platform (docs/plans/
// background-core.md §10.3, M3-F2). Window code calls it directly; the core asks for it with a
// window.request (window_requests.odin). main.odin fills it in (win_os_app); unit tests leave
// entries nil or set fakes, and test mode replaces the ones a script must not reach
// (autotest_platform).

import "core"

Win_OS :: struct {
	set_clipboard:        proc(text: string),
	get_clipboard:        proc() -> string, // what a paste inserts (clipboard_text)
	pick_folder:          proc() -> string, // asks the user for a folder (modal); "" = cancelled
	set_appearance:       proc(mode: core.Appearance), // the window's own appearance (title bar, folder picker): system = follow the OS
	reveal:               proc(path: string), // shows path in the file manager
	left_button:          proc() -> bool, // the left mouse button is down now (nil: assume it is)
	open_url:             proc(url: string) -> bool, // a web or mail link in the user's default app; false: not opened
	// the system clipboard's change count (browser_act.odin: a page changing it during an agent's
	// input is told to the user); nothing of its contents is read
	clipboard_count:      proc() -> int,
	// a secret (Copy a control token): onto the clipboard marked concealed and transient
	// (nspasteboard.org: clipboard managers neither show nor keep it); returns the change count
	// after it, for clear_clipboard_if. nil: set_clipboard (tests, test mode's own pasteboard)
	set_clipboard_secret: proc(text: string) -> int,
	clear_clipboard_if:   proc(count: int), // clears it if it still holds what that count put there
	set_badge:            proc(n: int), // the Dock icon's badge: n, none at 0 (macOS; nil elsewhere, in unit tests and scenes)
	play_sound:           proc(name: string), // a macOS system sound by name (the bell's: play_bell_sound); nil in unit tests, logged in scenes
}

win_os: Win_OS


// What a paste inserts: the system clipboard (a script's own pasteboard under autotest); "" with
// none (unit tests).
clipboard_text :: proc() -> string {
	return win_os.get_clipboard != nil ? win_os.get_clipboard() : ""
}

clipboard_set :: proc(text: string) {if win_os.set_clipboard != nil do win_os.set_clipboard(text)}

// The bell's sound (core.BELL_SOUND_LABELS): the core's window.request for an entry, or the
// gear previewing a choice. Only the names Deckhand offers reach macOS.
play_bell_sound :: proc(name: string) {
	if win_os.play_sound == nil do return
	for l, s in core.BELL_SOUND_LABELS do if s > .None && l == name {
		win_os.play_sound(name)
		return
	}
}

// The number on the Dock icon now (-1: not set yet).
dock_badge_shown := -1

// The Dock icon's badge: the sessions that need you (core.sessions_waiting_count), none at zero
// or while Badge Dock icon is off (set_notifications dock). Set only when it changes; from each
// frame and the window's timer (frames stop while hidden). The window owns the Dock tile: the
// background core has none.
dock_badge_update :: proc() {
	n := state.settings.bell_dock_off ? 0 : core.sessions_waiting_count()
	if n == dock_badge_shown do return
	dock_badge_shown = n
	if win_os.set_badge != nil do win_os.set_badge(n)
}
