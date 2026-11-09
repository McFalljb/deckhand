package main

// The macOS menu bar, built once at startup (menubar_install) from MENUBAR
// through the platform layer (platform_darwin.odin, src/native/menubar_macos.m).
// Most items are actions (actions.odin): their label, shortcut, whether they
// apply (make) and what a click runs come from the action table, so the menu
// bar, the palette and the shortcuts sheet share one source. The rest are
// key items (Edit: a shortcut that is not an action; a click sends the key to
// what has the keyboard, as pressing it does) and AppKit's own items (About,
// Hide, Minimize, Zoom, Full screen).
//
// Keys: a shortcut pressed goes through the menu bar to the view's keyDown:
// unchanged (menubar_macos.m), so event() (main.odin) handles every key as it
// did without a menu, once; shortcuts that are only in the menu bar reach
// actions through menubar_key_action. Items enable, disable and check when
// AppKit validates them (a menu opens, a key is looked up): no per-frame cost.

import "base:runtime"
import "core:strings"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

// AppKit's own items (menubar_macos.m's DH_* numbers).
Bar_Native :: enum {
	None,
	About,
	Hide,
	Hide_Others,
	Show_All,
	Minimize,
	Zoom,
	Full_Screen,
	Front,
}

Bar_Item :: struct {
	id:     string, // stable (tests, the autotest `menu` step); "" = action
	action: string, // an ACTIONS id: title, shortcut, enabled (its make) and what a click runs
	title:  string, // the menu's wording ("" = the action's label)
	keys:   string, // key and native items: their shortcut (the action's otherwise)
	native: Bar_Native,
	ok:     proc() -> bool, // enabled (and the action's make succeeds)
	check:  proc() -> bool, // a checkmark
	sub:    []Bar_Item, // a submenu (at the top: a menu in the bar)
	no_key: bool, // the action's shortcut belongs to another item
	sep:    bool,
}

@(private = "file")
SEP :: Bar_Item{sep = true}

MENUBAR := [?]Bar_Item {
	{title = "Deckhand", sub = []Bar_Item {
		{id = "about", title = "About Deckhand", native = .About},
		{action = "check_updates"}, // Deckhand's own updates (update.odin)
		SEP,
		{action = "settings", title = "Settings…"},
		{action = "setup"}, // "Set up Deckhand…": the first-run sheet (ui_setup.odin)
		SEP,
		{id = "hide", title = "Hide Deckhand", keys = "⌘H", native = .Hide},
		{id = "hide_others", title = "Hide others", keys = "⌥⌘H", native = .Hide_Others},
		{id = "show_all", title = "Show all", native = .Show_All},
		SEP,
		{action = "quit"},
		{action = "quit_stop_sessions"},
	}},
	{title = "File", sub = []Bar_Item {
		{action = "new_chat"},
		{action = "new_session", title = "New session in project"},
		{action = "new_shell_tab"},
		{action = "new_claude_tab"},
		{action = "new_browser_tab"},
		{action = "add_project"},
		{action = "open_file"},
		SEP,
		{action = "close_tab"},
		{action = "close_session"},
		SEP,
		{action = "save_file", ok = proc() -> bool {return editor_dirty(tab_editor())}},
	}},
	{title = "Edit", sub = []Bar_Item {
		{id = "undo", title = "Undo", keys = "⌘Z", ok = edit_undo_ok},
		{id = "redo", title = "Redo", keys = "⇧⌘Z", ok = edit_undo_ok},
		SEP,
		{id = "cut", title = "Cut", keys = "⌘X", ok = proc() -> bool {return edit_target() == .Field || edit_target() == .Editor && !tab_editor().readonly}},
		{id = "copy", title = "Copy", keys = "⌘C", ok = proc() -> bool {return edit_target() != .None}},
		{id = "paste", title = "Paste", keys = "⌘V", ok = proc() -> bool {t := edit_target(); return t == .Field || t == .Terminal || t == .Editor && !tab_editor().readonly}},
		{id = "select_all", title = "Select all", keys = "⌘A", ok = proc() -> bool {t := edit_target(); return t == .Field || t == .Editor}},
		SEP,
		{action = "find_in_file", title = "Find…"},
		{id = "find_replace", title = "Find and replace…", keys = "⌥⌘F", ok = edit_find_ok},
		{id = "find_next", title = "Find next", keys = "⌘G", ok = edit_find_ok},
		{id = "find_prev", title = "Find previous", keys = "⇧⌘G", ok = edit_find_ok},
		{action = "browser_find", title = "Find in page"},
		{action = "goto_line"},
		SEP,
		{action = "filter"},
	}},
	{title = "View", sub = []Bar_Item {
		{action = "toggle_left", check = proc() -> bool {return state.layout.left_open}},
		{action = "show_sessions", title = "Sessions", check = proc() -> bool {return left_tab_shown(.Sessions)}},
		{action = "show_files", title = "Files", check = proc() -> bool {return left_tab_shown(.Files)}},
		{id = "settings_tab", action = "settings", title = "Settings files", no_key = true, check = proc() -> bool {return left_tab_shown(.Settings)}},
		{action = "show_jobs", title = "Jobs", check = proc() -> bool {return left_tab_shown(.Jobs)}},
		{action = "changes_open"}, // "Show changes"
		{action = "toggle_right", title = "Toggle right panels", check = proc() -> bool {return state.layout.right_open}},
		SEP,
		{action = "palette", title = "Command palette"},
		{action = "notifications", title = "Bell"},
		{action = "toggle_agent", check = proc() -> bool {return state.home_open}},
		{action = "markdown_preview"},
		SEP,
		{title = "Appearance", sub = []Bar_Item {
			{action = "appearance_system", title = "System", check = proc() -> bool {return state.settings.appearance == .System}},
			{action = "appearance_light", title = "Light", check = proc() -> bool {return state.settings.appearance == .Light}},
			{action = "appearance_dark", title = "Dark", check = proc() -> bool {return state.settings.appearance == .Dark}},
		}},
		{title = "Look", sub = []Bar_Item {
			{action = "look_graphite", title = "Graphite", check = proc() -> bool {return state.settings.theme == .Graphite}},
			{action = "look_warm", title = "Warm", check = proc() -> bool {return state.settings.theme == .Warm}},
			{action = "look_ghostty", title = "Ghostty", check = proc() -> bool {return state.settings.theme == .Ghostty}},
		}},
		{action = "reduce_motion", check = proc() -> bool {return state.settings.reduce_motion}},
		SEP,
		{action = "text_bigger"},
		{action = "text_smaller"},
		{action = "text_reset"},
		SEP,
		{action = "browser_zoom_in", title = "Zoom page in"},
		{action = "browser_zoom_out", title = "Zoom page out"},
		{action = "browser_zoom_reset", title = "Page actual size"},
		{action = "browser_devtools", title = "Developer tools"},
		SEP,
		{id = "full_screen", title = "Enter full screen", keys = "⌃⌘F", native = .Full_Screen},
	}},
	{title = "Window", sub = []Bar_Item {
		{id = "minimize", title = "Minimize", keys = "⌘M", native = .Minimize},
		{id = "zoom", title = "Zoom", native = .Zoom},
		SEP,
		{action = "next_tab"},
		{action = "prev_tab"},
		{action = "tab_1"},
		{action = "tab_2"},
		{action = "tab_3"},
		{action = "tab_4"},
		{action = "tab_5"},
		{action = "tab_6"},
		{action = "tab_7"},
		{action = "tab_8"},
		{action = "tab_9"},
		SEP,
		{action = "split_right"},
		{action = "split_down"},
		{action = "close_pane"},
		{action = "equalize_panes"},
		{action = "focus_pane_left"},
		{action = "focus_pane_right"},
		{action = "focus_pane_up"},
		{action = "focus_pane_down"},
		{action = "move_tab_left"},
		{action = "move_tab_right"},
		{action = "move_tab_up"},
		{action = "move_tab_down"},
		SEP,
		{action = "next_session"},
		{action = "prev_session"},
		SEP,
		{id = "front", title = "Bring all to front", native = .Front},
	}},
	{title = "Help", sub = []Bar_Item {
		{action = "user_guide"},
		{action = "shortcuts"},
	}},
}

left_tab_shown :: proc(t: core.Left_Tab) -> bool {return state.layout.left_open && state.layout.left_tab == t}

// What the Edit menu's items act on: what has the keyboard.
Edit_Target :: enum {
	None,
	Field, // a text field (the palette, a filter, a name)
	Editor,
	Terminal,
}

edit_target :: proc() -> Edit_Target {
	if f, _, _ := focused_field(); f != nil do return .Field
	if state.focus_widget == "" && tab_editor() != nil do return .Editor
	if core.key_tab() != nil && core.key_term() != nil && (state.focus_widget == "" || state.focus_widget == "agent_input") do return .Terminal
	return .None
}

@(private = "file")
edit_undo_ok :: proc() -> bool {return edit_target() == .Editor && !tab_editor().readonly}

@(private = "file")
edit_find_ok :: proc() -> bool {
	e := tab_editor()
	return e != nil && e.refused == ""
}

// ---- the items, flattened (tag = index) ----

@(private = "file")
bar_items: [dynamic]^Bar_Item

menubar_item_id :: proc(it: ^Bar_Item) -> string {return it.id != "" ? it.id : it.action}

// Every item (not separators or submenus), in menu order; tag = index.
menubar_items :: proc() -> []^Bar_Item {
	if len(bar_items) == 0 {
		bar_items = make([dynamic]^Bar_Item, runtime.heap_allocator()) // for the app's life (tests too)
		for &top in MENUBAR do collect(&top)
	}
	return bar_items[:]
}

// The item's title now (by tag: the platform's callbacks).
menubar_title :: proc(tag: int) -> string {
	its := menubar_items()
	return tag >= 0 && tag < len(its) ? menubar_item_title(its[tag]) : ""
}

menubar_item_title :: proc(it: ^Bar_Item) -> string {
	if it.title != "" do return it.title
	if a := action_by_id(it.action); a != nil do return action_label(a)
	return ""
}

// The item's shortcut ("" = none).
menubar_keys :: proc(it: ^Bar_Item) -> string {
	if it.no_key do return ""
	if it.keys != "" do return it.keys
	if a := action_by_id(it.action); a != nil do return a.keys
	return ""
}

menubar_state :: proc(tag: int) -> (enabled, checked: bool) {
	its := menubar_items()
	if tag < 0 || tag >= len(its) do return
	it := its[tag]
	enabled = true
	if it.action != "" do enabled = action_ok(it.action)
	// the job sheet is modal: the menu's actions wait (Quit asks it first;
	// the Edit menu's keys go to its fields)
	if enabled && it.action != "" && it.action != "quit" && job_sheet_open() do enabled = false
	if enabled && it.ok != nil do enabled = it.ok()
	checked = it.check != nil && it.check()
	return
}

// A click on an item (or the autotest's `menu` step): the action, or the
// key item's key to what has the keyboard.
menubar_fire :: proc(tag: int) {
	its := menubar_items()
	if !app.ready || !autotest_allows_input() || tag < 0 || tag >= len(its) do return
	menubar_run(its[tag])
}

menubar_run :: proc(it: ^Bar_Item) {
	ime_cancel()
	if it.action != "" {
		action_run(it.action)
	} else if k, ok := parse_keys(it.keys); ok {
		ev := sapp.Event{type = .KEY_DOWN, key_code = k.code, modifiers = k.mods}
		event(&ev)
		if k.code == .V && k.mods == sapp.MODIFIER_SUPER {
			ev = {type = .CLIPBOARD_PASTED} // as sokol sends it after ⌘V
			event(&ev)
		}
		ev = {type = .KEY_UP, key_code = k.code, modifiers = k.mods}
		event(&ev)
	}
	core.inbox_drain()
	app.redraw = true
}

menubar_find :: proc(id: string) -> ^Bar_Item {
	for it in menubar_items() do if menubar_item_id(it) == id do return it
	return nil
}

menubar_tag :: proc(it: ^Bar_Item) -> int {
	for x, i in menubar_items() do if x == it do return i
	return -1
}

// The action whose menu shortcut a key press is (event(): keys that only the
// menu bar knows, such as ⌘+ or ⇧⌘]); "" = none.
menubar_key_action :: proc(code: sapp.Keycode, mods: u32) -> string {
	m := mods & (sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT | sapp.MODIFIER_ALT | sapp.MODIFIER_CTRL)
	for it in menubar_items() {
		if it.action == "" do continue
		k, ok := parse_keys(menubar_keys(it))
		if !ok || k.code != code do continue
		// ⌘+ is ⌘= with or without Shift (a US keyboard's + needs it)
		if k.mods == m || (k.equiv == "+" && k.mods | sapp.MODIFIER_SHIFT == m) do return it.action
	}
	return ""
}

menubar_install :: proc() {
	menubar_items()
	platform_menu_begin()
	for &top in MENUBAR do build(&top)
	platform_menu_end()
}

@(private = "file")
collect :: proc(it: ^Bar_Item) {
	if it.sep do return
	if it.sub != nil {
		for &s in it.sub do collect(&s)
		return
	}
	append(&bar_items, it)
}

@(private = "file")
build :: proc(it: ^Bar_Item) {
	if it.sep {
		platform_menu_separator()
		return
	}
	if it.sub != nil {
		platform_menu_push(it.title)
		for &s in it.sub do build(&s)
		platform_menu_pop()
		return
	}
	tag := menubar_tag(it)
	k, _ := parse_keys(menubar_keys(it))
	a := action_by_id(it.action)
	platform_menu_item(menubar_item_title(it), k.equiv, k.ns_mods, tag, int(it.native), it.title == "" && a != nil && a.title != nil)
}

// ---- shortcuts as written ("⇧⌘N") ----

Bar_Key :: struct {
	code:    sapp.Keycode,
	mods:    u32, // sapp.MODIFIER_*
	ns_mods: u64, // NSEventModifierFlags
	equiv:   string, // AppKit's key equivalent
}

NS_SHIFT :: u64(1) << 17
NS_CONTROL :: u64(1) << 18
NS_OPTION :: u64(1) << 19
NS_COMMAND :: u64(1) << 20

parse_keys :: proc(keys: string) -> (k: Bar_Key, ok: bool) {
	rest := keys
	mods: for len(rest) > 0 {
		switch {
		case strings.has_prefix(rest, "⌘"): k.mods |= sapp.MODIFIER_SUPER; k.ns_mods |= NS_COMMAND
		case strings.has_prefix(rest, "⇧"): k.mods |= sapp.MODIFIER_SHIFT; k.ns_mods |= NS_SHIFT
		case strings.has_prefix(rest, "⌥"): k.mods |= sapp.MODIFIER_ALT; k.ns_mods |= NS_OPTION
		case strings.has_prefix(rest, "⌃"): k.mods |= sapp.MODIFIER_CTRL; k.ns_mods |= NS_CONTROL
		case: break mods
		}
		rest = rest[len("⌘"):] // every modifier sign is 3 bytes
	}
	switch rest {
	case ",": k.code, k.equiv = .COMMA, ","
	case "/": k.code, k.equiv = .SLASH, "/"
	case "[": k.code, k.equiv = .LEFT_BRACKET, "["
	case "]": k.code, k.equiv = .RIGHT_BRACKET, "]"
	case "+": k.code, k.equiv = .EQUAL, "+"
	case "−", "-": k.code, k.equiv = .MINUS, "-"
	case "↑": k.code, k.equiv = .UP, "\uF700" // AppKit's NSUpArrowFunctionKey
	case "↓": k.code, k.equiv = .DOWN, "\uF701" // NSDownArrowFunctionKey
	case "←": k.code, k.equiv = .LEFT, "\uF702" // NSLeftArrowFunctionKey
	case "→": k.code, k.equiv = .RIGHT, "\uF703" // NSRightArrowFunctionKey
	case:
		if len(rest) != 1 do return {}, false
		c := rest[0]
		switch {
		case c >= 'A' && c <= 'Z':
			k.code = sapp.Keycode(int(sapp.Keycode.A) + int(c - 'A'))
			k.equiv = strings.to_lower(rest, context.temp_allocator)
		case c >= '0' && c <= '9':
			k.code = sapp.Keycode(int(sapp.Keycode._0) + int(c - '0'))
			k.equiv = rest
		case:
			return {}, false
		}
	}
	return k, k.mods != 0
}
