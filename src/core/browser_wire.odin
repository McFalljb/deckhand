package core

// The browser commands' wire layer (design §4: the core owns the command layer and its JSON):
// each command's type name, its copy and free for the inbox (inbox.odin), its fields for events
// and the log (json_write.odin), the tab it targets (socket.odin's event filter) and the names
// json_read.odin parses, and URLs without user:pass@ (browser_url_public, browser_url_redacted).
// The commands themselves are declared beside their code
// (browser_nav.odin, browser_polish.odin, browser_agent.odin, browser_act.odin), which the
// window's tab host runs.

import "base:runtime"
import "core:fmt"
import "core:strings"

browser_command_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Browser_Open:     return "browser_open"
	case Browser_Navigate: return "browser_navigate"
	case Browser_Back:     return "browser_back"
	case Browser_Forward:  return "browser_forward"
	case Browser_Reload:   return "browser_reload"
	case Browser_Stop:     return "browser_stop"
	case Browser_Update:   return "browser_update"
	case Browser_Popup_Open: return "browser_popup_open"
	}
	return ""
}

browser_command_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	s :: proc(x: string, a: runtime.Allocator) -> string {return strings.clone(x, a)}
	#partial switch c in cmd {
	case Browser_Open:     return Browser_Open{session = c.session, url = s(c.url, allocator)}
	case Browser_Navigate: return Browser_Navigate{tab_id = c.tab_id, url = s(c.url, allocator)}
	case Browser_Update:
		x := c
		x.url, x.title, x.blocked = s(c.url, allocator), s(c.title, allocator), s(c.blocked, allocator)
		return x
	case Browser_Popup_Open:
		x := c
		x.url = s(c.url, allocator)
		return x
	}
	return cmd
}

browser_command_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	#partial switch c in cmd {
	case Browser_Open:     delete(c.url, allocator)
	case Browser_Navigate: delete(c.url, allocator)
	case Browser_Update:
		delete(c.url, allocator)
		delete(c.title, allocator)
		delete(c.blocked, allocator)
	case Browser_Popup_Open: delete(c.url, allocator)
	}
}

// The tab a browser command targets (socket.odin's event filter).
browser_command_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Browser_Navigate: return c.tab_id
	case Browser_Back:     return c.tab_id
	case Browser_Forward:  return c.tab_id
	case Browser_Reload:   return c.tab_id
	case Browser_Stop:     return c.tab_id
	case Browser_Update:   return c.tab_id
	case Browser_Popup_Open: return c.opener
	}
	return 0
}

// The URL without a user name or password (scheme://NAME:PASSWORD@host/… ->
// scheme://host/…): what State, events and the workspace hold. The query and
// fragment stay (they may hold tokens: PERSISTENCE.md). Temp-allocated.
browser_url_public :: proc(url: string) -> string {
	i := strings.index(url, "://")
	if i < 0 do return url
	start := i + 3
	end := len(url)
	if k := strings.index_any(url[start:], "/?#"); k >= 0 do end = start + k
	at := strings.last_index_byte(url[start:end], '@')
	if at < 0 do return url
	return strings.concatenate({url[:start], url[start + at + 1:]}, context.temp_allocator)
}

// For events and logs: a command's address as typed, without user:pass@ also
// when it has no scheme yet ("NAME:PASSWORD@example.com"). Temp-allocated.
browser_url_redacted :: proc(url: string) -> string {
	if strings.contains(url, "://") do return browser_url_public(url)
	end := len(url)
	if k := strings.index_any(url, "/?#"); k >= 0 do end = k
	at := strings.last_index_byte(url[:end], '@')
	return at < 0 ? url : url[at + 1:]
}

BROWSER_ZOOM_STEP_NAMES := [Browser_Zoom_Step]string {
	.Reset = "reset",
	.In    = "in",
	.Out   = "out",
}

BROWSER_EDIT_OP_NAMES := [Browser_Edit_Op]string {
	.Undo       = "undo",
	.Redo       = "redo",
	.Cut        = "cut",
	.Copy       = "copy",
	.Paste      = "paste",
	.Select_All = "select_all",
}

BROWSER_DOWNLOAD_OP_NAMES := [Browser_Download_Op]string {
	.Open    = "open",
	.Reveal  = "reveal",
	.Cancel  = "cancel",
	.Dismiss = "dismiss",
	.Allow   = "allow",
	.Block   = "block",
}

browser_polish_command_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Browser_Zoom:       return "browser_zoom"
	case Browser_Find:       return "browser_find"
	case Browser_Find_Close: return "browser_find_close"
	case Browser_Dialog:     return "browser_dialog"
	case Browser_Permission: return "browser_permission"
	case Browser_Popup:      return "browser_popup"
	case Browser_Edit:       return "browser_edit"
	case Browser_Devtools:   return "browser_devtools"
	case Browser_External:   return "browser_external"
	case Browser_Download:   return "browser_download"
	}
	return ""
}

browser_polish_command_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	#partial switch c in cmd {
	case Browser_Find:
		x := c
		x.text = strings.clone(c.text, allocator)
		return x
	case Browser_Dialog:
		x := c
		x.text = strings.clone(c.text, allocator)
		return x
	}
	return cmd
}

browser_polish_command_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	#partial switch c in cmd {
	case Browser_Find:   delete(c.text, allocator)
	case Browser_Dialog: delete(c.text, allocator)
	}
}

// The command's fields for events and logs (redact: a prompt's answer becomes its length).
browser_polish_command_write :: proc(w: ^Jw, cmd: Command, redact := false) {
	#partial switch c in cmd {
	case Browser_Zoom:
		pw_u64(w, "tab_id", c.tab_id)
		pw_str(w, "step", BROWSER_ZOOM_STEP_NAMES[c.step])
	case Browser_Find:
		pw_u64(w, "tab_id", c.tab_id)
		pw_str(w, "text", c.text)
		if c.back do pw_bool(w, "back", true)
	case Browser_Find_Close: pw_u64(w, "tab_id", c.tab_id)
	case Browser_Dialog:
		pw_u64(w, "tab_id", c.tab_id)
		pw_bool(w, "ok", c.ok)
		if c.text != "" do pw_str(w, "text", redact ? fmt.tprintf("<redacted %d bytes>", len(c.text)) : c.text)
	case Browser_Permission:
		pw_u64(w, "tab_id", c.tab_id)
		pw_bool(w, "allow", c.allow)
	case Browser_Popup:
		pw_u64(w, "tab_id", c.tab_id)
		pw_bool(w, "open", c.open)
	case Browser_Edit:
		pw_u64(w, "tab_id", c.tab_id)
		pw_str(w, "op", BROWSER_EDIT_OP_NAMES[c.op])
	case Browser_Devtools:
		pw_u64(w, "tab_id", c.tab_id)
		if c.x >= 0 && c.y >= 0 {
			pw_u64(w, "x", u64(c.x))
			pw_u64(w, "y", u64(c.y))
		}
		if c.close do pw_bool(w, "close", true)
	case Browser_External: pw_u64(w, "tab_id", c.tab_id)
	case Browser_Download:
		pw_u64(w, "download_id", c.download_id)
		pw_str(w, "op", BROWSER_DOWNLOAD_OP_NAMES[c.op])
	}
}

@(private = "file")
pw_key :: proc(w: ^Jw, k: string) {
	if !w.first do strings.write_byte(w.b, ',')
	w.first = false
	json_quote(w.b, k)
	strings.write_byte(w.b, ':')
}

@(private = "file")
pw_str :: proc(w: ^Jw, k, v: string) {pw_key(w, k); json_quote(w.b, v)}

@(private = "file")
pw_u64 :: proc(w: ^Jw, k: string, v: u64) {pw_key(w, k); strings.write_u64(w.b, v)}

@(private = "file")
pw_bool :: proc(w: ^Jw, k: string, v: bool) {pw_key(w, k); strings.write_string(w.b, v ? "true" : "false")}

browser_agent_command_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Browser_Tabs:       return "browser_tabs"
	case Browser_Read:       return "browser_read"
	case Browser_Screenshot: return "browser_screenshot"
	case Browser_Page_Wait:       return "browser_wait"
	case Browser_Console:    return "browser_console"
	case Browser_Network:    return "browser_network"
	case Browser_Comments:   return "browser_comments"
	case Browser_Agent_Stop: return "browser_agent_stop"
	}
	return ""
}

browser_agent_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	#partial switch c in cmd {
	case Browser_Read:
		x := c
		x.mode, x.selector = strings.clone(c.mode, allocator), strings.clone(c.selector, allocator)
		return x
	case Browser_Page_Wait:
		x := c
		x.what, x.value = strings.clone(c.what, allocator), strings.clone(c.value, allocator)
		return x
	}
	return cmd
}

browser_agent_free :: proc(cmd: Command, allocator := context.allocator) {
	#partial switch c in cmd {
	case Browser_Read:
		delete(c.mode, allocator)
		delete(c.selector, allocator)
	case Browser_Page_Wait:
		delete(c.what, allocator)
		delete(c.value, allocator)
	}
}

// The command's fields for events and the log: never a waited-for text (it may be what the user
// typed into the page), only its length.
browser_agent_write :: proc(b: ^strings.Builder, cmd: Command, redact: bool) {
	field :: proc(b: ^strings.Builder, k: string) {fmt.sbprintf(b, `,"%s":`, k)}
	#partial switch c in cmd {
	case Browser_Tabs:
		if c.session != 0 do fmt.sbprintf(b, `,"session":%d`, c.session)
	case Browser_Read:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.mode != "" {field(b, "mode"); json_quote(b, c.mode)}
		if c.selector != "" {field(b, "selector"); json_quote(b, c.selector)}
		if c.max != 0 do fmt.sbprintf(b, `,"max":%d`, c.max)
	case Browser_Screenshot:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.has_rect do fmt.sbprintf(b, `,"rect":{{"x":%v,"y":%v,"w":%v,"h":%v}}`, c.rect.x, c.rect.y, c.rect.w, c.rect.h)
	case Browser_Page_Wait:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.what != "" {field(b, "for"); json_quote(b, c.what)}
		if c.value != "" {
			if redact && c.what == "text" do fmt.sbprintf(b, `,"value_bytes":%d`, len(c.value))
			else {field(b, "value"); json_quote(b, c.value)}
		}
		if c.timeout_ms != 0 do fmt.sbprintf(b, `,"timeout_ms":%d`, c.timeout_ms)
	case Browser_Console:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.since != 0 do fmt.sbprintf(b, `,"since":%d`, c.since)
	case Browser_Network:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.since != 0 do fmt.sbprintf(b, `,"since":%d`, c.since)
	case Browser_Comments:
		if c.tab_id != 0 do fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.session != 0 do fmt.sbprintf(b, `,"session":%d`, c.session)
	case Browser_Agent_Stop:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
	}
}

// The tab a command targets (socket.odin's event filter).
browser_agent_command_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Browser_Read:       return c.tab_id
	case Browser_Screenshot: return c.tab_id
	case Browser_Page_Wait:       return c.tab_id
	case Browser_Console:    return c.tab_id
	case Browser_Network:    return c.tab_id
	case Browser_Comments:   return c.tab_id
	case Browser_Agent_Stop: return c.tab_id
	}
	return 0
}

ACT_BUTTON_NAMES := [Act_Button]string {
	.Left   = "left",
	.Right  = "right",
	.Middle = "middle",
}

ACT_MOD_NAMES := [?]string{"alt", "control", "meta", "shift"} // bit 1 << index

browser_act_command_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Browser_Click:           return "browser_click"
	case Browser_Type:            return "browser_type"
	case Browser_Press:           return "browser_press"
	case Browser_Scroll:          return "browser_scroll"
	case Browser_Select:          return "browser_select"
	case Browser_Hover:           return "browser_hover"
	case Browser_Upload:          return "browser_upload"
	case Browser_Upload_Answer:   return "browser_upload_answer"
	case Browser_Agent_Take_Over: return "browser_agent_take_over"
	case Request_Cancel:          return "request_cancel"
	}
	return ""
}

browser_act_command_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Browser_Click:           return c.tab_id
	case Browser_Type:            return c.tab_id
	case Browser_Press:           return c.tab_id
	case Browser_Scroll:          return c.tab_id
	case Browser_Select:          return c.tab_id
	case Browser_Hover:           return c.tab_id
	case Browser_Upload:          return c.tab_id
	case Browser_Upload_Answer:   return c.tab_id
	case Browser_Agent_Take_Over: return c.tab_id
	}
	return 0
}

browser_act_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	#partial switch c in cmd {
	case Browser_Click:
		x := c
		x.target.selector = strings.clone(c.target.selector, allocator)
		return x
	case Browser_Hover:
		x := c
		x.target.selector = strings.clone(c.target.selector, allocator)
		return x
	case Browser_Scroll:
		x := c
		x.target.selector = strings.clone(c.target.selector, allocator)
		return x
	case Browser_Type:
		x := c
		x.selector, x.text = strings.clone(c.selector, allocator), strings.clone(c.text, allocator)
		return x
	case Browser_Press:
		x := c
		x.selector, x.keys = strings.clone(c.selector, allocator), strings.clone(c.keys, allocator)
		return x
	case Browser_Select:
		x := c
		x.selector, x.label, x.value = strings.clone(c.selector, allocator), strings.clone(c.label, allocator), strings.clone(c.value, allocator)
		return x
	case Browser_Upload:
		x := c
		x.selector = strings.clone(c.selector, allocator)
		x.paths = make([]string, len(c.paths), allocator)
		for p, i in c.paths do x.paths[i] = strings.clone(p, allocator)
		return x
	}
	return cmd
}

browser_act_free :: proc(cmd: Command, allocator := context.allocator) {
	#partial switch c in cmd {
	case Browser_Click:  delete(c.target.selector, allocator)
	case Browser_Hover:  delete(c.target.selector, allocator)
	case Browser_Scroll: delete(c.target.selector, allocator)
	case Browser_Type:
		delete(c.selector, allocator)
		delete(c.text, allocator)
	case Browser_Press:
		delete(c.selector, allocator)
		delete(c.keys, allocator)
	case Browser_Select:
		delete(c.selector, allocator)
		delete(c.label, allocator)
		delete(c.value, allocator)
	case Browser_Upload:
		delete(c.selector, allocator)
		for p in c.paths do delete(p, allocator)
		delete(c.paths, allocator)
	}
}

// The command's fields for events and the log: never the typed text (only its size) nor the
// files' paths (only how many).
browser_act_write :: proc(b: ^strings.Builder, cmd: Command, redact: bool) {
	target :: proc(b: ^strings.Builder, tg: Act_Target) {
		if tg.selector != "" {
			strings.write_string(b, `,"selector":`)
			json_quote(b, tg.selector)
		}
		if tg.has_xy do fmt.sbprintf(b, `,"x":%v,"y":%v`, tg.x, tg.y)
	}
	sel :: proc(b: ^strings.Builder, s: string) {
		if s == "" do return
		strings.write_string(b, `,"selector":`)
		json_quote(b, s)
	}
	#partial switch c in cmd {
	case Browser_Click:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		target(b, c.target)
		if c.button != .Left do fmt.sbprintf(b, `,"button":"%s"`, ACT_BUTTON_NAMES[c.button])
		if c.double do strings.write_string(b, `,"double":true`)
		if c.modifiers != 0 do fmt.sbprintf(b, `,"modifiers":%d`, c.modifiers)
	case Browser_Hover:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		target(b, c.target)
	case Browser_Scroll:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		target(b, c.target)
		if c.dx != 0 do fmt.sbprintf(b, `,"dx":%v`, c.dx)
		if c.dy != 0 do fmt.sbprintf(b, `,"dy":%v`, c.dy)
	case Browser_Type:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		sel(b, c.selector)
		if redact do fmt.sbprintf(b, `,"text_bytes":%d`, len(c.text))
		else {
			strings.write_string(b, `,"text":`)
			json_quote(b, c.text)
		}
		if c.clear do strings.write_string(b, `,"clear":true`)
		if c.submit do strings.write_string(b, `,"submit":true`)
	case Browser_Press:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		sel(b, c.selector)
		strings.write_string(b, `,"keys":`)
		json_quote(b, c.keys)
	case Browser_Select:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		sel(b, c.selector)
		if c.has_label {strings.write_string(b, `,"label":`); json_quote(b, c.label)}
		if c.has_value {strings.write_string(b, `,"value":`); json_quote(b, c.value)}
	case Browser_Upload:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		sel(b, c.selector)
		if redact do fmt.sbprintf(b, `,"files":%d`, len(c.paths))
		else {
			strings.write_string(b, `,"paths":[`)
			for p, i in c.paths {
				if i > 0 do strings.write_byte(b, ',')
				json_quote(b, p)
			}
			strings.write_byte(b, ']')
		}
	case Browser_Upload_Answer:
		fmt.sbprintf(b, `,"tab_id":%d,"allow":%v`, c.tab_id, c.allow)
	case Browser_Agent_Take_Over:
		fmt.sbprintf(b, `,"tab_id":%d,"on":%v`, c.tab_id, c.on)
	case Request_Cancel:
		fmt.sbprintf(b, `,"request_id":%d`, c.request_id)
	}
}
