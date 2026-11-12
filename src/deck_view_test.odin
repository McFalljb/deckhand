package main

// The Deck view (ui_deck.odin): the cards' order (the Attention view's, past no filter, online
// machines only), the columns for a width (fixed-width cards), a card's content per group (the
// message's lines or none, plain words, the harness (Codex too), the machine's chip only with
// several machines, another machine's text drawn cleaned, the other tabs' dots and count), its
// fill and edge, the current card outlined and the keyboard's ringed, each card its group's height
// whatever its status, its Peek (the look-only peek), a click and Enter, the arrows across the grid
// and into view, closing on other navigation, the action and its key, the empty centre's place,
// and the layout audit at narrow and wide centres in every look and with 1, 6 and 30 sessions.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
dk_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	p := core.Project{id = 1, group = .Projects, cwd = strings.clone("/tmp/dk-proj"), label = strings.clone("web")}
	append(&state.projects, p)
	state.selected_project = p.id
	ui_hover = nil
	deck = {cards = deck.cards} // closed, nothing remembered (its cards' array kept)
	state.settings.reduce_motion = true
	toast_clear()
}

// A shell tab: "" idle, "waiting", "error", "unseen", "working"; msg: its OSC 7501 message; its
// status `ago` ({}: not known).
@(private = "file")
dk_tab :: proc(id: u64, need := "", ago: time.Duration = 0, msg := "") -> core.Tab {
	t := core.Tab{id = id, kind = core.Shell_Tab{}, title = strings.clone(fmt.tprintf("tab %d", id), runtime.heap_allocator()), status = .Running}
	t.prog.progress = -1
	switch need {
	case "waiting": t.prog.state, t.prog.kind = .Blocked, .Permission
	case "error":   t.prog.state = .Error
	case "unseen":  t.unseen = true
	case "working": t.prog.state = .Working
	}
	if msg != "" do t.prog.msg = strings.clone(msg, runtime.heap_allocator())
	t.status_key = core.status_key(core.tab_status_view(t))
	if ago > 0 do t.status_since = time.time_add(time.now(), -ago)
	return t
}

@(private = "file")
dk_session :: proc(id: u64, title: string, tabs: ..core.Tab) -> ^core.Open_Session {
	context.allocator = runtime.heap_allocator()
	s := core.Open_Session{id = id, project_id = 1, pi_session_id = strings.clone(fmt.tprintf("s%d", id)), cwd = strings.clone("/tmp/dk-proj"), title = strings.clone(title), shown_at = i64(id)}
	for t in tabs do append(&s.tabs, t)
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
	append(&state.sessions, core.Session{id = s.pi_session_id, path = strings.clone(fmt.tprintf("/tmp/dk-proj/%d.jsonl", id)), title = s.title})
	return &state.open_sessions[len(state.open_sessions) - 1]
}

@(private = "file")
dk_ids :: proc(rows: []core.Attention_Row) -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	for r in rows do append(&out, r.session.id)
	return out[:]
}

@(private = "file")
dk_drawn :: proc() -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	for c in deck.cards do append(&out, c.sid)
	return out[:]
}

@(private = "file")
dk_same :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if b[i] != x do return false
	return true
}

@(private = "file")
dk_box :: proc(name: string, i: u32 = 0) -> (clay.BoundingBox, bool) {
	d := clay.GetElementData(clay.ID(name, i))
	return d.boundingBox, d.found
}

@(private = "file")
dk_in :: proc(a, b: clay.BoundingBox) -> bool {
	return a.x >= b.x - 0.5 && a.y >= b.y - 0.5 && a.x + a.width <= b.x + b.width + 0.5 && a.y + a.height <= b.y + b.height + 0.5
}

// The texts drawn inside a box, one per line.
@(private = "file")
dk_texts :: proc(cmds: clay.ClayArray(clay.RenderCommand), within: clay.BoundingBox) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text || !dk_in(c.boundingBox, within) do continue
		tx := c.renderData.text
		strings.write_string(&b, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// The card drawn for session sid (its box; false: none).
@(private = "file")
dk_card :: proc(sid: u64) -> (clay.BoundingBox, bool) {
	for c, i in deck.cards do if c.sid == sid do return dk_box("deckcard", u32(i))
	return {}, false
}

// The border drawn around a box (its colour; false: none).
@(private = "file")
dk_border :: proc(cmds: clay.ClayArray(clay.RenderCommand), b: clay.BoundingBox) -> (core.Rgba, bool) {
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType == .Border && c.boundingBox == b do return to_rgba(c.renderData.border.color), true
	}
	return {}, false
}

// The dots drawn inside a box (DOT px squares: a card's other tabs), their colours in order.
@(private = "file")
dk_dots :: proc(cmds: clay.ClayArray(clay.RenderCommand), b: clay.BoundingBox) -> []core.Rgba {
	out := make([dynamic]core.Rgba, context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType == .Rectangle && c.boundingBox.width == px(DOT) && c.boundingBox.height == px(DOT) && dk_in(c.boundingBox, b) do append(&out, to_rgba(c.renderData.rectangle.backgroundColor))
	}
	return out[:]
}

// A box's own background (its Rectangle command).
@(private = "file")
dk_fill :: proc(cmds: clay.ClayArray(clay.RenderCommand), b: clay.BoundingBox) -> core.Rgba {
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType == .Rectangle && c.boundingBox == b do return to_rgba(c.renderData.rectangle.backgroundColor)
	}
	return {}
}

// The colour of a text drawn inside a box ({}: none).
@(private = "file")
dk_text_color :: proc(cmds: clay.ClayArray(clay.RenderCommand), b: clay.BoundingBox, s: string) -> core.Rgba {
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text || !dk_in(c.boundingBox, b) do continue
		tx := c.renderData.text
		if string(tx.stringContents.chars[:tx.stringContents.length]) == s do return to_rgba(tx.textColor)
	}
	return {}
}

// The deck opened or closed, as the next frame sees it (show_no_session or focus_session, through
// the inbox).
@(private = "file")
dk_toggle :: proc() {
	deck_toggle()
	core.inbox_drain()
}

@(private = "file")
dk_shown :: proc() -> bool {
	core.inbox_drain()
	return deck_shown()
}

@(private = "file")
dk_key :: proc(k: sapp.Keycode, mods: u32 = 0) -> bool {
	ev := sapp.Event{type = .KEY_DOWN, key_code = k, modifiers = mods}
	return deck_event(&ev)
}

// The order is the Attention view's (its groups, the longest first) with no filter set; the deck
// passes the filter (the whole fleet); the columns for a width.
@(test)
deck_order_and_columns :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dk_reset()
	defer dk_reset()
	dk_session(100, "Idle one", dk_tab(101))
	dk_session(200, "Schema", dk_tab(201, "waiting", 3 * time.Minute))
	dk_session(300, "Login page", dk_tab(301, "waiting", 9 * time.Minute))
	dk_session(400, "Crash", dk_tab(401, "error", 20 * time.Minute))
	dk_session(500, "Bump deps", dk_tab(501, "unseen", time.Minute))
	dk_session(600, "Relay", dk_tab(601, "working", 12 * time.Minute))
	dk_session(700, "Docs", dk_tab(701, "working", 2 * time.Minute))
	want := []u64{300, 200, 400, 500, 600, 700, 100}
	testing.expectf(t, dk_same(dk_ids(core.attention_rows()), want), "attention: %v", dk_ids(core.attention_rows()))
	testing.expectf(t, dk_same(dk_ids(deck_rows()), want), "deck: %v", dk_ids(deck_rows()))
	// a filter narrows the Attention view, never the deck
	core.run_command(core.Set_Filter{text = "relay"}, {kind = .UI})
	testing.expect(t, len(core.attention_rows()) < len(want), "the filter narrows the list")
	testing.expectf(t, dk_same(dk_ids(deck_rows()), want), "the deck: every session: %v", dk_ids(deck_rows()))
	core.run_command(core.Set_Filter{text = ""}, {kind = .UI})

	// the columns: as many 288 px cards with 12 px gaps as fit, at least one; never stretched (one
	// column: up to 360 px, no wider than the room)
	testing.expect_value(t, deck_columns(200), 1)
	testing.expect_value(t, deck_columns(288), 1)
	testing.expect_value(t, deck_columns(587), 1)
	testing.expect_value(t, deck_columns(588), 2)
	testing.expect_value(t, deck_columns(1100), 3)
	testing.expect_value(t, deck_columns(1640), 5)
	testing.expect_value(t, deck_card_w(588, 2), f32(288))
	testing.expect_value(t, deck_card_w(1100, 3), f32(288))
	testing.expect_value(t, deck_card_w(330, 1), f32(330))
	testing.expect_value(t, deck_card_w(587, 1), f32(360))
	testing.expect_value(t, deck_card_w(200, 1), f32(200))

	// drawn: in that order, the cards of a grid row on one line, 288 px wide and their group's
	// height, 12 px apart, each group from a row of its own, all inside the deck
	dk_toggle()
	cmds := ui_layout(1600, 900)
	testing.expectf(t, dk_same(dk_drawn(), want), "drawn: %v", dk_drawn())
	dk, ok := dk_box("deck")
	testing.expect(t, ok, "the deck")
	first, _ := dk_box("deckcard", 0)
	cols := deck.cols
	testing.expect(t, cols >= 2, "a wide centre: several columns")
	rows := deck_rows()
	for c, i in deck.cards {
		b, found := dk_box("deckcard", u32(i))
		testing.expectf(t, found && dk_in(b, dk), "card %d inside the deck: %v", i, b)
		testing.expectf(t, b.width == f32(DECK_CARD_W) && b.height == deck_card_h(rows[i].group), "card %d: %v, %v", i, b, rows[i].group)
		if i > 0 {
			p, _ := dk_box("deckcard", u32(i - 1))
			prev := deck.cards[i - 1]
			if prev.row == c.row do testing.expectf(t, b.y == p.y && b.x - (p.x + p.width) == f32(DECK_GAP), "card %d beside %d: %v %v", i, i - 1, p, b)
			else do testing.expectf(t, b.y >= p.y + p.height + f32(DECK_GAP) && b.x == first.x, "card %d starts a row: %v", i, b)
		}
	}
	// NEEDS YOU (3) then FINISHED: a new row, under its label
	testing.expect(t, deck.cards[3].row > deck.cards[2].row, "FINISHED on a row of its own")
	// a card's height is its group's: needs you (two lines) > working and finished (one) > idle
	testing.expect(t, deck_card_h(.Needs_You) > deck_card_h(.Working) && deck_card_h(.Working) == deck_card_h(.Finished) && deck_card_h(.Finished) > deck_card_h(.Idle), "heights by group")
	// a group's label has its hairline across the rest of the row
	for g in ([]core.Attention_Group{.Needs_You, .Finished, .Working, .Idle}) {
		lb, _ := dk_box("decklabel", u32(g))
		rule := false
		for i in 0 ..< cmds.length {
			c := &cmds.internalArray[i]
			bb := c.boundingBox
			if c.commandType == .Rectangle && bb.height == f32(core.BORDER_W) && bb.width > lb.width / 2 && dk_in(bb, lb) && to_rgba(c.renderData.rectangle.backgroundColor) == theme().border do rule = true
		}
		testing.expectf(t, rule, "%v: its hairline", g)
	}
	text := dk_texts(cmds, dk)
	for label in ([]string{"NEEDS YOU\n3\n", "FINISHED\n1\n", "WORKING\n2\n", "IDLE\n1\n", "7 sessions · 3 need you (1 error) · 1 finished · 2 working\n"}) do testing.expectf(t, strings.contains(text, label), "%q in %q", label, text)
	// the panes are not laid out under it (they keep their sizes and run on)
	_, term := dk_box("terminal")
	testing.expect(t, !term, "no pane laid out")
}

// What a card says: the message or plain words, the machine only with several machines (another
// machine's text cleaned, an offline one's sessions left out), the tabs' footer, the current
// session outlined; a status change moves nothing.
@(test)
deck_card_content :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dk_reset()
	s := dk_session(100, "Login page", dk_tab(101, "waiting", 3 * time.Minute, "Apply these edits?"), dk_tab(102, "working"), dk_tab(103))
	s.agent = .Claude
	dk_session(200, "Relay", dk_tab(201, "working", 12 * time.Minute))
	dk_session(300, "Quiet", dk_tab(301))
	dk_session(400, "Bump deps", dk_tab(401, "unseen", time.Minute), dk_tab(402, "waiting", 0)) // its waiting tab places it
	state.current_session = 200
	dk_toggle()
	cmds := ui_layout(1600, 900)
	th := theme()
	card :: proc(t: ^testing.T, cmds: clay.ClayArray(clay.RenderCommand), sid: u64, loc := #caller_location) -> string {
		b, ok := dk_card(sid)
		testing.expectf(t, ok, "card %d", sid, loc = loc)
		return dk_texts(cmds, b)
	}
	// needs you: its title, age, message (body text), harness, and "3 tabs" with a dot for what
	// the others do (one works, one is idle: the working colour)
	c100 := card(t, cmds, 100)
	for want in ([]string{"dk-proj ·\nUntitled Claude", "\n3m\nApply these edits?\nClaude Code\n3 tabs\n"}) do testing.expectf(t, strings.contains(c100, want), "%q in %q", want, c100)
	testing.expectf(t, !strings.contains(c100, "this Mac"), "one machine: no machine: %q", c100)
	b100, _ := dk_card(100)
	d100 := dk_dots(cmds, b100)
	testing.expectf(t, len(d100) == 1 && d100[0] == th.running, "the others: one working: %v", d100)
	testing.expect(t, dk_text_color(cmds, b100, "Apply these edits?") == th.text, "needs you: its message in body text")
	testing.expect(t, dk_text_color(cmds, b100, "3m") == th.waiting, "its age in the waiting colour")
	// working: one line, its words; one tab: no tab count, no dots
	c200 := card(t, cmds, 200)
	testing.expectf(t, strings.contains(c200, "\n12m\nWorking for 12m\npi\n") && !strings.contains(c200, "tab"), "%q", c200)
	b200, _ := dk_card(200)
	testing.expectf(t, len(dk_dots(cmds, b200)) == 0, "one tab: no dots")
	// idle: the title and the meta line only, on a quieter fill
	c300 := card(t, cmds, 300)
	testing.expectf(t, strings.count(c300, "\n") == 4 && strings.contains(c300, "\nQuiet\n") && strings.has_suffix(c300, "\npi\n") && !strings.contains(c300, "Idle"), "%q", c300)
	c400 := card(t, cmds, 400)
	testing.expectf(t, strings.contains(c400, "\nWaiting for you\n") && strings.contains(c400, "\n2 tabs\n"), "%q", c400)
	b400, _ := dk_card(400)
	d400 := dk_dots(cmds, b400)
	testing.expectf(t, len(d400) == 1 && d400[0] == status_color(.Unseen), "the other tab finished: %v", d400)
	// each card's height is its group's
	b300, _ := dk_card(300)
	testing.expectf(t, b100.height == deck_card_h(.Needs_You) && b200.height == deck_card_h(.Working) && b300.height == deck_card_h(.Idle), "heights: %v %v %v", b100, b200, b300)
	// fills: needs you tinted in the waiting colour with its hairline; idle quieter; working plain
	f100, e100 := deck_fill(.Needs_You, false)
	f300, _ := deck_fill(.Idle, false)
	testing.expectf(t, dk_fill(cmds, b100) == f100 && f100 != th.bg_elevated, "needs you: tinted: %v", dk_fill(cmds, b100))
	testing.expectf(t, dk_fill(cmds, b300) == f300 && f300 != th.bg_elevated, "idle: quieter: %v", dk_fill(cmds, b300))
	testing.expectf(t, dk_fill(cmds, b200) == th.bg_elevated, "working: %v", dk_fill(cmds, b200))
	ferr, _ := deck_fill(.Needs_You, true)
	testing.expect(t, ferr != f100, "an error's tint is its own")
	// the current session's card outlined in the accent; one that needs you, its hairline; the
	// others none
	col, found := dk_border(cmds, b200)
	testing.expectf(t, found && col == th.accent, "current: %v", col)
	col, found = dk_border(cmds, b100)
	testing.expectf(t, found && col == e100 && e100 == with_alpha(th.waiting, DECK_EDGE_ALPHA), "needs you: %v", col)
	_, found = dk_border(cmds, b300)
	testing.expect(t, !found, "idle: no border")
	// a status change (working to waiting, with a message): every card where it was
	before := make([dynamic]clay.BoundingBox, context.temp_allocator)
	for _, i in deck.cards {
		b, _ := dk_box("deckcard", u32(i))
		append(&before, b)
	}
	order := dk_drawn()
	r := core.find_session(200)
	r.tabs[0] = dk_tab(201, "working", 12 * time.Minute, "Running the tests, a long message that wraps over more than three lines of the card so its end is cut with an ellipsis and nothing grows")
	cmds = ui_layout(1600, 900)
	testing.expect(t, dk_same(order, dk_drawn()), "same order")
	for _, i in deck.cards {
		b, _ := dk_box("deckcard", u32(i))
		testing.expectf(t, b == before[i], "card %d moved: %v, was %v", i, b, before[i])
	}
	lines := strings.count(card(t, cmds, 200), "\n")
	testing.expectf(t, lines == 5 && strings.contains(card(t, cmds, 200), "…"), "a long message while working: one line, cut: %q", card(t, cmds, 200))
	// needs you: two lines, cut
	core.find_session(100).tabs[0] = dk_tab(101, "waiting", 3 * time.Minute, "Apply these edits to the login form and its tests? They touch twelve files across the app and its fixtures, and the docs")
	cmds = ui_layout(1600, 900)
	for _, i in deck.cards {
		b, _ := dk_box("deckcard", u32(i))
		testing.expectf(t, b == before[i], "card %d moved: %v, was %v", i, b, before[i])
	}
	lines = strings.count(card(t, cmds, 100), "\n")
	testing.expectf(t, lines == 7 && strings.contains(card(t, cmds, 100), "…"), "a long question: two lines, cut: %q", card(t, cmds, 100))
	for sid in ([]u64{100, 200}) {
		bx, _ := dk_card(sid)
		for i in 0 ..< cmds.length {
			c := &cmds.internalArray[i]
			if c.commandType == .Text && c.boundingBox.y >= bx.y && c.boundingBox.y < bx.y + bx.height && c.boundingBox.x >= bx.x && c.boundingBox.x < bx.x + bx.width do testing.expectf(t, dk_in(c.boundingBox, bx), "a text spills out of its card: %v in %v", c.boundingBox, bx)
		}
	}

	// other machines: this Mac's and theirs named; another machine's text drawn as the mirror
	// cleaned it; an offline machine's sessions left out
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 2)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	state.machines[1] = {no = 4, name = "studio", status = .Offline}
	mirror :: proc(no: u64, title, need, msg: string, r: ^core.State, m: ^core.Machine_Mirror) {
		s := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/api"), title = strings.clone(title)}
		append(&s.tabs, dk_tab(10, need, 0, msg))
		s.active_tab = 10
		append(&r.open_sessions, s)
		core.mirror_merge(no, r, m)
	}
	r3, r4: core.State
	m3, m4: core.Machine_Mirror
	mirror(3, "Sch\x1b]0;owned\x07ema‮\nindex", "waiting", "Which\x1b[31m index?‮\x07", &r3, &m3)
	mirror(4, "Old one", "waiting", "", &r4, &m4)
	defer {
		core.mirror_unmerge(3)
		core.mirror_unmerge(4)
		core.mirror_free(&m3)
		core.mirror_free(&m4)
		core.replica_free(&r3, runtime.heap_allocator())
		core.replica_free(&r4, runtime.heap_allocator())
		dk_reset()
	}
	cmds = ui_layout(1600, 900)
	nuc, offline: u64
	for x in state.open_sessions do if x.machine == 3 do nuc = x.id
	for x in state.open_sessions do if x.machine == 4 do offline = x.id
	ids := dk_drawn()
	// nuc's waiting session under NEEDS YOU (after those whose wait has a known start); studio's left out
	testing.expectf(t, len(ids) == 5 && ids[2] == nuc && deck_rows()[2].group == .Needs_You, "nuc's, studio's left out: %v", ids)
	for id in ids do testing.expect(t, id != offline, "no offline machine's card")
	cn := card(t, cmds, nuc)
	testing.expectf(t, strings.has_suffix(cn, "\npi\nnuc\n") && strings.contains(cn, "Sch") && strings.contains(cn, "index?"), "%q", cn)
	for bad in ([]string{"\x1b", "\x07", "‮"}) do testing.expectf(t, !strings.contains(cn, bad), "cleaned: %q", cn)
	testing.expectf(t, strings.contains(card(t, cmds, 100), "\nClaude Code\nthis Mac\n3 tabs\n"), "the machine as a chip: %q", card(t, cmds, 100))
	bn, _ := dk_card(nuc)
	testing.expect(t, dk_text_color(cmds, bn, "nuc") == th.text_secondary, "the chip's text")
	// another machine's card has no "…" (its row has no menu): hovered, its age stays
	ui_hover = Hit_Deck_Card(nuc)
	_ = ui_layout(1600, 900)
	_, more := dk_box("deckmore", 0)
	testing.expect(t, !more, "no … on another machine's card")
	ui_hover = Hit_Deck_Card(100)
	_ = ui_layout(1600, 900)
	k := -1
	for c, i in deck.cards do if c.sid == 100 do k = i
	_, more = dk_box("deckmore", u32(k))
	testing.expect(t, more, "this Mac's card: its …")
	ui_hover = nil
}

// A click or Enter goes there and leaves the deck; the arrows move across the grid and scroll the
// card into view; Esc goes back; typing never reaches the terminal under it.
@(test)
deck_keys_and_clicks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dk_reset()
	defer dk_reset()
	for i in u64(0) ..< 3 do dk_session(100 + i * 100, fmt.tprintf("Ask %d", i), dk_tab(101 + i * 100, "waiting", time.Duration(30 - i) * time.Minute))
	for i in u64(0) ..< 5 do dk_session(1000 + i * 100, fmt.tprintf("Job %d", i), dk_tab(1001 + i * 100, "working", time.Duration(30 - i) * time.Minute))
	state.layout.right_open = false
	dk_toggle()
	_ = ui_layout(1300, 800)
	testing.expect(t, deck.cols >= 2, "two columns or more")
	cards := deck.cards[:]
	testing.expect(t, dk_key(.DOWN), "taken")
	testing.expect_value(t, deck.sel, cards[0].sid) // the first arrow: the first card (no current session)
	dk_key(.RIGHT)
	testing.expect_value(t, deck.sel, cards[1].sid)
	dk_key(.LEFT)
	dk_key(.LEFT)
	testing.expect_value(t, deck.sel, cards[0].sid) // stays at the first
	// down from the needs-you row's last card: the next row, the nearest column
	dk_key(.RIGHT)
	dk_key(.RIGHT)
	at := deck.sel
	from := -1
	for c, i in cards do if c.sid == at do from = i
	dk_key(.DOWN)
	to := -1
	for c, i in cards do if c.sid == deck.sel do to = i
	testing.expectf(t, from >= 0 && to >= 0 && cards[to].row == cards[from].row + 1 && cards[to].col <= cards[from].col, "down: %v to %v", cards[from], cards[to])
	dk_key(.UP)
	testing.expectf(t, cards[0].row == 0 && deck.sel != 0, "up again")
	// Enter: that session, on its waiting tab; the deck goes
	dk_key(.UP)
	sel := deck.sel
	dk_key(.ENTER)
	core.inbox_drain()
	testing.expect(t, !dk_shown(), "Enter leaves the deck")
	testing.expect_value(t, state.current_session, sel)
	_ = ui_layout(1300, 800)

	// a click on a card (its hit, then the window's click: main.odin): there
	dk_toggle()
	_ = ui_layout(1300, 800)
	b, _ := dk_box("deckcard", 4)
	clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
	h := ui_hit()
	testing.expectf(t, h == Hit(Hit_Deck_Card(deck.cards[4].sid)), "hit %v", h)
	label, _ := hit_tip(h)
	testing.expectf(t, strings.contains(label, "working"), "tip: %q", label)
	want := deck.cards[4].sid
	ev := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = b.x + b.width / 2, mouse_y = b.y + b.height / 2}
	event(&ev)
	core.inbox_drain()
	testing.expect(t, !dk_shown(), "a click leaves the deck")
	testing.expect_value(t, state.current_session, want)
	testing.expect_value(t, core.find_session(want).active_tab, want + 1)

	// Esc goes back to the session it was opened from; ⌘ chords and other keys go on (no session
	// is current: they reach no tab; deck_modal_test.odin)
	_ = ui_layout(1300, 800)
	dk_toggle()
	_ = ui_layout(1300, 800)
	testing.expect(t, !dk_key(.C, u32(sapp.MODIFIER_CTRL)), "⌃C: not the deck's")
	testing.expect(t, !dk_key(.W, u32(sapp.MODIFIER_SUPER)), "⌘W: not the deck's")
	testing.expect(t, dk_shown(), "still shown")
	dk_key(.ESCAPE)
	testing.expect(t, !dk_shown(), "Esc goes back")
	testing.expect_value(t, state.current_session, want)
	testing.expect_value(t, state.focus_widget, "") // the keys are the tabs' again

	// many cards in a short window: ↓ to the last one scrolls it into the grid's view
	for i in u64(0) ..< 30 do dk_session(5000 + i * 10, fmt.tprintf("More %d", i), dk_tab(5001 + i * 10, "working", time.Duration(60 - i) * time.Minute))
	dk_toggle()
	for _ in 0 ..< 3 do _ = ui_layout(1300, 500)
	for _ in 0 ..< 30 {
		dk_key(.DOWN)
		_ = ui_layout(1300, 500)
	}
	for _ in 0 ..< 3 do _ = ui_layout(1300, 500)
	k := -1
	for c, i in deck.cards do if c.sid == deck.sel do k = i
	testing.expect(t, k >= 0 && deck.cards[k].row == deck.cards[len(deck.cards) - 1].row, "the last row reached")
	grid, _ := dk_box("deckscroll")
	cb, _ := dk_box("deckcard", u32(max(k, 0)))
	testing.expectf(t, cb.y >= grid.y - 0.5 && cb.y + cb.height <= grid.y + grid.height + 0.5, "the keyboard's card in view: %v in %v", cb, grid)
	// no growth from frame to frame: the list keeps its room
	n := cap(deck.cards)
	for _ in 0 ..< 5 do _ = ui_layout(1300, 500)
	testing.expect_value(t, cap(deck.cards), n)
}

// Another session or tab on screen by any other means (its row, ⌥⌘A, a notification) closes the
// deck; the action, its key, its button and menu item; window state only (no command); with no
// session open it takes the empty centre's place; with none at all, what to do.
@(test)
deck_toggle_and_navigation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dk_reset()
	defer dk_reset()
	dk_session(100, "Login page", dk_tab(101, "waiting", time.Minute))
	dk_session(200, "Relay", dk_tab(201, "working", time.Minute), dk_tab(202))
	state.current_session = 100
	// the action: ⇧⌘\, View › Deck view, the palette, the top bar's button
	testing.expect_value(t, menubar_key_action(.BACKSLASH, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT)), "deck_view")
	it := menubar_find("deck_view")
	testing.expect(t, it != nil && menubar_keys(it) == "⇧⌘\\" && menubar_item_title(it) == "Deck view", "View › Deck view ⇧⌘\\")
	k, ok := parse_keys("⇧⌘\\")
	testing.expect(t, ok && k.code == .BACKSLASH && k.equiv == "\\", "the key")
	found := false
	for a in ACTIONS do if a.id == "deck_view" && a.label == "Toggle Deck view" && !a.no_palette do found = true
	testing.expect(t, found, "the palette's Toggle Deck view")
	_ = ui_layout(1600, 900)
	b, shown := dk_box("deckbtn")
	testing.expect(t, shown, "its button in the top bar")
	clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
	testing.expect(t, ui_hit() == Hit(Hit_Button(.Deck)), "the button's hit")
	core.inbox_drain()
	button_click(.Deck)
	testing.expect(t, dk_shown(), "the button shows it")
	cmd, applies := action_by_id("deck_view").make()
	testing.expect(t, applies && cmd == nil, "no command: the window's own")
	action_run("deck_view")
	testing.expect(t, !dk_shown(), "again: back")

	testing.expect_value(t, state.current_session, u64(100)) // back where it was opened

	// its row clicked (also the session it was opened from): the deck goes
	action_run("deck_view")
	core.inbox_drain() // the frame runs it before its layout
	_ = ui_layout(1600, 900)
	testing.expect(t, dk_shown(), "shown")
	testing.expect_value(t, state.current_session, u64(0)) // no session current while it shows
	ui_do(core.Focus_Session{session = 100})
	testing.expect(t, !dk_shown(), "a row's click")
	_ = ui_layout(1600, 900)
	testing.expect(t, !deck.on, "ended")
	// another session shown (⌥⌘A from the core, a notification): the deck goes
	action_run("deck_view")
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, dk_shown(), "shown")
	ui_do(core.Focus_Session{session = 200})
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, !dk_shown() && !deck.on, "another session on screen")

	// opened with no session shown (none current, none taken off screen by it): in the empty
	// centre's place, its summary line and buttons kept
	state.current_session = 0
	_ = ui_layout(1600, 900)
	_, rows := dk_box("fleetrow", 0)
	testing.expect(t, rows, "the empty centre's rows without the deck")
	action_run("deck_view")
	core.inbox_drain() // the frame runs it before its layout
	cmds := ui_layout(1600, 900)
	_, rows = dk_box("fleetrow", 0)
	testing.expect(t, !rows, "the deck in their place")
	dk, _ := dk_box("deck")
	text := dk_texts(cmds, dk)
	testing.expectf(t, strings.contains(text, "2 sessions · 1 needs you · 1 working\n") && strings.contains(text, "Go to next\n⌥⌘A\n") && strings.contains(text, "Add project…\n"), "%q", text)
	testing.expect_value(t, len(deck.cards), 2)
	for c, i in deck.cards {
		cb, _ := dk_box("deckcard", u32(i))
		col, found := dk_border(cmds, cb)
		testing.expectf(t, !found || col != theme().accent, "card %d not outlined: no session on screen", c.sid)
	}
	// nothing open at all: the deck's icon, what to do and the buttons, centred
	clear(&state.open_sessions)
	cmds = ui_layout(1600, 900)
	dk, _ = dk_box("deck")
	text = dk_texts(cmds, dk)
	testing.expectf(t, strings.has_prefix(text, "No sessions open\nStart a chat or open a project.") && strings.has_suffix(text, "online.\nAdd project…\n"), "%q", text) // (no chats folder here: no New chat)
	testing.expect_value(t, len(deck.cards), 0)
	empty, _ := dk_box("deckempty")
	mid := empty.x + empty.width / 2
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		bb := c.boundingBox
		if (c.commandType == .Text || c.commandType == .Custom) && dk_in(bb, empty) && !strings.has_prefix(dk_texts(cmds, bb), "Add") && !strings.has_prefix(dk_texts(cmds, bb), "New") do testing.expectf(t, abs(bb.x + bb.width / 2 - mid) <= 1, "centred: %v in %v", bb, empty)
	}
}

// The layout's cards: each DECK_CARD_W wide (one column: its own width, up to DECK_CARD_W_ONE) and
// its group's height, inside the deck, apart from every other card, its texts and icons inside it.
// Problems counted in problems (the first 40 reported).
@(private = "file")
dk_cards_ok :: proc(t: ^testing.T, cmds: clay.ClayArray(clay.RenderCommand), where_: string, problems: ^int) {
	bad :: proc(t: ^testing.T, problems: ^int, msg: string) {
		problems^ += 1
		if problems^ <= 40 do testing.expectf(t, false, "%s", msg)
	}
	dk, _ := dk_box("deck")
	grid, _ := dk_box("deckscroll")
	rows := deck_rows()
	if len(rows) != len(deck.cards) {
		bad(t, problems, fmt.tprintf("%s: %d cards for %d rows", where_, len(deck.cards), len(rows)))
		return
	}
	want_w := deck.cols == 1 ? deck_card_w(centre_width() - 2 * px(DECK_PAD), 1) : px(DECK_CARD_W)
	for _, i in deck.cards {
		b, _ := dk_box("deckcard", u32(i))
		if b.width != want_w || b.height != deck_card_h(rows[i].group) || b.x < dk.x - 0.5 || b.x + b.width > dk.x + dk.width + 0.5 {
			bad(t, problems, fmt.tprintf("%s: card %d %v (%v; width %v, deck %v)", where_, i, b, rows[i].group, want_w, dk))
		}
		for j in 0 ..< i {
			o, _ := dk_box("deckcard", u32(j))
			if b.x < o.x + o.width + px(DECK_GAP) - 0.5 && o.x < b.x + b.width + px(DECK_GAP) - 0.5 && b.y < o.y + o.height + px(DECK_GAP) - 0.5 && o.y < b.y + b.height + px(DECK_GAP) - 0.5 {
				bad(t, problems, fmt.tprintf("%s: cards %d and %d closer than the gap: %v %v", where_, j, i, o, b))
			}
		}
		if b.y < grid.y || b.y + b.height > grid.y + grid.height do continue // scrolled out of view
		for j in 0 ..< cmds.length {
			c := &cmds.internalArray[j]
			x := c.boundingBox
			if c.commandType != .Text && c.commandType != .Custom do continue
			if x.x < b.x || x.x >= b.x + b.width || x.y < b.y || x.y >= b.y + b.height do continue
			if !dk_in(x, b) do bad(t, problems, fmt.tprintf("%s: card %d spills: %v in %v", where_, i, x, b))
		}
	}
}

@(private = "file")
dk_report :: proc(t: ^testing.T, bad: []string, problems: ^int) {
	for b in bad {
		problems^ += 1
		if problems^ <= 40 do testing.expectf(t, false, "%s", b)
	}
}

// The layout audit: the deck at the narrowest centre (one column) to a wide one (four or more), in
// every look, light and dark, every text size, a card hovered (its Peek and "…") and the
// keyboard's: nothing overlaps or spills; every card its width and its group's height, inside the
// deck; the marks turn while shown.
@(test)
deck_layout_audit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dk_reset()
	defer {
		state.settings.text_size = .Default
		fonts_apply(theme_font_config(theme()), 1)
		if x := core.terms[101]; x != nil do free(x)
		delete_key(&core.terms, 101)
		dk_reset()
	}
	s := dk_session(100, "Login page with a rather long title that has to be cut", dk_tab(101, "waiting", 3 * time.Minute, "Apply these edits to the login form and its tests? They touch twelve files across the app"), dk_tab(102, "working"), dk_tab(103, "unseen"))
	s.agent = .Claude
	s.tabs[0].has_term = true // it can be peeked (the core has its terminal): its Peek shows while hovered
	core.terms[101] = new(core.Term)
	dk_session(200, "Relay", dk_tab(201, "working", 12 * time.Hour))
	dk_session(300, "Quiet", dk_tab(301))
	dk_session(400, "Crash", dk_tab(401, "error", 2 * time.Minute, "exit 1"))
	dk_session(500, "Bump deps", dk_tab(501, "unseen", time.Minute))
	for i in u64(0) ..< 6 do dk_session(1000 + i * 10, fmt.tprintf("Job %d", i), dk_tab(1001 + i * 10, "working", time.Duration(i + 1) * time.Minute))
	state.current_session = 200
	dk_toggle()
	problems := 0
	for size in TEXT_SIZE_ORDER {
		state.settings.text_size = size
		fonts_apply(theme_font_config(theme()), 1)
		for look in core.Theme_Id do for light in ([]bool{false, true}) {
			if size != .Default && (look != .Graphite || light) do continue
			state.settings.theme = look
			state.settings.appearance = light ? .Light : .Dark
			for w in AUDIT_WIDTHS {
				for cols in 0 ..< 2 { 	// the columns open (the narrowest centre) and closed
					state.layout.left_open, state.layout.right_open = cols == 0, cols == 0
					for hv in ([]Hit{nil, Hit_Deck_Card(100), Hit_Deck_More(100), Hit_Peek_Row(100)}) {
						ui_hover = hv
						deck.sel = hv == nil ? 300 : 0
						cmds := ui_layout(w, AUDIT_H)
						where_ := fmt.tprintf("deck %v %v %s w=%v columns=%v hover %v", size, look, light ? "light" : "dark", w, cols == 0, hv)
						dk_report(t, audit(cmds, where_, w)[:], &problems)
						dk_cards_ok(t, cmds, where_, &problems)
						if hv != nil {
							_, peek_shown := dk_box("deckpeek", 0)
							testing.expectf(t, peek_shown, "%s: its Peek", where_)
						}
						if cols == 0 && w == WINDOW_MIN_W do testing.expectf(t, deck.cols == 1, "%s: one column, %d", where_, deck.cols)
						if cols == 1 && w == 2000 do testing.expectf(t, deck.cols >= 4, "%s: four columns or more, %d", where_, deck.cols)
					}
				}
			}
		}
	}
	ui_hover = nil
	testing.expectf(t, problems == 0, "%d layout problems", problems)
	// motion: a working mark turns while the deck shows it
	state.settings.reduce_motion = false
	state.layout.left_open, state.layout.right_open = true, true
	_ = ui_layout(1600, AUDIT_H)
	testing.expect(t, ui_spinning(), "the working marks turn")
	state.settings.reduce_motion = true
}

// 1, 6 and 30 sessions (mixed states, a long title and question, several tabs) at the narrowest
// centre and a wide one, the keyboard's card on the first and the last: nothing overlaps or
// spills, cards keep their width and their group's height; one session is one card at its width,
// never stretched.
@(test)
deck_layout_counts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dk_reset()
	defer dk_reset()
	needs := []string{"waiting", "error", "unseen", "working", ""}
	problems := 0
	for n in ([]int{1, 6, 30}) {
		dk_reset()
		for i in 0 ..< n {
			id := u64(100 + i * 10)
			need := needs[i % len(needs)]
			title := i % 3 == 0 ? "A session with a rather long title that is cut at the card's edge" : fmt.tprintf("Job %d", i)
			msg := i % 2 == 0 ? "Which index should orders use: (created_at) alone, or (customer_id, created_at)? The second makes the account page six times faster" : ""
			if i % 4 == 1 do dk_session(id, title, dk_tab(id + 1, need, time.Duration(i + 1) * time.Minute, msg), dk_tab(id + 2, "working"), dk_tab(id + 3))
			else do dk_session(id, title, dk_tab(id + 1, need, time.Duration(i + 1) * time.Minute, msg))
		}
		dk_toggle()
		for wide in ([]bool{false, true}) {
			state.layout.left_open, state.layout.right_open = !wide, !wide
			w := wide ? f32(2000) : WINDOW_MIN_W
			for sel in 0 ..< 2 {
				deck.sel = state.open_sessions[sel == 0 ? 0 : n - 1].id
				deck.scroll = true
				for _ in 0 ..< 2 do _ = ui_layout(w, AUDIT_H)
				cmds := ui_layout(w, AUDIT_H)
				where_ := fmt.tprintf("deck n=%d w=%v sel=%d", n, w, sel)
				dk_report(t, audit(cmds, where_, w)[:], &problems)
				dk_cards_ok(t, cmds, where_, &problems)
				testing.expectf(t, len(deck.cards) == n, "%s: %d cards", where_, len(deck.cards))
				if n == 1 {
					b, _ := dk_box("deckcard", 0)
					want := wide ? f32(DECK_CARD_W) : deck_card_w(centre_width() - 2 * px(DECK_PAD), 1)
					testing.expectf(t, b.width == want, "%s: one card, %v wide (want %v)", where_, b.width, want)
				}
			}
		}
		dk_toggle()
	}
	testing.expectf(t, problems == 0, "%d layout problems", problems)
}

// A card's harness is the session's: pi, Claude Code or Codex (a Claude session whose main tab is
// Codex's: no longer "Claude Code"); its Peek (hovered) is the look-only peek's, hit as a row's eye
// (nothing reaches a terminal; the deck stays); the keyboard's card has a 2 px accent ring outside
// it, the session it was opened from a 1 px accent outline inside it.
@(test)
deck_card_harness_peek_and_ring :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dk_reset()
	terms: [dynamic]u64
	defer {
		peek_close()
		for id in terms {
			if x := core.terms[id]; x != nil do free(x)
			delete_key(&core.terms, id)
		}
		delete(terms)
		dk_reset()
	}
	th := theme()
	pi := dk_session(100, "Pi one", dk_tab(101, "working", time.Minute))
	_ = pi
	cl := dk_tab(201, "working", time.Minute)
	cl.kind = core.Claude_Tab{}
	c := dk_session(200, "Claude one", cl)
	c.agent = .Claude
	cx := dk_tab(301, "waiting", time.Minute, "Run the migration?")
	cx.kind = core.Claude_Tab{codex = true}
	cx.has_term = true
	x := dk_session(300, "Codex one", cx)
	x.agent = .Claude
	core.terms[301] = new(core.Term)
	append(&terms, 301)
	testing.expect_value(t, core.open_session_harness(core.find_session(100)), core.Harness.Pi)
	testing.expect_value(t, core.open_session_harness(core.find_session(200)), core.Harness.Claude)
	testing.expect_value(t, core.open_session_harness(core.find_session(300)), core.Harness.Codex)
	state.current_session = 200
	dk_toggle()
	cmds := ui_layout(1600, 900)
	for want, i in ([3]string{"pi", "Claude Code", "Codex"}) {
		b, _ := dk_card(u64(100 * (i + 1)))
		text := dk_texts(cmds, b)
		testing.expectf(t, strings.contains(text, fmt.tprintf("\n%s\n", want)), "%s: %q", want, text)
	}
	bx, _ := dk_card(300)
	testing.expect(t, !strings.contains(dk_texts(cmds, bx), "Claude Code"), "a Codex session is not Claude Code")
	glyph := false
	for i in 0 ..< cmds.length {
		cmd := &cmds.internalArray[i]
		if cmd.commandType != .Custom || !dk_in(cmd.boundingBox, bx) do continue
		if ic, _, _ := icon_of_command(cmd); ic == .Harness_Codex do glyph = true
	}
	testing.expect(t, glyph, "Codex's glyph")

	// the keyboard's card: a 2 px accent ring DECK_RING_GAP outside it; the session it was opened
	// from (200): 1 px inside
	deck.sel = 300
	cmds = ui_layout(1600, 900)
	bx, _ = dk_card(300)
	o := px(DECK_RING + DECK_RING_GAP)
	ring := clay.BoundingBox{bx.x - o, bx.y - o, bx.width + 2 * o, bx.height + 2 * o}
	found := false
	for i in 0 ..< cmds.length {
		cmd := &cmds.internalArray[i]
		if cmd.commandType == .Border && cmd.boundingBox == ring {
			found = true
			testing.expect(t, to_rgba(cmd.renderData.border.color) == th.accent && cmd.renderData.border.width.left == u16(DECK_RING), "the ring: 2 px of the accent")
		}
	}
	testing.expect(t, found, "the keyboard's ring")
	b200, _ := dk_card(200)
	under := false
	for i in 0 ..< cmds.length {
		cmd := &cmds.internalArray[i]
		if cmd.commandType == .Border && cmd.boundingBox == b200 do under = to_rgba(cmd.renderData.border.color) == th.accent && cmd.renderData.border.width.left == u16(core.BORDER_W)
	}
	testing.expect(t, under, "the session it was opened from: 1 px, inside")
	_, ring_on_200 := dk_box("deckring", 0)
	for c2, i in deck.cards do if c2.sid == 200 {
		_, ring_on_200 = dk_box("deckring", u32(i))
	}
	testing.expect(t, !ring_on_200, "no ring on a card the keyboard is not on")

	// hovered: Peek and "…" in its age's place; another card, neither
	deck.sel = 0
	ui_hover = Hit_Deck_Card(300)
	cmds = ui_layout(1600, 900)
	k := -1
	for c2, i in deck.cards do if c2.sid == 300 do k = i
	pb, peek_shown := dk_box("deckpeek", u32(k))
	_, more_shown := dk_box("deckmore", u32(k))
	testing.expect(t, peek_shown && more_shown, "hovered: Peek and …")
	testing.expect(t, !strings.contains(dk_texts(cmds, bx), "1m"), "its age gives way")
	_, pi_peek := dk_box("deckpeek", 0)
	testing.expect(t, deck.cards[0].sid == 300 || !pi_peek, "only the hovered card's Peek")
	// a card that cannot be peeked (no terminal): "…" only
	ui_hover = Hit_Deck_Card(200)
	_ = ui_layout(1600, 900)
	for c2, i in deck.cards do if c2.sid == 200 do k = i
	_, peek_shown = dk_box("deckpeek", u32(k))
	testing.expect(t, !peek_shown, "nothing to peek: no Peek")
	// its hit is a row's eye; its tip; a click peeks (look only) and the deck stays
	ui_hover = Hit_Deck_Card(300)
	_ = ui_layout(1600, 900)
	for c2, i in deck.cards do if c2.sid == 300 do k = i
	pb, _ = dk_box("deckpeek", u32(k))
	clay.SetPointerState({pb.x + pb.width / 2, pb.y + pb.height / 2}, false)
	h := ui_hit()
	testing.expectf(t, h == Hit(Hit_Peek_Row(300)), "Peek's hit: %v", h)
	label, _ := hit_tip(h)
	testing.expect_value(t, label, PEEK_ROW_TIP)
	ui_hover = h
	_ = ui_layout(1600, 900)
	_, peek_shown = dk_box("deckpeek", u32(k))
	testing.expect(t, peek_shown, "its Peek stays while the pointer is on it")
	ev := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = pb.x + pb.width / 2, mouse_y = pb.y + pb.height / 2}
	event(&ev)
	core.inbox_drain()
	testing.expect(t, peek_is_open() && peek.session == 300 && peek.tab == 301, "the peek opens on its tab")
	testing.expect(t, dk_shown(), "the deck stays under it")
	testing.expect_value(t, state.current_session, u64(0))
	ev.type = .MOUSE_UP
	event(&ev)
}
