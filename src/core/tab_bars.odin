package core

// The bars over a tab, as text: what the native window draws over a Claude, Codex or pi tab
// (ui_claude.odin: held messages, the status bar; ui_reload.odin, ui_claude_reload.odin: the
// hot-reload bars) and what a browser shows in its status strip (web_bars_json, the "webbars"
// section: web_view.odin).

import "core:fmt"
import "core:strings"

// A Claude or Codex tab's held texts, in one line: "1 message from Atlas waits: you are typing a
// message · “…”".
claude_held_message :: proc(tab: ^Tab, ct: ^Claude_Tab) -> string {
	n := len(ct.held)
	if n == 0 do return ""
	who := ct.held[0].who
	_, why := claude_ready(tab, ct)
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
	return strings.concatenate({cut_utf8(line, HELD_PREVIEW_MAX), "…"}, context.temp_allocator)
}

// ---- a browser's status strip ----

// One bar: [{tab (0 = every tab of harness), harness ("pi", "claude", "codex"), kind, tone
// ("waiting", "error", "info"), text, actions [{label, command {...}} | {label, copy} |
// {label, settings: section id}]}]. Actions only where a browser may do what the native button
// does: a command a browser may send (claude_held, pi_reload_all, pi_restart_updated,
// pi_reload_later, claude_restart_changed, claude_reload_later), copying text, or its own
// Settings screen; Dismiss and Details are the native window's (no command a browser may send),
// so the strip shows the text without them. Local tabs only: another machine's tab's bars are
// its own core's.
web_bars_json :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	n := 0
	bar :: proc(b: ^strings.Builder, n: ^int, tab: u64, harness, kind, tone, text: string) {
		if n^ > 0 do strings.write_byte(b, ',')
		n^ += 1
		fmt.sbprintf(b, `{{"tab":%d,"harness":"%s","kind":"%s","tone":"%s","text":`, tab, harness, kind, tone)
		json_quote(b, text)
		strings.write_string(b, `,"actions":[`)
	}
	act :: proc(b: ^strings.Builder, first: bool, label, key, raw: string) {
		if !first do strings.write_byte(b, ',')
		strings.write_string(b, `{"label":`)
		json_quote(b, label)
		fmt.sbprintf(b, `,"%s":%s}}`, key, raw)
	}
	quoted :: proc(s: string) -> string {
		q := strings.builder_make(context.temp_allocator)
		json_quote(&q, s)
		return strings.to_string(q)
	}
	for &s in state.open_sessions {
		if s.home || s.machine != 0 do continue
		for &t in s.tabs {
			if t.machine != 0 do continue
			#partial switch &k in t.kind {
			case Claude_Tab:
				h := k.codex ? "codex" : "claude"
				if msg := claude_status_message(&t); msg != "" {
					hooks := claude_hooks_silent(&t)
					bar(&b, &n, t.id, h, "status", hooks ? "error" : "waiting", msg)
					// the native bar's action: Show settings (hooks), Copy update command (an old
					// Claude Code); a Codex tab's bars say what to do in Codex itself
					if !k.codex && hooks do act(&b, true, "Show settings", "settings", `"agents"`)
					else if !k.codex do if cmd := claude_update_command_now(); cmd != "" do act(&b, true, "Copy update command", "copy", quoted(cmd))
					strings.write_string(&b, "]}")
				}
				if len(k.held) > 0 {
					bar(&b, &n, t.id, h, "held", "waiting", claude_held_message(&t, &k))
					act(&b, true, "Drop", "command", fmt.tprintf(`{{"type":"claude_held","tab_id":%d,"op":"drop"}}`, t.id))
					act(&b, false, "Send now", "command", fmt.tprintf(`{{"type":"claude_held","tab_id":%d,"op":"send"}}`, t.id))
					strings.write_string(&b, "]}")
				}
			case Pi_Tab:
				if msg := pi_status_message(&t); msg != "" {
					bar(&b, &n, t.id, "pi", "status", "waiting", msg)
					act(&b, true, "Copy update command", "copy", quoted(PI_UPDATE_COMMAND))
					strings.write_string(&b, "]}")
				}
			}
		}
	}
	// the hot-reload bars (every pi tab's, every Claude tab's): their text and their action, Later
	if restart_bar_shows() {
		msg, can := reload_message(true)
		bar(&b, &n, 0, "pi", "restart", "info", msg)
		act(&b, true, "Later", "command", `{"type":"pi_reload_later","restart":true}`)
		if can do act(&b, false, "Restart", "command", `{"type":"pi_restart_updated"}`)
		strings.write_string(&b, "]}")
	}
	if reload_bar_shows() {
		msg, can := reload_message(false)
		bar(&b, &n, 0, "pi", "reload", "info", msg)
		act(&b, true, "Later", "command", `{"type":"pi_reload_later"}`)
		if can do act(&b, false, "Reload", "command", `{"type":"pi_reload_all","only_changed":true}`)
		strings.write_string(&b, "]}")
	}
	for update in ([2]bool{true, false}) do if claude_bar_shows(update) {
		msg, can := claude_reload_message(update)
		bar(&b, &n, 0, "claude", update ? "claude_update" : "claude_reload", "info", msg)
		act(&b, true, "Later", "command", update ? `{"type":"claude_reload_later","update":true}` : `{"type":"claude_reload_later"}`)
		if can do act(&b, false, "Restart", "command", update ? `{"type":"claude_restart_changed","update":true}` : `{"type":"claude_restart_changed"}`)
		strings.write_string(&b, "]}")
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}
