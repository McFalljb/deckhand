package main

// Command palette search and ranking, palette actions through the command
// layer, text field words and mouse (`./build.sh test`).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	for k in palette.recent do delete(k)
	clear(&palette.recent)
	tf_set(&palette.field, "")
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	return runtime.heap_allocator()
}

@(private = "file")
picks: int

@(private = "file")
keys :: proc(items: []Palette_Item) -> []string {
	out := make([]string, len(items), context.temp_allocator)
	for it, i in items do out[i] = it.key
	return out
}

@(private = "file")
index_of :: proc(items: []Palette_Item, key: string) -> int {
	for it, i in items do if it.key == key do return i
	return -1
}

@(test)
palette_fuzzy_score :: proc(t: ^testing.T) {
	_, _, ok := fuzzy_score("xyz", "Look: Ghostty")
	testing.expect(t, !ok, "no subsequence: no match")
	s1, m, ok1 := fuzzy_score("gho", "Look: Ghostty")
	testing.expect(t, ok1)
	testing.expect_value(t, m, u64(0b111) << 6) // "Gho" at rune 6
	s2, _, _ := fuzzy_score("lgh", "Look: Ghostty") // scattered: L, G, h
	testing.expect(t, s1 > s2, "a substring beats a scattered match")
	pre, _, _ := fuzzy_score("new", "New chat")
	mid, _, _ := fuzzy_score("new", "Renew chat")
	testing.expect(t, pre > mid, "a prefix beats the middle of a word")
	ws, _, _ := fuzzy_score("nst", "New shell tab")
	in_word, _, _ := fuzzy_score("nst", "Unsettled")
	testing.expect(t, ws > in_word, "word starts beat letters inside a word")
	_, _, case_ok := fuzzy_score("GHOST", "look: ghostty")
	testing.expect(t, case_ok, "case-insensitive")
}

@(test)
palette_search_ranking :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp/recipe-box"})
	run_command(Add_Project{cwd = "/tmp/garden"})
	sess := run_command(New_Chat{project_id = state.selected_project}).created_id
	testing.expect(t, sess != 0)

	// empty query: actions first, then tabs, sessions, projects
	all := palette_search("")
	testing.expect_value(t, all[0].key, "action:new_session") // no data dir, so no Chats: New chat is not offered
	testing.expect(t, index_of(all, "action:close_tab") < 0, "close tab is not offered on a pi tab")
	tab_at := index_of(all, fmt.tprintf("tab:%d", find_session(sess).tabs[0].id))
	proj_at := index_of(all, "project:/tmp/garden")
	testing.expect(t, tab_at > 0 && proj_at > tab_at, "tabs before projects")

	// best match first; every word must match title or detail
	testing.expect_value(t, palette_search("ghost")[0].key, "action:look_ghostty")
	testing.expect_value(t, palette_search("garden")[0].key, "project:/tmp/garden")
	testing.expect_value(t, len(palette_search("look zzz")), 0)
	two := palette_search("look warm")
	testing.expect_value(t, two[0].key, "action:look_warm")
	testing.expect_value(t, palette_search("new")[0].key, "action:new_session") // tie: table order

	// recent items first: with an empty query, and on equal scores
	palette_remember("action:new_shell_tab")
	testing.expect_value(t, palette_search("")[0].key, "action:new_shell_tab")
	testing.expect_value(t, palette_search("new")[0].key, "action:new_shell_tab")
	palette_remember("project:/tmp/recipe-box")
	r := palette_search("")
	testing.expect_value(t, r[0].key, "project:/tmp/recipe-box")
	testing.expect_value(t, r[1].key, "action:new_shell_tab")
	for _ in 0 ..< PALETTE_RECENT_MAX + 3 do palette_remember("action:rescan")
	testing.expect_value(t, len(palette.recent), 3) // no duplicates
}

// Palette items run through the inbox as the user, like a click: State
// changes come from commands, and destructive ones still ask.
@(test)
palette_runs_commands :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"})
	sess := run_command(New_Chat{project_id = state.selected_project}).created_id

	run_command(Set_Focus{"palette"}, Caller{kind = .UI})
	testing.expect_value(t, state.focus_widget, "palette")
	v := state.version
	palette_run(palette_search("ghostty")[0])
	testing.expect_value(t, state.settings.theme, Theme_Id.Graphite) // queued, not applied directly
	inbox_drain()
	testing.expect_value(t, state.settings.theme, Theme_Id.Ghostty)
	testing.expect_value(t, state.focus_widget, "") // the palette closed
	testing.expect(t, state.version > v)
	testing.expect_value(t, palette.recent[0], "action:look_ghostty")

	// a new shell tab, then close it from the palette: it asks first
	palette_run(palette_search("new shell")[0])
	inbox_drain()
	s := find_session(sess)
	testing.expect_value(t, len(s.tabs), 2)
	run_command(Set_Close_Confirm{tab_kind = .Shell, rule = .Always})
	palette_run(palette_search("close tab")[0])
	inbox_drain()
	testing.expect_value(t, len(s.tabs), 2)
	testing.expect_value(t, len(state.pending_confirmations), 1)
	testing.expect_value(t, state.pending_confirmations[0].caller.kind, Caller_Kind.UI)

	// tabs and projects by name ("pi" ties with the Pin actions: pick the tab)
	pis := palette_search("pi")
	palette_run(pis[index_of(pis, fmt.tprintf("tab:%d", s.tabs[0].id))])
	inbox_drain()
	testing.expect_value(t, s.active_tab, s.tabs[0].id)

	// add project: the folder comes from the platform's (modal) picker, run
	// later from the main queue (platform.run_later), never inside the key or
	// click handler that chose the action; cancelled = nothing
	picks = 0
	platform.pick_folder = proc() -> string {picks += 1; return ""}
	n := len(state.projects)
	palette_run(palette_search("add project")[0])
	testing.expect_value(t, picks, 0) // not from inside the handler
	palette_run_deferred()
	inbox_drain()
	testing.expect_value(t, picks, 1)
	testing.expect_value(t, len(state.projects), n)
	platform.pick_folder = proc() -> string {picks += 1; return "/tmp/picked"}
	testing.expect_value(t, palette_search("add project")[0].key, "action:add_project")
	palette_run(palette_search("add project")[0])
	inbox_drain()
	testing.expect_value(t, picks, 1)
	palette_run_deferred()
	inbox_drain()
	testing.expect_value(t, picks, 2)
	testing.expect_value(t, state.projects[0].cwd, "/tmp/picked")
	palette_run_deferred() // once only
	testing.expect_value(t, picks, 2)

	// rename: fills the field, then focuses it (a command)
	palette_run(palette_search("rename")[0])
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "rename_project")
	testing.expect_value(t, tf_text(&rename_field), "/tmp/picked")
}

@(test)
text_field_words_and_mouse :: proc(t: ^testing.T) {
	f: Text_Field
	defer delete(f.buf)
	tf_set(&f, "git push --force origin")
	tf_end(&f, false)
	tf_word_left(&f, false)
	testing.expect_value(t, f.cursor, 17) // "origin"
	tf_word_left(&f, false)
	testing.expect_value(t, f.cursor, 11) // "force" (skips " --")
	tf_word_right(&f, true)
	testing.expect_value(t, tf_selected_text(&f), "force")
	tf_word_right(&f, false) // collapses to the right edge, then moves
	testing.expect_value(t, f.cursor, 23)
	tf_delete_word_left(&f)
	testing.expect_value(t, tf_text(&f), "git push --force ")
	tf_delete_to_start(&f)
	testing.expect_value(t, tf_text(&f), "")

	tf_set(&f, "héllo wörld, ok") // é and ö are two bytes: wörld = 7..13
	tf_click(&f, 7, 1, false) // caret
	testing.expect(t, f.cursor == 7 && f.anchor == 7)
	tf_click(&f, 3, 1, true) // shift-click extends
	testing.expect_value(t, tf_selected_text(&f), "llo ")
	tf_click(&f, 10, 2, false) // double-click: the word
	testing.expect_value(t, tf_selected_text(&f), "wörld")
	tf_drag(&f, 17) // drag right: by words
	testing.expect_value(t, tf_selected_text(&f), "wörld, ok")
	tf_drag(&f, 1) // drag left of the word: from its end back to a word start
	testing.expect_value(t, tf_selected_text(&f), "héllo wörld")
	tf_click(&f, 3, 3, false) // triple-click: everything
	testing.expect_value(t, tf_selected_text(&f), "héllo wörld, ok")
	tf_click(&f, 6, 1, false)
	tf_drag(&f, 0) // plain drag: characters
	testing.expect_value(t, tf_selected_text(&f), "héllo")

	// a composition shows at the caret, replacing the selection
	tf_set(&f, "cafe")
	tf_end(&f, false)
	tf_move(&f, -1, true)
	shown, lo, hi := tf_display(&f, "é")
	testing.expect_value(t, shown, "café")
	testing.expect(t, lo == 3 && hi == 5)
	shown, _, _ = tf_display(&f, "")
	testing.expect_value(t, shown, "cafe")
}

// An action run from a context menu row: one that cannot run now says so in
// a toast; one with a folder picker shows its outcome after the picker.
@(test)
menu_action_outcomes :: proc(t: ^testing.T) {
	context.allocator = reset()
	toast_clear()
	// no session on screen: New shell tab cannot run
	action_run("new_shell_tab", "New shell tab")
	testing.expect_value(t, toast.text, "New shell tab: not available now")
	toast_clear()
	action_run("new_shell_tab") // not from a menu: nothing said
	testing.expect_value(t, toast.text, "")
	// a folder picker row: its command's failure after the pick
	platform.pick_folder = proc() -> string {return "relative/not-there"}
	action_run("chats_dir", "Chats folder…")
	palette_run_deferred()
	inbox_drain()
	testing.expect(t, toast.err && len(toast.text) > len("Chats folder: ") && toast.text[:len("Chats folder: ")] == "Chats folder: ", toast.text)
	toast_clear()
}
