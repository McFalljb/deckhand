package main

// A Claude tab's held texts on screen (claude.odin): while the Claude tab on screen holds text
// Deckhand was asked to send (claude_prompt: Atlas, a script), a bar at the top of the centre says
// whose and why it waits ("1 message from Atlas waits: you are typing a message"), with Drop and
// Send now (the first goes at once, into whatever is typed). Every action is a button; the
// palette has both too.
//
// Below it, the tab's status bar (claude_status.odin): its hooks never reported (Show settings,
// Dismiss), or its Claude Code is older than Deckhand's minimum (Copy update command, Dismiss).
// A pi tab gets the same bar when its pi is older than PI_MIN_VERSION (pi_integration.odin).

import "core:fmt"
import "core:strings"
import "core"
import clay "../build/clay-odin"

Hit_Claude :: distinct int // 0 Send now, 1 Drop; the status bar: 2 its action, 3 Dismiss

@(private = "file")
CLAUDE_BAR_IDS := [2]string{"cl_held_send", "cl_held_drop"}
@(private = "file")
STATUS_IDS := [2]string{"cl_status_go", "cl_status_dismiss"}
@(private = "file")
STATUS_LINES :: 3

// The Claude or pi tab pane p shows while it has a status bar, else nil; its text and whether it is
// the hooks bar (else a version bar).
@(private = "file")
status_tab :: proc(p: ^core.Pane) -> (tab: ^core.Tab, msg: string, hooks: bool) {
	t := core.pane_shown(p)
	if t == nil do return nil, "", false
	if _, is := t.kind.(core.Pi_Tab); is {
		m := core.pi_status_message(t)
		return m != "" ? t : nil, m, false
	}
	if _, is := t.kind.(core.Claude_Tab); !is do return nil, "", false
	m := core.claude_status_message(t)
	if m == "" do return nil, "", false
	return t, m, core.claude_hooks_silent(t)
}

@(private = "file")
status_go_label :: proc(hooks: bool) -> string {return hooks ? "Show settings" : "Copy update command"}

// The version bar's update command for the tab's harness ("" = none to copy: nix, mise).
@(private = "file")
status_update_command :: proc(t: ^core.Tab) -> string {
	if _, is := t.kind.(core.Pi_Tab); is do return core.PI_UPDATE_COMMAND
	return core.claude_update_command_now()
}

// The Claude tab pane p shows while it holds texts, else nil.
@(private = "file")
held_tab :: proc(p: ^core.Pane) -> (^core.Tab, ^core.Claude_Tab) {
	t := core.pane_shown(p)
	if t == nil do return nil, nil
	ct, is := &t.kind.(core.Claude_Tab)
	if !is || len(ct.held) == 0 do return nil, nil
	return t, ct
}

claude_held_message :: proc(tab: ^core.Tab, ct: ^core.Claude_Tab) -> string {
	n := len(ct.held)
	who := ct.held[0].who
	_, why := core.claude_ready(tab, ct)
	if why == "" do why = "sending"
	return fmt.tprintf("%d %s from %s %s: %s · “%s”", n, n == 1 ? "message" : "messages", who, n == 1 ? "waits" : "wait", why, held_preview(ct.held[0].text))
}

// The first held text as one short line: control characters (tabs, escapes, line breaks) become
// spaces, bidi and invisible characters dropped, at most HELD_PREVIEW_MAX bytes on a character boundary.
@(private = "file")
HELD_PREVIEW_MAX :: 48

@(private = "file")
held_preview :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	space := false
	for r in text {
		// bidi controls and invisible characters: dropped (they could disguise the text)
		if (r >= 0x200b && r <= 0x200f) || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == 0xfeff do continue
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029 {
			if !space do strings.write_byte(&b, ' ')
			space = true
			continue
		}
		strings.write_rune(&b, r)
		space = r == ' '
	}
	line := strings.trim_space(strings.to_string(b))
	if len(line) <= HELD_PREVIEW_MAX do return line
	return strings.concatenate({core.cut_utf8(line, HELD_PREVIEW_MAX), "…"}, context.temp_allocator)
}

claude_bars :: proc(p: ^core.Pane) {
	status_bar(p)
	t, ct := held_tab(p)
	if t == nil do return
	th := theme()
	msg := claude_held_message(t, ct)
	used := px(2 * TERM_PAD + DOT + 2 * SP_2) + text_w("Drop", WEIGHT_BOLD) + text_w("Send now", WEIGHT_BOLD) + px(4 * SP_3 + 2 * SP_2)
	if clay.UI(cid("cl_held_bar"))({
		clip = {horizontal = true}, // its pane's width at most (bar_w)
		layout = {sizing = {bar_w(), clay.SizingFixed(px(BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		dot(th.waiting)
		clay.TextDynamic(clip(msg, max(pane_width() - used, px(80))), txt(th.text))
		spacer()
		button(cid(CLAUDE_BAR_IDS[1]), "Drop", false, ui_hover == Hit(Hit_Claude(1)))
		button(cid(CLAUDE_BAR_IDS[0]), "Send now", true, ui_hover == Hit(Hit_Claude(0)))
	}
}

// A Claude tab's status: its hooks never reported, or its Claude Code is old (claude_status.odin).
@(private = "file")
status_bar :: proc(p: ^core.Pane) {
	t, msg, hooks := status_tab(p)
	if t == nil do return
	th := theme()
	go_label := status_go_label(hooks)
	used := px(2 * TERM_PAD + DOT + 2 * SP_2) + text_w(go_label, WEIGHT_BOLD) + text_w("Dismiss") + px(4 * SP_3 + 2 * SP_2)
	text, n := wrap_clip(msg, max(pane_width() - used, px(80)), STATUS_LINES)
	if clay.UI(cid("cl_status_bar"))({
		clip = {horizontal = true}, // its pane's width at most (bar_w)
		layout = {sizing = {bar_w(), clay.SizingFixed(max(px(BAR_H), f32(n) * text_line_height(.UI) + px(2 * SP_2)))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		dot(hooks ? th.error : th.waiting)
		clay.TextDynamic(text, txt(th.text))
		spacer()
		button(cid(STATUS_IDS[1]), "Dismiss", false, ui_hover == Hit(Hit_Claude(3)))
		// no command to copy for nix or mise (claude_update_command): their package manager updates it
		if hooks || status_update_command(t) != "" do button(cid(STATUS_IDS[0]), go_label, true, ui_hover == Hit(Hit_Claude(2)))
	}
}

claude_hit :: proc() -> Hit {
	p := hit_pane() // the bars' hit tests: the pane under the pointer (ui_panes.odin)
	if t, _, _ := status_tab(p); t != nil {
		for id, i in STATUS_IDS do if clay.PointerOver(cid(id)) do return Hit_Claude(2 + i)
	}
	if t, _ := held_tab(p); t == nil do return nil
	for id, i in CLAUDE_BAR_IDS do if clay.PointerOver(cid(id)) do return Hit_Claude(i)
	return nil
}

claude_tip :: proc(h: Hit_Claude) -> (label, keys: string) {
	switch h {
	case 0: return "Send the first waiting message now, into whatever is typed in Claude's prompt", ""
	case 1: return "Drop the waiting messages (nothing is sent)", ""
	case 2:
		t, _, hooks := status_tab(hit_pane())
		if hooks do return "Show Claude Code's settings files (the Settings tab)", ""
		if t != nil do return fmt.tprintf("Copy “%s” to paste into a shell tab", status_update_command(t)), ""
		return "", ""
	}
	return "Hide this bar (the hooks bar until Claude restarts here; the version hint for this version)", ""
}

claude_click :: proc(p: ^core.Pane, h: Hit_Claude) {
	if h >= 2 {
		t, _, hooks := status_tab(p)
		if t == nil do return
		_, pi := t.kind.(core.Pi_Tab)
		switch {
		case h == 3 && pi: core.pi_status_dismiss(t)
		case h == 3: core.claude_status_dismiss(t)
		case hooks:  ui_do(core.Set_Left_Tab{tab = .Settings})
		case:
			cmd := status_update_command(t)
			if cmd == "" do return
			if win_os.set_clipboard != nil do win_os.set_clipboard(cmd)
			toast_show(fmt.tprintf("Copied: %s", cmd))
		}
		return
	}
	t, _ := held_tab(p)
	if t == nil do return
	ui_do(core.Claude_Held_Op{tab_id = t.id, op = h == 0 ? "send" : "drop"})
}
