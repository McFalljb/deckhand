package main

// Antigravity accounts (agy_accounts.odin; docs/HARNESSES.md §3a "Accounts"): discovery by stat,
// accounts.json under the extension's lock (lib/agy-lock.ts), the commands and their refusals, the
// guard on every profile, Settings' rows. Every test runs in its own fake HOME (the data dir is
// under it in test mode); no agy, pi or Google is ever involved, and no token file is ever read
// (they are made unreadable: a read would fail where a stat does not).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
AG_UI :: core.Caller{kind = .UI}

@(private = "file")
Ag_Env :: struct {
	home, root, old_home: string, // root: <data dir>/antigravity
}

@(private = "file")
ag_reset :: proc() -> (env: Ag_Env) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	core.platform, win_os = {quit = proc() {}}, {set_clipboard = proc(s: string) {}}
	env.old_home = strings.clone(os.get_env("HOME", context.temp_allocator))
	d := fmt.aprintf("%s/deckhand-agy-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	if r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:])); r != nil do d = strings.clone(string(r))
	env.home = d
	os.set_env("HOME", d)
	os.unset_env("XDG_CONFIG_HOME")
	os.unset_env("GEMINI_HOME")
	os.unset_env("DECKHAND_DATA_DIR")
	core.login_env.children = nil
	env.root = strings.clone(core.agy_root())
	os.make_directory_all(env.root)
	core.agy_accounts_refresh()
	return
}

@(private = "file")
ag_done :: proc(env: Ag_Env) {
	os.set_env("HOME", env.old_home)
	core.agy_accounts_refresh()
	os.remove_all(env.home)
}

@(private = "file")
ag_write :: proc(path, text: string, mode: posix.mode_t = {.IRUSR, .IWUSR}) {
	os.make_directory_all(filepath.dir(path))
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if fd >= 0 {
		posix.write(fd, raw_data(text), uint(len(text)))
		posix.close(fd)
	}
	posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), mode)
}

// An agy profile: its installation id, and a file sign-in (unreadable: never read) when signed.
@(private = "file")
ag_profile :: proc(dir: string, signed := false, cli := false) {
	ag_write(fmt.tprintf("%s/%s/installation_id", dir, cli ? "antigravity" : "antigravity-acp"), "id\n")
	ag_write(fmt.tprintf("%s/antigravity-acp/conversation_summaries.db", dir), "db")
	ag_write(fmt.tprintf("%s/GEMINI.md", dir), "# rules\n", {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if signed do ag_write(fmt.tprintf("%s/antigravity-acp/acp_token.json", dir), `{"secret":"never read"}`, {})
}

@(private = "file")
ag_file :: proc(env: Ag_Env) -> json.Object {
	data, err := os.read_entire_file(fmt.tprintf("%s/accounts.json", env.root), context.temp_allocator)
	if err != nil do return nil
	v, jerr := json.parse(data, allocator = context.temp_allocator)
	if jerr != nil do return nil
	o, _ := v.(json.Object)
	return o
}

@(private = "file")
ag_entry :: proc(env: Ag_Env, name: string) -> json.Object {
	o := ag_file(env)
	list, _ := o["accounts"].(json.Array)
	for v in list do if e, ok := v.(json.Object); ok && (e["name"].(json.String) or_else "") == json.String(name) do return e
	return nil
}

@(private = "file")
ag_find :: proc(name: string) -> (core.Agy_Account, bool) {
	for a in core.agy_accounts() do if a.name == name do return a, true
	return {}, false
}

// Found by stat: agy's default profile (~/.gemini, the keyring account without a file sign-in),
// ~/.gemini-* and ~/.config/gemini*, holding agy's marks; written into accounts.json as found;
// a folder without them, or Gemini CLI's own, is not one. The sign-in is told by stat only.
@(test)
agy_accounts_found_by_stat :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env := ag_reset()
	defer ag_done(env)
	h := env.home
	ag_profile(fmt.tprintf("%s/.gemini", h), cli = true) // what plain agy uses: no file sign-in
	ag_profile(fmt.tprintf("%s/.gemini-work", h), signed = true)
	ag_profile(fmt.tprintf("%s/.config/gemini-lab", h))
	os.make_directory_all(fmt.tprintf("%s/.gemini-cli-only", h)) // Gemini CLI's: no agy marks
	ag_write(fmt.tprintf("%s/.gemini-cli-only/oauth_creds.json", h), "{}")
	core.agy_accounts_refresh()
	accts := core.agy_accounts()
	testing.expect_value(t, len(accts), 4)
	testing.expect_value(t, accts[0].name, "default")
	testing.expect(t, accts[0].chosen, "default chosen")
	g, gok := ag_find("gemini")
	testing.expect(t, gok && g.keyring && g.sign_in == .Keychain && g.source == .Found && g.label == "Gemini", "~/.gemini: the keyring account")
	w, wok := ag_find("work")
	testing.expect(t, wok && !w.keyring && w.sign_in == .Yes && w.label == "Work", "~/.gemini-work: signed in by file")
	l, lok := ag_find("lab")
	testing.expect(t, lok && l.sign_in == .No, "~/.config/gemini-lab: not signed in")
	_, cok := ag_find("cli-only")
	testing.expect(t, !cok, "a folder without agy's marks is not an account")
	e := ag_entry(env, "work")
	testing.expect_value(t, e["source"].(json.String) or_else "", "found")
	testing.expect_value(t, e["storage"].(json.String) or_else "", "file")
	testing.expect_value(t, ag_entry(env, "gemini")["storage"].(json.String) or_else "", "keyring")
	// the file is 0600 in a 0700 folder
	k, st := core.path_stat(fmt.tprintf("%s/accounts.json", env.root))
	testing.expect(t, k == .File && st.mode == 0o600, "accounts.json 0600")
	_, rs := core.path_stat(env.root)
	testing.expect_value(t, rs.mode, u32(0o700))
	// a second scan changes nothing (one writer, no churn)
	before := st
	core.agy_accounts_refresh()
	_, after := core.path_stat(fmt.tprintf("%s/accounts.json", env.root))
	testing.expect(t, before.inode == after.inode && before.mtime == after.mtime, "not written again")
	// GEMINI_HOME (as tabs get it) names agy's default: ~/.gemini then is a file account like the rest
	testing.expect(t, core.agy_default_home() == fmt.tprintf("%s/.gemini", h))
}

// At most one keyring account: a file sign-in in agy's default wins (file mode), and a second
// keyring entry in the file is a file account.
@(test)
agy_accounts_one_keyring :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env := ag_reset()
	defer ag_done(env)
	ag_profile(fmt.tprintf("%s/.gemini", env.home), signed = true)
	core.agy_accounts_refresh()
	g, _ := ag_find("gemini")
	testing.expect(t, !g.keyring && g.sign_in == .Yes, "signed in by file: file mode")
	ag_write(fmt.tprintf("%s/accounts.json", env.root), fmt.tprintf(`{{"accounts":[{{"name":"a","method":"oauth-personal","dir":"%s/a","storage":"keyring"}},{{"name":"b","method":"oauth-personal","dir":"%s/b","storage":"keyring"}}]}}`, env.home, env.home))
	a, _ := ag_find("a")
	b, _ := ag_find("b")
	testing.expect(t, a.keyring && !b.keyring, "the first keyring entry only")
}

// A removed folder is never listed again by a scan; adding it again brings it back. The folder
// itself is never touched.
@(test)
agy_accounts_remove_and_add_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env := ag_reset()
	defer ag_done(env)
	work := fmt.tprintf("%s/.gemini-work", env.home)
	ag_profile(work, signed = true)
	core.agy_accounts_refresh()
	testing.expect(t, core.run_command(core.Remove_Antigravity_Account{account = "Work"}, AG_UI).ok)
	_, ok := ag_find("work")
	testing.expect(t, !ok, "removed")
	testing.expect(t, core.path_kind(fmt.tprintf("%s/antigravity-acp/acp_token.json", work)) == .File, "its folder is untouched")
	core.agy_accounts_refresh()
	_, ok = ag_find("work")
	testing.expect(t, !ok, "not found again")
	rm, _ := ag_file(env)["removedDirs"].(json.Array)
	testing.expect(t, len(rm) == 1 && (rm[0].(json.String) or_else "") == json.String(work), "remembered as removed")
	// still guarded while it holds agy's files
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/antigravity-acp/conversation_summaries.db", work)))
	r := core.run_command(core.Add_Antigravity_Account{dir = work}, AG_UI)
	testing.expectf(t, r.ok, "added again: %s", r.error)
	a, aok := ag_find("work")
	testing.expect(t, aok && a.source == .Added, "back, as the user's")
	rm, _ = ag_file(env)["removedDirs"].(json.Array)
	testing.expect_value(t, len(rm), 0)
	// the default stays
	r = core.run_command(core.Remove_Antigravity_Account{account = "default"}, AG_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "default account stays"), r.error)
}

// The commands: a new profile by name, a folder in place, rename (the label only), the default;
// every refusal says why. Only the user may send them.
@(test)
agy_accounts_commands :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env := ag_reset()
	defer ag_done(env)
	r := core.run_command(core.Add_Antigravity_Account{name = "personal"}, AG_UI)
	testing.expectf(t, r.ok, "a new profile: %s", r.error)
	p, ok := ag_find("personal")
	testing.expect(t, ok && p.dir == fmt.tprintf("%s/profiles/personal", env.root) && p.source == .Profile, "under profiles/")
	refused :: proc(t: ^testing.T, c: core.Command, want: string, loc := #caller_location) {
		r := core.run_command(c, AG_UI)
		testing.expectf(t, !r.ok && strings.contains(r.error, want), "refused (%s): %v", want, r.error, loc = loc)
	}
	refused(t, core.Add_Antigravity_Account{name = "personal"}, "exists")
	refused(t, core.Add_Antigravity_Account{name = "Bad Name"}, "cannot name an account")
	refused(t, core.Add_Antigravity_Account{}, "name (a new profile) or dir")
	refused(t, core.Add_Antigravity_Account{name = "x", method = "magic"}, "method must be one of")
	refused(t, core.Add_Antigravity_Account{name = "biz", method = "oauth-business"}, "gcp_project")
	refused(t, core.Add_Antigravity_Account{dir = "relative/dir"}, "absolute")
	refused(t, core.Add_Antigravity_Account{dir = fmt.tprintf("%s/nope", env.home)}, "no such folder")
	refused(t, core.Add_Antigravity_Account{dir = env.home}, "not your home folder or above it")
	refused(t, core.Add_Antigravity_Account{dir = "/"}, "not your home folder or above it")
	os.make_directory_all(fmt.tprintf("%s/profiles/personal", env.root))
	refused(t, core.Add_Antigravity_Account{dir = fmt.tprintf("%s/profiles/personal", env.root)}, "Deckhand's own profiles")
	// a folder holding a project, the main folder, the data folder, or a Claude config folder
	proj := fmt.tprintf("%s/work/code", env.home)
	os.make_directory_all(proj)
	append(&state.projects, core.Project{id = core.new_id(), cwd = strings.clone(proj), label = "code"})
	refused(t, core.Add_Antigravity_Account{dir = fmt.tprintf("%s/work", env.home)}, "holds the project code")
	main_dir := fmt.tprintf("%s/notes", env.home)
	os.make_directory_all(fmt.tprintf("%s/inner", main_dir))
	state.settings.home_dir = strings.clone(fmt.tprintf("%s/inner", main_dir))
	refused(t, core.Add_Antigravity_Account{dir = main_dir}, "main folder")
	state.settings.home_dir = ""
	refused(t, core.Add_Antigravity_Account{dir = fmt.tprintf("%s/Library", env.home)}, "data folder")
	cl := fmt.tprintf("%s/.claude", env.home)
	os.make_directory_all(cl)
	refused(t, core.Add_Antigravity_Account{dir = cl}, "Claude Code config folder")
	// a folder anywhere, used in place; `~/` is HOME
	os.make_directory_all(fmt.tprintf("%s/agy-lab", env.home))
	r = core.run_command(core.Add_Antigravity_Account{dir = "~/agy-lab", label = "Lab"}, AG_UI)
	testing.expectf(t, r.ok, "added: %s", r.error)
	lab, lok := ag_find("lab")
	testing.expect(t, lok && lab.dir == fmt.tprintf("%s/agy-lab", env.home) && lab.label == "Lab" && lab.source == .Added, "the folder in place")
	refused(t, core.Add_Antigravity_Account{dir = fmt.tprintf("%s/agy-lab", env.home)}, "already an account")
	// rename: the label only (the provider id stays)
	testing.expect(t, core.run_command(core.Rename_Antigravity_Account{account = "lab", label = "Research"}, AG_UI).ok)
	lab, _ = ag_find("lab")
	testing.expect_value(t, lab.label, "Research")
	refused(t, core.Rename_Antigravity_Account{account = "personal", label = "research"}, "another account has that name")
	refused(t, core.Rename_Antigravity_Account{account = "nobody", label = "x"}, "no such Antigravity account")
	// the default: by label; "" is `default` again
	testing.expect(t, core.run_command(core.Set_Antigravity_Account_Default{account = "Research"}, AG_UI).ok)
	testing.expect_value(t, ag_file(env)["defaultAccount"].(json.String) or_else "", "lab")
	lab, _ = ag_find("lab")
	testing.expect(t, lab.chosen, "chosen")
	testing.expect(t, core.run_command(core.Remove_Antigravity_Account{account = "lab"}, AG_UI).ok)
	_, has := ag_file(env)["defaultAccount"]
	testing.expect(t, !has, "removing the chosen default resets it")
	testing.expect(t, core.path_kind(fmt.tprintf("%s/agy-lab", env.home)) == .Dir, "the folder stays")
	// agents and scripts never send them (an agent never names a folder of its own)
	for c in ([]core.Caller{{kind = .Control}, {kind = .Panel, tab_id = 1}, {kind = .Panel, tab_id = 1, claude = true}}) {
		for cmd in ([]core.Command{core.Add_Antigravity_Account{dir = env.home}, core.Add_Antigravity_Account{name = "agent"}, core.Remove_Antigravity_Account{account = "personal"}, core.Rename_Antigravity_Account{account = "personal", label = "x"}, core.Set_Antigravity_Account_Default{account = "personal"}}) {
			testing.expectf(t, !core.caller_may(c, cmd), "%v may not send %v", c, cmd)
		}
	}
}

// accounts.json is shared with pi's extension: the core keeps every key it does not know, and
// edits it only under the lock (lib/agy-lock.ts: accounts.json.lock, {"pid":N}, hard-linked).
@(test)
agy_accounts_file_shared_with_pi :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env := ag_reset()
	defer ag_done(env)
	file := fmt.tprintf("%s/accounts.json", env.root)
	ag_write(file, `{"about":"x","agyPath":"/opt/agy","future":{"k":[1,2]},"accounts":[{"name":"default","method":"oauth-personal","note":"pi's"},{"name":"key","method":"gemini-api-key","extra":true}]}`)
	testing.expect(t, core.run_command(core.Rename_Antigravity_Account{account = "key", label = "API"}, AG_UI).ok)
	o := ag_file(env)
	testing.expect_value(t, o["agyPath"].(json.String) or_else "", "/opt/agy")
	_, fut := o["future"].(json.Object)
	testing.expect(t, fut, "an unknown key kept")
	testing.expect_value(t, ag_entry(env, "key")["extra"].(json.Boolean) or_else false, true)
	testing.expect_value(t, ag_entry(env, "key")["label"].(json.String) or_else "", "API")
	testing.expect_value(t, ag_entry(env, "default")["note"].(json.String) or_else "", "pi's")
	k, _ := ag_find("key")
	testing.expect(t, k.sign_in == .Key, "an API-key account: its key is pi's")
	lock := fmt.tprintf("%s.lock", file)
	// a lock a live process holds (pi): refused, the file untouched, the lock left
	ag_write(lock, fmt.tprintf(`{{"pid":%d}}`, posix.getppid()))
	_, st0 := core.path_stat(file)
	r := core.run_command(core.Set_Antigravity_Account_Default{account = "key"}, AG_UI)
	testing.expectf(t, !r.ok && strings.contains(r.error, "try again"), "held: %s", r.error)
	_, st1 := core.path_stat(file)
	testing.expect(t, st0.mtime == st1.mtime && core.path_kind(lock) == .File, "nothing written, the lock stays")
	// an empty lock younger than 2 s: being written, respected
	ag_write(lock, "")
	testing.expect(t, !core.agy_lock_try(lock), "an empty, young lock is held")
	// a lock whose process is gone: taken over, then released
	ag_write(lock, `{"pid":999999}`)
	testing.expect(t, core.run_command(core.Set_Antigravity_Account_Default{account = "key"}, AG_UI).ok)
	testing.expect(t, core.path_kind(lock) == .Missing, "released")
	testing.expect_value(t, ag_file(env)["defaultAccount"].(json.String) or_else "", "key")
	// our own lock: its content is our pid, exactly as the extension writes it
	testing.expect(t, core.agy_lock_try(lock))
	data, _ := os.read_entire_file(lock, context.temp_allocator)
	testing.expect_value(t, string(data), fmt.tprintf(`{{"pid":%d}}`, posix.getpid()))
	core.agy_lock_release(lock)
	testing.expect(t, core.path_kind(lock) == .Missing)
	// no leftovers next to it
	entries, _ := os.read_all_directory_by_path(env.root, context.temp_allocator)
	for e in entries do testing.expectf(t, !strings.contains(e.name, ".new-") && !strings.contains(e.name, ".stale-") && !strings.contains(e.name, ".tmp-"), "left over: %s", e.name)
	// a file that is not JSON: never written over
	ag_write(file, "{not json")
	r = core.run_command(core.Set_Antigravity_Account_Default{account = ""}, AG_UI)
	testing.expectf(t, !r.ok && strings.contains(r.error, "not a JSON object"), "%s", r.error)
	data, _ = os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "{not json")
}

// The guard: every profile's sign-in and state is refused to everyone (agents too), by any name;
// its GEMINI.md and skills are the user's; any acp_token.json anywhere is refused; Deckhand's own
// profiles are refused whole. The Files tree treats profiles as credential places.
@(test)
agy_accounts_guard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env := ag_reset()
	defer ag_done(env)
	work := fmt.tprintf("%s/.gemini-work", env.home)
	ag_profile(work, signed = true)
	ag_write(fmt.tprintf("%s/config/skills/s/SKILL.md", work), "skill", {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	ag_write(fmt.tprintf("%s/log/acp-server-x-1.log", work), "log", {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	core.agy_accounts_refresh()
	own := fmt.tprintf("%s/profiles/default", env.root)
	ag_profile(own, signed = true)
	ag_write(fmt.tprintf("%s/GEMINI.md", own), "# linked\n", {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	// a third profile nobody listed: guarded by what it holds
	stray := fmt.tprintf("%s/elsewhere/prof", env.home)
	ag_profile(stray, signed = true)
	secrets := []string{
		fmt.tprintf("%s/antigravity-acp/acp_token.json", work),
		fmt.tprintf("%s/antigravity-acp/conversation_summaries.db", work),
		fmt.tprintf("%s/antigravity-acp/installation_id", work),
		fmt.tprintf("%s/log/acp-server-x-1.log", work),
		fmt.tprintf("%s/antigravity-acp/acp_token.json", own),
		fmt.tprintf("%s/GEMINI.md", own), // Deckhand's own profiles: all of them
		fmt.tprintf("%s/antigravity-acp/conversation_summaries.db", stray),
		fmt.tprintf("%s/anything/acp_token.json", env.home), // by name, anywhere
		fmt.tprintf("%s/anything/ACP_TOKEN.JSON", env.home),
	}
	for p in secrets {
		testing.expectf(t, core.settings_credential(p), "%s is refused", p)
		r := core.run_command(core.Open_File{path = p}, AG_UI) // not even the user, in the editor
		testing.expectf(t, !r.ok && r.error == core.CREDENTIAL_REFUSED, "%s opened: %v", p, r)
		for c in ([]core.Caller{AG_UI, {kind = .Control}, {kind = .Script}}) {
			r = core.run_command(core.File_Read{path = p}, c) // file_read (a browser's, scripts', Atlas's)
			testing.expectf(t, !r.ok, "%s read by %v", p, c.kind)
		}
	}
	for p in ([]string{fmt.tprintf("%s/GEMINI.md", work), fmt.tprintf("%s/config/skills/s/SKILL.md", work)}) {
		testing.expectf(t, !core.settings_credential(p), "%s is the user's config", p)
	}
	// another name for a sign-in file: a symlink, a hard link
	ln := fmt.tprintf("%s/innocent.json", env.home)
	os.symlink(fmt.tprintf("%s/antigravity-acp/acp_token.json", work), ln)
	testing.expect(t, core.settings_credential(ln), "a symlink to the sign-in")
	hl := fmt.tprintf("%s/innocent2.json", env.home)
	os.link(fmt.tprintf("%s/antigravity-acp/acp_token.json", work), hl)
	testing.expect(t, core.settings_credential(hl), "a hard link to the sign-in")
	// the Files tree: a profile (and anything inside it) is a credential place; HOME is not
	testing.expect(t, core.fs_credential_place(work), "a found profile")
	testing.expect(t, core.fs_credential_place(fmt.tprintf("%s/antigravity-acp", work)), "inside one")
	testing.expect(t, core.fs_credential_place(stray), "a profile by what it holds")
	testing.expect(t, core.fs_credential_place(env.root), "the folder holding Deckhand's profiles")
	testing.expect(t, !core.settings_credential(fmt.tprintf("%s/notes.md", env.home)), "HOME's own files stay")
	// a project inside a profile is refused
	testing.expect(t, core.account_holding_why(fmt.tprintf("%s/proj", work)) != "", "no project inside a profile")
}

// Settings: with one account, one quiet More accounts… (once agy is there or there are several);
// with several, each one's row (how it signs in, its models, its folder), Add account… and Scan again.
@(test)
agy_accounts_settings_rows :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env := ag_reset()
	defer ag_done(env)
	rows :: proc() -> []core.Settings_File_Row {
		out := make([dynamic]core.Settings_File_Row, context.temp_allocator)
		core.agy_settings_rows(&out)
		return out[:]
	}
	testing.expect_value(t, len(rows()), 0) // no agy (unit tests never find one), one account
	ag_profile(fmt.tprintf("%s/.gemini-work", env.home), signed = true)
	ag_profile(fmt.tprintf("%s/.gemini", env.home), cli = true)
	ag_write(fmt.tprintf("%s/agy-models.json", env.root), `{"work":{"count":7,"at":1}}`)
	core.agy_accounts_refresh()
	got := rows()
	b := strings.builder_make(context.temp_allocator)
	for r in got do fmt.sbprintf(&b, "%s|%s|%s|%v%v\n", r.label, r.detail, r.button, r.remove, r.make_default)
	s := strings.to_string(b)
	testing.expectf(t, len(got) == 5, "three accounts, Add, Scan:\n%s", s)
	testing.expectf(t, strings.contains(s, "Default|Google account · not signed in: /antigravity login default in a pi tab ·"), "%s", s)
	testing.expectf(t, strings.contains(s, "Gemini|Google account · signed in through the system keychain (not checked) · ~/.gemini|Rename…|truetrue"), "%s", s)
	testing.expectf(t, strings.contains(s, "Work|Google account · signed in · 7 models · ~/.gemini-work|Rename…|truetrue"), "%s", s)
	testing.expectf(t, strings.contains(s, "Add account…|") && strings.contains(s, "Scan again|"), "%s", s)
	for r in got do if r.label == "Default" do testing.expect(t, !r.remove && !r.make_default, "the default: not removed, chosen")
}
