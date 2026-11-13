package core

// The settings registry: every setting Deckhand's own Settings show, in one table (SETTINGS), and
// which section each settings file and row of settings_file_rows belongs to (SETTINGS_FILE_GROUPS).
// One name per setting: the palette's and the menu bar's actions take their labels from here
// (actions.odin's settings_labels_init), so the page, the palette, the menu, the gear and the
// guide say the same words.
//
// A setting runs what it ran before: its `action` (the window's actions.odin), whose command is
// `command` (command_table.odin), so caller_may decides exactly as for that action. Nothing here
// adds a command or authority. Whether only the user at this Mac may change it ("Only you, at this
// Mac") is the command's `who` (.User_Here), read from the command table: setting_this_mac_only.
//
// Deckhand writes only its own settings: pi's, Claude Code's and Codex's config are files that
// Settings opens (or makes on the user's click: settings_create), never edits.

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Setting_Section :: enum u8 {
	Appearance,
	Notifications,
	Agents, // Coding agents
	Machines,
	Sessions, // Sessions & chats
	Atlas, // Atlas & jobs
	Folders,
	Deckhand,
	Project, // This project · <name>: the files of the session on screen's project
}

SETTING_SECTION_NAMES := [Setting_Section]string {
	.Appearance    = "Appearance",
	.Notifications = "Notifications",
	.Agents        = "Coding agents",
	.Machines      = "Machines",
	.Sessions      = "Sessions & chats",
	.Atlas         = "Atlas & jobs",
	.Folders       = "Folders",
	.Deckhand      = "Deckhand",
	.Project       = "This project",
}

// What a setting's control is.
Setting_Kind :: enum u8 {
	Switch, // on and off
	Choice, // one of a few (choices)
	Stepper, // − value +
	Grid, // the notifications grid (Bell, macOS, Sound per kind)
	Button, // a button that runs its action (Change…, Add…, Copy)
	Status, // a coding agent's state, with the checklist's Install…/Update… (the setup sheet)
	List, // rows that come and go (machines, accounts, subfolders), each with its own buttons
}

// When a change takes effect.
Setting_Applies :: enum u8 {
	Now,
	Next_Start, // the pi tabs started from now on
	Next_Launch, // Deckhand's next launch
}

SETTING_APPLIES_BADGES := [Setting_Applies]string {
	.Now         = "",
	.Next_Start  = "Next start",
	.Next_Launch = "Next launch",
}

// The badge of a setting only the user at this Mac may change (setting_this_mac_only).
SETTING_THIS_MAC_BADGE :: "Only you, at this Mac"

// One choice of a Choice setting: its action's label is "<label>: <name>" ("Appearance: System").
Setting_Choice :: struct {
	action, name: string,
}

Setting :: struct {
	id:       string,
	section:  Setting_Section,
	card:     string, // the card it sits in on the page ("" = the section's own)
	label:    string, // its one name; "…" when its button opens something (the page drops it)
	hint:     string, // a line under it ("" = none; a live one is the window's)
	keywords: string, // more words the search matches
	kind:     Setting_Kind,
	action:   string, // the action whose label this is (actions.odin; "" = none in the palette)
	choices:  []Setting_Choice, // a Choice's actions, in order
	also:     []string, // other actions its control runs (their own labels: ⌘+, the grid's cells)
	command:  string, // the command its control sends (command_table.odin's type)
	applies:  Setting_Applies,
	row:      string, // the Settings rows it stands for (settings_file_rows' path; a prefix ends in ':')
	atlas:    bool, // "Atlas" in its label is the agent's name (agent_name)
	ext:      string, // a pi extension of Deckhand's integration (set_pi_extension's name)
}

SETTINGS := [?]Setting {
	// ---- Appearance: this window, at once ----
	{id = "appearance", section = .Appearance, label = "Appearance", hint = "System follows macOS", keywords = "light dark system mode", kind = .Choice, choices = {{"appearance_system", "System"}, {"appearance_light", "Light"}, {"appearance_dark", "Dark"}}, command = "set_appearance"},
	{id = "look", section = .Appearance, label = "Look", hint = "Terminals follow the look", keywords = "theme graphite warm ghostty colour color", kind = .Choice, choices = {{"look_graphite", "Graphite"}, {"look_warm", "Warm"}, {"look_ghostty", "Ghostty"}}, command = "set_theme"},
	{id = "text_size", section = .Appearance, label = "Text size", hint = "Sidebar, tabs, menus and panels", keywords = "font small medium default large chrome", kind = .Choice, choices = {{"text_small", "Small"}, {"text_medium", "Medium"}, {"text_default", "Default"}, {"text_large", "Large"}}, command = "set_text_size"},
	{id = "term_text", section = .Appearance, label = "Terminal and editor text", hint = "Also ⌘+, ⌘− and ⌘0", keywords = "font size zoom points pt bigger smaller actual", kind = .Stepper, also = {"text_smaller", "text_bigger", "text_reset"}, command = "set_terminal_text_size"},
	{id = "reduce_motion", section = .Appearance, label = "Reduce motion", keywords = "animation fade slide", kind = .Switch, action = "reduce_motion", command = "set_reduce_motion"},
	{id = "dim_panes", section = .Appearance, label = "Dim inactive panes", hint = "Split panes without the keyboard dim slightly", keywords = "split focus", kind = .Switch, action = "dim_panes", command = "set_dim_panes"},
	// ---- Notifications ----
	{id = "notify_grid", section = .Notifications, label = "Notify me about", hint = "Bell, macOS notification and sound for each kind", keywords = "bell macos notification sound needs you waiting finished errors jobs tink alert", kind = .Grid, also = {"bell_waiting", "bell_os_waiting", "bell_sound_waiting", "bell_finished", "bell_os_finished", "bell_sound_finished", "bell_errors", "bell_os_errors", "bell_sound_errors", "bell_jobs", "bell_os_jobs", "bell_sound_jobs"}, command = "set_notifications"},
	{id = "bell_dock", section = .Notifications, label = "Badge the Dock icon", hint = "Sessions that need you, on every machine", keywords = "dock badge count", kind = .Switch, action = "bell_dock", command = "set_notifications"},
	{id = "agent_notify", section = .Notifications, label = "Atlas's notifications", hint = "macOS notifications from Atlas while Deckhand is in the background", keywords = "agent notifications", kind = .Switch, action = "agent_notify", command = "set_notify", atlas = true},
	// ---- Coding agents: what is installed and how Deckhand starts each one; their own config is files ----
	{id = "pi_status", section = .Agents, card = "pi", label = "pi", hint = "Its version, Deckhand's integration and the recommended packages", keywords = "install update version recommended packages pi-subagents rpiv-todo checklist", kind = .Status, command = "setup_sheet", row = HARNESS_SETTINGS_ROW},
	{id = "pi_ext_guardrails", section = .Agents, card = "pi", label = "Guardrails", hint = "Ask/block rules, secret redaction · pi tabs, not jobs", keywords = "extension redact secrets rules block ask", kind = .Switch, command = "set_pi_extension", applies = .Next_Start, row = PI_EXT_ROW + "guardrails", ext = "guardrails"},
	{id = "pi_ext_shell", section = .Agents, card = "pi", label = "Background shells", hint = "Deckhand's shell extension: background shells, monitors, timers", keywords = "extension shell monitor timer bash_bg", kind = .Switch, command = "set_pi_extension", applies = .Next_Start, row = PI_EXT_ROW + "shell", ext = "shell"},
	{id = "pi_ext_notes", section = .Agents, card = "pi", label = "Session-note reminder", hint = "Deckhand's notes extension: a reminder before pi compacts", keywords = "extension notes compact", kind = .Switch, command = "set_pi_extension", applies = .Next_Start, row = PI_EXT_ROW + "notes", ext = "notes"},
	{id = "claude_status", section = .Agents, card = "Claude Code", label = "Claude Code", hint = "Its version and Deckhand's plugin", keywords = "claude install update version plugin checklist", kind = .Status, command = "setup_sheet", row = HARNESS_SETTINGS_ROW},
	{id = "claude_accounts", section = .Agents, card = "Claude Code", label = "Add Claude account…", hint = "Another Claude Code config folder (CLAUDE_CONFIG_DIR)", keywords = "accounts config folder default rename remove scan", kind = .List, action = "claude_account_add", command = "add_claude_account", row = "deckhand:claude-account"},
	{id = "claude_skip_permissions", section = .Agents, card = "Claude Code", label = "Skip permissions in new tabs", hint = "Claude acts without asking. Tabs you start only, never an agent's.", keywords = "claude dangerously flags default permissions", kind = .Switch, action = "claude_skip_permissions", command = "set_claude_default_flags", row = CLAUDE_FLAGS_ROW},
	{id = "codex_status", section = .Agents, card = "Codex", label = "Codex", hint = "Its version", keywords = "codex openai install update version checklist", kind = .Status, command = "setup_sheet", row = HARNESS_SETTINGS_ROW},
	{id = "codex_full_access", section = .Agents, card = "Codex", label = "Full access in new Codex tabs", hint = "Codex acts without asking, outside its sandbox. Tabs you start only, never an agent's.", keywords = "codex dangerously bypass approvals sandbox flags default permissions", kind = .Switch, action = "codex_full_access", command = "set_claude_default_flags"},
	// ---- Machines: other machines' sessions over the user's own ssh ----
	{id = "remote_machines", section = .Machines, label = "Machines over SSH", hint = "Off: no link to any machine; your list is kept", keywords = "machines remote ssh links", kind = .Switch, action = "remote_machines", command = "set_remote_machines", row = MACHINE_SSH_ROW},
	{id = "machines", section = .Machines, label = "Your machines", hint = "Connect, log in, update, rename or remove", keywords = "machine remote ssh connect log in login update install rename remove take back", kind = .List, command = "machine_connect", row = MACHINE_ROW},
	{id = "machine_add", section = .Machines, label = "Add a machine…", hint = "user@host or a name from ~/.ssh/config", keywords = "machine new ssh remote host", kind = .Button, action = "machine_add", command = "machine_add", row = MACHINE_ADD_ROW},
	{id = "machines_reachable", section = .Machines, label = "Allow other machines to connect to this Mac", hint = "A machine you allow acts as you here. Asks first.", keywords = "machines reachable hub inbound connect", kind = .Switch, command = "set_machines_reachable", row = MACHINE_REACH_ROW},
	// ---- Sessions & chats ----
	{id = "keep_sessions", section = .Sessions, card = "Running", label = "Keep sessions running when Deckhand quits", hint = "The session holder keeps them; reopening Deckhand takes them back", keywords = "quit quitting holder keep update", kind = .Switch, action = "keep_sessions", command = "set_keep_sessions"},
	{id = "separate_core", section = .Sessions, card = "Running", label = "Run sessions in a background core", hint = "Applies once Deckhand Core has stopped", keywords = "background core separate process", kind = .Switch, action = "separate_core", command = "set_separate_core", applies = .Next_Launch},
	{id = "tidy_projects", section = .Sessions, card = "Running", label = "Tidy project list", hint = "Hide temp and missing folders, nest subfolders", keywords = "projects tidy hidden temp nest", kind = .Switch, action = "tidy_projects", command = "set_tidy_projects"},
	{id = "chats_dir", section = .Sessions, card = "Chats", label = "Chats folder…", keywords = "chats folder directory", kind = .Button, action = "chats_dir", also = {"chats_dir_default"}, command = "set_folder"},
	{id = "rescan", section = .Sessions, card = "Fix-ups", label = "Rescan sessions", hint = "Look for projects and sessions again", keywords = "refresh stale", kind = .Button, action = "rescan", command = "rescan"},
	{id = "refresh_shell_env", section = .Sessions, card = "Fix-ups", label = "Refresh shell environment", hint = "Your login shell's PATH and variables, for new tabs", keywords = "env path login shell stale", kind = .Button, action = "refresh_shell_env", command = "refresh_shell_env"},
	{id = "reload_all_pi", section = .Sessions, card = "Fix-ups", label = "Reload all pi tabs", hint = "pi reads its settings again", keywords = "reload pi stale", kind = .Button, action = "reload_all_pi", command = "pi_reload_all"},
	{id = "restart_all_claude", section = .Sessions, card = "Fix-ups", label = "Restart all Claude tabs", hint = "Each resumes its conversation", keywords = "restart claude stale", kind = .Button, action = "restart_all_claude", command = "claude_restart_changed"},
	// ---- Atlas & jobs ----
	{id = "atlas_model", section = .Atlas, label = "Atlas's model…", hint = "pi's model selector in Atlas's terminal", keywords = "agent model provider", kind = .Button, action = "agent_model", also = {"agent_model_pop"}, command = "agent_model_picker", row = ATLAS_MODEL_ROW, atlas = true},
	{id = "jobs", section = .Atlas, label = "Show jobs", hint = "Atlas's scheduled jobs, their runs and limits", keywords = "jobs schedule limits pause cost", kind = .Button, action = "show_jobs", command = "set_left_tab"},
	// ---- Folders ----
	{id = "main_folder", section = .Folders, label = "Main folder…", hint = "sessions/, jobs/, memory/, atlas/ and chats/ live here", keywords = "home folder notes vault", kind = .Button, action = "home_dir", command = "set_home_dir", row = FOLDER_MAIN_ROW},
	{id = "subfolders", section = .Folders, label = "Subfolders", hint = "Each one default or yours", keywords = "sessions jobs memory atlas chats folder custom reset", kind = .List, also = {"folder_change"}, command = "set_folder", row = "deckhand:folder:"},
	// ---- Deckhand ----
	{id = "update_checks", section = .Deckhand, label = "Check for updates automatically", hint = "About once a day", keywords = "update version release", kind = .Switch, action = "update_checks", also = {"check_updates"}, command = "set_update_check"},
	{id = "setup", section = .Deckhand, label = "Set up Deckhand…", hint = "Coding agents, main folder, chats", keywords = "first run setup", kind = .Button, action = "setup", command = "setup_sheet"},
	{id = "shortcuts", section = .Deckhand, label = "Keyboard shortcuts", keywords = "keys shortcuts", kind = .Button, action = "shortcuts", command = "set_focus"},
	{id = "control_token", section = .Deckhand, label = "Copy a control token", hint = "For deckhand --ctl scripts", keywords = "token ctl script control", kind = .Button, action = "copy_control_token", command = "copy_control_token"},
}

// Settings files and rows by settings_file_rows' group: their section and card. Rows of a group
// that are settings (settings_setting_row) are that section's lists (machines, accounts, folders);
// the others are its "Advanced: open the file" links.
Setting_File_Group :: struct {
	group:   string, // settings_file_rows' (a prefix ends in ':')
	section: Setting_Section,
	card:    string,
}

SETTINGS_FILE_GROUPS := [?]Setting_File_Group {
	{"pi", .Agents, "pi"},
	{"pi-ext", .Agents, "pi"},
	{"ext", .Agents, "pi"},
	{"claude", .Agents, "Claude Code"},
	{"claude:", .Agents, "Claude Code"}, // one per account once there are several
	{"claude-accounts", .Agents, "Claude Code"},
	{"agents", .Agents, ""},
	{"project", .Project, "pi"},
	{"claude-project", .Project, "Claude Code"},
	{"atlas", .Atlas, ""},
	{"jobs", .Atlas, "Jobs"},
	{"chats", .Sessions, "Chats"},
	{"folders", .Folders, ""},
	{"machines", .Machines, ""},
}

// Files a section lists only under "all files…" (and that search finds): the rest are its common
// ones, linked at once.
@(private = "file")
SETTINGS_FILES_RARE :: [?]string{"modes.json", "SYSTEM.md", "APPEND_SYSTEM.md", "output-styles", "rules", "HEARTBEAT.md", ".claude/settings.local.json", "CLAUDE.local.md"}

setting_by_id :: proc(id: string) -> ^Setting {
	for &s in SETTINGS do if s.id == id do return &s
	return nil
}

// The setting an action belongs to: its label (choice -1), or one of its choices (choice i);
// nil when none, or when the action only runs from it (`also`).
setting_for_action :: proc(action: string) -> (s: ^Setting, choice: int) {
	for &x in SETTINGS {
		if x.action == action do return &x, -1
		for c, i in x.choices do if c.action == action do return &x, i
	}
	return nil, -1
}

// The action's label from the registry: the setting's label, or "<label>: <choice>" ("" = none).
setting_action_label :: proc(action: string, allocator := context.temp_allocator) -> string {
	s, i := setting_for_action(action)
	if s == nil do return ""
	if i < 0 do return strings.clone(s.label, allocator)
	return fmt.aprintf("%s: %s", s.label, s.choices[i].name, allocator = allocator)
}

// A setting's label as shown: Atlas's own name in place of "Atlas" (set_agent_name).
setting_label :: proc(s: ^Setting) -> string {
	if !s.atlas do return s.label
	if n := agent_name(); n != "Atlas" {
		out, _ := strings.replace_all(s.label, "Atlas", n, context.temp_allocator)
		return out
	}
	return s.label
}

// The label shown by id (setting_label; "" = no such setting).
setting_title :: proc(id: string) -> string {
	s := setting_by_id(id)
	return s != nil ? setting_label(s) : ""
}

// "Only you, at this Mac": its command is this Mac's user's only (who .User_Here: refused to
// agents, scripts and another machine's core viewing this one). Read from the command table.
setting_this_mac_only :: proc(s: ^Setting) -> bool {
	spec := command_spec(s.command)
	return spec != nil && spec.who == .User_Here
}

// Which setting a Settings row stands for (settings_file_rows' path): an exact `row`, else the
// longest prefix one (nil = none). A Coding agents row picks its harness's Status.
setting_for_row :: proc(path: string) -> ^Setting {
	if !settings_setting_row(path) do return nil
	if strings.has_prefix(path, HARNESS_SETTINGS_ROW) {
		id := "pi_status"
		if it := harness_item(path[len(HARNESS_SETTINGS_ROW):]); it != nil {
			switch HARNESS_MANIFEST[it.row].harness {
			case .Pi:     id = "pi_status"
			case .Claude: id = "claude_status"
			case .Codex:  id = "codex_status"
			}
		}
		return setting_by_id(id)
	}
	best: ^Setting
	for &s in SETTINGS {
		if s.row == "" do continue
		if s.row == path do return &s
		if strings.has_prefix(path, s.row) && (best == nil || len(s.row) > len(best.row)) do best = &s
	}
	return best
}

// The section and card of a settings_file_rows group (ok false: none).
settings_group_section :: proc(group: string) -> (section: Setting_Section, card: string, ok: bool) {
	for g in SETTINGS_FILE_GROUPS {
		if g.group == group || (strings.has_suffix(g.group, ":") && strings.has_prefix(group, g.group)) do return g.section, g.card, true
	}
	return {}, "", false
}

// A file row a section links only under "all files…": the rare files, extensions' configs and
// folders, job notes.
settings_file_rare :: proc(r: Settings_File_Row) -> bool {
	if r.group == "ext" || r.group == "jobs" do return true
	for n in SETTINGS_FILES_RARE do if r.label == n do return true
	return false
}

// ---- search: one box over the settings and the files ----

Settings_Hit_Kind :: enum u8 {
	Setting, // a registry entry
	File, // a settings file or folder (settings_file_rows)
	Row, // a row of a setting's list (a machine, an account, a subfolder, a coding agent's item)
}

Settings_Hit :: struct {
	kind:    Settings_Hit_Kind,
	setting: ^Setting, // .Setting; .Row: the setting it belongs to (nil = none)
	row:     Settings_File_Row, // .File, .Row (temp)
	section: Setting_Section,
	card:    string,
	score:   int,
	order:   int, // where it is listed: the registry's order, then the rows'
}

// Every word of the query, case folded, in one of the fields (substrings: "dock" finds "Badge
// the Dock icon"); a file's name also by a fuzzy match, as the Files filter does. The score
// favours the label (fields[0]), then a word's start.
@(private = "file")
settings_match :: proc(words: []string, fields: []string, fuzzy_name := "") -> (score: int, ok: bool) {
	low := make([]string, len(fields), context.temp_allocator)
	for f, i in fields do low[i] = strings.to_lower(f, context.temp_allocator)
	for w in words {
		lw := strings.to_lower(w, context.temp_allocator)
		best := -1
		for f, i in low {
			at := strings.index(f, lw)
			if at < 0 do continue
			s := (i == 0 ? 40 : i == 1 ? 20 : 10) + (at == 0 || !is_word_char(f[at - 1]) ? 10 : 0)
			best = max(best, s)
		}
		if best < 0 && fuzzy_name != "" {
			if s, _, hit := fuzzy_score(w, fuzzy_name); hit do best = min(s, 9) // below any substring
		}
		if best < 0 do return 0, false
		score += best
	}
	return score, true
}

@(private = "file")
is_word_char :: proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c >= 0x80}

// Settings and files matching every word of query, best first (ties: the page's order). Labels,
// hints, keywords, cards and sections; for files their names, what they are and their paths.
// Empty query: nothing. rows: settings_file_rows() (nil: read now). deep: also every file inside
// the listed folders and the project's .pi/ (settings_scan_files), as the old tab's filter found them.
settings_search :: proc(query: string, rows: []Settings_File_Row = nil, deep := false) -> []Settings_Hit {
	out := make([dynamic]Settings_Hit, context.temp_allocator)
	words := strings.fields(query, context.temp_allocator)
	if len(words) == 0 do return out[:]
	for &s, i in SETTINGS {
		choices := make([dynamic]string, context.temp_allocator)
		for c in s.choices do append(&choices, c.name)
		names := strings.join(choices[:], " ", context.temp_allocator)
		if sc, ok := settings_match(words, {setting_label(&s), s.keywords, s.hint, names, s.card, SETTING_SECTION_NAMES[s.section]}); ok {
			append(&out, Settings_Hit{kind = .Setting, setting = &s, section = s.section, card = s.card, score = sc, order = i})
		}
	}
	list := rows
	if list == nil do list = settings_file_rows()
	cwd := settings_project_cwd()
	for r, i in list {
		sec, card, known := settings_group_section(r.group)
		if !known do continue
		group := settings_group_label(r.group, cwd)
		if settings_setting_row(r.path) {
			// a list's row: its own words, and its setting's
			st := setting_for_row(r.path)
			extra := st != nil ? strings.concatenate({setting_label(st), " ", st.keywords}, context.temp_allocator) : ""
			if sc, ok := settings_match(words, {r.label, r.detail, group, extra}); ok {
				append(&out, Settings_Hit{kind = .Row, setting = st, row = r, section = sec, card = card, score = sc, order = len(SETTINGS) + i})
			}
			continue
		}
		base := filepath.base(r.path)
		if sc, ok := settings_match(words, {r.label, base, r.detail, group, fs_display(r.path), card, SETTING_SECTION_NAMES[sec], "file"}, base); ok {
			append(&out, Settings_Hit{kind = .File, row = r, section = sec, card = card, score = sc, order = len(SETTINGS) + i})
		}
	}
	if deep {
		listed := make(map[string]bool, context.temp_allocator)
		for r in list do listed[r.path] = true
		for f, i in settings_scan_files(list, cwd) {
			if listed[f] do continue
			// in which listed folder (its group), else the project's .pi/
			r := Settings_File_Row{group = "project", path = f, exists = true}
			for x in list do if x.kind == .Folder && strings.has_prefix(f, strings.concatenate({x.path, "/"}, context.temp_allocator)) {
				r.group = x.group
				r.label = strings.concatenate({x.label, f[len(x.path):]}, context.temp_allocator)
			}
			if r.label == "" do r.label = cwd != "" && strings.has_prefix(f, cwd) ? f[len(cwd) + 1:] : filepath.base(f)
			sec, card, _ := settings_group_section(r.group)
			base := filepath.base(f)
			if sc, ok := settings_match(words, {r.label, base, fs_display(f), card, SETTING_SECTION_NAMES[sec], "file"}, base); ok {
				append(&out, Settings_Hit{kind = .File, row = r, section = sec, card = card, score = sc, order = len(SETTINGS) + len(list) + i})
			}
		}
	}
	slice.sort_by(out[:], proc(a, b: Settings_Hit) -> bool {
		if a.score != b.score do return a.score > b.score
		return a.order < b.order
	})
	return out[:]
}
