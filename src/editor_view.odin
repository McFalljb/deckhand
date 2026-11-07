package main

// Editor tabs on screen: drawing (gutter with line numbers and git marks,
// syntax colours, selection, find matches, cursor, status line) and input
// (keys, mouse, wheel, input methods). Like the terminal, text sits on the
// mono font's cell grid and is drawn per character through the shared run
// cache; only visible lines are touched, and nothing is drawn unless
// something changed (app.redraw).
//
// The bars above the text (find / replace / go to line, and the
// changed-on-disk banner) are Clay elements (editor_bars_layout, called by
// ui.odin's centre column); their fields are ordinary Text_Fields focused
// through State.focus_widget ("editor_find", "editor_replace",
// "editor_goto").

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strconv"
import "core:text/regex"
import "core:strings"
import "core:unicode/utf8"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"
import sgl "../vendor/sokol-odin/sokol/gl"

Editor_Bar :: enum u8 {
	None,
	Find,
	Replace,
	Goto,
}

editor_host := Tab_Host {
	display = .Drawn,
	draw = proc(tab_id: u64, x, y, w, h: f32) {if e := editor_of(tab_id); e != nil do editor_draw(e, x, y, w, h)},
}

// ---- metrics ----

Layout_Metrics :: struct {
	x, y, w, h:   f32, // text area (without gutter and status line)
	gutter_x:     f32,
	lh:           f32, // line height
	cw:           f32,
	cols:         int, // text columns that fit (soft wrap width)
	rows:         int, // rows that fit
	digits:       int,
}

@(private = "file")
metrics :: proc(e: ^Editor, x, y, w, h: f32) -> (m: Layout_Metrics) {
	m.lh = math.round(font.cell_h + px(EDITOR_LINE_PAD))
	m.cw = font.cell_w
	m.digits = max(3, len(fmt.tprint(tb_line_count(&e.buf))))
	gutter := px(EDITOR_GUTTER_PAD) + f32(m.digits) * m.cw + px(EDITOR_GUTTER_PAD) + px(EDITOR_DIFF_W) + px(SP_2)
	if e.view != .File do gutter = px(EDITOR_GUTTER_PAD)
	m.gutter_x = x
	m.x = x + gutter
	m.y = y
	m.w = max(w - gutter - px(SP_2), m.cw)
	m.h = max(h - m.lh, m.lh) // the status line
	m.cols = max(int(m.w / m.cw), 8)
	m.rows = max(int(m.h / m.lh), 1)
	return
}

// Row starts (byte offsets into text) of a line when soft-wrapped at cols:
// at the last space before the edge, else at the edge. {0} without wrap.
@(private = "file")
row_breaks :: proc(e: ^Editor, text: string, cols: int, out: ^[dynamic]int) {
	clear(out)
	append(out, 0)
	if !e.wrap do return
	col := 0
	row_start := 0
	last_space := -1
	for r, i in text {
		next := r == '\t' ? (col / EDITOR_TAB_WIDTH + 1) * EDITOR_TAB_WIDTH : col + rune_cols(r)
		if next - disp_col(text, row_start) > cols && i > row_start {
			at := last_space > row_start ? last_space : i
			append(out, at)
			row_start = at
			last_space = -1
		}
		if r == ' ' do last_space = i + 1
		col = next
	}
}

@(private = "file")
rows_of :: proc(e: ^Editor, line, cols: int) -> int {
	if !e.wrap do return 1
	row_breaks(e, tb_line(&e.buf, line, &e.scratch_draw), cols, &e.breaks)
	return len(e.breaks)
}

// Scrolls by px (positive = down), row by row, clamped to the document.
editor_scroll_by :: proc(e: ^Editor, dpx: f32, m_lh: f32, cols: int) {
	lh := m_lh
	e.frac += dpx
	n := tb_line_count(&e.buf)
	for e.frac >= lh {
		if e.top_sub + 1 < rows_of(e, e.top, cols) {
			e.top_sub += 1
		} else if e.top + 1 < n {
			e.top += 1
			e.top_sub = 0
		} else {
			e.frac = 0
			break
		}
		e.frac -= lh
		if !e.wrap && e.frac >= lh { 	// big jumps without wrap: arithmetic
			k := min(int(e.frac / lh), n - 1 - e.top)
			e.top += k
			e.frac -= f32(k) * lh
		}
	}
	for e.frac < 0 {
		if e.top_sub > 0 {
			e.top_sub -= 1
		} else if e.top > 0 {
			e.top -= 1
			e.top_sub = rows_of(e, e.top, cols) - 1
		} else {
			e.frac = 0
			break
		}
		e.frac += lh
		if !e.wrap && e.frac < 0 {
			k := min(int(-e.frac / lh), e.top)
			e.top -= k
			e.frac += f32(k) * lh
		}
	}
	app.redraw = true
}

// Brings the cursor into view (with a margin of lines) after a move or edit.
@(private = "file")
follow_cursor :: proc(e: ^Editor, m: Layout_Metrics) {
	e.follow = false
	cl := tb_line_of(&e.buf, e.cursor)
	ls := tb_line_start(&e.buf, cl)
	text := tb_line(&e.buf, cl, &e.scratch_draw)
	row_breaks(e, text, m.cols, &e.breaks)
	sub := 0
	for b, i in e.breaks do if e.cursor - ls >= b do sub = i
	margin := min(EDITOR_SCROLL_MARGIN, m.rows / 3)
	// above the top: the cursor's row goes `margin` rows under the top
	if cl < e.top || (cl == e.top && sub < e.top_sub) || (cl == e.top && sub == e.top_sub && e.frac > 0) {
		e.top, e.top_sub, e.frac = cl, sub, 0
		editor_scroll_by(e, -f32(margin) * m.lh, m.lh, m.cols)
	} else {
		// rows from the top to the cursor's row
		rows := 0
		l, s := e.top, e.top_sub
		far := m.rows + 64
		for (l < cl || (l == cl && s < sub)) && rows <= far {
			n := rows_of(e, l, m.cols)
			if l < cl {
				rows += n - s
				l += 1
				s = 0
			} else {
				rows += sub - s
				s = sub
			}
		}
		limit := m.rows - 1 - margin
		if rows > limit {
			if rows > far {
				// far below: jump, the cursor's row `margin` rows above the bottom
				e.top, e.top_sub, e.frac = cl, sub, 0
				editor_scroll_by(e, -f32(limit) * m.lh, m.lh, m.cols)
			} else {
				editor_scroll_by(e, f32(rows - limit) * m.lh + e.frac, m.lh, m.cols)
				e.frac = 0
			}
		}
	}
	// horizontal (no wrap)
	if !e.wrap {
		x := f32(disp_col(text, e.cursor - ls)) * m.cw
		edge := f32(4) * m.cw
		if x < e.scroll_x + edge do e.scroll_x = max(x - edge, 0)
		if x > e.scroll_x + m.w - edge do e.scroll_x = x - m.w + edge
	}
}

// ---- drawing ----

editor_draw :: proc(e: ^Editor, x, y, w, h: f32) {
	th := theme()
	ec := editor_colors()
	draw_rect(x, y, w, h, th.bg_app)
	if e.refused != "" {
		msg := e.refused
		tw := text_width(msg, .UI)
		draw_text(x + (w - tw) / 2, y + h / 2 - text_line_height(.UI), msg, th.text_secondary)
		hint := fs_display(e.path)
		hw := text_width(hint, .UI_Small)
		draw_text(x + (w - hw) / 2, y + h / 2 + px(SP_1), hint, th.text_muted, .UI_Small)
		return
	}
	m := metrics(e, x, y, w, h)
	e.area, e.area_drawn = m, true // its own: each pane draws its editor (panes.odin); cleared each draw pass (editors_frame_begin)
	e.view_rows = m.rows
	if e.view == .File do git_gutter_update(e)
	if e.follow do follow_cursor(e, m)
	if e.bar == .Find || e.bar == .Replace do find_update(e)
	n := tb_line_count(&e.buf)
	e.top = clamp(e.top, 0, n - 1)

	// visible bytes, for the highlighter: from the top line to the last line that can show
	last_line := min(e.top + m.rows + 1, n - 1)
	vis_lo := tb_line_start(&e.buf, e.top)
	vis_hi := min(tb_line_end(&e.buf, last_line), vis_lo + (4 << 20))
	toks := syntax_tokens(&e.sx, &e.buf, vis_lo, vis_hi, &e.scratch2)

	sel_lo, sel_hi := ed_selection(e)
	cur_line := tb_line_of(&e.buf, e.cursor)
	baseline := math.round((m.lh - font.cell_h) / 2) + font.baseline
	first_col := int(e.scroll_x / m.cw)
	ox := m.x - (e.wrap ? 0 : e.scroll_x)
	fm := e.find.matches[:]
	fi := 0 // first find match that may be visible
	if len(fm) > 0 {
		lo_i, hi_i := 0, len(fm)
		for lo_i < hi_i {
			mid := (lo_i + hi_i) / 2
			if fm[mid][1] <= vis_lo do lo_i = mid + 1
			else do hi_i = mid
		}
		fi = lo_i
	}

	row_y := m.y - e.frac
	line := e.top
	sub := e.top_sub
	cursor_xy := [2]f32{-1, -1}
	Row :: struct {
		line, sub: int,
		y:         f32,
	}
	rows := make([dynamic]Row, 0, m.rows + 2, context.temp_allocator)
	// text, clipped to its area (scrolled text must not run into the gutter)
	sgl_scissor(m.x - px(SP_1), m.y, m.w + px(SP_2), m.h)
	for row_y < m.y + m.h && line < n {
		ls := tb_line_start(&e.buf, line)
		le := tb_line_end(&e.buf, line)
		text := tb_line(&e.buf, line, &e.scratch_draw)
		row_breaks(e, text, m.cols, &e.breaks)
		for ; sub < len(e.breaks) && row_y < m.y + m.h; sub += 1 {
			rs := e.breaks[sub]
			re := sub + 1 < len(e.breaks) ? e.breaks[sub + 1] : len(text)
			base_col := disp_col(text, rs)
			ry := row_y
			row_y += m.lh
			if ry + m.lh <= m.y do continue
			append(&rows, Row{line, sub, ry})
			// current line, find matches, selection
			if line == cur_line && sel_lo == sel_hi do draw_rect(m.x - px(SP_1), ry, m.w + px(SP_2), m.lh, ec.current_line)
			span_rect :: proc(text: string, a, b, rs, re, base_col: int, ox, ry: f32, m: Layout_Metrics, col: Rgba, past_end: bool) {
				lo, hi := max(a, rs), min(b, re)
				if lo > hi || (lo == hi && !past_end) do return
				x0 := ox + f32(disp_col(text, lo) - base_col) * m.cw
				x1 := ox + f32(disp_col(text, hi) - base_col) * m.cw
				if past_end do x1 += m.cw * 0.6
				draw_rect(x0, ry, max(x1 - x0, 1), m.lh, col)
			}
			for k := fi; k < len(fm) && fm[k][0] <= ls + re; k += 1 {
				a, b := fm[k][0] - ls, fm[k][1] - ls
				if b < rs do continue
				col := ec.find_match
				if k == e.find.current do col = th.selection
				span_rect(text, a, b, rs, re, base_col, ox, ry, m, col, false)
			}
			if sel_hi > sel_lo && sel_lo <= ls + re && sel_hi >= ls + rs {
				past := sel_hi > le && sub == len(e.breaks) - 1
				span_rect(text, sel_lo - ls, sel_hi - ls, rs, re, base_col, ox, ry, m, th.selection, past)
			}
			// glyphs
			dcol := base_col
			i := rs
			diff_col := Rgba{}
			if e.view != .File && len(text) > 0 {
				switch text[0] {
				case '+': diff_col = ec.diff_added
				case '-': diff_col = ec.diff_removed
				case '@': diff_col = th.accent
				}
			}
			for i < re {
				r, sz := utf8.decode_rune(text[i:])
				cps: [8]rune
				cps[0] = r
				nc := 1
				j := i + sz
				for j < re && nc < len(cps) { 	// combining marks join the character before
					r2, s2 := utf8.decode_rune(text[j:])
					if rune_cols(r2) != 0 do break
					cps[nc] = r2
					nc += 1
					j += s2
				}
				span := r == '\t' ? (dcol / EDITOR_TAB_WIDTH + 1) * EDITOR_TAB_WIDTH - dcol : max(rune_cols(r), 1)
				visible := e.wrap || (dcol + span > first_col && f32(dcol - first_col) * m.cw < m.w + m.cw)
				if visible && r != '\t' && r != ' ' {
					col := ec.syntax[.Plain]
					if toks != nil && ls + i >= vis_lo && ls + i < vis_hi do col = ec.syntax[toks[ls + i - vis_lo]]
					if diff_col.a != 0 do col = diff_col
					if r < 0x20 || r == 0x7f do cps[0] = 0x2400 + (r == 0x7f ? 0x21 : r) // control pictures
					run := text_cell_run(cps[:nc], false, false, span == 2 ? 2 : 1)
					draw_run(run, ox + f32(dcol - base_col) * m.cw, ry + baseline, col)
				}
				if ls + i == e.cursor do cursor_xy = {ox + f32(dcol - base_col) * m.cw, ry}
				dcol += span
				i = j
			}
			if cursor_xy.x < 0 && e.cursor == ls + re && (sub == len(e.breaks) - 1 || e.cursor < ls + le) do cursor_xy = {ox + f32(dcol - base_col) * m.cw, ry}
		}
		line += 1
		sub = 0
	}
	// cursor (and an input method's composition there)
	focused := state.focus_widget == "" // no field (the agent's included) has the keyboard
	if cursor_xy.x >= 0 && !e.readonly {
		cx, cy := cursor_xy.x, cursor_xy.y
		if focused && ime.marked != "" {
			mw := text_width(ime.marked, .Mono)
			draw_rect(cx, cy, mw, m.lh, th.bg_app)
			draw_text(cx, cy + math.round((m.lh - font.cell_h) / 2), ime.marked, ec.syntax[.Plain], .Mono)
			draw_rect(cx, cy + m.lh - font.line_thick, mw, font.line_thick, th.text)
			cx += text_width(ime.marked[:clamp(ime.caret, 0, len(ime.marked))], .Mono)
		}
		draw_rect(cx, cy, max(px(CARET_W), 1), m.lh, focused ? th.term_cursor : th.text_muted)
		ime.caret_rect = {cx, cy, font.cell_w, m.lh}
	}
	sgl_scissor(0, 0, 1 << 15, 1 << 15)
	// gutter: line numbers on each line's first row, git marks
	if e.view == .File do for r in rows {
		if r.line == cur_line && sel_lo == sel_hi do draw_rect(m.gutter_x, r.y, m.x - px(SP_1) - m.gutter_x, m.lh, ec.current_line)
		if r.sub == 0 {
			num := fmt.tprint(r.line + 1)
			nx := m.gutter_x + px(EDITOR_GUTTER_PAD) + f32(m.digits - len(num)) * m.cw
			ncol := r.line == cur_line ? th.text_secondary : ec.line_number
			for ch, i in num do draw_cell(ch, nx + f32(i) * m.cw, r.y + baseline, ncol)
		}
		if e.git.in_repo && r.line < len(e.git.marks) {
			bx := m.x - px(SP_2) - px(EDITOR_DIFF_W)
			switch e.git.marks[r.line] {
			case .Added:    draw_rect(bx, r.y, px(EDITOR_DIFF_W), m.lh, ec.diff_added)
			case .Modified: draw_rect(bx, r.y, px(EDITOR_DIFF_W), m.lh, ec.diff_modified)
			case .None:
			}
			if r.sub == 0 && r.line < len(e.git.removed) && e.git.removed[r.line] do draw_rect(bx - px(1), r.y - px(1), px(EDITOR_DIFF_W + 3), px(2), ec.diff_removed)
		}
	}
	draw_status_line(e, x, y + h - m.lh, w, m.lh)
}

// Clips the quads that follow to a rectangle (framebuffer px).
@(private = "file")
sgl_scissor :: proc(x, y, w, h: f32) {
	sgl.end()
	sgl.scissor_rect(i32(x), i32(y), i32(w), i32(h), true)
	sgl.begin_quads()
}

@(private = "file")
draw_cell :: proc(r: rune, x, baseline: f32, col: Rgba) {
	cps := [1]rune{r}
	draw_run(text_cell_run(cps[:], false, false, 1), x, baseline, col)
}

// The bottom line: notice or state on the left; position, line ending,
// indentation and language on the right.
@(private = "file")
draw_status_line :: proc(e: ^Editor, x, y, w, h: f32) {
	th := theme()
	draw_rect(x, y, w, h, th.bg_app)
	draw_rect(x, y, w, px(BORDER_W), th.border)
	ty := y + (h - text_line_height(.UI_Small)) / 2
	left := e.notice
	lcol := th.error
	if left == "" {
		lcol = th.text_muted
		switch {
		case e.view == .Diff_Head: left = "Diff with HEAD (read-only)"
		case e.view == .Diff_Disk: left = "Diff with the file on disk (read-only)"
		case e.view == .Changes:   left = changes_status_text(e.tab_id)
		case e.view == .File && e.readonly && e.refused == "": left = "Read-only copy"
		case e.missing:            left = "Deleted on disk: ⌘S saves it again"
		case editor_dirty(e):      left = "Unsaved changes"
		}
		if e.missing do lcol = th.waiting
	}
	draw_text(x + px(TERM_PAD), ty, left, lcol, .UI_Small)
	l, c := ed_line_col(e, e.cursor)
	lo, hi := ed_selection(e)
	pos := fmt.tprintf("Ln %d, Col %d", l, c)
	if hi > lo do pos = fmt.tprintf("%s (%d selected)", pos, strings.rune_count(tb_slice(&e.buf, lo, min(hi - lo, 1 << 20), &e.scratch2)))
	parts := [?]string {
		pos,
		e.eol == "\r\n" ? "CRLF" : "LF",
		e.indent_tabs ? "Tabs" : fmt.tprintf("Spaces: %d", e.indent_w),
		e.sx.lang != nil ? e.sx.lang.name : "plain text",
		e.wrap ? "Wrap" : "",
	}
	s := strings.builder_make(context.temp_allocator)
	for p in parts {
		if p == "" do continue
		if strings.builder_len(s) > 0 do strings.write_string(&s, "   ")
		strings.write_string(&s, p)
	}
	rs := strings.to_string(s)
	draw_text(x + w - px(TERM_PAD) - text_width(rs, .UI_Small), ty, rs, th.text_muted, .UI_Small)
}

// ---- hits ----

// The byte offset under (mx, my) in the last drawn area (clamped to it).
@(private = "file")
offset_at :: proc(e: ^Editor, mx, my: f32) -> int {
	m := e.area
	n := tb_line_count(&e.buf)
	ry := m.y - e.frac
	line, sub := e.top, e.top_sub
	target := clamp(my, m.y - m.lh * 50, m.y + m.h + m.lh * 50)
	for {
		text := tb_line(&e.buf, line, &e.scratch_draw)
		row_breaks(e, text, m.cols, &e.breaks)
		for ; sub < len(e.breaks); sub += 1 {
			if target < ry + m.lh || (line == n - 1 && sub == len(e.breaks) - 1) || (target < m.y && line == e.top) {
				rs := e.breaks[sub]
				re := sub + 1 < len(e.breaks) ? e.breaks[sub + 1] : len(text)
				base := disp_col(text, rs)
				want := base + int(math.round((mx - m.x + (e.wrap ? 0 : e.scroll_x)) / m.cw))
				off := rs + byte_at_col(text[rs:re], want - base)
				if sub + 1 < len(e.breaks) && off == re && re > rs do off = re - 1 // the row's own end, not the next row's start
				return tb_line_start(&e.buf, line) + clamp(off, 0, len(text))
			}
			ry += m.lh
		}
		line += 1
		sub = 0
		if line >= n do return tb_len(&e.buf)
	}
}

// A draw pass starts (frame(), before the tabs are drawn): no editor counts as drawn until it is
// drawn again, so one not shown this frame (another tab, a Markdown preview over it) takes no hits.
editors_frame_begin :: proc() {
	for _, e in editors do e.area_drawn = false
}

// The point is over editor e's text, in its pane (panes.odin), not under the drawer or the palette.
editor_text_hit :: proc(e: ^Editor, mx, my: f32) -> bool {
	if e == nil || !e.area_drawn do return false
	if state.home_open && inside(clay.ID("drawer"), mx, my) do return false
	if palette_is_open() do return false
	s := cur()
	p := pane_of_tab(s, e.tab_id)
	if p == nil do p = session_focused_pane(s) // a session with no panes yet: its implicit one
	return inside(pid(p, "terminal"), mx, my)
}

// ---- input ----

// Input for the active editor tab: keys while it has the keyboard, mouse
// and wheel over it. True if consumed.
editor_event :: proc(e: ^Editor, ev: ^sapp.Event) -> bool {
	#partial switch ev.type {
	case .KEY_DOWN, .CHAR, .KEY_UP, .CLIPBOARD_PASTED:
		if state.focus_widget != "" do return false
		return editor_key(e, ev)
	case .MOUSE_DOWN:
		if palette_is_open() || (state.home_open && inside(clay.ID("drawer"), ev.mouse_x, ev.mouse_y)) do return false
		if ev.mouse_button == .LEFT && bar_click(e, ev.mouse_x, ev.mouse_y) do return true
		if !editor_text_hit(e, ev.mouse_x, ev.mouse_y) do return false
		right := ev.mouse_button == .RIGHT || (ev.mouse_button == .LEFT && ev.modifiers & sapp.MODIFIER_CTRL != 0)
		if right {
			// the menu acts on the selection, or where the click was
			if e.refused == "" {
				off := offset_at(e, ev.mouse_x, ev.mouse_y)
				lo, hi := ed_selection(e)
				if off < lo || off > hi || lo == hi do ed_click(e, off, 1, false)
			}
			menu_open(Menu_Editor(e.tab_id), {ev.mouse_x, ev.mouse_y})
			return true
		}
		if ev.mouse_button != .LEFT do return false
		if e.refused != "" do return true
		if state.home_open && !state.layout.drawer_pinned do ui_do(Set_Home{open = false}) // as for terminals: a sliding drawer goes away
		if state.focus_widget != "" do ui_do(Set_Focus{""})
		ime_cancel()
		ed_click(e, offset_at(e, ev.mouse_x, ev.mouse_y), app.clicks, ev.modifiers & sapp.MODIFIER_SHIFT != 0)
		e.dragging = true
		return true
	case .MOUSE_MOVE:
		if !e.dragging do return false
		if ev.modifiers & sapp.MODIFIER_LMB == 0 {
			e.dragging = false
			return false
		}
		m := e.area
		if ev.mouse_y < m.y do editor_scroll_by(e, -m.lh, m.lh, m.cols)
		if ev.mouse_y > m.y + m.h do editor_scroll_by(e, m.lh, m.lh, m.cols)
		ed_drag(e, offset_at(e, ev.mouse_x, ev.mouse_y))
		e.follow = false
		return true
	case .MOUSE_UP:
		if !e.dragging do return false
		e.dragging = false
		return true
	case .MOUSE_SCROLL:
		if !editor_text_hit(e, ev.mouse_x, ev.mouse_y) do return false
		m := e.area
		dy, dx := ev.scroll_y, ev.scroll_x
		if ev.modifiers & sapp.MODIFIER_SHIFT != 0 && dx == 0 do dx, dy = dy, 0
		if dy != 0 do editor_scroll_by(e, -dy * m.lh, m.lh, m.cols)
		if dx != 0 && !e.wrap do e.scroll_x = max(e.scroll_x - dx * m.cw * 2, 0)
		app.redraw = true
		return true
	}
	return false
}

// The metrics keys move by: where e was last drawn; never drawn yet (a key before its first
// frame), its pane's rect now.
@(private = "file")
key_metrics :: proc(e: ^Editor) -> Layout_Metrics {
	if e.area.lh > 0 do return e.area
	r := tab_rect(e.tab_id)
	return metrics(e, r.x, r.y, r.z, r.w)
}

@(private = "file")
editor_key :: proc(e: ^Editor, ev: ^sapp.Event) -> bool {
	mods := ev.modifiers
	shift := mods & sapp.MODIFIER_SHIFT != 0
	cmd := mods & sapp.MODIFIER_SUPER != 0
	alt := mods & sapp.MODIFIER_ALT != 0
	ctrl := mods & sapp.MODIFIER_CTRL != 0
	m := key_metrics(e)
	#partial switch ev.type {
	case .CLIPBOARD_PASTED:
		if e.readonly do return true
		ed_insert(e, clipboard_text(), .Other)
		return true
	case .CHAR:
		if cmd || ctrl do return true
		if ev.char_code < 0x20 || ev.char_code == 0x7f do return true // Enter, Tab, ⌫ come as keys
		if e.readonly do return true
		if r, ok := utf16_unit(&app_surrogate, ev.char_code); ok do ed_insert(e, utf8_string(r))
		return true
	case .KEY_UP:
		return true
	case .KEY_DOWN:
	case:
		return false
	}
	if e.notice != "" {
		delete(e.notice)
		e.notice = ""
	}
	app.redraw = true
	if cmd {
		#partial switch ev.key_code {
		case .A:      ed_select_all(e)
		case .C:      if s := copy_text(e); s != "" && platform.set_clipboard != nil do platform.set_clipboard(s)
		case .X:
			if e.readonly do return true
			lo, hi := ed_copy_range(e)
			if platform.set_clipboard != nil do platform.set_clipboard(tb_copy(&e.buf, lo, hi - lo, context.temp_allocator))
			ed_replace(e, lo, hi, "", .Other)
		case .Z:      if shift do ed_redo(e); else do ed_undo(e)
		case .S:      ui_do(Save_File{e.tab_id})
		case .F:      open_bar(e, alt ? .Replace : .Find)
		case .G:      find_step(e, shift ? -1 : 1)
		case .SLASH:  if !e.readonly do ed_toggle_comment(e)
		case .LEFT:   ed_line_home(e, shift)
		case .RIGHT:  ed_line_end_move(e, shift)
		case .UP, .DOWN:
			if alt do return false // ⌥⌘↑ ⌥⌘↓: previous, next session (menubar.odin)
			ed_set_cursor(e, ev.key_code == .UP ? 0 : tb_len(&e.buf), shift)
		case .BACKSPACE:
			if !e.readonly do ed_delete_to(e, tb_line_start(&e.buf, tb_line_of(&e.buf, e.cursor)))
		case .RIGHT_BRACKET, .LEFT_BRACKET:
			if shift do return false // ⇧⌘] ⇧⌘[: next, previous tab (menubar.odin)
			if !e.readonly do ed_indent_lines(e, ev.key_code == .LEFT_BRACKET)
		case:
			return false // ⌘W, ⌘T, ⌘1–9, ⌘Q…: the app's
		}
		return true
	}
	if ctrl {
		#partial switch ev.key_code {
		case .G: open_bar(e, .Goto)
		case .A: ed_line_home(e, shift)
		case .E: ed_line_end_move(e, shift)
		case:    return true
		}
		return true
	}
	#partial switch ev.key_code {
	case .LEFT:      if alt do ed_move_word(e, -1, shift); else do ed_move_char(e, -1, shift)
	case .RIGHT:     if alt do ed_move_word(e, 1, shift); else do ed_move_char(e, 1, shift)
	case .UP:        ed_move_lines(e, -1, shift)
	case .DOWN:      ed_move_lines(e, 1, shift)
	case .PAGE_UP:
		ed_move_lines(e, -max(m.rows - 1, 1), shift)
		editor_scroll_by(e, -f32(max(m.rows - 1, 1)) * m.lh, m.lh, m.cols)
	case .PAGE_DOWN:
		ed_move_lines(e, max(m.rows - 1, 1), shift)
		editor_scroll_by(e, f32(max(m.rows - 1, 1)) * m.lh, m.lh, m.cols)
	case .HOME:      ed_line_home(e, shift)
	case .END:       ed_line_end_move(e, shift)
	case .ESCAPE:
		if e.bar != .None do close_bar(e)
		else do ed_set_cursor(e, e.cursor, false)
	case:
		if e.readonly do return true
		#partial switch ev.key_code {
		case .ENTER, .KP_ENTER: ed_newline(e)
		case .TAB:       if shift do ed_indent_lines(e, true); else do ed_tab(e)
		case .BACKSPACE: if alt do ed_delete_to(e, ed_word_from(e, e.cursor, -1)); else do ed_backspace(e)
		case .DELETE:    if alt do ed_delete_to(e, ed_word_from(e, e.cursor, 1)); else do ed_delete_forward(e)
		}
	}
	return true
}

@(private = "file")
copy_text :: proc(e: ^Editor) -> string {
	lo, hi := ed_copy_range(e)
	return tb_copy(&e.buf, lo, hi - lo, context.temp_allocator)
}

// An input method committed text / is composing (main.odin's ime_* hooks).
editor_ime_commit :: proc(e: ^Editor, text: string) {
	if e.readonly do return
	ed_insert(e, text)
}

// ---- bars: find, replace, go to line, changed on disk ----

Find :: struct {
	query:          Text_Field,
	replace:        Text_Field,
	goto_line:      Text_Field,
	case_sensitive: bool,
	regex:          bool,
	matches:        [dynamic][2]int,
	current:        int, // index into matches (-1 = none)
	key:            string, // query + flags the matches are for (owned)
	gen:            u64, // buffer generation they are for
	error:          string, // bad regex (owned)
	capped:         bool, // stopped at FIND_MAX
}

FIND_MAX :: 10_000

find_free :: proc(f: ^Find) {
	delete(f.query.buf)
	delete(f.replace.buf)
	delete(f.goto_line.buf)
	delete(f.matches)
	delete(f.key)
	delete(f.error)
}

open_bar :: proc(e: ^Editor, bar: Editor_Bar) {
	ime_cancel()
	switch bar {
	case .Find, .Replace:
		lo, hi := ed_selection(e)
		if hi > lo && hi - lo < 200 && tb_line_of(&e.buf, lo) == tb_line_of(&e.buf, hi) do tf_set(&e.find.query, ed_selected_text(e))
		else do tf_select_all(&e.find.query)
		e.bar = bar
		e.find.current = -1
		ui_do(Set_Focus{"editor_find"})
	case .Goto:
		tf_set(&e.find.goto_line, "")
		e.bar = .Goto
		ui_do(Set_Focus{"editor_goto"})
	case .None:
	}
	app.redraw = true
}

close_bar :: proc(e: ^Editor) {
	e.bar = .None
	clear(&e.find.matches)
	delete(e.find.key)
	e.find.key = ""
	if strings.has_prefix(state.focus_widget, "editor_") do ui_do(Set_Focus{""})
	app.redraw = true
}

// Recomputes the matches when the query, its flags or the text changed.
// A Markdown preview searches the text as shown instead (markdown_view.odin).
find_update :: proc(e: ^Editor) {
	if v := md_preview(e.tab_id); v != nil {
		md_find_update(v, e)
		return
	}
	f := &e.find
	q := tf_text(&f.query)
	key := fmt.tprintf("%v%v%s", f.case_sensitive, f.regex, q)
	if key == f.key && f.gen == e.gen do return
	delete(f.key)
	f.key = strings.clone(key)
	f.gen = e.gen
	clear(&f.matches)
	delete(f.error)
	f.error = ""
	f.capped = false
	f.current = -1
	if q == "" do return
	find_matches(f, tb_text(&e.buf, context.temp_allocator), q)
	// the current match: the first at or after the cursor
	lo, _ := ed_selection(e)
	for mm, i in f.matches do if mm[0] >= lo {
		f.current = i
		break
	}
	if f.current < 0 && len(f.matches) > 0 do f.current = 0
}

// The matches of q in text (byte ranges), by f's case and regex flags.
find_matches :: proc(f: ^Find, text, q: string) {
	clear(&f.matches)
	delete(f.error)
	f.error = ""
	f.capped = false
	if q == "" do return
	if f.regex {
		find_regex(f, text, q)
	} else {
		hay, needle := text, q
		if !f.case_sensitive {
			hay = strings.to_lower(text, context.temp_allocator)
			needle = strings.to_lower(q, context.temp_allocator)
		}
		at := 0
		for len(f.matches) < FIND_MAX {
			i := strings.index(hay[at:], needle)
			if i < 0 do break
			append(&f.matches, [2]int{at + i, at + i + len(needle)})
			at += i + max(len(needle), 1)
		}
	}
	f.capped = len(f.matches) >= FIND_MAX
}

// Selects the next (dir > 0) or previous match after the cursor.
find_step :: proc(e: ^Editor, dir: int) {
	if v := md_preview(e.tab_id); v != nil {
		md_find_step(v, e, dir)
		return
	}
	if tf_text(&e.find.query) == "" do return
	find_update(e)
	f := &e.find
	if len(f.matches) == 0 do return
	lo, hi := ed_selection(e)
	pick := -1
	if dir > 0 {
		for mm, i in f.matches do if mm[0] >= hi && !(mm[0] == lo && mm[1] == hi) {
			pick = i
			break
		}
		if pick < 0 do pick = 0
	} else {
		#reverse for mm, i in f.matches do if mm[1] <= lo && !(mm[0] == lo && mm[1] == hi) {
			pick = i
			break
		}
		if pick < 0 do pick = len(f.matches) - 1
	}
	f.current = pick
	e.anchor, e.cursor = f.matches[pick][0], f.matches[pick][1]
	e.follow = true
	e.break_group = true
	app.redraw = true
}

// Replaces the current match (when it is selected) and moves to the next.
replace_one :: proc(e: ^Editor) {
	if e.readonly do return
	find_update(e)
	f := &e.find
	lo, hi := ed_selection(e)
	for mm in f.matches do if mm[0] == lo && mm[1] == hi {
		ed_replace(e, lo, hi, tf_text(&f.replace), .Other)
		break
	}
	find_step(e, 1)
}

// Replaces every match as one undo step.
replace_all :: proc(e: ^Editor) -> int {
	if e.readonly do return 0
	find_update(e)
	f := &e.find
	if len(f.matches) == 0 do return 0
	first, last := f.matches[0][0], f.matches[len(f.matches) - 1][1]
	rep := tf_text(&f.replace)
	sb := strings.builder_make(context.temp_allocator)
	at := first
	for mm in f.matches {
		strings.write_string(&sb, tb_slice(&e.buf, at, mm[0] - at, &e.scratch))
		strings.write_string(&sb, rep)
		at = mm[1]
	}
	n := len(f.matches)
	ed_replace(e, first, last, strings.to_string(sb), .Other)
	return n
}

goto_run :: proc(e: ^Editor) {
	s := strings.trim_space(tf_text(&e.find.goto_line))
	ls, _, cs := strings.partition(s, ":")
	line, ok := strconv.parse_int(strings.trim_space(ls))
	col, _ := strconv.parse_int(strings.trim_space(cs))
	if ok do ed_goto(e, line, max(col, 1))
	close_bar(e)
}

// The focused bar field (ui.odin's focused_field asks), with its Clay ids.
editor_focused_field :: proc() -> (f: ^Text_Field, text_id, box_id: clay.ElementId) {
	e := active_editor()
	if e == nil do return nil, {}, {}
	switch state.focus_widget {
	case "editor_find":    return &e.find.query, clay.ID("ed_find_text"), clay.ID("ed_find_box")
	case "editor_replace": return &e.find.replace, clay.ID("ed_replace_text"), clay.ID("ed_replace_box")
	case "editor_goto":    return &e.find.goto_line, clay.ID("ed_goto_text"), clay.ID("ed_goto_box")
	}
	return nil, {}, {}
}

editor_bar_focused :: proc() -> bool {return strings.has_prefix(state.focus_widget, "editor_")}

// Keys of a bar field before the generic text-field handling (main.odin):
// Enter, Esc, Tab between fields, ⌘G, ⌥⌘F, ⌘S. True if consumed.
editor_bar_event :: proc(p: ^Pane, ev: ^sapp.Event) -> bool {
	e := pane_editor(p)
	if e == nil {
		if editor_bar_focused() do ui_do(Set_Focus{""})
		return false
	}
	if ev.type != .KEY_DOWN do return false
	shift := ev.modifiers & sapp.MODIFIER_SHIFT != 0
	alt := ev.modifiers & sapp.MODIFIER_ALT != 0
	cmd := ev.modifiers & sapp.MODIFIER_SUPER != 0
	app.redraw = true
	if cmd {
		#partial switch ev.key_code {
		case .G: find_step(e, shift ? -1 : 1)
		case .F: if alt do e.bar = .Replace
		case .S: ui_do(Save_File{e.tab_id})
		case .Z: if shift do ed_redo(e); else do ed_undo(e)
		case:    return false
		}
		return true
	}
	#partial switch ev.key_code {
	case .ESCAPE:
		close_bar(e)
		return true
	case .ENTER, .KP_ENTER:
		switch state.focus_widget {
		case "editor_find":    find_step(e, shift ? -1 : 1)
		case "editor_replace": if alt do replace_all(e); else do replace_one(e)
		case "editor_goto":    goto_run(e)
		}
		app.key_taken = true // its CHAR must not reach the text
		return true
	case .TAB:
		if e.bar == .Replace {
			ui_do(Set_Focus{state.focus_widget == "editor_find" ? "editor_replace" : "editor_find"})
			return true
		}
	}
	return false
}

// Clay: the bars above the editor text (called inside ui.odin's centre
// column, before the "terminal" element that becomes the text area).
editor_bars_layout :: proc(p: ^Pane) {
	e := pane_editor(p)
	if e == nil do return
	th := theme()
	if e.view != .Changes do toolbar_layout(e) // a Changes tab has its own bars (ui_changes.odin)
	if e.disk_changed {
		{
			if clay.UI(clay.ID("ed_banner"))({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_elevated),
				border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
			}) {
				if clay.UI()({layout = {sizing = {clay.SizingFixed(px(DOT)), clay.SizingFixed(px(DOT))}}, backgroundColor = cc(th.waiting), cornerRadius = clay.CornerRadiusAll(px(DOT / 2))}) {}
				// cut to the room left of the buttons: a long file name never pushes them out of the window
				used := px(2 * TERM_PAD + DOT + 5 * SP_2 + 6 * SP_3) + text_w("Compare") + text_w("Keep mine") + text_w("Reload", WEIGHT_BOLD)
				clay.TextDynamic(clip(fmt.tprintf("%s changed on disk. You have unsaved changes.", filepath.base(e.path)), max(centre_width() - used, px(80))), txt(th.text))
				grow()
				bar_button(clay.ID("ed_compare"), "Compare", false)
				bar_button(clay.ID("ed_keep"), "Keep mine", false)
				bar_button(clay.ID("ed_reload"), "Reload", true)
			}
		}
	}
	if e.bar == .None do return
	if clay.UI(clay.ID("ed_bar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(TERM_PAD), pu(TERM_PAD), pu(SP_1), pu(SP_1)}, childGap = pu(SP_1), layoutDirection = .TopToBottom},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		if e.bar == .Goto {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_BAR_H - 2 * SP_1))}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				clay.Text("Go to line", txt(th.text_secondary))
				bar_field(clay.ID("ed_goto_box"), clay.ID("ed_goto_text"), &e.find.goto_line, "line or line:column", state.focus_widget == "editor_goto")
				clay.TextDynamic(fmt.tprintf("1–%d", tb_line_count(&e.buf)), txt(th.text_muted))
			}
			return
		}
		f := &e.find
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_BAR_H - 2 * SP_1))}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
			bar_field(clay.ID("ed_find_box"), clay.ID("ed_find_text"), &f.query, "Find", state.focus_widget == "editor_find")
			bar_toggle(clay.ID("ed_case"), "Aa", f.case_sensitive)
			bar_toggle(clay.ID("ed_regex"), ".*", f.regex)
			count := "No results"
			if f.error != "" do count = f.error
			else if len(f.matches) > 0 do count = fmt.tprintf("%d of %d%s", f.current + 1, len(f.matches), f.capped ? "+" : "")
			else if tf_text(&f.query) == "" do count = ""
			clay.TextDynamic(count, txt(f.error != "" ? th.error : th.text_muted))
			grow()
			bar_button(clay.ID("ed_prev"), "↑", false)
			bar_button(clay.ID("ed_next"), "↓", false)
			bar_button(clay.ID("ed_replace_toggle"), e.bar == .Replace ? "Hide replace" : "Replace", false)
			bar_button(clay.ID("ed_close"), "×", false)
		}
		if e.bar == .Replace {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_BAR_H - 2 * SP_1))}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				bar_field(clay.ID("ed_replace_box"), clay.ID("ed_replace_text"), &f.replace, "Replace", state.focus_widget == "editor_replace")
				bar_button(clay.ID("ed_replace_one"), "Replace", false)
				bar_button(clay.ID("ed_replace_all"), "All", false)
			}
		}
	}
}

@(private = "file")
grow :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {}
}

@(private = "file")
bar_field :: proc(box, text_id: clay.ElementId, f: ^Text_Field, placeholder: string, focused: bool) {
	th := theme()
	if clay.UI(box)({
		layout = {sizing = {clay.SizingFixed(px(EDITOR_FIELD_W)), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(focused ? th.accent : th.border), width = {pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), 0}},
	}) {
		shown, _, _ := tf_display(f, focused ? ime.marked : "")
		if clay.UI(text_id)({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
			if shown == "" && !focused do clay.TextDynamic(placeholder, txt(th.text_muted))
			else do clay.TextDynamic(shown, txt(th.text))
		}
	}
}

@(private = "file")
bar_button :: proc(id: clay.ElementId, label: string, primary: bool) {
	th := theme()
	hovered := clay.PointerOver(id)
	bg := primary ? th.accent : mix(th.bg_elevated, th.text, hovered ? TINT_BUTTON_HOVER : TINT_BUTTON)
	col := primary ? th.text_on_accent : th.text
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(bg),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		clay.TextDynamic(label, txt(col, primary ? WEIGHT_BOLD : WEIGHT_REGULAR))
	}
}

@(private = "file")
bar_toggle :: proc(id: clay.ElementId, label: string, on: bool) {
	th := theme()
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(on ? with_alpha(th.accent, 0.35) : th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		clay.TextDynamic(label, txt(on ? th.text : th.text_muted, WEIGHT_BOLD))
	}
}

// A click on a bar's buttons. True if it hit one.
@(private = "file")
bar_click :: proc(e: ^Editor, mx, my: f32) -> bool {
	clay.SetPointerState({mx, my}, false)
	if toolbar_click(e) {
		app.redraw = true
		return true
	}
	hit :: proc(name: string) -> bool {return clay.PointerOver(clay.ID(name))}
	switch {
	case hit("ed_reload"):  ui_do(Reload_File{tab_id = e.tab_id})
	case hit("ed_keep"):    ui_do(Keep_Buffer{e.tab_id})
	case hit("ed_compare"): ui_do(Diff_File{e.tab_id, .Diff_Disk})
	case hit("ed_prev"):    find_step(e, -1)
	case hit("ed_next"):    find_step(e, 1)
	case hit("ed_close"):   close_bar(e)
	case hit("ed_case"):    e.find.case_sensitive = !e.find.case_sensitive
	case hit("ed_regex"):   e.find.regex = !e.find.regex
	case hit("ed_replace_toggle"):
		e.bar = e.bar == .Replace ? .Find : .Replace
	case hit("ed_replace_one"): replace_one(e)
	case hit("ed_replace_all"): replace_all(e)
	case hit("ed_find_box"):    if state.focus_widget != "editor_find" do ui_do(Set_Focus{"editor_find"})
	case hit("ed_replace_box"): if state.focus_widget != "editor_replace" do ui_do(Set_Focus{"editor_replace"})
	case hit("ed_goto_box"):    if state.focus_widget != "editor_goto" do ui_do(Set_Focus{"editor_goto"})
	case hit("ed_bar"), hit("ed_banner"):
	case:
		return false
	}
	app.redraw = true
	return true
}

@(private = "file")
find_regex :: proc(f: ^Find, text, q: string) {
	flags := regex.Flags{.Multiline, .Unicode}
	if !f.case_sensitive do flags += {.Case_Insensitive}
	re, err := regex.create(q, flags, context.temp_allocator, context.temp_allocator)
	if err != nil {
		f.error = fmt.aprintf("bad pattern")
		return
	}
	at := 0
	for at <= len(text) && len(f.matches) < FIND_MAX {
		c, ok := regex.match_and_allocate_capture(re, text[at:], context.temp_allocator)
		if !ok || len(c.pos) == 0 do break
		s, t := at + c.pos[0][0], at + c.pos[0][1]
		if t > s do append(&f.matches, [2]int{s, t})
		at = max(t, s + 1)
	}
}

// Whether ⌘/ toggles a comment in the shown editor (else it opens the
// shortcuts sheet).
editor_takes_cmd_slash :: proc() -> bool {
	e := tab_editor()
	// read-only views (diffs, refused files) have nothing to comment: the sheet
	return e != nil && !e.readonly && e.refused == "" && state.focus_widget == "" && !menu.open
}

// ---- buttons: the toolbar and the right-click menu ----
// Every editor action has a button or a menu row as well as its shortcut;
// the toolbar's tooltips name the shortcut.

Menu_Editor :: distinct u64 // tab id: the right-click menu over its text

Editor_Action :: enum u8 {
	None,
	Undo,
	Redo,
	Cut,
	Copy,
	Paste,
	Select_All,
	Toggle_Comment,
	Indent,
	Outdent,
	Find,
	Replace,
	Goto,
}

// Runs an editor step from a button or menu row.
editor_run_action :: proc(tab_id: u64, a: Editor_Action) {
	e := editor_of(tab_id)
	if e == nil do return
	ro := e.readonly
	switch a {
	case .None:
	case .Undo:           ed_undo(e)
	case .Redo:           ed_redo(e)
	case .Copy:           if s := copy_text(e); s != "" && platform.set_clipboard != nil do platform.set_clipboard(s)
	case .Cut:
		if ro do break
		lo, hi := ed_copy_range(e)
		if platform.set_clipboard != nil do platform.set_clipboard(tb_copy(&e.buf, lo, hi - lo, context.temp_allocator))
		ed_replace(e, lo, hi, "", .Other)
	case .Paste:          if !ro do ed_insert(e, clipboard_text(), .Other)
	case .Select_All:     ed_select_all(e)
	case .Toggle_Comment: if !ro do ed_toggle_comment(e)
	case .Indent:         if !ro do ed_indent_lines(e, false)
	case .Outdent:        if !ro do ed_indent_lines(e, true)
	case .Find:           open_bar(e, .Find)
	case .Replace:        if !ro do open_bar(e, .Replace)
	case .Goto:           open_bar(e, .Goto)
	}
	app.redraw = true
}

// The right-click menu's rows (ui_sidebar.odin's menu draws and runs them).
editor_menu_items :: proc(tab_id: u64, items: ^[dynamic]Menu_Item) {
	e := editor_of(tab_id)
	if e == nil do return
	ro := e.readonly || e.refused != ""
	if e.refused == "" {
		if !ro do append(items, Menu_Item{label = "Cut", keys = "⌘X", editor = .Cut})
		append(items, Menu_Item{label = "Copy", keys = "⌘C", editor = .Copy})
		if !ro do append(items, Menu_Item{label = "Paste", keys = "⌘V", editor = .Paste})
		append(items, Menu_Item{label = "Select all", keys = "⌘A", editor = .Select_All})
		append(items, Menu_Item{sep = true})
		if !ro && e.sx.lang != nil do append(items, Menu_Item{label = "Toggle comment", keys = "⌘/", editor = .Toggle_Comment})
		if !ro do append(items, Menu_Item{label = "Indent", keys = "⌘]", editor = .Indent})
		if !ro do append(items, Menu_Item{label = "Outdent", keys = "⌘[", editor = .Outdent})
		append(items, Menu_Item{label = "Find…", keys = "⌘F", editor = .Find})
		append(items, Menu_Item{label = "Go to line…", keys = "⌘L", editor = .Goto})
	}
	if e.view == .File {
		append(items, Menu_Item{sep = true})
		if e.git.in_repo && e.refused == "" do append(items, Menu_Item{label = "Diff with HEAD", cmd = Diff_File{e.tab_id, .Diff_Head}})
		append(items, Menu_Item{label = "Reveal in Finder", cmd = Reveal_In_Finder{path = e.path}})
	}
}

@(private = "file")
Tool :: struct {
	label:   string,
	act:     string, // the action it runs (actions.odin): its label and shortcut are the tooltip
	tip:     string, // or, for an editor step with no action, the tooltip
	keys:    string,
	enabled: bool,
	on:      bool, // a toggle that is on
	step:    Editor_Action,
	gap:     bool, // a small gap before it (groups)
}

// The toolbar's buttons for e (temp allocator).
@(private = "file")
editor_tools :: proc(e: ^Editor) -> []Tool {
	out := make([dynamic]Tool, context.temp_allocator)
	file := e.view == .File && e.refused == ""
	text := e.refused == ""
	if md_view_of(e.tab_id) != nil {
		// a Markdown tab (markdown_view.odin): read-only; the toggle, find, the editor
		preview := md_preview(e.tab_id) != nil
		if text do append(&out, Tool{label = preview ? "Source" : "Preview", act = "markdown_preview", enabled = true})
		if text do append(&out, Tool{label = "Find", act = "find_in_file", enabled = true, on = e.bar == .Find, step = .Find, gap = true})
		if text && !preview {
			append(&out, Tool{label = "Go to line", act = "goto_line", enabled = true, on = e.bar == .Goto, step = .Goto})
			append(&out, Tool{label = "Wrap", act = "toggle_wrap", enabled = true, on = e.wrap})
		}
		append(&out, Tool{label = "Open in editor", act = "markdown_edit", enabled = true, gap = true})
		append(&out, Tool{label = "Reveal", act = "reveal_file", enabled = true})
		return out[:]
	}
	if file do append(&out, Tool{label = "Save", act = "save_file", enabled = editor_dirty(e) || e.missing})
	if text && !e.readonly {
		append(&out, Tool{label = "Undo", tip = "Undo", keys = "⌘Z", enabled = len(e.undo) > 0, step = .Undo, gap = true})
		append(&out, Tool{label = "Redo", tip = "Redo", keys = "⇧⌘Z", enabled = len(e.redo) > 0, step = .Redo})
	}
	if text {
		append(&out, Tool{label = "Find", act = "find_in_file", enabled = true, on = e.bar == .Find, step = .Find, gap = true})
		if !e.readonly do append(&out, Tool{label = "Replace", tip = "Find and replace", keys = "⌥⌘F", enabled = true, on = e.bar == .Replace, step = .Replace})
		append(&out, Tool{label = "Go to line", act = "goto_line", enabled = true, on = e.bar == .Goto, step = .Goto})
		append(&out, Tool{label = "Wrap", act = "toggle_wrap", enabled = true, on = e.wrap, gap = true})
	}
	if file && e.git.in_repo do append(&out, Tool{label = "Diff", act = "diff_head", enabled = true})
	if file && md_is_markdown_path(e.path) do append(&out, Tool{label = "Preview", act = "markdown_preview", enabled = true})
	if e.view == .File do append(&out, Tool{label = "Reveal", act = "reveal_file", enabled = true})
	return out[:]
}

// The toolbar button under the pointer (ui_hit), as a Hit for hover and tooltips.
editor_tool_hit :: proc() -> Hit {
	e := tab_editor()
	if e == nil do return nil
	for _, i in editor_tools(e) do if clay.PointerOver(clay.ID("ed_tool", u32(i))) do return Hit_Editor_Tool(i)
	return nil
}

// A toolbar button's tooltip: the action table's label and shortcut where it
// runs an action (hit_tip, ui_toolbar.odin).
editor_tool_tip :: proc(i: int) -> (label, keys: string) {
	e := tab_editor()
	if e == nil do return "", ""
	tools := editor_tools(e)
	if i < 0 || i >= len(tools) do return "", ""
	t := tools[i]
	if t.act != "" do if a := action_by_id(t.act); a != nil do return action_label(a), a.keys
	return t.tip, t.keys
}

// Clay: the toolbar row (first of the editor's bars): button groups split by
// a thin separator, then the file's path on the right. Groups that do not fit
// the centre's width are left out from the end (their actions stay in the
// palette, the right-click menu and the shortcuts); the path is cut first.
@(private = "file")
toolbar_layout :: proc(e: ^Editor) {
	th := theme()
	tools := editor_tools(e)
	avail := centre_width() - px(2 * TERM_PAD)
	shown := len(tools)
	for shown > 0 && toolbar_width(tools[:shown]) > avail do shown -= 1
	for shown > 0 && shown < len(tools) && !tools[shown].gap do shown -= 1 // whole groups
	path := fs_display(e.path)
	path_room := avail - toolbar_width(tools[:shown]) - px(GAP_GROUP)
	if clay.UI(clay.ID("ed_tools"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_TOOLBAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(GAP_BUTTONS), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		for t, i in tools[:shown] {
			if t.gap && i > 0 do group_separator()
			id := clay.ID("ed_tool", u32(i))
			hovered := ui_hover == Hit(Hit_Editor_Tool(i)) && t.enabled
			bg := t.on ? with_alpha(th.accent, 0.3) : (hovered ? mix(th.bg_app, th.text, TINT_BUTTON_HOVER) : Rgba{})
			col := !t.enabled ? th.text_muted : (hovered || t.on ? th.text : th.text_secondary)
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TAB_H - SP_1))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
				backgroundColor = cc(bg),
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				clay.TextDynamic(t.label, txt(col))
			}
		}
		grow()
		if path_room > px(SP_6) do clay.TextDynamic(clip(path, path_room), txt(th.text_muted))
	}
}

// The toolbar's buttons' width: labels, their padding, the gaps and separators.
@(private = "file")
toolbar_width :: proc(tools: []Tool) -> f32 {
	w: f32 = 0
	for t, i in tools {
		w += text_w(t.label) + px(2 * SP_2)
		if i > 0 do w += px(GAP_BUTTONS)
		if t.gap && i > 0 do w += px(GAP_GROUP + GAP_BUTTONS)
	}
	return w
}

// A click on the toolbar. True if it hit a button.
@(private = "file")
toolbar_click :: proc(e: ^Editor) -> bool {
	for t, i in editor_tools(e) {
		if !clay.PointerOver(clay.ID("ed_tool", u32(i))) do continue
		if !t.enabled do return true
		tip_dismiss()
		if t.act != "" do action_run(t.act) // as from the palette (prepare included)
		else if t.step != .None do editor_run_action(e.tab_id, t.step)
		return true
	}
	return clay.PointerOver(clay.ID("ed_tools"))
}
