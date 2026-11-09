package core

// From src/app_tab.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

App_Status :: enum {
	Starting,
	Running,
	Stalled, // no frame for APP_STALL_AFTER, but it answers tab.ping
	Not_Responding, // no answer to tab.ping, or a Mach send timed out
	Exited,
}

App_Tab :: struct {
	argv:       []string, // owned
	cwd:        string, // owned
	app_status: App_Status,
	exit_code:  int, // the last exit (-1 = none yet; 128+N for a signal)
}

// Commands (rows in command_table.odin).
New_App_Tab :: struct {
	session: u64, // 0 = the one on screen (a pi or Claude tab: its own)
	name:    string, // an app the session's .deckhand/apps.json declares (a pi or Claude tab: only this), or
	argv:    []string, // what to run (argv[0] on PATH), or
	command: string, // a command line for /bin/sh -c
	cwd:     string, // inside the session's folder ("" = it)
	title:   string,
}

App_Restart :: struct {
	tab_id: u64,
}

// Close an app tab: close_tab for an app tab, which a session's own agents may send too.
App_Close :: struct {
	tab_id:   u64,
	confirm:  string, // the user's close rule may ask (close_needs_confirm)
	comments: Comments_Choice, // pending comments made on it: send or drop (as close_tab)
}

// The apps a session's .deckhand/apps.json declares (what new_app_tab's name opens).
App_Declared :: struct {
	session: u64, // 0 = the caller's own (the user and scripts: the one on screen)
}

App_Input :: struct {
	tab_id: u64,
	events: []string, // JSON objects (TAB-PROTOCOL `input` without type/v), sent with "source":"agent"
}

App_Events :: struct {
	tab_id: u64,
	topic:  string, // "log" for tab.log events, ...
	since:  u64, // events after this seq
	limit:  int,
}

// Any method of the app's own (tab.describe lists them), passed through.
App_Call :: struct {
	tab_id:     u64,
	method:     string, // the request's `type` on the app's line
	params:     string, // a JSON object ("" = none): its fields go on the line as given
	timeout_ms: int,
}

// The frame on show (the slot Deckhand holds), as a PNG under the data dir.
App_Screenshot :: struct {
	tab_id:   u64,
	rect:     App_Rect, // the tab's logical px
	has_rect: bool, // false: the whole frame
}

// Draw the app's boxes (tab.boxes) over the tab; hovering shows a box's label.
App_Inspect :: struct {
	tab_id: u64,
	on:     bool,
}

App_Rect :: struct {
	x, y, w, h: f32,
}

// One of the app's boxes (tab.boxes): logical tab px.
App_Box :: struct {
	id, label: string,
	rect:      App_Rect,
}

// Internal: the app answered a request Deckhand sent it.
App_Call_Done :: struct {
	tab_id: u64,
	wire:   string, // our request id on the app's connection
	ok:     bool,
	error:  string,
	code:   string,
	data:   string, // JSON
	from_worker: bool, // a screenshot worker's, not the app's (only it may finish an "s…" wire)
	file:   string, // the worker's PNG: deleted if its request is gone
}

// Internal: the app's status changed (the frame loop saw it).
App_Update :: struct {
	tab_id:    u64,
	status:    App_Status,
	exit_code: int,
}

APP_EVENTS_MAX :: 500

APP_EVENT_TOPICS :: 32 // topics kept per tab

APP_METHOD_MAX :: 64 // app_call's method: [A-Za-z][A-Za-z0-9_.:/-]*

APP_BOXES_MAX :: 256 // tab.boxes kept per tab

APP_BOX_LABEL_MAX :: 200 // bytes of a box's label (id: APP_METHOD_MAX)
