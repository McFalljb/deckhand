package main

// The Deck view (⇧⌘\, View › Deck view, the top bar's four-cards button, the palette's Toggle
// Deck view): the centre as a grid of cards, one per open session on this Mac and on every online
// machine (Home excluded, as the fleet counts), so the whole fleet shows at a glance, in the empty
// centre's place (its summary line kept; its buttons too when it was opened with no session shown).
//
//	8 sessions · 2 need you · 1 finished · 3 working
//	NEEDS YOU  2
//	┌──────────────────────────────┐ ┌──────────────────────────────┐
//	│ ⚿  web · Login page       3m │ │ ?  api · Schema           9m │
//	│ this Mac · Claude Code       │ │ nuc · pi                     │
//	│ Apply these edits?           │ │ Which index?                 │
//	│                              │ │                              │
//	│ 3 tabs · 1 working           │ │ 1 tab                        │
//	└──────────────────────────────┘ └──────────────────────────────┘
//	WORKING  1
//	…
//
// The cards follow the Attention view's order (core.attention_rows: needs you, finished, working,
// idle; ⌥⌘A's within them), each group under its label on a row of its own. A card: the mark of
// the tab that placed it (session_tier_tab) with its place, title and age; the machine (only while
// other machines are in play) and the harness; that tab's message (the mirror's cleaned text for
// another machine's), else its status in plain words; what the other tabs are doing. Every card
// is the same size whatever it holds, so nothing moves when a status changes; the session it was
// opened from is outlined in the accent; a card flashes as its row does (status_flash, by session).
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

// The session it was opened from (the core's state.shown_before: Show_No_Session), while open.
deck_under :: proc() -> u64 {
	if state.shown_before != 0 && find_session(state.shown_before) != nil do return state.shown_before
	return 0
}

// Whether the deck shows: no session current, and one taken off screen by it (the core keeps which,
// so a second window or a reattached one shows it too) or opened from the empty centre.
deck_shown :: proc() -> bool {return core.cur_view() == nil && (deck_under() != 0 || deck.on)}

// Toggle Deck view (⇧⌘\, the top bar's button, View menu, palette). Pressed again before the core
// answered (a separate core): Show_No_Session again, which does nothing; the deck shows.
deck_toggle :: proc() {
	if deck_shown() {
		deck_back()
		return
	}
	peek_close() // one look at a time: the deck shows them all (ui_peek.odin)
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
	if deck.under && !under do deck.on = true
	deck.under = under
}

// The columns that fit in w px (at least one): each card at least DECK_CARD_MIN_W wide.
deck_columns :: proc(w: f32) -> int {
	return max(1, int(math.floor((w + px(DECK_GAP)) / px(DECK_CARD_MIN_W + DECK_GAP))))
}

// A card's width for cols columns in w px (whole px: every card the same).
deck_card_w :: proc(w: f32, cols: int) -> f32 {
	return math.floor((w - f32(cols - 1) * px(DECK_GAP)) / f32(cols))
}

@(private = "file")
line_h :: proc(weight: u16) -> f32 {
	kind, _ := font_id_split(weight)
	return text_line_height(kind)
}

// The title line's height: a line of body text, or the "…" button where it is taller.
@(private = "file")
title_h :: proc() -> f32 {return max(line_h(WEIGHT_REGULAR), px(ROW_BUTTON))}

// Every card's height: its padding, the title line, the machine and harness, DECK_BODY_LINES of
// message and the footer, with their gaps; the same whatever a card holds.
deck_card_h :: proc() -> f32 {
	small := line_h(FONT_UI_SMALL)
	return px(2 * DECK_CARD_PAD + SP_1 + 2 * SP_2) + title_h() + small + f32(DECK_BODY_LINES) * line_h(WEIGHT_REGULAR) + small
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

// "this Mac · Claude Code": the machine while other machines are in play, then the harness.
deck_meta :: proc(s: ^core.Open_Session) -> string {
	harness := core.HARNESSES[s.agent == .Claude ? core.Harness.Claude : core.Harness.Pi].name
	if !(state.settings.remote_machines && len(state.machines) > 0) do return harness
	return fmt.tprintf("%s · %s", s.machine == 0 ? "this Mac" : core.machine_name(s.machine), harness)
}

// "3 tabs · 1 waiting · 1 working": its tabs, then what the others (not the card's own) are doing.
deck_footer :: proc(s: ^core.Open_Session, from: ^core.Tab) -> string {
	n := [5]int{}
	for &t in s.tabs do if &t != from do n[core.tab_tier(t)] += 1
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d %s", len(s.tabs), len(s.tabs) == 1 ? "tab" : "tabs")
	if n[core.NEED_WAITING] > 0 do fmt.sbprintf(&b, " · %d waiting", n[core.NEED_WAITING])
	if n[core.NEED_ERROR] > 0 do fmt.sbprintf(&b, " · %d %s", n[core.NEED_ERROR], n[core.NEED_ERROR] == 1 ? "error" : "errors")
	if n[core.NEED_UNSEEN] > 0 do fmt.sbprintf(&b, " · %d finished", n[core.NEED_UNSEEN])
	if n[core.NEED_WORKING] > 0 do fmt.sbprintf(&b, " · %d working", n[core.NEED_WORKING])
	return strings.to_string(b)
}

// "8 sessions · 2 need you · 1 finished · 3 working".
deck_summary :: proc(n: int) -> string {
	head := fmt.tprintf("%d %s", n, n == 1 ? "session" : "sessions")
	if words := fleet_words(fleet, " · "); words != "" do return fmt.tprintf("%s · %s", head, words)
	return head
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
	ch := deck_card_h()
	if clay.UI(clay.ID("deck"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}, backgroundColor = cc(th.bg_app)}) {
		// the summary line; with no session open, the empty centre's buttons under it
		if clay.UI(clay.ID("deckhead"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(DECK_PAD), pu(DECK_PAD), pu(DECK_PAD), pu(SP_2)}, childGap = pu(SP_3), layoutDirection = .TopToBottom}}) {
			if len(rows) > 0 do clay.TextDynamic(clip(deck_summary(len(rows)), inner), txt(th.text_secondary))
			if len(rows) == 0 {
				lines, _ := wrap_clip("Nothing running. Start a chat or open a project.", inner, 3)
				cfg := txt(th.text_secondary)
				cfg.wrapMode = .Newlines
				clay.TextDynamic(lines, cfg)
			}
			if deck_under() == 0 || len(rows) == 0 do deck_buttons(inner) // opened with no session shown
		}
		if len(rows) == 0 do return
		if clay.UI(clay.ID("deckscroll"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, padding = {pu(DECK_PAD), pu(DECK_PAD), pu(SP_1), pu(DECK_PAD)}, childGap = pu(DECK_GAP), layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			// each group under its label, cols cards a row (rows are in group order: core.attention_rows)
			grid_row := 0
			for at := 0; at < len(rows); {
				g := rows[at].group
				end := at
				for end < len(rows) && rows[end].group == g do end += 1
				deck_label(g, end - at, at == 0)
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

// A group's label on a row of its own: "NEEDS YOU  2" in the Attention view's headers' style.
@(private = "file")
deck_label :: proc(g: core.Attention_Group, n: int, first: bool) {
	th := theme()
	// a little more room above a group than between its rows (none above the first)
	top := first ? 0 : pu(SP_2)
	if clay.UI(clay.ID("decklabel", u32(g)))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {0, 0, top, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
		clay.TextDynamic(ATTENTION_LABELS[g], txt(th.text_muted, FONT_UI_SMALL | WEIGHT_HEADER))
		clay.TextDynamic(fmt.tprint(n), txt(g == .Needs_You ? th.waiting : th.text_muted, FONT_UI_SMALL))
	}
}

// One card, w by h px (every card's size): see the top of this file.
@(private = "file")
deck_card :: proc(r: core.Attention_Row, i: int, w, h: f32) {
	th := theme()
	s := r.session
	id := clay.ID("deckcard", u32(i))
	more_id := clay.ID("deckmore", u32(i))
	v, from := card_view(r)
	remote := s.machine != 0
	current := s.id == deck_under() // the session it was opened from
	more_hover := !remote && ui_hover == Hit(Hit_Deck_More(s.id))
	hovered := ui_hover == Hit(Hit_Deck_Card(s.id)) || more_hover
	key_sel := s.id == deck.sel
	// hovered or the keyboard's: lifted by the hover tint; a status turning: the row's flash
	lift := fade(id, 0, hovered || key_sel ? 1 : 0, DUR_HOVER)
	lit := status_flash(id, s.id ~ SALT_FLASH_ROW, v, s.machine)
	bg := flash_wash(cc(mix(th.bg_elevated, {th.hover.r, th.hover.g, th.hover.b, 255}, lift * f32(th.hover.a) / 255)), v.dot, lit)
	edge := current ? th.accent : (key_sel ? th.text_muted : th.border)
	pad := px(DECK_CARD_PAD)
	room := w - 2 * pad
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}, padding = clay.PaddingAll(pu(DECK_CARD_PAD)), layoutDirection = .TopToBottom},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(edge), width = clay.BorderOutside(pu(core.BORDER_W))}, // Outside: BorderAll also rules a line between every child
	}) {
		small := FONT_UI_SMALL
		// mark, [place ·] title, then its age, or (hovered) its "…" in the same box
		age := status_age(v)
		if age == "" && r.tier == core.NEED_NONE && !remote do age = core.open_session_age(s)
		right := max(text_w("00m", small), text_w("now", small), px(ROW_BUTTON))
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
			clay.TextDynamic(clip(title, left, WEIGHT_HEADER), txt(th.text, WEIGHT_HEADER))
			spacer()
			if clay.UI()({layout = {sizing = {clay.SizingFixed(right), clay.SizingFit()}, childAlignment = {x = .Right, y = .Center}}}) {
				if hovered && !remote {
					mbg, _ := overlay(more_id, false, more_hover)
					if clay.UI(more_id)({
						layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
						backgroundColor = mbg,
						cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
					}) {
						icon(.More, more_hover ? th.text : th.text_muted, ICON_SIZE_SM)
					}
				} else if age != "" {
					clay.TextDynamic(clip(age, right, small), txt(th.text_muted, small))
				}
			}
		}
		gap(SP_1)
		clay.TextDynamic(clip(deck_meta(s), room, small), txt(th.text_muted, small))
		gap(SP_2)
		// the message, up to DECK_BODY_LINES lines (its room kept, so every card is the same)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(f32(DECK_BODY_LINES) * line_h(WEIGHT_REGULAR))}}}) {
			lines, _ := wrap_clip(deck_body(v), room, DECK_BODY_LINES)
			cfg := txt(th.text_secondary)
			cfg.wrapMode = .Newlines
			clay.TextDynamic(lines, cfg)
		}
		gap(SP_2)
		clay.TextDynamic(clip(deck_footer(s, from), room, small), txt(th.text_muted, small))
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
		sidebar_context(Hit_Open_Row(u64(x)), at) // another machine's has none (as its row)
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
			sidebar_context(Hit_Open_Row(u64(x)), p) // as its row's (another machine's has none)
			return true
		}
	}
	return false
}

// The pointer is over Atlas's drawer (open, sliding over the centre): its, not the cards'.
@(private = "file")
deck_under_drawer :: proc(e: ^sapp.Event) -> bool {return state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)}
