package core

// The settings registry (settings_registry.odin): every setting sends an existing command, its
// "Only you, at this Mac" badge is the command table's, the pi extensions are the integration's,
// every group of settings_file_rows has a section, and the search finds settings and files.

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private = "file")
PI_EXTENSIONS_JSON :: #load("../../integrations/pi/extensions.json", string)

@(test)
settings_registry_commands :: proc(t: ^testing.T) {
	seen := make(map[string]bool, context.temp_allocator)
	for &s in SETTINGS {
		testing.expectf(t, !seen[s.id], "setting %s twice", s.id)
		seen[s.id] = true
		testing.expectf(t, s.label != "", "setting %s has no label", s.id)
		spec := command_spec(s.command)
		testing.expectf(t, spec != nil, "setting %s: no command %q", s.id, s.command)
		if spec == nil do continue
		// the badge is the command table's own word, never the registry's
		testing.expect_value(t, setting_this_mac_only(&s), spec.who == .User_Here)
		// nothing on the page is sendable by an agent that the user alone may not send today
		testing.expectf(t, spec.who != .Internal && spec.who != .Bridge && spec.who != .Claude && spec.who != .Report, "setting %s: %s is not the user's", s.id, s.command)
		switch s.kind {
		case .Choice:  testing.expectf(t, len(s.choices) >= 2, "%s: a choice of one", s.id)
		case .Stepper, .Grid: testing.expectf(t, len(s.also) > 0, "%s: no actions", s.id)
		case .Switch, .Button, .Status, .List:
		}
	}
	// the known ones (the grid and machines are this Mac's; the look is anyone's)
	testing.expect(t, setting_this_mac_only(setting_by_id("notify_grid")), "notify grid")
	testing.expect(t, setting_this_mac_only(setting_by_id("machine_add")), "machine_add")
	testing.expect(t, !setting_this_mac_only(setting_by_id("look")), "look")
	// the pi extensions' switches are the integration's optional extensions, all of them
	v, err := json.parse_string(PI_EXTENSIONS_JSON, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "extensions.json")
	root, _ := v.(json.Object)
	list, _ := root["extensions"].(json.Array)
	n := 0
	for e in list {
		o, _ := e.(json.Object)
		if req, _ := o["required"].(json.Boolean); req do continue
		name, _ := o["name"].(json.String)
		n += 1
		found := false
		for s in SETTINGS do if s.ext == string(name) do found = s.row == strings.concatenate({PI_EXT_ROW, string(name)}, context.temp_allocator) && s.command == "set_pi_extension"
		testing.expectf(t, found, "no setting for pi extension %s", name)
	}
	testing.expect(t, n >= 3, "optional pi extensions read")
	// every group settings_file_rows makes has a section
	for g in ([]string{"pi", "pi-ext", "ext", "project", "claude", "claude:work", "claude-project", "claude-accounts", "codex-accounts", "agents", "atlas", "jobs", "chats", "folders", "machines"}) {
		_, _, ok := settings_group_section(g)
		testing.expectf(t, ok, "group %s has no section", g)
	}
	// a row stands for its setting
	testing.expect_value(t, setting_for_row(MACHINE_REACH_ROW).id, "machines_reachable")
	testing.expect_value(t, setting_for_row("deckhand:machine:3").id, "machines")
	testing.expect_value(t, setting_for_row(FOLDER_MAIN_ROW).id, "main_folder")
	testing.expect_value(t, setting_for_row("deckhand:folder:jobs").id, "subfolders")
	testing.expect_value(t, setting_action_label("appearance_dark"), "Appearance: Dark")
	testing.expect_value(t, setting_action_label("keep_sessions"), "Keep sessions running when Deckhand quits")
	testing.expect_value(t, setting_action_label("text_bigger"), "") // its own (⌘+)
}

@(test)
settings_registry_search :: proc(t: ^testing.T) {
	rows := []Settings_File_Row {
		{group = "pi", label = "settings.json", detail = "model, theme, packages…", path = "/h/.pi/agent/settings.json", exists = true},
		{group = "pi", label = "modes.json", detail = "modes", path = "/h/.pi/agent/modes.json", exists = true},
		{group = "machines", label = "nuc", detail = "Needs you to log in", path = "deckhand:machine:2", button = "Log in…"},
		{group = "chats", label = "Chat instructions (AGENTS.md)", detail = "how pi talks in chats", path = "/h/Deckhand/chats/AGENTS.md", exists = true},
	}
	first :: proc(q: string, rows: []Settings_File_Row) -> Settings_Hit {
		hits := settings_search(q, rows)
		return len(hits) > 0 ? hits[0] : {}
	}
	testing.expect_value(t, len(settings_search("", rows)), 0)
	testing.expect_value(t, len(settings_search("zzqx", rows)), 0)
	h := first("dock", rows)
	testing.expect(t, h.kind == .Setting && h.setting.id == "bell_dock", "dock: the Dock badge first")
	h = first("Keep sessions", rows) // case folded, every word
	testing.expect(t, h.setting != nil && h.setting.id == "keep_sessions", "keep sessions")
	h = first("modes", rows) // a rare file by its name
	testing.expect(t, h.kind == .File && h.row.label == "modes.json" && h.section == .Agents && h.card == "pi", "modes.json")
	h = first("nuc", rows) // a machine's row by its name, in Machines
	testing.expect(t, h.kind == .Row && h.section == .Machines && h.setting != nil && h.setting.id == "machines", "nuc")
	h = first("chat agents", rows) // a file by its label and name
	testing.expect(t, h.kind == .File && h.section == .Sessions, "chat instructions")
	// "machine" finds the machine settings and the machine's row
	n := 0
	for x in settings_search("machine", rows) do if x.section == .Machines do n += 1
	testing.expect(t, n >= 4, "machine: the Machines section")
	// a hint's words count ("redaction": Guardrails)
	h = first("redaction", rows)
	testing.expect(t, h.setting != nil && h.setting.id == "pi_ext_guardrails", "redaction")
}
