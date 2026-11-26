package core

// The browser commands' wire layer (design §4: the core owns the command layer and its JSON):
// the tab each targets (socket.odin's event filter), their enums' wire names and URLs without
// user:pass@ (browser_url_public, browser_url_redacted). Their JSON follows their structs' `cmd`
// tags (command_codec.odin).
// The commands themselves are declared beside their code
// (browser_nav.odin, browser_polish.odin, browser_agent.odin, browser_act.odin), which the
// window's tab host runs.

import "core:strings"

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
// scheme://host/…): what State, get_state and the workspace hold. The query and
// fragment stay (they may hold tokens: PERSISTENCE.md; events and the log have
// browser_url_redacted's). Temp-allocated.
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

// For events and logs (the redacted encoding's red=url): a command's address as typed, without
// user:pass@ also when it has no scheme yet ("NAME:PASSWORD@example.com"; a scheme is a :// before
// the first of /?#@, not one in the query); a mail address keeps mailto: and its domain, not whom
// ("mailto:<redacted>@example.com"). Its query keeps its keys, not their values
// ("?code=<redacted>&state=<redacted>": OAuth codes, access tokens, signatures, magic links), and
// the fragment (#access_token=…) is left out. State keeps the address whole (browser_url_public).
// Temp-allocated.
browser_url_redacted :: proc(url: string) -> string {
	return url_query_redacted(url_who_redacted(url))
}

@(private = "file")
url_who_redacted :: proc(url: string) -> string {
	if strings.has_prefix(url, "//") do return strings.concatenate({"//", strings.trim_prefix(browser_url_public(strings.concatenate({"x:", url}, context.temp_allocator)), "x://")}, context.temp_allocator) // scheme-relative: as with one
	if i := strings.index(url, "://"); i >= 0 {
		first := strings.index_any(url, "/?#@")
		if first < 0 || i <= first do return browser_url_public(url)
	}
	if len(url) >= 7 && strings.equal_fold(url[:7], "mailto:") {
		to := url[7:]
		end := len(to)
		if k := strings.index_any(to, "?#"); k >= 0 do end = k
		at := strings.last_index_byte(to[:end], '@')
		return at < 0 ? url : strings.concatenate({url[:7], "<redacted>", to[at:]}, context.temp_allocator)
	}
	end := len(url)
	if k := strings.index_any(url, "/?#"); k >= 0 do end = k
	at := strings.last_index_byte(url[:end], '@')
	return at < 0 ? url : url[at + 1:]
}

// The fragment left out; each query part's value (a part without =: all of it) as <redacted>.
@(private = "file")
url_query_redacted :: proc(url: string) -> string {
	u := url
	if k := strings.index_byte(u, '#'); k >= 0 do u = u[:k]
	q := strings.index_byte(u, '?')
	if q < 0 || q == len(u) - 1 do return u
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, u[:q + 1])
	for part, i in strings.split(u[q + 1:], "&", context.temp_allocator) {
		if i > 0 do strings.write_byte(&b, '&')
		key, eq, val := strings.partition(part, "=")
		if eq == "" {
			if part != "" do strings.write_string(&b, "<redacted>")
		} else {
			strings.write_string(&b, key)
			strings.write_byte(&b, '=')
			if val != "" do strings.write_string(&b, "<redacted>")
		}
	}
	return strings.to_string(b)
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
