package main

// Peek (docs/GUIDE.md "Peek"): look at and answer a session that needs you without leaving what
// you are doing. A panel over the centre shows ONE terminal tab of another open session, live,
// and the keyboard and the mouse go to it; the session on screen, its panes, its zoom and what
// has the keyboard there are left exactly as they are. Window state only (peek): nothing in the
// core, nothing saved.
//
// What can be peeked (peek_tab_of, peek_ok): a terminal tab (pi, Claude Code, a shell) whose
// terminal the core has, of an open session that is not the one on screen, on this Mac or on
// another machine while it is online. Its terminal is streamed as a tab on screen is: the
// window's term.attach (term_view_of), which for another machine's tab starts that tab's relay on
// demand (machine_route.odin), so what is typed takes exactly the path a tab on screen's input
// takes (its stream's DATA; a paste is the user's send_text), with the same authority. Its tab:
// the one the session's Attention row shows (core.session_tier_tab), else its focused one; "Peek
// at next needing you" takes the tab ⌥⌘A would go to.
//
// Entry points: Space on the Attention view's keyboard row; the eye button on a hovered row of
// the Attention view, of the empty centre's list and of the bell's popover; "Peek" in a session
// row's menu; Peek at next needing you (⌃⌥⌘A, Window menu, palette).
//
// Keys while peeking (peek_event, before anything else takes a key): everything goes to the
// peeked terminal, Esc and Enter included (agents' prompts need them), except ⌘ chords, which
// never reach programs: ⌘↩ Open (it becomes the tab on screen, as fleet_go goes there), ⌘W
// Close, ⌥⌘A or ⌃⌥⌘A the next one needing you (⇧⌥⌘A the one before), ⌘C copies its selection,
// ⌘V pastes into it, ⌘⌫ ⌘← ⌘→ edit its line as in a pane; any other ⌘ chord closes the peek and
// then does what it does. A click outside the panel (the scrim) only closes it. Nothing here
// moves the keyboard's owner (state.focus_widget, the focused pane), so closing returns to it.
//
// Sizes (peek_after_layout): a tab this window has laid out (term_fits) is never resized: its
// grid is drawn 1:1 (cells on whole pixels, text as crisp as in a pane), the panel grown to show
// it whole up to the centre less a margin, and what is still larger clipped to its bottom-left
// (where an agent's prompt is). One this window never laid out gets the panel's grid once (the
// first layout it would have had); another machine's never (that machine's own window may show
// it), it is only clipped.
//
// It closes when its tab, its session or its machine goes, when its session becomes the one on
// screen, and when a sheet that takes all input (the job sheet, the first-run sheet) opens.

import "core:fmt"
import "core:math"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"
import sgl "../vendor/sokol-odin/sokol/gl"

Peek_Button :: enum u8 {
	None,
	Open,
	Close,
}
Hit_Peek :: distinct Peek_Button // the panel's header buttons
Hit_Peek_Row :: distinct u64 // a row's eye button: peek at that open session

// Its scrim, the panel's shadow (overlay_shadow: PEEK_Z_BOX - 1) and the panel: above the menus
// and popovers (8) and the palette and sheets (10), which close or cannot open while it shows;
// below the toast and the tooltips.
PEEK_Z_SCRIM :: 11
PEEK_Z_BOX :: 13
PEEK_SEEN_GAP :: 500 * time.Millisecond // a tab finished again while peeked: marked seen again at most this often

Peek_State :: struct {
	session: u64, // the open session (0: no peek)
	tab:     u64, // the tab peeked
	opened:  time.Tick, // its fade-in started
	area:    [4]f32, // the terminal's part of the panel in the last layout (framebuffer px): drawn, clipped and hit there
	sized:   bool, // a tab never laid out here was given the panel's grid (once)
	seen_at: time.Tick, // Set_Unread last sent for it
}
peek: Peek_State
peek_moving: bool // its fade runs: draw the next frame (ui_wants_frame)

peek_is_open :: proc() -> bool {return peek.tab != 0}

// The peeked tab's terminal copy, if it has one (no attach).
peek_view :: proc() -> ^Term_View {
	if !peek_is_open() do return nil
	return term_view_peek(peek.tab)
}

// ---- what can be peeked ----

@(private = "file")
machine_online :: proc(no: u64) -> bool {
	if no == 0 do return true
	for m in state.machines do if m.no == no do return m.status == .Online
	return false
}

// A terminal-backed tab (pi, Claude Code, a shell) whose terminal the core has.
peek_tab_kind_ok :: proc(t: core.Tab) -> bool {
	#partial switch _ in t.kind {
	case core.Pi_Tab, core.Shell_Tab, core.Claude_Tab: return t.has_term
	}
	return false
}

// Whether tab (of s) can be peeked now.
peek_ok :: proc(s: ^core.Open_Session, tab: ^core.Tab) -> bool {
	if s == nil || tab == nil || s.home || s.id == state.current_session || !machine_online(s.machine) do return false
	mine := false
	for &t in s.tabs do if &t == tab do mine = true
	return mine && peek_tab_kind_ok(tab^)
}

// The tab a row's Peek shows for s: the one its Attention row shows (its tier's), else its
// focused one; nil when that one cannot be peeked (a page, an app; offline; on screen already).
peek_tab_of :: proc(s: ^core.Open_Session) -> ^core.Tab {
	if s == nil do return nil
	tier := core.session_need(s)
	tab := tier != core.NEED_NONE ? core.session_tier_tab(s, tier) : core.session_focused_tab(s)
	return peek_ok(s, tab) ? tab : nil
}

// ---- open, close, step ----

// Peeks at open session sid's row tab (peek_tab_of). False: nothing to peek there.
peek_open_session :: proc(sid: u64) -> bool {
	s := find_session(sid)
	return peek_open_tab(s, peek_tab_of(s))
}

// Peeks at tab of s (another peek is replaced).
peek_open_tab :: proc(s: ^core.Open_Session, tab: ^core.Tab) -> bool {
	if !peek_ok(s, tab) do return false
	if menu.open do menu_close()
	switching := peek_is_open()
	if switching && peek.tab == tab.id do return true
	if switching do peek_close()
	ime_cancel() // a composition belongs to what had the keyboard
	peek = {session = s.id, tab = tab.id, opened = time.tick_now()}
	if switching do peek.opened = {} // from one peek to the next: no fade
	if v := term_view_of(tab.id); v != nil && !v.focused && app.window_active do term_focus(v, true)
	peek_seen(s, tab)
	set_hover(nil, false) // the row's eye under the scrim is not hovered now
	app.redraw = true
	if core.autotest_active do fmt.println("[autotest] peek:", tab.id)
	return true
}

// The peek closes; the keyboard is where it was (nothing moved it).
peek_close :: proc() {
	if !peek_is_open() do return
	if v := term_view_peek(peek.tab); v != nil do term_cancel_drag(v)
	peek = {}
	peek_moving = false
	ime_cancel()
	set_hover(nil, false)
	// the window went to the background and came back while peeking: the terminal under it has the keyboard again
	if kt := key_view(); kt != nil && !kt.focused && app.window_active do term_focus(kt, true)
	app.redraw = true
	if core.autotest_active do fmt.println("[autotest] peek closed")
}

// Open (⌘↩): the peeked tab becomes the tab on screen, as fleet_go goes to a session (another
// machine's through its session, then the tab), and the peek closes.
peek_go :: proc() {
	s := find_session(peek.session)
	tid := peek.tab
	peek_close()
	if s == nil do return
	sid, local, focused := s.id, s.machine == 0, core.session_focused_id(s) // (no pointer held across a command)
	if local {
		ui_do(core.Focus_Tab{tab_id = tid})
		return
	}
	ui_do(core.Focus_Session{session = sid})
	if focused != tid do ui_do(core.Focus_Tab{tab_id = tid})
}

// Peek at next needing you (⌃⌥⌘A; ⌥⌘A and ⇧⌥⌘A while peeking): the next session in needing_you's
// order that can be peeked, from the one peeked, else from where ⌥⌘A would go; its tab as ⌥⌘A
// would pick it (core.session_need_tab).
peek_next :: proc(back := false) {
	list := core.needing_you()
	n := len(list)
	k := -1
	if peek_is_open() do for x, i in list do if x.session.id == peek.session do k = back ? (i - 1 + n) %% n : (i + 1) %% n
	if k < 0 {
		s, _ := core.next_needing_target(back)
		if s != nil do for x, i in list do if x.session.id == s.id do k = i
	}
	if k < 0 {
		toast_show("Nothing needs you")
		return
	}
	for j in 0 ..< n {
		i := back ? (k - j + n) %% n : (k + j) %% n
		x := list[i]
		tab := core.session_need_tab(x.session, x.tier)
		if !peek_ok(x.session, tab) do continue
		if peek_is_open() && tab.id == peek.tab {
			toast_show("Nothing else needs you")
			return
		}
		peek_open_tab(x.session, tab)
		return
	}
	toast_show(peek_is_open() ? "Nothing else needs you" : "Nothing to peek at: what needs you is on screen, or not a terminal")
}

// An action run while peeking (action_run: the menu bar's items clicked): the peek's own are
// handled here (true); any other closes the peek first and then runs.
peek_action :: proc(id: string) -> bool {
	if !peek_is_open() do return false
	switch id {
	case "peek_next_needing_you", "next_needing_you":
		peek_next()
		return true
	case "prev_needing_you":
		peek_next(back = true)
		return true
	case "close_tab": // ⌘W: the peek, never the tab under it
		peek_close()
		return true
	}
	peek_close()
	return false
}

// Seen: the peeked tab is on screen. A tab finished and not seen is seen now (as a tab shown in
// the window in front: status_wants_seen), and so are its unread bell entries.
@(private = "file")
peek_seen :: proc(s: ^core.Open_Session, tab: ^core.Tab) {
	if !app.window_active do return
	tid, unseen := tab.id, tab.unseen
	read := make([dynamic]u64, context.temp_allocator)
	if s.machine == 0 do for n in state.notices.items do if !n.read && n.tab_id == tid do append(&read, n.id)
	if unseen {
		ui_do(core.Set_Unread{tab_id = tid, unread = false})
		peek.seen_at = time.tick_now()
	}
	for id in read do ui_do(core.Notifications_Mark_Read{id = id})
}

// Every frame and before each event: a peek whose tab, session or machine went (or whose session
// is on screen now, or under a sheet that takes all input) closes; its terminal stays attached;
// a tab that finished while peeked is seen.
peek_tick :: proc() {
	if !peek_is_open() do return
	s, tab, _ := find_tab(peek.tab)
	if s == nil || s.id != peek.session || !peek_ok(s, tab) || job_sheet_open() || setup_open() {
		peek_close()
		return
	}
	v := term_view_of(peek.tab)
	if v == nil && client.attached { 	// the core has no terminal for it
		peek_close()
		return
	}
	if tab.unseen && app.window_active && (peek.seen_at == {} || time.tick_since(peek.seen_at) >= PEEK_SEEN_GAP) {
		ui_do(core.Set_Unread{tab_id = tab.id, unread = false})
		peek.seen_at = time.tick_now()
	}
}

// ---- layout ----

// The fade-in, 0..1 eased (1: done, and under Reduce motion); frames while it runs.
peek_progress :: proc() -> f32 {
	peek_moving = false
	if peek.opened == {} || state.settings.reduce_motion do return 1
	k := f32(time.duration_seconds(time.tick_since(peek.opened)) / time.duration_seconds(DUR_PEEK))
	if k >= 1 {
		peek.opened = {}
		return 1
	}
	peek_moving = true
	return ease_out(k)
}

// The panel's box (framebuffer px, whole pixels): centred on the centre column, PEEK_FRAC of it,
// grown to show v's grid whole when its size is settled (a layout here gave it, or it is another
// machine's, never resized), at most the centre less the margins (the window's when the centre
// is too small).
peek_box :: proc(w, h: f32, v: ^Term_View, remote := false) -> [4]f32 {
	c := [4]f32{0, 0, w, h}
	if d := clay.GetElementData(clay.ID("centre")); d.found do c = {d.boundingBox.x, d.boundingBox.y, d.boundingBox.width, d.boundingBox.height}
	m := px(PEEK_MARGIN)
	if c.z < px(PEEK_MIN_W) + 2 * m || c.w < px(PEEK_MIN_H) + 2 * m do c = {0, 0, w, h}
	max_w, max_h := max(c.z - 2 * m, 0), max(c.w - 2 * m, 0)
	want_w, want_h := c.z * PEEK_FRAC, c.w * PEEK_FRAC
	if v != nil && v.cols > 0 && v.rows > 0 && (remote || peek.tab in term_fits) {
		inset := 2 * px(PEEK_PAD)
		want_w = max(want_w, f32(v.cols) * font.cell_w + 2 * term_pad() + inset)
		want_h = max(want_h, f32(v.rows) * font.cell_h + 2 * term_pad() + inset + px(PEEK_HEAD_H))
	}
	bw := math.floor(min(max(want_w, px(PEEK_MIN_W)), max_w))
	bh := math.floor(min(max(want_h, px(PEEK_MIN_H)), max_h))
	return {math.round(c.x + (c.z - bw) / 2), math.round(c.y + (c.w - bh) / 2), bw, bh}
}

// A header button's width as button() lays it out.
@(private = "file")
head_button_w :: proc(label, keys: string, primary: bool) -> f32 {
	w := text_w(label, primary ? WEIGHT_BOLD : WEIGHT_REGULAR) + px(2 * SP_3)
	if keys != "" do w += px(SP_2) + text_w(keys, FONT_UI_SMALL)
	return w
}

// The scrim and the panel (ui_layout, above the popovers): the header, then the terminal's area
// (peek_term), where the terminal is drawn after the layout (peek_draw).
peek_layout :: proc(w, h: f32) {
	if !peek_is_open() do return
	s, tab, _ := find_tab(peek.tab)
	if s == nil || tab == nil do return
	th := theme()
	e := peek_progress()
	b := peek_box(w, h, term_view_peek(peek.tab), remote = s.machine != 0)
	b.y += math.round((1 - e) * px(PEEK_RISE))
	if clay.UI(clay.ID("peek_scrim"))({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}},
		backgroundColor = cc(th.scrim),
		floating = {attachTo = .Root, zIndex = PEEK_Z_SCRIM},
	}) {}
	if clay.UI(clay.ID("peek_box"))({
		layout = {sizing = {clay.SizingFixed(b.z), clay.SizingFixed(b.w)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(PEEK_PAD))},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {b.x, b.y}, zIndex = PEEK_Z_BOX},
	}) {
		overlay_shadow("peek_shadow", PEEK_Z_BOX)
		peek_header(s, tab, b.z - 2 * px(PEEK_PAD))
		if clay.UI(clay.ID("peek_term"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
			backgroundColor = cc(core.term_colors().bg), // until its first snapshot draws
		}) {}
	}
}

// The header: status mark, "place · title" (and the tab's own title when it is not the
// session's main tab), the machine while other machines are in play, the age; then Open and
// Close. Narrow: the buttons lose their keys, then the machine and the age go; the title clips.
@(private = "file")
peek_header :: proc(s: ^core.Open_Session, tab: ^core.Tab, inner_w: f32) {
	th := theme()
	v := core.tab_status_view(tab^)
	ic, place := core.session_place(s)
	label := core.open_session_title(s)
	if ic != .Chat do label = fmt.tprintf("%s · %s", place, label)
	if len(s.tabs) > 0 && tab.id != s.tabs[0].id && tab.title != "" do label = fmt.tprintf("%s · %s", label, tab.title)
	mach := ""
	if state.settings.remote_machines && len(state.machines) > 0 do mach = s.machine == 0 ? "this Mac" : core.machine_name(s.machine)
	age := status_age(v)
	gap := px(GAP_INLINE)
	pad := px(SP_2) + px(SP_1)
	keys := true
	room :: proc(inner_w, pad, gap: f32, keys: bool, mach, age: string) -> f32 {
		r := inner_w - pad - px(MARK) - head_button_w("Open", keys ? "⌘↩" : "", true) - head_button_w("Close", keys ? "⌘W" : "", false) - 4 * gap // mark, title, spacer, Open, Close: four gaps
		if mach != "" do r -= text_w(mach, FONT_UI_SMALL) + gap
		if age != "" do r -= text_w(age, FONT_UI_SMALL) + gap
		return r
	}
	if room(inner_w, pad, gap, keys, mach, age) < px(120) do keys = false
	if room(inner_w, pad, gap, keys, mach, age) < px(80) do mach = ""
	if room(inner_w, pad, gap, keys, mach, age) < px(60) do age = ""
	title_w := max(room(inner_w, pad, gap, keys, mach, age), 0)
	if clay.UI(clay.ID("peek_head"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(PEEK_HEAD_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
	}) {
		status_mark_el(v)
		if clay.UI(clay.ID("peek_title"))({layout = {sizing = {clay.SizingFixed(title_w), clay.SizingFit()}}}) {
			clay.TextDynamic(clip(label, title_w, WEIGHT_BOLD), txt(th.text, WEIGHT_BOLD))
		}
		if mach != "" do clay.TextDynamic(mach, txt(th.text_muted, FONT_UI_SMALL))
		if age != "" do clay.TextDynamic(age, txt(th.text_muted, FONT_UI_SMALL))
		spacer()
		button(clay.ID("peek_open"), "Open", true, ui_hover == Hit(Hit_Peek(.Open)), keys ? "⌘↩" : "")
		button(clay.ID("peek_close"), "Close", false, ui_hover == Hit(Hit_Peek(.Close)), keys ? "⌘W" : "")
	}
}

// After the layout (frame): where the terminal goes. Its area is the panel's; a tab never laid
// out here gets that area's grid once (term_fit_rect); its copy is placed at its grid's own size
// from the area's top-left on whole pixels, its bottom rows in view when it is taller.
peek_after_layout :: proc() {
	peek.area = {}
	if !peek_is_open() do return
	d := clay.GetElementData(clay.ID("peek_term"))
	if !d.found || d.boundingBox.width <= 0 || d.boundingBox.height <= 0 do return
	bb := d.boundingBox
	a := [4]f32{math.round(bb.x), math.round(bb.y), math.floor(bb.width), math.floor(bb.height)}
	peek.area = a
	s := find_session(peek.session)
	if s != nil && s.machine == 0 && !peek.sized && peek.tab not_in term_fits {
		term_fit_rect(peek.tab, a.x, a.y, a.z, a.w) // the first size it gets in this window: the panel's
		peek.sized = true
	}
	v := term_view_peek(peek.tab)
	if v == nil do return
	gw := f32(v.cols) * font.cell_w + 2 * term_pad()
	gh := f32(v.rows) * font.cell_h + 2 * term_pad()
	v.x, v.w = a.x, max(a.z, gw)
	v.h = max(a.w, gh)
	v.y = gh > a.w ? a.y + a.w - math.ceil(gh) : a.y
}

// Inside the terminal's part of the panel (what is drawn there is hit there).
peek_in_term :: proc(x, y: f32) -> bool {
	a := peek.area
	return a.z > 0 && x >= a.x && x < a.x + a.z && y >= a.y && y < a.y + a.w
}

// The terminal, clipped to its area, and an input method's composition at its cursor (frame,
// after the panel's own commands, at the panel's fade).
peek_draw :: proc() {
	v := peek_view()
	a := peek.area
	if v == nil || a.z <= 0 || a.w <= 0 do return
	sgl.end()
	sgl.scissor_rect(i32(a.x), i32(a.y), i32(a.z), i32(a.w), true)
	sgl.begin_quads()
	term_draw(v)
	if ime.marked != "" do term_draw_marked(v, ime.marked, ime.caret)
	sgl.end()
	sgl.scissor_rect(0, 0, 1 << 15, 1 << 15, true)
	sgl.begin_quads()
}

// The range of the layout's commands that is the peek (its scrim, shadow and panel): [from, to).
peek_commands :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> (from, to: i32) {
	from = ui_overlay_start(cmds, "peek_scrim")
	to = cmds.length
	for i in from ..< cmds.length do if cmds.internalArray[i].zIndex > PEEK_Z_BOX {
		to = i
		break
	}
	return
}

// ---- hits and input ----

// What the pointer is over while peeking (ui_hit: nothing under the scrim is hit).
peek_hit :: proc() -> Hit {
	if clay.PointerOver(clay.ID("peek_open")) do return Hit_Peek(.Open)
	if clay.PointerOver(clay.ID("peek_close")) do return Hit_Peek(.Close)
	return nil
}

peek_tip :: proc(h: Hit_Peek) -> (string, string) {
	#partial switch Peek_Button(h) {
	case .Open:  return "Open it here: the tab on screen", "⌘↩"
	case .Close: return "Close the peek", "⌘W"
	}
	return "", ""
}

PEEK_ROW_TIP :: "Peek: look and answer without leaving what you are doing"

// The peek's own ⌘ chords. True: taken.
@(private = "file")
peek_key :: proc(e: ^sapp.Event) -> bool {
	m := e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT | sapp.MODIFIER_ALT | sapp.MODIFIER_CTRL)
	#partial switch e.key_code {
	case .ENTER, .KP_ENTER:
		if m != sapp.MODIFIER_SUPER do return false
		peek_go()
	case .W:
		if m != sapp.MODIFIER_SUPER do return false
		peek_close()
	case .A:
		switch m {
		case sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT, sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT | sapp.MODIFIER_CTRL: peek_next()
		case sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT: peek_next(back = true)
		case: return false
		}
	case .C:
		if m != sapp.MODIFIER_SUPER do return false
		ui_do(core.Copy_Selection{peek.tab}) // the window's copy's selection (core.window_term_selection)
	case .V:
		if m != sapp.MODIFIER_SUPER do return false // the paste itself comes as CLIPBOARD_PASTED
	case:
		return false
	}
	return true
}

// Input while peeking (main.odin event, before anything else takes it). True: taken. Only the
// peeked terminal and the panel's buttons get anything; a ⌘ chord that is not the peek's closes
// it and goes on (false), as do events that are not input (focus, resize, quit).
peek_event :: proc(e: ^sapp.Event) -> bool {
	if !peek_is_open() do return false
	peek_tick() // its tab, session or machine went: closed, and this event goes where it would
	if !peek_is_open() do return false
	v := term_view_of(peek.tab)
	_, tab, _ := find_tab(peek.tab)
	#partial switch e.type {
	case .KEY_DOWN:
		app.key_in_widget, app.key_taken = false, false
		if e.modifiers & sapp.MODIFIER_SUPER != 0 {
			if peek_key(e) {
				app.key_taken = true // its release goes nowhere
				app.redraw = true
				return true
			}
			// ⌘⌫ ⌘← ⌘→: line editing in the peeked program, as in a pane (mac_key_text)
			if mac_key_text(e.key_code, e.modifiers, false) != "" {
				if v != nil {
					core.claude_note_typed(tab)
					term_key_down(v, e)
				}
				return true
			}
			peek_close() // another ⌘ chord: the peek closes, and the chord does what it does
			return false
		}
		if v != nil {
			// as a pane's terminal: a Claude tab's prompt holds text now (Enter and Esc add none)
			if e.key_code != .ENTER && e.key_code != .KP_ENTER && e.key_code != .ESCAPE do core.claude_note_typed(tab)
			term_key_down(v, e)
		}
		return true
	case .KEY_UP:
		// (a key whose press opened or closed a peek, or was the peek's: its release goes nowhere)
		if !app.key_taken && v != nil && e.modifiers & sapp.MODIFIER_SUPER == 0 do term_key_up(v, e)
		return true
	case .CHAR:
		if !app.key_taken && v != nil && e.modifiers & sapp.MODIFIER_SUPER == 0 do term_char(v, e)
		return true
	case .CLIPBOARD_PASTED:
		core.claude_note_typed(tab)
		ui_do(core.Send_Text{peek.tab, clipboard_text()}) // the user's paste, as into a pane's tab
		return true
	case .MOUSE_DOWN:
		app.pointer = {e.mouse_x, e.mouse_y}
		app.redraw = true
		if peek_in_term(e.mouse_x, e.mouse_y) {
			if v == nil do return true
			// ⌘-click opens a link; a right click's link menu would open under the panel: the program's
			if e.modifiers & sapp.MODIFIER_SUPER != 0 && term_link_mouse_down(v, e) do return true
			term_mouse_down(v, e, app.clicks)
			return true
		}
		if h, ok := chrome_hit(app.pointer).(Hit_Peek); ok {
			#partial switch Peek_Button(h) {
			case .Open:  peek_go()
			case .Close: peek_close()
			}
			return true
		}
		if !inside(clay.ID("peek_box"), e.mouse_x, e.mouse_y) do peek_close() // the scrim: it closes, nothing else
		return true
	case .MOUSE_UP:
		if v != nil do term_mouse_up(v, e) // only a press it took (Term_View.mouse_down)
		return true
	case .MOUSE_MOVE:
		app.pointer = {e.mouse_x, e.mouse_y}
		over := peek_in_term(e.mouse_x, e.mouse_y)
		set_hover(over ? nil : chrome_hit(app.pointer), over)
		if v != nil do term_mouse_move(v, e)
		return true
	case .MOUSE_SCROLL:
		if v != nil && peek_in_term(e.mouse_x, e.mouse_y) do term_scroll(v, e)
		return true
	case .MOUSE_LEAVE:
		set_hover(nil, false)
		return true
	case .FILES_DROPPED, .MOUSE_ENTER:
		return true
	}
	return false
}

// ---- entry points ----

// Space on the Attention view's keyboard row (main.odin widget_event, the filter field): peeks
// at it when the row was picked with ↑↓ since the field was last typed in. True: taken.
attention_peek_key :: proc() -> bool {
	if !attention_keyed || attention_sel == 0 || state.sidebar.view != .Attention || state.layout.left_tab != .Sessions do return false
	listed := false
	for r in attention_shown() do if r.session.id == attention_sel do listed = true
	if !listed do return false
	if !peek_open_session(attention_sel) do toast_show("Nothing to peek at in this session: open it instead (Enter)")
	return true
}

// A bell entry's tab, when it can be peeked (its eye button).
bell_peek_tab :: proc(n: core.Notice) -> (^core.Open_Session, ^core.Tab) {
	if n.session == 0 || n.tab_id == 0 do return nil, nil
	s, tab, _ := find_tab(n.tab_id)
	if s == nil || s.id != n.session || !peek_ok(s, tab) do return nil, nil
	return s, tab
}
