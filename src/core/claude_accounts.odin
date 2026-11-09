package core

// Claude Code accounts (docs/CLAUDE.md §1b). An account in Deckhand is a Claude Code config folder:
// what CLAUDE_CONFIG_DIR names (its sign-in, settings, transcripts). Sign-ins that come from the
// environment (ANTHROPIC_API_KEY, apiKeyHelper, Bedrock, Vertex) are untouched: claude inherits
// the login environment as before, and Deckhand never stores a secret.
//
// Where accounts come from (all optional):
//   - the default: CLAUDE_CONFIG_DIR in the environment Claude tabs get (when absolute: that is
//     what the user's plain `claude` uses), else ~/.claude. Always there, even before Claude Code
//     made the folder. Starting it changes nothing in claude's environment.
//   - ~/.claude when CLAUDE_CONFIG_DIR names another default and ~/.claude is a folder.
//   - found (claude_accounts_refresh, stat only, never a read): folders directly under HOME whose
//     name starts with ".claude" and folders under ~/.config (or XDG_CONFIG_HOME) whose name
//     starts with "claude", that hold Claude Code's account file (.claude.json) or sign-in
//     (.credentials.json). Labels come from the folder's name (".claude-work" -> "Work").
//   - added by hand (Add_Claude_Account: Settings → Claude accounts → Add account…, a folder
//     picker), anywhere.
// The user renames or removes any but the default (Settings.claude_accounts keeps what they
// changed). With one account there is no account UI: no picker, no tags.
//
// A Claude tab and a history entry keep their account's folder (Claude_Tab.account,
// Claude_Record.account). Every start (new, resume, restore, restart) sets it: nothing for the
// default; else CLAUDE_CONFIG_DIR=<folder> (or unset, for ~/.claude while the default is
// another), set again in the tab's shell after the login profile ran (CLAUDE_ACCOUNT_SH), so a
// profile that exports CLAUDE_CONFIG_DIR cannot move a tab to another account. Agents name a
// configured account by its label or folder, never a folder of their own.
//
// Every account's folder, and every folder found or removed, is guarded like ~/.claude
// (claude_config_dirs, claude_credential): its transcripts, state and sign-ins are never listed,
// opened, watched or given to an agent.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Claude_Account_Source :: enum u8 {
	Default, // CLAUDE_CONFIG_DIR of the login environment, else ~/.claude
	Home, // ~/.claude while CLAUDE_CONFIG_DIR names the default
	Found, // a folder with Claude Code's account file, found by stat
	Added, // the user's (Add account…)
}
CLAUDE_ACCOUNT_SOURCE_NAMES := [Claude_Account_Source]string {
	.Default = "default",
	.Home    = "home",
	.Found   = "found",
	.Added   = "added",
}

// One account as the lists show it (temp).
Claude_Account :: struct {
	label:   string,
	dir:     string, // absolute, clean
	source:  Claude_Account_Source,
	default: bool, // the environment's default (what plain `claude` uses): never removed
	chosen:  bool, // the default for new sessions (Settings.claude_account_default, else the environment's)
}

// What the user changed about an account (Settings.claude_accounts; saved): a label of their
// own, an account they added, one they removed. Keyed by the folder.
Claude_Account_Setting :: struct {
	dir:     string,
	label:   string, // "" = from the folder's name
	added:   bool,
	removed: bool,
}

// Add an account: a Claude Code config folder (the user's).
Add_Claude_Account :: struct {
	dir:   string,
	label: string, // "" = from the folder's name
}
Rename_Claude_Account :: struct {
	account: string, // its label or folder
	label:   string, // "" = from the folder's name again
}
Remove_Claude_Account :: struct {
	account: string,
}
// The account new Claude sessions start with (unless their project last used another): its
// label or folder; "" = the environment's default again.
Set_Claude_Account_Default :: struct {
	account: string,
}

CLAUDE_ACCOUNT_LABEL_MAX :: 40

// The shell line that sets the tab's account after the login profile ran (claude_start puts it
// before the command): DECKHAND_CLAUDE_ACCOUNT set = this account (empty: ~/.claude, so
// CLAUDE_CONFIG_DIR is unset); not set = the default (the environment as the profile left it).
CLAUDE_ACCOUNT_SH :: `if [ -n "${DECKHAND_CLAUDE_ACCOUNT+x}" ]; then if [ -n "$DECKHAND_CLAUDE_ACCOUNT" ]; then CLAUDE_CONFIG_DIR=$DECKHAND_CLAUDE_ACCOUNT; export CLAUDE_CONFIG_DIR; else unset CLAUDE_CONFIG_DIR; fi; unset DECKHAND_CLAUDE_ACCOUNT; fi; `

// Folders found by claude_accounts_refresh (heap), in a stable order.
@(private = "file")
found_dirs: [dynamic]string

// ---- folders ----

@(private = "file")
home_dir_now :: proc() -> string {return strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")}

// ~/.claude ("" without HOME). Temp.
claude_home_config :: proc() -> string {
	h := home_dir_now()
	if h == "" do return ""
	return strings.concatenate({h, "/.claude"}, context.temp_allocator)
}

@(private = "file")
clean_dir :: proc(d: string) -> string {
	if d == "" || !filepath.is_abs(d) do return ""
	c, _ := filepath.clean(d, context.temp_allocator)
	return strings.trim_right(c, "/") == "" ? "/" : c
}

// Whether d holds Claude Code's account file or sign-in (stat only).
@(private = "file")
marked :: proc(d: string) -> bool {
	for f in ([2]string{".claude.json", ".credentials.json"}) {
		if k, _ := path_stat(strings.concatenate({d, "/", f}, context.temp_allocator)); k == .File do return true
	}
	return false
}

// Whether a folder holds Claude Code's account file or sign-in (stat only; never read).
claude_account_marked :: proc(d: string) -> bool {return marked(d)}

// Looks for config folders again (stat only): main thread; at start, Rescan, Refresh shell
// environment, and when the accounts setting changed.
claude_accounts_refresh :: proc() {
	heap := runtime.heap_allocator()
	claude_accounts_gen += 1
	for d in found_dirs do delete(d, heap)
	clear(&found_dirs)
	if found_dirs.allocator.procedure == nil do found_dirs = make([dynamic]string, heap)
	h := home_dir_now()
	if h == "" || !filepath.is_abs(h) do return
	look :: proc(parent, prefix: string, skip: []string) {
		entries, err := os.read_all_directory_by_path(parent, context.temp_allocator)
		if err != nil do return
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		outer: for e in entries {
			if !strings.has_prefix(e.name, prefix) || e.name == prefix do continue
			for s in skip do if e.name == s || strings.has_prefix(e.name, strings.concatenate({s, "."}, context.temp_allocator)) do continue outer
			p := strings.concatenate({parent, "/", e.name}, context.temp_allocator)
			if path_kind(p) != .Dir || !marked(p) do continue
			if len(found_dirs) < 32 do append(&found_dirs, strings.clone(p, runtime.heap_allocator()))
		}
	}
	look(h, ".claude", {".claude.json"})
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !filepath.is_abs(xdg) do xdg = strings.concatenate({h, "/.config"}, context.temp_allocator)
	look(clean_dir(xdg), "claude", {})
	// "claude" itself under ~/.config is a config folder by that name too
	if c := strings.concatenate({clean_dir(xdg), "/claude"}, context.temp_allocator); path_kind(c) == .Dir && marked(c) && len(found_dirs) < 32 {
		append(&found_dirs, strings.clone(c, heap))
	}
}

// A label from a folder's name: ".claude-work" -> "Work", "claude_personal" -> "Personal",
// "acme-claude" -> "Acme-claude", ".claude" -> "Claude". Temp.
claude_account_label_of :: proc(dir: string) -> string {
	name := filepath.base(dir)
	name = strings.trim_left(name, ".")
	low := strings.to_lower(name, context.temp_allocator)
	if strings.has_prefix(low, "claude") && len(name) > len("claude") {
		rest := strings.trim_left(name[len("claude"):], "-_. ")
		if rest != "" do name = rest
	}
	if name == "" do name = "claude"
	r, w := utf8.decode_rune_in_string(name)
	up := strings.to_upper(name[:w], context.temp_allocator)
	_ = r
	return cut_utf8(strings.concatenate({up, name[w:]}, context.temp_allocator), CLAUDE_ACCOUNT_LABEL_MAX)
}

@(private = "file")
setting_of :: proc(dir: string) -> ^Claude_Account_Setting {
	for &s in state.settings.claude_accounts do if s.dir == dir do return &s
	return nil
}

// Bumped whenever the accounts may differ (a look for folders, a command, the settings back).
claude_accounts_gen: u64

@(private = "file")
Accounts_Key :: struct {
	frame, gen:           u64,
	settings:             rawptr,
	n:                    int,
	home, def, chosen:    string, // heap
}

@(private = "file")
accounts_cache: struct {
	key:  Accounts_Key,
	list: [dynamic]Claude_Account, // strings heap
	ok:   bool,
}

// The accounts now, the default first (temp). Never empty while HOME is set. Made once a frame or
// core tick (the rows, menus and tags all ask): again when anything it reads changed.
claude_accounts :: proc() -> []Claude_Account {
	heap := runtime.heap_allocator()
	// frame: a frame or a core tick, so also while the window is hidden, and in a separate core
	key := Accounts_Key{frame = app_frames_called + core_loop.ticks, gen = claude_accounts_gen, settings = raw_data(state.settings.claude_accounts), n = len(state.settings.claude_accounts), home = home_dir_now(), def = claude_config_dir(), chosen = state.settings.claude_account_default}
	c := &accounts_cache
	same := c.ok && c.key.frame == key.frame && c.key.gen == key.gen && c.key.settings == key.settings && c.key.n == key.n && c.key.home == key.home && c.key.def == key.def && c.key.chosen == key.chosen
	if !same {
		for a in c.list {
			delete(a.label, heap)
			delete(a.dir, heap)
		}
		clear(&c.list)
		if c.list.allocator.procedure == nil do c.list = make([dynamic]Claude_Account, heap)
		for a in accounts_make() do append(&c.list, Claude_Account{label = strings.clone(a.label, heap), dir = strings.clone(a.dir, heap), source = a.source, default = a.default, chosen = a.chosen})
		delete(c.key.home, heap)
		delete(c.key.def, heap)
		delete(c.key.chosen, heap)
		c.key = key
		c.key.home = strings.clone(key.home, heap)
		c.key.def = strings.clone(key.def, heap)
		c.key.chosen = strings.clone(key.chosen, heap)
		c.ok = true
	}
	out := make([]Claude_Account, len(c.list), context.temp_allocator)
	for a, i in c.list do out[i] = Claude_Account{label = strings.clone(a.label, context.temp_allocator), dir = strings.clone(a.dir, context.temp_allocator), source = a.source, default = a.default, chosen = a.chosen}
	return out
}

@(private = "file")
accounts_make :: proc() -> []Claude_Account {
	out := make([dynamic]Claude_Account, context.temp_allocator)
	seen := make([dynamic]string, context.temp_allocator) // real paths
	add :: proc(out: ^[dynamic]Claude_Account, seen: ^[dynamic]string, dir: string, src: Claude_Account_Source) {
		d := clean_dir(dir)
		if d == "" do return
		real := fs_real(d)
		if slice.contains(seen[:], real) || slice.contains(seen[:], d) do return
		st := setting_of(d)
		if src != .Default && st != nil && st.removed do return
		label := src == .Default ? "Claude" : claude_account_label_of(d)
		if st != nil && st.label != "" do label = st.label
		// two of one name: the later one by its folder
		for a in out do if strings.equal_fold(a.label, label) do label = path_tilde(d)
		append(seen, real, d)
		append(out, Claude_Account{label = label, dir = d, source = src, default = src == .Default})
	}
	def := claude_config_dir()
	add(&out, &seen, def, .Default)
	if home := claude_home_config(); home != "" && home != def && path_kind(home) == .Dir do add(&out, &seen, home, .Home)
	for d in found_dirs do add(&out, &seen, d, .Found)
	for s in state.settings.claude_accounts do if s.added && path_kind(s.dir) == .Dir do add(&out, &seen, s.dir, .Added)
	chosen := 0
	for a, i in out do if i > 0 && a.dir == state.settings.claude_account_default do chosen = i
	if len(out) > 0 do out[chosen].chosen = true
	return out[:]
}

// An account's label now ("" = not configured). Temp.
claude_account_label_now :: proc(dir: string) -> string {
	for a in claude_accounts() do if a.dir == dir do return a.label
	return ""
}

// More than one account: the pickers and the rows' tags show.
claude_accounts_many :: proc() -> bool {return len(claude_accounts()) > 1}

// Every folder Deckhand guards as Claude's (claude_credential): ~/.claude, the default, every
// account, and every folder found or added, also the removed ones. Temp.
claude_account_dirs :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, d: string) {
		c := clean_dir(d)
		if c != "" && !slice.contains(out[:], c) do append(out, c)
	}
	add(&out, claude_home_config())
	add(&out, claude_config_dir())
	for d in found_dirs do add(&out, d)
	// a removed folder stays guarded while it holds Claude Code's files (a hand-added one
	// without them was never Claude's: removing it gives it back)
	for s in state.settings.claude_accounts do if !s.removed || marked(s.dir) do add(&out, s.dir)
	return out[:]
}

// The account named by its label (any case) or folder; "" names none (err ""). Only configured
// accounts: never a folder an agent makes up.
claude_account_resolve :: proc(name: string) -> (dir: string, err: string) {
	n := strings.trim_space(name)
	if n == "" do return "", ""
	accts := claude_accounts()
	c := clean_dir(n)
	for a in accts do if c != "" && (a.dir == c || fs_real(c) == fs_real(a.dir)) do return a.dir, ""
	for a in accts do if strings.equal_fold(a.label, n) do return a.dir, ""
	b := strings.builder_make(context.temp_allocator)
	for a, i in accts {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, a.label)
	}
	return "", fmt.tprintf("no such Claude account (Settings → Claude accounts: %s)", strings.to_string(b))
}

// The folder a tab or record's account is ("" = the default: legacy entries). Temp.
claude_account_dir :: proc(account: string) -> string {
	if account == "" do return claude_config_dir()
	return account
}

// Whether an account folder is configured now (a tab's or record's, at its start).
claude_account_known :: proc(account: string) -> bool {
	d := claude_account_dir(account)
	for a in claude_accounts() do if a.dir == d do return true
	return false
}

// The account's label ("" with one account: no tag). Temp.
claude_account_tag :: proc(account: string) -> string {
	accts := claude_accounts()
	if len(accts) < 2 do return ""
	d := claude_account_dir(account)
	for a in accts do if a.dir == d do return a.label
	return path_tilde(d)
}

// The account a new Claude session of p starts with: the project's last used, else the default
// the user chose, else the last used anywhere, else the environment's default (each only while
// configured).
claude_account_pick :: proc(p: ^Project) -> string {
	if p != nil do for r in state.claude_history do if r.project == p.cwd && r.account != "" && claude_account_known(r.account) do return r.account
	if d := state.settings.claude_account_default; d != "" && claude_account_known(d) do return d
	if l := state.settings.claude_account_last; l != "" && claude_account_known(l) do return l
	return claude_config_dir()
}

// What a Claude tab's environment gets for its account (claude_start): nothing for the default;
// else DECKHAND_CLAUDE_ACCOUNT for CLAUDE_ACCOUNT_SH (after the login profile), and
// CLAUDE_CONFIG_DIR set or dropped here too (DECKHAND_CLAUDE_CMD replaces the shell line in tests).
claude_account_env :: proc(account: string) -> []string {
	d := claude_account_dir(account)
	if d == "" || d == claude_config_dir() do return nil
	out := make([dynamic]string, context.temp_allocator)
	if d == claude_home_config() {
		append(&out, "DECKHAND_CLAUDE_ACCOUNT=", "!CLAUDE_CONFIG_DIR")
	} else {
		append(&out, fmt.tprintf("DECKHAND_CLAUDE_ACCOUNT=%s", d), fmt.tprintf("CLAUDE_CONFIG_DIR=%s", d))
	}
	return out[:]
}

// The account's user settings folder for the read-only profile's --setting-sources user: the
// same folder (CLAUDE_CONFIG_DIR is the process's), nothing to pass.

// The saved accounts setting back (persist.odin's settings): folders absolute only.
claude_accounts_restore :: proc(st: json.Object) {
	heap := runtime.heap_allocator()
	claude_accounts_gen += 1
	if list, ok := st["claude_accounts"].(json.Array); ok {
		for x in state.settings.claude_accounts {
			delete(x.dir, heap)
			delete(x.label, heap)
		}
		clear(&state.settings.claude_accounts)
		for v in list {
			o, oo := v.(json.Object)
			if !oo do continue
			dir, _ := o["dir"].(json.String)
			d := clean_dir(string(dir))
			if d == "" || setting_of(d) != nil do continue
			label, _ := o["label"].(json.String)
			added, _ := o["added"].(json.Boolean)
			removed, _ := o["removed"].(json.Boolean)
			l := cut_utf8(strings.trim_space(one_line(string(label), context.temp_allocator)), CLAUDE_ACCOUNT_LABEL_MAX)
			append(&state.settings.claude_accounts, Claude_Account_Setting{dir = strings.clone(d, heap), label = strings.clone(l, heap), added = bool(added), removed = bool(removed)})
			if len(state.settings.claude_accounts) >= 64 do break
		}
	}
	if l, ok := st["claude_account_last"].(json.String); ok && filepath.is_abs(string(l)) {
		delete(state.settings.claude_account_last, heap)
		state.settings.claude_account_last = strings.clone(clean_dir(string(l)), heap)
	}
	if l, ok := st["claude_account_default"].(json.String); ok && filepath.is_abs(string(l)) {
		delete(state.settings.claude_account_default, heap)
		state.settings.claude_account_default = strings.clone(clean_dir(string(l)), heap)
	}
	claude_accounts_refresh()
	// an added account's projects and transcripts: the next scan (at launch the first scan ran
	// before the settings came back)
	added := false
	for a in state.settings.claude_accounts do if a.added do added = true
	if added {
		claude_scan_prepare()
		claude_disk_rescan()
	}
}

// Menu rows that start Claude under an account: one row (label) with one account; with several,
// one row per account ("label · Work"), the pick for this place first is checked.
claude_account_items :: proc(items: ^[dynamic]Menu_Item, label: string, cmd: Command) {
	accts := claude_accounts()
	if len(accts) < 2 || !claude_installed() {
		append(items, Menu_Item{label = claude_label(label), cmd = cmd})
		return
	}
	pid: u64
	#partial switch c in cmd {
	case New_Claude_Session: pid = c.project_id
	case New_Claude_Tab:
		pid = c.project_id
		if s := find_session(c.session); s != nil do pid = s.project_id
	}
	pick := claude_account_pick(find_project(pid))
	for a in accts {
		c := cmd
		#partial switch &x in c {
		case New_Claude_Session: x.account = a.dir
		case New_Claude_Tab:     x.account = a.dir
		}
		append(items, Menu_Item{label = fmt.tprintf("%s · %s", label, a.label), check = a.dir == pick, cmd = c})
	}
}

// Why a folder cannot be an account ("" = it can): every account folder is guarded like
// ~/.claude (claude_credential), so it may not be HOME or above it, nor hold a project, the main
// folder or the chats folder (they would be locked out of the editor and Files).
claude_account_dir_refused :: proc(d: string) -> string {
	h := home_dir_now()
	rd := fs_real(d)
	holds :: proc(d, rd, x: string) -> bool {
		if x == "" do return false
		rx := fs_real(x)
		return x == d || rx == rd || within(x, d) || within(rx, rd)
	}
	if d == "/" || holds(d, rd, h) do return "a Claude Code config folder is not your home folder or above it"
	for p in state.projects do if holds(d, rd, p.cwd) do return fmt.tprintf("it holds the project %s: pick the Claude Code config folder itself", p.label != "" ? p.label : p.cwd)
	if holds(d, rd, state.settings.home_dir) do return "it holds Deckhand's main folder: pick the Claude Code config folder itself"
	if holds(d, rd, chats_cwd()) do return "it holds the chats folder: pick the Claude Code config folder itself"
	return ""
}

// The account (its label) whose config folder holds path, other than the environment's default
// ("" = none): a project, the main folder or the chats folder never goes there (every account
// folder is guarded like ~/.claude, so it would be locked out of the editor and Files).
claude_account_holding :: proc(path: string) -> string {
	if path == "" do return ""
	rp := fs_real(path)
	for a in claude_accounts() {
		if a.default do continue
		ra := fs_real(a.dir)
		if path == a.dir || rp == ra || within(path, a.dir) || within(rp, ra) do return a.label
	}
	return ""
}

// ---- commands ----

claude_account_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	heap := runtime.heap_allocator()
	defer if changed do claude_accounts_gen += 1
	#partial switch c in cmd {
	case Add_Claude_Account:
		d := clean_dir(strings.trim_space(c.dir))
		if d == "" do return fail("dir must be an absolute folder"), false
		if path_kind(d) != .Dir do return fail("no such folder"), false
		if why := claude_account_dir_refused(d); why != "" do return fail(why), false
		for a in claude_accounts() do if a.dir == d || fs_real(a.dir) == fs_real(d) do return fail(fmt.tprintf("already an account: %s", a.label)), false
		label := cut_utf8(strings.trim_space(one_line(c.label, context.temp_allocator)), CLAUDE_ACCOUNT_LABEL_MAX)
		if st := setting_of(d); st != nil {
			st.removed = false
			st.added = true
			if label != "" {
				delete(st.label, heap)
				st.label = strings.clone(label, heap)
			}
		} else do append(&state.settings.claude_accounts, Claude_Account_Setting{dir = strings.clone(d, heap), label = strings.clone(label, heap), added = true})
		settings_gen += 1
		return {ok = true}, true
	case Rename_Claude_Account:
		d, err := claude_account_resolve(c.account)
		if err != "" || d == "" do return fail(err != "" ? err : "account is needed"), false
		label := cut_utf8(strings.trim_space(one_line(c.label, context.temp_allocator)), CLAUDE_ACCOUNT_LABEL_MAX)
		for a in claude_accounts() do if a.dir != d && label != "" && strings.equal_fold(a.label, label) do return fail("another account has that name"), false
		st := setting_of(d)
		if st == nil {
			append(&state.settings.claude_accounts, Claude_Account_Setting{dir = strings.clone(d, heap)})
			st = &state.settings.claude_accounts[len(state.settings.claude_accounts) - 1]
		}
		delete(st.label, heap)
		st.label = strings.clone(label, heap)
		settings_gen += 1
		return {ok = true}, true
	case Remove_Claude_Account:
		d, err := claude_account_resolve(c.account)
		if err != "" || d == "" do return fail(err != "" ? err : "account is needed"), false
		if d == claude_config_dir() do return fail("the default account stays (it is what `claude` uses in your shell)"), false
		st := setting_of(d)
		if st == nil {
			append(&state.settings.claude_accounts, Claude_Account_Setting{dir = strings.clone(d, heap)})
			st = &state.settings.claude_accounts[len(state.settings.claude_accounts) - 1]
		}
		st.removed = true
		st.added = false
		if state.settings.claude_account_last == d {
			delete(state.settings.claude_account_last, heap)
			state.settings.claude_account_last = ""
		}
		if state.settings.claude_account_default == d {
			delete(state.settings.claude_account_default, heap)
			state.settings.claude_account_default = ""
		}
		settings_gen += 1
		return {ok = true}, true
	case Set_Claude_Account_Default:
		d, err := claude_account_resolve(c.account)
		if err != "" do return fail(err), false
		if d == claude_config_dir() do d = "" // the environment's: follows CLAUDE_CONFIG_DIR
		if d == state.settings.claude_account_default do return {ok = true}, false
		delete(state.settings.claude_account_default, heap)
		state.settings.claude_account_default = strings.clone(d, heap)
		settings_gen += 1
		return {ok = true}, true
	}
	return fail("not an account command"), false
}

claude_account_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Add_Claude_Account:    return "add_claude_account"
	case Rename_Claude_Account: return "rename_claude_account"
	case Remove_Claude_Account: return "remove_claude_account"
	case Set_Claude_Account_Default: return "set_claude_account_default"
	}
	return ""
}

claude_account_write :: proc(b: ^strings.Builder, cmd: Command) {
	#partial switch c in cmd {
	case Add_Claude_Account:
		strings.write_string(b, `,"dir":`)
		json_quote(b, c.dir)
		if c.label != "" {
			strings.write_string(b, `,"label":`)
			json_quote(b, c.label)
		}
	case Rename_Claude_Account:
		strings.write_string(b, `,"account":`)
		json_quote(b, c.account)
		strings.write_string(b, `,"label":`)
		json_quote(b, c.label)
	case Remove_Claude_Account:
		strings.write_string(b, `,"account":`)
		json_quote(b, c.account)
	case Set_Claude_Account_Default:
		strings.write_string(b, `,"account":`)
		json_quote(b, c.account)
	}
}

claude_account_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	#partial switch c in cmd {
	case Add_Claude_Account:    return Add_Claude_Account{dir = strings.clone(c.dir, allocator), label = strings.clone(c.label, allocator)}
	case Rename_Claude_Account: return Rename_Claude_Account{account = strings.clone(c.account, allocator), label = strings.clone(c.label, allocator)}
	case Remove_Claude_Account: return Remove_Claude_Account{account = strings.clone(c.account, allocator)}
	case Set_Claude_Account_Default: return Set_Claude_Account_Default{account = strings.clone(c.account, allocator)}
	}
	return cmd
}

claude_account_free :: proc(cmd: Command, allocator := context.allocator) {
	#partial switch c in cmd {
	case Add_Claude_Account:
		delete(c.dir, allocator)
		delete(c.label, allocator)
	case Rename_Claude_Account:
		delete(c.account, allocator)
		delete(c.label, allocator)
	case Remove_Claude_Account: delete(c.account, allocator)
	case Set_Claude_Account_Default: delete(c.account, allocator)
	}
}

// The snapshot's accounts (no secrets: labels and folders).
claude_accounts_json :: proc(b: ^strings.Builder) {
	strings.write_string(b, `,"claude_accounts":[`)
	for a, i in claude_accounts() {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"label":`)
		json_quote(b, a.label)
		strings.write_string(b, `,"dir":`)
		json_quote(b, a.dir)
		fmt.sbprintf(b, `,"source":"%s"`, CLAUDE_ACCOUNT_SOURCE_NAMES[a.source])
		if a.default do strings.write_string(b, `,"default":true`)
		if a.chosen do strings.write_string(b, `,"chosen":true`)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

// ---- the folder name Claude Code gives a project ----

CLAUDE_SLUG_MAX :: 200

// Claude Code's folder name under <config>/projects/ for a working folder (verified against
// Claude Code 2.1.317's own function, never by running it): every UTF-16 code unit that is not
// an ASCII letter or digit becomes "-" (so a character outside the BMP makes two); longer than
// 200: its first 200, "-", and the base-36 absolute value of the path's 32-bit string hash
// (h = h*31 + unit, over the UTF-16 units). Claude normalises the path to NFC first (a
// decomposed path counts its combining marks: claude_found matches those by the transcript's
// cwd). Lossy: never turned back into a path.
claude_project_slug :: proc(path: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	h: i32 = 0
	unit :: proc(h: ^i32, u: u32) {h^ = h^ * 31 + i32(u)}
	for i := 0; i < len(path); {
		r, w := utf8.decode_rune_in_string(path[i:])
		if r == utf8.RUNE_ERROR && w <= 1 {
			strings.write_byte(&b, '-') // an invalid byte: one replacement character
			unit(&h, 0xFFFD)
			i += 1
			continue
		}
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			strings.write_byte(&b, u8(r))
			unit(&h, u32(r))
		case r >= 0x10000:
			strings.write_string(&b, "--")
			v := u32(r) - 0x10000
			unit(&h, 0xD800 + (v >> 10))
			unit(&h, 0xDC00 + (v & 0x3FF))
		case:
			strings.write_byte(&b, '-')
			unit(&h, u32(r))
		}
		i += w
	}
	s := strings.to_string(b)
	if len(s) <= CLAUDE_SLUG_MAX do return strings.clone(s, allocator)
	n := abs(i64(h))
	digits := "0123456789abcdefghijklmnopqrstuvwxyz"
	buf: [16]u8
	k := len(buf)
	if n == 0 {
		k -= 1
		buf[k] = '0'
	}
	for n > 0 {
		k -= 1
		buf[k] = digits[n % 36]
		n /= 36
	}
	return strings.concatenate({s[:CLAUDE_SLUG_MAX], "-", string(buf[k:])}, allocator)
}

// CLAUDE_CODE_PROJECT_DIR_NAME as Claude Code honours it (2.1.317): only while CLAUDE_CONFIG_DIR
// is set for it, and only a name of 1-64 letters, digits, '-' or '_' (not a Windows device
// name). Every project of such a process keeps its transcripts in that one folder. Temp; "" =
// none for that account.
claude_project_dir_override :: proc(account: string) -> string {
	v, _ := env_lookup(child_base_env(), "CLAUDE_CODE_PROJECT_DIR_NAME")
	if v == "" || len(v) > 64 do return ""
	for ch in transmute([]u8)v do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '_') do return ""
	switch strings.to_lower(v, context.temp_allocator) {
	case "con", "prn", "aux", "nul": return ""
	}
	low := strings.to_lower(v, context.temp_allocator)
	if len(low) == 4 && (strings.has_prefix(low, "com") || strings.has_prefix(low, "lpt")) && low[3] >= '0' && low[3] <= '9' do return ""
	// set for claude: another account's, or the default's when the environment names it
	// ~/.claude runs with CLAUDE_CONFIG_DIR unset (as the default, or as another account); every
	// other account's folder is CLAUDE_CONFIG_DIR
	if claude_account_dir(account) == claude_home_config() do return ""
	return strings.clone(v, context.temp_allocator)
}
