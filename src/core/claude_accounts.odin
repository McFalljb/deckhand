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
//
// Codex accounts (docs/CODEX.md §6a) are the same code with harness `.Codex`: an account is a Codex
// home (what CODEX_HOME names). The default is CODEX_HOME as tabs get it, else ~/.codex
// (codex_home); ~/.codex too while CODEX_HOME names another; the rest only added by hand (no
// folders are looked for). A non-default account's tab gets CODEX_HOME=<home>, set again after
// the login profile (CODEX_ACCOUNT_SH). Every Codex home, also a removed one that still holds
// Codex's files, is guarded like ~/.codex (codex_credential). Deckhand never makes or writes a
// home: the user signs in on Codex's own screen in the tab.

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

// Add an account: a Claude Code config folder (the user's); .Codex: a Codex home (wire: harness
// "codex", as on every account command).
Add_Claude_Account :: struct {
	dir:   string,
	label: string, // "" = from the folder's name
	harness: Harness, // .Claude or .Codex
}
Rename_Claude_Account :: struct {
	account: string, // its label or folder
	label:   string, // "" = from the folder's name again
	harness: Harness, // .Claude or .Codex
}
Remove_Claude_Account :: struct {
	account: string,
	harness: Harness, // .Claude or .Codex
}
// The account new Claude (.Codex: Codex) sessions start with (unless their project last used
// another): its label or folder; "" = the environment's default again.
Set_Claude_Account_Default :: struct {
	account: string,
	harness: Harness, // .Claude or .Codex
}

CLAUDE_ACCOUNT_LABEL_MAX :: 40

// The shell line that sets the tab's account after the login profile ran (claude_start puts it
// before the command): DECKHAND_CLAUDE_ACCOUNT set = this account (empty: ~/.claude, so
// CLAUDE_CONFIG_DIR is unset); not set = the default (the environment as the profile left it).
CLAUDE_ACCOUNT_SH :: `if [ -n "${DECKHAND_CLAUDE_ACCOUNT+x}" ]; then if [ -n "$DECKHAND_CLAUDE_ACCOUNT" ]; then CLAUDE_CONFIG_DIR=$DECKHAND_CLAUDE_ACCOUNT; export CLAUDE_CONFIG_DIR; else unset CLAUDE_CONFIG_DIR; fi; unset DECKHAND_CLAUDE_ACCOUNT; fi; `
// The same for a Codex tab (codex_start, codex_login_check): DECKHAND_CODEX_ACCOUNT -> CODEX_HOME.
CODEX_ACCOUNT_SH :: `if [ -n "${DECKHAND_CODEX_ACCOUNT+x}" ]; then if [ -n "$DECKHAND_CODEX_ACCOUNT" ]; then CODEX_HOME=$DECKHAND_CODEX_ACCOUNT; export CODEX_HOME; else unset CODEX_HOME; fi; unset DECKHAND_CODEX_ACCOUNT; fi; `

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

// ~/.codex ("" without HOME). Temp.
codex_home_config :: proc() -> string {
	h := home_dir_now()
	if h == "" do return ""
	return strings.concatenate({h, "/.codex"}, context.temp_allocator)
}

// Whether d holds Claude Code's account file or sign-in (.Codex: Codex's sign-in, auth.json, or
// its sessions/ folder; stat only).
@(private = "file")
marked :: proc(d: string, harness: Harness) -> bool {
	switch harness {
	case .Codex:
		if k, _ := path_stat(strings.concatenate({d, "/auth.json"}, context.temp_allocator)); k == .File do return true
		return path_kind(strings.concatenate({d, "/sessions"}, context.temp_allocator)) == .Dir
	case .Claude, .Pi: // .Pi: never an account's (claude_harness_check)
	}
	for f in ([2]string{".claude.json", ".credentials.json"}) {
		if k, _ := path_stat(strings.concatenate({d, "/", f}, context.temp_allocator)); k == .File do return true
	}
	return false
}

// The harness's own settings and folders (.Codex: Codex's). .Pi has no accounts: never asked
// (claude_harness_check), it gets Claude's as the codex bool's false did.
@(private = "file")
settings_of :: proc(harness: Harness) -> ^[dynamic]Claude_Account_Setting {
	switch harness {
	case .Codex:       return &state.settings.codex_accounts
	case .Claude, .Pi:
	}
	return &state.settings.claude_accounts
}
@(private = "file")
chosen_of :: proc(harness: Harness) -> ^string {
	switch harness {
	case .Codex:       return &state.settings.codex_account_default
	case .Claude, .Pi:
	}
	return &state.settings.claude_account_default
}
@(private = "file")
last_of :: proc(harness: Harness) -> ^string {
	switch harness {
	case .Codex:       return &state.settings.codex_account_last
	case .Claude, .Pi:
	}
	return &state.settings.claude_account_last
}
// The environment's default: CLAUDE_CONFIG_DIR, else ~/.claude; CODEX_HOME (never HOME or above
// it), else ~/.codex.
@(private = "file")
env_default :: proc(harness: Harness) -> string {
	switch harness {
	case .Codex:       return codex_home()
	case .Claude, .Pi:
	}
	return claude_config_dir()
}
@(private = "file")
home_config :: proc(harness: Harness) -> string {
	switch harness {
	case .Codex:       return codex_home_config()
	case .Claude, .Pi:
	}
	return claude_home_config()
}

// Whether a folder holds Claude Code's account file or sign-in (stat only; never read).
claude_account_marked :: proc(d: string) -> bool {return marked(d, .Claude)}

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
			if path_kind(p) != .Dir || !marked(p, .Claude) do continue
			if len(found_dirs) < 32 do append(&found_dirs, strings.clone(p, runtime.heap_allocator()))
		}
	}
	look(h, ".claude", {".claude.json"})
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !filepath.is_abs(xdg) do xdg = strings.concatenate({h, "/.config"}, context.temp_allocator)
	look(clean_dir(xdg), "claude", {})
	// "claude" itself under ~/.config is a config folder by that name too
	if c := strings.concatenate({clean_dir(xdg), "/claude"}, context.temp_allocator); path_kind(c) == .Dir && marked(c, .Claude) && len(found_dirs) < 32 {
		append(&found_dirs, strings.clone(c, heap))
	}
}

// A label from a folder's name: ".claude-work" -> "Work", "claude_personal" -> "Personal",
// "acme-claude" -> "Acme-claude", ".claude" -> "Claude" (.Codex: ".codex-work" -> "Work"). Temp.
claude_account_label_of :: proc(dir: string, harness: Harness) -> string {
	word := harness == .Codex ? "codex" : "claude"
	name := filepath.base(dir)
	name = strings.trim_left(name, ".")
	low := strings.to_lower(name, context.temp_allocator)
	if strings.has_prefix(low, word) && len(name) > len(word) {
		rest := strings.trim_left(name[len(word):], "-_. ")
		if rest != "" do name = rest
	}
	if name == "" do name = word
	r, w := utf8.decode_rune_in_string(name)
	up := strings.to_upper(name[:w], context.temp_allocator)
	_ = r
	return cut_utf8(strings.concatenate({up, name[w:]}, context.temp_allocator), CLAUDE_ACCOUNT_LABEL_MAX)
}

@(private = "file")
setting_of :: proc(dir: string, harness: Harness) -> ^Claude_Account_Setting {
	for &s in settings_of(harness)^ do if s.dir == dir do return &s
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
accounts_cache: [2]struct {
	key:  Accounts_Key,
	list: [dynamic]Claude_Account, // strings heap
	ok:   bool,
}

// The accounts now, the default first (temp; .Codex: Codex's). Never empty while HOME is set.
// Made once a frame or core tick (the rows, menus and tags all ask): again when anything it reads
// changed.
claude_accounts :: proc(harness: Harness) -> []Claude_Account {
	heap := runtime.heap_allocator()
	// frame: a frame or a core tick, so also while the window is hidden, and in a separate core
	list := settings_of(harness)
	key := Accounts_Key{frame = app_frames_called + core_loop.ticks, gen = claude_accounts_gen, settings = raw_data(list^), n = len(list^), home = home_dir_now(), def = env_default(harness), chosen = chosen_of(harness)^}
	c := &accounts_cache[harness == .Codex ? 1 : 0]
	same := c.ok && c.key.frame == key.frame && c.key.gen == key.gen && c.key.settings == key.settings && c.key.n == key.n && c.key.home == key.home && c.key.def == key.def && c.key.chosen == key.chosen
	if !same {
		for a in c.list {
			delete(a.label, heap)
			delete(a.dir, heap)
		}
		clear(&c.list)
		if c.list.allocator.procedure == nil do c.list = make([dynamic]Claude_Account, heap)
		for a in accounts_make(harness) do append(&c.list, Claude_Account{label = strings.clone(a.label, heap), dir = strings.clone(a.dir, heap), source = a.source, default = a.default, chosen = a.chosen})
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
accounts_make :: proc(harness: Harness) -> []Claude_Account {
	out := make([dynamic]Claude_Account, context.temp_allocator)
	seen := make([dynamic]string, context.temp_allocator) // real paths
	add :: proc(out: ^[dynamic]Claude_Account, seen: ^[dynamic]string, dir: string, src: Claude_Account_Source, harness: Harness) {
		d := clean_dir(dir)
		if d == "" do return
		real := fs_real(d)
		if slice.contains(seen[:], real) || slice.contains(seen[:], d) do return
		st := setting_of(d, harness)
		if src != .Default && st != nil && st.removed do return
		label := src == .Default ? (harness == .Codex ? "Codex" : "Claude") : claude_account_label_of(d, harness)
		if st != nil && st.label != "" do label = st.label
		// two of one name: the later one by its folder
		for a in out do if strings.equal_fold(a.label, label) do label = path_tilde(d)
		append(seen, real, d)
		append(out, Claude_Account{label = label, dir = d, source = src, default = src == .Default})
	}
	def := env_default(harness)
	add(&out, &seen, def, .Default, harness)
	if home := home_config(harness); home != "" && home != def && path_kind(home) == .Dir do add(&out, &seen, home, .Home, harness)
	if harness != .Codex do for d in found_dirs do add(&out, &seen, d, .Found, harness) // Codex homes are only added by hand
	for s in settings_of(harness)^ do if s.added && path_kind(s.dir) == .Dir && !(harness == .Codex && codex_home_too_high(s.dir)) do add(&out, &seen, s.dir, .Added, harness)
	chosen := 0
	for a, i in out do if i > 0 && a.dir == chosen_of(harness)^ do chosen = i
	if len(out) > 0 do out[chosen].chosen = true
	return out[:]
}

// Whether a Codex home would be HOME or above it (all of HOME would be "Codex's"): never an
// account.
codex_home_too_high :: proc(d: string) -> bool {
	h := home_dir_now()
	if d == "/" || h == "" do return true
	return within(h, d) || within(fs_real(h), fs_real(d))
}

// An account's label now ("" = not configured). Temp.
claude_account_label_now :: proc(dir: string, harness: Harness) -> string {
	for a in claude_accounts(harness) do if a.dir == dir do return a.label
	return ""
}

// More than one account: the pickers and the rows' tags show.
claude_accounts_many :: proc(harness: Harness) -> bool {return len(claude_accounts(harness)) > 1}

// Every folder Deckhand guards as Claude's (claude_credential): ~/.claude, the default, every
// account, and every folder found or added, also the removed ones (.Codex: as Codex's,
// codex_credential: ~/.codex, the default, every home added, also removed ones that still hold
// Codex's files; never HOME or above it). Temp.
claude_account_dirs :: proc(harness: Harness) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, d: string, harness: Harness) {
		c := clean_dir(d)
		if c == "" || slice.contains(out[:], c) do return
		if harness == .Codex && codex_home_too_high(c) do return // only its auth.json (codex_credential)
		append(out, c)
	}
	add(&out, home_config(harness), harness)
	add(&out, env_default(harness), harness)
	if harness != .Codex do for d in found_dirs do add(&out, d, harness)
	// a removed folder stays guarded while it holds Claude Code's (Codex's) files (a hand-added
	// one without them was never Claude's: removing it gives it back)
	for s in settings_of(harness)^ do if !s.removed || marked(s.dir, harness) do add(&out, s.dir, harness)
	return out[:]
}

// The account named by its label (any case) or folder; "" names none (err ""). Only configured
// accounts: never a folder an agent makes up.
claude_account_resolve :: proc(name: string, harness: Harness) -> (dir: string, err: string) {
	n := strings.trim_space(name)
	if n == "" do return "", ""
	accts := claude_accounts(harness)
	c := clean_dir(n)
	for a in accts do if c != "" && (a.dir == c || fs_real(c) == fs_real(a.dir)) do return a.dir, ""
	for a in accts do if strings.equal_fold(a.label, n) do return a.dir, ""
	b := strings.builder_make(context.temp_allocator)
	for a, i in accts {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, a.label)
	}
	return "", fmt.tprintf("no such %s account (Settings → %s accounts: %s)", harness == .Codex ? "Codex" : "Claude", harness == .Codex ? "Codex" : "Claude", strings.to_string(b))
}

// The folder a tab or record's account is ("" = the default: legacy entries). Temp.
claude_account_dir :: proc(account: string, harness: Harness) -> string {
	if account == "" do return env_default(harness)
	return account
}

// Whether an account folder is configured now (a tab's or record's, at its start).
claude_account_known :: proc(account: string, harness: Harness) -> bool {
	d := claude_account_dir(account, harness)
	for a in claude_accounts(harness) do if a.dir == d do return true
	return false
}

// The account's label ("" with one account: no tag). Temp.
claude_account_tag :: proc(account: string, harness: Harness) -> string {
	accts := claude_accounts(harness)
	if len(accts) < 2 do return ""
	d := claude_account_dir(account, harness)
	for a in accts do if a.dir == d do return a.label
	return path_tilde(d)
}

// The account a new Claude (.Codex: Codex) session of p starts with: the project's last used, else
// the default the user chose, else the last used anywhere, else the environment's default (each
// only while configured).
claude_account_pick :: proc(p: ^Project, harness: Harness) -> string {
	if p != nil do for r in state.claude_history do if r.harness == harness && r.project == p.cwd && r.account != "" && claude_account_known(r.account, harness) do return r.account
	if d := chosen_of(harness)^; d != "" && claude_account_known(d, harness) do return d
	if l := last_of(harness)^; l != "" && claude_account_known(l, harness) do return l
	return env_default(harness)
}

// What a Claude tab's environment gets for its account (claude_start): nothing for the default;
// else DECKHAND_CLAUDE_ACCOUNT for CLAUDE_ACCOUNT_SH (after the login profile), and
// CLAUDE_CONFIG_DIR set or dropped here too (DECKHAND_CLAUDE_CMD replaces the shell line in tests).
// .Codex: a Codex tab's (codex_start), DECKHAND_CODEX_ACCOUNT and CODEX_HOME the same way.
claude_account_env :: proc(account: string, harness: Harness) -> []string {
	d := claude_account_dir(account, harness)
	if d == "" || d == env_default(harness) do return nil
	marker, name := "DECKHAND_CLAUDE_ACCOUNT", "CLAUDE_CONFIG_DIR"
	switch harness {
	case .Codex:       marker, name = "DECKHAND_CODEX_ACCOUNT", "CODEX_HOME"
	case .Claude, .Pi:
	}
	out := make([dynamic]string, context.temp_allocator)
	if d == home_config(harness) {
		append(&out, fmt.tprintf("%s=", marker), fmt.tprintf("!%s", name))
	} else {
		append(&out, fmt.tprintf("%s=%s", marker, d), fmt.tprintf("%s=%s", name, d))
	}
	return out[:]
}

// The saved accounts setting back (persist.odin's settings): folders absolute only (Codex homes:
// never HOME or above it).
claude_accounts_restore :: proc(st: json.Object) {
	heap := runtime.heap_allocator()
	claude_accounts_gen += 1
	for harness in ([2]Harness{.Claude, .Codex}) {
		key := harness == .Codex ? "codex_" : "claude_"
		list_now := settings_of(harness)
		if list, ok := st[strings.concatenate({key, "accounts"}, context.temp_allocator)].(json.Array); ok {
			for x in list_now^ {
				delete(x.dir, heap)
				delete(x.label, heap)
			}
			clear(list_now)
			for v in list {
				o, oo := v.(json.Object)
				if !oo do continue
				dir, _ := o["dir"].(json.String)
				d := clean_dir(string(dir))
				if d == "" || setting_of(d, harness) != nil || (harness == .Codex && codex_home_too_high(d)) do continue
				label, _ := o["label"].(json.String)
				added, _ := o["added"].(json.Boolean)
				removed, _ := o["removed"].(json.Boolean)
				l := cut_utf8(strings.trim_space(one_line(string(label), context.temp_allocator)), CLAUDE_ACCOUNT_LABEL_MAX)
				append(list_now, Claude_Account_Setting{dir = strings.clone(d, heap), label = strings.clone(l, heap), added = bool(added), removed = bool(removed)})
				if len(list_now^) >= 64 do break
			}
		}
		if l, ok := st[strings.concatenate({key, "account_last"}, context.temp_allocator)].(json.String); ok && filepath.is_abs(string(l)) {
			delete(last_of(harness)^, heap)
			last_of(harness)^ = strings.clone(clean_dir(string(l)), heap)
		}
		if l, ok := st[strings.concatenate({key, "account_default"}, context.temp_allocator)].(json.String); ok && filepath.is_abs(string(l)) {
			delete(chosen_of(harness)^, heap)
			chosen_of(harness)^ = strings.clone(clean_dir(string(l)), heap)
		}
	}
	claude_accounts_refresh()
	// an added account's projects and transcripts: the next scan (at launch the first scan ran
	// before the settings came back)
	added := false
	for a in state.settings.claude_accounts do if a.added do added = true
	for a in state.settings.codex_accounts do if a.added do added = true
	if added {
		claude_scan_prepare()
		claude_disk_rescan()
	}
}

// Menu rows that start Claude (or Codex: a command with harness .Codex) under an account: one row
// (label) with one account; with several, one row per account ("label · Work"), the pick for
// this place first is checked. Another machine's place: one row (its own accounts there; a Codex
// row's label as it is: that machine's checklist offered it).
claude_account_items :: proc(items: ^[dynamic]Menu_Item, label: string, cmd: Command) {
	harness := Harness.Claude
	pid, sid: u64
	#partial switch c in cmd {
	case New_Claude_Session:
		harness = c.harness
		pid = c.project_id
	case New_Claude_Tab:
		harness = c.harness
		pid, sid = c.project_id, c.session
		if s := find_session(c.session); s != nil do pid = s.project_id
	}
	if id_machine(pid) != 0 || id_machine(sid) != 0 {
		append(items, Menu_Item{label = label, cmd = cmd}) // its own install, not this Mac's (claude_offered, codex_offered)
		return
	}
	accts := claude_accounts(harness)
	if len(accts) < 2 || !(harness == .Codex ? codex_installed() : claude_installed()) {
		append(items, Menu_Item{label = harness == .Codex ? codex_label(label) : claude_label(label), cmd = cmd})
		return
	}
	pick := claude_account_pick(find_project(pid), harness)
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
// folder or the chats folder (they would be locked out of the editor and Files). A Codex home
// (harness .Codex) is guarded like ~/.codex, and is never inside another guarded Codex or Claude folder,
// nor holds one; a Claude account is never a guarded Codex home, inside one or holding one.
claude_account_dir_refused :: proc(d: string, harness: Harness) -> string {
	h := home_dir_now()
	rd := fs_real(d)
	holds :: proc(d, rd, x: string) -> bool {
		if x == "" do return false
		rx := fs_real(x)
		return x == d || rx == rd || within(x, d) || within(rx, rd)
	}
	what := harness == .Codex ? "a Codex home" : "a Claude Code config folder"
	pick := harness == .Codex ? "pick the Codex home itself" : "pick the Claude Code config folder itself"
	if d == "/" || holds(d, rd, h) || (harness == .Codex && codex_home_too_high(d)) do return fmt.tprintf("%s is not your home folder or above it", what)
	for p in state.projects do if p.machine == 0 && holds(d, rd, p.cwd) do return fmt.tprintf("it holds the project %s: %s", p.label != "" ? p.label : p.cwd, pick)
	if holds(d, rd, state.settings.home_dir) do return fmt.tprintf("it holds Deckhand's main folder: %s", pick)
	if holds(d, rd, chats_cwd()) do return fmt.tprintf("it holds the chats folder: %s", pick)
	// never one harness's folder as the other's, nor (a Codex home) one inside another: one guard
	// would cover the other's files. The same harness's own folder: itself (a removed one added
	// again; a listed one: "already an account")
	for same in ([2]bool{true, false}) {
		if harness != .Codex && same do continue // Claude's own folders nest as before
		other := same ? harness : harness == .Codex ? Harness.Claude : Harness.Codex
		for o in claude_account_dirs(other) {
			if same && (o == d || fs_real(o) == rd) do continue
			if holds(d, rd, o) || holds(o, fs_real(o), d) do return fmt.tprintf("it is, is inside, or holds %s (%s)", other == .Codex ? "a Codex home" : "a Claude Code config folder", path_tilde(o))
		}
	}
	return ""
}

// The account (its label) whose config folder holds path, other than the environment's default
// ("" = none): a project, the main folder or the chats folder never goes there (every account
// folder is guarded like ~/.claude, so it would be locked out of the editor and Files). .Codex: a
// Codex home's.
claude_account_holding :: proc(path: string, harness: Harness) -> string {
	if path == "" do return ""
	rp := fs_real(path)
	for a in claude_accounts(harness) {
		if a.default do continue
		ra := fs_real(a.dir)
		if path == a.dir || rp == ra || within(path, a.dir) || within(rp, ra) do return a.label
	}
	return ""
}

// Why a project, the main folder or the chats folder cannot be path: it is inside a Claude
// account's config folder or a Codex account's home ("" = it can).
account_holding_why :: proc(path: string) -> string {
	if l := claude_account_holding(path, .Claude); l != "" do return fmt.tprintf("that folder is inside the Claude account %s's config folder (Settings → Claude accounts)", l)
	if l := claude_account_holding(path, .Codex); l != "" do return fmt.tprintf("that folder is inside the Codex account %s's home (Settings → Codex accounts)", l)
	return ""
}

// ---- commands ----

claude_account_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	heap := runtime.heap_allocator()
	defer if changed do claude_accounts_gen += 1
	#partial switch c in cmd {
	case Add_Claude_Account:
		claude_harness_check(c.harness)
		d := clean_dir(strings.trim_space(c.dir))
		if d == "" do return fail("dir must be an absolute folder"), false
		if path_kind(d) != .Dir do return fail("no such folder"), false
		if why := claude_account_dir_refused(d, c.harness); why != "" do return fail(why), false
		for a in claude_accounts(c.harness) do if a.dir == d || fs_real(a.dir) == fs_real(d) do return fail(fmt.tprintf("already an account: %s", a.label)), false
		label := cut_utf8(strings.trim_space(one_line(c.label, context.temp_allocator)), CLAUDE_ACCOUNT_LABEL_MAX)
		if st := setting_of(d, c.harness); st != nil {
			st.removed = false
			st.added = true
			if label != "" {
				delete(st.label, heap)
				st.label = strings.clone(label, heap)
			}
		} else do append(settings_of(c.harness), Claude_Account_Setting{dir = strings.clone(d, heap), label = strings.clone(label, heap), added = true})
		settings_gen += 1
		return {ok = true}, true
	case Rename_Claude_Account:
		claude_harness_check(c.harness)
		d, err := claude_account_resolve(c.account, c.harness)
		if err != "" || d == "" do return fail(err != "" ? err : "account is needed"), false
		label := cut_utf8(strings.trim_space(one_line(c.label, context.temp_allocator)), CLAUDE_ACCOUNT_LABEL_MAX)
		for a in claude_accounts(c.harness) do if a.dir != d && label != "" && strings.equal_fold(a.label, label) do return fail("another account has that name"), false
		st := setting_of(d, c.harness)
		if st == nil {
			list := settings_of(c.harness)
			append(list, Claude_Account_Setting{dir = strings.clone(d, heap)})
			st = &list^[len(list^) - 1]
		}
		delete(st.label, heap)
		st.label = strings.clone(label, heap)
		settings_gen += 1
		return {ok = true}, true
	case Remove_Claude_Account:
		claude_harness_check(c.harness)
		d, err := claude_account_resolve(c.account, c.harness)
		if err != "" || d == "" do return fail(err != "" ? err : "account is needed"), false
		if d == env_default(c.harness) do return fail(c.harness == .Codex ? "the default account stays (it is what `codex` uses in your shell)" : "the default account stays (it is what `claude` uses in your shell)"), false
		st := setting_of(d, c.harness)
		if st == nil {
			list := settings_of(c.harness)
			append(list, Claude_Account_Setting{dir = strings.clone(d, heap)})
			st = &list^[len(list^) - 1]
		}
		st.removed = true
		st.added = false
		for s in ([2]^string{last_of(c.harness), chosen_of(c.harness)}) do if s^ == d {
			delete(s^, heap)
			s^ = ""
		}
		settings_gen += 1
		return {ok = true}, true
	case Set_Claude_Account_Default:
		claude_harness_check(c.harness)
		d, err := claude_account_resolve(c.account, c.harness)
		if err != "" do return fail(err), false
		if d == env_default(c.harness) do d = "" // the environment's: follows CLAUDE_CONFIG_DIR (CODEX_HOME)
		chosen := chosen_of(c.harness)
		if d == chosen^ do return {ok = true}, false
		delete(chosen^, heap)
		chosen^ = strings.clone(d, heap)
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
	harness := Harness.Claude
	#partial switch c in cmd {
	case Add_Claude_Account:
		strings.write_string(b, `,"dir":`)
		json_quote(b, c.dir)
		if c.label != "" {
			strings.write_string(b, `,"label":`)
			json_quote(b, c.label)
		}
		harness = c.harness
	case Rename_Claude_Account:
		strings.write_string(b, `,"account":`)
		json_quote(b, c.account)
		strings.write_string(b, `,"label":`)
		json_quote(b, c.label)
		harness = c.harness
	case Remove_Claude_Account:
		strings.write_string(b, `,"account":`)
		json_quote(b, c.account)
		harness = c.harness
	case Set_Claude_Account_Default:
		strings.write_string(b, `,"account":`)
		json_quote(b, c.account)
		harness = c.harness
	}
	if harness == .Codex do strings.write_string(b, `,"harness":"codex"`) // Claude's wire is unchanged
}

claude_account_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	#partial switch c in cmd {
	case Add_Claude_Account:    return Add_Claude_Account{dir = strings.clone(c.dir, allocator), label = strings.clone(c.label, allocator), harness = c.harness}
	case Rename_Claude_Account: return Rename_Claude_Account{account = strings.clone(c.account, allocator), label = strings.clone(c.label, allocator), harness = c.harness}
	case Remove_Claude_Account: return Remove_Claude_Account{account = strings.clone(c.account, allocator), harness = c.harness}
	case Set_Claude_Account_Default: return Set_Claude_Account_Default{account = strings.clone(c.account, allocator), harness = c.harness}
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

// The snapshot's accounts (no secrets: labels and folders): Claude's, then Codex's.
claude_accounts_json :: proc(b: ^strings.Builder) {
	for harness in ([2]Harness{.Claude, .Codex}) {
		strings.write_string(b, harness == .Codex ? `,"codex_accounts":[` : `,"claude_accounts":[`)
		for a, i in claude_accounts(harness) {
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
	if claude_account_dir(account, .Claude) == claude_home_config() do return ""
	return strings.clone(v, context.temp_allocator)
}
