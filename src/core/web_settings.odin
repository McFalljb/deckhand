package core

// A browser's Settings page (#148): the settings registry (settings_registry.odin) as data, sent
// only to a web link, and only while its page shows (web_settings). The page draws the window's
// sections, cards and rows from it (web/src/app/Settings.tsx); each control sends the setting's
// own command, which caller_may decides as for any browser's command. Nothing here adds authority:
// `web` says whether a browser may send the setting's command (web_may_run, the gate itself), and
// the page shows the rest with "Change this at the Mac".
//
//   webset  {sections [{id, name, note, empty}], settings [{id, section, card, label, hint,
//           keywords, kind, choices [{name, arg}], value, web, here, applies, button, show,
//           items [{label, detail, button, acts, arg, codex}]}]}
//
// value: a switch's bool, a choice's arg, the stepper's points (0 = the look's), a button's live
// detail; the grid's [{group, bell, macos, sound}]. items: a list's or a status's rows
// (settings_file_rows), with the actions a browser may take on each (acts: connect, rename,
// remove, default, add, scan, change, reset).
//
// Built on the main thread when the page opens and when a section it reads changed (a flush); never
// on a timer, so a list changed on disk alone (a file, a folder) shows when the page opens again.
// Sent only to the link that opened it (window_link_serial): a takeover does not inherit it.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:strings"

WEB_SETTINGS_SECTION :: "webset"

// The settings a browser cannot use even though their command is not this Mac's user's only:
// they open the window's own sheets (the setup sheet, the shortcuts list).
WEB_SETTINGS_AT_MAC := [?]string{"pi_status", "claude_status", "codex_status", "setup", "shortcuts"}

// The sections a change of which may change the page.
@(private = "file")
WEB_SETTINGS_INPUTS := [?]string{"settings", "machines", "live", "reload", "claude", "jobs"}

// The page's view state (web_settings): open or not.
Web_Settings :: struct {
	open: bool,
}

@(private = "file")
web_set: struct {
	link:   u64, // the link (window_link_serial) whose page shows; 0: none
	json:   string, // heap: the last build
	key:    u64, // the inputs it was built from
	builds: int, // how many builds (tests)
}

web_settings_apply :: proc(c: Web_Settings, caller: Caller) -> Result {
	if !caller_from_web(caller) do return fail("only a browser's Settings page")
	web_set_open_for(c.open, window_link_serial())
	window_state_changed()
	return {ok = true}
}

// Opened (or closed) by the link with this serial; opening builds anew at the next flush (the
// files and folders behind the lists are read then: on open, not on a timer).
web_set_open_for :: proc(open: bool, serial: u64) {
	web_set.link = open && serial != 0 ? serial : 0
	web_set.key = 0
}

// state_sections: webset while the page shows, to the link that opened it.
web_settings_sections :: proc(out: ^[dynamic][2]string) {
	web_settings_sections_for(out, window_link_serial())
}

web_settings_sections_for :: proc(out: ^[dynamic][2]string, serial: u64) {
	if web_set.link == 0 || web_set.link != serial do return
	h := hash.fnv64a(transmute([]u8)string("set"))
	for x in out do for name in WEB_SETTINGS_INPUTS do if x[0] == name {
		h = hash.fnv64a(transmute([]u8)x[1], h)
	}
	if h == 0 do h = 1
	if h != web_set.key || web_set.json == "" do web_settings_rebuild(h)
	append(out, [2]string{WEB_SETTINGS_SECTION, web_set.json})
}

// web_view_tick: the flag goes with its link (a takeover, a detach). No rebuild here: the page is
// built on open and when a section it reads changes, so no disk work runs on a timer.
web_settings_tick :: proc() {
	if web_set.link != 0 do claude_lists_poll() // the lists read on a worker since (settings_files.odin)
	if web_set.link != 0 && (!window_link_web() || window_link_serial() != web_set.link) do web_settings_reset()
}

// Something the page lists changed outside the sections its key hashes (claude_lists.odin's
// plugins and MCP servers, read on a worker): built again at the next flush.
web_settings_stale :: proc() {
	web_set.key = 0
}

web_settings_reset :: proc() {
	delete(web_set.json, runtime.heap_allocator())
	web_set = {}
}

web_settings_builds :: proc() -> int {return web_set.builds}

// The new build made and compared before the old one is freed; true: it differs.
@(private = "file")
web_settings_rebuild :: proc(key: u64) -> bool {
	heap := runtime.heap_allocator()
	next := web_settings_json()
	changed := next != web_set.json
	if changed {
		old := web_set.json
		web_set.json = strings.clone(next, heap)
		delete(old, heap)
	}
	web_set.key = key
	web_set.builds += 1
	return changed
}

// The page's data (temp allocator).
web_settings_json :: proc() -> string {
	rows := settings_file_rows()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"sections":[`)
	n := 0
	for sec in Setting_Section {
		if sec == .Project do continue // its files open in an editor tab: the window's
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		strings.write_string(&b, `{"id":`)
		json_quote(&b, web_section_id(sec))
		strings.write_string(&b, `,"name":`)
		json_quote(&b, SETTING_SECTION_NAMES[sec])
		strings.write_string(&b, `,"note":`)
		json_quote(&b, web_section_note(sec, rows))
		strings.write_string(&b, `,"empty":`)
		json_quote(&b, sec == .Atlas && !atlas_offered() ? "Atlas runs on pi: install pi under Coding agents." : "")
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `],"settings":[`)
	for &s, i in SETTINGS {
		if i > 0 do strings.write_byte(&b, ',')
		web_setting_json(&b, &s, rows)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

web_section_id :: proc(sec: Setting_Section) -> string {
	return strings.to_lower(fmt.tprintf("%v", sec), context.temp_allocator)
}

// The section list's notes, as the window's (ui_settings_page.odin sp_nav_note).
@(private = "file")
web_section_note :: proc(sec: Setting_Section, rows: []Settings_File_Row) -> string {
	n := 0
	#partial switch sec {
	case .Agents:
		for r in rows do if r.group == "agents" && r.button == "Update…" do n += 1
		if n > 0 do return n == 1 ? "1 update" : fmt.tprintf("%d updates", n)
	case .Machines:
		for r in rows do if strings.has_prefix(r.path, MACHINE_ROW) {
			switch r.button {
			case "Log in…", "Try again", "Retry", "Keep running…", "Install…", "Update": n += 1
			}
		}
		if n > 0 do return fmt.tprintf("%d %s you", n, n == 1 ? "needs" : "need")
	}
	return ""
}

// Whether a browser may change this setting: the gate's own answer for its command, less the ones
// that open the window's sheets.
web_setting_may :: proc(s: ^Setting) -> bool {
	for id in WEB_SETTINGS_AT_MAC do if id == s.id do return false
	spec := command_spec(s.command)
	return spec != nil && web_may_run(spec.type, spec.who)
}

@(private = "file")
web_setting_json :: proc(b: ^strings.Builder, s: ^Setting, rows: []Settings_File_Row) {
	st := &state.settings
	kinds := [Setting_Kind]string{.Switch = "switch", .Choice = "choice", .Stepper = "stepper", .Grid = "grid", .Button = "button", .Status = "status", .List = "list"}
	strings.write_string(b, `{"id":`)
	json_quote(b, s.id)
	strings.write_string(b, `,"section":`)
	json_quote(b, web_section_id(s.section))
	strings.write_string(b, `,"card":`)
	json_quote(b, s.card)
	strings.write_string(b, `,"label":`)
	json_quote(b, setting_label(s))
	strings.write_string(b, `,"hint":`)
	json_quote(b, web_setting_hint(s))
	strings.write_string(b, `,"keywords":`)
	json_quote(b, s.keywords)
	fmt.sbprintf(b, `,"kind":"%s","web":%v,"here":%v,"applies":`, kinds[s.kind], web_setting_may(s), setting_this_mac_only(s))
	json_quote(b, SETTING_APPLIES_BADGES[s.applies])
	strings.write_string(b, `,"choices":[`)
	for c, i in s.choices {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"name":`)
		json_quote(b, c.name)
		strings.write_string(b, `,"arg":`)
		json_quote(b, strings.to_lower(c.name, context.temp_allocator))
		strings.write_byte(b, '}')
	}
	strings.write_string(b, `],"value":`)
	switch s.kind {
	case .Switch:
		on := false
		switch s.id {
		case "reduce_motion":           on = st.reduce_motion
		case "dim_panes":               on = !st.dim_panes_off
		case "bell_dock":               on = !st.bell_dock_off
		case "agent_notify":            on = !st.notify_off
		case "claude_skip_permissions": on = st.claude_skip_permissions
		case "codex_full_access":       on = st.codex_full_access
		case "remote_machines":         on = st.remote_machines
		case "machines_reachable":      on = st.machines_reachable
		case "web_access":              on = st.web_access
		case "keep_sessions":           on = st.keep_sessions
		case "separate_core":           on = st.separate_core
		case "tidy_projects":           on = !st.tidy_off
		case "update_checks":           on = !update_view().checks_off
		}
		if s.ext != "" do on = pi_extension_on(s.ext)
		fmt.sbprintf(b, "%v", on)
	case .Choice:
		v := ""
		switch s.id {
		case "appearance": v = fmt.tprintf("%v", st.appearance)
		case "look":       v = fmt.tprintf("%v", st.theme)
		case "text_size":  v = TEXT_SIZE_NAMES[st.text_size]
		}
		json_quote(b, strings.to_lower(v, context.temp_allocator))
	case .Stepper:
		fmt.sbprintf(b, "%d", st.term_text_pt)
	case .Grid:
		strings.write_byte(b, '[')
		for g, i in ([]Bell_Group{.Waiting, .Finished, .Errors, .Jobs}) {
			if i > 0 do strings.write_byte(b, ',')
			fmt.sbprintf(b, `{{"group":"%s","bell":%v,"macos":"%s","sound":"%s"}}`, BELL_GROUP_NAMES[g], g not_in st.bell_off, OS_WHEN_NAMES[bell_os_when(st^, g)], BELL_SOUND_LABELS[bell_sound_of(st^, g)])
		}
		strings.write_byte(b, ']')
	case .Button, .Status, .List:
		json_quote(b, web_setting_detail(s))
	}
	fmt.sbprintf(b, `,"show":%v,"button":`, web_setting_shown(s, rows))
	json_quote(b, web_setting_button(s))
	strings.write_string(b, `,"items":[`)
	web_setting_items(b, s, rows)
	strings.write_string(b, "]}")
}

// A button's live detail (the window's action details), "" none.
@(private = "file")
web_setting_detail :: proc(s: ^Setting) -> string {
	switch s.id {
	case "chats_dir":
		c := chats_project()
		return c != nil ? fs_display(c.cwd) : ""
	case "atlas_model":
		m := agent_model_short()
		return m != "" ? m : "pi's default"
	case "web_listen": return web_listen_address()
	}
	return ""
}

// The hint under a label: the registry's, or a live one as the window shows it.
@(private = "file")
web_setting_hint :: proc(s: ^Setting) -> string {
	switch s.id {
	case "web_listen": return fmt.tprintf("%s · %s", web_listen_address(), s.hint)
	case "chats_dir", "atlas_model": return web_setting_detail(s)
	}
	return s.hint
}

// A button setting's button, as the window words it (ui_settings_page.odin sp_button_text).
@(private = "file")
web_setting_button :: proc(s: ^Setting) -> string {
	if s.kind != .Button do return ""
	switch s.id {
	case "chats_dir", "atlas_model", "web_listen", "main_folder": return "Change…"
	case "machine_add":        return "Add…"
	case "web_pair":           return "Pair…"
	case "setup":              return "Set up…"
	case "shortcuts":          return "Show ⌘/"
	case "control_token":      return "Copy"
	case "refresh_shell_env":  return "Refresh"
	case "rescan":             return "Rescan"
	case "reload_all_pi":      return "Reload"
	case "restart_all_claude": return "Restart…"
	}
	return "Open"
}

// Whether the window shows the setting now (ui_settings_page.odin sp_section, sp_setting).
@(private = "file")
web_setting_shown :: proc(s: ^Setting, rows: []Settings_File_Row) -> bool {
	if s.card == "pi" && s.section == .Agents && !pi_installed() {
		has := false
		for r in rows do if r.group == "agents" {
			if x := setting_for_row(r.path); x != nil && x.card == "pi" do has = true
		}
		if !has do return false
	}
	if s.section == .Atlas && !atlas_offered() do return false
	if s.ext != "" {
		for e in pi_integration_optional() do if e.name == s.ext do return true
		return false
	}
	switch s.id {
	case "reload_all_pi":
		for &o in state.open_sessions do if t := session_pi_tab(&o); t != nil && t.status == .Running do return true
		return false
	case "restart_all_claude": return len(running_claude()) > 0
	case "web_pair", "web_devices": return state.settings.web_access
	case "machines", "machine_add": return state.settings.remote_machines
	}
	return true
}

// A list's (or a status's) rows, with what a browser may do on each.
@(private = "file")
web_setting_items :: proc(b: ^strings.Builder, s: ^Setting, rows: []Settings_File_Row) {
	n := 0
	item :: proc(b: ^strings.Builder, n: ^int, r: Settings_File_Row, acts: []string, arg: string, codex := false) {
		if n^ > 0 do strings.write_byte(b, ',')
		n^ += 1
		strings.write_string(b, `{"label":`)
		json_quote(b, strings.trim_space(r.label))
		strings.write_string(b, `,"detail":`)
		json_quote(b, r.detail)
		strings.write_string(b, `,"button":`)
		json_quote(b, r.button)
		strings.write_string(b, `,"acts":[`)
		for a, i in acts {
			if i > 0 do strings.write_byte(b, ',')
			json_quote(b, a)
		}
		strings.write_string(b, `],"arg":`)
		json_quote(b, arg)
		fmt.sbprintf(b, `,"codex":%v}}`, codex)
	}
	acts := make([dynamic]string, context.temp_allocator)
	switch s.id {
	case "pi_status", "claude_status", "codex_status":
		for r in rows do if r.group == "agents" && setting_for_row(r.path) == s do item(b, &n, r, nil, "")
	case "machines":
		for r in rows do if strings.has_prefix(r.path, MACHINE_ROW) || strings.has_prefix(r.path, MACHINE_CHECK_ROW) {
			clear(&acts)
			no, ok := machine_row_no(r.path)
			if ok && (r.button == "Connect" || r.button == "Take back") do append(&acts, "connect") // machine_connect: view state, a browser's too
			item(b, &n, r, acts[:], ok ? fmt.tprintf("%d", no) : "")
		}
	case "web_devices":
		for r in rows do if strings.has_prefix(r.path, WEB_DEVICE_ROW) do item(b, &n, r, nil, "")
	case "claude_plugins", "claude_mcp", "codex_plugins": // read-only: names only (claude_lists.odin, codex_plugins.odin)
		for r in rows do if strings.has_prefix(r.path, s.row) do item(b, &n, r, nil, "")
	case "claude_accounts", "codex_accounts":
		codex := s.id == "codex_accounts"
		group := codex ? "codex-accounts" : "claude-accounts"
		prefix := codex ? CODEX_ACCOUNT_ROW : CLAUDE_ACCOUNT_ROW
		for r in rows do if r.group == group {
			clear(&acts)
			arg := ""
			switch {
			case strings.has_prefix(r.path, prefix):
				arg = r.path[len(prefix):]
				append(&acts, "rename")
				if r.make_default do append(&acts, "default")
				if r.remove do append(&acts, "remove")
			case r.path == CLAUDE_ACCOUNT_SCAN_ROW: append(&acts, "scan")
			case r.button == "Add…": append(&acts, "add")
			}
			item(b, &n, r, acts[:], arg, codex)
		}
	case "main_folder":
		for r in rows do if r.path == FOLDER_MAIN_ROW do item(b, &n, r, []string{"change"}, "")
	case "subfolders":
		for r in rows do if r.group == "folders" && r.path != FOLDER_MAIN_ROW {
			clear(&acts)
			arg := ""
			if k, ok := folder_row_kind(r.path); ok {
				arg = FOLDER_NAMES[k]
				append(&acts, "change")
				if r.reset do append(&acts, "reset")
			}
			item(b, &n, r, acts[:], arg)
		}
	}
}
