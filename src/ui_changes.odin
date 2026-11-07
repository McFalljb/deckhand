package main

// The Changes tab on screen (model: changes.odin). Above the centre's text
// area: a header (the branch against the default branch, Refresh, Ask pi to
// review, Merge into main… (disabled: later)), the commit row (message
// field, Commit) and a banner with the last action's outcome. Below it, a
// row: the file list on the left (scope and status headers, rows with the
// status letter, the name, +/- counts and a staged dot; virtualised), and
// on the right the selected file's bar (↑ ↓, its path, Open, Stage,
// Unstage, Discard…) over the diff, which is the tab's read-only editor in
// the "terminal" element (editor_draw: scrolling, selection, copy, find),
// and "Show more" when a long diff is cut. j/k and ↑/↓ move between files.
//
// The top bar has a "±" button with the current session's count of
// changed files; it opens the tab (also the palette's "Show changes" and
// the Files tab's worktree row menu).

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

changes_host := Tab_Host {
	display = .Drawn,
	draw = proc(tab_id: u64, x, y, w, h: f32) {if e := editor_of(tab_id); e != nil do editor_draw(e, x, y, w, h)},
}

Changes_Hit_Kind :: enum u8 {
	Button, // the top bar's "±"
	Tool, // index: Changes_Tool
	Row, // index: the drawn slot
	List, // the list's empty space
	Field, // the commit message field
}
Hit_Changes :: struct {
	what:  Changes_Hit_Kind,
	index: int,
}

Changes_Tool :: enum u8 {
	Refresh,
	Review,
	Merge,
	Commit,
	Prev,
	Next,
	Open,
	Stage,
	Unstage,
	Discard,
	More,
}

@(private = "file")
TOOL_LABEL := [Changes_Tool]string {
	.Refresh = "Refresh",
	.Review  = "Ask pi to review",
	.Merge   = "Merge into main…",
	.Commit  = "Commit",
	.Prev    = "↑",
	.Next    = "↓",
	.Open    = "Open",
	.Stage   = "Stage",
	.Unstage = "Unstage",
	.Discard = "Discard…",
	.More    = "Show more",
}

CHANGES_ROWS_DRAWN_MAX :: 128

// What the list drew last (slot -> row index into changes_rows), for hits.
@(private = "file")
drawn: [CHANGES_ROWS_DRAWN_MAX]int
@(private = "file")
drawn_n: int
@(private = "file")
last_active: u64 // the Changes tab laid out last (a new one is read again: "on focus")

// The Changes tab on screen (nil = another tab).
active_changes :: proc() -> ^Changes_View {
	tab := active_tab()
	if tab == nil do return nil
	if _, is := tab.kind.(Changes_Tab); !is do return nil
	return changes_view(tab.id)
}

// ---- the top bar's button ----

// The checkout of the session on screen and its model (nil = none).
@(private = "file")
session_repo :: proc(cs: ^Open_Session) -> ^Changes_Repo {
	if cs == nil || cs.home || cs.missing do return nil
	return changes_repo(changes_root_of(cs.cwd))
}

@(private = "file")
button_label :: proc(r: ^Changes_Repo) -> string {
	n := changes_count(r)
	return n > 0 ? fmt.tprintf("± %d", min(n, 9999)) : "±"
}

// The "±" button's width with its gap (0 = not shown: no git checkout).
changes_button_w :: proc(cs: ^Open_Session) -> f32 {
	r := session_repo(cs)
	if r == nil do return 0
	return text_w(button_label(r)) + px(2 * SP_2) + px(SP_1)
}

// Whether the "±" shows in the top bar (ui.odin's tab strip sets it per
// layout): only when the tabs at their narrowest still fit beside it.
changes_btn_shown: bool

changes_button_decide :: proc(cs: ^Open_Session, bar_w: f32) {
	changes_btn_shown = false
	bw := changes_button_w(cs)
	if bw == 0 do return
	need := top_bar_fixed_w() + bw + tab_close_w() + px(SP_4)
	for _ in cs.tabs do need += px(TAB_MIN_W + SP_1)
	changes_btn_shown = need <= bar_w
}

// Clay: the "±" button (ui.odin's tab strip), after "+".
changes_tab_button :: proc(cs: ^Open_Session) {
	r := session_repo(cs)
	if r == nil do return
	changes_ask(r)
	th := theme()
	id := clay.ID("changesbtn")
	v := active_changes()
	bg, em := overlay(id, v != nil && v.root == r.root, ui_hover == Hit(Hit_Changes{what = .Button}))
	col := mix(th.text_muted, th.text, em)
	if changes_count(r) > 0 do col = mix(th.text_secondary, th.text, em)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TOOL_BUTTON))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		clay.TextDynamic(button_label(r), txt(col))
	}
}

// ---- layout ----

@(private = "file")
tool_w :: proc(t: Changes_Tool) -> f32 {return text_w(tool_label(t)) + px(2 * SP_2)}

@(private = "file")
tool_label :: proc(t: Changes_Tool) -> string {
	if t == .Review {
		if v := active_changes(); v != nil {
			if s, _, _ := find_tab(v.tab_id); s != nil && s.agent == .Claude do return "Ask Claude to review"
		}
	}
	if t == .Merge {
		if v := active_changes(); v != nil {
			if r := changes_repo(v.root); r != nil && r.default_branch != "" do return fmt.tprintf("Merge into %s…", r.default_branch)
		}
	}
	return TOOL_LABEL[t]
}

// Whether a tool applies now, and why not.
changes_tool_state :: proc(v: ^Changes_View, t: Changes_Tool) -> (enabled: bool, why: string) {
	r, f := changes_selected(v)
	busy := v.busy != ""
	switch t {
	case .Refresh:
		return true, ""
	case .Review:
		s, _, _ := find_tab(v.tab_id)
		if s != nil && s.agent == .Claude {
			// a Claude-only session: its main Claude tab (claude_prompt holds the text until it is idle)
			if len(s.tabs) == 0 || s.tabs[0].status != .Running do return false, "this session's Claude is not running"
			if _, is := s.tabs[0].kind.(Claude_Tab); !is do return false, "this session's Claude is not running"
			return true, ""
		}
		pt := session_pi_tab(s)
		if pt == nil || pt.status != .Running do return false, "this session's pi is not running"
		if pt.waiting do return false, "pi is waiting for you"
		return true, ""
	case .Merge:
		return false, "coming later"
	case .Commit:
		if busy do return false, v.busy
		staged := false
		if r != nil do for g in r.files do if g.scope == .Uncommitted && g.staged != .None do staged = true
		if !staged do return false, "stage files first"
		if strings.trim_space(tf_text(&changes_message_field)) == "" do return false, "write a message first"
		return true, ""
	case .Prev, .Next:
		return r != nil && len(r.files) > 0, ""
	case .Open:
		if f == nil do return false, "no file selected"
		if f.credential do return false, "credentials file: not opened"
		if f.status == 'D' do return false, "deleted"
		return true, ""
	case .Stage:
		if f == nil do return false, "no file selected"
		if f.scope == .Committed do return false, "already committed on the branch"
		if busy do return false, v.busy
		if f.status == 'U' do return false, "a conflict: resolve it in a terminal"
		if !f.unstaged do return false, "nothing to stage"
		return true, ""
	case .Unstage:
		if f == nil do return false, "no file selected"
		if f.scope == .Committed do return false, "already committed on the branch"
		if busy do return false, v.busy
		if f.staged == .None do return false, "nothing staged"
		return true, ""
	case .Discard:
		if f == nil do return false, "no file selected"
		if f.scope == .Committed do return false, "committed on the branch: not discarded here"
		if busy do return false, v.busy
		if f.status == 'U' do return false, "a conflict: resolve it in a terminal"
		return true, ""
	case .More:
		return v.diff_lines > v.shown, ""
	}
	return false, ""
}

@(private = "file")
tool :: proc(v: ^Changes_View, t: Changes_Tool, primary := false) {
	th := theme()
	id := clay.ID("chtool", u32(t))
	enabled, _ := changes_tool_state(v, t)
	hovered := enabled && ui_hover == Hit(Hit_Changes{what = .Tool, index = int(t)})
	bg := hovered ? mix(th.bg_app, th.text, TINT_BUTTON_HOVER) : mix(th.bg_app, th.text, TINT_BUTTON)
	col := enabled ? (hovered ? th.text : th.text_secondary) : with_alpha(th.text_muted, DISABLED_ALPHA + 0.2)
	if primary && enabled {
		bg = hovered ? mix(th.accent, th.text, TINT_PRIMARY_HOVER) : th.accent
		col = th.text_on_accent
	}
	if !enabled do bg = with_alpha(mix(th.bg_app, th.text, TINT_BUTTON), 0.5)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TAB_H - SP_1))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(bg),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		clay.TextDynamic(tool_label(t), txt(col, primary && enabled ? WEIGHT_BOLD : WEIGHT_REGULAR))
	}
}

// How many of tools fit in avail (with GAP_BUTTONS between), from the start.
@(private = "file")
fit :: proc(tools: []Changes_Tool, avail: f32) -> int {
	w: f32 = 0
	for t, i in tools {
		w += tool_w(t) + (i > 0 ? px(GAP_BUTTONS) : 0)
		if w > avail do return i
	}
	return len(tools)
}

@(private = "file")
bar :: proc(id: clay.ElementId, h: f32) -> clay.ElementDeclaration {
	th := theme()
	return {
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(h))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(GAP_BUTTONS), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}
}

// What the header says about the checkout: "topic → main · 2 commits".
@(private = "file")
branch_text :: proc(r: ^Changes_Repo) -> string {
	if r == nil || !r.loaded do return "Changes"
	b := r.branch != "" ? r.branch : "detached HEAD"
	if r.default_branch == "" || r.branch == r.default_branch do return b
	if r.ahead > 0 do return fmt.tprintf("%s → %s · %d %s ahead", b, r.default_branch, r.ahead, r.ahead == 1 ? "commit" : "commits")
	return fmt.tprintf("%s → %s", b, r.default_branch)
}

// Clay: the bars above the list and the diff (ui.odin's centre column,
// before the editor's bars).
changes_bars_layout :: proc(p: ^Pane) {
	v := pane_changes(p)
	if v == nil {
		last_active = 0
		return
	}
	r := changes_repo(v.root)
	changes_ask(r)
	if last_active != v.tab_id {
		last_active = v.tab_id
		changes_refresh(r) // focused: read again
	}
	th := theme()
	avail := centre_width() - px(2 * TERM_PAD)
	// header: branch and path, the status slot, Refresh, Ask pi to review, Merge
	if clay.UI(clay.ID("ch_head"))(bar(clay.ID("ch_head"), EDITOR_TOOLBAR_H)) {
		tools := []Changes_Tool{.Refresh, .Review, .Merge}
		n := fit(tools, avail)
		used: f32 = 0
		for t, i in tools[:n] do used += tool_w(t) + (i > 0 ? px(GAP_BUTTONS) : 0)
		status := ""
		if r != nil && r.slow do status = "Refreshing…"
		slot := text_w("Refreshing…") + px(SP_2)
		room := avail - used - px(GAP_GROUP)
		if room >= slot + px(SP_6) {
			room -= slot
		} else {
			slot = 0
		}
		if room > px(ICON_SIZE_SM + SP_6) {
			icon(.Branch, th.text_muted, ICON_SIZE_SM)
			title := clip(branch_text(r), room - px(ICON_SIZE_SM + GAP_INLINE))
			clay.TextDynamic(title, txt(th.text))
			left := room - px(ICON_SIZE_SM + GAP_INLINE) - text_w(title) - px(GAP_INLINE)
			if left > px(SP_6) {
				if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_INLINE - GAP_BUTTONS)), clay.SizingFit()}}}) {}
				clay.TextDynamic(clip(fs_display(v.root), left), txt(th.text_muted))
			}
		}
		spacer()
		if slot > 0 {
			if clay.UI(clay.ID("ch_status"))({layout = {sizing = {clay.SizingFixed(slot), clay.SizingFit()}}}) {
				if status != "" do clay.TextDynamic(status, txt(th.text_muted, FONT_UI_SMALL))
			}
		}
		for t in tools[:n] do tool(v, t)
	}
	// the commit row: message and Commit
	if clay.UI(clay.ID("ch_commit"))(bar(clay.ID("ch_commit"), EDITOR_BAR_H)) {
		cw := tool_w(.Commit)
		field_w := avail - cw - px(GAP_INLINE)
		focused := state.focus_widget == "changes_message"
		if field_w > px(SP_6 * 3) {
			if clay.UI(clay.ID("ch_field"))({
				layout = {sizing = {clay.SizingFixed(field_w), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_field),
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				border = {color = cc(focused ? th.accent : th.border), width = {pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), 0}},
				clip = {horizontal = true, childOffset = {}},
			}) {
				shown, _, _ := tf_display(&changes_message_field, focused ? ime.marked : "")
				if clay.UI(clay.ID("ch_field_text"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
					if shown == "" && !focused do clay.TextDynamic(clip("Commit message for the staged files", field_w - px(2 * SP_2)), txt(th.text_muted))
					else do clay.TextDynamic(shown, txt(th.text))
				}
			}
			if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_INLINE - GAP_BUTTONS)), clay.SizingFit()}}}) {}
		}
		if avail >= cw do tool(v, .Commit, primary = true)
	}
	// the last action's outcome, or what runs now
	msg := v.busy != "" ? v.busy : v.notice
	if msg != "" {
		if clay.UI(clay.ID("ch_notice"))(bar(clay.ID("ch_notice"), EDITOR_BAR_H - SP_2)) {
			col := v.notice_err && v.busy == "" ? th.error : th.text_secondary
			dot(v.notice_err && v.busy == "" ? th.error : (v.busy != "" ? th.running : th.done))
			if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_INLINE - GAP_BUTTONS)), clay.SizingFit()}}}) {}
			clay.TextDynamic(clip(msg, avail - px(DOT + GAP_INLINE)), txt(col))
		}
	}
}

// The list's width: a third of the centre, within bounds.
@(private = "file")
list_w :: proc() -> f32 {
	return clamp(centre_width() * 0.32, px(150), px(340))
}

@(private = "file")
ROW :: ROW_H - 4

// Clay: the file list (left of the diff, inside ui.odin's centre row).
changes_list_layout :: proc(p: ^Pane) {
	v := pane_changes(p)
	if v == nil do return
	th := theme()
	ec := editor_colors()
	r := changes_repo(v.root)
	rows := changes_rows(r)
	lw := list_w()
	// rows that fit: the list's height at the last layout
	h := px(600)
	if d := clay.GetElementData(clay.ID("ch_list")); d.found && d.boundingBox.height > 0 do h = d.boundingBox.height
	fitn := max(int((h - px(2 * SP_1)) / px(ROW)), 1)
	changes_list_rows_fit = fitn
	v.list_top = clamp(v.list_top, 0, max(len(rows) - fitn, 0))
	drawn_n = 0
	if clay.UI(clay.ID("ch_list"))({
		layout = {sizing = {clay.SizingFixed(lw), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {pu(SP_1), pu(SP_1), pu(SP_1), pu(SP_1)}},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(th.border), width = {right = pu(BORDER_W)}},
		clip = {vertical = true, horizontal = true, childOffset = {}},
	}) {
		inner := lw - px(2 * SP_1) - px(BORDER_W)
		if r == nil || !r.loaded {
			empty_state("Reading the changes…", "git status runs", inner)
			return
		}
		if r.err != "" {
			empty_state("Could not read the changes", r.err, inner)
			return
		}
		if len(rows) == 0 {
			empty_state("No changes", r.default_branch != "" && r.branch != r.default_branch ? fmt.tprintf("Nothing uncommitted, nothing ahead of %s", r.default_branch) : "Nothing uncommitted", inner)
			return
		}
		for i in v.list_top ..< min(len(rows), v.list_top + fitn + 1) {
			if drawn_n >= CHANGES_ROWS_DRAWN_MAX do break
			row := rows[i]
			slot := drawn_n
			drawn[slot] = i
			drawn_n += 1
			id := clay.ID("chrow", u32(slot))
			if row.head != "" {
				if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW))}, padding = {pu(PAD_ROW), pu(PAD_ROW), row.scope ? pu(SP_1) : 0, 0}, childAlignment = {y = .Center}}}) {
					clay.TextDynamic(clip(row.head, inner - px(2 * PAD_ROW), row.scope ? WEIGHT_BOLD : WEIGHT_REGULAR), txt(row.scope ? th.text_secondary : th.text_muted, row.scope ? WEIGHT_BOLD : WEIGHT_REGULAR))
				}
				continue
			}
			f := r.files[row.file]
			sel := changes_is_selected(v, f)
			bg, em := overlay(id, sel, ui_hover == Hit(Hit_Changes{what = .Row, index = slot}))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				letter := status_letter(f.status)
				lcol := th.text_secondary
				switch f.status {
				case 'A', '?': lcol = ec.diff_added
				case 'D':      lcol = ec.diff_removed
				case 'M', 'R': lcol = ec.diff_modified
				case 'U':      lcol = th.error
				}
				if clay.UI()({layout = {sizing = {clay.SizingFixed(px(12)), clay.SizingFit()}}}) {
					clay.TextDynamic(letter, txt(lcol, WEIGHT_BOLD))
				}
				// +a −d, a staged dot
				plus, minus := "", ""
				if f.binary do plus = "bin"
				else if f.added >= 0 {
					plus = fmt.tprintf("+%d", f.added)
					if f.removed > 0 do minus = fmt.tprintf("−%d", f.removed)
				}
				pw := plus != "" ? text_w(plus, FONT_UI_SMALL) : 0
				mw := minus != "" ? text_w(minus, FONT_UI_SMALL) : 0
				name := filepath.base(f.path)
				dir := strings.trim_suffix(f.path[:len(f.path) - len(name)], "/")
				// children: letter, name, dir, spacer, plus, minus, dot (gaps between)
				parts := 4 + (plus != "" ? 1 : 0) + (minus != "" ? 1 : 0) + (f.staged != .None ? 1 : 0)
				fixed := px(12) + pw + mw + (f.staged != .None ? px(DOT) : 0) + f32(parts - 1) * px(GAP_INLINE)
				room := inner - px(2 * PAD_ROW) - fixed
				ncol := mix(th.text_secondary, th.text, em)
				if room > px(SP_4) {
					shown := clip(name, room)
					clay.TextDynamic(shown, txt(ncol))
					left := room - text_w(shown)
					if dir != "" && left > px(SP_6) do clay.TextDynamic(clip(dir, left, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
				}
				spacer()
				if plus != "" do clay.TextDynamic(plus, txt(f.binary ? th.text_muted : ec.diff_added, FONT_UI_SMALL))
				if minus != "" do clay.TextDynamic(minus, txt(ec.diff_removed, FONT_UI_SMALL))
				if f.staged != .None do dot(f.staged == .All ? th.done : th.waiting)
			}
		}
	}
}

// Clay: the selected file's bar (over the diff, inside ui.odin's centre).
changes_file_bar_layout :: proc(p: ^Pane) {
	v := pane_changes(p)
	if v == nil do return
	th := theme()
	_, f := changes_selected(v)
	avail := centre_width() - list_w() - px(2 * TERM_PAD)
	if clay.UI(clay.ID("ch_file"))(bar(clay.ID("ch_file"), EDITOR_TOOLBAR_H)) {
		nav := []Changes_Tool{.Prev, .Next}
		acts := []Changes_Tool{.Open, .Stage, .Unstage, .Discard}
		nn := fit(nav, avail)
		for t in nav[:nn] do tool(v, t)
		used: f32 = 0
		for t, i in nav[:nn] do used += tool_w(t) + (i > 0 ? px(GAP_BUTTONS) : 0)
		na := fit(acts, avail - used - px(GAP_GROUP))
		aw: f32 = 0
		for t, i in acts[:na] do aw += tool_w(t) + (i > 0 ? px(GAP_BUTTONS) : 0)
		room := avail - used - aw - 2 * px(GAP_GROUP)
		if f != nil && room > px(SP_6) {
			if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_GROUP - GAP_BUTTONS)), clay.SizingFit()}}}) {}
			label := f.path
			if f.old_path != "" do label = fmt.tprintf("%s ← %s", f.path, f.old_path)
			clay.TextDynamic(clip(label, room - px(GAP_GROUP - GAP_BUTTONS)), txt(th.text_secondary))
		}
		spacer()
		for t in acts[:na] do tool(v, t)
	}
}

// Clay: "Show more" under a cut diff.
changes_more_layout :: proc(p: ^Pane) {
	v := pane_changes(p)
	if v == nil || v.diff_lines <= v.shown do return
	th := theme()
	avail := centre_width() - list_w() - px(2 * TERM_PAD)
	if clay.UI(clay.ID("ch_more"))(bar(clay.ID("ch_more"), EDITOR_BAR_H)) {
		label := fmt.tprintf("Showing %d of %d lines", v.shown, v.diff_lines)
		room := avail - tool_w(.More) - px(GAP_INLINE)
		if room > px(SP_6) do clay.TextDynamic(clip(label, room), txt(th.text_muted))
		spacer()
		if avail >= tool_w(.More) do tool(v, .More)
	}
}

// The diff's status line (editor_view.odin's draw_status_line).
changes_status_text :: proc(tab_id: u64) -> string {
	v := changes_view(tab_id)
	if v == nil do return ""
	r, f := changes_selected(v)
	if f == nil do return ""
	if v.diff_loading do return "Reading the diff…"
	if f.scope == .Committed do return fmt.tprintf("Committed on %s, against %s (read-only)", r.branch != "" ? r.branch : "HEAD", r.default_branch)
	switch f.staged {
	case .All:    return "Uncommitted, staged (read-only)"
	case .Partly: return "Uncommitted, partly staged (read-only)"
	case .None:
	}
	return f.status == '?' ? "Untracked (read-only)" : "Uncommitted (read-only)"
}

// A status as a letter (a literal: Clay keeps the text until it draws).
@(private = "file")
status_letter :: proc(s: u8) -> string {
	switch s {
	case 'M': return "M"
	case 'A': return "A"
	case 'D': return "D"
	case 'R': return "R"
	case 'U': return "U"
	case '?': return "?"
	}
	return "·"
}

// ---- hits, tooltips, input ----

changes_hit :: proc() -> Hit {
	if clay.PointerOver(clay.ID("changesbtn")) do return Hit_Changes{what = .Button}
	if active_changes() == nil do return nil
	for t in Changes_Tool do if clay.PointerOver(clay.ID("chtool", u32(t))) do return Hit_Changes{what = .Tool, index = int(t)}
	for slot in 0 ..< drawn_n do if clay.PointerOver(clay.ID("chrow", u32(slot))) do return Hit_Changes{what = .Row, index = slot}
	if clay.PointerOver(clay.ID("ch_field")) do return Hit_Changes{what = .Field}
	if clay.PointerOver(clay.ID("ch_list")) do return Hit_Changes{what = .List}
	return nil
}

changes_tip :: proc(h: Hit_Changes) -> (label, keys: string) {
	switch h.what {
	case .Button:
		r := session_repo(cur())
		n := changes_count(r)
		if n == 0 do return "Changes in this checkout (none)", ""
		return fmt.tprintf("Changes in this checkout: %d %s", n, n == 1 ? "file" : "files"), ""
	case .Field:
		return "Commit message", "Enter commits"
	case .List:
		return "", ""
	case .Row:
		v := active_changes()
		r := v != nil ? changes_repo(v.root) : nil
		rows := changes_rows(r)
		if h.index >= drawn_n || drawn[h.index] >= len(rows) do return "", ""
		row := rows[drawn[h.index]]
		if row.head != "" || r == nil do return "", ""
		f := r.files[row.file]
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, f.path)
		if f.old_path != "" do fmt.sbprintf(&b, " (from %s)", f.old_path)
		fmt.sbprintf(&b, " · %s", change_status_name(f.status))
		switch f.staged {
		case .All:    strings.write_string(&b, ", staged")
		case .Partly: strings.write_string(&b, ", partly staged")
		case .None:
		}
		if f.binary do strings.write_string(&b, " · binary")
		else if f.added >= 0 do fmt.sbprintf(&b, " · +%d −%d", f.added, f.removed)
		if f.credential do strings.write_string(&b, " · credentials: not shown")
		return strings.to_string(b), ""
	case .Tool:
		v := active_changes()
		if v == nil do return "", ""
		t := Changes_Tool(h.index)
		enabled, why := changes_tool_state(v, t)
		tip, keys := "", ""
		switch t {
		case .Refresh: tip = "Read the changes again"
		case .Review:
			tip = "Ask this session's pi to review these changes"
			if s, _, _ := find_tab(v.tab_id); s != nil && s.agent == .Claude do tip = "Ask this session's Claude to review these changes (sent once it is idle and nothing is typed)"
		case .Merge:   tip = fmt.tprintf("%s coming later", strings.trim_suffix(tool_label(.Merge), "…"))
		case .Commit:  tip, keys = "Commit the staged files (your git hooks run)", "Enter"
		case .Prev:    tip, keys = "Previous file", "K"
		case .Next:    tip, keys = "Next file", "J"
		case .Open:    tip = "Open the file at this hunk in an editor tab"
		case .Stage:   tip = "Stage this file (git add)"
		case .Unstage: tip = "Unstage this file"
		case .Discard: tip = "Discard this file's uncommitted changes (asks first)"
		case .More:    tip = fmt.tprintf("Show %d more lines", CHANGES_LINES_STEP)
		}
		if t == .Merge do return tip, ""
		if !enabled && why != "" do tip = fmt.tprintf("%s: %s", tip, why)
		return tip, keys
	}
	return "", ""
}

// A tool's click (and the keys that do the same).
changes_tool_run :: proc(v: ^Changes_View, t: Changes_Tool) {
	if ok, _ := changes_tool_state(v, t); !ok do return
	s, _, _ := find_tab(v.tab_id)
	r, f := changes_selected(v)
	switch t {
	case .Refresh: changes_refresh(r)
	case .Review:
		if cmd, _ := changes_review_command(s, changes_review_prompt(v, r)); cmd != nil do ui_do(cmd)
	case .Merge:
	case .Commit:
		ui_do(Changes_Commit{tab_id = v.tab_id, message = tf_text(&changes_message_field)})
		if state.focus_widget == "changes_message" do ui_do(Set_Focus{""})
	case .Prev:    changes_step(v, -1)
	case .Next:    changes_step(v, 1)
	case .Open:
		if f != nil && s != nil do ui_do(Open_File{path = strings.concatenate({v.root, "/", f.path}, context.temp_allocator), line = changes_line_at_cursor(v), session = s.id})
	case .Stage:   if f != nil do ui_do(Changes_Stage{tab_id = v.tab_id, path = f.path, status = change_status_wire(f.status)})
	case .Unstage: if f != nil do ui_do(Changes_Unstage{tab_id = v.tab_id, path = f.path, status = change_status_wire(f.status)})
	case .Discard: if f != nil do ui_do(Changes_Discard{tab_id = v.tab_id, path = f.path, status = change_status_wire(f.status)})
	case .More:    changes_show_more(v)
	}
	app.redraw = true
}

// What the review button sends, and its label.
changes_review_command :: proc(s: ^Open_Session, text: string) -> (Command, string) {
	if s == nil do return nil, ""
	if s.agent == .Claude {
		if len(s.tabs) == 0 do return nil, ""
		if _, is := s.tabs[0].kind.(Claude_Tab); !is do return nil, ""
		return Claude_Prompt{tab_id = s.tabs[0].id, text = text}, "Ask Claude to review"
	}
	if pt := session_pi_tab(s); pt != nil do return Pi_Prompt{tab_id = pt.id, text = text}, TOOL_LABEL[.Review]
	return nil, ""
}

// The prompt "Ask pi to review" sends to the session's pi.
changes_review_prompt :: proc(v: ^Changes_View, r: ^Changes_Repo) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Review the uncommitted changes in this checkout (%s): git status and git diff HEAD", v.root)
	if r != nil && r.ahead > 0 && r.default_branch != "" {
		fmt.sbprintf(&b, ", and the %d %s on %s that %s not on %s (git diff %s...HEAD)", r.ahead, r.ahead == 1 ? "commit" : "commits", r.branch != "" ? r.branch : "HEAD", r.ahead == 1 ? "is" : "are", r.default_branch, r.default_branch)
	}
	strings.write_string(&b, ". Point out bugs, risks and unfinished work.")
	return strings.to_string(b)
}

// Enter and Esc in the commit message field (main.odin, before the
// generic field handling). True if consumed.
changes_field_key :: proc(e: ^sapp.Event) -> bool {
	if state.focus_widget != "changes_message" || e.type != .KEY_DOWN do return false
	#partial switch e.key_code {
	case .ENTER, .KP_ENTER:
		app.key_taken = true // its CHAR must not reach anything
		if v := active_changes(); v != nil do changes_tool_run(v, .Commit)
		return true
	case .ESCAPE:
		ui_do(Set_Focus{""})
		return true
	}
	return false
}

// Clicks on the "±" button and the tab's bars and list, the list's wheel,
// j/k and ↑/↓ (main.odin, after the focused field's handling). True if consumed.
changes_event :: proc(p: ^Pane, e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .MOUSE_DOWN:
		if palette_is_open() || menu.open do return false
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		h, ok := changes_hit().(Hit_Changes)
		if !ok do return false
		if e.mouse_button != .LEFT do return true
		app.redraw = true
		tip_dismiss()
		v := pane_changes(p)
		switch h.what {
		case .Button:
			if cs := cur(); cs != nil do ui_do(Changes_Open{session = cs.id})
		case .Tool:
			if v != nil do changes_tool_run(v, Changes_Tool(h.index))
		case .Row:
			if v == nil || h.index >= drawn_n do return true
			r := changes_repo(v.root)
			rows := changes_rows(r)
			if drawn[h.index] >= len(rows) do return true
			row := rows[drawn[h.index]]
			if row.head == "" do changes_select(v, r.files[row.file].path, r.files[row.file].scope, r.files[row.file].status)
		case .Field:
			if state.focus_widget != "changes_message" do ui_do(Set_Focus{"changes_message"})
		case .List:
		}
		return true
	case .MOUSE_SCROLL:
		v := pane_changes(p)
		if v == nil || !inside(clay.ID("ch_list"), e.mouse_x, e.mouse_y) do return false
		step := int(-e.scroll_y)
		if step == 0 do step = e.scroll_y < 0 ? 1 : (e.scroll_y > 0 ? -1 : 0)
		v.list_top = max(v.list_top + step, 0) // clamped at the next layout
		app.redraw = true
		return true
	case .KEY_DOWN, .CHAR:
		v := pane_changes(p)
		if v == nil || state.focus_widget != "" || palette_is_open() || menu.open do return false
		if e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT) != 0 do return false
		if e.type == .CHAR do return e.char_code == 'j' || e.char_code == 'k' // taken with their keys
		#partial switch e.key_code {
		case .J, .DOWN: changes_step(v, 1)
		case .K, .UP:   changes_step(v, -1)
		case:           return false
		}
		app.redraw = true
		return true
	}
	return false
}
