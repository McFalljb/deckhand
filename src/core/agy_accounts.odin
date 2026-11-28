package core

// Antigravity accounts (docs/HARNESSES.md §3a "Accounts", docs/GUIDE.md "Antigravity accounts"),
// the model of claude_accounts.odin for pi's bundled antigravity extension. An account is an agy
// profile (the folder agy's --gemini-dir names: its sign-in, settings, conversations) with
// a sign-in method; the extension gives each one a pi provider (`antigravity`, `antigravity-<name>`).
//
// Who owns the list: one file, <data dir>/antigravity/accounts.json (lib/agy-accounts.ts). The core
// is its UI (Settings, the setup sheet, discovery); the extension reads it at every action and keeps
// working when pi runs outside Deckhand. Both edit it under the same lock (accounts.json.lock, the
// hard-link protocol of lib/agy-lock.ts, implemented here byte for byte: agy_lock_try), each reading
// the file again inside the lock and keeping every key it does not know. No secret is ever in it.
//
//   accounts:       [{name, method, label?, dir?, source?, storage?, gcpProject?, gcpLocation?,
//                     approvals? (the extension's: "ask"; /antigravity approvals)}]
//                   name: the provider's suffix, never changed (a rename changes label only);
//                   dir: a profile used in place (absent: <root>/profiles/<name>); source: "found"
//                   (this scan), "added" (the user's folder), absent (a profile Deckhand or pi made);
//                   storage "keyring": the one account whose Google sign-in is in the OS keyring.
//   defaultAccount: the user's chosen default (absent: "default"): the `antigravity` tool's account
//                   when none is named, and the extension's commands with no name.
//   removedDirs:    folders the user removed (never listed again by a scan; still guarded while
//                   they hold agy's files). Deckhand never deletes, copies or moves a profile.
//   agyPath:        agy's path when set (agy_detect.odin).
//
// Where accounts come from: the implicit `default` (<root>/profiles/default, always listed, never
// removed); the file's entries; profiles under <root>/profiles/ the file does not name; folders
// found by stat only, never opening a file (agy_accounts_refresh): agy's own default profile
// (~/.gemini: agy 1.5.18 reads no variable for it, GEMINI_HOME included; only --gemini-dir moves
// it), ~/.gemini* and ~/.config/gemini* (or $XDG_CONFIG_HOME/gemini*) holding agy's marks
// (AGY_PROFILE_MARKS), at most 32, written into the file (source "found") unless the user removed
// them. agy's app data in a profile is `antigravity-acp/` (agy acp) or `antigravity-cli/` (its
// interactive CLI); `antigravity/` in ~/.gemini is the Antigravity IDE's, which does not make a
// folder an account but is guarded like one (AGY_GUARD_MARKS).
//
// Keyring or file. agy 1.5.18 signs a Google account in to one OS keychain entry shared by every
// profile, unless AGY_CLI_FORCE_FILE_TOKEN_STORAGE is set ("Using file-based token storage because
// AGY_CLI_FORCE_FILE_TOKEN_STORAGE is set"): then into the profile's antigravity-acp/acp_token.json.
// It reads a sign-in from the profile's file, else from the keychain, in either mode (neither
// SSH_CONNECTION nor AGY_ACP_FORCE_FILE_STORAGE changes where it stores: tried against the real
// agy). Deckhand never reads the keychain, so a keychain sign-in cannot be told from none, nor
// one profile's from another's. Hence at most one account uses the keychain, signing in and
// running in keychain mode: in order, the default first, the first Google entry with storage
// "keyring" and no sign-in file of its own; when no Google entry has storage "keyring", the default
// (a Google account not marked "file", with no file of its own); else none (lib/agy-accounts.ts
// keychainHolder: the same rule). A scan gives "keyring" to agy's own default profile found without
// a file sign-in when none is marked. Every other account runs and signs in in file mode, and pi
// refuses a Google one with no file of its own (it would run as the keychain account).
//
// The guard (agy_credential, settings_credential): every profile Deckhand knows or found, removed
// ones while they hold agy's files, everything under <root>/profiles, any folder holding agy's
// marks and any file named acp_token.json are refused to agents and kept out of the Files and
// Settings trees (but a profile's GEMINI.md, AGENTS.md and skills); an account folder may not be
// HOME or above it, nor hold a project, the main folder, the chats folder or the data dir
// (agy_account_dir_refused).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import jg "../jsonguard"

Agy_Source :: enum u8 {
	Default, // the implicit `default` (<root>/profiles/default)
	Profile, // a profile Deckhand or pi made under <root>/profiles
	Found, // found by stat (agy_accounts_refresh)
	Added, // the user's folder (Add account…)
}
AGY_SOURCE_NAMES := [Agy_Source]string {
	.Default = "default",
	.Profile = "profile",
	.Found   = "found",
	.Added   = "added",
}

// How an account signs in, as far as a stat tells.
Agy_Sign_In :: enum u8 {
	No, // a Google account with no saved sign-in in the profile: unknown (agy may use the keychain's)
	Yes, // a saved sign-in in the profile (its file stat'ed, never read)
	Keychain, // the keyring account: cannot be checked without reading the keyring
	Key, // an API key in pi's credential store (the extension's; not checked here)
	Adc, // Application Default Credentials (gcloud's)
}
AGY_SIGN_IN_NAMES := [Agy_Sign_In]string {
	.No       = "no",
	.Yes      = "yes",
	.Keychain = "keychain",
	.Key      = "key",
	.Adc      = "adc",
}

AGY_METHODS := [4]string{"oauth-personal", "oauth-business", "gemini-api-key", "agent-platform"}
AGY_METHOD_LABELS := [4]string{"Google account", "Gemini Enterprise", "Gemini API key", "Agent Platform (Vertex AI)"}

// One account as the lists show it (temp).
Agy_Account :: struct {
	name:    string, // the provider's suffix
	label:   string,
	dir:     string, // its profile, absolute, clean
	method:  string,
	source:  Agy_Source,
	keyring: bool,
	sign_in: Agy_Sign_In,
	chosen:  bool, // the default
	models:  int, // agy's models the extension last listed (-1 = not known)
	missing: bool, // a profile used in place whose folder is gone
}

// Add an account: dir, an agy profile folder used in place (the user's: a picker or a typed
// path), or with no dir a new profile under <root>/profiles named name. method: its sign-in
// (default a Google account).
Add_Antigravity_Account :: struct {
	dir:          string `cmd:"opt"`,
	name:         string `cmd:"opt"`,
	label:        string `cmd:"opt"`,
	method:       string `cmd:"opt"`,
	gcp_project:  string `cmd:"opt"`,
	gcp_location: string `cmd:"opt"`,
}
Rename_Antigravity_Account :: struct {
	account: string, // its name, label or folder
	label:   string `cmd:"opt"`, // "" = from the folder's name again
}
Remove_Antigravity_Account :: struct {
	account: string,
}
Set_Antigravity_Account_Default :: struct {
	account: string `cmd:"opt"`, // "" = `default` again
}

AGY_LABEL_MAX :: 40
AGY_FOUND_MAX :: 32
AGY_ACCOUNTS_MAX :: 64
@(private = "file")
AGY_FILE_MAX :: 256 * 1024

// What makes a folder an agy profile (stat only): its file sign-in, or the installation id agy
// writes into its app data on its first run (the ACP server's, antigravity-acp/, or its
// interactive CLI's, antigravity-cli/).
AGY_TOKEN_FILE :: "antigravity-acp/acp_token.json"
AGY_PROFILE_MARKS := [3]string{AGY_TOKEN_FILE, "antigravity-acp/installation_id", "antigravity-cli/installation_id"}
// What Deckhand guards as an agy profile: those, and the Antigravity IDE's app data (~/.gemini/
// antigravity/), never an account by itself.
AGY_GUARD_MARKS := [4]string{AGY_TOKEN_FILE, "antigravity-acp/installation_id", "antigravity-cli/installation_id", "antigravity/installation_id"}

// ---- folders ----

agy_accounts_file :: proc() -> string {
	r := agy_root()
	return r != "" ? strings.concatenate({r, "/accounts.json"}, context.temp_allocator) : ""
}
agy_profiles_root :: proc() -> string {
	r := agy_root()
	return r != "" ? strings.concatenate({r, "/profiles"}, context.temp_allocator) : ""
}

@(private = "file")
agy_home_now :: proc() -> string {return strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")}

@(private = "file")
clean_abs :: proc(d: string) -> string {
	if d == "" || !filepath.is_abs(d) do return ""
	c, _ := filepath.clean(d, context.temp_allocator)
	return strings.trim_right(c, "/") == "" ? "/" : c
}

// agy's own default profile: ~/.gemini (agy 1.5.18 has no variable for it: GEMINI_HOME,
// GEMINI_DIR, GEMINI_CLI_HOME and XDG_CONFIG_HOME leave it there). Temp.
agy_default_home :: proc() -> string {
	h := agy_home_now()
	return h != "" ? strings.concatenate({h, "/.gemini"}, context.temp_allocator) : ""
}

// Whether folder d holds agy's marks (stat only; never read): an account to find.
agy_profile_marked :: proc(d: string) -> bool {
	if d == "" do return false
	for m in AGY_PROFILE_MARKS do if path_kind(strings.concatenate({d, "/", m}, context.temp_allocator)) == .File do return true
	return false
}

// Whether folder d is guarded as an agy profile (agy's marks, or the Antigravity IDE's app data).
agy_profile_guarded :: proc(d: string) -> bool {
	if d == "" do return false
	for m in AGY_GUARD_MARKS do if path_kind(strings.concatenate({d, "/", m}, context.temp_allocator)) == .File do return true
	return false
}

// Whether a profile holds a saved Google sign-in (agy's file storage; stat only).
agy_signed_in_file :: proc(d: string) -> bool {
	return d != "" && path_kind(strings.concatenate({d, "/", AGY_TOKEN_FILE}, context.temp_allocator)) == .File
}

// Account names: a provider id's suffix and a folder name (lib/agy-accounts.ts validName).
agy_valid_name :: proc(n: string) -> bool {
	if len(n) == 0 || len(n) > 32 do return false
	for c, i in transmute([]u8)n {
		ok := c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || (i > 0 && c == '-')
		if !ok do return false
	}
	return true
}

agy_method_ok :: proc(m: string) -> bool {return slice.contains(AGY_METHODS[:], m)}
agy_method_label :: proc(m: string) -> string {
	for x, i in AGY_METHODS do if x == m do return AGY_METHOD_LABELS[i]
	return m
}

// A label from a folder's name: ".gemini-work" -> "Work", ".gemini" -> "Gemini", "acme" ->
// "Acme". Temp.
agy_label_of :: proc(dir: string) -> string {
	name := strings.trim_left(filepath.base(dir), ".")
	low := strings.to_lower(name, context.temp_allocator)
	if strings.has_prefix(low, "gemini") && len(name) > len("gemini") {
		rest := strings.trim_left(name[len("gemini"):], "-_. ")
		if rest != "" do name = rest
	}
	if name == "" do name = "gemini"
	_, w := utf8.decode_rune_in_string(name)
	return cut_utf8(strings.concatenate({strings.to_upper(name[:w], context.temp_allocator), name[w:]}, context.temp_allocator), AGY_LABEL_MAX)
}

// A free account name from a label ("Work" -> "work", taken -> "work-2"). Temp.
@(private = "file")
name_from :: proc(label: string, taken: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	dash := false
	for c in transmute([]u8)strings.to_lower(label, context.temp_allocator) {
		if c >= 'a' && c <= 'z' || c >= '0' && c <= '9' {
			strings.write_byte(&b, c)
			dash = false
		} else if strings.builder_len(b) > 0 && !dash {
			strings.write_byte(&b, '-')
			dash = true
		}
		if strings.builder_len(b) >= 28 do break
	}
	base := strings.trim_right(strings.to_string(b), "-")
	if base == "" do base = "account"
	n := base
	for i := 2; slice.contains(taken, n) || n == "default"; i += 1 do n = fmt.tprintf("%s-%d", base, i)
	return n
}

// ---- the lock (lib/agy-lock.ts, byte for byte) ----

AGY_EMPTY_LOCK_GRACE :: 2 * time.Second

@(private = "file")
Lock_Seen :: struct {
	pid:   int, // 0: no content yet
	ino:   u64,
	mtime: i64, // ns
	ok:    bool,
}

@(private = "file")
lock_read :: proc(p: string) -> Lock_Seen {
	k, st := path_stat(p)
	if k != .File do return {}
	s := Lock_Seen{ino = st.inode, mtime = st.mtime, ok = true}
	if st.size > 4096 do return s
	data, err := os.read_entire_file(p, context.temp_allocator)
	if err != nil do return s
	v, jerr := jg.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return s
	if o, oo := v.(json.Object); oo {
		#partial switch n in o["pid"] {
		case json.Integer: if n > 0 && n < 1 << 31 do s.pid = int(n)
		case json.Float:   if n > 0 && n < 1 << 31 && f64(int(n)) == n do s.pid = int(n)
		}
	}
	return s
}

// Whether process pid exists (kill 0: EPERM is another user's, alive).
agy_pid_alive :: proc(pid: int) -> bool {
	if pid <= 0 do return false
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK do return true
	return posix.errno() == .EPERM
}

@(private = "file")
rand_tag :: proc() -> string {
	digits := "0123456789abcdefghijklmnopqrstuvwxyz"
	b: [8]u8
	for &c in b do c = digits[rand.int_max(36)]
	return strings.clone(string(b[:]), context.temp_allocator)
}

@(private = "file")
write_private :: proc(p, body: string, excl := false) -> bool {
	flags: posix.O_Flags = {.WRONLY, .CREAT, .TRUNC}
	if excl do flags = {.WRONLY, .CREAT, .EXCL}
	fd := posix.open(strings.clone_to_cstring(p, context.temp_allocator), flags, {.IRUSR, .IWUSR})
	if fd < 0 do return false
	defer posix.close(fd)
	data := transmute([]u8)body
	for len(data) > 0 {
		n := posix.write(fd, raw_data(data), uint(len(data)))
		if n <= 0 do return false
		data = data[n:]
	}
	return true
}

// Takes lock p for this process: false when someone holds it. Its content ({"pid":N}) is written
// to p.new-<pid>-<random> and hard-linked into place, so it appears whole or not at all. A lock whose
// holder is gone (or empty and older than 2 s) is taken over by renaming it aside and checking
// that the file moved is the one seen (its inode); one another process took meanwhile is put back.
agy_lock_try :: proc(p: string) -> bool {
	pid := int(posix.getpid())
	mine := fmt.tprintf("%s.new-%d-%s", p, pid, rand_tag())
	if !write_private(mine, fmt.tprintf(`{{"pid":%d}}`, pid), excl = true) do return false
	defer _ = os.remove(mine)
	cp := strings.clone_to_cstring(p, context.temp_allocator)
	for _ in 0 ..< 4 {
		if posix.link(strings.clone_to_cstring(mine, context.temp_allocator), cp) == .OK do return true
		if posix.errno() != .EEXIST do return false
		seen := lock_read(p)
		if !seen.ok do continue // gone meanwhile: try again
		old := seen.pid == 0 ? time.now()._nsec - seen.mtime > i64(AGY_EMPTY_LOCK_GRACE) : !agy_pid_alive(seen.pid)
		if !old do return false
		aside := fmt.tprintf("%s.stale-%d-%s", p, pid, rand_tag())
		ca := strings.clone_to_cstring(aside, context.temp_allocator)
		if posix.rename(cp, ca) != 0 do continue // someone else moved it first
		moved := lock_read(aside)
		if !moved.ok || moved.ino != seen.ino {
			// not the stale lock seen: another process took it meanwhile. Back (unless a third
			// appeared there since), and give way.
			posix.link(ca, cp)
			_ = os.remove(aside)
			return false
		}
		_ = os.remove(aside)
	}
	return false
}

// Removes lock p when this process holds it.
agy_lock_release :: proc(p: string) {
	if lock_read(p).pid == int(posix.getpid()) do _ = os.remove(p)
}

// ---- the file ----

// accounts.json as a JSON object (temp): {} when there is none; ok false when it cannot be read
// or is not an object (then nothing is written over it).
@(private = "file")
file_read :: proc(path: string) -> (o: json.Object, ok: bool) {
	k, st := path_stat(path)
	if k == .Missing do return make(json.Object, context.temp_allocator), true
	if k != .File || st.size > AGY_FILE_MAX do return nil, false
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil, false
	if len(strings.trim_space(string(data))) == 0 do return make(json.Object, context.temp_allocator), true
	v, jerr := jg.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return nil, false
	o, ok = v.(json.Object)
	return
}

// Changes accounts.json under the lock, reading it again inside: change edits the object (false:
// nothing to write). "" = done (or nothing to do); else why not. Never waits long: the core's
// main thread (a pi holding the lock for longer: "try again").
agy_accounts_change :: proc(change: proc(o: ^json.Object, data: rawptr) -> bool, data: rawptr = nil) -> string {
	root := agy_root()
	file := agy_accounts_file()
	if root == "" || file == "" do return "no data folder"
	os.make_directory_all(root, {.Read_User, .Write_User, .Execute_User})
	lock := strings.concatenate({file, ".lock"}, context.temp_allocator)
	got := false
	for i in 0 ..< 10 {
		if agy_lock_try(lock) {
			got = true
			break
		}
		if i < 9 do time.sleep(20 * time.Millisecond)
	}
	if !got {
		who := lock_read(lock).pid
		return who > 0 ? fmt.tprintf("pi (process %d) is changing the Antigravity accounts: try again", who) : "pi is changing the Antigravity accounts: try again"
	}
	defer agy_lock_release(lock)
	o, ok := file_read(file)
	if !ok do return fmt.tprintf("%s is not a JSON object: fix it or remove it", path_tilde(file))
	if !change(&o, data) do return ""
	if _, has := o["about"]; !has do o["about"] = json.String("Deckhand's Antigravity accounts (pi tabs and Deckhand's Settings). No secrets: API keys are in pi's credential store.")
	body, merr := json.marshal(json.Value(o), {pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil do return "could not write the accounts"
	tmp := fmt.tprintf("%s.tmp-%d", file, posix.getpid())
	if !write_private(tmp, strings.concatenate({string(body), "\n"}, context.temp_allocator)) {
		_ = os.remove(tmp)
		return fmt.tprintf("could not write %s", path_tilde(file))
	}
	if posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(file, context.temp_allocator)) != 0 {
		_ = os.remove(tmp)
		return fmt.tprintf("could not write %s", path_tilde(file))
	}
	agy_accounts_gen += 1
	settings_gen += 1
	return ""
}

// The array at key k of the file (empty when missing; set it back with o^[k] = …). Temp.
@(private = "file")
array_of :: proc(o: ^json.Object, k: string) -> json.Array {
	if a, ok := o^[k].(json.Array); ok do return a
	return make(json.Array, context.temp_allocator)
}

@(private = "file")
str_of :: proc(o: json.Object, k: string) -> string {
	s, _ := o[k].(json.String)
	return string(s)
}

// ---- the accounts now ----

// One entry of the file as read (heap: the cache's).
@(private = "file")
Entry :: struct {
	name, label, dir, method, source, storage, gcp_project, gcp_location: string,
}

@(private = "file")
File_Cache :: struct {
	stamp:   Disk_Stamp,
	path:    string,
	present: bool,
	entries: [dynamic]Entry,
	chosen:  string,
	removed: [dynamic]string,
	ok:      bool,
}
@(private = "file")
file_cache: File_Cache

@(private = "file")
entry_free :: proc(e: Entry) {
	heap := runtime.heap_allocator()
	for s in ([8]string{e.name, e.label, e.dir, e.method, e.source, e.storage, e.gcp_project, e.gcp_location}) do delete(s, heap)
}

// The file's entries, read again when it changed (its stamp): bad and repeated names skipped.
@(private = "file")
file_load :: proc() -> ^File_Cache {
	heap := runtime.heap_allocator()
	c := &file_cache
	path := agy_accounts_file()
	k, st := path_stat(path)
	if c.ok && c.path == path && c.present == (k == .File) && c.stamp == st do return c
	for e in c.entries do entry_free(e)
	clear(&c.entries)
	for d in c.removed do delete(d, heap)
	clear(&c.removed)
	delete(c.chosen, heap)
	c.chosen = ""
	delete(c.path, heap)
	if c.entries.allocator.procedure == nil do c.entries = make([dynamic]Entry, heap)
	if c.removed.allocator.procedure == nil do c.removed = make([dynamic]string, heap)
	c.path = strings.clone(path, heap)
	c.present, c.stamp, c.ok = k == .File, st, true
	agy_accounts_gen += 1
	o, ok := file_read(path)
	if !ok || o == nil do return c
	if list, lok := o["accounts"].(json.Array); lok do for v in list {
		e, eo := v.(json.Object)
		if !eo do continue
		name := str_of(e, "name")
		method := str_of(e, "method")
		if !agy_valid_name(name) || !agy_method_ok(method) do continue
		dup := false
		for x in c.entries do if x.name == name do dup = true
		if dup do continue
		dir := ""
		if d := str_of(e, "dir"); d != "" {
			dir = clean_abs(d)
			if dir == "" do continue // a relative folder: not an account
		}
		label := cut_utf8(strings.trim_space(one_line(str_of(e, "label"), context.temp_allocator)), AGY_LABEL_MAX)
		append(&c.entries, Entry{name = strings.clone(name, heap), label = strings.clone(label, heap), dir = strings.clone(dir, heap), method = strings.clone(method, heap), source = strings.clone(str_of(e, "source"), heap), storage = strings.clone(str_of(e, "storage"), heap), gcp_project = strings.clone(str_of(e, "gcpProject"), heap), gcp_location = strings.clone(str_of(e, "gcpLocation"), heap)})
		if len(c.entries) >= AGY_ACCOUNTS_MAX do break
	}
	if d := str_of(o, "defaultAccount"); agy_valid_name(d) do c.chosen = strings.clone(d, heap)
	if list, lok := o["removedDirs"].(json.Array); lok do for v in list {
		if s, so := v.(json.String); so do if d := clean_abs(string(s)); d != "" && len(c.removed) < 256 do append(&c.removed, strings.clone(d, heap))
	}
	return c
}

// The models each account's agy listed last (agy-models.json, the extension's; nothing secret).
@(private = "file")
models_cache: struct {
	stamp:  Disk_Stamp,
	ok:     bool,
	counts: map[string]int,
}

@(private = "file")
models_of :: proc(name: string) -> int {
	heap := runtime.heap_allocator()
	m := &models_cache
	r := agy_root()
	path := r != "" ? strings.concatenate({r, "/agy-models.json"}, context.temp_allocator) : ""
	k, st := path_stat(path)
	if !m.ok || m.stamp != st {
		for key in m.counts do delete(key, heap)
		clear(&m.counts)
		if m.counts == nil do m.counts = make(map[string]int, heap)
		m.stamp, m.ok = st, true
		if k == .File && st.size < 64 * 1024 {
			if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
				if v, jerr := jg.parse(data, .JSON, true, context.temp_allocator); jerr == nil {
					if o, oo := v.(json.Object); oo do for key, val in o {
						e, eo := val.(json.Object)
						if !eo || !agy_valid_name(key) || len(m.counts) >= AGY_ACCOUNTS_MAX do continue
						if n, no := e["count"].(json.Integer); no && n >= 0 && n < 10000 do m.counts[strings.clone(key, heap)] = int(n)
					}
				}
			}
		}
	}
	if n, ok := m.counts[name]; ok do return n
	return -1
}

// Folders found by agy_accounts_refresh (heap), in a stable order.
@(private = "file")
found_dirs: [dynamic]string

// Bumped whenever the accounts may differ (a scan, a command, the file read again).
agy_accounts_gen: u64

@(private = "file")
list_cache: struct {
	frame, gen: u64,
	list:       [dynamic]Agy_Account, // strings heap
	ok:         bool,
}

// The accounts now, `default` first (temp). Made once a frame or core tick, again when the file
// changed or a scan or command ran.
agy_accounts :: proc() -> []Agy_Account {
	heap := runtime.heap_allocator()
	file_load() // bumps the gen when the file changed
	c := &list_cache
	frame := app_frames_called + core_loop.ticks
	if !c.ok || c.frame != frame || c.gen != agy_accounts_gen {
		for a in c.list {
			delete(a.name, heap)
			delete(a.label, heap)
			delete(a.dir, heap)
			delete(a.method, heap)
		}
		clear(&c.list)
		if c.list.allocator.procedure == nil do c.list = make([dynamic]Agy_Account, heap)
		for a in accounts_make() do append(&c.list, Agy_Account{name = strings.clone(a.name, heap), label = strings.clone(a.label, heap), dir = strings.clone(a.dir, heap), method = strings.clone(a.method, heap), source = a.source, keyring = a.keyring, sign_in = a.sign_in, chosen = a.chosen, models = a.models, missing = a.missing})
		c.frame, c.gen, c.ok = frame, agy_accounts_gen, true
	}
	out := make([]Agy_Account, len(c.list), context.temp_allocator)
	for a, i in c.list do out[i] = Agy_Account{name = strings.clone(a.name, context.temp_allocator), label = strings.clone(a.label, context.temp_allocator), dir = strings.clone(a.dir, context.temp_allocator), method = strings.clone(a.method, context.temp_allocator), source = a.source, keyring = a.keyring, sign_in = a.sign_in, chosen = a.chosen, models = a.models, missing = a.missing}
	return out
}

@(private = "file")
accounts_make :: proc() -> []Agy_Account {
	out := make([dynamic]Agy_Account, context.temp_allocator)
	c := file_load()
	profiles := agy_profiles_root()
	if profiles == "" do return out[:]
	keyring_taken := false
	add :: proc(out: ^[dynamic]Agy_Account, e: Entry, src: Agy_Source, profiles: string, keyring_taken: ^bool) {
		dir := e.dir != "" ? e.dir : strings.concatenate({profiles, "/", e.name}, context.temp_allocator)
		label := e.label
		if label == "" do label = e.dir != "" ? agy_label_of(e.dir) : e.name == "default" ? "Default" : agy_label_of(e.name)
		for a in out do if strings.equal_fold(a.label, label) do label = e.name // two of one label: the later one by its name
		a := Agy_Account{name = e.name, label = label, dir = dir, method = e.method, source = src, models = models_of(e.name)}
		// the keychain account (agy_keychain rule, as lib/agy-accounts.ts keychainHolder): the first
		// Google account, default first, with storage "keyring" and no sign-in file of its own (agy
		// reads its file before the keychain: such an account runs in file mode)
		if e.storage == "keyring" && e.method == "oauth-personal" && !keyring_taken^ && !agy_signed_in_file(dir) {
			a.keyring = true
			keyring_taken^ = true
		}
		a.missing = e.dir != "" && path_kind(dir) != .Dir
		uses_key := e.method == "gemini-api-key" || (e.method == "agent-platform" && !(e.gcp_project != "" && e.gcp_location != ""))
		switch {
		case uses_key:                     a.sign_in = .Key
		case e.method == "agent-platform": a.sign_in = .Adc
		case agy_signed_in_file(dir):      a.sign_in = .Yes // a file sign-in wins: agy uses it over SSH too
		case a.keyring:                    a.sign_in = .Keychain
		}
		append(out, a)
	}
	def := Entry{name = "default", method = "oauth-personal"}
	for e in c.entries do if e.name == "default" do def = e
	def.dir = "" // the default is always Deckhand's own profile
	if default_holds_keyring(c.entries[:]) do def.storage = "keyring" // in memory only
	add(&out, def, .Default, profiles, &keyring_taken)
	for e in c.entries {
		if e.name == "default" do continue
		src := Agy_Source.Profile
		switch e.source {
		case "found": src = .Found
		case "added": src = .Added
		}
		if e.dir == "" do src = .Profile
		add(&out, e, src, profiles, &keyring_taken)
	}
	// profiles under <root>/profiles the file does not name (another pi's, a file that lost them)
	entries, err := os.read_all_directory_by_path(profiles, context.temp_allocator)
	if err == nil {
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for d in entries {
			if !agy_valid_name(d.name) || len(out) >= AGY_ACCOUNTS_MAX do continue
			listed := false
			for a in out do if a.name == d.name do listed = true
			p := strings.concatenate({profiles, "/", d.name}, context.temp_allocator)
			if listed || path_kind(p) != .Dir || slice.contains(c.removed[:], p) do continue
			add(&out, Entry{name = d.name, method = "oauth-personal"}, .Profile, profiles, &keyring_taken)
		}
	}
	chosen := 0
	for a, i in out do if c.chosen != "" && a.name == c.chosen do chosen = i
	if len(out) > 0 do out[chosen].chosen = true
	return out[:]
}

// The folders the user removed (accounts.json removedDirs). Temp.
agy_removed_dirs :: proc() -> []string {
	c := file_load()
	out := make([]string, len(c.removed), context.temp_allocator)
	for d, i in c.removed do out[i] = strings.clone(d, context.temp_allocator)
	return out
}

// More than one account: the rows and the setup step show.
agy_accounts_many :: proc() -> bool {return len(agy_accounts()) > 1}

// ---- discovery ----

// Looks for agy profiles again (stat only, never opening a file) and writes the new ones into
// accounts.json (source "found"; not one the user removed), dropping found ones whose folder is
// gone. Main thread: at start, Rescan, Refresh shell environment, Scan again.
agy_accounts_refresh :: proc() {
	heap := runtime.heap_allocator()
	agy_accounts_gen += 1
	for d in found_dirs do delete(d, heap)
	clear(&found_dirs)
	if found_dirs.allocator.procedure == nil do found_dirs = make([dynamic]string, heap)
	h := agy_home_now()
	if h == "" || !filepath.is_abs(h) do return
	add :: proc(p: string) {
		if len(found_dirs) >= AGY_FOUND_MAX || p == "" || path_kind(p) != .Dir || !agy_profile_marked(p) do return
		for d in found_dirs do if d == p || fs_real(d) == fs_real(p) do return
		if agy_account_dir_refused(p) != "" do return // HOME, a project's folder…: never an account
		append(&found_dirs, strings.clone(p, runtime.heap_allocator()))
	}
	add(agy_default_home())
	look :: proc(parent, prefix: string, add: proc(p: string)) {
		if parent == "" do return
		entries, err := os.read_all_directory_by_path(parent, context.temp_allocator)
		if err != nil do return
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for e in entries do if strings.has_prefix(e.name, prefix) do add(strings.concatenate({parent, "/", e.name}, context.temp_allocator))
	}
	look(h, ".gemini", add)
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !filepath.is_abs(xdg) do xdg = strings.concatenate({h, "/.config"}, context.temp_allocator)
	look(clean_abs(xdg), "gemini", add)
	agy_accounts_sync()
}

// Writes what the scan found into the file (nothing when it says so already).
agy_accounts_sync :: proc() -> string {
	c := file_load()
	profiles := agy_profiles_root()
	if profiles == "" do return ""
	def_home := agy_default_home()
	// what to add: found, not listed (by folder, as written or real), not removed
	Plan :: struct {
		add:  [dynamic]Entry,
		drop: [dynamic]string, // names
	}
	plan := Plan{add = make([dynamic]Entry, context.temp_allocator), drop = make([dynamic]string, context.temp_allocator)}
	listed := make([dynamic]string, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	append(&names, "default")
	keyring := default_holds_keyring(c.entries[:])
	for e in c.entries {
		d := e.dir != "" ? e.dir : strings.concatenate({profiles, "/", e.name}, context.temp_allocator)
		append(&listed, d, fs_real(d))
		append(&names, e.name)
		if e.storage == "keyring" && e.method == "oauth-personal" do keyring = true
		if e.source == "found" && e.dir != "" && path_kind(e.dir) != .Dir do append(&plan.drop, e.name)
	}
	for d in found_dirs {
		if slice.contains(listed[:], d) || slice.contains(listed[:], fs_real(d)) do continue
		gone := false
		for r in c.removed do if r == d || fs_real(r) == fs_real(d) do gone = true
		if gone || within(d, profiles) do continue
		label := agy_label_of(d)
		name := name_from(label, names[:])
		append(&names, name)
		storage := "file"
		if !keyring && (d == def_home || fs_real(d) == fs_real(def_home)) && !agy_signed_in_file(d) {
			storage = "keyring"
			keyring = true
		}
		append(&plan.add, Entry{name = name, label = label, dir = d, method = "oauth-personal", source = "found", storage = storage})
	}
	// profiles under <root>/profiles the file does not name (a file another tool rewrote): named
	// again, so pi gives them a provider too
	if entries, err := os.read_all_directory_by_path(profiles, context.temp_allocator); err == nil {
		for d in entries {
			p := strings.concatenate({profiles, "/", d.name}, context.temp_allocator)
			if !agy_valid_name(d.name) || slice.contains(names[:], d.name) || path_kind(p) != .Dir || slice.contains(c.removed[:], p) do continue
			append(&names, d.name)
			append(&plan.add, Entry{name = d.name, method = "oauth-personal"})
		}
	}
	if len(plan.add) == 0 && len(plan.drop) == 0 do return ""
	return agy_accounts_change(proc(o: ^json.Object, data: rawptr) -> bool {
		plan := (^Plan)(data)
		list := array_of(o, "accounts")
		defer o^["accounts"] = list
		changed := false
		// again inside the lock: what another writer did meanwhile wins
		for i := len(list) - 1; i >= 0; i -= 1 {
			e, ok := list[i].(json.Object)
			if ok && slice.contains(plan.drop[:], str_of(e, "name")) && str_of(e, "source") == "found" {
				ordered_remove(&list, i)
				changed = true
			}
		}
		next: for a in plan.add {
			keyring := default_holds_keyring_raw(list)
			for v in list {
				e, ok := v.(json.Object)
				if !ok do continue
				if str_of(e, "name") == a.name do continue next
				if d := clean_abs(str_of(e, "dir")); d != "" && a.dir != "" && (d == a.dir || fs_real(d) == fs_real(a.dir)) do continue next
				if str_of(e, "storage") == "keyring" && str_of(e, "method") == "oauth-personal" do keyring = true
			}
			if rm, rok := o^["removedDirs"].(json.Array); rok && a.dir != "" do for v in rm do if s, so := v.(json.String); so && clean_abs(string(s)) == a.dir do continue next
			e := make(json.Object, context.temp_allocator)
			e["name"] = json.String(a.name)
			e["method"] = json.String(a.method)
			if a.dir != "" { // a found folder (else one of Deckhand's own profiles, by its name)
				e["label"] = json.String(a.label)
				e["dir"] = json.String(a.dir)
				e["source"] = json.String("found")
				e["storage"] = json.String(a.storage == "keyring" && !keyring ? "keyring" : "file")
			}
			append(&list, json.Value(e))
			changed = true
		}
		return changed
	}, &plan)
}

// After Install agy… (agy_install.odin): agy's path in the file when the folder it went to is not on
// the PATH tabs get (pi's extension then finds it as /antigravity path would set it). An agyPath
// the user set to another executable stays. "" = done or nothing to do.
agy_accounts_set_path :: proc(bin: string) -> string {
	if bin == "" || !filepath.is_abs(bin) do return ""
	bin := bin
	return agy_accounts_change(proc(o: ^json.Object, data: rawptr) -> bool {
		bin := (^string)(data)^
		cur := str_of(o^, "agyPath")
		if cur == bin do return false
		if cur != "" && filepath.is_abs(cur) && exe_in(filepath.dir(cur), filepath.base(cur)) do return false // the user's own choice
		o^["agyPath"] = json.String(bin)
		return true
	}, &bin)
}

// ---- the guard ----

// Every folder Deckhand guards as agy's (agy_credential): each account's profile, every folder
// found, the removed ones while they hold agy's files, agy's own default profile when it does, and
// <root>/profiles itself; each as written and where it leads. Never HOME or above it. Made once a
// frame or core tick (a tree asks for every entry), again when the accounts may differ. Temp.
@(private = "file")
dirs_cache: struct {
	frame, gen: u64,
	list:       [dynamic]string, // heap
	ok:         bool,
}

agy_profile_dirs :: proc() -> []string {
	heap := runtime.heap_allocator()
	c := &dirs_cache
	frame := app_frames_called + core_loop.ticks
	if !c.ok || c.frame != frame || c.gen != agy_accounts_gen {
		accts := agy_accounts() // reads the file again when it changed (bumps the gen)
		for d in c.list do delete(d, heap)
		clear(&c.list)
		if c.list.allocator.procedure == nil do c.list = make([dynamic]string, heap)
		h := agy_home_now()
		add :: proc(out: ^[dynamic]string, d, h: string) {
			for x in ([2]string{clean_abs(d), fs_real(clean_abs(d))}) {
				if x == "" || x == "/" do continue
				dup := false
				for y in out do if y == x do dup = true
				if dup do continue
				if h != "" && (within(h, x) || within(fs_real(h), x)) do continue // HOME or above: never all of it
				append(out, strings.clone(x, runtime.heap_allocator()))
			}
		}
		add(&c.list, agy_profiles_root(), h)
		for a in accts do add(&c.list, a.dir, h)
		for d in found_dirs do add(&c.list, d, h)
		for d in file_load().removed do if agy_profile_guarded(d) do add(&c.list, d, h)
		if d := agy_default_home(); agy_profile_guarded(d) do add(&c.list, d, h)
		c.frame, c.gen, c.ok = frame, agy_accounts_gen, true
	}
	out := make([]string, len(c.list), context.temp_allocator)
	for d, i in c.list do out[i] = strings.clone(d, context.temp_allocator)
	return out
}

// Whether p (under the profile d) is the user's own config agy reads: GEMINI.md and AGENTS.md at its
// top, its skills (config/skills/, antigravity-cli/skills/, config/skills.json).
@(private = "file")
config_entry :: proc(p, d: string) -> bool {
	rel := p[len(d) + 1:]
	switch rel {
	case "GEMINI.md", "AGENTS.md", "config/skills.json": return true
	}
	return strings.has_prefix(rel, "config/skills/") || strings.has_prefix(rel, "antigravity-cli/skills/")
}

@(private = "file")
under :: proc(p, dir: string) -> bool {return dir != "" && len(p) > len(dir) && strings.has_prefix(p, dir) && p[len(dir)] == '/'}

// Whether folder d holds agy's marks, remembered for a second (a tree asks for many paths).
@(private = "file")
marks: map[string]bool
@(private = "file")
marks_at: time.Tick
agy_marked_cached :: proc(d: string) -> bool {
	if marks_at == {} || time.tick_since(marks_at) > time.Second {
		for k in marks do delete(k, runtime.heap_allocator())
		clear(&marks)
		marks_at = time.tick_now()
	}
	if v, ok := marks[d]; ok do return v
	v := agy_profile_guarded(d)
	if marks == nil do marks = make(map[string]bool, runtime.heap_allocator())
	if len(marks) < 4096 do marks[strings.clone(d, runtime.heap_allocator())] = v
	return v
}

// An agy file Deckhand never lists, reads, watches or opens (settings_credential): any file named
// acp_token.json (agy's saved sign-in), oauth_creds.json or google_accounts.json, and everything in an agy profile but the user's own config
// (config_entry): sign-ins, conversations, databases, logs, settings. Profiles: every one of
// agy_profile_dirs, and any folder that holds agy's marks. HOME or above is never one.
// p: clean and absolute.
agy_credential :: proc(p: string) -> bool {
	base := filepath.base(p)
	// agy's file sign-in and Gemini CLI's OAuth files, by name anywhere (pi's AGY_TOKEN_FILES)
	for f in ([3]string{"acp_token.json", "oauth_creds.json", "google_accounts.json"}) do if strings.equal_fold(base, f) do return true
	h := agy_home_now()
	homes := [2]string{h, fs_real(h)}
	home_or_above :: proc(d: string, homes: [2]string) -> bool {
		if d == "" || d == "/" || d == "." do return true
		for x in homes do if x != "" && (d == x || under(x, d)) do return true
		return false
	}
	profiles := agy_profiles_root()
	for c in agy_profile_dirs() {
		if home_or_above(c, homes) || !under(p, c) do continue
		if c == profiles || c == fs_real(profiles) do return true // all of it
		// the user's own config there: not the profile's, but it may hold another profile (a
		// folder of skills that is one): kept looking
		if !config_entry(p, c) do return true
	}
	for d := filepath.dir(p); !home_or_above(d, homes); d = filepath.dir(d) {
		if user_home_dir(d) do continue
		if agy_marked_cached(d) && !config_entry(p, d) do return true
	}
	return false
}

// The sign-in files whose other names (hard links) are refused too (credential_ids).
agy_credential_files :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for d in agy_profile_dirs() do append(&out, strings.concatenate({d, "/", AGY_TOKEN_FILE}, context.temp_allocator))
	return out[:]
}

// Why a folder cannot be an Antigravity account ("" = it can): every profile is guarded, so it may
// not be HOME or above it, nor hold a project, the main folder, the chats folder or Deckhand's data
// folder, nor be, be inside or hold a Claude Code config folder or a Codex home.
agy_account_dir_refused :: proc(d: string) -> string {
	h := agy_home_now()
	rd := fs_real(d)
	holds :: proc(d, rd, x: string) -> bool {
		if x == "" do return false
		rx := fs_real(x)
		return x == d || rx == rd || within(x, d) || within(rx, rd)
	}
	if d == "/" || h == "" || holds(d, rd, h) do return "an agy profile is not your home folder or above it"
	for p in state.projects do if p.machine == 0 && holds(d, rd, p.cwd) do return fmt.tprintf("it holds the project %s: pick the agy profile itself", p.label != "" ? p.label : p.cwd)
	if holds(d, rd, state.settings.home_dir) do return "it holds Deckhand's main folder: pick the agy profile itself"
	if holds(d, rd, chats_cwd()) do return "it holds the chats folder: pick the agy profile itself"
	if dd := data_dir(context.temp_allocator); dd != "" && holds(d, rd, dd) do return "it holds Deckhand's data folder: pick the agy profile itself"
	for harness in ([2]Harness{.Claude, .Codex}) do for o in claude_account_dirs(harness) {
		if holds(d, rd, o) || holds(o, fs_real(o), d) do return fmt.tprintf("it is, is inside, or holds %s (%s)", harness_is_codex(harness) ? "a Codex home" : "a Claude Code config folder", path_tilde(o))
	}
	return ""
}

// The account (its label) whose profile holds path ("" = none): a project, the main folder or the
// chats folder never goes there (it would be locked out of the editor and Files).
agy_account_holding :: proc(path: string) -> string {
	if path == "" do return ""
	rp := fs_real(path)
	for a in agy_accounts() {
		ra := fs_real(a.dir)
		if path == a.dir || rp == ra || within(path, a.dir) || within(rp, ra) do return a.label
	}
	return ""
}

// ---- commands ----

// The account named by its name, label (any case) or folder; err says which there are.
agy_account_resolve :: proc(name: string) -> (a: Agy_Account, err: string) {
	n := strings.trim_space(name)
	accts := agy_accounts()
	if n == "" do return {}, "account is needed"
	c := clean_abs(n)
	for x in accts do if x.name == n do return x, ""
	for x in accts do if c != "" && (x.dir == c || fs_real(c) == fs_real(x.dir)) do return x, ""
	for x in accts do if strings.equal_fold(x.label, n) do return x, ""
	b := strings.builder_make(context.temp_allocator)
	for x, i in accts {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, x.label)
	}
	return {}, fmt.tprintf("no such Antigravity account (Settings → Antigravity accounts: %s)", strings.to_string(b))
}

@(private = "file")
Edit :: struct {
	name, label, dir, method, gcp_project, gcp_location, storage, source: string,
	add, remove, rename, set_default, profile: bool,
	// add: agy's own default profile with no file sign-in, the keychain account if none is by then
	// (decided inside the lock); lost: the name was taken meanwhile (another writer)
	keyring_candidate, lost: bool,
}

// Applies one edit inside the lock (agy_accounts_change).
@(private = "file")
apply_edit :: proc(o: ^json.Object, data: rawptr) -> bool {
	ed := (^Edit)(data)
	list := array_of(o, "accounts")
	defer o^["accounts"] = list
	find :: proc(list: json.Array, name: string) -> int {
		for v, i in list do if e, ok := v.(json.Object); ok && str_of(e, "name") == name do return i
		return -1
	}
	switch {
	case ed.add:
		if find(list, ed.name) >= 0 {
			ed.lost = true
			return false
		}
		e := make(json.Object, context.temp_allocator)
		e["name"] = json.String(ed.name)
		e["method"] = json.String(ed.method)
		if ed.label != "" do e["label"] = json.String(ed.label)
		if ed.dir != "" {
			e["dir"] = json.String(ed.dir)
			e["source"] = json.String("added")
		}
		if ed.storage != "" do e["storage"] = json.String(ed.storage)
		if ed.keyring_candidate && !keyring_marked_raw(list) && !default_holds_keyring_raw(list) do e["storage"] = json.String("keyring")
		if ed.gcp_project != "" do e["gcpProject"] = json.String(ed.gcp_project)
		if ed.gcp_location != "" do e["gcpLocation"] = json.String(ed.gcp_location)
		append(&list, json.Value(e))
		// added again: no longer one the user removed
		if ed.dir != "" {
			if rm, ok := o^["removedDirs"].(json.Array); ok {
				for i := len(rm) - 1; i >= 0; i -= 1 do if s, so := rm[i].(json.String); so && clean_abs(string(s)) == ed.dir do ordered_remove(&rm, i)
				o^["removedDirs"] = rm
			}
		}
		return true
	case ed.rename:
		i := find(list, ed.name)
		e: json.Object
		if i >= 0 {
			e = list[i].(json.Object)
		} else {
			// an account the file does not name yet (the implicit default, a profile): named now
			e = make(json.Object, context.temp_allocator)
			e["name"] = json.String(ed.name)
			e["method"] = json.String(ed.method)
		}
		if ed.label == "" do delete_key(&e, "label")
		else do e["label"] = json.String(ed.label)
		if i >= 0 do list[i] = e
		else do append(&list, json.Value(e))
		return true
	case ed.remove:
		if i := find(list, ed.name); i >= 0 do ordered_remove(&list, i)
		if ed.dir != "" {
			rm := array_of(o, "removedDirs")
			have := false
			for v in rm do if s, so := v.(json.String); so && clean_abs(string(s)) == ed.dir do have = true
			if !have do append(&rm, json.Value(json.String(ed.dir)))
			o^["removedDirs"] = rm
		}
		if str_of(o^, "defaultAccount") == ed.name do delete_key(o, "defaultAccount")
		return true
	case ed.set_default:
		if ed.name == "" || ed.name == "default" {
			if _, has := o^["defaultAccount"]; !has do return false
			delete_key(o, "defaultAccount")
			return true
		}
		if str_of(o^, "defaultAccount") == ed.name do return false
		o^["defaultAccount"] = json.String(ed.name)
		return true
	}
	return false
}

agy_account_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	run :: proc(ed: ^Edit) -> (Result, bool) {
		if why := agy_accounts_change(apply_edit, ed); why != "" do return fail(why), false
		if ed.lost do return fail(fmt.tprintf("the account %s exists", ed.name)), false
		return {ok = true}, true
	}
	defer if changed do agy_accounts_gen += 1
	#partial switch c in cmd {
	case Add_Antigravity_Account:
		method := strings.trim_space(c.method)
		if method == "" do method = "oauth-personal"
		if !agy_method_ok(method) do return fail(fmt.tprintf("method must be one of %s", strings.join(AGY_METHODS[:], ", ", context.temp_allocator))), false
		project, location := strings.trim_space(c.gcp_project), strings.trim_space(c.gcp_location)
		if method == "oauth-business" && (project == "" || location == "") do return fail("Gemini Enterprise needs gcp_project and gcp_location"), false
		label := cut_utf8(strings.trim_space(one_line(c.label, context.temp_allocator)), AGY_LABEL_MAX)
		accts := agy_accounts()
		taken := make([dynamic]string, context.temp_allocator)
		for a in accts do append(&taken, a.name)
		ed := Edit{add = true, method = method, label = label, gcp_project = project, gcp_location = location}
		if given := strings.trim_space(c.dir); given != "" {
			if strings.has_prefix(given, "~/") && agy_home_now() != "" do given = strings.concatenate({agy_home_now(), given[1:]}, context.temp_allocator)
			d := clean_abs(given)
			if d == "" do return fail("dir must be an absolute folder"), false
			if path_kind(d) != .Dir do return fail("no such folder"), false
			if within(d, agy_profiles_root()) do return fail("that is one of Deckhand's own profiles: it is listed already, or removed with its account"), false
			if why := agy_account_dir_refused(d); why != "" do return fail(why), false
			for a in accts do if a.dir == d || fs_real(a.dir) == fs_real(d) do return fail(fmt.tprintf("already an account: %s", a.label)), false
			ed.dir = d
			ed.name = strings.trim_space(c.name)
			if ed.name == "" do ed.name = name_from(label != "" ? label : agy_label_of(d), taken[:])
			// agy's own default profile with no file sign-in: the keyring account, while there is none
			// (worked out again inside the lock, where another writer's change is seen)
			def := agy_default_home()
			ed.keyring_candidate = method == "oauth-personal" && (d == def || fs_real(d) == fs_real(def)) && !agy_signed_in_file(d)
		} else {
			ed.name = strings.trim_space(c.name)
			if ed.name == "" do return fail("name (a new profile) or dir (an agy profile folder) is needed"), false
		}
		if !agy_valid_name(ed.name) do return fail(fmt.tprintf("%q cannot name an account: lower-case letters, digits and -, up to 32", ed.name)), false
		if slice.contains(taken[:], ed.name) do return fail(fmt.tprintf("the account %s exists", ed.name)), false
		for a in accts do if label != "" && strings.equal_fold(a.label, label) do return fail("another account has that name"), false
		return run(&ed)
	case Rename_Antigravity_Account:
		a, err := agy_account_resolve(c.account)
		if err != "" do return fail(err), false
		label := cut_utf8(strings.trim_space(one_line(c.label, context.temp_allocator)), AGY_LABEL_MAX)
		for x in agy_accounts() do if x.name != a.name && label != "" && strings.equal_fold(x.label, label) do return fail("another account has that name"), false
		ed := Edit{rename = true, name = a.name, label = label, method = a.method}
		return run(&ed)
	case Remove_Antigravity_Account:
		a, err := agy_account_resolve(c.account)
		if err != "" do return fail(err), false
		if a.source == .Default do return fail("the default account stays (Deckhand's own profile): sign it out in a pi tab with /antigravity logout"), false
		// the keychain's account (the shared rule, accounts_make): removed here, its keychain sign-in
		// would pass to the next keychain account. A pi tab's remove signs it out first.
		if a.keyring do return fail(agy_keyring_remove_hint(a.name)), false
		// the folder is never deleted: it is remembered as removed (and stays guarded while it holds agy's files)
		ed := Edit{remove = true, name = a.name, dir = path_kind(a.dir) == .Dir ? a.dir : ""}
		return run(&ed)
	case Set_Antigravity_Account_Default:
		name := ""
		if strings.trim_space(c.account) != "" {
			a, err := agy_account_resolve(c.account)
			if err != "" do return fail(err), false
			name = a.name
		}
		ed := Edit{set_default = true, name = name}
		return run(&ed)
	}
	return fail("not an Antigravity account command"), false
}

// ---- what the lists show ----

// Whether the default account holds the keychain: no Google entry has storage "keyring", and the
// default (implicit until written) is a Google account not marked "file" with no sign-in file of
// its own (lib/agy-accounts.ts keychainHolder: the same rule).
@(private = "file")
default_holds_keyring :: proc(entries: []Entry) -> bool {
	method, storage := "oauth-personal", ""
	for e in entries {
		if e.storage == "keyring" && e.method == "oauth-personal" do return false
		if e.name == "default" do method, storage = e.method, e.storage
	}
	return method == "oauth-personal" && storage != "file" && !default_signed_in_file()
}

// Whether Deckhand's own default profile has a sign-in file (the default never has a dir).
@(private = "file")
default_signed_in_file :: proc() -> bool {
	p := agy_profiles_root()
	return p != "" && agy_signed_in_file(strings.concatenate({p, "/default"}, context.temp_allocator))
}

// Whether a raw list has a Google entry marked "keyring" (one holds, or none may be given it).
@(private = "file")
keyring_marked_raw :: proc(list: json.Array) -> bool {
	for v in list do if e, ok := v.(json.Object); ok && str_of(e, "storage") == "keyring" && str_of(e, "method") == "oauth-personal" do return true
	return false
}

// default_holds_keyring over accounts.json's raw list (inside the lock).
@(private = "file")
default_holds_keyring_raw :: proc(list: json.Array) -> bool {
	method, storage := "oauth-personal", ""
	for v in list {
		e, ok := v.(json.Object)
		if !ok do continue
		if str_of(e, "storage") == "keyring" && str_of(e, "method") == "oauth-personal" do return false
		if str_of(e, "name") == "default" do method, storage = str_of(e, "method"), str_of(e, "storage")
	}
	return method == "oauth-personal" && storage != "file" && !default_signed_in_file()
}

// Why the keychain's account is not removed here (Remove_Antigravity_Account, its Settings row).
agy_keyring_remove_hint :: proc(name: string) -> string {
	return fmt.tprintf("Remove it from a pi tab with /antigravity remove %s: that signs its keychain sign-in out first.", name)
}

// Whether the account named so (not the default) holds the macOS keychain: not removed here.
agy_account_holds_keyring :: proc(name: string) -> bool {
	for a in agy_accounts() do if a.name == name do return a.keyring && a.source != .Default
	return false
}

// An account's state in plain words (its Settings row; the setup step).
agy_account_detail :: proc(a: Agy_Account) -> string {
	how := ""
	switch a.sign_in {
	case .Yes:      how = "signed in"
	case .No:
		def := agy_default_home()
		own := a.dir == def || fs_real(a.dir) == fs_real(def)
		how = a.method != "oauth-personal" ? fmt.tprintf("sign-in unknown until agy is used (/antigravity login %s in a pi tab to sign in)", a.name) : own ? fmt.tprintf("no sign-in of its own (/antigravity login %s in a pi tab writes a sign-in file into %s, which agy outside Deckhand then uses too)", a.name, fs_display(a.dir)) : fmt.tprintf("no sign-in of its own (/antigravity login %s in a pi tab)", a.name)
	case .Keychain: how = "signed in through the system keychain (not checked)"
	case .Key:      how = fmt.tprintf("API key in pi (/login %s)", a.name == "default" ? "antigravity" : strings.concatenate({"antigravity-", a.name}, context.temp_allocator))
	case .Adc:      how = "Application Default Credentials"
	}
	if a.missing do how = "its folder is gone"
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s · %s", agy_method_label(a.method), how)
	if a.models >= 0 do fmt.sbprintf(&b, " · %d model%s", a.models, a.models == 1 ? "" : "s")
	fmt.sbprintf(&b, " · %s", fs_display(a.dir))
	if a.chosen do strings.write_string(&b, " · default")
	if a.keyring && a.source != .Default do fmt.sbprintf(&b, " · %s", agy_keyring_remove_hint(a.name))
	return strings.to_string(b)
}

AGY_ACCOUNT_ROW :: "deckhand:agy-account:"
AGY_ACCOUNT_ADD_ROW :: "deckhand:agy-account-add"
AGY_ACCOUNT_MORE_ROW :: "deckhand:agy-account-more"
AGY_ACCOUNT_SCAN_ROW :: "deckhand:agy-account-scan"

// Whether Settings shows the Antigravity accounts: agy is there, or there are several already.
agy_accounts_shown :: proc() -> bool {
	if b, _ := agy_detect(); b != "" do return true
	return agy_accounts_many()
}

// The rows (settings_file_rows): each account's once there are several, Add account… and Scan
// again; with one, one quiet More accounts….
agy_settings_rows :: proc(out: ^[dynamic]Settings_File_Row) {
	if !agy_accounts_shown() do return
	accts := agy_accounts()
	if len(accts) > 1 {
		for a in accts do append(out, Settings_File_Row{group = "agy-accounts", label = a.label, detail = agy_account_detail(a), path = strings.concatenate({AGY_ACCOUNT_ROW, a.name}, context.temp_allocator), button = "Rename…", remove = a.source != .Default && !a.keyring, make_default = !a.chosen})
		append(out, Settings_File_Row{group = "agy-accounts", label = "Add account…", detail = "an agy profile folder (its --gemini-dir), used in place", path = AGY_ACCOUNT_ADD_ROW, button = "Add…"})
		append(out, Settings_File_Row{group = "agy-accounts", label = "Scan again", detail = "look for agy profiles in ~/.gemini*, ~/.config/gemini*", path = AGY_ACCOUNT_SCAN_ROW, button = "Scan"})
	} else {
		append(out, Settings_File_Row{group = "agy-accounts", label = "More accounts…", detail = "another agy profile folder (its --gemini-dir)", path = AGY_ACCOUNT_MORE_ROW, button = "Add…"})
	}
}

// The snapshot's accounts (no secrets: names, labels, folders, how each signs in).
agy_accounts_json :: proc(b: ^strings.Builder) {
	strings.write_string(b, `,"antigravity_accounts":[`)
	for a, i in agy_accounts() {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"name":`)
		json_quote(b, a.name)
		strings.write_string(b, `,"label":`)
		json_quote(b, a.label)
		strings.write_string(b, `,"dir":`)
		json_quote(b, a.dir)
		strings.write_string(b, `,"method":`)
		json_quote(b, a.method)
		fmt.sbprintf(b, `,"source":"%s","signed_in":"%s"`, AGY_SOURCE_NAMES[a.source], AGY_SIGN_IN_NAMES[a.sign_in])
		if a.keyring do strings.write_string(b, `,"keyring":true`)
		if a.chosen do strings.write_string(b, `,"chosen":true`)
		if a.models >= 0 do fmt.sbprintf(b, `,"models":%d`, a.models)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}
