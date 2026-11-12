package main

// The Deck view (⇧⌘\, View › Deck view, the top bar's four-cards button, the palette's Toggle
// Deck view): the centre as a grid of cards, one per open session on this Mac and on every online
// machine (Home excluded, as the fleet counts), so the whole fleet shows at a glance, in the empty
// centre's place (its summary line kept; its buttons too when it was opened with no session shown).
//
//	8 sessions · 2 need you · 1 finished · 3 working
//	NEEDS YOU  2 ─────────────────────────────────────────────────────────
//	┌──────────────────────────────┐ ┌──────────────────────────────┐
//	│ ⚿  web · Login page       3m │ │ ?  api · Schema           9m │
//	│ Apply these edits to the     │ │ Which index should orders    │
//	│ login form and its tests?    │ │ use: (created_at) alone, or… │
//	│ ✳ Claude Code [mac] ● 2 tabs │ │ π pi [nuc]                   │
//	└──────────────────────────────┘ └──────────────────────────────┘
//	WORKING  1 ───────────────────────────────────────────────────────────
//	…
//
// The cards follow the Attention view's order (core.attention_rows: needs you, finished, working,
// idle; ⌥⌘A's within them), each group under its label and a hairline on a row of its own. Every
// card is DECK_CARD_W wide (as many columns as fit, never stretched; one column: up to
// DECK_CARD_W_ONE). A card: the mark of the tab that placed it (session_tier_tab) with its place,
// title and how long its status has been so (the waiting or error colour while it needs you); that
// tab's message (the mirror's cleaned text for another machine's), else its status in plain words:
// two lines on a card that needs you, one on a working or finished one, none on an idle one; then
// the harness's glyph and name, the machine as a chip (only while other machines are in play) and,
// with more than one tab, what the others are doing as dots and "N tabs". A card that needs you is
// tinted with its status colour (an error's red, else waiting's) with a hairline of it; an idle
// one is quieter. A card's height depends only on its group (deck_card_h), so nothing moves while
// a status holds. The session it was opened from is outlined in the accent (1 px, inside); the
// keyboard's card has a DECK_RING accent ring outside it; a card flashes as its row does
// (status_flash, by session). Hovered: Peek (the look-only peek: ui_peek.odin) and "…" (this Mac's
// only: its row's menu) in its age's place.
//
// A click or Enter goes where its Attention row goes (attention_go); ←→↑↓ move the keyboard's card
// across the grid (scrolled into view); Esc, the toggle or the button goes back to the session it
// was opened from.
//
// The deck is the centre with no session shown (core Show_No_Session: none is current, as with
// none open), its cards in the empty centre's place. Every open session runs on; no pane is laid
// out, drawn, hit, typed into or seen, and nothing has to be told: there is no current session.
// The core remembers the session it took off screen (state.shown_before; saved as the current
// one, so a relaunch shows it; a reattached window shows the deck again). Going back is
// Focus_Session of it (still open: else the deck goes and the empty centre stays). Showing any
// session by any way (a card, its row, ⌥⌘A, a notification, an agent) ends it.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Hit_Deck_Card :: distinct u64 // a card: its open session id
Hit_Deck_More :: distinct u64 // a card's "…": its row's menu (open session id)
// (a card's Peek is Hit_Peek_Row, as a row's eye: main.odin opens the peek)

// A card as the last layout placed it: its session, its grid row (across every group) and column.
Deck_Card :: struct {
	sid:      u64,
	row, col: int,
}

Deck :: struct {
	on:     bool, // shows with no session under it: opened from the empty centre, or that session closed
	under:  bool, // the last layout's: a session under it (state.shown_before, still open)
	sel:    u64, // the keyboard's card (an open session id; 0: none yet)
	scroll: bool, // sel moved: into view after the layout that draws it (deck_scroll_to)
	top:    bool, // just opened: the grid from its top
	cards:  [dynamic]Deck_Card, // the last layout's, in order (hits, the keys); grows with the sessions only
	cols:   int, // the last layout's columns
}

deck: Deck

// Its button shows in the top bar (fleet_pill_decide: it gives way in a bar too narrow for it).
deck_btn_shown := true

// The deck with nothing open: what to do (as the empty centre says it).
DECK_EMPTY_TITLE :: "No sessions open"
DECK_EMPTY_TEXT :: "Start a chat or open a project. Sessions on your other machines show here too while they are online."
DECK_EMPTY_TOP :: 72 // above its icon
DECK_EMPTY_ICON :: 2 * ICON_SIZE
DECK_EMPTY_TEXT_W :: 340 // its words wrap at this width

// The session it was opened from (the core's state.shown_before: Show_No_Session), while open.
deck_under :: proc() -> u64 {
	if state.shown_before != 0 && find_session(state.shown_before) != nil do return state.shown_before
	return 0
}

// Whether the deck shows: no session current, and one taken off screen by it (the core keeps which,
// so a second window or a reattached one shows it too) or opened from the empty centre.
// Never under the Settings page, which shows in the same place (ui_settings_page.odin): one at a time.
deck_shown :: proc() -> bool {return core.cur_view() == nil && !spage.on && (deck_under() != 0 || deck.on)}

// Toggle Deck view (⇧⌘\, the top bar's button, View menu, palette). Pressed again before the core
// answered (a separate core): Show_No_Session again, which does nothing; the deck shows.
deck_toggle :: proc() {
	if deck_shown() {
		deck_back()
		return
	}
	peek_close() // one look at a time: the deck shows them all (ui_peek.odin)
	settings_page_off() // the Settings page gives way (the session under it stays under the deck)
	deck.sel, deck.scroll, deck.top = 0, false, true
	ui_hover = nil // the pane's hover is not the deck's
	if state.focus_widget != "" && state.focus_widget != "agent_input" do ui_do(core.Set_Focus{""}) // a field of the panes goes with them; the drawer's stays
	if core.cur_view() != nil do ui_do(core.Show_No_Session{})
	else do deck.on = true
	app.redraw = true
}

// Back to the session it was opened from (Esc, the toggle, the button), if it is still open; else
// the empty centre.
deck_back :: proc() {
	back := deck_under()
	deck.on, deck.sel = false, 0
	if back != 0 do ui_do(core.Focus_Session{session = back})
	app.redraw = true
}

// Each layout, first: a session shown (by any way) ends it; the session under it closed, it stays
// (Esc then leaves it for the empty centre).
deck_sync :: proc() {
	if core.cur_view() != nil {
		deck.on, deck.under = false, false
		return
	}
	under := deck_under() != 0
	if deck.under && !under && !spage.on do deck.on = true
	deck.under = under
}

// The columns that fit in w px (at least one): DECK_CARD_W cards, DECK_GAP apart.
deck_columns :: proc(w: f32) -> int {
	return max(1, int(math.floor((w + px(DECK_GAP)) / px(DECK_CARD_W + DECK_GAP))))
}

// A card's width for cols columns in w px: DECK_CARD_W, never stretched to fill; one column: up
// to DECK_CARD_W_ONE, and never wider than w (whole px: every card the same).
deck_card_w :: proc(w: f32, cols: int) -> f32 {
	if cols <= 1 do return math.floor(min(w, px(DECK_CARD_W_ONE)))
	return px(DECK_CARD_W)
}

@(private = "file")
line_h :: proc(weight: u16) -> f32 {
	kind, _ := font_id_split(weight)
	return text_line_height(kind)
}

// The title line's height: a line of body text, or the Peek and "…" buttons where they are taller.
@(private = "file")
title_h :: proc() -> f32 {return max(line_h(WEIGHT_REGULAR), px(ROW_BUTTON))}

// The meta line's height: a small line, or the harness's glyph where it is taller.
@(private = "file")
meta_h :: proc() -> f32 {return max(line_h(FONT_UI_SMALL), px(HARNESS_ICON_SIZE))}

// The lines of message a card of group g shows: needs you DECK_BODY_LINES, working and finished
// one, idle none.
deck_body_lines :: proc(g: core.Attention_Group) -> int {
	switch g {
	case .Needs_You:          return DECK_BODY_LINES
	case .Finished, .Working: return 1
	case .Idle:               return 0
	}
	return 0
}

// A card's height in group g: its padding, the title line, its message's lines (their room kept)
// and the meta line, SP_1 apart. It depends on the group only, so nothing moves while a status holds.
deck_card_h :: proc(g: core.Attention_Group) -> f32 {
	h := px(2 * DECK_CARD_PAD_Y + SP_1) + title_h() + meta_h()
	if n := deck_body_lines(g); n > 0 do h += px(SP_1) + f32(n) * line_h(WEIGHT_REGULAR)
	return h
}

// The cards in order (temp allocator): the Attention view's order, every session the fleet counts.
deck_rows :: proc() -> []core.Attention_Row {return core.attention_rows(deck = true)}

// The status a card shows: the tab that placed it in its group (as its Attention row), else (idle)
// the session's strongest.
@(private = "file")
card_view :: proc(r: core.Attention_Row) -> (v: core.Tab_Status_View, from: ^core.Tab) {
	if r.tier != core.NEED_NONE do from = core.session_tier_tab(r.session, r.tier)
	if from != nil do return core.tab_status_view(from^), from
	return core.session_row_view(r.session), nil
}

// The card's status in plain words, when its tab sends no message.
deck_words :: proc(v: core.Tab_Status_View) -> string {
	#partial switch v.dot {
	case .Waiting:  return "Waiting for you" // as its row says
	case .Question: return "Asked you a question"
	case .Error:    return "Stopped with an error"
	case .Unseen:   return "Finished"
	case .Running:
		if age := core.ago(v.since); age != "" && age != "now" do return fmt.tprintf("Working for %s", age)
		return "Working"
	case .Exited:   return "Exited"
	}
	return "Idle"
}

// The body: the tab's message (the mirror's cleaned text for another machine's), else its status
// in words.
deck_body :: proc(v: core.Tab_Status_View) -> string {
	if msg := strings.trim_space(v.msg); msg != "" do return msg
	return deck_words(v)
}

// The machine a card names in its chip while other machines are in play ("this Mac" or its name),
// else "".
deck_machine :: proc(s: ^core.Open_Session) -> string {
	if !(state.settings.remote_machines && len(state.machines) > 0) do return ""
	return s.machine == 0 ? "this Mac" : core.machine_name(s.machine)
}

// What the session's other tabs (not the card's own) are doing: a dot's colour for each status
// among them (waiting, error, finished, working), in that order; none: one quiet dot. Only with
// more than one tab (n 0: nothing to say).
deck_others :: proc(s: ^core.Open_Session, from: ^core.Tab) -> (dots: [4]core.Rgba, n: int) {
	if len(s.tabs) <= 1 do return
	th := theme()
	tiers := [5]int{}
	for &t in s.tabs do if &t != from do tiers[core.tab_tier(t)] += 1
	cols := [4]core.Rgba{th.waiting, th.error, status_color(.Unseen), th.running}
	for need, i in ([4]int{core.NEED_WAITING, core.NEED_ERROR, core.NEED_UNSEEN, core.NEED_WORKING}) do if tiers[need] > 0 {
		dots[n] = cols[i]
		n += 1
	}
	if n == 0 {
		dots[0] = with_alpha(th.text_muted, 0.45)
		n = 1
	}
	return
}

// "8 sessions · 2 need you · 1 finished · 3 working".
deck_summary :: proc(n: int) -> string {
	head := fmt.tprintf("%d %s", n, n == 1 ? "session" : "sessions")
	if words := fleet_words(fleet, " · "); words != "" do return fmt.tprintf("%s · %s", head, words)
	return head
}

// A card's fill and its hairline edge (alpha 0: none) by its group: needs you tinted with its
// status colour (err: the error's red, else waiting's), idle quieter, the others bg_elevated.
deck_fill :: proc(g: core.Attention_Group, err: bool) -> (fill, edge: core.Rgba) {
	th := theme()
	#partial switch g {
	case .Needs_You:
		c := err ? th.error : th.waiting
		c.a = 255
		return mix(th.bg_elevated, c, core.theme_is_light() ? DECK_TINT_LIGHT : DECK_TINT_DARK), with_alpha(c, DECK_EDGE_ALPHA)
	case .Idle:
		return mix(th.bg_elevated, th.bg_app, DECK_IDLE_FILL), {}
	}
	return th.bg_elevated, {}
}

// ---- layout ----

// The deck, in the centre's panes area (centre: ui.odin), while no session is current.
deck_layout :: proc() {
	th := theme()
	deck_scroll_to() // the keyboard's card moved: into view (by the last layout's boxes)
	if deck.top { 	// opened: from the top, wherever it was scrolled to the last time
		deck.top = false
		if sc := clay.GetScrollContainerData(clay.ID("deckscroll")); sc.found do sc.scrollPosition^ = {}
	}
	if deck.cards.allocator.procedure == nil do deck.cards.allocator = runtime.heap_allocator() // for the window's life
	clear(&deck.cards)
	rows := deck_rows()
	pad := px(DECK_PAD)
	inner := centre_width() - 2 * pad
	cols := deck_columns(inner)
	deck.cols = cols
	cw := deck_card_w(inner, cols)
	if clay.UI(clay.ID("deck"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}, backgroundColor = cc(th.bg_app)}) {
		if len(rows) == 0 {
			deck_empty(inner)
			return
		}
		// the summary line; opened with no session shown, the empty centre's buttons under it
		if clay.UI(clay.ID("deckhead"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(DECK_PAD), pu(DECK_PAD), pu(DECK_PAD), pu(SP_2)}, childGap = pu(SP_3), layoutDirection = .TopToBottom}}) {
			clay.TextDynamic(clip(deck_summary(len(rows)), inner), txt(th.text_secondary))
			if deck_under() == 0 do deck_buttons(inner)
		}
		if clay.UI(clay.ID("deckscroll"))({
			// SP_1 above the first row: room for the keyboard's ring (DECK_RING_GAP + DECK_RING)
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, padding = {pu(DECK_PAD), pu(DECK_PAD), pu(SP_1), pu(DECK_PAD)}, childGap = pu(DECK_GAP), layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			// each group under its label, cols cards a row (rows are in group order: core.attention_rows)
			grid_row := 0
			for at := 0; at < len(rows); {
				g := rows[at].group
				end := at
				for end < len(rows) && rows[end].group == g do end += 1
				deck_label(g, end - at, at == 0, inner)
				ch := deck_card_h(g)
				for start := at; start < end; start += cols {
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(DECK_GAP)}}) {
						for k in start ..< min(start + cols, end) {
							append(&deck.cards, Deck_Card{sid = rows[k].session.id, row = grid_row, col = k - start})
							deck_card(rows[k], k, cw, ch)
						}
					}
					grid_row += 1
				}
				at = end
			}
		}
	}
}

// Nothing open: the deck's icon, what to do, and the empty centre's buttons, centred.
@(private = "file")
deck_empty :: proc(room: f32) {
	th := theme()
	if clay.UI(clay.ID("deckempty"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(DECK_PAD), pu(DECK_PAD), pu(DECK_EMPTY_TOP), pu(DECK_PAD)}, childGap = pu(SP_3), childAlignment = {x = .Center}, layoutDirection = .TopToBottom}}) {
		icon(.Deck, th.text_muted, DECK_EMPTY_ICON)
		clay.TextDynamic(clip(DECK_EMPTY_TITLE, room, WEIGHT_HEADER), txt(th.text, WEIGHT_HEADER))
		lines, _ := wrap_clip(DECK_EMPTY_TEXT, min(room, px(DECK_EMPTY_TEXT_W)), 4)
		cfg := txt(th.text_secondary)
		cfg.wrapMode = .Newlines
		cfg.textAlignment = .Center
		clay.TextDynamic(lines, cfg)
		deck_buttons(room)
	}
}

// The empty centre's buttons: Go to next (while something needs you), New chat, Add project…;
// side by side while they fit, else one under the other.
@(private = "file")
deck_buttons :: proc(room: f32) {
	next := core.fleet_need(fleet) + fleet.unseen > 0
	chat := button_enabled(.Empty_New_Chat)
	w := text_w("Add project…") + px(2 * SP_3)
	if chat do w += text_w("New chat", next ? WEIGHT_REGULAR : WEIGHT_BOLD) + px(2 * SP_3 + SP_2)
	if next do w += text_w("Go to next", WEIGHT_BOLD) + text_w("⌥⌘A", FONT_UI_SMALL) + px(2 * SP_3 + SP_2 + SP_2)
	if clay.UI()({layout = {childGap = pu(SP_2), layoutDirection = w <= room ? .LeftToRight : .TopToBottom}}) {
		if next do button(clay.ID(BUTTONS[.Empty_Next].element), "Go to next", true, ui_hover == Hit(Hit_Button(.Empty_Next)), "⌥⌘A")
		if chat do action_button(.Empty_New_Chat, !next)
		action_button(.Empty_Add_Project, false)
	}
}

// A group's label on a row of its own: "NEEDS YOU  2" in the Attention view's headers' style, then
// a hairline across the rest of the row.
@(private = "file")
deck_label :: proc(g: core.Attention_Group, n: int, first: bool, room: f32) {
	th := theme()
	// a little more room above a group than between its rows (none above the first)
	top := first ? 0 : pu(SP_2)
	if clay.UI(clay.ID("decklabel", u32(g)))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {0, 0, top, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
		clay.TextDynamic(ATTENTION_LABELS[g], txt(th.text_muted, FONT_UI_SMALL | WEIGHT_HEADER))
		clay.TextDynamic(fmt.tprint(n), txt(g == .Needs_You ? th.waiting : th.text_muted, FONT_UI_SMALL))
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}}, backgroundColor = cc(th.border)}) {}
	}
}

// One card, w by h px (its group's height): see the top of this file.
@(private = "file")
deck_card :: proc(r: core.Attention_Row, i: int, w, h: f32) {
	th := theme()
	s := r.session
	g := r.group
	id := clay.ID("deckcard", u32(i))
	more_id := clay.ID("deckmore", u32(i))
	v, from := card_view(r)
	remote := s.machine != 0
	need := g == .Needs_You
	err := need && r.tier == core.NEED_ERROR
	current := s.id == deck_under() // the session it was opened from
	can_peek := peek_tab_of(s) != nil // the look-only peek (ui_peek.odin): this Mac's and an online machine's
	more_hover := !remote && ui_hover == Hit(Hit_Deck_More(s.id))
	peek_hover := can_peek && ui_hover == Hit(Hit_Peek_Row(s.id))
	hovered := ui_hover == Hit(Hit_Deck_Card(s.id)) || more_hover || peek_hover
	key_sel := s.id == deck.sel
	// its group's fill; hovered: lifted by the hover tint; a status turning: the row's flash
	fill, edge := deck_fill(g, err)
	if current do edge = th.accent
	lift := fade(id, 0, hovered ? 1 : 0, DUR_HOVER)
	lit := status_flash(id, s.id ~ SALT_FLASH_ROW, v, s.machine)
	bg := flash_wash(cc(mix(fill, {th.hover.r, th.hover.g, th.hover.b, 255}, lift * f32(th.hover.a) / 255)), v.dot, lit)
	room := w - 2 * px(DECK_CARD_PAD)
	small := FONT_UI_SMALL
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}, padding = {pu(DECK_CARD_PAD), pu(DECK_CARD_PAD), pu(DECK_CARD_PAD_Y), pu(DECK_CARD_PAD_Y)}, childGap = pu(SP_1), layoutDirection = .TopToBottom},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(edge), width = edge.a > 0 ? clay.BorderOutside(pu(core.BORDER_W)) : {}}, // Outside: BorderAll also rules a line between every child
	}) {
		// the keyboard's card: a ring outside it (in the gap around it; clipped with the grid)
		if key_sel {
			o := px(DECK_RING + DECK_RING_GAP)
			if clay.UI(clay.ID("deckring", u32(i)))({
				layout = {sizing = {clay.SizingFixed(w + 2 * o), clay.SizingFixed(h + 2 * o)}},
				floating = {attachTo = .Parent, offset = {-o, -o}, pointerCaptureMode = .Passthrough, clipTo = .AttachedParent},
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD) + o),
				border = {color = cc(th.accent), width = clay.BorderOutside(pu(DECK_RING))},
			}) {}
		}
		// mark, [place ·] title, then how long it has been so, or (hovered) Peek and "…" in its place
		age := status_age(v)
		if age == "" && r.tier == core.NEED_NONE && !remote do age = core.open_session_age(s)
		// the right box: as wide as both buttons whatever it shows, so the title never moves
		right := max(text_w("00m", small), 2 * px(ROW_BUTTON) + px(SP_1))
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(title_h())}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
			status_mark_el(v, lit)
			ic, place := core.session_place(s)
			title := core.open_session_title(s)
			// the room the texts share: less the mark, the right box and the gaps between the parts
			// (mark, [place,] title, spacer, right box)
			left := room - px(MARK) - right - f32(ic != .Chat ? 4 : 3) * px(SP_2)
			if ic != .Chat {
				// the place keeps 40% of the room, or all it needs (as the rows' does)
				lead := fmt.tprintf("%s ·", place)
				pw := min(text_w(lead), max(left * 0.4, left - text_w(title, WEIGHT_HEADER)))
				clay.TextDynamic(clip(lead, pw), txt(th.text_muted))
				left -= pw
			}
			if g == .Idle do clay.TextDynamic(clip(title, left), txt(th.text_secondary))
			else do clay.TextDynamic(clip(title, left, WEIGHT_HEADER), txt(th.text, WEIGHT_HEADER))
			spacer()
			if clay.UI()({layout = {sizing = {clay.SizingFixed(right), clay.SizingFit()}, childGap = pu(SP_1), childAlignment = {x = .Right, y = .Center}}}) {
				if hovered && (can_peek || !remote) {
					if can_peek do peek_row_button(clay.ID("deckpeek", u32(i)), true, peek_hover)
					if !remote {
						mbg, _ := overlay(more_id, false, more_hover)
						if clay.UI(more_id)({
							layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
							backgroundColor = mbg,
							cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
						}) {
							icon(.More, more_hover ? th.text : th.text_muted, ICON_SIZE_SM)
						}
					}
				} else if age != "" {
					age_col := err ? th.error : (need ? th.waiting : th.text_muted)
					clay.TextDynamic(clip(age, right, small), txt(age_col, small))
				}
			}
		}
		// the message: its group's lines (their room kept); body text while it needs you
		if n := deck_body_lines(g); n > 0 {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(f32(n) * line_h(WEIGHT_REGULAR))}}}) {
				lines, _ := wrap_clip(deck_body(v), room, n)
				cfg := txt(need ? th.text : th.text_secondary)
				cfg.wrapMode = .Newlines
				clay.TextDynamic(lines, cfg)
			}
		}
		deck_meta_line(s, from, room)
	}
}

// A card's last line: the harness's glyph and name, the machine's chip (while other machines are
// in play), then (more than one tab) what the others do as dots and "N tabs".
@(private = "file")
deck_meta_line :: proc(s: ^core.Open_Session, from: ^core.Tab, room: f32) {
	th := theme()
	small := FONT_UI_SMALL
	harness := core.HARNESSES[core.open_session_harness(s)]
	mach := deck_machine(s)
	dots, ndots := deck_others(s, from)
	tabs := ndots > 0 ? fmt.tprintf("%d tabs", len(s.tabs)) : ""
	// the parts: glyph, name, [chip,] spacer, [dots and tabs]
	parts := 3 + (mach != "" ? 1 : 0) + (ndots > 0 ? 1 : 0)
	tabs_w := ndots > 0 ? f32(ndots) * px(DOT + SP_1) + text_w(tabs, small) : 0
	left := room - px(HARNESS_ICON_SIZE) - tabs_w - f32(parts - 1) * px(GAP_INLINE)
	chip_w: f32
	if mach != "" do chip_w = max(0, min(text_w(mach, small) + px(2 * SP_1), max(left * 0.5, left - text_w(harness.name, small))))
	name_w := max(0, left - chip_w)
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(meta_h())}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}}}) {
		icon(harness.glyph, th.text_muted, HARNESS_ICON_SIZE)
		clay.TextDynamic(clip(harness.name, name_w, small), txt(th.text_muted, small))
		if mach != "" {
			if clay.UI()({layout = {sizing = {clay.SizingFixed(chip_w), clay.SizingFit()}, padding = {pu(SP_1), pu(SP_1), 0, 0}}, backgroundColor = cc(th.selected), cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM))}) {
				clay.TextDynamic(clip(mach, chip_w - px(2 * SP_1), small), txt(th.text_secondary, small))
			}
		}
		spacer()
		if ndots > 0 {
			if clay.UI()({layout = {childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
				for c in dots[:ndots] do dot(c)
				clay.TextDynamic(tabs, txt(th.text_muted, small))
			}
		}
	}
}

// The keyboard's card moved: the grid scrolls it into view (after the layout that draws it, from
// its box and the grid's).
@(private = "file")
deck_scroll_to :: proc() {
	if !deck.scroll do return
	k := -1
	for c, i in deck.cards do if c.sid == deck.sel do k = i
	sc := clay.GetScrollContainerData(clay.ID("deckscroll"))
	list, card := clay.GetElementData(clay.ID("deckscroll")), clay.GetElementData(clay.ID("deckcard", u32(max(k, 0))))
	if k < 0 || !sc.found || !list.found || !card.found do return
	deck.scroll = false
	l, r := list.boundingBox, card.boundingBox
	top, bottom := l.y + px(SP_1), l.y + l.height - px(DECK_PAD) // inside its padding
	if r.y < top do sc.scrollPosition.y += top - r.y
	else if r.y + r.height > bottom do sc.scrollPosition.y -= r.y + r.height - bottom
	else do return
	app.redraw = true // drawn again where it scrolled to
}

// ---- hits and input ----

deck_hit :: proc() -> Hit {
	if !deck_shown() do return nil
	for c, i in deck.cards {
		if clay.PointerOver(clay.ID("deckpeek", u32(i))) && peek_tab_of(find_session(c.sid)) != nil do return Hit_Peek_Row(c.sid) // its Peek (main.odin: peek_open_session)
		if clay.PointerOver(clay.ID("deckmore", u32(i))) do return Hit_Deck_More(c.sid)
		if clay.PointerOver(clay.ID("deckcard", u32(i))) do return Hit_Deck_Card(c.sid)
	}
	return nil
}

// A card's tooltip: where it runs and its status in words (as the empty centre's rows').
deck_tip :: proc(sid: u64) -> (string, string) {return fleet_row_tip(sid)}

// A click on a card (main.odin): there; on its "…": its row's menu under the button.
deck_click :: proc(h: Hit, at: [2]f32) {
	#partial switch x in h {
	case Hit_Deck_Card:
		deck_choose(u64(x))
	case Hit_Deck_More:
		at := at
		for c, i in deck.cards do if c.sid == u64(x) {
			if d := clay.GetElementData(clay.ID("deckmore", u32(i))); d.found do at = {d.boundingBox.x, d.boundingBox.y + d.boundingBox.height}
		}
		sidebar_context(Hit_Open_Row(u64(x)), at) // as its row's (another machine's: Peek and Mark as unread only)
	}
}

// Go to a card's session where its Attention row goes (its tab of its tier): shown, it ends the
// deck (deck_sync).
deck_choose :: proc(sid: u64) {attention_go(sid)}

// ←→ the previous or next card (in order, across rows and groups); ↑↓ the card above or below in
// the same column (the nearest in a shorter row). The first arrow picks the current session's card,
// else the first.
deck_step :: proc(dx, dy: int) {
	app.redraw = true
	if len(deck.cards) == 0 do return
	at := -1
	for c, i in deck.cards do if c.sid == deck.sel do at = i
	if at < 0 {
		k := 0
		for c, i in deck.cards do if c.sid == deck_under() do k = i
		deck.sel, deck.scroll = deck.cards[k].sid, true
		return
	}
	k := at
	if dx != 0 do k = clamp(at + dx, 0, len(deck.cards) - 1)
	if dy != 0 {
		want := deck.cards[at].row + dy
		best := -1
		for c, i in deck.cards do if c.row == want && c.col <= deck.cards[at].col do best = i // the same column, else the row's last
		if best >= 0 do k = best
	}
	deck.sel, deck.scroll = deck.cards[k].sid, true
}

// Enter: the keyboard's card, else the first.
deck_enter :: proc() {
	if len(deck.cards) == 0 do return
	sid := deck.cards[0].sid
	for c in deck.cards do if c.sid == deck.sel do sid = c.sid
	deck_choose(sid)
}


// The deck's keys and wheel while it shows and no field has the keyboard (main.odin, where the
// keys would go to the session on screen: there is none). ←→↑↓, Enter, Esc; the wheel over it
// scrolls the grid; a right-click on a card, its menu. Anything else goes on (⌘ chords as with no
// session open). True: taken.
deck_event :: proc(e: ^sapp.Event) -> bool {
	if !deck_shown() do return false
	mods := e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT)
	#partial switch e.type {
	case .KEY_DOWN:
		if mods != 0 do return false
		#partial switch e.key_code {
		case .LEFT:             deck_step(-1, 0)
		case .RIGHT:            deck_step(1, 0)
		case .UP:               deck_step(0, -1)
		case .DOWN:             deck_step(0, 1)
		case .ENTER, .KP_ENTER: deck_enter()
		case .ESCAPE:           deck_back()
		case:                   return false
		}
		app.key_taken = true
		app.redraw = true
		return true
	case .MOUSE_SCROLL:
		if !inside(clay.ID("deck"), e.mouse_x, e.mouse_y) || deck_under_drawer(e) do return false
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		clay.UpdateScrollContainers(false, {e.scroll_x, e.scroll_y} * SCROLL_STEP * app.dpi, 1.0 / 60)
		app.redraw = true
		return true
	case .MOUSE_DOWN:
		right := e.mouse_button == .RIGHT || (e.mouse_button == .LEFT && mods & sapp.MODIFIER_CTRL != 0)
		if !right || !inside(clay.ID("deck"), e.mouse_x, e.mouse_y) || deck_under_drawer(e) do return false
		p := [2]f32{e.mouse_x, e.mouse_y}
		clay.SetPointerState(p, false)
		if x, ok := deck_hit().(Hit_Deck_Card); ok {
			sidebar_context(Hit_Open_Row(u64(x)), p) // as its row's (another machine's: Peek and Mark as unread only)
			return true
		}
	}
	return false
}

// The pointer is over Atlas's drawer (open, sliding over the centre): its, not the cards'.
@(private = "file")
deck_under_drawer :: proc(e: ^sapp.Event) -> bool {return state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)}
