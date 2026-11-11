package core

// Settings as files: the left column's Settings tab (⌘, the gear's "Edit
// settings files…", the palette) shows pi's settings files as a tree in
// fixed groups, drawn and driven by the Files tab's code (ui_files.odin):
//
//   pi (global)   the agent folder's settings files, by an allowlist
//                 (SETTINGS_PI_FILES; the instructions file by the name pi
//                 reads) and the folders prompts/, skills/, extensions/
//                 (SETTINGS_FOLDERS), which open like the Files tab's.
//                 Nothing else of the agent folder shows: not sessions/,
//                 npm/, git/, bin/, logs or pi's sign-ins.
//   This project  the session on screen's project (none for Chats): the
//                 contents of its .pi/ folder and its instructions file; a
//                 missing .pi/settings.json or instructions file is dimmed
//                 with a Create button (made only on that click, never over
//                 a file: O_EXCL)
//   Extensions    each extension's config file(s) and its folder
//
// A click opens a file in an editor tab of the session on screen (a preview,
// as in the Files tab). Nothing here edits settings: the editor does, with
// two guards:
//
//   - credential files (pi's sign-ins, other private files in the agent dir,
//     .env) are never shown, also not inside an opened folder, and the
//     editor refuses to open them at all (settings_credential;
//     editor_commands.odin, editor_file.odin)
//   - a JSON settings file pi reads (settings_json_kind) is saved only when
//     pi can read it; the error says the line and column (Save_File)
//
// The row menu renames and deletes only inside prompts/, skills/,
// extensions/ (settings_editable) and a project's .pi/, never pi's own
// config files. The agent folder is outside every project, so it is not
// watched (watching is recursive): settings_poll looks at the shown folders'
// times every EDITOR_POLL while the tab shows. After a pi settings file is
// saved, the hot-reload bar (reload.odin, ui_reload.odin) offers to reload
// the running pi tabs (pi reads its settings at start or on /reload).

import "core:encoding/json"
import jg "../jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// pi's agent directory: PI_CODING_AGENT_DIR, else ~/.pi/agent. As pi reads it (getAgentDir,
// expandTildePath): "~" is the home folder, "~/x" under it; a relative one (pi would take it from
// its cwd, which differs per tab) falls back to ~/.pi/agent.
pi_agent_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	d := os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	if d == "~" do d = home
	else if strings.has_prefix(d, "~/") do d = strings.concatenate({strings.trim_right(home, "/"), d[1:]}, context.temp_allocator)
	if d != "" && strings.has_prefix(d, "/") do return d
	return strings.concatenate({home, "/.pi/agent"}, context.temp_allocator)
}

CREDENTIAL_REFUSED :: "credentials file: managed by pi (/login), not opened"

// Config files of the agent dir that are never credentials by their mode
// alone (pi may create them 0600 too).
@(private = "file")
AGENT_CONFIG_FILES :: [?]string{"settings.json", "models.json", "keybindings.json", "mcp.json", "modes.json", "AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD", "SYSTEM.md", "APPEND_SYSTEM.md"}

// A file Deckhand never lists, reads or opens: pi's sign-ins (auth.json,
// models-store.json, cursor-sdk*.json, intercom/), any other private (no
// group/other access, e.g. 0600) file in the agent dir (any depth; not
// pi's own config files at its top), .env files anywhere (.env.example and
// the like are fine), and any other name for those sign-in files (a
// symlink, a hard link: the same device and inode).
// ids: credential_ids() when checking many paths (nil: read now).
settings_credential :: proc(path: string, ids: []Cred_Id = nil) -> bool {
	if path == "" do return false
	check :: proc(p: string) -> bool {
		base := filepath.base(p)
		if base == ".env" do return true
		if strings.has_prefix(base, ".env.") {
			switch base {
			case ".env.example", ".env.sample", ".env.template", ".env.dist": return false
			}
			return true
		}
		for ad in ([2]string{pi_agent_dir(), fs_real(pi_agent_dir())}) {
			ad := strings.trim_right(ad, "/")
			if ad == "" || !strings.has_prefix(p, strings.concatenate({ad, "/"}, context.temp_allocator)) do continue
			rel := p[len(ad) + 1:]
			if rel == "intercom" || strings.has_prefix(rel, "intercom/") do return true
			if !strings.contains(rel, "/") {
				if rel == "auth.json" || rel == "models-store.json" do return true
				if strings.has_prefix(rel, "cursor-sdk") && strings.has_suffix(rel, ".json") do return true
				for c in AGENT_CONFIG_FILES do if rel == c do return false
			}
			if k, st := path_stat(p); k == .File && st.mode & 0o077 == 0 do return true
		}
		return claude_credential(p) // Claude Code's credentials, account state, transcripts (claude_reload.odin)
	}
	clean, _ := filepath.clean(path, context.temp_allocator)
	if check(clean) || check(fs_real(clean)) do return true
	if k, st := path_stat(clean); k == .File do return credential_inode(st.dev, st.inode, ids)
	return false
}

Cred_Id :: struct {
	dev, inode: u64,
}

// The device and inode of each of pi's sign-in files now.
credential_ids :: proc() -> []Cred_Id {
	out := make([dynamic]Cred_Id, context.temp_allocator)
	ad := pi_agent_dir()
	add :: proc(out: ^[dynamic]Cred_Id, p: string) {
		if k, st := path_stat(p); k == .File do append(out, Cred_Id{st.dev, st.inode})
	}
	add(&out, fmt.tprintf("%s/auth.json", ad))
	add(&out, fmt.tprintf("%s/models-store.json", ad))
	for p in claude_credential_files() do add(&out, p) // .credentials.json, .claude.json
	for dir in ([2]string{ad, fmt.tprintf("%s/intercom", ad)}) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do continue
		for e in entries {
			if dir == ad && !(strings.has_prefix(e.name, "cursor-sdk") && strings.has_suffix(e.name, ".json")) do continue
			add(&out, fmt.tprintf("%s/%s", dir, e.name))
		}
	}
	return out[:]
}

// The device and inode of a file opened or about to be: one of pi's
// sign-in files under another name (disk_read checks the open file, so a
// swap after the path check is caught too). ids: as settings_credential.
credential_inode :: proc(dev, inode: u64, ids: []Cred_Id = nil) -> bool {
	list := ids
	if list == nil do list = credential_ids()
	for c in list do if c.dev == dev && c.inode == inode do return true
	return false
}

// ---- the list ----

Settings_File_Kind :: enum u8 {
	File,
	Folder, // opens in the tree
}

Settings_File_Row :: struct {
	group:  string, // "pi", "project", "ext"
	label:  string,
	detail: string, // what it is
	path:   string,
	kind:   Settings_File_Kind,
	exists: bool,
	create: bool, // missing: a Create button makes it (a project's files)
	seed:   string, // what Create writes
	pi:     bool, // pi reads it at start: saving it shows the hot-reload bar (reload.odin)
	button: string, // not a file: a setting shown as text (note) with this button (ATLAS_MODEL_ROW)
	reset:  bool, // a folder row (folders.odin): a Reset button (back to the default)
	reveal: bool, // a folder row: a Reveal in Finder button
	remove: bool, // a Claude account's row (claude_accounts.odin): a Remove button
	make_default: bool, // a Claude account's row: a Make default button
}

// The Settings tab's Claude accounts group (claude_accounts.odin): an account's row is
// CLAUDE_ACCOUNT_ROW + its folder (Rename…, Remove); the last row adds one (a folder picker).
CLAUDE_ACCOUNT_ROW :: "deckhand:claude-account:"
CLAUDE_ACCOUNT_ADD_ROW :: "deckhand:claude-account-add"
CLAUDE_ACCOUNT_SCAN_ROW :: "deckhand:claude-account-scan"
CLAUDE_ACCOUNT_MORE_ROW :: "deckhand:claude-account-more"


// The Settings tab's Atlas group: its model is a row that is no file; its
// button opens pi's model selector in Atlas's terminal.
ATLAS_MODEL_ROW :: "deckhand:atlas-model"

// The Claude Code group's default flags for new tabs (Set_Claude_Default_Flags): the setting's
// row (what is on), the flag's toggle row and its warning line.
CLAUDE_FLAGS_HEAD_ROW :: "deckhand:claude-default-flags-head"
CLAUDE_FLAGS_ROW :: "deckhand:claude-default-flags"
CLAUDE_FLAGS_WARN_ROW :: "deckhand:claude-default-flags-warning"

// The Machines group (machines.odin; Settings › Machines over SSH on, or other
// machines allowed in): a machine's row is MACHINE_ROW + its number (Connect / Take back, Remove);
// then a row adds one, and the last allows other machines to connect to this one (the hub door).
MACHINE_ROW :: "deckhand:machine:"
MACHINE_ADD_ROW :: "deckhand:machine-add"
MACHINE_REACH_ROW :: "deckhand:machine-reachable"
// Its coding agents (its core's checklist, read-only here): MACHINE_CHECK_ROW + no + ":" + item id,
// with Copy (the command, run in a shell tab there).
MACHINE_CHECK_ROW :: "deckhand:machine-check:"

// A machine checklist row's machine and item (ok false: not one).
machine_check_row :: proc(path: string) -> (no: u64, id: string, ok: bool) {
	if !strings.has_prefix(path, MACHINE_CHECK_ROW) do return 0, "", false
	rest := path[len(MACHINE_CHECK_ROW):]
	i := strings.index_byte(rest, ':')
	if i < 0 do return 0, "", false
	n, nok := strconv.parse_u64(rest[:i], 10)
	return n, rest[i + 1:], nok
}

// A machine row's number (ok false: not one).
machine_row_no :: proc(path: string) -> (no: u64, ok: bool) {
	if !strings.has_prefix(path, MACHINE_ROW) do return 0, false
	n, nok := strconv.parse_u64(path[len(MACHINE_ROW):], 10)
	return n, nok
}

// The pi extensions group (pi_integration.odin): one row per optional extension of Deckhand's pi
// integration, PI_EXT_ROW + its name, with a Turn on / Turn off button (Set_Pi_Extension).
PI_EXT_ROW :: "deckhand:pi-extension:"

// A row that is a setting, not a file.
settings_setting_row :: proc(path: string) -> bool {return strings.has_prefix(path, "deckhand:")}

// The folders of pi's agent folder the tree shows (and that open).
SETTINGS_FOLDERS :: [?]string{"prompts", "skills", "extensions"}

// The folders of Claude Code's config folder the tree shows (and that open; never anything else
// of that folder: claude_credential).
CLAUDE_SETTINGS_FOLDERS :: [?]struct {
	name, detail: string,
}{{"agents", "subagents"}, {"skills", "skills"}, {"commands", "slash commands"}, {"output-styles", "output styles"}, {"rules", "rules"}}

// pi's agent folder as written, cleaned (the tree's paths start here).
settings_agent_dir :: proc() -> string {
	d, _ := filepath.clean(pi_agent_dir(), context.temp_allocator)
	return d
}

// The project the tree shows: the session on screen's ("" = none, Home,
// or a chat).
settings_project_cwd :: proc() -> string {
	if cs := cur(); cs != nil && !cs.home {
		if p := find_project(cs.project_id); p != nil && p.group == .Projects do return p.cwd
	}
	return ""
}

// The settings files and folders at the top of the tree, in order (temp
// allocator); credential files never. Only what is there, or what may be
// made (Create).
settings_file_rows :: proc() -> []Settings_File_Row {
	out := make([dynamic]Settings_File_Row, context.temp_allocator)
	ad := settings_agent_dir()
	j :: proc(a, b: string) -> string {return strings.concatenate({a, "/", b}, context.temp_allocator)}
	add :: proc(out: ^[dynamic]Settings_File_Row, r: Settings_File_Row) {
		if settings_credential(r.path) do return
		row := r
		k := path_kind(r.path)
		row.exists = r.kind == .Folder ? k == .Dir : k == .File
		if r.button != "" || settings_setting_row(r.path) do row.exists = true
		if !row.exists && !row.create do return
		for x in out do if x.path == row.path do return
		append(out, row)
	}
	// pi's groups only with pi installed (harness.odin): someone with Claude Code alone sees none
	if pi_installed() {
		add(&out, {group = "pi", label = "settings.json", detail = "model, theme, packages…", path = j(ad, "settings.json"), pi = true})
		add(&out, {group = "pi", label = "models.json", detail = "may hold API keys", path = j(ad, "models.json"), pi = true})
		add(&out, {group = "pi", label = "modes.json", detail = "modes", path = j(ad, "modes.json"), pi = true})
		add(&out, {group = "pi", label = "keybindings.json", detail = "pi's keys", path = j(ad, "keybindings.json"), pi = true})
		add(&out, {group = "pi", label = "mcp.json", detail = "MCP servers (may hold tokens)", path = j(ad, "mcp.json"), pi = true})
		if name := context_file(ad); name != "" do add(&out, {group = "pi", label = name, detail = "instructions for every project", path = j(ad, name), pi = true})
		add(&out, {group = "pi", label = "SYSTEM.md", detail = "replaces pi's system prompt", path = j(ad, "SYSTEM.md"), pi = true})
		add(&out, {group = "pi", label = "APPEND_SYSTEM.md", detail = "added to pi's system prompt", path = j(ad, "APPEND_SYSTEM.md"), pi = true})
		add(&out, {group = "pi", label = "prompts", detail = "prompt templates", path = j(ad, "prompts"), kind = .Folder})
		add(&out, {group = "pi", label = "skills", detail = "skills", path = j(ad, "skills"), kind = .Folder})
		add(&out, {group = "pi", label = "extensions", detail = "local extensions", path = j(ad, "extensions"), kind = .Folder})
		// Deckhand's optional pi extensions: on or off for the pi tabs started from now on
		for e in pi_integration_optional() {
			add(&out, {group = "pi-ext", label = e.name, detail = fmt.tprintf("%s · %s (default %s; pi tabs, not jobs)", e.on ? "ON" : "off", e.does, e.default_on ? "on" : "off"), path = strings.concatenate({PI_EXT_ROW, e.name}, context.temp_allocator), button = e.on ? "Turn off" : "Turn on"})
		}
		if cwd := settings_project_cwd(); cwd != "" {
			add(&out, {group = "project", label = ".pi/settings.json", detail = "overrides pi's settings here", path = j(cwd, ".pi/settings.json"), create = true, seed = "{}\n", pi = true})
			if name := context_file(cwd); name != "" do add(&out, {group = "project", label = name, detail = "this project's instructions", path = j(cwd, name), pi = true})
			else do add(&out, {group = "project", label = "AGENTS.md", detail = "this project's instructions", path = j(cwd, "AGENTS.md"), create = true, seed = "", pi = true})
		}
		for c in extension_configs() do add(&out, {group = "ext", label = c.label, detail = c.detail, path = c.path, kind = c.folder ? .Folder : .File, pi = !c.folder})
	}
	// Claude Code (claude_reload.odin), once it has a config folder here (it has been used): its
	// config only, never its credentials or state (.credentials.json, ~/.claude.json, projects/,
	// sessions…: claude_credential refuses them)
	// one group per account (claude_accounts.odin) once there are several
	claude_used := false
	accts := claude_accounts()
	for a in accts {
		cd := a.dir
		if !os.is_dir(cd) do continue
		claude_used = true
		g := len(accts) > 1 ? strings.concatenate({"claude:", a.label}, context.temp_allocator) : "claude"
		add(&out, {group = g, label = "settings.json", detail = "permissions, hooks, env, model (applied live)", path = j(cd, "settings.json")})
		add(&out, {group = g, label = "CLAUDE.md", detail = "instructions for every project", path = j(cd, "CLAUDE.md"), create = true, seed = ""})
		add(&out, {group = g, label = "keybindings.json", detail = "Claude Code's keys", path = j(cd, "keybindings.json")})
		for f in CLAUDE_SETTINGS_FOLDERS do add(&out, {group = g, label = f.name, detail = f.detail, path = j(cd, f.name), kind = .Folder})
	}
	// the default flags for the Claude tabs the user starts (claude_with_defaults): off by default
	if claude_used {
		on := state.settings.claude_skip_permissions
		add(&out, {group = "claude", label = "Default flags for new tabs", detail = on ? "--dangerously-skip-permissions" : "none", path = CLAUDE_FLAGS_HEAD_ROW})
		add(&out, {group = "claude", label = "Skip permissions", detail = on ? "ON" : "off", path = CLAUDE_FLAGS_ROW, button = on ? "Turn off" : "Turn on"})
		add(&out, {group = "claude", label = "Warning:", detail = on ? "Claude acts without asking" : "on, Claude acts without asking", path = CLAUDE_FLAGS_WARN_ROW})
	}
	if cwd := settings_project_cwd(); cwd != "" && claude_used {
		add(&out, {group = "claude-project", label = ".claude/settings.json", detail = "the project's Claude Code settings (shared)", path = j(cwd, ".claude/settings.json"), create = true, seed = "{}\n"})
		add(&out, {group = "claude-project", label = ".claude/settings.local.json", detail = "your settings here (not committed)", path = j(cwd, ".claude/settings.local.json")})
		add(&out, {group = "claude-project", label = "CLAUDE.md", detail = "this project's instructions for Claude", path = j(cwd, "CLAUDE.md"), create = true, seed = ""})
		add(&out, {group = "claude-project", label = "CLAUDE.local.md", detail = "your instructions here (not committed)", path = j(cwd, "CLAUDE.local.md")})
		add(&out, {group = "claude-project", label = ".mcp.json", detail = "the project's MCP servers (may hold tokens)", path = j(cwd, ".mcp.json")})
	}
	// Atlas (agent.odin): its prompt file (made on its first start; Create
	// writes the starter), its model
	if p := agent_prompt_path(); p != "" && pi_installed() {
		add(&out, {group = "atlas", label = ATLAS_PROMPT_FILE, detail = "Atlas's prompt, added to pi's", path = p, create = true, seed = ATLAS_PROMPT_STARTER})
		m := agent_model()
		add(&out, {group = "atlas", label = "Model", detail = m != "" ? m : "pi's default", path = ATLAS_MODEL_ROW, button = "Change…"})
		if ad := folder_of(.Atlas); ad != "" {
			hb := fmt.tprintf("%s/HEARTBEAT.md", ad)
			if path_kind(hb) == .File do add(&out, {group = "atlas", label = "HEARTBEAT.md", detail = "the heartbeat's checklist", path = hb})
		}
		// the job notes (jobs.odin)
		if jd := folder_of(.Jobs); jd != "" {
			entries, _ := os.read_all_directory_by_path(jd, context.temp_allocator)
			slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
			for e in entries do if e.type == .Regular && strings.has_suffix(e.name, ".md") && !strings.has_prefix(e.name, ".") {
				add(&out, {group = "jobs", label = fmt.tprintf("jobs/%s", e.name), detail = "a job note (runs on its schedule while Deckhand is open)", path = e.fullpath})
			}
		}
	}
	// Chats: their instructions file (folders.odin; pi reads it in the chats folder)
	{
		d := chats_cwd()
		name := context_file(d)
		if name == "" do name = "AGENTS.md"
		add(&out, {group = "chats", label = fmt.tprintf("Chat instructions (%s)", name), detail = "how pi talks in chats", path = fmt.tprintf("%s/%s", d, name), create = true, seed = CHATS_AGENTS_STARTER})
	}
	// Folders (folders.odin): the main folder, each subfolder (default or custom)
	{
		h := state.settings.home_dir
		add(&out, {group = "folders", label = "Main folder", detail = h != "" ? fs_display(h) : "not set", path = FOLDER_MAIN_ROW, button = h != "" ? "Change…" : "Set up…", reveal = h != "" && os.is_dir(h)})
		for k in Folder_Kind {
			p := folder_of(k)
			custom := folder_custom(k)
			detail := p == "" ? "no main folder" : fmt.tprintf("%s · %s", custom ? "custom" : "default", fs_display(p))
			add(&out, {group = "folders", label = fmt.tprintf("%s/", FOLDER_NAMES[k]), detail = detail, path = folder_row_path(k), button = "Change…", reset = custom, reveal = p != "" && os.is_dir(p)})
		}
		if prev := state.home_dir_prev; prev != "" && os.is_dir(prev) do add(&out, {group = "folders", label = "Old main folder", detail = fmt.tprintf("%s (nothing moved)", fs_display(prev)), path = FOLDER_PREV_ROW, button = "Reveal"})
		if u := notes_env_user(); u != "" do add(&out, {group = "folders", label = "PI_KIT_NOTES_DIR", detail = fmt.tprintf("yours: %s (pi-kit's notes go there)", fs_display(u)), path = FOLDER_ENV_ROW})
	}
	// Claude Code's accounts (claude_accounts.odin), last: the accounts themselves: each one's row once there are several, and Add account… (a
	// config folder anywhere) once Claude Code has a config folder
	if claude_used {
		if len(accts) > 1 do for a in accts {
			what := a.chosen ? "default" : a.default ? "your shell's" : CLAUDE_ACCOUNT_SOURCE_NAMES[a.source]
			add(&out, {group = "claude-accounts", label = a.label, detail = fmt.tprintf("%s · %s", fs_display(a.dir), what), path = strings.concatenate({CLAUDE_ACCOUNT_ROW, a.dir}, context.temp_allocator), button = "Rename…", remove = !a.default, make_default = !a.chosen})
		}
		if len(accts) > 1 {
			add(&out, {group = "claude-accounts", label = "Add account…", detail = "a Claude Code config folder (CLAUDE_CONFIG_DIR)", path = CLAUDE_ACCOUNT_ADD_ROW, button = "Add…"})
			add(&out, {group = "claude-accounts", label = "Scan again", detail = "look for config folders in ~/.claude*, ~/.config/claude*", path = CLAUDE_ACCOUNT_SCAN_ROW, button = "Scan"})
		} else {
			// one account (most setups): one quiet row
			add(&out, {group = "claude-accounts", label = "More accounts…", detail = "another Claude Code config folder", path = CLAUDE_ACCOUNT_MORE_ROW, button = "Add…"})
		}
	}
	// Coding agents (ui_harness.odin): the harness checklist's states; Install…/Update… open the sheet
	for r in harness_settings_rows() do add(&out, r)
	// Machines over SSH (machines.odin), while the experimental setting is on (or this machine
	// lets others in: the row that turns it off stays)
	if state.settings.remote_machines || state.settings.machines_reachable {
		if state.settings.remote_machines do for m in state.machines {
			detail := fmt.tprintf("%s · %s", m.target != "" ? m.target : "via", MACHINE_STATUS_NAMES[m.status])
			if m.status == .Online && m.version != "" do detail = fmt.tprintf("%s %s", detail, m.version)
			if m.error != "" do detail = fmt.tprintf("%s: %s", detail, m.error)
			if m.job != .None do detail = fmt.tprintf("%s · %s%s%s", detail, MACHINE_JOB_NAMES[m.job], m.job_note != "" ? ": " : "", m.job_note)
			if m.linger == .Off do detail = fmt.tprintf("%s · linger is off: its jobs stop when you log out of it", detail)
			button := machine_row_button(m)
			add(&out, {group = "machines", label = m.name, detail = detail, path = fmt.tprintf("%s%d", MACHINE_ROW, m.no), button = button, remove = true})
			for c in m.checklist {
				r, _ := harness_row(c.id)
				add(&out, {group = "machines", label = fmt.tprintf("%s: %s", m.name, r.name), detail = fmt.tprintf("%s%s%s", HARNESS_STATE_NAMES[c.state], c.command != "" ? " · " : "", c.command), path = fmt.tprintf("%s%d:%s", MACHINE_CHECK_ROW, m.no, c.id), button = c.command != "" ? "Copy" : ""})
			}
		}
		if state.settings.remote_machines do add(&out, {group = "machines", label = "Add machine…", detail = "an ~/.ssh/config alias or user@host", path = MACHINE_ADD_ROW, button = "Add…"})
		reach := state.settings.machines_reachable
		detail := reach ? "on: another machine that logs in here over ssh as you can view and drive this one's sessions" : "off: no other machine can reach this one's sessions"
		add(&out, {group = "machines", label = "Allow other machines to connect to this one", detail = detail, path = MACHINE_REACH_ROW, button = reach ? "Turn off" : "Allow"})
	}
	return out[:]
}

// A machine row's button in Settings: Cancel while its install runs, Install… / Update (M6-E),
// Keep running… (Linux linger off), Take back, Connect.
machine_row_button :: proc(m: Machine_View) -> string {
	#partial switch m.job {
	case .Fetching, .Verifying, .Copying, .Handing_Over: return "Cancel"
	case .Cleaning: return ""
	}
	if m.update != .None do return "Update"
	#partial switch m.status {
	case .Not_Installed: return "Install…"
	case .Taken:         return "Take back"
	case .Online:        return m.linger == .Off ? "Keep running…" : ""
	case .Connecting:    return ""
	}
	return "Connect"
}

// The instructions file pi reads in dir: the first of these that is a
// file (pi 1.4: dist/core/resource-loader.js, loadContextFileFromDir), or "".
context_file :: proc(dir: string) -> string {
	for name in ([]string{"AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"}) {
		if path_kind(strings.concatenate({dir, "/", name}, context.temp_allocator)) == .File do return name
	}
	return ""
}

@(private = "file")
Ext_Config :: struct {
	label, detail, path: string,
	folder:              bool, // the extension's own folder in the agent folder
}

// Extensions' own config files and local folders: for each package in settings.json (and
// each local extension), a config.json under <agent dir>/extensions/<name>/
// or ~/.config/<name>/ if there is one. Names: the package's without its
// scope, also without a "pi-" prefix and a trailing "s"
// (pi-subagents -> extensions/subagent/config.json). Extensions that only
// read environment variables have nothing to list.
@(private = "file")
extension_configs :: proc() -> []Ext_Config {
	out := make([dynamic]Ext_Config, context.temp_allocator)
	ad := settings_agent_dir()
	home := os.get_env("HOME", context.temp_allocator)
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if xdg == "" do xdg = fmt.tprintf("%s/.config", home)
	names := make([dynamic]string, context.temp_allocator)
	for p in settings_packages() {
		n := p
		if i := strings.last_index_byte(n, '/'); i >= 0 do n = n[i + 1:]
		append(&names, n)
	}
	if entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/extensions", ad), context.temp_allocator); err == nil {
		for e in entries do if e.type == .Directory && !strings.has_prefix(e.name, ".") do append(&names, e.name)
	}
	for n in names {
		variants := make([dynamic]string, context.temp_allocator)
		append(&variants, n)
		if strings.has_prefix(n, "pi-") do append(&variants, n[3:])
		for v in variants[:] do if strings.has_suffix(v, "s") do append(&variants, v[:len(v) - 1])
		for v in variants {
			for c in ([]string{fmt.tprintf("%s/extensions/%s/config.json", ad, v), fmt.tprintf("%s/%s/config.json", xdg, v)}) {
				if path_kind(c) != .File do continue
				dup := false
				for x in out do if x.path == c do dup = true
				if !dup do append(&out, Ext_Config{label = fmt.tprintf("%s config", n), detail = "the extension's own settings", path = c})
			}
		}
		// its folder, when it is a local one (packages live in npm/ and git/, not shown)
		for v in variants {
			d := fmt.tprintf("%s/extensions/%s", ad, v)
			if path_kind(d) != .Dir do continue
			dup := false
			for x in out do if x.path == d do dup = true
			if !dup do append(&out, Ext_Config{label = v, detail = "extension folder", path = d, folder = true})
		}
	}
	return out[:]
}

// Package names from settings.json's packages (npm:@x/name@1 -> @x/name;
// git and local sources -> their last path part). Read only.
@(private = "file")
settings_packages :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	path := fmt.tprintf("%s/settings.json", pi_agent_dir())
	if k, st := path_stat(path); k != .File || st.size > 4 << 20 do return out[:]
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return out[:]
	v, jerr := jg.parse(data, .JSON5, true, context.temp_allocator)
	if jerr != nil do return out[:]
	root, _ := v.(json.Object)
	list, _ := root["packages"].(json.Array)
	for it in list {
		src: string
		#partial switch x in it {
		case json.String: src = string(x)
		case json.Object: src, _ = x["source"].(json.String)
		}
		if src == "" do continue
		name := src
		switch {
		case strings.has_prefix(src, "npm:"):
			name = src[4:]
			if at := strings.last_index_byte(name, '@'); at > 0 do name = name[:at]
		case:
			if i := strings.index(name, ":"); i >= 0 && !strings.has_prefix(name, "/") do name = name[i + 1:]
			if at := strings.last_index_byte(name, '@'); at > 0 do name = name[:at]
			name = strings.trim_suffix(filepath.base(strings.trim_right(name, "/")), ".git")
		}
		append(&out, name)
	}
	return out[:]
}

// ---- JSON check on save ----

// How pi reads a JSON settings file, so a save is refused only when pi
// would fail to read it (pi 1.4: dist/core/model-config.js,
// settings-manager.js, keybindings.js, extensions/mcp/config.js).
Json_Kind :: enum u8 {
	None, // not checked: pi does not read it, or the reader is unknown (extensions' files, modes.json)
	Strict, // JSON.parse after a BOM: settings.json, keybindings.json, mcp.json, a project's .pi/settings.json
	Comments, // stripJsonComments first (// comments, trailing commas): models.json
}

settings_json_kind :: proc(path: string) -> Json_Kind {
	rp := fs_real(path)
	ad := fs_real(pi_agent_dir())
	for name in ([]string{"settings.json", "keybindings.json", "mcp.json", "models.json"}) {
		if rp == strings.concatenate({ad, "/", name}, context.temp_allocator) do return name == "models.json" ? .Comments : .Strict
	}
	if strings.has_suffix(rp, "/.pi/settings.json") do return .Strict
	// Claude Code's settings files are strict JSON (its docs: a comment or a trailing comma is a
	// Settings Error at the next start)
	for d in claude_account_dirs() do if cd := fs_real(d); cd != "" {
		for name in ([]string{"settings.json", "keybindings.json"}) do if rp == strings.concatenate({cd, "/", name}, context.temp_allocator) do return .Strict
	}
	if strings.has_suffix(rp, "/.claude/settings.json") || strings.has_suffix(rp, "/.claude/settings.local.json") do return .Strict
	return .None
}

// "" when text is one valid JSON value, else what is wrong and where (line
// and column, 1-based). As pi reads it: a leading BOM is dropped, then
// strict JSON.parse; with comments, pi's stripJsonComments runs first
// (// to the end of the line and a comma before } or ], outside strings).
json_check :: proc(text: string, comments := false) -> string {
	Chk :: struct {
		t:     string,
		i:     int,
		err:   string,
		depth: int,
	}
	body := strings.trim_prefix(text, "\xef\xbb\xbf")
	c := Chk{t = comments ? strip_json_comments(body) : body}
	ws :: proc(c: ^Chk) {for c.i < len(c.t) && (c.t[c.i] == ' ' || c.t[c.i] == '\t' || c.t[c.i] == '\n' || c.t[c.i] == '\r') do c.i += 1}
	bad :: proc(c: ^Chk, what: string) {if c.err == "" do c.err = what}
	str :: proc(c: ^Chk) {
		c.i += 1
		for c.i < len(c.t) {
			ch := c.t[c.i]
			if ch == '"' {
				c.i += 1
				return
			}
			if ch < 0x20 {
				bad(c, "a control character in a string")
				return
			}
			if ch == '\\' {
				if c.i + 1 >= len(c.t) do break
				e := c.t[c.i + 1]
				if strings.index_byte(`"\/bfnrtu`, e) < 0 {
					bad(c, "a bad escape in a string")
					return
				}
				c.i += 2
				continue
			}
			c.i += 1
		}
		bad(c, "a string that never ends")
	}
	value :: proc(c: ^Chk) {
		ws(c)
		if c.err != "" do return
		if c.i >= len(c.t) {
			bad(c, "unexpected end of the file")
			return
		}
		ch := c.t[c.i]
		switch {
		case ch == '{' || ch == '[':
			c.depth += 1
			if c.depth > 256 {
				bad(c, "nested too deeply")
				return
			}
			obj := ch == '{'
			close: u8 = obj ? '}' : ']'
			c.i += 1
			ws(c)
			if c.i < len(c.t) && c.t[c.i] == close {
				c.i += 1
				c.depth -= 1
				return
			}
			for c.err == "" {
				if obj {
					ws(c)
					if c.i >= len(c.t) || c.t[c.i] != '"' {
						bad(c, c.i < len(c.t) && c.t[c.i] == '}' ? "a comma before }" : "expected a key in double quotes")
						return
					}
					str(c)
					ws(c)
					if c.i >= len(c.t) || c.t[c.i] != ':' {
						bad(c, "expected ':' after the key")
						return
					}
					c.i += 1
				}
				ws(c)
				if !obj && c.i < len(c.t) && c.t[c.i] == ']' {
					bad(c, "a comma before ]")
					return
				}
				value(c)
				if c.err != "" do return
				ws(c)
				if c.i < len(c.t) && c.t[c.i] == ',' {
					c.i += 1
					continue
				}
				if c.i < len(c.t) && c.t[c.i] == close {
					c.i += 1
					c.depth -= 1
					return
				}
				bad(c, obj ? "expected ',' or '}'" : "expected ',' or ']'")
				return
			}
		case ch == '"':
			str(c)
		case strings.has_prefix(c.t[c.i:], "true"):
			c.i += 4
		case strings.has_prefix(c.t[c.i:], "false"):
			c.i += 5
		case strings.has_prefix(c.t[c.i:], "null"):
			c.i += 4
		case ch == '-' || (ch >= '0' && ch <= '9'):
			j := c.i
			if c.t[j] == '-' do j += 1
			digits :: proc(t: string, j: int) -> int {
				k := j
				for k < len(t) && t[k] >= '0' && t[k] <= '9' do k += 1
				return k
			}
			k := digits(c.t, j)
			if k == j || (c.t[j] == '0' && k > j + 1) {
				bad(c, "a bad number")
				return
			}
			if k < len(c.t) && c.t[k] == '.' {
				k2 := digits(c.t, k + 1)
				if k2 == k + 1 {
					bad(c, "a bad number")
					return
				}
				k = k2
			}
			if k < len(c.t) && (c.t[k] == 'e' || c.t[k] == 'E') {
				k += 1
				if k < len(c.t) && (c.t[k] == '+' || c.t[k] == '-') do k += 1
				k2 := digits(c.t, k)
				if k2 == k {
					bad(c, "a bad number")
					return
				}
				k = k2
			}
			c.i = k
		case ch == '/':
			bad(c, "a comment (JSON has none)")
		case:
			bad(c, "unexpected character")
		}
	}
	value(&c)
	if c.err == "" {
		ws(&c)
		if c.i < len(c.t) do c.err = "more after the end of the JSON value"
	}
	if c.err == "" do return ""
	at := min(c.i, len(c.t)) // in what was checked: stripping keeps every offset
	line := strings.count(c.t[:at], "\n") + 1
	col := at - (strings.last_index_byte(c.t[:at], '\n') + 1) + 1
	return fmt.tprintf("line %d, column %d: %s", line, col, c.err)
}

// pi's stripJsonComments (utils/json.js), with spaces in place of what it
// removes so lines and columns stay put: first // comments outside
// strings, then a comma followed by blanks and } or ] outside strings.
@(private = "file")
strip_json_comments :: proc(text: string) -> string {
	b := transmute([]u8)strings.clone(text, context.temp_allocator)
	// a string as pi's regex sees it: "..." with escapes (across lines), or a lone quote
	string_end :: proc(b: []u8, i: int) -> int {
		j := i + 1
		for j < len(b) {
			switch b[j] {
			case '\\': j += 2; continue
			case '"': return j + 1
			}
			j += 1
		}
		return -1 // never closed: the quote is just a character
	}
	for pass in 0 ..< 2 {
		i := 0
		for i < len(b) {
			if b[i] == '"' {
				if e := string_end(b, i); e > 0 {
					i = e
					continue
				}
			} else if pass == 0 && b[i] == '/' && i + 1 < len(b) && b[i + 1] == '/' {
				for i < len(b) && b[i] != '\n' {
					b[i] = ' '
					i += 1
				}
				continue
			} else if pass == 1 && b[i] == ',' {
				j := i + 1
				for j < len(b) && (b[j] == ' ' || b[j] == '\t' || b[j] == '\n' || b[j] == '\r') do j += 1
				if j < len(b) && (b[j] == '}' || b[j] == ']') do b[i] = ' '
			}
			i += 1
		}
	}
	return string(b)
}

// ---- after a save: offer to reload pi ----

// Atlas's tab, when a restart (pi_reload through its bridge) can reach it.
atlas_reloadable :: proc() -> u64 {
	ht := home_tab()
	return ht != nil && ht.status == .Running && ht.agent != .Unknown ? ht.id : 0
}

// Save_File saved path (editor_commands.odin): a file pi reads at start?
// Then the hot-reload bar shows at once (reload.odin), for the pi tabs that
// read it: Atlas's prompt only Atlas, a project's file that project's.
settings_after_save :: proc(tab_id: u64, path: string) {
	claude_reload_note_save(path) // a file a running Claude reads only at start (claude_reload.odin)
	rp := fs_real(path)
	if ap := agent_prompt_path(); ap != "" && fs_real(ap) == rp {
		reload_note_save(path, RELOAD_SCOPE_ATLAS)
		return
	}
	for r in settings_file_rows() do if r.pi && fs_real(r.path) == rp {
		reload_note_save(path, r.group == "project" ? settings_project_cwd() : "")
		return
	}
}

// ---- where the tree may act ----

@(private = "file")
under :: proc(p, dir: string) -> bool {return len(p) > len(dir) && strings.has_prefix(p, dir) && p[len(dir)] == '/'}

// The root a folder of pi's prompts/, skills/ or extensions/ (or one of
// them) keeps its open state under: the agent folder as written ("" = not
// one). Lexical: the tree's paths are as written.
settings_tree_root :: proc(path: string) -> string {
	if path == "" || !filepath.is_abs(path) do return ""
	p, _ := filepath.clean(path, context.temp_allocator)
	ad := settings_agent_dir()
	for sub in SETTINGS_FOLDERS {
		d := strings.concatenate({ad, "/", sub}, context.temp_allocator)
		if p == d || under(p, d) do return ad
	}
	for cd in claude_account_dirs() do for f in CLAUDE_SETTINGS_FOLDERS {
		d := strings.concatenate({cd, "/", f.name}, context.temp_allocator)
		if p == d || under(p, d) do return cd
	}
	return ""
}

// Where the user's file commands may also act outside projects (fs_check_write):
// strictly inside pi's prompts/, skills/ or extensions/, with the real
// folder above it inside the same real folder (a symlink cannot lead out),
// and never a credentials file.
settings_editable :: proc(path: string) -> (abs: string, ok: bool) {
	if path == "" || !filepath.is_abs(path) do return "", false
	p, _ := filepath.clean(path, context.temp_allocator)
	if settings_credential(p) do return "", false
	ad := settings_agent_dir()
	rad := fs_real(ad)
	parent := fs_real(filepath.dir(p))
	for sub in SETTINGS_FOLDERS {
		d := strings.concatenate({ad, "/", sub}, context.temp_allocator)
		rd := strings.concatenate({rad, "/", sub}, context.temp_allocator)
		if under(p, d) && (parent == rd || under(parent, rd)) do return p, true
	}
	return "", false
}

// A path the tree shows that Reveal in Finder may show (the user's only).
settings_revealable :: proc(path: string) -> bool {
	if path == "" || settings_credential(path) do return false
	if path == settings_agent_dir() || settings_tree_root(path) != "" do return true
	// the Folders group's (folders.odin)
	if path == state.settings.home_dir || path == state.home_dir_prev do return true
	for k in Folder_Kind do if path == folder_of(k) do return true
	for r in settings_file_rows() do if r.exists && r.path == path do return true
	return false
}

// Whether the row menu may rename and delete path: inside prompts/,
// skills/, extensions/ (settings_editable) or a project's .pi/; never pi's
// own config files.
settings_row_editable :: proc(path: string) -> bool {
	if _, ok := settings_editable(path); ok do return true
	if cwd := settings_project_cwd(); cwd != "" do return under(path, strings.concatenate({cwd, "/.pi"}, context.temp_allocator)) && !settings_credential(path)
	return false
}

// Whether New file/New folder go in dir: pi's or the project's prompts/ and
// skills/, where the file command would allow it (fs_check_write: the real
// folder there too, so not in a skill that is a symlink to elsewhere).
settings_new_ok :: proc(dir: string) -> bool {
	if _, _, err := fs_check_write(strings.concatenate({dir, "/x"}, context.temp_allocator), {kind = .UI}); err != "" do return false
	bases := make([dynamic]string, context.temp_allocator)
	append(&bases, settings_agent_dir())
	if cwd := settings_project_cwd(); cwd != "" do append(&bases, strings.concatenate({cwd, "/.pi"}, context.temp_allocator))
	for b in bases do for sub in ([]string{"prompts", "skills"}) {
		d := strings.concatenate({b, "/", sub}, context.temp_allocator)
		if (dir == d || under(dir, d)) && path_kind(dir) == .Dir do return true
	}
	return false
}

// The open folders inside the project's .pi/ (they live in the project's tree).
settings_open_pi_dirs :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	cwd := settings_project_cwd()
	if cwd == "" do return out[:]
	pi := strings.concatenate({cwd, "/.pi"}, context.temp_allocator)
	root, rel := files_expand_key(pi)
	if root == "" do return out[:]
	for d in files_expanded_dirs(root) {
		if d == rel || (strings.has_prefix(d, rel) && d[len(rel)] == '/') do append(&out, strings.concatenate({root, "/", d}, context.temp_allocator))
	}
	return out[:]
}

// ---- the tree's rows ----

// Bumped when the poll sees a change in a shown folder (the rows are rebuilt).
settings_gen: u64
@(private = "file")
sf_built_gen: u64
@(private = "file")
sf_ids: []Cred_Id // the sign-in files' ids, read once per rebuild
@(private = "file")
sf_has_ids: bool

// The last Create's error (owned), shown over the tree.
sf_error: string

// A credential file the tree leaves out (files_walk; settings_credential).
settings_hidden :: proc(path: string) -> bool {
	if !sf_has_ids {
		sf_ids, sf_has_ids = credential_ids(), true
	}
	return settings_credential(path, sf_ids)
}

settings_group_label :: proc(group, cwd: string) -> string {
	switch group {
	case "pi":      return "pi (global)"
	case "project": return fmt.tprintf("This project · %s", filepath.base(cwd))
	case "ext":     return "Extensions"
	case "pi-ext":  return "pi extensions (Deckhand's)"
	case "atlas":   return agent_name()
	case "jobs":    return fmt.tprintf("%s's jobs", agent_name())
	case "chats":   return "Chats"
	case "folders": return "Folders"
	case "claude":  return "Claude Code (global)"
	case "claude-accounts": return "Claude accounts"
	case "agents":  return "Coding agents"
	case "machines": return "Machines (experimental)"
	case "claude-project": return fmt.tprintf("Claude Code · %s", filepath.base(cwd))
	}
	if strings.has_prefix(group, "claude:") do return fmt.tprintf("Claude Code · %s (global)", group[len("claude:"):])
	return group
}

@(private = "file")
sf_model: string // the model the rows were built with
@(private = "file")
sf_machines: string // ...and the machines (settings_machines_key)

@(private = "file")
settings_machines_key :: proc() -> string {
	if !state.settings.remote_machines && !state.settings.machines_reachable do return ""
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%v%v;", state.settings.remote_machines, state.settings.machines_reachable)
	for m in state.machines {
		fmt.sbprintf(&b, "%d|%s|%v|%s|%s|%v|%s|%v|%v;", m.no, m.name, m.status, m.version, m.error, m.job, m.job_note, m.update, m.linger)
		for c in m.checklist do fmt.sbprintf(&b, "%s|%v|%s;", c.id, c.state, c.command)
	}
	return strings.to_string(b)
}


// The Settings tab's rows (settings_ui), rebuilt only when what they show changed.
settings_tree_rows :: proc() -> []Files_Row {
	v := &settings_ui
	cwd := settings_project_cwd()
	model := agent_model() // the Atlas group's model row
	machines := settings_machines_key() // the Machines group follows its links' status
	if v.built && v.root == cwd && v.state_gen == files_state_gen && v.cache_gen == files_cache_gen && sf_built_gen == settings_gen && model == sf_model && machines == sf_machines do return v.rows[:]
	delete(sf_model)
	sf_model = strings.clone(model)
	delete(sf_machines)
	sf_machines = strings.clone(machines)
	virtual.arena_destroy(&v.arena)
	_ = virtual.arena_init_growing(&v.arena)
	a := virtual.arena_allocator(&v.arena)
	v.rows = make([dynamic]Files_Row, a)
	v.root = strings.clone(cwd, a)
	sf_has_ids = false
	rows := settings_file_rows()
	if state.files.filter != "" {
		settings_filter_rows(v, rows, a)
	} else {
		group := ""
		for r in rows {
			if r.group != group {
				group = r.group
				append(&v.rows, Files_Row{head = true, name = strings.clone(settings_group_label(group, cwd), a)})
			}
			tree_row(v, r.path, r.label, r.kind == .Folder ? .Dir : .File, r.detail, !r.exists, a)
			if r.button != "" do v.rows[len(v.rows) - 1].button = strings.clone(r.button, a)
			v.rows[len(v.rows) - 1].reset, v.rows[len(v.rows) - 1].reveal, v.rows[len(v.rows) - 1].remove = r.reset, r.reveal, r.remove
			v.rows[len(v.rows) - 1].make_default = r.make_default
			if r.group != "project" || r.label != ".pi/settings.json" do continue
			// the rest of the project's .pi/ folder
			dir := strings.concatenate({cwd, "/.pi"}, context.temp_allocator)
			if path_kind(dir) != .Dir do continue
			for e in files_dir(dir, false).entries {
				full := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
				if e.name == "settings.json" || settings_hidden(full) do continue
				tree_row(v, full, strings.concatenate({".pi/", e.name}, context.temp_allocator), e.kind, "", false, a)
			}
		}
	}
	files_walk_done()
	sf_has_ids = false
	sf_look(record_only = true) // what was listed is the poll's baseline
	v.state_gen, v.cache_gen, v.built = files_state_gen, files_cache_gen, true
	sf_built_gen = settings_gen
	return v.rows[:]
}

@(private = "file")
tree_row :: proc(v: ^Files_View, path, name: string, kind: Fs_Kind, note: string, missing: bool, a: runtime.Allocator) {
	full := strings.clone(path, a)
	open := kind == .Dir && !missing && files_is_open(full)
	append(&v.rows, Files_Row{path = full, name = strings.clone(name, a), kind = kind, note = strings.clone(note, a), missing = missing, expanded = open})
	if open do files_walk(v, full, "", 1, false, nil, a, settings = true)
}

SETTINGS_FILTER_SCAN :: 5000 // entries looked at by a filter

// Filter mode: every file of the tree (open or not, ignored ones and
// node_modules left out) whose path matches every word, best first, flat.
@(private = "file")
settings_filter_rows :: proc(v: ^Files_View, rows: []Settings_File_Row, a: runtime.Allocator) {
	ad := settings_agent_dir()
	cwd := v.root
	Dir :: struct {
		path:  string,
		depth: int,
	}
	files := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	queue := make([dynamic]Dir, context.temp_allocator)
	for r in rows {
		if !r.exists do continue
		if r.kind == .Folder do append(&queue, Dir{r.path, 0})
		else if !seen[r.path] {
			seen[r.path] = true
			append(&files, r.path)
		}
	}
	if cwd != "" do append(&queue, Dir{strings.concatenate({cwd, "/.pi"}, context.temp_allocator), 0})
	n := 0
	for qi := 0; qi < len(queue) && n < SETTINGS_FILTER_SCAN; qi += 1 {
		q := queue[qi]
		if path_kind(q.path) != .Dir || seen[q.path] do continue
		seen[q.path] = true
		for e in files_dir(q.path, false).entries {
			if e.ignored || e.name == "node_modules" do continue
			full := strings.concatenate({q.path, "/", e.name}, context.temp_allocator)
			if settings_hidden(full) do continue
			n += 1
			if e.kind == .Dir {
				if q.depth < 6 do append(&queue, Dir{full, q.depth + 1})
			} else if !seen[full] {
				seen[full] = true
				append(&files, full)
			}
		}
	}
	rel_of :: proc(p, ad, cwd: string) -> string {
		if under(p, ad) do return p[len(ad) + 1:]
		if cwd != "" && under(p, cwd) do return p[len(cwd) + 1:]
		return fs_display(p)
	}
	words := strings.fields(state.files.filter, context.temp_allocator)
	Hit :: struct {
		i, score: int,
	}
	hits := make([dynamic]Hit, context.temp_allocator)
	for f, i in files {
		rel := rel_of(f, ad, cwd)
		total := 0
		ok := true
		for w in words {
			if s, _, hit := fuzzy_score(w, filepath.base(f)); hit {
				total += 2 * s
				continue
			}
			s, _, hit := fuzzy_score(w, rel)
			if !hit {
				ok = false
				break
			}
			total += s
		}
		if ok do append(&hits, Hit{i, total})
	}
	slice.sort_by(hits[:], proc(x, y: Hit) -> bool {
		if x.score != y.score do return x.score > y.score
		return x.i < y.i
	})
	for h, k in hits {
		if k >= FILES_FILTER_MAX {
			append(&v.rows, Files_Row{path = strings.clone(ad, a), more = len(hits) - k})
			break
		}
		full := strings.clone(files[h.i], a)
		append(&v.rows, Files_Row{path = full, name = full[len(full) - len(filepath.base(full)):], rel = strings.clone(rel_of(full, ad, cwd), a), kind = .File})
	}
}

// ---- Create, the poll, the palette ----

// A missing row's Create button: makes the file (never over one made since
// the tree was drawn: O_EXCL; one that is there opens as it is), then opens
// it. Only files the tree offers to create. The error shows over the tree.
settings_create :: proc(path: string) {
	delete(sf_error)
	sf_error = ""
	row: Settings_File_Row
	found := false
	for r in settings_file_rows() do if r.path == path && r.create {
		row, found = r, true
	}
	if !found do return
	if !row.exists {
		os.make_directory_all(filepath.dir(row.path))
		f, err := os.open(row.path, {.Write, .Create, .Excl}, os.perm_number(0o644))
		if err == nil {
			_, werr := os.write_string(f, row.seed)
			os.close(f)
			if werr != nil {
				sf_error = strings.clone(fmt.tprintf("could not create %s: %v", fs_display(row.path), werr))
				return
			}
		} else if path_kind(row.path) != .File {
			sf_error = strings.clone(fmt.tprintf("could not create %s: %v", fs_display(row.path), err))
			return
		}
		fs_model_changed(row.path)
		settings_gen += 1
	}
	if replica_process { // a separate core's window: the core opens it (a failure shows as a toast)
		if replica_ui_send != nil do replica_ui_send(Open_File{path = row.path}, "Open")
		window_state_changed()
		return
	}
	res := run_command(Open_File{path = row.path}, {kind = .UI})
	if !res.ok do sf_error = strings.clone(fmt.tprintf("%s: %s", fs_display(row.path), res.error))
	window_state_changed()
}

// A window whose core is another process: a command as the user's (ui), sent to the core; menu: a
// label its failure is shown under. The window sets it (client_core.odin).
replica_ui_send: proc(cmd: Command, menu: string)

@(private = "file")
sf_poll_at: time.Tick
@(private = "file")
sf_mtimes: map[string]i64 // folder (owned) -> its modification time at the last poll

// While the Settings tab shows, every EDITOR_POLL (editor_tick): the shown
// folders outside projects (the agent folder, its open folders) and the
// project's folder and .pi/ are looked at; one whose time changed is listed
// again. A few stats, no watcher on ~/.pi.
settings_poll :: proc() {
	if !state.layout.left_open || state.layout.left_tab != .Settings do return
	if time.tick_since(sf_poll_at) < EDITOR_POLL do return
	sf_poll_at = time.tick_now()
	if sf_look(record_only = false) {
		settings_gen += 1
		window_state_changed()
	}
}

// The poll now (tests).
settings_poll_now :: proc() {
	sf_poll_at = {}
	settings_poll()
}

// Looks at the shown folders' times; true when one changed since the last
// look (its listing is read again). record_only: the tree was just built,
// what it showed is the baseline.
@(private = "file")
sf_look :: proc(record_only: bool) -> bool {
	ad := settings_agent_dir()
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, ad)
	for sub in SETTINGS_FOLDERS do append(&dirs, strings.concatenate({ad, "/", sub}, context.temp_allocator))
	for d in files_cached_dirs(ad) do append(&dirs, d)
	if cwd := settings_project_cwd(); cwd != "" {
		append(&dirs, cwd)
		append(&dirs, strings.concatenate({cwd, "/.pi"}, context.temp_allocator))
	}
	changed := false
	for d in dirs {
		_, st := path_stat(d)
		old, known := sf_mtimes[d]
		if known && old == st.mtime do continue
		if !known {
			sf_mtimes[strings.clone(d)] = st.mtime
			continue
		}
		if record_only do continue // a change is the poll's to see
		sf_mtimes[d] = st.mtime
		files_path_changed(d)
		changed = true
	}
	return changed
}

// The palette's direct entries: a listed file by label in a group, opened.
settings_file_action :: proc(group, label: string) -> (Command, bool) {
	for r in settings_file_rows() {
		if r.label == label && r.group == group && r.exists && r.kind == .File && cur() != nil do return Open_File{path = r.path}, true
	}
	return nil, false
}

// The Atlas group's model row as shown (its tooltip).
sf_model_note :: proc() -> string {return sf_model != "" ? sf_model : "pi's default"}
