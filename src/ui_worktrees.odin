package main

// The Files tab's checkout switcher (worktrees.odin has the model): a button
// under the project's name showing which checkout the tree shows ("main
// checkout · main", "worktree · feature"), and its menu: the repository's
// checkouts (main first) with their state, then the local branches without
// a checkout. Picking a checkout shows it in the tree (files_set_root);
// each row's "…" opens its actions (the context menu, ui_sidebar.odin):
// terminal and pi session there, Reveal, copy path or branch, and Clean up
// for a merged, clean worktree (worktree_cleanup asks in the confirmation
// bar). Branches are listed, never checked out here.
//
// Mouse: a click on a checkout picks it, on "…" (or a branch) opens its
// actions; a click outside closes the menu. Keyboard while it is open: ↑/↓
// move, Enter picks (a branch: its actions), → or Space its actions, Esc closes.

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

WT_SWITCH_H :: BUTTON_H // the switcher's button
WT_ROW_H :: 40 // a checkout's row: its branch and state, then where it is
WT_HEAD_H :: 22 // "Worktrees", "Branches"
WT_MENU_W :: 320
WT_MENU_W_MAX :: 460

Wt_Menu :: struct {
	open:     bool,
	selected: int, // keyboard selection (a row of wt_menu_rows), -1 = none
	drawn:    int, // rows laid out last time (the rest did not fit)
	at:       [2]f32, // framebuffer px: under the button
	w:        f32, // the button's width (framebuffer px)
}
wt_menu: Wt_Menu

// A row of the menu: a checkout or a branch (index into the repository's lists).
Wt_Row :: struct {
	checkout: int, // -1 = a branch
	branch:   int,
}

// The rows of the last layout, by position: a checkout's path or a
// branch's name, so a click acts on the row it was drawn for even when a
// scan arrived since.
@(private = "file")
Wt_Key :: struct {
	path, branch: string,
}
@(private = "file")
wt_drawn_arena: virtual.Arena
@(private = "file")
wt_drawn: [dynamic]Wt_Key

// Row i of the last layout, now (ok = false: gone since).
@(private = "file")
wt_drawn_row :: proc(i: int) -> (r: ^Wt_Repo, row: Wt_Row, ok: bool) {
	if i < 0 || i >= len(wt_drawn) do return
	k := wt_drawn[i]
	r, _ = wt_current()
	if r == nil do return
	if k.path != "" {
		for c, j in r.checkouts do if c.path == k.path do return r, {checkout = j, branch = -1}, true
		return
	}
	for b, j in r.branches do if b.name == k.branch && !b.checkout do return r, {checkout = -1, branch = j}, true
	return
}

// A worktree row's context menu (ui_sidebar.odin draws it).
Menu_Worktree :: struct {
	path:   string, // owned; "" = a branch without a checkout
	branch: string, // owned
}

// The repository of the Files tab's project and the folder its tree shows
// (nil: not in git). counts: see wt_repo_for.
wt_current :: proc(counts := true) -> (r: ^Wt_Repo, root: string) {
	base := files_base()
	if base == "" do return nil, ""
	return wt_repo_for(base, counts), files_root_for(base)
}

// The menu's rows: checkouts, then branches without one.
wt_menu_rows :: proc(r: ^Wt_Repo) -> []Wt_Row {
	out := make([dynamic]Wt_Row, context.temp_allocator)
	if r == nil do return nil
	for _, i in r.checkouts do append(&out, Wt_Row{checkout = i, branch = -1})
	for b, i in r.branches do if !b.checkout do append(&out, Wt_Row{checkout = -1, branch = i})
	return out[:]
}

// A piece of state shown after a name: its text and colour.
Wt_Badge :: struct {
	text: string,
	col:  Rgba,
}

// A checkout's state: ahead/behind, changed files, merged, gone, locked.
wt_checkout_badges :: proc(c: Wt_Checkout) -> []Wt_Badge {
	th := theme()
	out := make([dynamic]Wt_Badge, context.temp_allocator)
	switch wt_cleanup_phase(c.path) {
	case "checking": append(&out, Wt_Badge{"Checking…", th.text_muted})
	case "removing": append(&out, Wt_Badge{"Removing…", th.text_muted})
	}
	if e := wt_cleanup_error(c.path); e != "" do append(&out, Wt_Badge{fmt.tprintf("⚠ %s", e), th.error})
	if c.missing || c.prunable do append(&out, Wt_Badge{c.missing ? "⚠ missing" : "⚠ prunable", th.error})
	if c.ahead > 0 do append(&out, Wt_Badge{fmt.tprintf("↑%d", c.ahead), th.text_secondary})
	if c.behind > 0 do append(&out, Wt_Badge{fmt.tprintf("↓%d", c.behind), th.text_secondary})
	if c.dirty > 0 do append(&out, Wt_Badge{fmt.tprintf("● %d", c.dirty), th.waiting})
	if c.merged do append(&out, Wt_Badge{"✓ merged", th.done})
	if c.locked do append(&out, Wt_Badge{"locked", th.text_muted})
	return out[:]
}

// A branch's state against the default branch, and its last commit's age.
wt_branch_badges :: proc(b: Wt_Branch) -> []Wt_Badge {
	th := theme()
	out := make([dynamic]Wt_Badge, context.temp_allocator)
	if b.ahead > 0 do append(&out, Wt_Badge{fmt.tprintf("↑%d", b.ahead), th.text_secondary})
	if b.behind > 0 do append(&out, Wt_Badge{fmt.tprintf("↓%d", b.behind), th.text_secondary})
	if b.merged do append(&out, Wt_Badge{"✓ merged", th.done})
	if b.date > 0 do append(&out, Wt_Badge{ago(time.unix(b.date, 0)), th.text_muted})
	return out[:]
}

@(private = "file")
badges_w :: proc(bs: []Wt_Badge) -> f32 {
	w: f32 = 0
	for b in bs do w += text_w(b.text, FONT_UI_SMALL) + px(SP_2)
	return w
}

@(private = "file")
badges :: proc(bs: []Wt_Badge) {
	for b, i in bs {
		if i > 0 do if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_2)), clay.SizingFit()}}}) {}
		clay.TextDynamic(b.text, txt(b.col, FONT_UI_SMALL))
	}
}

// A path for a row: ~ for the home folder, the middle cut when long.
wt_short_path :: proc(p: string, room: f32) -> string {
	d := fs_display(p)
	if text_w(d, FONT_UI_SMALL) <= room do return d
	// keep the last folder whole: "…/parent/name"
	i := strings.last_index_byte(d, '/')
	if i > 0 {
		if j := strings.last_index_byte(d[:i], '/'); j > 0 do return clip(strings.concatenate({"…", d[j:]}, context.temp_allocator), room, FONT_UI_SMALL)
	}
	return clip(d, room, FONT_UI_SMALL)
}

// The switcher's label: "main checkout · main", "worktree · feature".
wt_switch_label :: proc(r: ^Wt_Repo, root: string) -> string {
	if c := wt_checkout(r, root); c != nil do return fmt.tprintf("%s · %s", wt_kind(c^), wt_branch_label(c^))
	return wt_where(root).linked ? "worktree" : "main checkout"
}

// ---- layout ----

// The button under the Files header (only in a git repository).
wt_switcher :: proc(row_w: f32) {
	r, root := wt_current(counts = wt_menu.open)
	if r == nil {
		wt_menu.open = false
		return
	}
	th := theme()
	id := clay.ID("wt_switch")
	hovered := ui_hover == Hit(Hit_Files{what = .Switcher})
	bg, em := overlay(id, wt_menu.open, hovered)
	label := wt_switch_label(r, root)
	room := row_w - px(2 * PAD_ROW + ICON_SIZE_SM + 2 * GAP_INLINE + ICON_SIZE_SM)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(WT_SWITCH_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
	}) {
		icon(.Branch, mix(th.text_muted, th.text_secondary, em), ICON_SIZE_SM)
		clay.TextDynamic(clip(label, room), txt(mix(th.text_secondary, th.text, em)))
		spacer()
		icon(.Chevron_Down, th.text_muted, ICON_SIZE_SM)
	}
	if d := clay.GetElementData(id); d.found {
		b := d.boundingBox
		wt_menu.at = {b.x, b.y + b.height + px(SP_1)}
		wt_menu.w = b.width
	}
}

// The open menu, floating under the switcher.
wt_menu_layout :: proc(w, h: f32) {
	if !wt_menu.open do return
	if !files_shown() {
		wt_menu_close()
		return
	}
	r, root := wt_current()
	if r == nil {
		wt_menu_close()
		return
	}
	th := theme()
	rows := wt_menu_rows(r)
	box_w := clamp(wt_menu.w, px(WT_MENU_W), px(WT_MENU_W_MAX))
	box_w = min(box_w, w - px(2 * SP_2))
	x := clamp(wt_menu.at.x, 0, max(w - box_w, 0))
	y := wt_menu.at.y
	inner := box_w - px(2 * PAD_OVERLAY + 2 * PAD_ROW)
	// rows that fit above the window's bottom edge
	avail := h - y - px(SP_3 + 2 * PAD_OVERLAY)
	used := px(WT_HEAD_H)
	n := 0
	for row, i in rows {
		need := row.checkout >= 0 ? px(WT_ROW_H) : px(MENU_ROW_H)
		if row.checkout < 0 && (i == 0 || rows[i - 1].checkout >= 0) do need += px(MENU_SEP_H + WT_HEAD_H)
		if used + need > avail - px(MENU_ROW_H) && i < len(rows) - 1 do break // room for "N more"
		used += need
		n += 1
	}
	wt_menu.drawn = n
	if wt_menu.selected >= n do wt_menu.selected = n - 1
	virtual.arena_destroy(&wt_drawn_arena)
	_ = virtual.arena_init_growing(&wt_drawn_arena)
	da := virtual.arena_allocator(&wt_drawn_arena)
	wt_drawn = make([dynamic]Wt_Key, da)
	for row in rows[:n] {
		if row.checkout >= 0 do append(&wt_drawn, Wt_Key{path = strings.clone(r.checkouts[row.checkout].path, da)})
		else do append(&wt_drawn, Wt_Key{branch = strings.clone(r.branches[row.branch].name, da)})
	}
	if clay.UI(clay.ID("wt_menu"))({
		layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(PAD_OVERLAY))},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 8},
	}) {
		overlay_shadow("wt_menu_shadow", 8)
		wt_heading("wthead", 0, r.loaded ? "Worktrees" : "Worktrees (reading git…)", inner)
		for row, i in rows[:n] {
			if row.checkout < 0 && (i == 0 || rows[i - 1].checkout >= 0) {
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_SEP_H))}, childAlignment = {y = .Center}}}) {
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BORDER_W))}}, backgroundColor = cc(th.border)}) {}
				}
				wt_heading("wthead", 1, fmt.tprintf("Branches without a worktree · vs %s", r.default_branch != "" ? r.default_branch : "?"), inner)
			}
			if row.checkout >= 0 do wt_checkout_row(r, r.checkouts[row.checkout], i, root, inner)
			else do wt_branch_row(r.branches[row.branch], i, inner)
		}
		if n < len(rows) {
			if clay.UI(clay.ID("wtnote"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_ROW_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childAlignment = {y = .Center}}}) {
				clay.TextDynamic(clip(fmt.tprintf("%d more (list_worktrees has them all)", len(rows) - n), inner, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
			}
		}
		if r.err != "" {
			if clay.UI(clay.ID("wtnote", 1))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_ROW_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childAlignment = {y = .Center}}}) {
				clay.TextDynamic(clip(r.err, inner, FONT_UI_SMALL), txt(th.error, FONT_UI_SMALL))
			}
		}
	}
}

@(private = "file")
wt_heading :: proc(name: string, i: u32, text: string, inner: f32) {
	th := theme()
	if clay.UI(clay.ID(name, i))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(WT_HEAD_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childAlignment = {y = .Center}}}) {
		clay.TextDynamic(clip(text, inner, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
	}
}

// The "…" of row i, shown while the row is hovered or selected.
@(private = "file")
wt_more_button :: proc(i: int, shown: bool) {
	th := theme()
	mid := clay.ID("wtmore", u32(i))
	more_hover := ui_hover == Hit(Hit_Files{what = .Wt_More, index = i})
	mbg, _ := overlay(mid, false, more_hover)
	if clay.UI(mid)({
		layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON - SP_1)), clay.SizingFixed(px(ROW_BUTTON - SP_1))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = shown ? mbg : {},
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		icon(.More, shown ? (more_hover ? th.text : th.text_muted) : {}, ICON_SIZE_SM)
	}
}

@(private = "file")
wt_checkout_row :: proc(r: ^Wt_Repo, c: Wt_Checkout, i: int, root: string, inner: f32) {
	th := theme()
	id := clay.ID("wtrow", u32(i))
	hovered := ui_hover == Hit(Hit_Files{what = .Wt_Row, index = i}) || ui_hover == Hit(Hit_Files{what = .Wt_More, index = i})
	selected := i == wt_menu.selected
	bg, em := overlay(id, selected, hovered)
	current := c.path == root
	bs := wt_checkout_badges(c)
	text_room := inner - px(ICON_SIZE_SM + GAP_INLINE + ROW_BUTTON - SP_1 + GAP_INLINE)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(WT_ROW_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		if current do icon(.Check, th.accent, ICON_SIZE_SM)
		else do icon(.None, {}, ICON_SIZE_SM)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = pu(2)}}) {
			// the branch, then the state
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Center}}}) {
				bw := min(badges_w(bs), text_room * 0.6)
				weight: u16 = current ? WEIGHT_BOLD : WEIGHT_REGULAR
				col := c.missing ? th.text_muted : mix(th.text_secondary, th.text, em)
				clay.TextDynamic(clip(wt_branch_label(c), text_room - bw - px(SP_2), weight), txt(col, weight))
				spacer()
				if badges_w(bs) <= text_room * 0.6 do badges(bs)
				else if len(bs) > 0 do clay.TextDynamic(clip(bs[0].text, bw, FONT_UI_SMALL), txt(bs[0].col, FONT_UI_SMALL)) // the first only
			}
			// where it is
			kind := wt_kind(c)
			kw := text_w(kind, FONT_UI_SMALL)
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				clay.TextDynamic(kind, txt(th.text_muted, FONT_UI_SMALL))
				clay.TextDynamic(wt_short_path(c.path, text_room - kw - px(SP_2)), txt(th.text_muted, FONT_UI_SMALL))
			}
		}
		wt_more_button(i, hovered || selected)
	}
}

@(private = "file")
wt_branch_row :: proc(b: Wt_Branch, i: int, inner: f32) {
	th := theme()
	id := clay.ID("wtrow", u32(i))
	hovered := ui_hover == Hit(Hit_Files{what = .Wt_Row, index = i}) || ui_hover == Hit(Hit_Files{what = .Wt_More, index = i})
	selected := i == wt_menu.selected
	bg, em := overlay(id, selected, hovered)
	bs := wt_branch_badges(b)
	text_room := inner - px(ICON_SIZE_SM + GAP_INLINE + ROW_BUTTON - SP_1 + GAP_INLINE)
	bw := min(badges_w(bs), text_room * 0.6)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_ROW_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		icon(.Branch, th.text_muted, ICON_SIZE_SM)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childAlignment = {y = .Center}}}) {
			clay.TextDynamic(clip(b.name, text_room - bw - px(SP_2)), txt(mix(th.text_secondary, th.text, em)))
			spacer()
			if badges_w(bs) <= text_room * 0.6 do badges(bs)
			else if len(bs) > 0 do clay.TextDynamic(clip(bs[0].text, bw, FONT_UI_SMALL), txt(bs[0].col, FONT_UI_SMALL))
		}
		wt_more_button(i, hovered || selected)
	}
}

// ---- input ----

wt_menu_toggle :: proc() {
	if wt_menu.open {
		wt_menu_close()
		return
	}
	menu_close()
	wt_menu.open = true
	wt_menu.selected = -1
	if r, root := wt_current(); r != nil {
		for row, i in wt_menu_rows(r) do if row.checkout >= 0 && r.checkouts[row.checkout].path == root do wt_menu.selected = i
	}
	app.redraw = true
}

wt_menu_close :: proc() {
	if !wt_menu.open do return
	wt_menu.open = false
	app.redraw = true
}

// What is under the pointer while the menu is open (it covers everything).
wt_menu_hit :: proc() -> Hit {
	for i in 0 ..< wt_menu.drawn {
		if clay.PointerOver(clay.ID("wtmore", u32(i))) do return Hit_Files{what = .Wt_More, index = i}
		if clay.PointerOver(clay.ID("wtrow", u32(i))) do return Hit_Files{what = .Wt_Row, index = i}
	}
	if clay.PointerOver(clay.ID("wt_switch")) do return Hit_Files{what = .Switcher}
	if clay.PointerOver(clay.ID("wt_menu")) do return Hit_Files{what = .Wt_Box}
	return nil
}

// Input while the menu is open: everything is consumed.
wt_menu_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .KEY_DOWN:
		app.redraw = true
		#partial switch e.key_code {
		case .ESCAPE: wt_menu_close()
		case .UP:     wt_menu_step(-1)
		case .DOWN, .TAB: wt_menu_step(1)
		case .ENTER, .KP_ENTER: if wt_menu.selected >= 0 do wt_menu_pick(wt_menu.selected)
		case .RIGHT, .SPACE: if wt_menu.selected >= 0 do wt_menu_actions(wt_menu.selected, {})
		}
		return true
	case .MOUSE_MOVE:
		app.pointer = {e.mouse_x, e.mouse_y} // the tooltip shows here
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		set_hover(wt_menu_hit(), false)
		return true
	case .MOUSE_DOWN:
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		h, ok := wt_menu_hit().(Hit_Files)
		if !ok {
			wt_menu_close() // a click outside only closes it
			return true
		}
		#partial switch h.what {
		case .Switcher: wt_menu_close()
		case .Wt_Row:
			if e.mouse_button == .RIGHT do wt_menu_actions(h.index, {e.mouse_x, e.mouse_y})
			else do wt_menu_pick(h.index)
		case .Wt_More:
			if d := clay.GetElementData(clay.ID("wtmore", u32(h.index))); d.found {
				b := d.boundingBox
				wt_menu_actions(h.index, {b.x, b.y + b.height})
			}
		}
		return true
	case .KEY_UP, .CHAR, .CLIPBOARD_PASTED, .MOUSE_SCROLL, .MOUSE_UP:
		return true
	}
	return false
}

@(private = "file")
wt_menu_step :: proc(d: int) {
	if wt_menu.drawn <= 0 do return
	wt_menu.selected = (wt_menu.selected + d + wt_menu.drawn) %% wt_menu.drawn
}

// A row picked: a checkout shows in the tree; a branch opens its actions.
@(private = "file")
wt_menu_pick :: proc(i: int) {
	r, row, ok := wt_drawn_row(i)
	if !ok do return
	if row.checkout < 0 {
		wt_menu_actions(i, {})
		return
	}
	c := r.checkouts[row.checkout]
	if c.missing || c.bare do return
	ui_do(Files_Set_Root{path = c.path})
	wt_menu_close()
}

// Row i's actions (the context menu) at `at` (framebuffer px; {} = beside the row).
@(private = "file")
wt_menu_actions :: proc(i: int, at: [2]f32) {
	r, row, ok := wt_drawn_row(i)
	if !ok do return
	pos := at
	if pos == {} {
		if d := clay.GetElementData(clay.ID("wtrow", u32(i))); d.found {
			b := d.boundingBox
			pos = {b.x + b.width - px(MENU_W), b.y + b.height}
		}
	}
	wt_menu_close()
	if row.checkout >= 0 {
		c := r.checkouts[row.checkout]
		menu_open(Menu_Worktree{path = c.path, branch = c.branch}, pos)
	} else {
		menu_open(Menu_Worktree{branch = r.branches[row.branch].name}, pos)
	}
}

// A worktree row's actions: open a terminal or a pi session there, Reveal,
// copy its path or branch; Clean up for a merged, clean worktree.
wt_menu_items :: proc(t: Menu_Worktree, items: ^[dynamic]Menu_Item) {
	sep :: proc(items: ^[dynamic]Menu_Item) {append(items, Menu_Item{sep = true})}
	r, _ := wt_current()
	c := wt_checkout(r, t.path)
	if t.path != "" && c != nil && !c.missing && !c.bare {
		if cs := cur(); cs != nil && !cs.home do append(items, Menu_Item{label = "Open terminal here", cmd = New_Shell_Tab{session = cs.id, cwd = t.path}})
		if p := files_project(); p != nil do append(items, Menu_Item{label = "New pi session here", cmd = Worktree_Session{project_id = p.id, path = t.path}})
		if cs := cur(); cs != nil && !cs.home do append(items, Menu_Item{label = "Show changes", cmd = Changes_Open{session = cs.id, path = t.path}})
		append(items, Menu_Item{label = "Reveal in Finder", cmd = Reveal_In_Finder{path = t.path}})
		sep(items)
	}
	if t.path != "" do append(items, Menu_Item{label = "Copy path", copy = t.path})
	if t.branch != "" do append(items, Menu_Item{label = "Copy branch name", copy = t.branch})
	if c != nil && wt_cleanable(r, c^) {
		sep(items)
		append(items, Menu_Item{label = "Clean up…", cmd = Worktree_Cleanup{path = t.path}})
	}
}

// The project of the Files tab: the session on screen's, else the selected one.
files_project :: proc() -> ^Project {
	if cs := cur(); cs != nil && !cs.home do return find_project(cs.project_id)
	return find_project(state.selected_project)
}

// Tooltips of the switcher and its rows.
wt_tip :: proc(h: Hit_Files) -> (label, keys: string) {
	#partial switch h.what {
	case .Switcher: return "Worktrees and branches of this repository", ""
	case .Wt_More:  return "More actions", ""
	case .Wt_Row:
		r, row, ok := wt_drawn_row(h.index)
		if !ok do break
		if row.checkout < 0 {
			b := r.branches[row.branch]
			if b.subject != "" do return fmt.tprintf("%s: %s", b.name, b.subject), ""
			return b.name, ""
		}
		c := r.checkouts[row.checkout]
		if c.missing do return fmt.tprintf("%s is gone (git worktree prune drops it)", fs_display(c.path)), ""
		vs := c.upstream != "" && !c.gone ? c.upstream : r.default_branch
		if c.main && c.upstream == "" do return fs_display(c.path), ""
		return fmt.tprintf("%s · ahead/behind %s", fs_display(c.path), vs), ""
	}
	return "", ""
}
