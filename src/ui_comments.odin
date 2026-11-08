package main

// Pending comments on screen (comments.odin has the model; docs/BROWSER.md §3.6). The new-comment
// bar: a click on an app tab's Inspect box opens "Comment on box “coin”: [field] Cancel Add" while
// that tab shows (Enter adds, Esc cancels); a browser tab's pick (browser_annotate.odin) opens
// "Comment on button "Save": …" the same way. The strip at
// the top of the centre while the session on screen has comments and its pi tab (or a browser or
// app tab of it) shows: "2 comments will go with your next message · View · Send now · Clear", or
// why they wait (Send now is then disabled). View opens the list: each comment with Edit and
// Delete; Edit turns its row into a field with Save and Cancel (Enter, Esc). And the close prompt:
// a tab or session closed with comments not sent yet: Send and close (a tab) or Send now (a
// session: closing it stops its pi), Drop and close, Cancel. Every action is a button.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"
import stbi "vendor:stb/image"

Comments_Part :: enum u8 {
	View,
	Send,
	Clear,
	Edit, // index: the row
	Delete,
	Save,
	Cancel,
	Field,
	Ask_Send,
	Ask_Drop,
	Ask_Cancel,
	New_Add, // the new-comment bar
	New_Cancel,
	New_Field,
}

Hit_Comments :: struct {
	part:  Comments_Part,
	index: int,
}

@(private = "file")
IDS := [Comments_Part]string {
	.View       = "cm_view",
	.Send       = "cm_send",
	.Clear      = "cm_clear",
	.Edit       = "cm_edit",
	.Delete     = "cm_delete",
	.Save       = "cm_save",
	.Cancel     = "cm_cancel",
	.Field      = "cm_edit_box",
	.Ask_Send   = "cm_ask_send",
	.Ask_Drop   = "cm_ask_drop",
	.Ask_Cancel = "cm_ask_cancel",
	.New_Add    = "cm_new_add",
	.New_Cancel = "cm_new_cancel",
	.New_Field  = "cm_new_box",
}

// UI state: the list is open; the comment being edited (its text in comment_edit_field).
comments_ui: struct {
	open:    bool,
	edit_id: u64,
	draft:   Comment_Draft, // a comment being written (tab_id 0 = none)
}
comment_edit_field: Text_Field
comment_new_field: Text_Field

// What a new comment is about until the user adds it: an app tab's box (copied: the app may send
// new boxes meanwhile), or a browser tab's pick.
Comment_Draft :: struct {
	tab_id:        u64,
	box_id, label: string, // owned
	rect:          App_Rect,
	pick:          ^Annot_Pick, // owned: a browser tab's element or area (nil: an app box)
	crop:          string, // owned: the crop file taken at the click ("" none); removed on Cancel
}

// A click on an Inspect box (app_tab.odin, with its crop taken then): the new-comment bar for it,
// with the keyboard. The draft owns crop from here.
comments_draft_box :: proc(tab_id: u64, box: App_Box, crop: string) {
	comments_draft_end()
	comments_ui.draft = {tab_id = tab_id, box_id = strings.clone(box.id), label = strings.clone(box.label), rect = box.rect, crop = crop}
	tf_set(&comment_new_field, "")
	ui_do(Set_Focus{"comment_new"})
	app.redraw = true
}

// A pick in a browser tab's comment mode (browser_annotate.odin, its crop taken then): the
// new-comment bar for it, with the keyboard. The draft owns pick and crop from here.
comments_draft_pick :: proc(tab_id: u64, pick: ^Annot_Pick, crop: string) {
	comments_draft_end()
	comments_ui.draft = {tab_id = tab_id, pick = pick, crop = crop}
	tf_set(&comment_new_field, "")
	ui_do(Set_Focus{"comment_new"})
	app.redraw = true
}

// A marker's badge was clicked: the list opens with its comment in the edit field.
comments_edit_open :: proc(comment_id: u64) {
	_, pc, _ := comment_find(comment_id)
	if pc == nil do return
	comments_ui.open = true
	comments_ui.edit_id = comment_id
	tf_set(&comment_edit_field, pc.text)
	ui_do(Set_Focus{"comment_edit"})
	app.redraw = true
}

comments_draft_end :: proc() {
	d := &comments_ui.draft
	delete(d.box_id)
	delete(d.label)
	annot_pick_free(d.pick)
	if d.crop != "" do os.remove(d.crop) // not added: nothing else has it
	delete(d.crop)
	d^ = {}
	if state.focus_widget == "comment_new" do ui_do(Set_Focus{""})
}

@(private = "file")
draft_add :: proc() {
	d := comments_ui.draft
	text := strings.trim_space(tf_text(&comment_new_field))
	if d.tab_id == 0 || text == "" do return
	if d.pick != nil do annot_pick_add(d.tab_id, d.pick, text, d.crop) // the comment has the file now
	else do app_comment_add(d.tab_id, d.box_id, d.label, d.rect, text, d.crop)
	comments_ui.draft.crop = ""
	delete(d.crop)
	comments_draft_end()
}

// The draft's tab is on screen.
@(private = "file")
draft_shown :: proc() -> bool {
	t := active_tab()
	return comments_ui.draft.tab_id != 0 && t != nil && t.id == comments_ui.draft.tab_id
}

COMMENTS_LIST_ROWS :: 8 // rows shown; the rest counted

// The session whose strip shows: the one on screen, while its pi tab or one of its browser or app
// tabs is the active tab. Never another session's comments.
comments_strip_session :: proc() -> ^Open_Session {
	s := cur()
	if s == nil || s.home || len(s.comments) == 0 do return nil
	t := active_tab()
	if t == nil do return nil
	#partial switch _ in t.kind {
	case Pi_Tab, Browser_Tab, App_Tab, Claude_Tab: return s
	}
	return nil
}

@(private = "file")
plural :: proc(n: int) -> string {return n == 1 ? "comment" : "comments"}

// The strip's message and whether Send now may go (and why not).
comments_message :: proc(s: ^Open_Session) -> (msg: string, can_send: bool, why: string) {
	n := len(s.comments)
	can_send, why = comments_can_send(s)
	if s.attach.sending != 0 do return fmt.tprintf("Sending %d %s to %s…", n, plural(n), comments_to_word(s)), false, why
	// Send now goes into the Claude tab on screen; the next message there takes them too
	if comments_claude_target(s) != nil do return fmt.tprintf("%d %s will go with your next message", n, plural(n)), can_send, why
	if ok, wait := comments_ready(s); !ok do return fmt.tprintf("%d %s wait: %s", n, plural(n), wait), can_send, why
	return fmt.tprintf("%d %s will go with your next message", n, plural(n)), can_send, why
}

// The close prompt's tab or session, if it still has something to ask about.
@(private = "file")
ask_target :: proc() -> (s: ^Open_Session, tab: ^Tab, n: int) {
	a := state.comments_ask
	if a.session == 0 do return nil, nil, 0
	s = find_session(a.session)
	if s == nil do return nil, nil, 0
	if a.tab_id != 0 {
		_, tab, _ = find_tab(a.tab_id)
		if tab == nil do return nil, nil, 0
		n = comments_of_tab(s, a.tab_id)
	} else do n = len(s.comments)
	if n == 0 do return nil, nil, 0
	return
}

// The bars at the top of the centre (ui.odin): the close prompt, then the strip and its list.
comments_bars :: proc() {
	if s, tab, n := ask_target(); s != nil do ask_bar(s, tab, n)
	if comments_ui.draft.tab_id != 0 {
		if _, t, _ := find_tab(comments_ui.draft.tab_id); t == nil do comments_draft_end() // its tab closed
		else if draft_shown() do new_bar()
	}
	s := comments_strip_session()
	if s == nil {
		comments_ui.open = false
		return
	}
	strip(s)
	if comments_ui.open do list(s)
}

@(private = "file")
bar_layout :: proc() -> clay.ElementDeclaration {
	th := theme()
	return {
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}
}

// A button; disabled: muted, no hover (its tip says why).
@(private = "file")
strip_button :: proc(part: Comments_Part, label: string, primary: bool, enabled := true, index := 0) {
	id := clay.ID(IDS[part], u32(index))
	hovered := ui_hover == Hit(Hit_Comments{part, index})
	if enabled {
		button(id, label, primary, hovered)
		return
	}
	th := theme()
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(mix(th.bg_elevated, th.text, TINT_BUTTON / 2)),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		clay.TextDynamic(label, txt(th.text_muted))
	}
}

@(private = "file")
labels_w :: proc(labels: []string) -> f32 {
	w: f32
	for l in labels do w += text_w(l, WEIGHT_BOLD) + px(2 * SP_3 + SP_2)
	return w
}

// Who a session's comments go to, in words: its Claude in a Claude-only session (no pi), else pi.
comments_agent_word :: proc(s: ^Open_Session) -> string {
	return s != nil && s.agent == .Claude ? "Claude" : "pi"
}

// Who the strip's comments go to now: the Claude tab on screen (comments_claude_target) or a
// Claude-only session's Claude, else pi.
comments_to_word :: proc(s: ^Open_Session) -> string {
	if s != nil && comments_claude_target(s) != nil do return "Claude"
	return comments_agent_word(s)
}

// The close prompt's line and its send button (a tab's close, or the session's: tab nil).
comments_ask_text :: proc(s: ^Open_Session, tab: ^Tab, n: int) -> (msg, send: string) {
	agent := comments_agent_word(s)
	if tab != nil do return fmt.tprintf("Close %q? %d %s on it %s not sent to %s yet", tab.title, n, plural(n), n == 1 ? "is" : "are", agent), "Send and close"
	return fmt.tprintf("Close this session? %d %s %s not sent to %s yet (closing stops %s)", n, plural(n), n == 1 ? "is" : "are", agent, agent), "Send now"
}

@(private = "file")
ask_bar :: proc(s: ^Open_Session, tab: ^Tab, n: int) {
	th := theme()
	msg, send := comments_ask_text(s, tab, n)
	can, _ := comments_can_send(s, for_tab = tab != nil) // a tab's: pi's path (comments_send_now with tab_id)
	used := px(2 * TERM_PAD + DOT + 2 * SP_2) + labels_w({"Cancel", "Drop and close", send})
	if clay.UI(clay.ID("cm_ask_bar"))(bar_layout()) {
		dot(th.waiting)
		clay.TextDynamic(clip(msg, max(centre_width() - used, px(80))), txt(th.text))
		spacer()
		strip_button(.Ask_Cancel, "Cancel", false)
		strip_button(.Ask_Drop, "Drop and close", false)
		strip_button(.Ask_Send, send, true, can)
	}
}

@(private = "file")
new_bar :: proc() {
	th := theme()
	d := comments_ui.draft
	head := d.pick != nil ? fmt.tprintf("Comment on %s:", annot_pick_head(d.pick)) : fmt.tprintf("Comment on box %q:", d.label != "" ? d.label : d.box_id)
	room := centre_width() - px(2 * TERM_PAD + DOT + 3 * SP_2) - text_w(head) - labels_w({"Cancel", "Add"})
	focused := state.focus_widget == "comment_new"
	if clay.UI(clay.ID("cm_new_bar"))(bar_layout()) {
		dot(th.accent)
		clay.TextDynamic(head, txt(th.text))
		if clay.UI(clay.ID(IDS[.New_Field]))({
			layout = {sizing = {clay.SizingFixed(max(room, px(SP_6 * 3))), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			border = {color = cc(focused ? th.accent : th.border), width = {pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), 0}},
			clip = {horizontal = true, childOffset = {}},
		}) {
			shown, _, _ := tf_display(&comment_new_field, focused ? ime.marked : "")
			if clay.UI(clay.ID("cm_new_text"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
				if shown == "" && !focused do clay.TextDynamic(fmt.tprintf("What should %s know about it?", comments_to_word(comments_strip_session())), txt(th.text_muted))
				else do clay.TextDynamic(shown, txt(th.text))
			}
		}
		spacer()
		strip_button(.New_Cancel, "Cancel", false)
		strip_button(.New_Add, "Add", true, strings.trim_space(tf_text(&comment_new_field)) != "")
	}
}

@(private = "file")
strip :: proc(s: ^Open_Session) {
	th := theme()
	msg, can, _ := comments_message(s)
	ready, _ := comments_ready(s)
	if comments_claude_target(s) != nil do ready = true // Claude's next message takes them
	view := comments_ui.open ? "Hide" : "View"
	used := px(2 * TERM_PAD + DOT + 2 * SP_2) + labels_w({view, "Clear", "Send now"})
	if clay.UI(clay.ID("cm_strip"))(bar_layout()) {
		dot(ready ? th.accent : th.waiting)
		if clay.UI(clay.ID("cm_message"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
			clay.TextDynamic(clip(msg, max(centre_width() - used, px(80))), txt(th.text))
		}
		spacer()
		strip_button(.View, view, false)
		strip_button(.Clear, "Clear", false)
		strip_button(.Send, "Send now", true, can)
	}
}

@(private = "file")
list :: proc(s: ^Open_Session) {
	th := theme()
	if clay.UI(clay.ID("cm_list"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(TERM_PAD + DOT + SP_2), pu(TERM_PAD), pu(SP_1), pu(SP_2)}, childGap = pu(SP_1), layoutDirection = .TopToBottom},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		room := centre_width() - px(2 * TERM_PAD + DOT + SP_2)
		for c, i in s.comments {
			if i == COMMENTS_LIST_ROWS {
				clay.TextDynamic(fmt.tprintf("+%d more", len(s.comments) - i), txt(th.text_muted, FONT_UI_SMALL))
				break
			}
			if clay.UI(clay.ID("cm_row", u32(i)))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BUTTON_H))}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				if comments_ui.edit_id == c.id {
					edit_row(i, room - labels_w({"Cancel", "Save"}))
					strip_button(.Cancel, "Cancel", false, true, i)
					strip_button(.Save, "Save", true, true, i)
				} else {
					line := fmt.tprintf("%d. %s — %s%s", i + 1, c.text, c.what, c.crop != "" ? " · image" : "")
					clay.TextDynamic(clip(strings.trim_space(one_line(line, context.temp_allocator)), max(room - labels_w({"Edit", "Delete"}), px(80))), txt(th.text_secondary))
					spacer()
					strip_button(.Edit, "Edit", false, true, i)
					strip_button(.Delete, "Delete", false, true, i)
				}
			}
		}
	}
}

@(private = "file")
edit_row :: proc(i: int, w: f32) {
	th := theme()
	focused := state.focus_widget == "comment_edit"
	if clay.UI(clay.ID(IDS[.Field]))({
		layout = {sizing = {clay.SizingFixed(max(w, px(SP_6 * 3))), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(focused ? th.accent : th.border), width = {pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), 0}},
		clip = {horizontal = true, childOffset = {}},
	}) {
		shown, _, _ := tf_display(&comment_edit_field, focused ? ime.marked : "")
		if clay.UI(clay.ID("cm_edit_text"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
			clay.TextDynamic(shown, txt(th.text))
		}
	}
	spacer()
}

comments_hit :: proc() -> Hit {
	if draft_shown() && clay.PointerOver(clay.ID("cm_new_bar")) {
		for p in ([]Comments_Part{.New_Add, .New_Cancel}) do if clay.PointerOver(clay.ID(IDS[p], 0)) do return Hit_Comments{p, 0}
		if clay.PointerOver(clay.ID(IDS[.New_Field])) do return Hit_Comments{.New_Field, 0}
		return nil
	}
	if clay.PointerOver(clay.ID("cm_ask_bar")) {
		for p in ([]Comments_Part{.Ask_Send, .Ask_Drop, .Ask_Cancel}) do if clay.PointerOver(clay.ID(IDS[p], 0)) do return Hit_Comments{p, 0}
		return nil
	}
	s := comments_strip_session()
	if s == nil do return nil
	for p in ([]Comments_Part{.View, .Send, .Clear}) do if clay.PointerOver(clay.ID(IDS[p], 0)) do return Hit_Comments{p, 0}
	if !comments_ui.open do return nil
	if clay.PointerOver(clay.ID(IDS[.Field])) do return Hit_Comments{.Field, 0}
	for _, i in s.comments {
		if i == COMMENTS_LIST_ROWS do break
		for p in ([]Comments_Part{.Edit, .Delete, .Save, .Cancel}) do if clay.PointerOver(clay.ID(IDS[p], u32(i))) do return Hit_Comments{p, i}
	}
	return nil
}

comments_tip :: proc(h: Hit_Comments) -> (label, keys: string) {
	switch h.part {
	case .View:   return comments_ui.open ? "Hide the list" : "The comments: edit or delete each", ""
	case .Clear:  return "Remove every comment (nothing is sent)", ""
	case .Send:
		if s := comments_strip_session(); s != nil {
			if ok, why := comments_can_send(s); !ok do return strings.concatenate({"Cannot send now: ", why}, context.temp_allocator), ""
			if comments_claude_target(s) != nil || s.agent == .Claude do return "Send the comments to Claude now, as a message of their own", ""
		}
		return "Send the comments to pi now, as a message of their own", ""
	case .Edit:   return "Change this comment's text", ""
	case .Delete: return "Remove this comment", ""
	case .Save:   return "Save the comment", "Enter"
	case .Cancel: return "Keep the comment as it was", "Esc"
	case .Field:  return "", ""
	case .Ask_Send:
		agent := "pi"
		if s, _, _ := ask_target(); s != nil {
			if ok, why := comments_can_send(s, for_tab = state.comments_ask.tab_id != 0); !ok do return strings.concatenate({"Cannot send now: ", why}, context.temp_allocator), ""
			agent = comments_agent_word(s)
			// a Claude-only session's Send and close: Claude's hook takes all of its comments
			if s.agent == .Claude && state.comments_ask.tab_id != 0 do return "Send the session's comments to Claude now (its next message takes them all), then close the tab", ""
		}
		return state.comments_ask.tab_id != 0 ? fmt.tprintf("Send its comments to %s now, then close the tab", agent) : fmt.tprintf("Send the comments to %s now; the session stays open", agent), ""
	case .Ask_Drop:   return "Remove the comments and close", ""
	case .Ask_Cancel: return "Keep it open, with its comments", ""
	case .New_Add:    return fmt.tprintf("Add the comment: it goes to this session's %s with your next message", comments_to_word(comments_strip_session())), "Enter"
	case .New_Cancel: return "Forget this comment", "Esc"
	case .New_Field:  return "", ""
	}
	return "", ""
}

@(private = "file")
edit_end :: proc() {
	comments_ui.edit_id = 0
	if state.focus_widget == "comment_edit" do ui_do(Set_Focus{""})
}

@(private = "file")
edit_save :: proc() {
	if comments_ui.edit_id != 0 do ui_do(Comment_Edit{comment_id = comments_ui.edit_id, text = tf_text(&comment_edit_field)})
	edit_end()
}

// A click on the strip, the list or the close prompt (main.odin).
comments_click :: proc(h: Hit_Comments) {
	app.redraw = true
	a := state.comments_ask
	switch h.part {
	case .Ask_Send:
		s, _, _ := ask_target()
		if s == nil do return
		if ok, _ := comments_can_send(s, for_tab = a.tab_id != 0); !ok do return // disabled
		if a.tab_id != 0 do ui_do(Close_Tab{tab_id = a.tab_id, comments = .Send})
		else {
			ui_do(Comments_Send_Now{session = a.session})
			ui_do(Comments_Ask_Cancel{})
		}
		return
	case .Ask_Drop:
		if a.tab_id != 0 do ui_do(Close_Tab{tab_id = a.tab_id, comments = .Drop})
		else if a.session != 0 do ui_do(Close_Session{session = a.session, comments = .Drop})
		return
	case .Ask_Cancel:
		ui_do(Comments_Ask_Cancel{})
		return
	case .New_Add:
		draft_add()
		return
	case .New_Cancel:
		comments_draft_end()
		return
	case .New_Field:
		if state.focus_widget != "comment_new" do ui_do(Set_Focus{"comment_new"})
		return
	case .View, .Send, .Clear, .Edit, .Delete, .Save, .Cancel, .Field:
	}
	s := comments_strip_session()
	if s == nil do return
	switch h.part {
	case .View:
		comments_ui.open = !comments_ui.open
		if !comments_ui.open do edit_end()
	case .Send:
		if ok, _ := comments_can_send(s); ok do ui_do(Comments_Send_Now{session = s.id})
	case .Clear:
		edit_end()
		ui_do(Comments_Clear{session = s.id})
	case .Edit:
		if h.index >= len(s.comments) do return
		comments_ui.edit_id = s.comments[h.index].id
		tf_set(&comment_edit_field, s.comments[h.index].text)
		ui_do(Set_Focus{"comment_edit"})
	case .Delete:
		if h.index >= len(s.comments) do return
		if comments_ui.edit_id == s.comments[h.index].id do edit_end()
		ui_do(Comment_Delete{comment_id = s.comments[h.index].id})
	case .Save:   edit_save()
	case .Cancel: edit_end()
	case .Field:  if state.focus_widget != "comment_edit" do ui_do(Set_Focus{"comment_edit"})
	case .Ask_Send, .Ask_Drop, .Ask_Cancel, .New_Add, .New_Cancel, .New_Field:
	}
}

// Enter and Esc in the edit field (main.odin, before the generic field handling). True if consumed.
comments_field_key :: proc(e: ^sapp.Event) -> bool {
	if state.focus_widget == "comment_new" && e.type == .KEY_DOWN {
		#partial switch e.key_code {
		case .ENTER, .KP_ENTER:
			app.key_taken = true
			draft_add()
			return true
		case .ESCAPE:
			comments_draft_end()
			return true
		}
		return false
	}
	if state.focus_widget != "comment_edit" || e.type != .KEY_DOWN do return false
	#partial switch e.key_code {
	case .ENTER, .KP_ENTER:
		app.key_taken = true // its CHAR must not reach anything
		edit_save()
		return true
	case .ESCAPE:
		edit_end()
		return true
	}
	return false
}

// Crops box (logical px of the frame's top-left, margin added) from the slot on screen of a frame
// ring into a new crop file: the frame read app_screenshot uses (dh_frames_read), scaled down to
// COMMENT_CROP_SIDE, PNG by stb. "" = no frame to crop.
@(private = "file")
ring_crop :: proc(tab_id: u64, ring: ^Frame_Ring, content_w, content_h: int, scale: f32, box: [4]int) -> string {
	when ODIN_OS != .Darwin do return ""
	if ring.shown_gen == 0 || content_w <= 0 || content_h <= 0 do return ""
	m := COMMENT_CROP_MARGIN
	x0, y0 := max(int(f32(box[0] - m) * scale), 0), max(int(f32(box[1] - m) * scale), 0)
	x1, y1 := min(int(f32(box[0] + box[2] + m) * scale), content_w), min(int(f32(box[1] + box[3] + m) * scale), content_h)
	w, h := x1 - x0, y1 - y0
	if w <= 0 || h <= 0 do return ""
	px := make([]u8, w * h * 4, context.temp_allocator)
	if window.frames_read == nil || !window.frames_read(tab_id, ring.shown_gen, ring.shown_slot, x0, y0, w, h, px) do return ""
	// down to COMMENT_CROP_SIDE on the long side (nearest pixel); BGRA -> RGBA, opaque
	k := min(1, f32(COMMENT_CROP_SIDE) / f32(max(w, h)))
	dw, dh := max(int(f32(w) * k), 1), max(int(f32(h) * k), 1)
	out := make([]u8, dw * dh * 4, context.temp_allocator)
	for y in 0 ..< dh {
		sy := min(int(f32(y) / k), h - 1)
		for x in 0 ..< dw {
			sx := min(int(f32(x) / k), w - 1)
			s, d := (sy * w + sx) * 4, (y * dw + x) * 4
			out[d], out[d + 1], out[d + 2], out[d + 3] = px[s + 2], px[s + 1], px[s], 255
		}
	}
	png := make([dynamic]u8, 0, len(out) / 4, context.temp_allocator)
	sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = runtime.default_context()
		dst := (^[dynamic]u8)(ctx)
		append(dst, ..([^]u8)(data)[:size])
	}
	if stbi.write_png_to_func(sink, &png, c.int(dw), c.int(dh), 4, raw_data(out), c.int(dw * 4)) == 0 do return ""
	path := comments_crop_path()
	if os.write_entire_file(path, png[:], {.Read_User, .Write_User}) != nil {
		delete(path)
		return ""
	}
	return path
}

// The browser's picker (step 4 of docs/BROWSER.md §6 calls this with the picked element): a
// comment on box (page CSS px in the viewport: x, y, w, h) of the tab's page, cropped from the
// frame on screen. what: the picked element ("button \"Save\" form#settings button.primary") or
// "" for an area; the page's title and address are added.
browser_comment_add :: proc(tab_id: u64, box: [4]int, what, text: string) -> (id: u64, err: string) {
	b := browser_of(tab_id)
	if b == nil do return 0, "no such browser tab"
	crop := ring_crop(tab_id, &b.ring, b.content_w, b.content_h, app.dpi, box)
	r := run_command(Comment_Add{source = .Browser, tab_id = tab_id, what = browser_comment_what(box, what, b.title, b.url), text = text, crop = crop}, {kind = .Internal})
	if !r.ok && crop != "" do os.remove(crop)
	if crop != "" do delete(crop)
	return r.created_id, r.error
}

// The browser's picker (browser_annotate.odin): box (viewport CSS px: x, y, w, h) of the tab's
// page cropped at the pick, from the frame on screen: a new crop file, "" if there is no frame.
browser_box_crop :: proc(tab_id: u64, box: [4]int) -> string {
	b := browser_of(tab_id)
	if b == nil do return ""
	return ring_crop(tab_id, &b.ring, b.content_w, b.content_h, app.dpi, box)
}

// An app tab's Inspect box, cropped at the click (app_tab.odin; before the comment bar opens and
// moves the content) from the frame on screen through app_screenshot's frame read: a new crop
// file, "" if there is no frame. rect: logical tab px, as the app sent it in tab.boxes.
app_box_crop :: proc(tab_id: u64, rect: App_Rect) -> string {
	a := app_of(tab_id)
	if a == nil do return ""
	g := ring_gen(&a.ring, a.ring.shown_gen)
	if g == nil do return ""
	return ring_crop(tab_id, &a.ring, g.w, g.h, g.scale, {int(rect.x), int(rect.y), int(rect.w), int(rect.h)})
}

// Deckhand quits: the comment bar's draft crop goes too (comments_shutdown removes the comments').
comments_draft_shutdown :: proc() {
	if d := &comments_ui.draft; d.crop != "" {
		os.remove(d.crop)
		delete(d.crop)
		d.crop = ""
	}
}
