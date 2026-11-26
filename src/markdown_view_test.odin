package main

// Markdown tabs through the command layer: who may follow which links, and
// what the tab does when its file changes, moves or goes away. No processes:
// the session is made by hand, the layout runs with system fonts.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
opened: [dynamic]string

// A clean State with one open session in a fresh temp folder (also a
// project), and a Markdown tab of `name` holding `text`, laid out.
@(private = "file")
md_setup :: proc(t: ^testing.T, name, text: string) -> (dir: string, tab_id: u64) {
	context.allocator = runtime.heap_allocator()
	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids {
		md_drop(id)
		editor_drop(id)
	}
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	clear(&opened)
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}, open_url = proc(url: string) -> bool {append(&opened, strings.clone(url, runtime.heap_allocator())); return true}}
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/deckhand-md-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	dir = core.fs_real(made, context.allocator)
	append(&state.projects, core.Project{id = core.new_id(), cwd = dir, label = "proj"})
	s := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("s-1"), project_id = state.projects[0].id, cwd = dir}
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	path := fmt.tprintf("%s/%s", dir, name)
	_ = os.write_entire_file(path, transmute([]u8)text)
	r := core.run_command(core.Markdown_Open{path = path}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	tab_id = r.created_id
	md_layout_now(t, tab_id)
	return
}

// Lays the tab's document out as a frame would (links, anchors).
@(private = "file")
md_layout_now :: proc(t: ^testing.T, tab_id: u64) {
	testing.expect(t, audit_ui(), "fonts")
	v, e := md_view_of(tab_id), editor_of(tab_id)
	if v != nil && e != nil do md_ensure_layout(v, e, 900)
}

@(test)
markdown_links_by_caller :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, tab := md_setup(t, "a.md", "# Top\n\n[site](https://example.com/x) [mail](mailto:a@example.invalid) [up](#top) [b](b.md)\n")
	ctl := core.Caller{kind = .Control}
	// another program's call: a web or mail link waits for the user
	for url in ([]string{"https://example.com/x", "mailto:a@example.invalid"}) {
		r := core.run_command(core.Markdown_Follow{tab_id = tab, url = url}, ctl)
		testing.expect_value(t, r.error, "needs_confirmation")
		testing.expect(t, r.confirm_by_user && r.confirm_token == "", "only the user confirms")
	}
	testing.expect_value(t, len(opened), 0)
	testing.expect_value(t, state.pending_confirmations[0].class, core.Command_Class.Open_Link)
	// asked again: the same entry
	_ = core.run_command(core.Markdown_Follow{tab_id = tab, url = "https://example.com/x"}, ctl)
	testing.expect_value(t, len(state.pending_confirmations), 2)
	// the user confirms the bar: it opens
	p := state.pending_confirmations[0]
	r := core.run_command(core.Markdown_Follow{tab_id = tab, url = "https://example.com/x", confirm = p.token}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, len(opened) == 1 && opened[0] == "https://example.com/x", "opened after the user confirmed")
	// the user's click: no question
	r = core.run_command(core.Markdown_Follow{tab_id = tab, url = "mailto:a@example.invalid"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(opened), 2)
	// anchors and relative files stay open to every caller
	testing.expect(t, core.run_command(core.Markdown_Follow{tab_id = tab, url = "#top"}, ctl).ok)
	r = core.run_command(core.Markdown_Follow{tab_id = tab, url = "b.md"}, ctl)
	testing.expect_value(t, r.error, "no such file") // followed (not asked): b.md does not exist
}

@(private = "file")
md_tab_of :: proc(id: u64) -> core.Markdown_Tab {
	_, tab, _ := core.find_tab(id)
	if tab == nil do return {}
	return tab.kind.(core.Markdown_Tab) or_else {}
}

// Files renames the file: the tab follows it (path, title, its editor).
@(test)
markdown_tab_follows_rename :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, tab := md_setup(t, "a.md", "# A\n")
	to := fmt.tprintf("%s/c.md", dir)
	r := core.run_command(core.Rename_Path{from = fmt.tprintf("%s/a.md", dir), to = to}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, md_tab_of(tab).path, to)
	_, tb, _ := core.find_tab(tab)
	testing.expect(t, tb != nil && tb.title == "c.md", tb != nil ? tb.title : "no tab")
	e := editor_of(tab)
	testing.expect(t, e != nil && e.path == to, e != nil ? e.path : "no editor")
}

// The file goes away or turns into something that cannot be shown: the
// preview says so (it keeps the last text).
@(test)
markdown_preview_says_when_the_file_is_gone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, tab := md_setup(t, "a.md", "# Kept text\n")
	e := editor_of(tab)
	path := fmt.tprintf("%s/a.md", dir)
	os.remove(path)
	editor_check_disk(e)
	md_layout_now(t, tab)
	shown := md_shown_text()
	testing.expect(t, strings.contains(shown, "Kept text") && strings.contains(shown, "Deleted on disk"), shown)
	_ = os.write_entire_file(path, transmute([]u8)string("\x7fELF\x00\x00\x01"))
	editor_check_disk(e)
	md_layout_now(t, tab)
	shown = md_shown_text()
	testing.expect(t, strings.contains(shown, "Kept text") && strings.contains(shown, "cannot be shown"), shown)
}

// Code blocks are highlighted once per document, not on every layout.
@(test)
markdown_code_highlighted_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, tab := md_setup(t, "a.md", "```go\nfunc main() {}\n```\n")
	v, e := md_view_of(tab), editor_of(tab)
	n := md_highlights
	for w in ([]f32{500, 700, 900}) do md_ensure_layout(v, e, w)
	testing.expect_value(t, md_highlights - n, 0) // md_setup laid it out (and highlighted) already
}

// ⇧⌘V is the Markdown tab's only while it (or its find bar) has the keyboard.
@(test)
markdown_shortcut_needs_the_keyboard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, tab := md_setup(t, "a.md", "# A\n")
	ev := sapp.Event{type = .KEY_DOWN, key_code = .V, modifiers = sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT}
	state.focus_widget = "agent_input" // typing in Atlas's terminal
	testing.expect(t, !markdown_event(core.focused_pane(), &ev), "Atlas keeps ⇧⌘V")
	testing.expect(t, !md_takes_keys(), "nor does the menu shortcut path take it")
	core.inbox_drain()
	testing.expect(t, !md_tab_of(tab).source, "still the preview")
	state.focus_widget = ""
	testing.expect(t, markdown_event(core.focused_pane(), &ev), "the tab's own shortcut")
	core.inbox_drain()
	testing.expect(t, md_tab_of(tab).source, "the source now")
}

// A link follows when the button comes up over it; ⌃-click (the context
// menu's click) does not follow.
@(test)
markdown_links_follow_on_mouse_up :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, tab := md_setup(t, "a.md", "[site](https://example.com/)\n")
	v := md_view_of(tab)
	v.area = {0, 0, 900, 600}
	x, y: f32 = -1, -1
	for p in v.lay.pieces do if p.kind == .Text && p.link >= 0 {
		x, y = p.x + p.w / 2, p.y + p.h / 2
		break
	}
	testing.expect(t, x >= 0, "a link piece")
	click :: proc(x, y: f32, mods: u32) {
		down := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = mods}
		markdown_event(core.focused_pane(), &down)
		core.inbox_drain()
	}
	click(x, y, 0)
	testing.expect_value(t, len(opened), 0) // the button is still down
	up := sapp.Event{type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y}
	markdown_event(core.focused_pane(), &up)
	core.inbox_drain()
	testing.expect_value(t, len(opened), 1)
	click(x, y, sapp.MODIFIER_CTRL)
	up.modifiers = sapp.MODIFIER_CTRL
	markdown_event(core.focused_pane(), &up)
	core.inbox_drain()
	testing.expect_value(t, len(opened), 1)
	// pressed on the link, released elsewhere: nothing
	click(x, y, 0)
	off := sapp.Event{type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = 899, mouse_y = 599}
	markdown_event(core.focused_pane(), &off)
	core.inbox_drain()
	testing.expect_value(t, len(opened), 1)
}

// Find's highlight inside a code block counts wide characters as two cells,
// as the block draws them; in inline code it follows the shaped text.
@(test)
markdown_match_offsets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, tab := md_setup(t, "a.md", "```\n日本語 x\n```\n\nSee `日本語 y`.\n")
	v := md_view_of(tab)
	block, inline: Md_Piece
	for p in v.lay.pieces do if p.kind == .Text && strings.has_prefix(p.text, "日本語") {
		if p.ink == .Syntax do block = p
		else if p.code do inline = p
	}
	testing.expect(t, block.text != "" && inline.text != "", "both pieces")
	testing.expect_value(t, md_piece_x(block, len("日本語")), 6 * font.cell_w)
	want := md_measure(inline.text[:len("日本語")], {font = inline.font, bold = inline.bold, italic = inline.italic, scale = inline.scale})
	testing.expect_value(t, md_piece_x(inline, len("日本語")), want)
}

// The source stays read-only when its file is opened again (a reload of a
// file that could not be shown).
@(test)
markdown_source_stays_read_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, tab := md_setup(t, "a.md", "# A\n")
	e := editor_of(tab)
	editor_reopen(e)
	testing.expect(t, e.readonly, "read-only after editor_reopen")
}

// The preview's safety rules, over tests/markdown/corpus/safety.md: raw HTML is never shown as
// markup (an HTML block shows its text, inline tags are dropped), an image is never fetched nor
// followed (it is not a link), and following a link opens only http, https and mailto outside
// Deckhand: javascript:, data:, file:, vbscript: and other schemes are refused however they are
// spelled (case, entities, escapes, angle brackets, references, autolinks).
@(test)
markdown_safety_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, tab := md_setup(t, "safety.md", #load("../tests/markdown/corpus/safety.md", string))
	v := md_view_of(tab)
	testing.expect(t, v != nil && v.laid, "laid out")
	shown := md_shown_text()
	for tag in ([]string{"<a ", "<img", "<iframe", "<script", "<style", "<div", "onerror", "onclick", "<title", "<textarea"}) {
		testing.expectf(t, !strings.contains(strings.to_lower(shown, context.temp_allocator), tag), "the preview shows %q:\n%s", tag, shown)
	}
	testing.expect(t, strings.contains(shown, "markdown inside an html block"), "an HTML block's text is shown")
	// images are not links: not in the link list, and not followable
	for u in v.lay.links {
		testing.expectf(t, !strings.has_prefix(u, "https://tracker.") && u != "data:image/png;base64,iVBORw0KGgo=", "an image's source is a link: %q", u)
	}
	r := core.run_command(core.Markdown_Follow{tab_id = tab, url = "https://tracker.example.com/pixel.gif"}, {kind = .UI})
	testing.expect_value(t, r.error, "not a link of this document")
	r = core.run_command(core.Markdown_Follow{tab_id = tab, url = "javascript:alert(2)"}, {kind = .UI})
	testing.expect_value(t, r.error, "not a link of this document")
	// every link of the document, clicked by the user: only web and mail links leave Deckhand
	links := make([dynamic]string, context.temp_allocator)
	for u in v.lay.links do append(&links, strings.clone(u, context.temp_allocator))
	testing.expect(t, len(links) >= 25, fmt.tprintf("%d links", len(links)))
	refused := 0
	for u in links {
		before := len(opened)
		r = core.run_command(core.Markdown_Follow{tab_id = tab, url = u}, {kind = .UI})
		core.inbox_drain()
		scheme := ""
		for c, i in u {
			if c == ':' {
				if i > 1 do scheme = strings.to_lower(u[:i], context.temp_allocator)
				break
			}
			if !(c < 128 && is_ascii_alnum(u8(c)) || c == '+' || c == '-' || c == '.') do break
		}
		web := scheme == "http" || scheme == "https" || scheme == "mailto"
		if len(opened) > before do testing.expectf(t, web, "opened %q", u)
		if scheme != "" && !web {
			testing.expectf(t, !r.ok && len(opened) == before, "followed %q (%v)", u, r)
			refused += 1
		}
	}
	testing.expect(t, refused >= 15, fmt.tprintf("%d dangerous links refused", refused))
	testing.expect(t, len(opened) >= 4, fmt.tprintf("%d web links opened", len(opened)))
}
