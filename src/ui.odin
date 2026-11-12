package main

// Clay layout: left column (projects, then the selected project's sessions),
// the tab strip and terminal pane, and an optional right column; widths come
// from State.layout. Clay runs only on frames that redraw; its render
// commands are drawn with the same sokol_gl quads as the terminal. All units
// are framebuffer pixels; every size and colour comes from theme.odin.
//
// Motion: hover and selection fade (ease-out), a pulsing dot for running
// tabs, a one-shot flash when a status turns waiting, finished or error (and
// a copied terminal selection's shine). Each only redraws while it moves and
// is seen (ui_wants_frame); nothing animates while idle, and
// Settings.reduce_motion turns them all off.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "core"
import clay "../build/clay-odin"
import sgl "../vendor/sokol-odin/sokol/gl"

// Renaming the selected project (its row in the left column).
rename_field: Text_Field
rename_session: string // the Claude session whose row the rename field takes (focus widget rename_session; ui_sidebar.odin)

ui_memory: []u8

// What the pointer is over (from the last layout), for hover states.
ui_hover: Hit

ui_init :: proc() {
	// the agent's chat lays out a line per element: room for long chats
	clay.SetMaxElementCount(1 << 16)
	clay.SetMaxMeasureTextCacheWordCount(1 << 17)
	size := clay.MinMemorySize()
	ui_memory = make([]u8, size)
	arena := clay.CreateArenaWithCapacityAndMemory(uint(size), raw_data(ui_memory))
	clay.Initialize(arena, {1, 1}, {handler = ui_error})
	clay.SetMeasureTextFunction(ui_measure_text, nil)
}

ui_error :: proc "c" (e: clay.ErrorData) {
	context = core.app_context
	fmt.eprintln("clay:", e.errorType, string(e.errorText.chars[:e.errorText.length]))
}

// Clay's fontId = font kind | FONT_BOLD (font.odin); UI text is proportional.
ui_measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user: rawptr) -> clay.Dimensions {
	context = core.app_context
	kind, bold := font_id_split(config.fontId)
	return {text_width(string(text.chars[:text.length]), kind, bold, font_id_italic(config.fontId), font_id_semibold(config.fontId)), text_line_height(kind)}
}

// ---- token helpers ----

px :: proc(v: f32) -> f32 {return v * app.dpi}
pu :: proc(v: f32) -> u16 {return u16(math.round(v * app.dpi))}
cc :: proc(c: core.Rgba) -> clay.Color {return {f32(c.r), f32(c.g), f32(c.b), f32(c.a)}}
to_rgba :: proc(c: clay.Color) -> core.Rgba {return {u8(c.r), u8(c.g), u8(c.b), u8(c.a)}}

with_alpha :: proc(c: core.Rgba, k: f32) -> core.Rgba {return {c.r, c.g, c.b, u8(f32(c.a) * clamp(k, 0, 1))}}

mix :: proc(a, b: core.Rgba, t: f32) -> core.Rgba {
	k := clamp(t, 0, 1)
	l :: proc(x, y: u8, k: f32) -> u8 {return u8(math.round(f32(x) + (f32(y) - f32(x)) * k))}
	return {l(a.r, b.r, k), l(a.g, b.g, k), l(a.b, b.b, k), l(a.a, b.a, k)}
}

txt :: proc(col: core.Rgba, weight: u16 = WEIGHT_REGULAR) -> clay.TextElementConfig {
	return {textColor = cc(col), fontId = weight, wrapMode = .None}
}

text_w :: proc(s: string, weight: u16 = WEIGHT_REGULAR) -> f32 {
	kind, bold := font_id_split(weight)
	return text_width(s, kind, bold, font_id_italic(weight), font_id_semibold(weight))
}

// Clips s to max_w pixels (temp allocator when cut), with an ellipsis.
clip :: proc(s: string, max_w: f32, weight: u16 = WEIGHT_REGULAR) -> string {
	kind, bold := font_id_split(weight)
	return text_clip(s, max_w, kind, bold, font_id_italic(weight), font_id_semibold(weight))
}

// s as at most max_lines lines no wider than max_w, joined with "\n" (temp
// allocator; draw with wrapMode .Newlines): broken at spaces, a word wider
// than a line cut between characters, the last line cut with an ellipsis
// when text is left over. n: the number of lines.
wrap_clip :: proc(s: string, max_w: f32, max_lines: int, weight: u16 = WEIGHT_REGULAR) -> (text: string, n: int) {
	kind, bold := font_id_split(weight)
	flat, _ := strings.replace_all(s, "\n", " ", context.temp_allocator)
	rest := strings.trim_space(flat)
	if rest == "" || max_w <= 0 || max_lines <= 0 do return "", 0
	b := strings.builder_make(context.temp_allocator)
	for rest != "" {
		if n > 0 do strings.write_byte(&b, '\n')
		n += 1
		fit := text_fit(rest, max_w, kind, bold, font_id_italic(weight), font_id_semibold(weight))
		if n == max_lines || fit == len(rest) {
			strings.write_string(&b, clip(rest, max_w, weight))
			break
		}
		cut := strings.last_index_byte(rest[:fit + 1], ' ') // a space right after the fit breaks there too
		if cut <= 0 {
			cut = fit
			if cut == 0 do _, cut = utf8.decode_rune_in_string(rest) // not even one character fits: one per line
		}
		strings.write_string(&b, strings.trim_right_space(rest[:cut]))
		rest = strings.trim_left_space(rest[cut:])
	}
	return strings.to_string(b), n
}

// "2026-08-21 01:20" (UTC, from the file name) -> "now", "5m", "3h", "2d", "6w", "1y".
rel_time :: proc(when_: string) -> string {
	if len(when_) < 16 do return ""
	n :: proc(s: string) -> int {v, _ := strconv.parse_int(s); return v}
	t, ok := time.components_to_time(n(when_[0:4]), n(when_[5:7]), n(when_[8:10]), n(when_[11:13]), n(when_[14:16]), 0)
	if !ok do return ""
	m := int(time.duration_minutes(time.since(t)))
	switch {
	case m < 1:              return "now"
	case m < 60:             return fmt.tprintf("%dm", m)
	case m < 24 * 60:        return fmt.tprintf("%dh", m / 60)
	case m < 7 * 24 * 60:    return fmt.tprintf("%dd", m / (24 * 60))
	case m < 365 * 24 * 60:  return fmt.tprintf("%dw", m / (7 * 24 * 60))
	}
	return fmt.tprintf("%dy", m / (365 * 24 * 60))
}

// ---- motion ----

Fade :: struct {
	from, to, value: f32,
	t0:              time.Tick,
}

@(private = "file")
fades: map[u32]Fade
@(private = "file")
animating: bool // a fade is mid-way: draw the next frame
@(private = "file")
pulsing: bool // a running dot is on screen: draw at PULSE_FPS
@(private = "file")
pulse_drawn: i64 // pulse step of the last drawn frame

@(private = "file")
pulse_step :: proc() -> i64 {
	// reduce motion: the dot is static; redraw once a second so it still
	// turns idle when output stops
	step := state.settings.reduce_motion ? time.Second : time.Second / PULSE_FPS
	return time.tick_now()._nsec / i64(step)
}

// Eases towards target (0..1) over dur; returns the current value. An
// element seen for the first time starts at its target.
fade :: proc(id: clay.ElementId, salt: u32, target: f32, dur: time.Duration) -> f32 {
	key := id.id ~ salt
	f, seen := fades[key]
	if !seen || state.settings.reduce_motion {
		fades[key] = {from = target, to = target, value = target}
		return target
	}
	if f.to != target do f.from, f.to, f.t0 = f.value, target, time.tick_now()
	k := f32(time.duration_seconds(time.tick_since(f.t0)) / time.duration_seconds(dur))
	if k >= 1 {
		f.value = f.to
	} else {
		e := 1 - (1 - k) * (1 - k) * (1 - k) // ease-out cubic
		f.value = f.from + (f.to - f.from) * e
		animating = true
	}
	fades[key] = f
	return f.value
}

// PULSE_MIN..1 brightness of a running dot, stepped at PULSE_FPS.
@(private = "file")
pulse :: proc() -> f32 {
	pulsing = true // keeps redraws coming until no running dot is left
	if state.settings.reduce_motion do return 1
	period := f64(PULSE_PERIOD) / f64(time.Second)
	t := f64(time.tick_now()._nsec / i64(time.Second / PULSE_FPS)) / PULSE_FPS
	wave := 0.5 + 0.5 * math.cos(2 * math.PI * t / period) // 1 -> 0 -> 1
	return PULSE_MIN + (1 - PULSE_MIN) * f32(wave)
}

// True if the next frame must be drawn for motion alone, or once more after the right column's
// offset was clamped (that layout was built at the old one).
ui_wants_frame :: proc() -> bool {
	again := panels_clamped
	panels_clamped = false
	return again || animating || peek_moving || flash_seen || shine_drawn || pane_motion.moving || ((pulsing || spinning) && pulse_step() != pulse_drawn) || (ages_shown && age_minute() != age_minute_drawn)
}

// ---- flash: a one-shot 1 -> 0 ----

Flash :: struct {
	stamp: i64, // what it last saw (0 = at rest)
	t0:    time.Tick, // when stamp last changed to a non-zero one; {} = done
}

FLASHES_MAX :: 512 // entries kept; past it the ones at rest go (flash_prune)
FLASH_LIT_MAX :: 16

@(private = "file")
flashes: map[u64]Flash
@(private = "file")
flash_lit: [FLASH_LIT_MAX]u32 // the elements that host a running flash this layout (flash_host)
@(private = "file")
flash_lit_n: int
@(private = "file")
flash_seen: bool // one of them is drawn where it can be seen (motion_visible): draw the next frame
@(private = "file")
shine_drawn: bool // a terminal drew a copy shine this frame (term_draw): draw the next one

// 1 the frame stamp changes for key (to anything but 0), decaying linearly to 0 over dur; 0 at
// rest, for stamp 0 and under Reduce motion. A key first seen with a stamp starts too (the caller
// decides what is new: status_flash). No allocation but a new key's entry; the table is bounded.
flash :: proc(key: u64, stamp: i64, dur: time.Duration = DUR_FLASH) -> f32 {
	return flash_at(key, stamp, dur, time.tick_now())
}

flash_at :: proc(key: u64, stamp: i64, dur: time.Duration, now: time.Tick) -> f32 {
	f, seen := flashes[key]
	if !seen || f.stamp != stamp {
		if !seen && len(flashes) >= FLASHES_MAX do flash_prune()
		f = {stamp = stamp}
		if stamp != 0 && !state.settings.reduce_motion do f.t0 = now
		flashes[key] = f
	}
	if f.t0 == {} do return 0
	if state.settings.reduce_motion {
		flashes[key] = {stamp = stamp}
		return 0
	}
	k := f32(time.duration_seconds(time.tick_diff(f.t0, now)) / time.duration_seconds(dur))
	if k >= 1 || k < 0 {
		flashes[key] = {stamp = stamp}
		return 0
	}
	return 1 - k
}

// Entries at rest go (a running one stays): the table never grows past FLASHES_MAX for long.
@(private = "file")
flash_prune :: proc() {
	rest := make([dynamic]u64, context.temp_allocator)
	for k, f in flashes do if f.t0 == {} do append(&rest, k)
	for k in rest do delete_key(&flashes, k)
}

// The element id drawing a running flash: frames come while it is on screen (motion_visible).
flash_host :: proc(id: clay.ElementId) {
	if flash_lit_n < FLASH_LIT_MAX do flash_lit[flash_lit_n] = id.id
	flash_lit_n += 1 // past the table: frames, seen or not (motion_visible)
}

// A terminal drew a shine (term_view.odin): the next frame is drawn too.
shine_frame :: proc() {shine_drawn = true}

// Whether the last layout has a running flash where it can be seen (tests).
ui_flashing :: proc() -> bool {return flash_seen}

// Every flash back to its start (tests: n ms ago).
flash_age_for_test :: proc(d: time.Duration) {
	for _, &f in flashes do if f.t0 != {} do f.t0 = time.tick_add(f.t0, -d)
}

flashes_for_test :: proc() -> map[u64]Flash {return flashes}

flash_reset_for_test :: proc() {
	clear(&flashes)
	flash_quiet_until = {}
	clear(&flash_machines)
}

// ---- status flash: a row or tab whose status turns waiting, finished or error ----

// Statuses before this began with the window's link (flash_quiet): a connect's rows stay still.
@(private = "file")
flash_quiet_until: time.Time

Flash_Machine :: struct {
	live:  bool,
	until: time.Time,
}
@(private = "file")
flash_machines: map[u64]Flash_Machine

// The window's link to the core is (again) up: statuses that came with it do not flash.
flash_quiet :: proc(now := time.Time{}) {
	now := now != {} ? now : time.now()
	flash_quiet_until = time.time_add(now, FLASH_SETTLE)
}

// The statuses that flash: the ones that ask for the user (waiting, a question, finished not seen,
// an error). Working and idle change too often.
status_flashes :: proc(dot: core.Row_Status) -> bool {
	#partial switch dot {
	case .Waiting, .Question, .Unseen, .Error: return true
	}
	return false
}

// The colour a status washes its row and tab in.
flash_color :: proc(dot: core.Row_Status) -> core.Rgba {
	th := theme()
	#partial switch dot {
	case .Waiting, .Question: return th.waiting
	case .Error:              return th.error
	case .Unseen:             return th.accent
	}
	return {}
}

// A row's or tab's flash for its status v (1 -> 0; key: what it is, stable across reorders),
// drawn on element host. machine: whose status (0 = this Mac's), live: that machine is online.
// It starts when v's status began (since) a moment ago, as a status that flashes, after that
// machine's link settled; a repeat report keeps since, so it never starts again.
status_flash :: proc(host: clay.ElementId, key: u64, v: core.Tab_Status_View, machine: u64 = 0, live := true, now := time.Time{}) -> f32 {
	now := now != {} ? now : time.now()
	if flash_quiet_until == {} do flash_quiet(now) // the window's first frames
	quiet := flash_quiet_until
	if machine != 0 {
		m, seen := flash_machines[machine]
		if !seen || (live && !m.live) do m.until = time.time_add(now, FLASH_SETTLE) // its link came up
		m.live = live
		flash_machines[machine] = m
		if time.diff(quiet, m.until) > 0 do quiet = m.until
	}
	stamp: i64
	if live && status_flashes(v.dot) && v.since != {} && time.diff(v.since, now) < FLASH_FRESH && time.diff(quiet, v.since) > 0 do stamp = v.since._nsec
	r := flash(key, stamp)
	if r > 0 do flash_host(host)
	return r
}

// bg with a status's wash over it, at FLASH_ALPHA * r² (r: status_flash's 1 -> 0, so it eases out).
flash_wash :: proc(bg: clay.Color, dot: core.Row_Status, r: f32) -> clay.Color {
	if r <= 0 do return bg
	c := flash_color(dot)
	wa := FLASH_ALPHA * r * r * f32(c.a) / 255
	ba := bg.a / 255
	oa := wa + ba * (1 - wa)
	if oa <= 0 do return bg
	out: clay.Color
	for i in 0 ..< 3 do out[i] = (f32(c[i]) * wa + bg[i] * ba * (1 - wa)) / oa
	out[3] = oa * 255
	return out
}

// A mark's size while it flashes (r 1 -> 0): it grows to 1 + FLASH_POP soon after the start and
// settles back to 1 by FLASH_POP_PART of the flash (a fast rise, a slower settle); 1 at rest.
flash_pop :: proc(r: f32) -> f32 {
	k := (1 - r) / FLASH_POP_PART
	if r <= 0 || k >= 1 do return 1
	return 1 + FLASH_POP * math.sin(math.PI * math.sqrt(max(k, 0)))
}

@(private = "file")
spinning: bool // a working mark turns where it can be seen (spin_visible): draw at PULSE_FPS

// Whether the last layout has a turning mark on screen (tests).
ui_spinning :: proc() -> bool {return spinning}

// Whether a working mark (spin) and a running flash's element (lit: flash_host) are drawn where
// they can be seen: inside the window and the list that clips them. Motion off (Reduce motion):
// they hold still, and ask for nothing.
@(private = "file")
motion_visible :: proc(cmds: clay.ClayArray(clay.RenderCommand), w, h: f32) -> (spin, lit: bool) {
	if state.settings.reduce_motion do return false, false
	if flash_lit_n > FLASH_LIT_MAX do lit = true // more than the table holds: frames until they end
	clip := [4]f32{0, 0, w, h}
	stack: [dynamic][4]f32
	stack.allocator = context.temp_allocator
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		b := c.boundingBox
		seen := b.x < clip[2] && b.x + b.width > clip[0] && b.y < clip[3] && b.y + b.height > clip[1]
		#partial switch c.commandType {
		case .ScissorStart:
			append(&stack, clip)
			clip = {max(clip[0], b.x), max(clip[1], b.y), min(clip[2], b.x + b.width), min(clip[3], b.y + b.height)}
		case .ScissorEnd:
			if len(stack) > 0 do clip = pop(&stack)
		case .Rectangle:
			// a washed row or tab (its background is drawn while the wash shows)
			if !lit && seen do for x in flash_lit[:min(flash_lit_n, FLASH_LIT_MAX)] do if x == c.id do lit = true
		case .Custom:
			ic, _, _ := icon_of_command(c)
			if ic == .Mark_Working && seen do spin = true
		}
		if spin && lit do break
	}
	return
}

@(private = "file")
ages_shown: bool // a status's age ("4m") is on screen: draw again when the minute turns
@(private = "file")
age_minute_drawn: i64

@(private = "file")
age_minute :: proc() -> i64 {return time.now()._nsec / i64(time.Minute)}

// How long a status has been what it is ("now", "4m", "1h"): "" with no status (none, or a dead
// tab's) or no known start. Keeps the row's age fresh: a frame when the minute turns.
status_age :: proc(v: core.Tab_Status_View) -> string {
	if v.dot == .None || v.dot == .Exited || v.since == {} do return ""
	ages_shown = true
	return core.ago(v.since)
}

// ---- status ----

// A tab's status in the tab strip: its status (the bridge, OSC 7501 or unseen:
// agent_status.odin), else recent output or an agent acting in a browser tab.
tab_strip_view :: proc(tab: core.Tab, active: bool) -> core.Tab_Status_View {
	view := core.tab_status_view(tab)
	_, is_pi := tab.kind.(core.Pi_Tab)
	if view.dot != .None || is_pi do return view // a status (done or idle: none) leaves room for recent output
	if tab.status == .Running && tab.output_recent do view.dot = .Running // recent output (the core's terminal, in the replica's record)
	else if !active && browser_act_recent(tab.id) do view.dot = .Running // an agent acts in this tab behind (browser_act.odin)
	return view
}

tab_strip_status :: proc(tab: core.Tab, active: bool) -> core.Row_Status {return tab_strip_view(tab, active).dot}

// Whether a tab has a status mark: every tab that can have a status (a terminal, a page an agent
// may act in) keeps its mark's room, a quiet dot while nothing goes on, so it never moves.
tab_shows_mark :: proc(tab: core.Tab) -> bool {
	#partial switch _ in tab.kind {
	case core.Pi_Tab, core.Shell_Tab, core.Claude_Tab, core.Browser_Tab: return true
	}
	return tab.has_term
}


status_color :: proc(st: core.Row_Status) -> core.Rgba {
	th := theme()
	switch st {
	case .None:     return {}
	case .Running:  return with_alpha(th.running, pulse())
	case .Waiting:  return th.waiting
	case .Question: return with_alpha(th.waiting, QUESTION_ALPHA)
	case .Error:    return th.error
	case .Exited:   return with_alpha(th.text_muted, EXITED_ALPHA)
	case .Unseen:   return th.accent // "finished, not seen yet": the accent, as unread is in the Jobs tab and the bell (green is "online", "ran ok")
	}
	return {}
}

// The icon each status mark is drawn with (icons.odin draw_mark).
MARK_ICONS := [core.Status_Mark]core.Icon {
	.None       = .None,
	.Idle       = .Mark_Idle,
	.Exited     = .Mark_Exited,
	.Working    = .Mark_Working,
	.Progress   = .Mark_Progress,
	.Waiting    = .Mark_Waiting,
	.Permission = .Mark_Permission,
	.Question   = .Mark_Question,
	.Auth       = .Mark_Auth,
	.Done       = .Mark_Done,
	.Error      = .Mark_Error,
}

// A status mark's colour: its status's (status_color), but working is steady (the arc's turn is
// its motion, not a pulse) and idle is a quiet grey.
mark_color :: proc(m: core.Status_Mark, st: core.Row_Status) -> core.Rgba {
	th := theme()
	#partial switch m {
	case .None:              return {}
	case .Idle:              return with_alpha(th.text_muted, IDLE_ALPHA)
	case .Working, .Progress: return th.running
	}
	return status_color(st)
}

// A working mark's step: it turns at PULSE_FPS while one is on screen (spin_visible); still under
// Reduce motion.
@(private = "file")
spin_step :: proc() -> u8 {
	if state.settings.reduce_motion do return 0
	return u8(pulse_step() % SPIN_STEPS) // its frames: spin_visible, after the layout
}

// A status's mark (core.status_mark), MARK px square: every state the same box, so a row or tab
// never moves when its status changes. flash: its row's status_flash (the mark pops: flash_pop,
// drawn larger about its centre; the box stays).
status_mark_el :: proc(v: core.Tab_Status_View, flash: f32 = 0) {
	m := core.status_mark(v)
	param: u8
	#partial switch m {
	case .Working:  param = spin_step()
	case .Progress: param = u8(clamp(v.progress, 0, 1) * 100 + 0.5)
	}
	icon(MARK_ICONS[m], mark_color(m, v.dot), MARK, param, flash_pop(flash))
}

// A mark in a colour of its own (the fleet's counts, ui_fleet.odin): working turns as every
// working mark does (spin_visible gives it frames only where it is seen).
mark_el :: proc(m: core.Status_Mark, col: core.Rgba) {
	icon(MARK_ICONS[m], col, MARK, m == .Working ? spin_step() : 0)
}

// ---- building blocks ----

SALT_SELECT :: 0x9e3779b9
// status_flash keys: a tab's and an open row's flash are their own (by tab or session id, never
// the element's index: rows reorder when they turn waiting)
SALT_FLASH_TAB :: 0x5bd1e995_00000000
SALT_FLASH_ROW :: 0x27d4eb2f_00000000
SALT_SHINE :: 0x165667b1_00000000

// Background of a row/tab/button: selection and hover overlays, faded.
overlay :: proc(id: clay.ElementId, selected, hovered: bool) -> (bg: clay.Color, emphasis: f32) {
	th := theme()
	s := fade(id, SALT_SELECT, selected ? 1 : 0, DUR_SWITCH)
	h := fade(id, 0, hovered ? 1 : 0, DUR_HOVER)
	a := f32(th.selected.a) * s + f32(th.hover.a) * h
	return cc({th.selected.r, th.selected.g, th.selected.b, u8(min(a, 255))}), max(s, h)
}

row_cfg :: proc(bg: clay.Color, direction := clay.LayoutDirection.LeftToRight) -> clay.ElementDeclaration {
	return {
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))},
			padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0},
			childGap = pu(GAP_INLINE),
			childAlignment = {y = .Center},
			layoutDirection = direction,
		},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}
}

spacer :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {}
}

gap :: proc(h: f32) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(h))}}}) {}
}

dot :: proc(col: core.Rgba) {
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(px(DOT)), clay.SizingFixed(px(DOT))}},
		backgroundColor = cc(col),
		cornerRadius = clay.CornerRadiusAll(px(DOT / 2)),
	}) {}
}

@(private = "file")
section_header :: proc(id: clay.ElementId, label: string) {
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
	}) {
		clay.TextDynamic(label, txt(theme().text_muted, WEIGHT_BOLD))
	}
}

// A thin vertical line between button groups, GAP_GROUP wide.
group_separator :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_GROUP)), clay.SizingFixed(px(SEPARATOR_H))}, childAlignment = {x = .Center}}}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(core.BORDER_W)), clay.SizingGrow()}}, backgroundColor = cc(theme().border)}) {}
	}
}

// The centre's width (framebuffer px): the window less the columns and a
// pinned agent drawer.
centre_width :: proc() -> f32 {
	left, right := column_widths()
	w := ui_win_w - (left + right) * app.dpi
	if state.layout.drawer_pinned && state.home_open && core.home_tab() != nil do w -= drawer_w()
	return w
}

// Two lines in a list that has nothing to show.
empty_state :: proc(title, hint: string, width: f32) {
	th := theme()
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), pu(SP_2), pu(SP_2), pu(SP_2)}, childGap = pu(SP_1), layoutDirection = .TopToBottom},
	}) {
		room := width - px(2 * SP_2)
		clay.TextDynamic(clip(title, room), txt(th.text_secondary))
		clay.TextDynamic(clip(hint, room), txt(th.text_muted))
	}
}

// ---- layout ----

// Layout passes so far (ui_layout): what was laid out in the last one is on screen.
ui_layout_pass: u64

ui_layout :: proc(w, h: f32) -> clay.ClayArray(clay.RenderCommand) {
	ui_layout_pass += 1
	animating, pulsing, ages_shown = false, false, false
	flash_lit_n, shine_drawn = 0, false
	drawer_laid_out = false
	pulse_drawn = pulse_step()
	age_minute_drawn = age_minute()
	ui_win_w = w
	fleet_tally_frame() // once per frame: the pill's, the machine headers', the Dock's (ui_fleet.odin)
	clay.SetLayoutDimensions({w, h})
	clay.BeginLayout()
	cs := core.cur_view() // another machine's session too: its tab bar and "Connecting…"
	palette_sync()
	if clay.UI(clay.ID("root"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .LeftToRight},
		backgroundColor = cc(theme().bg_app),
	}) {
		sidebar(cs, h)
		// the top bar (tabs) spans the centre and the right column; it is
		// the window's title bar too (empty parts drag the window)
		if clay.UI(clay.ID("main"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
			tab_strip(cs, w)
			if len(state.pending_confirmations) > 0 do confirm_bar(state.pending_confirmations[0])
			if clay.UI(clay.ID("body"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .LeftToRight}}) {
				centre(cs)
				if state.layout.right_open do right_column(cs)
				if state.layout.drawer_pinned do drawer_pinned_column()
			}
		}
		if !state.layout.drawer_pinned do drawer_floating(w, h)
		files_drag_layout()
		tab_drag_layout() // a tab being dragged: its drop indicator and ghost (panes_drag.odin)
		wt_menu_layout(w, h)
		menu_layout(w, h)
		settings_layout(w, h)
		bell_layout(w, h)
		shortcuts_layout(w, h)
		setup_layout(w, h) // the first-run sheet (ui_setup.odin)
		job_sheet_layout(w, h) // the job sheet (ui_job_sheet.odin)
		peek_layout(w, h) // a peeked tab over the centre (ui_peek.odin)
		if palette_is_open() do palette_layout(w, h)
		term_link_tip_layout() // a terminal link's URL while ⌘ is held (term_links.odin)
		toast_layout(w, h) // a menu choice's outcome (toast.odin)
		tooltip_layout(w, h)
	}
	cmds := clay.EndLayout(0)
	spinning, flash_seen = motion_visible(cmds, w, h) // frames for a turning mark or a flash only where it is seen
	pane_motion_layout(cs) // split panes: dim, the focus line's glide, a zoom's outline (ui_pane_motion.odin)
	if panels_scroll_clamp() do panels_clamped = true // drawn again at the clamped offset (ui_wants_frame)
	return cmds
}

// A text field's text (with an input method's composition at the caret);
// the caret, selection and composition underline are drawn after the
// layout (ui_draw_field_cursor).
field_text :: proc(id: clay.ElementId, f: ^Text_Field, placeholder: string) {
	th := theme()
	shown, _, _ := tf_display(f, ime.marked)
	if clay.UI(id)({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
		if shown == "" && placeholder != "" do clay.TextDynamic(placeholder, txt(th.text_muted))
		else do clay.TextDynamic(shown, txt(th.text))
	}
}

// The focused text field, its text element and its box (for clicks).
focused_field :: proc() -> (f: ^Text_Field, text_id, box_id: clay.ElementId) {
	if job_sheet_open() do return &job_sheet.fields[job_sheet.focus], clay.ID("jstext"), clay.ID("jsfield", u32(job_sheet.focus))
	if setup_open() && setup_ui.edit != SETUP_EDIT_NONE do return &setup_ui.field, clay.ID("setup_field_text"), clay.ID("setup_field_box") // the setup sheet's accounts step
	switch state.focus_widget {
	case "rename_project", "rename_session": return &rename_field, clay.ID("rename_text"), clay.ID("rename_field")
	case "palette":        return &palette.field, clay.ID("palette_text"), clay.ID("palette_input")
	case "sidebar_filter": return &filter_field, clay.ID("filter_text"), clay.ID("filter_box")
	case "files_filter":   return &files_filter_field, clay.ID("files_filter_text"), clay.ID("files_filter_box")
	case "files_name":     return &files_name_field, clay.ID("files_name_text"), clay.ID("files_name_box")
	case "changes_message": return &changes_message_field, fid("ch_field_text"), fid("ch_field")
	case "comment_edit":   return &comment_edit_field, clay.ID("cm_edit_text"), clay.ID("cm_edit_box")
	case "comment_new":    return &comment_new_field, clay.ID("cm_new_text"), clay.ID("cm_new_box")
	case "browser_url":    return &browser_url_field, fid("br_url_text"), fid("br_url_box") // browser_nav.odin
	case "browser_find":   return &page_find_field, fid("pg_find_text"), fid("pg_find_box") // browser_polish.odin
	case "browser_prompt": return &page_prompt_field, fid("pg_prompt_text"), fid("pg_prompt_box")
	case:                  return editor_focused_field()
	}
}

// A per-tab bar's field id: the focused pane's (the keyboard's field is always in it), wherever
// the pointer or the layout is.
@(private = "file")
fid :: proc(name: string) -> clay.ElementId {return pid(core.focused_pane(), name)}

// A press on the focused field's box (focused_field): a pane's field (fid, the editor's bars) only
// inside its pane, where it shows (pane_inside: a field reaching past a narrow pane's edge is cut
// there); the others anywhere on their box.
field_inside :: proc(box_id: clay.ElementId, x, y: f32) -> bool {
	switch state.focus_widget {
	case "changes_message", "browser_url", "browser_find", "browser_prompt", "editor_find", "editor_replace", "editor_goto":
		return pane_inside(core.focused_pane(), box_id, x, y)
	}
	return inside(box_id, x, y)
}

// ---- command palette ----

// A scrim over the window and a box near its top: the query field, then the
// results. Drawn above the terminal (ui_draw draws the terminal first).
@(private = "file")
palette_layout :: proc(w, h: f32) {
	th := theme()
	rs := palette_results()
	palette.selected = clamp(palette.selected, 0, max(len(rs) - 1, 0))
	palette_keep_visible()
	box_w := px(PALETTE_W)
	if clay.UI(clay.ID("palette_scrim"))({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}, padding = {0, 0, pu(PALETTE_TOP), 0}, childAlignment = {x = .Center}},
		backgroundColor = cc(th.scrim),
		floating = {attachTo = .Root, zIndex = 10},
	}) {
		if clay.UI(clay.ID("palette_box"))({
			layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(SP_2))},
			backgroundColor = cc(th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
		}) {
			if clay.UI(clay.ID("palette_input"))({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H + SP_2))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
			}) {
				field_text(clay.ID("palette_text"), &palette.field, palette.files ? "Open a file in this project" : palette.apps ? "A command to run in an app tab" : palette.pages ? "A port on that machine, e.g. 3000 or 3000/admin" : palette.machine_pick == .Remove ? "Which machine to remove" : palette.machine_pick == .Connect ? "Which machine to connect to" : "Search actions, tabs, sessions, projects")
			}
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}}, backgroundColor = cc(th.border)}) {}
			gap(SP_1)
			if len(rs) == 0 {
				empty_state("No matches", "Try fewer letters", box_w - px(2 * SP_2))
			}
			for i in palette.first ..< min(len(rs), palette.first + PALETTE_ROWS) {
				palette_row(rs[i], i, box_w - px(2 * SP_2))
			}
		}
	}
}

@(private = "file")
palette_row :: proc(it: Palette_Item, i: int, width: f32) {
	th := theme()
	id := clay.ID("palrow", u32(i))
	sel := i == palette.selected
	bg, _ := overlay(id, sel, ui_hover == Hit(Hit_Palette_Row(i)))
	if clay.UI(id)(row_cfg(bg)) {
		inner := width - px(2 * PAD_ROW)
		right := it.hint != "" ? it.hint : (it.chat ? "Chat" : PALETTE_KIND_NAMES[it.kind])
		// where a session or project is: a folder (a project) or a bubble (a chat)
		ic := core.Icon.None
		if it.kind == .Project || it.kind == .Session do ic = it.chat ? .Chat : .Folder
		room := inner - max(px(PALETTE_KIND_W), text_w(right)) - 2 * px(GAP_INLINE) // a spacer between title and kind
		if ic != .None do room -= px(KIND_ICON + GAP_INLINE)
		detail := clip(it.detail, room * 0.4)
		if detail != "" do room -= text_w(detail) + px(GAP_INLINE)
		title := clip(it.title, room)
		if ic != .None do icon(ic, th.text_muted, KIND_ICON)
		// matched characters at full strength, the rest secondary
		if clay.UI()({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
			start, ri := 0, 0
			cur_on := false
			for _, off in title {
				on := ri < 64 && it.matched & (1 << u64(ri)) != 0
				if off > start && on != cur_on {
					clay.TextDynamic(title[start:off], txt(cur_on ? th.text : th.text_secondary, cur_on ? WEIGHT_BOLD : WEIGHT_REGULAR))
					start = off
				}
				cur_on = on
				ri += 1
			}
			if start < len(title) do clay.TextDynamic(title[start:], txt(cur_on ? th.text : th.text_secondary, cur_on ? WEIGHT_BOLD : WEIGHT_REGULAR))
		}
		if detail != "" do clay.TextDynamic(detail, txt(th.text_muted))
		spacer()
		clay.TextDynamic(right, txt(th.text_muted))
	}
}

@(private = "file")
centre :: proc(cs: ^core.Open_Session) {
	if clay.UI(clay.ID("centre"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
		update_bar() // a Deckhand update: available, downloading, ready (ui_update.odin)
		reload_bars() // hot reload: pi settings changed, pi updated (ui_reload.odin)
		claude_reload_bars() // and Claude Code's (ui_claude_reload.odin)
		comments_bars() // pending comments: the close prompt, the strip and its list (ui_comments.odin)
		machine_bar() // another machine's session while it is not online (ui_dead_tab.odin)
		// the session's panes (panes.odin): its layout tree, or its one (implicit) pane
		if clay.UI(clay.ID("panes"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			// zoomed (zoom_pane): that pane alone fills the area; the others are not laid out (not drawn, not hit)
			if zp := core.session_pane(cs, core.session_zoomed(cs)); zp != nil do pane_layout(cs, zp)
			else if cs != nil && len(cs.nodes) > 0 && len(cs.panes) > 0 do pane_tree_layout(cs, cs.root)
			else do pane_layout(cs, core.session_focused_pane(cs))
		}
	}
}

// A node of cs's layout tree: a split lays out child a at its share, the divider, then child b
// in the rest (so b takes the divider and any rounding); a leaf, its pane.
@(private = "file")
pane_tree_layout :: proc(cs: ^core.Open_Session, n: int) {
	node := cs.nodes[n]
	if node.leaf {
		pane_layout(cs, core.session_pane(cs, node.pane))
		return
	}
	th := theme()
	across := node.dir == .Right
	ratio := pane_drag_ratio(node.id, node.ratio) // a divider being dragged: where it is now
	// kept off the panes' minimum sizes at the split's last laid-out size (pane_rects does the same);
	// not laid out last frame (a zoom just ended): its place in the tree inside the last centre
	if d := clay.GetElementData(clay.ID("pane_split", u32(node.id))); d.found {
		kept := core.pane_split_share(cs, n, ratio, (across ? d.boundingBox.width : d.boundingBox.height) - px(core.BORDER_W), app.dpi)
		if abs(kept - ratio) > 0.0005 do app.redraw = true // laid out at last frame's size: once more at this one's
		ratio = kept
	} else if app.centre.z > 0 {
		div, mw, mh := core.pane_mins(app.dpi)
		if r, ok := core.pane_split_rect(cs, node.id, {0, 0, app.centre.z, app.centre.w}, div, mw, mh); ok {
			ratio = core.pane_split_share(cs, n, ratio, (across ? r.z : r.w) - div, app.dpi)
		}
	}
	sz_a := across ? clay.Sizing{clay.SizingPercent(ratio), clay.SizingGrow()} : clay.Sizing{clay.SizingGrow(), clay.SizingPercent(ratio)}
	sz_div := across ? clay.Sizing{clay.SizingFixed(px(core.BORDER_W)), clay.SizingGrow()} : clay.Sizing{clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}
	if clay.UI(clay.ID("pane_split", u32(node.id)))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = across ? .LeftToRight : .TopToBottom}}) {
		if clay.UI(clay.ID("pane_side_a", u32(node.id)))({layout = {sizing = sz_a}}) do pane_tree_layout(cs, node.a)
		hot := pane_divider_hot(node.id)
		if clay.UI(clay.ID("pane_div", u32(node.id)))({layout = {sizing = sz_div}, backgroundColor = cc(hot ? th.accent : th.border)}) {}
		if clay.UI(clay.ID("pane_side_b", u32(node.id)))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) do pane_tree_layout(cs, node.b)
	}
}

// One pane: its strip when the session is split (the tabs leave the title bar), its tab's bars,
// then its content (pid(p, "pane_body"): the rect its tabs are sized to) holding the
// "terminal" element its tab draws in. Every id inside is the pane's (cid, pid).
@(private = "file")
pane_layout :: proc(cs: ^core.Open_Session, p: ^core.Pane) {
	th := theme()
	old := ids_pane_begin(p)
	defer ids_pane_end(old)
	split := cs != nil && len(cs.panes) > 1
	shown := core.pane_tab(cs, p) // another machine's too: its terminals are relayed
	empty := (shown == nil || !shown.has_term) && pane_editor(p) == nil && pane_browser(p) == nil && pane_app(p) == nil
	if clay.UI(pid(p, "pane"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
		if split do pane_strip_layout(cs, p)
		// the tab's bars, clipped across: a bar wider than a narrow pane (its buttons, an agent's
		// strip) hides its end rather than widening the pane (a clip container has no minimum width)
		if clay.UI(pid(p, "pane_bars"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom}, clip = {horizontal = true}}) {
			claude_bars(p) // a Claude tab's held messages (ui_claude.odin)
			app_bar_layout(p) // an app tab that exited or stopped drawing (app_tab.odin)
			dead_tab_bar_layout(p) // a pi tab whose process exited: how, Restart (dead_tab.odin)
			browser_bar_layout(p) // a browser tab: Back, Forward, Reload / Stop, the URL field, Annotate (browser_nav.odin)
			changes_bars_layout(p) // a Changes tab: branch, actions, commit (ui_changes.odin)
			editor_bars_layout(p) // find, replace, go to line, changed on disk (editor_view.odin)
		}
		// a Changes tab's file list sits left of its diff (ui_changes.odin); other tabs: the pane alone
		if clay.UI(pid(p, "pane_body"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			changes_list_layout(p)
			if clay.UI(pid(p, "centre_main"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
				changes_file_bar_layout(p)
				if clay.UI(pid(p, "terminal"))({
					layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = pu(SP_2), childAlignment = {x = .Center, y = .Center}},
					backgroundColor = cc(th.bg_app),
				}) {
					if empty && cs != nil && cs.missing {
						clay.Text("Session gone", txt(th.text_secondary))
						clay.Text("Its session file or folder no longer exists", txt(th.text_muted))
						action_button(.Empty_Close, false)
					} else if b := pane_browser(p); b != nil && b.message != "" {
						clay.TextDynamic(b.message, txt(th.text_secondary))
						if b.closed_by_page do browser_reload_button() // browser.odin
					} else if away := core.pane_shown(p); empty && away != nil && core.tab_held_away(away) != 0 {
						clay.Text("Still running in the session holder", txt(th.text_secondary))
						clay.Text(core.HELD_AWAY_TEXT, txt(th.text_muted))
					} else if empty && cs != nil && cs.machine != 0 {
						// another machine's session: its terminals are relayed; its other tabs show there only
						clay.Text("Shown on its machine only", txt(th.text_secondary))
						clay.TextDynamic(fmt.tprintf("This tab runs on %s. Its terminals work from here; this kind of tab does not yet.", core.machine_name(cs.machine)), txt(th.text_muted))
					} else if empty && cs == nil && core.fleet_any(fleet) {
						fleet_empty_layout() // what runs and what needs you, instead of the bare prompt (ui_fleet.odin)
					} else if empty {
						clay.Text("No session open", txt(th.text_secondary))
						clay.Text("Pick one on the left, or start a new chat", txt(th.text_muted))
						if clay.UI()({layout = {childGap = pu(SP_2)}}) {
							if button_enabled(.Empty_New_Chat) do action_button(.Empty_New_Chat, true)
							action_button(.Empty_Add_Project, false) // "Add project…", as the Projects header's "+"
						}
					}
				}
				changes_more_layout(p)
			}
		}
	}
}

// A pane's own strip (the session is split): its tabs, the zoomed pane's "⤢ 1 of 3" (a click
// restores), then "+" (the new-tab menu, for it). The focused pane's accent line along its bottom
// is drawn over the strips' border (ui_pane_motion.odin: it glides when the focus moves).
@(private = "file")
pane_strip_layout :: proc(cs: ^core.Open_Session, p: ^core.Pane) {
	th := theme()
	zoomed := core.session_zoomed(cs) == p.id
	zoom_label := zoomed ? pane_zoom_label(cs, p) : ""
	// clipped across like the bars: many tabs in a narrow pane never widen it
	if clay.UI(pid(p, "pane_strip"))({
		clip = {horizontal = true},
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(TAB_STRIP_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		new_w := px(TOOL_BUTTON + SP_1)
		zoom_w := zoomed ? text_w(zoom_label, FONT_UI_SMALL) + px(2 * SP_2 + SP_1) : 0
		strip_tabs(cs, p, pane_width() - px(2 * SP_2) - new_w - zoom_w)
		hovered := ui_hover == Hit(Hit_Pane_New(p.id))
		if clay.UI(pid(p, "pane_new"))({
			layout = {sizing = {clay.SizingFixed(px(TOOL_BUTTON)), clay.SizingFixed(px(TOOL_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = cc(mix(th.bg_app, th.text, hovered ? TINT_BUTTON_HOVER : 0)),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			icon(.Plus, th.text_secondary, ICON_SIZE_SM)
		}
		if zoomed {
			spacer() // the marker at the strip's right end; "+" stays after the tabs
			zid := pid(p, "pane_zoom")
			zbg, zem := overlay(zid, false, ui_hover == Hit(Hit_Pane_Zoom(p.id)))
			if clay.UI(zid)({
				layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TAB_H - SP_1))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
				backgroundColor = zbg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
			}) {
				clay.TextDynamic(zoom_label, txt(mix(th.text_secondary, th.text, zem), FONT_UI_SMALL))
			}
		}
	}
}

// The oldest pending confirmation's summary as the bar shows it: wrapped to
// the room left of its buttons, at most CONFIRM_LINES lines (the last cut
// with an ellipsis), so Cancel and Confirm always stay in the window.
@(private = "file")
confirm_text :: proc(pc: core.Pending_Confirmation) -> (text: string, lines: int) {
	left, _ := column_widths()
	bar_w := ui_win_w - left * app.dpi // the bar spans the centre and the right column
	used := px(2 * TERM_PAD + DOT + SP_1 + 4 * SP_2 + 4 * SP_3) + text_w("Cancel") + text_w("Confirm", WEIGHT_BOLD)
	return wrap_clip(pc.summary, max(bar_w - used, px(80)), CONFIRM_LINES)
}

// The confirmation bar's height (0 without one): one line's bar, taller
// when its summary wraps.
confirm_bar_h :: proc() -> f32 {
	if len(state.pending_confirmations) == 0 do return 0
	_, n := confirm_text(state.pending_confirmations[0])
	return max(px(BAR_H), f32(n) * text_line_height(.UI) + px(2 * SP_2))
}

// The oldest pending confirmation, as a bar above the tabs.
@(private = "file")
confirm_bar :: proc(pc: core.Pending_Confirmation) {
	th := theme()
	text, _ := confirm_text(pc)
	if clay.UI(clay.ID("confirm_bar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(confirm_bar_h())}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		dot(th.waiting)
		gap_w :: proc() {if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_1)), clay.SizingFit()}}}) {}}
		gap_w()
		// takes the room between the dot and the buttons (clipped, should a line still be too wide)
		if clay.UI(clay.ID("confirm_text"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}, clip = {horizontal = true}}) {
			cfg := txt(th.text)
			cfg.wrapMode = .Newlines
			clay.TextDynamic(text, cfg)
		}
		button(clay.ID("confirm_no"), "Cancel", false, ui_hover == Hit(Hit_Cancel(pc.token)))
		if pc.command != nil do button(clay.ID("confirm_yes"), "Confirm", true, ui_hover == Hit(Hit_Confirm(pc.token))) // nil: a newer core's command (confirm_pending)
	}
}

button :: proc(id: clay.ElementId, label: string, primary, hovered: bool, keys := "") {
	th := theme()
	bg: clay.Color
	col := th.text
	h := fade(id, 0, hovered ? 1 : 0, DUR_HOVER)
	if primary {
		bg = cc(mix(th.accent, th.text, h * TINT_PRIMARY_HOVER))
		col = th.text_on_accent
	} else {
		bg = cc(mix(th.bg_elevated, th.text, TINT_BUTTON + h * (TINT_BUTTON_HOVER - TINT_BUTTON)))
	}
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		clay.TextDynamic(label, txt(col, primary ? WEIGHT_BOLD : WEIGHT_REGULAR))
		if keys != "" { 	// its shortcut, quieter, after a gap
			if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_2)), clay.SizingFit()}}}) {}
			clay.TextDynamic(keys, txt(with_alpha(col, KEYS_ALPHA), FONT_UI_SMALL))
		}
	}
}

KEYS_ALPHA :: 0.7 // a button's shortcut beside its label

// The top bar: (the left column's buttons while it is hidden), the tabs of
// the open session (pi tab first, then shells; later browser, markdown, app
// tabs), "+" and its menu, the search pill, Settings, the right column's
// toggle, and the agent's button at the far right. Every tab has a close button: a pi tab's closes its
// session (with the usual confirmation).
@(private = "file")
tab_strip :: proc(cs: ^core.Open_Session, w: f32) {
	th := theme()
	{
		left, _ := column_widths()
		bar_compact = w - left * app.dpi < px(TOP_BAR_COMPACT_W)
		fleet_pill_decide(cs, w - left * app.dpi) // the pill whole, its most urgent part, or none: where the tabs keep their room (ui_fleet.odin)
		changes_button_decide(cs, w - left * app.dpi) // the "±" only where the tabs keep their room
	}
	if clay.UI(clay.ID("tabs"))({
		// left edge of the first tab lines up with the terminal's cell grid
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(TAB_STRIP_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		if !state.layout.left_open do lights_buttons(px(LIGHTS_X + LIGHTS_W + SP_2 - TERM_PAD), px(SP_2))
		if cs != nil {
			// another machine's session: one quiet marker of where it runs, before its tabs
			marker_w := remote_marker_w(cs)
			if cs.machine != 0 {
				label := clip(fmt.tprintf("on %s", core.machine_name(cs.machine)), px(140), FONT_UI_SMALL)
				if clay.UI(clay.ID("remote_marker"))({
					layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TAB_H - SP_1))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
					border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
				}) {
					clay.TextDynamic(label, txt(th.text_muted, FONT_UI_SMALL))
				}
			}
			if len(cs.panes) <= 1 {
				left, _ := column_widths()
				strip_tabs(cs, nil, w - left * app.dpi - top_bar_fixed_w() - marker_w)
			}
			tool_button(.New_Tab)
			tool_button(.New_Menu, menu.open && menu.target == Menu_Target(Menu_New{}))
			if changes_btn_shown do changes_tab_button(cs) // "±": the checkout's changed files (ui_changes.odin; the palette has it too)
		}
		left, _ := column_widths()
		wide := search_wide(cs, w - left * app.dpi)
		spacer()
		search_pill(wide)
		spacer()
		fleet_pill() // what needs you and what works, on every machine (ui_fleet.odin)
		bell_button() // the notification centre (ui_bell.odin)
		tool_button(.Settings, settings_open())
		tool_button(.Toggle_Right)
		agent_button() // far right
	}
}

// The width of the "on <machine>" marker before another machine's session's tabs (0: this Mac's).
remote_marker_w :: proc(cs: ^core.Open_Session) -> f32 {
	if cs == nil || cs.machine == 0 do return 0
	return text_w(clip(fmt.tprintf("on %s", core.machine_name(cs.machine)), px(140), FONT_UI_SMALL), FONT_UI_SMALL) + px(2 * SP_2 + SP_1)
}

// The tabs of a strip: every tab of cs (p nil: the top bar of a session with one pane) or pane p's
// (its own strip, when split), in room px. Ids are by index in cs.tabs, unique across strips.
@(private = "file")
strip_tabs :: proc(cs: ^core.Open_Session, p: ^core.Pane, room: f32) {
	th := theme()
	max_tab, squeezed := tab_max_w(cs, room, p)
	for tab, i in cs.tabs {
		if p != nil && tab.pane != p.id do continue
		id := clay.ID("tab", u32(i))
		active := p != nil ? tab.id == p.active : tab.id == cs.active_tab
		// an unfocused pane's shown tab: a quieter tint than the focused one's
		quiet := active && p != nil && p.id != cs.focused_pane
		close_id := clay.ID("tabclose", u32(i))
		close_hover := ui_hover == Hit(Hit_Close_Tab(tab.id))
		hovered := ui_hover == Hit(Hit_Tab(tab.id)) || close_hover
		bg, em := overlay(id, active && !quiet, hovered || quiet)
		ic, label, extra := tab_label(cs, tab)
		view := tab_strip_view(tab, active)
		show_mark := tab_shows_mark(tab)
		// it turned waiting, finished or error just now: a brief wash, its mark pops
		lit := show_mark ? status_flash(id, tab.id ~ SALT_FLASH_TAB, view, tab.machine) : 0
		bg = flash_wash(bg, view.dot, lit)
		dirty := editor_dirty(editor_of(tab.id))
		font: u16 = WEIGHT_REGULAR
		if et, is := tab.kind.(core.Editor_Tab); is && et.preview do font |= FONT_ITALIC // a preview: the next one replaces it
		// the title is cut to the widest a tab may be; a short tab is padded to TAB_MIN_W
		// squeezed: only the active tab keeps its close button (the others: ⌘W once active)
		close := !squeezed || active
		fixed := tab_fixed_w(ic, show_mark, dirty, extra, close)
		room := max_tab + (close ? tab_close_w() : 0) - fixed
		title := clip(label, room, font)
		if clay.UI(id)({
			layout = {
				sizing = {clay.SizingFit({min = px(TAB_MIN_W)}), clay.SizingFixed(px(TAB_H))},
				padding = {pu(SP_3), pu(SP_1), 0, 0},
				childGap = pu(SP_2),
				childAlignment = {y = .Center},
			},
			backgroundColor = bg,
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			if show_mark do status_mark_el(view, lit)
			if dirty do dot(th.text_secondary) // unsaved changes
			col := mix(th.text_secondary, th.text, em)
			if tab.status != .Running do col = th.text_muted
			if ic != .None do icon(ic, col, KIND_ICON)
			clay.TextDynamic(title, txt(col, font))
			if extra != "" do clay.TextDynamic(extra, txt(th.text_muted))
			spacer() // the close button sits at the right edge of a padded tab
			if close {
				cbg, _ := overlay(close_id, false, close_hover)
				show := max(em, f32(active ? 1 : 0))
				if clay.UI(close_id)({
					layout = {sizing = {clay.SizingFixed(px(TAB_H - SP_2)), clay.SizingFixed(px(TAB_H - SP_2))}, childAlignment = {x = .Center, y = .Center}},
					backgroundColor = cbg,
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				}) {
					icon(.Close, with_alpha(close_hover ? th.text : th.text_muted, show), ICON_SIZE_SM)
				}
			}
		}
	}
}

// What a tab shows: the pi tab says where its session runs (a folder and the
// project, or a bubble and "Chat"); other tabs their title. `extra`: a muted
// note (exited, not started).
tab_label :: proc(cs: ^core.Open_Session, tab: core.Tab) -> (ic: core.Icon, label, extra: string) {
	label = tab.title
	if _, is_pi := tab.kind.(core.Pi_Tab); is_pi && cs != nil && !cs.home {
		_, label = core.session_place(cs)
		ic = core.harness_icon(.Pi) // which agent (sidebar.odin: Harness); the place is in the label
	}
	ct, is_claude := tab.kind.(core.Claude_Tab)
	tag := ""
	if is_claude {
		ic = core.harness_icon(.Claude)
		// several accounts: which one (claude_accounts.odin)
		tag = core.claude_account_tag(ct.account)
		if tag != "" do label = fmt.tprintf("%s · %s", tab.title, tag)
	}
	// a Claude-only session's main tab: Claude and where it runs
	if cs != nil && cs.agent == .Claude && len(cs.tabs) > 0 && cs.tabs[0].id == tab.id {
		_, place := core.session_place(cs)
		label = tag != "" ? fmt.tprintf("Claude · %s · %s", tag, place) : fmt.tprintf("Claude · %s", place)
	}
	if is_claude {
		// what the process started with (ct.readonly); a tab not started yet: what it will start as
		if tab.status == .Not_Started {
			if core.claude_tab_readonly(cs, &ct) do extra = "read-only"
		} else if ct.readonly do extra = "read-only"
		else if core.claude_tab_readonly(cs, &ct) do extra = "read-only after restart"
	}
	if tab.status == .Exited do extra = "exited"
	if is_claude && ct.guard_stopped do extra = "read-only guard not confirmed: stopped"
	if tab.status == .Not_Started do extra = cs != nil && cs.missing ? "gone" : "not started"
	if tc := tab; core.tab_held_away(&tc) != 0 do extra = "in the session holder" // not reachable: never started here
	// a kind this window does not know: a newer core's (the replica decodes it as nil, state_read.odin)
	if tab.kind == nil do extra = "needs a newer Deckhand"
	return
}

// The widest a tab may be now (its close button aside): TAB_MAX_W, less when
// the session's tabs would not fit the top bar beside its buttons (never
// under TAB_MIN_W). Squeezed: they do not fit at their natural widths; only
// the active tab keeps its close button then.
tab_max_w :: proc(cs: ^core.Open_Session, room: f32, p: ^core.Pane = nil) -> (max_w: f32, squeezed: bool) {
	if cs == nil || len(cs.tabs) == 0 do return px(TAB_MAX_W), false
	n: f32 = 0
	for tab in cs.tabs do if p == nil || tab.pane == p.id do n += 1
	if n == 0 do return px(TAB_MAX_W), false
	avail := room - n * px(SP_1)
	natural: f32 = 0
	for tab in cs.tabs {
		if p != nil && tab.pane != p.id do continue
		ic, label, extra := tab_label(cs, tab)
		// as drawn (strip_tabs): its title up to TAB_MAX_W besides its parts, and its close button
		natural += clamp(text_w(label) + tab_fixed_w(ic, tab_shows_mark(tab), false, extra), px(TAB_MIN_W), px(TAB_MAX_W) + tab_close_w())
	}
	if natural <= avail do return px(TAB_MAX_W), false
	return clamp((avail - tab_close_w()) / n, px(TAB_MIN_W), px(TAB_MAX_W)), true
}

// A narrow top bar (under TOP_BAR_COMPACT_W): the agent's button shows its
// initial without its name (set by tab_strip for the layout).
bar_compact: bool

// The top bar's width besides the tabs at their narrowest: padding, the
// buttons (the search pill as an icon), the agent's button, the gaps.
top_bar_fixed_w :: proc() -> f32 {
	w := px(2 * TERM_PAD) + 5 * px(TOOL_BUTTON + SP_1) + px(NEW_MENU_W + SP_1) + bell_extra_w()
	if pw := fleet_pill_w(); pw > 0 do w += pw + px(SP_1) // the fleet pill, while it shows
	w += px(SP_2 + SP_3 + AVATAR - 6 + SP_2 + MARK + SP_2) // the agent's button with a status mark
	if !bar_compact do w += text_w(core.agent_name()) + px(SP_2) // and its name
	if changes_btn_shown do w += changes_button_w(core.cur()) // the "±" button (ui_changes.odin), when it fits
	if !state.layout.left_open do w += px(LIGHTS_X + LIGHTS_W + SP_2 - TERM_PAD) + 2 * px(TOOL_BUTTON + SP_1) + px(SP_2)
	return w
}

// A tab's close button and the gap before it.
tab_close_w :: proc() -> f32 {return px(TAB_H - SP_2 + SP_2)}

// A tab's width besides its title: padding, icon, status mark, unsaved dot, note, close button, gaps.
tab_fixed_w :: proc(ic: core.Icon, show_mark, dirty: bool, extra: string, close := true) -> f32 {
	w := px(SP_3 + SP_1) + px(SP_2) // padding, the gap before the spacer
	if close do w += tab_close_w()
	if ic != .None do w += px(KIND_ICON + SP_2)
	if show_mark do w += px(MARK + SP_2)
	if dirty do w += px(DOT + SP_2)
	if extra != "" do w += text_w(extra) + px(SP_2)
	return w
}

// The top bar's agent button (also ⌘J): its initial, name and status dot,
// selected while the drawer shows. Shut, it carries the unread count and a
// gentle waiting tint while the agent needs the user (a dialog in its pi,
// from its bridge status).
@(private = "file")
agent_button :: proc() {
	th := theme()
	id := clay.ID("homebutton")
	ch := &state.agent
	if !core.atlas_offered() do return // Atlas runs on pi: without it, no button (harness.odin; ⌘J says why)
	needs := !state.home_open && core.agent_needs_user()
	bg, em := overlay(id, state.home_open, ui_hover == Hit(Hit_Home{}))
	if needs do bg = cc(mix(to_rgba(bg), with_alpha(th.waiting, 1), 0.14))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TAB_H))}, padding = {pu(SP_2), pu(SP_3), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(needs ? with_alpha(th.waiting, 0.6) : {}), width = needs ? {pu(core.BORDER_W), pu(core.BORDER_W), pu(core.BORDER_W), pu(core.BORDER_W), 0} : {}},
	}) {
		avatar(AVATAR - 6)
		if !bar_compact do clay.TextDynamic(core.agent_name(), txt(needs ? th.waiting : mix(th.text_secondary, th.text, em)))
		// its status mark's box in every state (top_bar_fixed_w counts it): nothing moves when it changes
		v := core.Tab_Status_View{progress = -1}
		if ht := core.home_tab(); ht != nil && !needs do v = core.tab_status_view(ht^)
		if v.dot != .None do status_mark_el(v)
		else if clay.UI()({layout = {sizing = {clay.SizingFixed(px(MARK)), clay.SizingFixed(px(MARK))}}}) {}
		if !state.home_open && ch.unread > 0 {
			n := ch.unread > 99 ? "99+" : fmt.tprint(ch.unread)
			if clay.UI(clay.ID("agent_unread"))({
				layout = {sizing = {clay.SizingFit({min = px(BADGE_H)}), clay.SizingFixed(px(BADGE_H))}, padding = {pu(SP_1 + 1), pu(SP_1 + 1), 0, 0}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = cc(th.accent),
				cornerRadius = clay.CornerRadiusAll(px(BADGE_H / 2)),
			}) {
				clay.TextDynamic(n, {textColor = cc(th.text_on_accent), fontId = FONT_UI_SMALL | FONT_BOLD, wrapMode = .None})
			}
		}
	}
}

// The open session of a listed pi session in a project (0 = not open).
open_session_of :: proc(project_id: u64, pi_session_id: string) -> u64 {
	for s in state.open_sessions do if !s.home && s.project_id == project_id && s.pi_session_id == pi_session_id do return s.id
	return 0
}

// The tab whose panels the right column showed last (0 = none).
@(private = "file")
panels_shown: u64

// The last layout clamped the panels' offset: one more frame (ui_wants_frame clears it).
@(private = "file")
panels_clamped: bool

// Clay clamps a scroll offset only on wheel input: when the panels get shorter while scrolled
// (rows removed), the offset is clamped to the new end after the layout. Whether it moved.
@(private = "file")
panels_scroll_clamp :: proc() -> bool {
	d := clay.GetScrollContainerData(clay.ID("panels"))
	if !d.found do return false
	end := -max(d.contentDimensions.height - d.scrollContainerDimensions.height, 0)
	if d.scrollPosition.y >= end do return false
	d.scrollPosition.y = end
	return true
}

// Right column: the current session's pi tab panels, published by its
// bridge (subagents, shells, todos), as foldable sections.
@(private = "file")
right_column :: proc(cs: ^core.Open_Session) {
	th := theme()
	_, right := column_widths()
	col_w := right * app.dpi
	edge := th.border // the divider: highlighted while hovered or dragged
	if divider.active && divider.which == 1 do edge = th.accent
	else if d, ok := ui_hover.(Hit_Divider); ok && int(d) == 1 do edge = mix(th.border, th.accent, 0.6)
	inner_w := col_w - px(2 * SP_2) // inside the column's padding
	pt := core.right_panels_tab(cs) // the active Claude tab's, else pi's (claude_panels.odin)
	from_claude := false
	if pt != nil do _, from_claude = pt.kind.(core.Claude_Tab)
	if clay.UI(clay.ID("right"))({
		layout = {
			sizing = {clay.SizingFixed(col_w), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {pu(SP_2), pu(SP_2), pu(SP_3), pu(SP_3)},
		},
		backgroundColor = cc(th.bg_panel),
		border = {color = cc(edge), width = {left = pu(core.BORDER_W)}},
	}) {
		// another tab's panels start at the top: Clay keeps the offset by element id, so the last
		// tab's would carry over (past the end of a shorter list)
		shown := pt != nil ? pt.id : 0
		if shown != panels_shown {
			panels_shown = shown
			if d := clay.GetScrollContainerData(clay.ID("panels")); d.found do d.scrollPosition^ = {}
		}
		if clay.UI(clay.ID("panels"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			if pt == nil || len(pt.panels) == 0 {
				if from_claude do empty_state("Nothing running", "Todos and subagents from Claude", inner_w)
				else do empty_state("Nothing running", RIGHT_EMPTY_HINT, inner_w)
			} else {
				for &p, i in pt.panels {
					if i > 0 do gap(SP_2)
					panel_section(&p, i, inner_w)
				}
			}
		}
	}
}

// A panel's header text and its body rows: a leading head row (pi-kit's
// "Todos 2/5") is the header text.
panel_parts :: proc(p: core.Panel) -> (title: string, rows: []core.Panel_Row) {
	rows = p.rows[:]
	title = p.title != "" ? p.title : p.id
	if len(rows) > 0 && rows[0].head {
		title = rows[0].text
		rows = rows[1:]
	}
	return
}

// Whether a panel has rows under its header (blank spacer rows aside): a
// panel without is just its header, not a fold.
panel_has_body :: proc(p: core.Panel) -> bool {
	_, rows := panel_parts(p)
	for r in rows do if r.text != "" do return true
	return false
}

// One panel: a header that folds it, then its rows. With no rows under the
// header (pi-kit's "Todos 3/3" with the done items hidden): the header
// alone, no fold arrow, not a toggle.
@(private = "file")
panel_section :: proc(p: ^core.Panel, i: int, width: f32) {
	th := theme()
	title, rows := panel_parts(p^)
	body := panel_has_body(p^)
	folded := body && core.panel_collapsed(p.id)
	id := clay.ID("panelhead", u32(i))
	bg, em := overlay(id, false, body && ui_hover == Hit(Hit_Panel_Head(p.id)))
	chevron := !body ? "" : folded ? "▸" : "▾"
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		col := mix(th.text_muted, th.text_secondary, em)
		room := width - px(3 * SP_2) - text_w(chevron)
		if chevron != "" do clay.TextDynamic(chevron, txt(col))
		clay.TextDynamic(clip(title, room, WEIGHT_HEADER), txt(col, WEIGHT_HEADER))
	}
	if folded || !body do return
	room := width - px(2 * SP_2)
	for r in rows {
		if r.text == "" {
			gap(SP_1)
			continue
		}
		weight: u16 = r.head ? WEIGHT_BOLD : WEIGHT_REGULAR
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(PANEL_ROW_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		}) {
			clay.TextDynamic(clip(r.text, room, weight), txt(r.head ? th.text_secondary : tone_color(r.tone), weight))
		}
	}
}

// Panel tones onto the look's text and status colours.
@(private = "file")
tone_color :: proc(t: core.Panel_Tone) -> core.Rgba {
	th := theme()
	switch t {
	case .Normal:  return th.text
	case .Accent:  return th.running // pi-kit's accent marks running work
	case .Muted:   return th.text_secondary
	case .Dim:     return th.text_muted
	case .Warning: return th.waiting
	case .Success: return th.done
	case .Error:   return th.error
	}
	return th.text
}

// What the click at the current pointer position hit, from the last layout.
// List positions stay in here: hits carry ids.
Hit :: union {
	Hit_Project,
	Hit_Session,
	Hit_New,
	Hit_Tab,
	Hit_Close_Tab,
	Hit_Pane_New,
	Hit_Pane_Zoom,
	Hit_Pane_Divider,
	Hit_Confirm,
	Hit_Cancel,
	Hit_Panel_Head,
	Hit_Palette_Row,
	Hit_Home,
	Hit_Close_Session,
	// left column (ui_sidebar.odin)
	Hit_Chat,
	Hit_Open_Row,
	Hit_Pin_Project,
	Hit_Pin_Session,
	Hit_New_In,
	Hit_Add_Project,
	Hit_Sort,
	Hit_Fold,
	Hit_Filter,
	Hit_Filter_Clear,
	Hit_Quick,
	Hit_Menu_Row,
	Hit_Divider,
	Hit_Waiting_Filtered,
	Hit_Agent,
	Hit_More_Project,
	Hit_More_Session,
	Hit_More_Open,
	Hit_Show_More,
	Hit_Group,
	Hit_Kids,
	Hit_Info_Session,
	Hit_New_Job_In,
	Hit_Machine, // another machine's button (ui_sidebar.odin)
	Hit_Machine_Head, // its header: the tooltip says why, a click folds it, right click its menu
	Hit_Machine_More, // its header's "…": its menu
	Hit_Machine_Add, // + Add a machine…
	// the toolbar, settings popover, shortcuts sheet (ui_toolbar.odin)
	Hit_Button,
	Hit_Pop,
	Hit_Sheet_Close,
	Hit_Setup, // the first-run sheet (ui_setup.odin)
	Hit_Job_Sheet, // the job sheet (ui_job_sheet.odin)
	Hit_Editor_Tool, // the editor's toolbar (editor_view.odin)
	Hit_Files, // the left column's tab switch and the Files tab (ui_files.odin)
	Hit_Reload, // the hot-reload bars' buttons (ui_reload.odin)
	Hit_Claude_Reload, // Claude Code's (ui_claude_reload.odin)
	Hit_Dead_Tab, // the bar over a pi tab whose process exited (dead_tab.odin)
	Hit_Update, // the update bar's buttons (ui_update.odin)
	Hit_Comments, // the pending comments' strip, list and close prompt (ui_comments.odin)
	Hit_Claude, // a Claude tab's held messages bar (ui_claude.odin)
	Hit_Bell, // the bell's popover (ui_bell.odin)
	Hit_Jobs, // the Jobs tab (ui_jobs.odin)
	Hit_Changes, // the Changes tab and the top bar's "±" (ui_changes.odin)
	Hit_Fleet_Row, // a row of the empty centre's summary (ui_fleet.odin)
	Hit_Attention, // the Sessions column's By project | Attention switch, IDLE's header, the footer (ui_sidebar.odin)
	Hit_Peek, // a peek's header buttons (ui_peek.odin)
	Hit_Peek_Row, // a row's eye button: peek at its session (ui_peek.odin)
}
Hit_Attention :: distinct int // a core.Sidebar_View (the switch), ATTN_HIT_IDLE, ATTN_HIT_FOOTER
Hit_Editor_Tool :: distinct int // button index
Hit_Project :: distinct u64 // project id
Hit_Session :: distinct string // pi session id
Hit_New :: struct {}
Hit_Tab :: distinct u64 // tab id
Hit_Close_Tab :: distinct u64 // tab id (a pi tab's closes its session)
Hit_Pane_New :: distinct u64 // a pane strip's "+": the new-tab menu, for that pane (pane id)
Hit_Pane_Zoom :: distinct u64 // the zoomed pane's "⤢ 1 of 3": restores the layout (pane id)
Hit_Pane_Divider :: distinct u64 // a divider between panes (its split's id)
Hit_Confirm :: distinct string // confirmation token
Hit_Cancel :: distinct string
Hit_Panel_Head :: distinct string // panel id: folds its section
Hit_Palette_Row :: distinct int // result index
Hit_Home :: struct {}
Hit_Close_Session :: distinct u64 // open session id
Hit_Chat :: distinct string // pi session id of a chat
Hit_Open_Row :: distinct u64 // open session id (the Open group)
Hit_Pin_Project :: distinct u64 // project id
Hit_Pin_Session :: distinct string // pi session id
Hit_New_In :: distinct u64 // project id (Chats too): a new chat there
Hit_Add_Project :: struct {}
Hit_Sort :: distinct core.Sort_Section
Hit_Fold :: distinct core.Sidebar_Fold
Hit_Filter :: struct {}
Hit_Filter_Clear :: struct {}
Hit_Quick :: distinct int // 0 running, 1 waiting, 2 pinned
Hit_Menu_Row :: distinct int
Hit_Divider :: distinct int // 0 left column's edge, 1 right column's, 2 the agent drawer's left edge
Hit_Waiting_Filtered :: struct {} // "N waiting (filtered)": clears the filter
Hit_More_Project :: distinct u64 // a row's "…": its context menu
Hit_More_Session :: distinct string // pi session id (a project's or a chat)
Hit_More_Open :: distinct u64 // open session id (the Open group)
Hit_Show_More :: distinct int // 0: the selected project's sessions, 1: Chats
Hit_Group :: distinct string // a group row of the Projects tree: its folder (opens or collapses it)
Hit_Kids :: distinct u64 // a parent row's "N folders": opens or collapses its nested rows
Hit_Info_Session :: distinct string // a session row's ⓘ: its info menu (pi session id)
Hit_New_Job_In :: distinct u64 // "New job…" under the selected project (project id)
Hit_Machine :: distinct u64 // a machine row's button: Log in…, Connect, Take back… (machine number)
Hit_Machine_Head :: distinct u64 // a machine's header (machine number)
Hit_Machine_More :: distinct u64 // another machine's header's "…" (machine number)
Hit_Machine_Add :: struct {}
Hit_Button :: distinct Button
Hit_Pop :: distinct Pop_Item
Hit_Sheet_Close :: struct {}

ui_hit :: proc() -> Hit {
	if peek_is_open() do return peek_hit() // a peek's scrim covers everything: nothing under it is hit (ui_peek.odin)
	if palette_is_open() {
		// the palette covers everything: nothing under it is hit
		for i in palette.first ..< palette.first + PALETTE_ROWS do if clay.PointerOver(clay.ID("palrow", u32(i))) do return Hit_Palette_Row(i)
		return nil
	}
	if shortcuts_open() do return sheet_hit() // so does the shortcuts sheet
	if setup_open() do return setup_hit() // and the first-run sheet (ui_setup.odin)
	if job_sheet_open() do return job_sheet_hit() // and the job sheet (ui_job_sheet.odin)
	if settings_open() do return settings_hit() // and the settings popover
	if bell_open() do return bell_hit() // and the bell's
	if menu.open do return menu_hit() // the menu covers everything too
	if wt_menu.open do return wt_menu_hit() // and the checkout switcher's (ui_worktrees.odin)
	if h := toolbar_hit(); h != nil do return h
	// the per-tab bars below are tested with the ids of the pane under the pointer (cid)
	old_ids := ids_pane_begin(hit_pane())
	defer ids_pane_end(old_ids)
	if h := pane_hit(); h != nil do return h // a pane strip's "+" (ui_panes.odin)
	if clay.PointerOver(clay.ID("homebutton")) do return Hit_Home{}
	if state.home_open && clay.PointerOver(clay.ID("drawer")) do return drawer_hit() // nothing under the drawer is hit
	if h := empty_hit(); h != nil do return h
	if clay.PointerOver(clay.ID("new")) do return Hit_New{}
	if len(state.pending_confirmations) > 0 {
		token := state.pending_confirmations[0].token
		if clay.PointerOver(clay.ID("confirm_yes")) do return Hit_Confirm(token)
		if clay.PointerOver(clay.ID("confirm_no")) do return Hit_Cancel(token)
	}
	if h := comments_hit(); h != nil do return h
	if h := claude_hit(); h != nil do return h
	if h := update_hit(); h != nil do return h
	if h := reload_hit(); h != nil do return h
	if h := claude_reload_hit(); h != nil do return h
	if h := dead_tab_hit(); h != nil do return h
	if h := machine_bar_hit(); h != nil do return h
	if h := changes_hit(); h != nil do return h
	if h := editor_tool_hit(); h != nil do return h
	if h := files_hit(); h != nil do return h
	if h := jobs_hit(); h != nil do return h
	if h := sidebar_hit(); h != nil do return h
	if pt := core.right_panels_tab(core.cur()); pt != nil && state.layout.right_open {
		for p, i in pt.panels do if panel_has_body(p) && clay.PointerOver(clay.ID("panelhead", u32(i))) do return Hit_Panel_Head(p.id)
	}
	if cs := core.cur(); cs != nil {
		for t, i in cs.tabs do if clay.PointerOver(clay.ID("tabclose", u32(i))) do return Hit_Close_Tab(t.id)
		for t, i in cs.tabs do if clay.PointerOver(clay.ID("tab", u32(i))) do return Hit_Tab(t.id)
	}
	return nil
}

// Caret, selection and composition underline of the focused field (after
// ui_draw). Also remembers the caret for the input method's candidate window.
ui_draw_field_cursor :: proc(cmds: clay.ClayArray(clay.RenderCommand)) {
	f, text_id, _ := focused_field()
	if f == nil do return
	d := clay.GetElementData(text_id)
	if !d.found do return
	if job_sheet_open() {
		// the sheet draws its own caret and composition (multi-line fields);
		// the input method's candidate window goes under that caret
		if r, ok := job_sheet_caret_rect(cmds); ok {
			ime.caret_rect = r
			return
		}
		b := d.boundingBox
		ime.caret_rect = {b.x, b.y + b.height - text_line_height(.UI), px(CARET_W), text_line_height(.UI)}
		return
	}
	th := theme()
	b := d.boundingBox
	lh := text_line_height(.UI)
	shown, mlo, mhi := tf_display(f, ime.marked)
	if ime.marked != "" {
		x0, x1 := text_width(shown[:mlo], .UI), text_width(shown[:mhi], .UI)
		draw_rect(b.x + x0, b.y + lh - px(core.BORDER_W), x1 - x0, px(core.BORDER_W), th.text)
		xc := text_width(shown[:mlo + clamp(ime.caret, 0, mhi - mlo)], .UI)
		draw_rect(b.x + xc, b.y, max(1, px(CARET_W)), lh, th.accent)
		ime.caret_rect = {b.x + xc, b.y, px(CARET_W), lh}
		return
	}
	lo, hi := tf_selection(f)
	s := tf_text(f)
	xc, xlo, xhi := text_width(s[:f.cursor], .UI), text_width(s[:lo], .UI), text_width(s[:hi], .UI)
	if hi > lo do draw_rect(b.x + xlo, b.y, xhi - xlo, lh, th.selection)
	draw_rect(b.x + xc, b.y, max(1, px(CARET_W)), lh, th.accent)
	ime.caret_rect = {b.x + xc, b.y, px(CARET_W), lh}
}

// Byte offset in the focused field under x (framebuffer px).
field_offset_at :: proc(f: ^Text_Field, text_id: clay.ElementId, x: f32) -> int {
	d := clay.GetElementData(text_id)
	if !d.found do return len(f.buf)
	return text_offset_at(tf_text(f), x - d.boundingBox.x, .UI)
}

// The focused pane's content rect (its "terminal" element) at the last layout.
ui_terminal_rect :: proc() -> (x, y, w, h: f32, ok: bool) {
	d := clay.GetElementData(pid(core.focused_pane(), "terminal"))
	if !d.found do return
	b := d.boundingBox
	return b.x, b.y, b.width, b.height, true
}

// Every pane of cs from the last layout: p.rect its content container (pid(p, "pane_body")),
// p.frame the whole pane; app.centre the panes' area. A pane not laid out: {}.
ui_pane_rects :: proc(cs: ^core.Open_Session) {
	box :: proc(id: clay.ElementId) -> [4]f32 {
		d := clay.GetElementData(id)
		if !d.found do return {}
		b := d.boundingBox
		return {b.x, b.y, b.width, b.height}
	}
	app.centre = box(clay.ID("panes"))
	core.pane_centre_set(app.centre.z, app.centre.w, app.dpi) // the room and ratio checks' (panes_commands.odin)
	if cs == nil do return
	for &p in cs.panes {
		p.rect = box(pid(&p, "pane_body"))
		p.frame = box(pid(&p, "pane"))
	}
}

// Where pane p's tab draws: its "terminal" element (a Changes tab's diff, right of its list),
// else its content rect.
pane_draw_rect :: proc(p: ^core.Pane) -> [4]f32 {
	d := clay.GetElementData(pid(p, "terminal"))
	if !d.found do return pane_rect(p)
	b := d.boundingBox
	return {b.x, b.y, b.width, b.height}
}

// Where draw_round_rect and draw_border put their quads: draw_rect, or a test's recorder.
Rect_Sink :: #type proc(x, y, w, h: f32, col: core.Rgba)

// A corner's radius in whole px: at most half the box (a pill), 0 when under 1 px.
corner_px :: proc(radius, w, h: f32) -> f32 {
	r := math.floor(min(radius, w / 2, h / 2))
	return r < 1 ? 0 : r
}

// How far row i of a corner of radius r (row 0 the box's outer edge) starts in from the side:
// the circle's edge at the row's centre.
corner_inset :: proc(r: f32, i: int) -> f32 {
	if f32(i) >= r do return 0
	dy := r - f32(i) - 0.5
	return r - math.sqrt(r * r - dy * dy)
}

// One pixel row of the cover between a and b px in from a side (a < b, fractional), each end's
// partly covered pixel at its share of col's alpha. From the left side (x up) or the right (x + w
// down), so a right corner is the left one mirrored to the pixel. A pixel under 1% is left out.
row_span :: proc(x, w, row_y, a, b: f32, right: bool, col: core.Rgba, rect: Rect_Sink) {
	put :: proc(x, w, row_y, from, n: f32, right: bool, col: core.Rgba, rect: Rect_Sink) {
		rect(right ? x + w - from - n : x + from, row_y, n, 1, col)
	}
	if b - a <= 0.01 do return
	full, last := math.ceil(a), math.floor(b)
	if full > last { 	// both ends in one pixel
		put(x, w, row_y, last, 1, right, with_alpha(col, b - a), rect)
		return
	}
	if full - a > 0.01 do put(x, w, row_y, full - 1, 1, right, with_alpha(col, full - a), rect)
	if last > full do put(x, w, row_y, full, last - full, right, col, rect)
	if b - last > 0.01 do put(x, w, row_y, last, 1, right, with_alpha(col, b - last), rect)
}

// A filled rectangle with rounded corners (each its own radius), drawn as one quad per pixel row
// in the corners, with an anti-aliased edge pixel.
draw_round_rect :: proc(x, y, w, h: f32, radius: clay.CornerRadius, col: core.Rgba, rect: Rect_Sink = draw_rect) {
	tl, tr := corner_px(radius.topLeft, w, h), corner_px(radius.topRight, w, h)
	bl, br := corner_px(radius.bottomLeft, w, h), corner_px(radius.bottomRight, w, h)
	top, bottom := max(tl, tr), max(bl, br)
	if top + bottom == 0 {
		rect(x, y, w, h, col)
		return
	}
	if h - top - bottom > 0 do rect(x, y + top, w, h - top - bottom, col)
	// rows from the top (y down) and from the bottom (y + h - 1 up)
	ends := [2]struct {
		l, r, n: f32,
		up:      bool,
	}{{tl, tr, top, false}, {bl, br, bottom, true}}
	for e in ends {
		for i in 0 ..< int(e.n) {
			row_y := e.up ? y + h - 1 - f32(i) : y + f32(i)
			l, r := corner_inset(e.l, i), corner_inset(e.r, i)
			lf, rf := math.ceil(l), math.ceil(r)
			rect(x + lf, row_y, w - lf - rf, 1, col)
			if lf - l > 0.01 do rect(x + lf - 1, row_y, 1, 1, with_alpha(col, lf - l))
			if rf - r > 0.01 do rect(x + w - rf, row_y, 1, 1, with_alpha(col, rf - r))
		}
	}
}

// A border inside the box: each side its own width, laid over the fill (draw_round_rect) and
// following its corners. A corner is rounded where it has a radius and both of its sides have a
// border narrower than the radius: rows of a ring, the fill's own outer edge (same rows, same
// edge pixels) and inside it the inner curve (radius minus each side's width; an ellipse when
// the two widths differ). Elsewhere sides stay straight: a lone side runs the box's full length,
// and at a square corner the top and bottom run through while the left and right stop at them,
// so no pixel is drawn twice (a see-through colour would darken there).
draw_border :: proc(x, y, w, h: f32, bd: clay.BorderRenderData, rect: Rect_Sink = draw_rect) {
	col := to_rgba(bd.color)
	if col.a == 0 do return
	t, b := f32(bd.width.top), f32(bd.width.bottom)
	l, r := f32(bd.width.left), f32(bd.width.right)
	round :: proc(radius, w, h, side_a, side_b: f32) -> f32 {
		k := corner_px(radius, w, h)
		return side_a > 0 && side_b > 0 && side_a < k && side_b < k ? k : 0
	}
	tl, tr := round(bd.cornerRadius.topLeft, w, h, t, l), round(bd.cornerRadius.topRight, w, h, t, r)
	bl, br := round(bd.cornerRadius.bottomLeft, w, h, b, l), round(bd.cornerRadius.bottomRight, w, h, b, r)

	if t > 0 && w - tl - tr > 0 do rect(x + tl, y, w - tl - tr, t, col)
	if b > 0 && w - bl - br > 0 do rect(x + bl, y + h - b, w - bl - br, b, col)
	// the left and right start below the top's straight run (or its rounded corner)
	if l > 0 {
		y0, y1 := tl > 0 ? tl : t, bl > 0 ? bl : b
		if h - y0 - y1 > 0 do rect(x, y + y0, l, h - y0 - y1, col)
	}
	if r > 0 {
		y0, y1 := tr > 0 ? tr : t, br > 0 ? br : b
		if h - y0 - y1 > 0 do rect(x + w - r, y + y0, r, h - y0 - y1, col)
	}

	// The rounded corners. k: the radius; across: the width of the top or bottom; side: the left
	// or right's. Row i lies within the top/bottom band (to the corner's end at k) or crosses the
	// inner curve, an ellipse with radii k - side by k - across centred k in from both sides.
	corners := [4]struct {
		k, across, side: f32,
		right, up:       bool,
	}{{tl, t, l, false, false}, {tr, t, r, true, false}, {bl, b, l, false, true}, {br, b, r, true, true}}
	for c in corners {
		if c.k == 0 do continue
		rx, ry := c.k - c.side, c.k - c.across
		for i in 0 ..< int(c.k) {
			row_y := c.up ? y + h - 1 - f32(i) : y + f32(i)
			inner := c.k
			if f32(i) >= c.across {
				dy := (c.k - f32(i) - 0.5) / ry
				inner = c.side + rx * (1 - math.sqrt(max(1 - dy * dy, 0)))
			}
			row_span(x, w, row_y, corner_inset(c.k, i), inner, c.right, col, rect)
		}
	}
}

// Index of the first command of an overlay element (the Home pane, the
// palette's scrim), or cmds.length: terminals are drawn between the chrome
// and the overlays (floating elements come last, by zIndex).
ui_overlay_start :: proc(cmds: clay.ClayArray(clay.RenderCommand), name: string) -> i32 {
	id := clay.ID(name).id
	for i in 0 ..< cmds.length do if cmds.internalArray[i].id == id do return i
	return cmds.length
}

// Draws Clay's commands [from, to) (inside draw_begin/draw_end).
ui_draw :: proc(cmds: clay.ClayArray(clay.RenderCommand), from, to: i32) {
	for i in from ..< to {
		cmd := &cmds.internalArray[i]
		b := cmd.boundingBox
		switch cmd.commandType {
		case .Rectangle:
			rd := cmd.renderData.rectangle
			if rd.backgroundColor.a == 0 do continue
			draw_round_rect(b.x, b.y, b.width, b.height, rd.cornerRadius, to_rgba(rd.backgroundColor))
		case .Text:
			t := cmd.renderData.text
			col := to_rgba(t.textColor)
			if col.a == 0 do continue
			kind, bold := font_id_split(t.fontId)
			draw_text(b.x, b.y, string(t.stringContents.chars[:t.stringContents.length]), col, kind, bold, font_id_italic(t.fontId), font_id_semibold(t.fontId))
		case .Border:
			draw_border(b.x, b.y, b.width, b.height, cmd.renderData.border)
		case .ScissorStart:
			sgl.end()
			sgl.scissor_rect(i32(b.x), i32(b.y), i32(b.width), i32(b.height), true)
			sgl.begin_quads()
		case .ScissorEnd:
			sgl.end()
			sgl.scissor_rect(0, 0, 1 << 15, 1 << 15, true)
			sgl.begin_quads()
		case .Custom:
			ic, col, param := icon_of_command(cmd)
			x, y, iw, ih := icon_draw_box(cmd) // a flashing mark pops about its centre (status_mark_el)
			draw_icon(ic, x, y, iw, ih, col, param)
		case .None, .Image, .OverlayColorStart, .OverlayColorEnd:
		}
	}
}

// The right column's empty state.
RIGHT_EMPTY_HINT :: "Subagents, shells and todos show here"
