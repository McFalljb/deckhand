package main

// The fleet: what needs you and what works, on this Mac and every online machine, from one core
// count (core/needing_you.odin fleet_tally, over needing_you's tiers), so the pill, the
// machine headers, the empty centre, the Dock's badge and ⌥⌘A never disagree.
//
//   - the pill (top bar, left of the bell): "◉2 ✓1 ◜3": needs you (waiting, or an error), finished
//     and not seen, working; a zero part is left out, all zero: no pill. A compact bar: the most
//     urgent part alone. Each part is a fixed width per digit count, so nothing beside it moves
//     while a number changes within its digits. A click: Next needing you (⌥⌘A); with only work
//     going on, the next working session.
//   - a machine header's mini-counts (ui_sidebar.odin machine_header): the same parts, smaller.
//   - the empty centre ("No session open") while anything needs you or works: the counts in words,
//     up to FLEET_ROWS sessions in needing_you's order (each goes where ⌥⌘A would), Go to next.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core"
import clay "../build/clay-odin"

// This frame's counts (ui_layout: fleet_tally_frame), all and per machine (fleet_per[0]: this
// Mac's, fleet_per[i + 1]: state.machines[i]'s). Counted once per frame in one pass, without
// allocating; the ordered list (core.needing_you) is built only for a click and for the empty
// centre while it is drawn.
fleet: core.Fleet
fleet_per: [dynamic]core.Fleet

fleet_tally_frame :: proc() {
	if fleet_per.allocator.procedure == nil do fleet_per.allocator = runtime.heap_allocator()
	if len(fleet_per) != len(state.machines) + 1 do resize(&fleet_per, len(state.machines) + 1) // grows with the machines only
	fleet = core.fleet_tally(fleet_per[:])
}

// One machine's counts this frame (0: this Mac's).
fleet_of :: proc(no: u64) -> core.Fleet {
	if no == 0 do return len(fleet_per) > 0 ? fleet_per[0] : {}
	for m, i in state.machines do if m.no == no && i + 1 < len(fleet_per) do return fleet_per[i + 1]
	return {}
}

FLEET_ROWS :: 5 // the empty centre's rows, at most
FLEET_ROW_W :: 460 // the empty centre's rows' width, at most (logical px)

Fleet_Part :: struct {
	mark: core.Status_Mark,
	col:  core.Rgba,
	n:    int,
}

// The parts shown, most urgent first; compact: that one alone. Needs you takes the waiting mark
// when anything waits, in the error colour when an error is among them (so a failure is never
// hidden behind a question); errors alone take the error mark.
fleet_parts :: proc(f: core.Fleet, compact := false) -> (parts: [3]Fleet_Part, n: int) {
	th := theme()
	if need := core.fleet_need(f); need > 0 {
		m := f.waiting > 0 ? core.Status_Mark.Waiting : core.Status_Mark.Error
		parts[n] = {m, f.errors > 0 ? th.error : th.waiting, need}
		n += 1
	}
	if f.unseen > 0 {
		parts[n] = {.Done, th.accent, f.unseen}
		n += 1
	}
	if f.working > 0 {
		parts[n] = {.Working, th.running, f.working}
		n += 1
	}
	if compact do n = min(n, 1)
	return
}

// The widest digit in a font: a count's box is that times its digits, so it never shifts as the
// number changes within its digits.
@(private = "file")
digit_w :: proc(font: u16) -> f32 {
	w: f32
	for d in ([]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}) do w = max(w, text_w(d, font))
	return w
}

@(private = "file")
part_w :: proc(p: Fleet_Part, font: u16) -> f32 {
	return px(MARK + SP_1) + f32(len(fmt.tprint(p.n))) * digit_w(font)
}

// The width of a row of parts (gap between them).
fleet_counts_w :: proc(f: core.Fleet, compact: bool, font: u16, gap: f32) -> f32 {
	parts, n := fleet_parts(f, compact)
	w: f32
	for p in parts[:n] do w += part_w(p, font)
	if n > 1 do w += f32(n - 1) * gap
	return w
}

// How far a mark moves down to sit centred on a digit (the digits' middle is half their cap
// height above the baseline, not the line box's middle).
@(private = "file")
digit_nudge :: proc(weight: u16) -> f32 {
	kind, _ := font_id_split(weight)
	set := font.sets[kind]
	return math.round(set.baseline - set.metrics.cap_height / 2 - set.line_h / 2)
}

// The parts, laid out: each a mark and its count in a box of fixed width.
fleet_counts_el :: proc(f: core.Fleet, compact: bool, font: u16, gap: f32, col: core.Rgba) {
	parts, n := fleet_parts(f, compact)
	nudge := digit_nudge(font)
	if clay.UI()({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}, childGap = u16(gap), childAlignment = {y = .Center}}}) {
		for p in parts[:n] {
			if clay.UI()({layout = {sizing = {clay.SizingFixed(part_w(p, font)), clay.SizingFit()}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
				// the mark, optically on the digits' middle
				pad := u16(abs(nudge) * 2)
				if clay.UI()({layout = {sizing = {clay.SizingFixed(px(MARK)), clay.SizingFit()}, padding = {0, 0, nudge > 0 ? pad : 0, nudge < 0 ? pad : 0}}}) {
					mark_el(p.mark, p.col)
				}
				clay.TextDynamic(fmt.tprint(p.n), txt(col, font))
			}
		}
	}
}

// ---- the pill ----

@(private = "file")
PILL_GAP :: SP_3 // between its parts

// How the pill shows in this layout (fleet_pill_decide): whole, its most urgent part, or not at all.
@(private = "file")
pill_compact: bool
@(private = "file")
pill_hidden: bool

// The pill whole while the bar has room for it beside the tabs at their narrowest (as the "±"
// decides: ui_changes.odin), else its most urgent part (always in a compact bar), else none.
fleet_pill_decide :: proc(cs: ^core.Open_Session, bar_w: f32) {
	pill_compact, pill_hidden = bar_compact, false
	if !core.fleet_any(fleet) do return
	changes_btn_shown = false // decided after it (changes_button_decide): the "±" gives way first
	room := bar_w - remote_marker_w(cs)
	if cs != nil && len(cs.panes) <= 1 && len(cs.tabs) > 0 {
		for _ in cs.tabs do room -= px(TAB_MIN_W + SP_1)
		room -= tab_close_w()
	}
	if top_bar_fixed_w() <= room do return
	pill_compact = true
	if top_bar_fixed_w() <= room do return
	pill_hidden = true
}

// The pill's width, 0 while it does not show (top_bar_fixed_w counts it).
fleet_pill_w :: proc() -> f32 {
	if !core.fleet_any(fleet) || pill_hidden do return 0
	return fleet_counts_w(fleet, pill_compact, WEIGHT_REGULAR, px(PILL_GAP)) + px(2 * SP_2)
}

fleet_pill :: proc() {
	if !core.fleet_any(fleet) || pill_hidden do return
	th := theme()
	id := clay.ID(BUTTONS[.Fleet].element)
	h := fade(id, 0, ui_hover == Hit(Hit_Button(.Fleet)) ? 1 : 0, DUR_HOVER)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(fleet_pill_w()), clay.SizingFixed(px(TOOL_BUTTON))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(mix(th.bg_app, th.text, TINT_BUTTON + h * (TINT_BUTTON_HOVER - TINT_BUTTON))), // as the search pill's
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		fleet_counts_el(fleet, pill_compact, WEIGHT_REGULAR, px(PILL_GAP), mix(th.text_secondary, th.text, h))
	}
}

// "2 need you, 1 finished, 3 working" ("" with nothing going on); errors are named.
fleet_words :: proc(f: core.Fleet, sep := ", ") -> string {
	b := strings.builder_make(context.temp_allocator)
	add :: proc(b: ^strings.Builder, sep, s: string) {
		if strings.builder_len(b^) > 0 do strings.write_string(b, sep)
		strings.write_string(b, s)
	}
	if need := core.fleet_need(f); need > 0 {
		s := fmt.tprintf("%d %s you", need, need == 1 ? "needs" : "need")
		if f.errors > 0 do s = fmt.tprintf("%s (%d %s)", s, f.errors, f.errors == 1 ? "error" : "errors")
		add(&b, sep, s)
	}
	if f.unseen > 0 do add(&b, sep, fmt.tprintf("%d finished", f.unseen))
	if f.working > 0 do add(&b, sep, fmt.tprintf("%d working", f.working))
	return strings.to_string(b)
}

// Whether ⌥⌘A has somewhere to go (something needs you or finished unseen).
@(private = "file")
fleet_has_next :: proc(f: core.Fleet) -> bool {return core.fleet_need(f) + f.unseen > 0}

fleet_tip :: proc() -> (label, keys: string) {
	words := fleet_words(fleet)
	if words == "" do return "", ""
	if fleet_has_next(fleet) do return fmt.tprintf("%s: click to go to the next", words), "⌥⌘A"
	return fmt.tprintf("%s: click to go to the next working session", words), ""
}

// The pill's click: Next needing you; with only work going on, the working session after the
// current one (round), so the click is never a "Nothing needs you".
fleet_click :: proc() {
	if fleet_has_next(fleet) {
		action_run("next_needing_you")
		return
	}
	list := core.needing_you(working = true)
	if len(list) == 0 do return
	k := 0
	for x, i in list do if x.session.id == state.current_session do k = (i + 1) % len(list)
	fleet_go(list[k].session.id)
}

// Go to a session where ⌥⌘A would: its tab of its tier (another machine's as a click on its
// row, then on that tab: core/commands.odin Next_Needing_You).
fleet_go :: proc(sid: u64) {
	s := core.find_session(sid)
	if s == nil do return
	tab := core.session_need_tab(s, core.session_need(s))
	switch {
	case tab == nil:
		ui_do(core.Focus_Session{session = s.id})
	case s.machine == 0:
		ui_do(core.Focus_Tab{tab_id = tab.id})
	case:
		tid := tab.id
		focused := core.session_focused_id(s)
		ui_do(core.Focus_Session{session = sid})
		if focused != tid do ui_do(core.Focus_Tab{tab_id = tid})
	}
}

// ---- the empty centre ----

Hit_Fleet_Row :: distinct u64 // open session id

// The sessions its rows showed in the last layout (their hits).
@(private = "file")
rows_drawn: [FLEET_ROWS]u64
@(private = "file")
rows_n: int

fleet_row_hit :: proc() -> Hit {
	for i in 0 ..< rows_n do if clay.PointerOver(clay.ID("fleetpeek", u32(i))) && peek_tab_of(find_session(rows_drawn[i])) != nil do return Hit_Peek_Row(rows_drawn[i]) // its eye (ui_peek.odin)
	for i in 0 ..< rows_n do if clay.PointerOver(clay.ID("fleetrow", u32(i))) do return Hit_Fleet_Row(rows_drawn[i])
	return nil
}

// A row's tooltip: where it is and its status in words.
fleet_row_tip :: proc(sid: u64) -> (string, string) {
	s := core.find_session(sid)
	if s == nil do return "", ""
	tab := core.session_need_tab(s, core.session_need(s))
	if tab == nil do return "", ""
	tip := core.status_explain(tab^)
	if s.machine != 0 do tip = fmt.tprintf("On %s · %s", core.machine_name(s.machine), tip)
	return tip, ""
}

// The summary the centre shows instead of "No session open" while anything needs you or works:
//
//	2 need you · 1 finished · 3 working
//	⛉ web · Login page          this Mac   3m
//	? api · Schema              nuc        9m
//	[Go to next ⌥⌘A] [New chat] [Add project…]
fleet_empty_layout :: proc() {
	th := theme()
	rows_n = 0
	list := core.needing_you(working = true)
	machines := state.settings.remote_machines && len(state.machines) > 0 // a machine column only then
	row_w := min(px(FLEET_ROW_W), centre_width() - px(2 * SP_6))
	// the machine column: as wide as its widest name (at most 120 px), so the names line up
	mach_w: f32
	if machines do for x, i in list do if i < FLEET_ROWS do mach_w = max(mach_w, min(text_w(fleet_machine(x.session), FONT_UI_SMALL), px(120)))
	age_w := text_w("00m", FONT_UI_SMALL)
	clay.TextDynamic(fleet_words(fleet, " · "), txt(th.text_secondary))
	if clay.UI(clay.ID("fleetrows"))({layout = {sizing = {clay.SizingFixed(row_w), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = {0, 0, pu(SP_1), pu(SP_1)}}}) {
		for x, i in list {
			if i >= FLEET_ROWS do break
			s := x.session
			rows_drawn[i] = s.id
			rows_n = i + 1
			id := clay.ID("fleetrow", u32(i))
			// hovered, a row that can be peeked shows an eye at its end (ui_peek.odin)
			can_peek := peek_tab_of(s) != nil
			peek_hover := can_peek && ui_hover == Hit(Hit_Peek_Row(s.id))
			peek_shown := can_peek && (peek_hover || ui_hover == Hit(Hit_Fleet_Row(s.id)))
			bg, em := overlay(id, false, ui_hover == Hit(Hit_Fleet_Row(s.id)) || peek_hover)
			if clay.UI(id)(row_cfg(bg)) {
				tab := core.session_need_tab(s, x.tier)
				v := tab != nil ? core.tab_status_view(tab^) : core.Tab_Status_View{progress = -1}
				age := status_age(v)
				ic, place := core.session_place(s)
				title := core.open_session_title(s)
				// mark, [place ·], title, spacer, [machine], age
				room := row_w - px(2 * PAD_ROW) - px(MARK) - age_w - 3 * px(GAP_INLINE)
				if machines do room -= mach_w + px(GAP_INLINE)
				if peek_shown do room -= px(ROW_BUTTON) + px(GAP_INLINE)
				status_mark_el(v)
				if ic != .Chat {
					lead := fmt.tprintf("%s ·", place)
					pw := min(text_w(lead), max(room * 0.4, room - text_w(title)))
					clay.TextDynamic(clip(lead, pw), txt(th.text_muted))
					room -= pw + px(GAP_INLINE)
				}
				clay.TextDynamic(clip(title, room), txt(mix(th.text_secondary, th.text, em)))
				spacer()
				// (not `machines && clay.UI()`: the element's close is deferred, opened or not)
				if machines {
					if clay.UI()({layout = {sizing = {clay.SizingFixed(mach_w), clay.SizingFit()}}}) {
						clay.TextDynamic(clip(fleet_machine(s), mach_w, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
					}
				}
				if clay.UI()({layout = {sizing = {clay.SizingFixed(age_w), clay.SizingFit()}, childAlignment = {x = .Right}}}) {
					if age != "" do clay.TextDynamic(age, txt(th.text_muted, FONT_UI_SMALL))
				}
				peek_row_button(clay.ID("fleetpeek", u32(i)), peek_shown, peek_hover)
			}
		}
		if more := len(list) - FLEET_ROWS; more > 0 {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childAlignment = {y = .Center}}}) {
				clay.TextDynamic(fmt.tprintf("and %d more", more), txt(th.text_muted, FONT_UI_SMALL))
			}
		}
	}
	if clay.UI()({layout = {childGap = pu(SP_2)}}) {
		next := fleet_has_next(fleet)
		if next do button(clay.ID(BUTTONS[.Empty_Next].element), "Go to next", true, ui_hover == Hit(Hit_Button(.Empty_Next)), "⌥⌘A")
		if button_enabled(.Empty_New_Chat) do action_button(.Empty_New_Chat, !next)
		action_button(.Empty_Add_Project, false)
	}
}

// Where a session runs, in the empty centre's machine column.
@(private = "file")
fleet_machine :: proc(s: ^core.Open_Session) -> string {
	return s.machine == 0 ? "this Mac" : core.machine_name(s.machine)
}
